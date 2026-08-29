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

assert_contains() {
    local file=$1 expected=$2 description=$3
    grep -Fqs -- "$expected" "$file" || fail "$description: missing [$expected]"
}

assert_not_contains() {
    local file=$1 unexpected=$2 description=$3
    if grep -Fqs -- "$unexpected" "$file"; then
        fail "$description: unexpectedly found [$unexpected]"
    fi
}

export CLASHCTL_KERNEL=mihomo
mkdir -p -- "$WORK_DIR/resources"
export CLASH_RESOURCES_DIR="$WORK_DIR/resources"
# shellcheck source=../scripts/cmd/ui.sh
. "$REPO_DIR/scripts/cmd/ui.sh"

_detect_ext_addr() {
    EXT_IP=127.0.0.1
    EXT_PORT=9090
    export EXT_IP EXT_PORT
}
_ui_info() { printf '[INFO] %s\n' "$*" >&2; }
_ui_step() { printf '[STEP] %s\n' "$*" >&2; }
_ui_ok() { printf '[ OK ] %s\n' "$*" >&2; }
_ui_error() { printf '[ERROR] %s\n' "$*" >&2; }
_ui_blank() { printf '\n' >&2; }
_ui_header() { printf '[INFO] %s\n' "$*" >&2; }
_ui_detail() { printf '        %s: %s\n' "$1" "$2" >&2; }
curl() { return 1; }
_ci_provision() {
    PROVISIONED=$1
    return 0
}
sleep() { :; }

ACTIVE_CHECKS=0
READY_AT=999
START_RESULT=0
service_is_active() {
    ACTIVE_CHECKS=$((ACTIVE_CHECKS + 1))
    [ "$ACTIVE_CHECKS" -ge "$READY_AT" ]
}
service_start() { return "$START_RESULT"; }

stderr="$WORK_DIR/not-active.stderr"
rc=0
clashui >"$WORK_DIR/not-active.stdout" 2>"$stderr" || rc=$?
[ "$rc" -eq 1 ] || fail "inactive service: expected rc 1, got $rc"
assert_contains "$stderr" '服务未能进入运行状态' 'inactive service reports the verified state'
assert_not_contains "$stderr" '[ OK ] mihomo 服务已启动' 'inactive service is not reported as started'

ACTIVE_CHECKS=0
READY_AT=3
stderr="$WORK_DIR/delayed.stderr"
clashui >"$WORK_DIR/delayed.stdout" 2>"$stderr" || fail 'delayed service readiness failed'
assert_contains "$stderr" '[ OK ] mihomo 服务已启动' 'readiness confirmation precedes success'
assert_not_contains "$stderr" '[ERROR]' 'ready service is not reported as failed'

printf 'ui-startup: ok\n'
