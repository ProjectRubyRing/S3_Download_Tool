#!/usr/bin/env bash
#
# s3_download.sh
#
# 指定した S3 バケットの指定フォルダ (プレフィックス) 配下のファイルを、
# 指定したローカルディレクトリへすべてダウンロードする。
#
# 実行前に対象 S3 へのアクセス権限を確認し、CodeCommit 用ロールに切り替えたまま等で
# 権限が不足している場合は --switchback-mode に応じて以下の動作をする。
#   warn : スイッチバックを促す警告を出して終了する (既定)
#   auto : 別チーム提供のスイッチバック用シェルを source してから処理を続行する
#
# 動作環境: RHEL 9 系 (bash 5.1), AWS CLI v2
#
# 補足:
#   - スイッチバック用シェルはこのスクリプトのプロセス内で source するため、
#     切り替えた認証情報は呼び出し元のシェル (ターミナル) には反映されない。
#   - スイッチバック用シェルと変数名・関数名が衝突しないよう、
#     本スクリプトのグローバル変数は S3DL_、関数は s3dl_ を接頭辞にしている。
#   - 使い方は -h を参照。
#

# source で読み込まれると set -e 等が呼び出し元シェルに影響するため中断する
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    echo "ERROR: このスクリプトは source せずに実行してください (例: bash ${BASH_SOURCE[0]} -h)" >&2
    return 1
fi

set -euo pipefail
# コマンド置換内でも set -e を有効にする ($(set +o) で errexit を正しく退避するためにも必要)
shopt -s inherit_errexit

