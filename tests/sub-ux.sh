#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_DIR=$(cd -- "$TEST_DIR/.." && pwd -P)
WORK_DIR=$(mktemp -d)
trap '/usr/bin/rm -rf -- "$WORK_DIR"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_eq() {
    local expected=$1 actual=$2 description=$3
    [ "$expected" = "$actual" ] ||
        fail "$description: expected [$expected], got [$actual]"
}

assert_contains() {
    local value=$1 expected=$2 description=$3
    case $value in
    *"$expected"*) ;;
    *) fail "$description: missing [$expected]" ;;
    esac
}

assert_not_contains() {
    local value=$1 unexpected=$2 description=$3
    case $value in
    *"$unexpected"*) fail "$description: found [$unexpected]" ;;
    *) ;;
    esac
}

_errorcat() {
    printf 'ERROR: %s\n' "${*: -1}" >&2
    return 1
}

_ui_fail() {
    printf 'ERROR: %s\n' "${*: -1}" >&2
    return 1
}

_ui_warn() {
    printf 'WARN: %s\n' "$*" >&2
    return 0
}

_ui_prompt() {
    printf 'PROMPT: %s ' "$*" >&2
    return 0
}

_ui_step() {
    printf 'STEP: %s\n' "$*" >&2
    return 0
}

_ui_info_out() {
    printf 'INFO: %s\n' "$*"
    return 0
}

_ui_ok_out() {
    printf 'OK: %s\n' "$*"
    return 0
}

_dispwidth() {
    printf '%s\n' "${#1}"
}

_pad() {
    printf '%-*s' "$2" "$1"
}

CLASH_PROFILES_META="$WORK_DIR/profiles.yaml"
CLASH_PROFILES_DIR="$WORK_DIR/profiles"
# shellcheck disable=SC2034  # consumed by functions in the sourced command module
CLASH_PROFILES_LOG="$WORK_DIR/profiles.log"
# shellcheck disable=SC2034  # consumed by functions in the sourced command module
CLASH_PROFILES_LOCK="$WORK_DIR/profiles.lock"
BIN_YQ=/usr/bin/yq
mkdir -p -- "$CLASH_PROFILES_DIR"

secret_url='https://user:password@example.test/sub?token=top-secret&client=demo'
cat >"$CLASH_PROFILES_META" <<EOF
use: demo
profiles:
  - name: demo
    path: $CLASH_PROFILES_DIR/demo.yaml
    url: $secret_url
    updated: "2026-08-26 12:00:00"
    userinfo: ""
EOF

# shellcheck source=../scripts/cmd/sub.sh
. "$REPO_DIR/scripts/cmd/sub.sh"

RUN_RC=0 RUN_STDOUT='' RUN_STDERR=''
run_cmd() {
    local label=$1
    shift
    set +e
    "$@" </dev/null >"$WORK_DIR/$label.stdout" 2>"$WORK_DIR/$label.stderr"
    RUN_RC=$?
    set -e
    RUN_STDOUT=$(<"$WORK_DIR/$label.stdout")
    RUN_STDERR=$(<"$WORK_DIR/$label.stderr")
}

run_cmd unknown clashsub definitely-not-a-command
assert_eq 2 "$RUN_RC" 'unknown subcommand exit code'
assert_eq '' "$RUN_STDOUT" 'unknown subcommand stdout'
assert_contains "$RUN_STDERR" '未知订阅命令' 'unknown subcommand diagnosis'

run_cmd missing_add sub_add
assert_eq 1 "$RUN_RC" 'non-TTY add without URL'
assert_eq '' "$RUN_STDOUT" 'non-TTY add prompt does not use stdout'
assert_contains "$RUN_STDERR" '非交互环境请传入 URL' 'non-TTY add guidance'

run_cmd missing_del _sub_del
assert_eq 1 "$RUN_RC" 'non-TTY del without name'
assert_contains "$RUN_STDERR" '显式指定' 'non-TTY del guidance'

run_cmd missing_use _sub_use
assert_eq 1 "$RUN_RC" 'non-TTY use without name'
assert_contains "$RUN_STDERR" '显式指定' 'non-TTY use guidance'

run_cmd missing_old_name _sub_rename
assert_eq 1 "$RUN_RC" 'non-TTY rename without old name'
assert_contains "$RUN_STDERR" '缺少原订阅名称' 'non-TTY rename old-name guidance'

run_cmd missing_new_name _sub_rename demo
assert_eq 1 "$RUN_RC" 'non-TTY rename without new name'
assert_contains "$RUN_STDERR" '缺少新订阅名称' 'non-TTY rename guidance'

run_cmd control_name _sub_validate_name $'bad\tname'
assert_eq 1 "$RUN_RC" 'control character in name'
assert_contains "$RUN_STDERR" '控制字符' 'control character name diagnosis'

