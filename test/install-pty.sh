#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_DIR=$(cd -- "$TEST_DIR/.." && pwd -P)
INSTALL_SH="$REPO_DIR/install.sh"
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
    local file=$1 expected=$2 description=$3
    grep -Fqs -- "$expected" "$file" ||
        fail "$description: missing [$expected]"
}

command -v timeout >/dev/null 2>&1 || fail 'timeout is required'
command -v script >/dev/null 2>&1 || fail 'util-linux script is required'

truncated_output="$WORK_DIR/truncated.out"
rc=0
sed -n '1,/trap .*_install_exit_guard/p' "$INSTALL_SH" |
    env -u CLASHCTL_INSTALL_SOURCE_ONLY bash >"$truncated_output" 2>&1 || rc=$?
assert_eq 1 "$rc" 'truncated stream fails before the exit guard function is defined'
assert_contains "$truncated_output" '安装脚本下载不完整' 'truncated stream explains the failure'

help_output="$WORK_DIR/help.out"
help_command="cat '$INSTALL_SH' | env -u CLASHCTL_INSTALL_SOURCE_ONLY bash -s -- --help"
rc=0
timeout 8 script -q -e -E never -c "$help_command" /dev/null \
    </dev/null >"$help_output" 2>&1 || rc=$?
assert_eq 0 "$rc" 'streamed --help finishes successfully'
assert_contains "$help_output" 'Usage:' 'streamed --help is fully parsed and executed'
assert_contains "$help_output" '--take-over-service' 'streamed --help is not truncated'

confirm_command="env -u CI CLASHCTL_INSTALL_SOURCE_ONLY=1 CLASHCTL_COLOR=never TERM=xterm BASH_ENV='$INSTALL_SH' bash -c '_ui_confirm \"continue?\"'"

run_confirm() {
    local label=$1 input=$2 expected_rc=$3
    local output="$WORK_DIR/confirm-$label.out" rc=0
    printf '%s' "$input" |
        timeout 8 script -q -e -E never -c "$confirm_command" /dev/null \
            >"$output" 2>&1 || rc=$?
    assert_eq "$expected_rc" "$rc" "_ui_confirm $label result"
    assert_contains "$output" '[ ? ] continue? [y/N]' "_ui_confirm $label prompt"
}

run_confirm yes $'y\n' 0
run_confirm no $'N\n' 1
run_confirm empty $'\n' 1

printf 'install-pty: ok\n'