readonly S3DL_PROG=${0##*/}

# 終了コード
readonly S3DL_EXIT_OK=0
readonly S3DL_EXIT_USAGE=1      # 引数エラー / 前提条件エラー
readonly S3DL_EXIT_DENIED=2     # 権限不足 (スイッチバックが必要 / スイッチバック後も権限不足)
readonly S3DL_EXIT_TARGET=3     # バケット・フォルダが存在しない / ファイルが無い
readonly S3DL_EXIT_AWS=4        # AWS CLI のその他のエラー (通信エラー等)
readonly S3DL_EXIT_DOWNLOAD=5   # ダウンロード失敗

# アクセス権限の確認結果 (s3dl_check_access の戻り値)
readonly S3DL_CHK_OK=0
readonly S3DL_CHK_DENIED=10     # 権限不足・認証情報の不備 (スイッチバックで解消し得る)
readonly S3DL_CHK_NOTFOUND=11   # バケット・ファイルが存在しない
readonly S3DL_CHK_EMPTY=12      # フォルダ配下にファイルが無い
readonly S3DL_CHK_ERROR=13      # その他のエラー

# 引数
S3DL_BUCKET=""
S3DL_PREFIX=""
S3DL_DEST=""
S3DL_PROFILE=""
S3DL_REGION=""
S3DL_DRYRUN=0
# スイッチバック関連は環境変数で既定値を指定できる
S3DL_SWITCHBACK_MODE=${S3DL_SWITCHBACK_MODE:-warn}
S3DL_SWITCHBACK_SCRIPT=${S3DL_SWITCHBACK_SCRIPT:-}
S3DL_SWITCHBACK_ARGS=${S3DL_SWITCHBACK_ARGS:-}
S3DL_SWITCHBACK_ARGV=()

# 実行時の状態
S3DL_AWS_OPTS=()            # 全 aws コマンド共通のオプション
S3DL_AWS_OUT=""             # s3dl_aws_capture の標準出力
S3DL_AWS_ERR=""             # s3dl_aws_capture の標準エラー出力
S3DL_CALLER_ARN=""          # 現在の実行主体
S3DL_CHECK_MSG=""           # アクセス権限の確認で失敗した処理の説明
S3DL_TMPDIR=""
S3DL_NEED_SWITCHBACK=0      # auto モードでスイッチバックが必要と判定された
S3DL_SWITCHBACK_DONE=0      # スイッチバック実行済み
S3DL_IN_SWITCHBACK=0        # スイッチバック用シェルを source 中
S3DL_SWITCHBACK_RC=0
S3DL_SAVED_OPTS=""
S3DL_SAVED_IFS=""
S3DL_SAVED_PWD=""

s3dl_usage() {
    cat <<EOF
使い方:
  ${S3DL_PROG} -b <バケット名> -p <フォルダ> -d <ダウンロード先> [オプション]

  S3 バケットの指定フォルダ配下のファイルをすべて、ダウンロード先ディレクトリへ
  ダウンロードします (サブフォルダの構成は維持されます)。

必須:
  -b, --bucket <バケット名>       S3 バケット名 (s3:// は付けても可)
  -p, --prefix <フォルダ>         ダウンロード対象のフォルダ (例: data/2026/10)
                                  バケット全体を対象にする場合は / を指定
  -d, --dest <ディレクトリ>       ダウンロード先 (存在しない場合は作成)

AWS:
      --profile <プロファイル>    使用する AWS プロファイル
      --region <リージョン>       使用するリージョン

権限不足時の動作 (スイッチバック):
      --switchback-mode <モード>  warn : スイッチバックを促す警告を出して終了 (既定)
                                  auto : スイッチバック用シェルを source して続行
      --switchback-script <パス>  スイッチバック用シェルのパス (auto の場合は必須)
      --switchback-args <引数>    スイッチバック用シェルに渡す引数 (空白区切り)

その他:
      --dryrun                    ダウンロードせず、対象ファイルの表示のみ行う
  -h, --help                      このヘルプを表示する

環境変数 (対応するオプションが未指定の場合に使用):
  S3DL_SWITCHBACK_MODE            --switchback-mode の既定値
  S3DL_SWITCHBACK_SCRIPT          --switchback-script の既定値
  S3DL_SWITCHBACK_ARGS            --switchback-args の既定値

終了コード:
  ${S3DL_EXIT_OK}  正常終了
  ${S3DL_EXIT_USAGE}  引数エラー / 前提条件エラー
  ${S3DL_EXIT_DENIED}  権限不足 (スイッチバックが必要 / スイッチバック後も権限不足)
  ${S3DL_EXIT_TARGET}  バケット・フォルダが存在しない、またはファイルが無い
  ${S3DL_EXIT_AWS}  AWS CLI のその他のエラー (通信エラー等)
  ${S3DL_EXIT_DOWNLOAD}  ダウンロード失敗

例:
  # 権限不足の場合は警告を出して終了する
  ${S3DL_PROG} -b my-bucket -p data/2026/10 -d /work/download

  # 権限不足の場合は自動でスイッチバックして続行する
  ${S3DL_PROG} -b my-bucket -p data/2026/10 -d /work/download \\
      --switchback-mode auto --switchback-script /opt/common/switchback.sh
EOF
}

s3dl_log() {
    local level=$1
    shift
    printf '%s [%-5s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >&2
}

s3dl_info() { s3dl_log INFO "$@"; }
s3dl_warn() { s3dl_log WARN "$@"; }
s3dl_error() { s3dl_log ERROR "$@"; }

# エラーを出力して終了する
#   $1: 終了コード, $2...: メッセージ
s3dl_die() {
    local code=$1
    shift
    s3dl_error "$@"
    exit "$code"
}

s3dl_usage_error() {
    s3dl_error "$1"
    echo "使い方は ${S3DL_PROG} -h を参照してください" >&2
    exit "$S3DL_EXIT_USAGE"
}

# 終了時の後処理
s3dl_on_exit() {
    local rc=$?
    # スイッチバック用シェルの中で exit された場合は、ダウンロードせずに終わっているため権限不足として扱う
    if (( S3DL_IN_SWITCHBACK )) && (( rc != 130 && rc != 143 )); then
        s3dl_error "スイッチバック用シェルの中で exit (終了コード: ${rc}) が実行されたため、処理を中断しました"
        rc=$S3DL_EXIT_DENIED
    fi
    if [[ -n $S3DL_TMPDIR && -d $S3DL_TMPDIR ]]; then
        rm -rf -- "$S3DL_TMPDIR"
    fi
    exit "$rc"
}

s3dl_set_traps() {
    trap s3dl_on_exit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

# オプションの値が指定されているか確認する
#   $1: オプション名, $2: 値
s3dl_require_value() {
    if (( $# < 2 )); then
        s3dl_usage_error "オプション $1 には値が必要です"
    fi
}

s3dl_parse_args() {
    while (( $# > 0 )); do
        case $1 in
            -b|--bucket)         s3dl_require_value "$@"; S3DL_BUCKET=$2; shift 2 ;;
            -p|--prefix)         s3dl_require_value "$@"; S3DL_PREFIX=$2; shift 2 ;;
            -d|--dest)           s3dl_require_value "$@"; S3DL_DEST=$2; shift 2 ;;
            --profile)           s3dl_require_value "$@"; S3DL_PROFILE=$2; shift 2 ;;
            --region)            s3dl_require_value "$@"; S3DL_REGION=$2; shift 2 ;;
            --switchback-mode)   s3dl_require_value "$@"; S3DL_SWITCHBACK_MODE=$2; shift 2 ;;
            --switchback-script) s3dl_require_value "$@"; S3DL_SWITCHBACK_SCRIPT=$2; shift 2 ;;
            --switchback-args)   s3dl_require_value "$@"; S3DL_SWITCHBACK_ARGS=$2; shift 2 ;;
            --dryrun)            S3DL_DRYRUN=1; shift ;;
            -h|--help)           s3dl_usage; exit "$S3DL_EXIT_OK" ;;
            *)                   s3dl_usage_error "不明なオプションです: $1" ;;
        esac
    done
}