run_cmd c1_control_name _sub_validate_name $'bad\u009b31m'
assert_eq 1 "$RUN_RC" 'C1 control character in name'
assert_contains "$RUN_STDERR" '控制字符' 'C1 control character name diagnosis'

run_cmd whitespace_name _sub_validate_name '   '
assert_eq 1 "$RUN_RC" 'all-whitespace name'
assert_contains "$RUN_STDERR" '全为空白' 'all-whitespace name diagnosis'

run_cmd edge_whitespace_name _sub_validate_name ' demo '
assert_eq 1 "$RUN_RC" 'edge whitespace in name'
assert_contains "$RUN_STDERR" '开头或结尾' 'edge whitespace name diagnosis'

run_cmd control_url _sub_validate_url $'https://example.test/sub\nheader: value'
assert_eq 1 "$RUN_RC" 'control character in URL'
assert_contains "$RUN_STDERR" '控制字符' 'control character URL diagnosis'
assert_not_contains "$RUN_STDERR" 'header: value' 'invalid URL is not echoed'

run_cmd control_url_add sub_add $'https://example.test/sub\rforged-header: value'
assert_eq 1 "$RUN_RC" 'add rejects a control character in URL'
assert_contains "$RUN_STDERR" '控制字符' 'add control character diagnosis'
assert_not_contains "$RUN_STDERR" 'forged-header' 'add does not echo invalid URL'

run_cmd unsupported_url _sub_validate_url 'ftp://example.test/sub'
assert_eq 1 "$RUN_RC" 'unsupported URL scheme'
assert_contains "$RUN_STDERR" '仅支持 http://' 'unsupported URL scheme diagnosis'

run_cmd file_url _sub_validate_url 'file:///tmp/subscription.yaml'
assert_eq 0 "$RUN_RC" 'file URL scheme remains supported'

run_cmd direct_profile_path _sub_validate_profile_path "$CLASH_PROFILES_DIR/demo.yaml"
assert_eq 0 "$RUN_RC" 'direct profile path'
run_cmd nested_profile_path _sub_validate_profile_path "$CLASH_PROFILES_DIR/nested/demo.yaml"
assert_eq 1 "$RUN_RC" 'nested profile path rejection'
run_cmd external_profile_path _sub_validate_profile_path "$WORK_DIR/outside.yaml"
assert_eq 1 "$RUN_RC" 'external profile path rejection'

assert_eq example.test \
    "$(_sub_default_name 'https://user:password@example.test:8443/sub?token=secret')" \
    'userinfo is excluded from a generated name'
assert_eq '2001:db8::1' \
    "$(_sub_default_name 'https://user:password@[2001:db8::1]:8443/sub')" \
    'IPv6 host is parsed without userinfo or port'

run_cmd list_default _sub_list
assert_eq 0 "$RUN_RC" 'default list exit code'
assert_not_contains "$RUN_STDOUT" "$secret_url" 'default list hides full URL'
assert_not_contains "$RUN_STDOUT" 'top-secret' 'default list hides URL token'

run_cmd list_explicit _sub_list --show-url
assert_eq 0 "$RUN_RC" 'explicit URL list exit code'
assert_contains "$RUN_STDOUT" "$secret_url" 'explicit URL list shows URL'

_sub_load
_sub_write_preview 0 "$WORK_DIR/preview"
preview=$(<"$WORK_DIR/preview")
assert_not_contains "$preview" "$secret_url" 'fzf preview hides full URL'
assert_not_contains "$preview" 'top-secret' 'fzf preview hides URL token'
assert_contains "$preview" '链接：已隐藏' 'fzf preview explains hidden URL'

working_yq=$BIN_YQ
BIN_YQ=/bin/false
run_cmd list_read_failure _sub_list
assert_eq 1 "$RUN_RC" 'list metadata read failure exit code'
assert_contains "$RUN_STDERR" '无法读取当前订阅状态' 'list metadata read failure diagnosis'
assert_not_contains "$RUN_STDOUT" '暂无订阅' 'list read failure is not reported as empty state'
BIN_YQ=$working_yq

"$BIN_YQ" -i '.use = ""' "$CLASH_PROFILES_META"
run_cmd missing_update _sub_update
assert_eq 1 "$RUN_RC" 'non-TTY update without current name'
assert_contains "$RUN_STDERR" '请指定订阅名称' 'non-TTY update guidance'

run_cmd bare_non_tty clashsub
assert_eq 0 "$RUN_RC" 'bare non-TTY subcommand lists subscriptions'
assert_not_contains "$RUN_STDOUT" "$secret_url" 'bare non-TTY list hides URL'

printf 'sub-ux: ok\n'
