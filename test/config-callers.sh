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

assert_not_contains() {
    local file=$1 unexpected=$2 description=$3
    if grep -Fqs -- "$unexpected" "$file"; then
        fail "$description: unexpectedly found [$unexpected]"
    fi
}

export CLASHCTL_KERNEL=mihomo
# shellcheck source=../scripts/cmd/on.sh
. "$REPO_DIR/scripts/cmd/on.sh"
# shellcheck source=../scripts/cmd/ui.sh
. "$REPO_DIR/scripts/cmd/ui.sh"
# shellcheck source=../scripts/cmd/node.sh
. "$REPO_DIR/scripts/cmd/node.sh"

SERVICE_ACTIVE=0
SERVICE_START_CALLS=0
PROXY_DETECT_RC=0
CONTROLLER_DETECT_RC=0
CONTROLLER_IP=127.0.0.1
CONTROLLER_PORT=9090
SYSTEM_PROXY_RC=0

service_is_active() {
    [ "$SERVICE_ACTIVE" -eq 1 ]
}

service_start() {
    SERVICE_START_CALLS=$((SERVICE_START_CALLS + 1))
    SERVICE_ACTIVE=1
}

_detect_proxy_port() {
    return "$PROXY_DETECT_RC"
}

_detect_ext_addr() {
    # shellcheck disable=SC2034  # consumed by the sourced ui/node command modules
    EXT_IP=$CONTROLLER_IP EXT_PORT=$CONTROLLER_PORT
    return "$CONTROLLER_DETECT_RC"
}

set_system_proxy() {
    return "$SYSTEM_PROXY_RC"
}

_ui_step() { printf '[STEP] %s\n' "$*" >&2; }
_ui_ok() { printf '[ OK ] %s\n' "$*" >&2; }
_ui_ok_out() { printf '[ OK ] %s\n' "$*"; }
_ui_error() { printf '[ERROR] %s\n' "$*" >&2; }
_ui_fail() { printf '[ERROR] %s\n' "$*" >&2; return 1; }
_ui_blank() { printf '\n' >&2; }
_ui_header() { printf '[INFO] %s\n' "$*" >&2; }
_ui_detail() { printf '        %s: %s\n' "$1" "$2" >&2; }

run_case() {
    local label=$1
    shift
    RUN_RC=0
    "$@" >"$WORK_DIR/$label.stdout" 2>"$WORK_DIR/$label.stderr" || RUN_RC=$?
    RUN_STDOUT="$WORK_DIR/$label.stdout"
}

PROXY_DETECT_RC=1
SERVICE_ACTIVE=0
SERVICE_START_CALLS=0
run_case on-detect-failure on_service_only
assert_eq 1 "$RUN_RC" 'service command propagates proxy detection failure'
assert_eq 0 "$SERVICE_START_CALLS" 'service is not started after proxy detection failure'

CONTROLLER_DETECT_RC=1
SERVICE_ACTIVE=0
SERVICE_START_CALLS=0
run_case ui-detect-failure clashui
assert_eq 1 "$RUN_RC" 'UI command propagates controller detection failure'
assert_eq 0 "$SERVICE_START_CALLS" 'UI command does not start after detection failure'

run_case node-detect-failure _node_api_base
assert_eq 1 "$RUN_RC" 'node API base propagates controller detection failure'
assert_eq '' "$(<"$RUN_STDOUT")" 'node API base emits no invalid URL after detection failure'

CONTROLLER_DETECT_RC=0
CONTROLLER_IP=controller.example
CONTROLLER_PORT=19090
run_case node-hostname _node_api_base
assert_eq 0 "$RUN_RC" 'node API base accepts a controller hostname'
assert_eq 'http://controller.example:19090' "$(<"$RUN_STDOUT")" \
    'node API base uses the parsed controller hostname'

CONTROLLER_IP=2001:db8::1
CONTROLLER_PORT=29090
run_case node-ipv6 _node_api_base
assert_eq 0 "$RUN_RC" 'node API base accepts a controller IPv6 address'
assert_eq 'http://[2001:db8::1]:29090' "$(<"$RUN_STDOUT")" \
    'node API base brackets the parsed controller IPv6 address'

SERVICE_ACTIVE=1
SYSTEM_PROXY_RC=1
run_case env-failure on_env_only
assert_eq 1 "$RUN_RC" 'terminal proxy setup failure is propagated'
assert_not_contains "$RUN_STDOUT" '终端代理已启用' \
    'terminal proxy setup failure is not reported as success'

printf 'config-callers: ok\n'