s3dl_validate_args() {
    if [[ -z $S3DL_BUCKET ]]; then
        s3dl_usage_error "-b (バケット名) を指定してください"
    fi
    if [[ -z $S3DL_PREFIX ]]; then
        s3dl_usage_error "-p (フォルダ) を指定してください (バケット全体の場合は / を指定)"
    fi
    if [[ -z $S3DL_DEST ]]; then
        s3dl_usage_error "-d (ダウンロード先) を指定してください"
    fi

    S3DL_BUCKET=${S3DL_BUCKET#s3://}
    S3DL_BUCKET=${S3DL_BUCKET%/}
    if [[ -z $S3DL_BUCKET || $S3DL_BUCKET == */* ]]; then
        s3dl_usage_error "バケット名が不正です: ${S3DL_BUCKET} (フォルダは -p で指定してください)"
    fi

    # 先頭の / を除き、末尾を / で終わらせる (data/2026/1 が data/2026/10/ に一致しないように)
    while [[ $S3DL_PREFIX == /* ]]; do
        S3DL_PREFIX=${S3DL_PREFIX#/}
    done
    if [[ -n $S3DL_PREFIX && $S3DL_PREFIX != */ ]]; then
        S3DL_PREFIX+=/
    fi

    S3DL_DEST=$(realpath -m -- "$S3DL_DEST")
    if [[ -e $S3DL_DEST && ! -d $S3DL_DEST ]]; then
        s3dl_usage_error "ダウンロード先がディレクトリではありません: ${S3DL_DEST}"
    fi

    case $S3DL_SWITCHBACK_MODE in
        warn|auto) ;;
        *) s3dl_usage_error "--switchback-mode には warn または auto を指定してください: ${S3DL_SWITCHBACK_MODE}" ;;
    esac
    if [[ $S3DL_SWITCHBACK_MODE == auto ]]; then
        if [[ -z $S3DL_SWITCHBACK_SCRIPT ]]; then
            s3dl_usage_error "--switchback-mode auto の場合は --switchback-script (または環境変数 S3DL_SWITCHBACK_SCRIPT) を指定してください"
        fi
        if [[ ! -f $S3DL_SWITCHBACK_SCRIPT || ! -r $S3DL_SWITCHBACK_SCRIPT ]]; then
            s3dl_usage_error "スイッチバック用シェルが存在しないか、読み取れません: ${S3DL_SWITCHBACK_SCRIPT}"
        fi
        S3DL_SWITCHBACK_SCRIPT=$(realpath -- "$S3DL_SWITCHBACK_SCRIPT")
    fi
    read -r -a S3DL_SWITCHBACK_ARGV <<<"$S3DL_SWITCHBACK_ARGS"
}

