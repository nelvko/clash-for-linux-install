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

export CLASHCTL_COLOR=never CLASHCTL_KERNEL=mihomo
export CLASHCTL_HOME="$WORK_DIR/home"
export BIN_KERNEL="$CLASHCTL_HOME/bin/mihomo/mihomo"

_ui_fail() { printf '[FAIL] %s\n' "$*" >&2; }

# shellcheck source=../scripts/cmd/on.sh
. "$REPO_DIR/scripts/cmd/on.sh"
# shellcheck source=../scripts/cmd/status.sh
. "$REPO_DIR/scripts/cmd/status.sh"

# ── 空壳态：内核二进制缺失 → 指路 clashctl install，不触碰服务 ──
service_touched=0
service_is_active() { service_touched=1; return 1; }
service_start() { service_touched=1; return 1; }
service_status() { service_touched=1; }

stderr="$WORK_DIR/on.stderr"
rc=0
clashon >"$WORK_DIR/on.stdout" 2>"$stderr" || rc=$?
assert_eq 1 "$rc" 'clashctl on fails on empty shell'
assert_contains "$stderr" '代理内核未安装' 'on explains the missing kernel'
assert_contains "$stderr" '请先运行: clashctl install' 'on guides to clashctl install'
assert_eq 0 "$service_touched" 'on does not touch service machinery on empty shell'

: >"$stderr"
rc=0
clashstatus >"$WORK_DIR/status.stdout" 2>"$stderr" || rc=$?
assert_eq 1 "$rc" 'clashctl status fails on empty shell'
assert_contains "$stderr" '请先运行: clashctl install' 'status guides to clashctl install'

# ── 内核就位：守卫放行（进入正常启动路径）──
mkdir -p -- "$(dirname -- "$BIN_KERNEL")"
printf '#!/bin/sh\n' >"$BIN_KERNEL"
chmod 0755 -- "$BIN_KERNEL"
started=0
service_is_active() { return 1; }
service_start() { started=1; return 0; }
_detect_proxy_port() { return 0; }

rc=0
clashon -s >"$WORK_DIR/provisioned.stdout" 2>"$WORK_DIR/provisioned.stderr" || rc=$?
assert_eq 1 "$started" 'guard passes once the kernel binary exists'

printf '%s\n' 'install-empty-shell: ok'
