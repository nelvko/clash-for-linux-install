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

assert_stream() {
    local file=$1 expected=$2 description=$3 expected_file="$WORK_DIR/expected"
    printf '%s' "$expected" >"$expected_file"
    cmp -s -- "$expected_file" "$file" || fail "$description"
}

assert_empty() {
    [ ! -s "$1" ] || fail "$2"
}

assert_contains() {
    grep -Fqs -- "$2" "$1" || fail "$3: missing [$2]"
}

assert_not_contains() {
    if grep -Fqs -- "$2" "$1"; then
        fail "$3: unexpectedly found [$2]"
    fi
}

export CLASHCTL_HOME="$WORK_DIR/home"
export CLASHCTL_KERNEL=mihomo
export CLASHCTL_COLOR=never
export TERM=dumb
mkdir -p -- "$CLASHCTL_HOME"

# shellcheck source=../scripts/lib/common.sh
. "$REPO_DIR/scripts/lib/common.sh"
# shellcheck source=../scripts/lib/config.sh
. "$REPO_DIR/scripts/lib/config.sh"

stdout_file="$WORK_DIR/stdout"
stderr_file="$WORK_DIR/stderr"

: >"$stdout_file"
: >"$stderr_file"
_ui_info_out '正在处理' >"$stdout_file" 2>"$stderr_file"
assert_stream "$stdout_file" $'[INFO] 正在处理\n' '_ui_info_out stdout content'
assert_empty "$stderr_file" '_ui_info_out wrote to stderr'

: >"$stdout_file"
: >"$stderr_file"
_ui_ok_out '处理完成' >"$stdout_file" 2>"$stderr_file"
assert_stream "$stdout_file" $'[ OK ] 处理完成\n' '_ui_ok_out stdout content'
assert_empty "$stderr_file" '_ui_ok_out wrote to stderr'

: >"$stdout_file"
: >"$stderr_file"
rc=0
_ui_fail '处理失败' >"$stdout_file" 2>"$stderr_file" || rc=$?
assert_eq 1 "$rc" '_ui_fail return code'
assert_empty "$stdout_file" '_ui_fail wrote to stdout'
assert_stream "$stderr_file" $'[ERROR] 处理失败\n' '_ui_fail stderr content'

: >"$stdout_file"
: >"$stderr_file"
rc=0
_ui_warn_fail '已降级处理' >"$stdout_file" 2>"$stderr_file" || rc=$?
assert_eq 1 "$rc" '_ui_warn_fail return code'
assert_empty "$stdout_file" '_ui_warn_fail wrote to stdout'
assert_stream "$stderr_file" $'[WARN] 已降级处理\n' '_ui_warn_fail stderr content'

: >"$stdout_file"
: >"$stderr_file"
_ui_prompt '请选择：' >"$stdout_file" 2>"$stderr_file"
assert_empty "$stdout_file" '_ui_prompt wrote to stdout'
assert_stream "$stderr_file" '[ ? ] 请选择： ' '_ui_prompt must not append a newline'

export BIN_YQ=fake_yq
export CLASH_CONFIG_RUNTIME="$WORK_DIR/runtime.yaml"
fake_yq() {
    printf '%s\n' Meta
}
TUN_PRESENT=1
ip() {
    [ "$TUN_PRESENT" -eq 1 ] && printf '%s\n' '7: Meta: <POINTOPOINT,UP>'
}

: >"$stdout_file"
: >"$stderr_file"
tunstatus >"$stdout_file" 2>"$stderr_file"
assert_stream "$stdout_file" $'[ OK ] Tun 状态：启用\n' 'active Tun status level'
assert_empty "$stderr_file" 'active Tun status wrote to stderr'

TUN_PRESENT=0
: >"$stdout_file"
: >"$stderr_file"
rc=0
tunstatus >"$stdout_file" 2>"$stderr_file" || rc=$?
assert_eq 1 "$rc" 'inactive Tun status return code'
assert_stream "$stdout_file" $'[INFO] Tun 状态：关闭\n' 'inactive Tun status level'
assert_empty "$stderr_file" 'inactive Tun status wrote to stderr'

command -v script >/dev/null 2>&1 || fail 'util-linux script is required'
preflight_probe="$WORK_DIR/preflight-probe.sh"
cat >"$preflight_probe" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

REPO_DIR=$1
CASE_DIR=$2
VERBOSE=$3
mkdir -p -- "$CASE_DIR/home" "$CASE_DIR/download"
export CLASHCTL_SRC=$REPO_DIR
export CLASHCTL_HOME="$CASE_DIR/home"
export CLASHCTL_KERNEL=mihomo
export CLASHCTL_COLOR=never
export CLASHCTL_DOWNLOAD_TIMEOUT=60
export _INSTALL_VERBOSE=$VERBOSE

# shellcheck source=../scripts/preflight.sh
. "$REPO_DIR/scripts/preflight.sh"

_archive_is_valid() {
    [ -s "$1" ]
}

curl() {
    local arg output= expect_output=0
    : >"$CASE_DIR/curl-args"
    for arg in "$@"; do
        printf '%s\n' "$arg" >>"$CASE_DIR/curl-args"
        if [ "$expect_output" -eq 1 ]; then
            output=$arg
            expect_output=0
        elif [ "$arg" = --output ]; then
            expect_output=1
        fi
    done
    [ -n "$output" ] || return 1
    printf 'archive\n' >"$output"
}

_download_archive component https://example.invalid/component.tar.gz \
    "$CASE_DIR/download/component.tar.gz"
EOF
chmod 0700 "$preflight_probe"

run_preflight_probe() {
    local label=$1 verbose=$2 case_dir="$WORK_DIR/$1" command output rc=0
    mkdir -p -- "$case_dir"
    printf -v command '%q ' bash "$preflight_probe" "$REPO_DIR" "$case_dir" "$verbose"
    output="$case_dir/terminal"
    script -q -e -E never -c "$command" /dev/null </dev/null >"$output" 2>&1 || rc=$?
    assert_eq 0 "$rc" "preflight progress probe $label"
}

run_preflight_probe quiet ''
assert_contains "$WORK_DIR/quiet/curl-args" --silent 'quiet dependency download'
assert_not_contains "$WORK_DIR/quiet/curl-args" --progress-bar 'quiet dependency download'

run_preflight_probe verbose 1
assert_contains "$WORK_DIR/verbose/curl-args" --progress-bar 'verbose dependency download'
assert_not_contains "$WORK_DIR/verbose/curl-args" --silent 'verbose dependency download'

printf 'common-ui: ok\n'