# 前提コマンドの確認、ダウンロード先・一時ディレクトリの作成
s3dl_prepare() {
    if ! command -v aws >/dev/null 2>&1; then
        s3dl_die "$S3DL_EXIT_USAGE" "aws コマンドが見つかりません。AWS CLI v2 をインストールしてください"
    fi
    # aws の出力がページャーで止まらないようにする
    export AWS_PAGER=""
    # --profile オプションではなく環境変数で渡す。
    # (--profile を付けると、スイッチバック用シェルが環境変数で設定した認証情報より優先されてしまうため)
    if [[ -n $S3DL_PROFILE ]]; then
        export AWS_PROFILE=$S3DL_PROFILE
    fi
    if [[ -n $S3DL_REGION ]]; then
        S3DL_AWS_OPTS+=(--region "$S3DL_REGION")
    fi

    if (( ! S3DL_DRYRUN )); then
        mkdir -p -- "$S3DL_DEST" || s3dl_die "$S3DL_EXIT_USAGE" "ダウンロード先を作成できません: ${S3DL_DEST}"
        if [[ ! -w $S3DL_DEST ]]; then
            s3dl_die "$S3DL_EXIT_USAGE" "ダウンロード先に書き込み権限がありません: ${S3DL_DEST}"
        fi
    fi

    S3DL_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/s3dl.XXXXXX")
}

# aws コマンドを実行し、標準出力を S3DL_AWS_OUT、標準エラー出力を S3DL_AWS_ERR に格納する
s3dl_aws_capture() {
    local rc=0
    S3DL_AWS_OUT=$(aws "${S3DL_AWS_OPTS[@]}" "$@" 2>"${S3DL_TMPDIR}/aws_stderr") || rc=$?
    S3DL_AWS_ERR=$(<"${S3DL_TMPDIR}/aws_stderr")
    return "$rc"
}

# AWS CLI のエラーメッセージから原因を分類し、S3DL_CHK_* を標準出力に返す
s3dl_classify_error() {
    case $1 in
        *AccessDenied*|*AllAccessDisabled*|*"(403)"*|*Forbidden*|\
        *UnauthorizedOperation*|*"is not authorized to perform"*|\
        *ExpiredToken*|*InvalidAccessKeyId*|*InvalidClientTokenId*|*InvalidToken*|\
        *SignatureDoesNotMatch*|*"Unable to locate credentials"*|\
        *"Error loading SSO Token"*|*"Error when retrieving token from sso"*|*"has expired"*)
            echo "$S3DL_CHK_DENIED"
            ;;
        *NoSuchBucket*|*NoSuchKey*|*"(404)"*)
            echo "$S3DL_CHK_NOTFOUND"
            ;;
        *)
            echo "$S3DL_CHK_ERROR"
            ;;
    esac
}

