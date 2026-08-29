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
    local file=$1 expected=$2 description=$3
    grep -Fqs -- "$expected" "$file" ||
        fail "$description: missing [$expected]"
}

assert_not_contains() {
    local file=$1 unexpected=$2 description=$3
    if grep -Fqs -- "$unexpected" "$file"; then
        fail "$description: unexpectedly found [$unexpected]"
    fi
}

export CLASHCTL_COLOR=never CLASHCTL_KERNEL=mihomo
CLASHCTL_HOME="$WORK_DIR/home"
export CLASHCTL_HOME
mkdir -p -- "$CLASHCTL_HOME"
# clashinstall 编排入口在标记检查后会重导出 BIN_KERNEL；契约测试提供最小变量集
export BIN_BASE_DIR="$CLASHCTL_HOME/bin"

# 最小 lib 桩（cmd/install.sh 仅在调用时用到这些；见契约测试惯例 cmd-ui-contract）
_install_private_locals() {
    local variable
    for variable in "$@"; do
        declare -g +x "$variable"
        export -n "${variable?}"
    done
}
_install_has_control_chars() {
    local value=$1 cleaned
    cleaned=$(printf '%s' "$value" | LC_ALL=C tr -d '\001-\037\177')
    [ "$cleaned" != "$value" ]
}
_ui_error() { printf '[ERROR] %s\n' "$*" >&2; }
_ui_info() { printf '[INFO] %s\n' "$*" >&2; }

# shellcheck source=../../scripts/cmd/install.sh
. "$REPO_DIR/scripts/cmd/install.sh"

stdout_file="$WORK_DIR/stdout"
stderr_file="$WORK_DIR/stderr"

# ── 帮助 ──
: >"$stdout_file"
clashinstall --help >"$stdout_file" 2>"$stderr_file" || fail 'help failed'
assert_contains "$stdout_file" 'clashctl install' 'help names the command'
assert_contains "$stdout_file" '--subscription-file' 'help documents subscription file'
assert_contains "$stdout_file" '--take-over-service' 'help documents takeover consent'

# ── 未知参数：拒绝且 usage 走 stderr ──
: >"$stdout_file"
: >"$stderr_file"
rc=0
clashinstall --definitely-unknown >"$stdout_file" 2>"$stderr_file" || rc=$?
assert_eq 1 "$rc" 'unknown option fails'
[ ! -s "$stdout_file" ] || fail 'unknown option polluted stdout'
assert_contains "$stderr_file" 'Usage:' 'unknown option writes usage to stderr'

# ── 控制字符参数：拒绝且回显安全 ──
: >"$stderr_file"
rc=0
clashinstall $'--branch=stable\033[31mCONTROL' >"$stdout_file" 2>"$stderr_file" || rc=$?
assert_eq 1 "$rc" 'control characters in arguments are rejected'
assert_not_contains "$stderr_file" 'stable' 'rejected input is not echoed'

# ── 非法内核：拒绝 ──
rc=0
clashinstall sing-box >"$stdout_file" 2>"$stderr_file" || rc=$?
assert_eq 1 "$rc" 'unsupported kernel is rejected'
assert_contains "$stderr_file" '未知参数' 'unsupported kernel falls into rejection path'

# ── 已完成初始化 + 无参：幂等成功 ──
printf 'CLASHCTL_KERNEL=mihomo\n' >"$CLASHCTL_HOME/.env"
: >"$stderr_file"
rc=0
clashinstall >"$stdout_file" 2>"$stderr_file" || rc=$?
assert_eq 0 "$rc" 'completed install without args is idempotent success'
assert_contains "$stderr_file" '已完成初始化' 'idempotent path reports completion'
assert_contains "$stderr_file" '当前内核: mihomo' 'idempotent path reports active kernel'

# ── 已完成初始化 + 带内核参数：进入安装/切换路径（文件探针跨子 shell）─
# clashinstall 是子 shell 函数，探针必须用文件（变量不会回传）
probe_file="$WORK_DIR/entered"
operation_lock_acquire() { printf 'x' >>"$probe_file"; return 1; }
: >"$probe_file"
rc=0
CLASHCTL_UPDATE_BRANCH=master clashinstall clash >"$stdout_file" 2>"$stderr_file" || rc=$?
[ -s "$probe_file" ] || fail 'kernel argument enters provisioning flow despite completed install'
operation_lock_acquire() { return 0; }
rm -f -- "$CLASHCTL_HOME/.env"

# ── 空壳（无 .env）+ 无参：进入编排（默认 mihomo）──
operation_lock_acquire() { printf 'x' >>"$probe_file"; return 1; }
: >"$probe_file"
rc=0
CLASHCTL_UPDATE_BRANCH=master clashinstall >"$stdout_file" 2>"$stderr_file" || rc=$?
[ -s "$probe_file" ] || fail 'empty shell without args enters provisioning'
operation_lock_acquire() { return 0; }

# ── 锁随子 shell 释放：交互 shell 内跑完 clashctl install 不得驻留锁 ──
# 用真 flock 探针验证（clashinstall 在拿锁后因 preflight 缺失而失败退出，
# fd 应随子 shell 关闭；若改回普通函数体，探针将拿不到锁）
lock_probe="$WORK_DIR/oplock-probe"
: >"$lock_probe"
operation_lock_acquire() {
    exec 9>>"$lock_probe"
    flock -n 9
}
rc=0
CLASHCTL_UPDATE_BRANCH=master clashinstall >"$stdout_file" 2>"$stderr_file" || rc=$?
assert_eq 1 "$rc" 'probe run fails after lock acquisition (preflight missing)'
exec 9>>"$lock_probe"
if flock -n 9 2>/dev/null; then
    exec 9<&-
else
    exec 9<&-
    fail 'operation lock outlives clashctl install (interactive shell leak)'
fi

printf '%s\n' 'cmd-install-contract: ok'
