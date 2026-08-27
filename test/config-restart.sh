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

# shellcheck source=../scripts/lib/config.sh
. "$REPO_DIR/scripts/lib/config.sh"

CLASHCTL_KERNEL=mihomo
export CLASHCTL_KERNEL

MERGE_RC=0
TUN_WAS_ACTIVE=0
TUN_ENABLED=0
TUN_QUERY_RC=0
TUN_READY=0
TUN_STATUS_CALLS=0
SERVICE_ACTIVE=1
STOP_RESULT_ACTIVE=0
START_RESULT_ACTIVE=1
START_RESULT_TUN_READY=1
STOP_CALLS=0
START_CALLS=0

_merge_config() { return "$MERGE_RC"; }
tunstatus() {
    TUN_STATUS_CALLS=$((TUN_STATUS_CALLS + 1))
    if [ "$TUN_STATUS_CALLS" -eq 1 ]; then
        [ "$TUN_WAS_ACTIVE" -eq 1 ]
    else
        [ "$TUN_READY" -eq 1 ]
    fi
}
_is_tun_enabled() {
    [ "$TUN_QUERY_RC" -eq 0 ] || return "$TUN_QUERY_RC"
    [ "$TUN_ENABLED" -eq 1 ]
}
service_is_active() { [ "$SERVICE_ACTIVE" -eq 1 ]; }
service_stop() {
    STOP_CALLS=$((STOP_CALLS + 1))
    SERVICE_ACTIVE=$STOP_RESULT_ACTIVE
    return "${STOP_RC:-0}"
}
service_sudo_stop() { service_stop; }
service_start() {
    START_CALLS=$((START_CALLS + 1))
    SERVICE_ACTIVE=$START_RESULT_ACTIVE
    return "${START_RC:-0}"
}
service_sudo_start() {
    START_CALLS=$((START_CALLS + 1))
    TUN_READY=$START_RESULT_TUN_READY
    SERVICE_ACTIVE=$START_RESULT_ACTIVE
    return "${START_RC:-0}"
}
sleep() { :; }
_ui_error() { printf '[ERROR] %s\n' "$*" >&2; }
_errorcat() { printf '[ERROR] %s\n' "$*" >&2; return 1; }

reset_case() {
    MERGE_RC=0
    TUN_WAS_ACTIVE=0
    TUN_ENABLED=0
    TUN_QUERY_RC=0
    TUN_READY=0
    TUN_STATUS_CALLS=0
    SERVICE_ACTIVE=1
    STOP_RESULT_ACTIVE=0
    START_RESULT_ACTIVE=1
    START_RESULT_TUN_READY=1
    STOP_RC=0
    START_RC=0
    STOP_CALLS=0
    START_CALLS=0
}

run_restart() {
    local label=$1
    RUN_RC=0
    _merge_config_restart >"$WORK_DIR/$label.stdout" 2>"$WORK_DIR/$label.stderr" || RUN_RC=$?
    RUN_STDERR="$WORK_DIR/$label.stderr"
}

reset_case
MERGE_RC=1
run_restart merge-failure
assert_eq 1 "$RUN_RC" 'merge failure exit code'
assert_eq 0 "$STOP_CALLS" 'merge failure does not stop the service'

reset_case
TUN_QUERY_RC=2
run_restart tun-query-failure
assert_eq 2 "$RUN_RC" 'Tun state query failure exit code'
assert_eq 0 "$STOP_CALLS" 'Tun state query failure does not stop the service'

reset_case
STOP_RC=73
STOP_RESULT_ACTIVE=1
run_restart stop-failure
assert_eq 2 "$RUN_RC" 'service stop failure exit code'
assert_eq 0 "$START_CALLS" 'service is not started after a failed stop'
assert_contains "$RUN_STDERR" '未能停止' 'service stop failure diagnosis'

reset_case
START_RC=74
START_RESULT_ACTIVE=0
run_restart start-failure
assert_eq 2 "$RUN_RC" 'service start failure exit code'
assert_contains "$RUN_STDERR" '服务重启失败' 'service start failure diagnosis'

reset_case
run_restart normal-success
assert_eq 0 "$RUN_RC" 'normal service restart exit code'
assert_eq 1 "$STOP_CALLS" 'normal service is stopped once'
assert_eq 1 "$START_CALLS" 'normal service is started once'

reset_case
TUN_WAS_ACTIVE=1
TUN_ENABLED=1
START_RC=75
START_RESULT_ACTIVE=0
START_RESULT_TUN_READY=0
run_restart tun-start-failure
assert_eq 2 "$RUN_RC" 'Tun start failure exit code'
assert_contains "$RUN_STDERR" 'Tun 模式重启失败' 'Tun start failure diagnosis'

reset_case
TUN_WAS_ACTIVE=1
TUN_ENABLED=1
START_RC=75
START_RESULT_ACTIVE=0
START_RESULT_TUN_READY=1
run_restart tun-stale-interface
assert_eq 2 "$RUN_RC" 'Tun restart requires the service to be active'
assert_contains "$RUN_STDERR" 'Tun 模式重启失败' \
    'stale Tun interface does not mask service start failure'

reset_case
TUN_WAS_ACTIVE=1
TUN_ENABLED=1
run_restart tun-success
assert_eq 0 "$RUN_RC" 'Tun restart succeeds when service and interface are ready'

printf 'config-restart: ok\n'