# 現在の認証情報で対象 S3 を操作できるか確認する
#   認証情報 (sts)、一覧取得 (s3:ListBucket)、ファイル参照 (s3:GetObject) の順に確認する。
#   戻り値: S3DL_CHK_*
#   失敗時は S3DL_CHECK_MSG と S3DL_AWS_ERR に内容を設定する。
s3dl_check_access() {
    local out count first_key

    S3DL_CALLER_ARN="(取得できませんでした)"
    if ! s3dl_aws_capture sts get-caller-identity --query Arn --output text; then
        S3DL_CHECK_MSG="認証情報の確認 (sts get-caller-identity) に失敗しました"
        return "$(s3dl_classify_error "$S3DL_AWS_ERR")"
    fi
    S3DL_CALLER_ARN=$S3DL_AWS_OUT
    s3dl_info "実行主体: ${S3DL_CALLER_ARN}"

    if ! s3dl_aws_capture s3api list-objects-v2 --bucket "$S3DL_BUCKET" --prefix "$S3DL_PREFIX" \
            --max-items 1 --page-size 1 --query '[length(Contents || `[]`), Contents[0].Key]' --output text; then
        S3DL_CHECK_MSG="s3://${S3DL_BUCKET}/${S3DL_PREFIX} の一覧取得 (s3:ListBucket) に失敗しました"
        return "$(s3dl_classify_error "$S3DL_AWS_ERR")"
    fi
    # 出力形式: "<件数>\t<先頭のキー>"
    out=${S3DL_AWS_OUT%%$'\n'*}
    count=${out%%$'\t'*}
    first_key=${out#*$'\t'}
    if [[ $count == 0 ]]; then
        S3DL_CHECK_MSG="s3://${S3DL_BUCKET}/${S3DL_PREFIX} 配下にファイルがありません"
        S3DL_AWS_ERR=""
        return "$S3DL_CHK_EMPTY"
    fi

    if ! s3dl_aws_capture s3api head-object --bucket "$S3DL_BUCKET" --key "$first_key"; then
        S3DL_CHECK_MSG="s3://${S3DL_BUCKET}/${first_key} の参照 (s3:GetObject) に失敗しました"
        return "$(s3dl_classify_error "$S3DL_AWS_ERR")"
    fi

    return "$S3DL_CHK_OK"
}

# アクセス権限の確認で失敗した内容を、指定したレベルで出力する
s3dl_report_check_failure() {
    local level=$1 line
    s3dl_log "$level" "$S3DL_CHECK_MSG"
    while IFS= read -r line; do
        if [[ $line == *[![:space:]]* ]]; then
            s3dl_log "$level" "  ${line}"
        fi
    done <<<"$S3DL_AWS_ERR"
}

# スイッチバックを促す警告を出力する
s3dl_warn_switchback_required() {
    s3dl_warn "現在の認証情報では s3://${S3DL_BUCKET}/${S3DL_PREFIX} を操作できません (実行主体: ${S3DL_CALLER_ARN})"
    s3dl_warn "CodeCommit 用のロールに切り替えたままになっていないか確認し、スイッチバックしてから再実行してください"
    if [[ -n $S3DL_SWITCHBACK_SCRIPT ]]; then
        s3dl_warn "  スイッチバック方法: source ${S3DL_SWITCHBACK_SCRIPT}${S3DL_SWITCHBACK_ARGS:+ ${S3DL_SWITCHBACK_ARGS}}"
    fi
    s3dl_warn "自動でスイッチバックして続行する場合は --switchback-mode auto を指定してください"
}

# 対象 S3 へのアクセス権限を確認する
#   権限不足の場合、warn モードでは警告を出して終了する。
#   auto モードでは S3DL_NEED_SWITCHBACK=1 を設定して戻る (スイッチバックはトップレベルで行う)。
#   スイッチバック後の再確認でも権限不足の場合はエラー終了する。
s3dl_ensure_access() {
    local rc=0

    s3dl_info "アクセス権限を確認しています: s3://${S3DL_BUCKET}/${S3DL_PREFIX}"
    s3dl_check_access || rc=$?

    case $rc in
        "$S3DL_CHK_OK")
            s3dl_info "アクセス権限を確認しました"
            return 0
            ;;
        "$S3DL_CHK_DENIED")
            if (( S3DL_SWITCHBACK_DONE )); then
                s3dl_report_check_failure ERROR
                s3dl_die "$S3DL_EXIT_DENIED" "スイッチバック後も権限が不足しています (実行主体: ${S3DL_CALLER_ARN})。スイッチバック用シェルの内容と IAM 権限を確認してください"
            fi
            if [[ $S3DL_SWITCHBACK_MODE == auto ]]; then
                s3dl_report_check_failure WARN
                s3dl_warn "現在の認証情報では権限が不足しているため、自動でスイッチバックします"
                S3DL_NEED_SWITCHBACK=1
                return 0
            fi
            s3dl_report_check_failure ERROR
            s3dl_warn_switchback_required
            exit "$S3DL_EXIT_DENIED"
            ;;
        "$S3DL_CHK_NOTFOUND")
            s3dl_report_check_failure ERROR
            s3dl_die "$S3DL_EXIT_TARGET" "バケットまたはファイルが存在しません。バケット名とフォルダを確認してください"
            ;;
        "$S3DL_CHK_EMPTY")
            s3dl_report_check_failure ERROR
            s3dl_die "$S3DL_EXIT_TARGET" "ダウンロード対象のファイルがありません。フォルダを確認してください"
            ;;
        *)
            s3dl_report_check_failure ERROR
            s3dl_die "$S3DL_EXIT_AWS" "AWS へのアクセスでエラーが発生しました。ネットワークや AWS CLI の設定を確認してください"
            ;;
    esac
}

# スイッチバック用シェルを source する前に、本スクリプトの実行環境を退避する
s3dl_switchback_begin() {
    s3dl_info "スイッチバックを実行します: source ${S3DL_SWITCHBACK_SCRIPT}${S3DL_SWITCHBACK_ARGS:+ ${S3DL_SWITCHBACK_ARGS}}"
    S3DL_SAVED_OPTS=$(set +o)
    S3DL_SAVED_IFS=$IFS
    S3DL_SAVED_PWD=$PWD
    # スイッチバック用シェルは set -e / -u / pipefail を前提にしていない可能性があるため一時的に解除する
    set +o errexit +o nounset +o pipefail
    S3DL_IN_SWITCHBACK=1
}

# スイッチバック用シェルの source 後に、本スクリプトの実行環境を復元する
s3dl_switchback_end() {
    S3DL_IN_SWITCHBACK=0
    eval "$S3DL_SAVED_OPTS"
    IFS=$S3DL_SAVED_IFS
    cd -- "$S3DL_SAVED_PWD" || s3dl_die "$S3DL_EXIT_USAGE" "作業ディレクトリに戻れません: ${S3DL_SAVED_PWD}"
    # スイッチバック用シェルが trap を上書きしている場合に備えて再設定する
    s3dl_set_traps
    S3DL_SWITCHBACK_DONE=1

    if (( S3DL_SWITCHBACK_RC != 0 )); then
        s3dl_warn "スイッチバック用シェルが終了コード ${S3DL_SWITCHBACK_RC} を返しました"
    fi
    s3dl_info "スイッチバック後のアクセス権限を再確認します"
}

s3dl_download() {
    local src="s3://${S3DL_BUCKET}/${S3DL_PREFIX}"
    local -a cp_opts=(--recursive)
    local rc=0

    # ログファイル等へリダイレクトされている場合は進捗表示を出さない
    if [[ ! -t 1 ]]; then
        cp_opts+=(--no-progress)
    fi
    if (( S3DL_DRYRUN )); then
        cp_opts+=(--dryrun)
        s3dl_info "ドライランのため、ダウンロード対象の表示のみ行います"
    fi

    s3dl_info "ダウンロードを開始します: ${src} -> ${S3DL_DEST}/"
    aws "${S3DL_AWS_OPTS[@]}" s3 cp "$src" "${S3DL_DEST}/" "${cp_opts[@]}" || rc=$?

    case $rc in
        0)
            s3dl_info "ダウンロードが完了しました: ${S3DL_DEST}"
            ;;
        2)
            s3dl_die "$S3DL_EXIT_DOWNLOAD" "一部のファイルがスキップされました (aws s3 cp 終了コード: 2)。Glacier 等、そのままでは取得できないファイルが含まれていないか確認してください"
            ;;
        *)
            s3dl_die "$S3DL_EXIT_DOWNLOAD" "ダウンロードに失敗しました (aws s3 cp 終了コード: ${rc})"
            ;;
    esac
}

s3dl_set_traps
s3dl_parse_args "$@"
s3dl_validate_args
s3dl_prepare
s3dl_ensure_access

if (( S3DL_NEED_SWITCHBACK )); then
    s3dl_switchback_begin
    # 関数内で source すると、スイッチバック用シェル内の declare / typeset で設定した変数が
    # 関数のローカル変数になって認証情報が引き継がれないため、トップレベルで source する。
    # また、引数なしで source すると本スクリプトの引数がそのまま渡るため、位置パラメータを置き換える。
    set -- "${S3DL_SWITCHBACK_ARGV[@]}"
    # shellcheck source=/dev/null
    source "$S3DL_SWITCHBACK_SCRIPT" || S3DL_SWITCHBACK_RC=$?
    s3dl_switchback_end
    s3dl_ensure_access
fi

s3dl_download
