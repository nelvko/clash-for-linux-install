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
    *"$unexpected"*) fail "$description: unexpectedly contained [$unexpected]" ;;
    esac
}

CLASHCTL_HOME=$WORK_DIR
CLASHCTL_KERNEL=mihomo
CLASHCTL_COLOR=never
CI=1
export CLASHCTL_HOME CLASHCTL_KERNEL CLASHCTL_COLOR CI

mkdir -p -- "$WORK_DIR/bin"
BIN_YQ="$WORK_DIR/bin/yq"
export BIN_YQ
cat >"$BIN_YQ" <<'EOF'
#!/usr/bin/env bash
printf '{"name":"node"}\n'
EOF
chmod 0700 "$BIN_YQ"

# shellcheck source=../scripts/lib/common.sh
. "$REPO_DIR/scripts/lib/common.sh"
# shellcheck source=../scripts/cmd/node.sh
. "$REPO_DIR/scripts/cmd/node.sh"
# shellcheck source=../scripts/cmd/off.sh
. "$REPO_DIR/scripts/cmd/off.sh"
# shellcheck source=../scripts/cmd/update.sh
. "$REPO_DIR/scripts/cmd/update.sh"

RUN_RC=0 RUN_STDOUT='' RUN_STDERR=''
run_cmd() {
    local label=$1
    shift
    set +e
    "$@" >"$WORK_DIR/$label.stdout" 2>"$WORK_DIR/$label.stderr"
    RUN_RC=$?
    set -e
    RUN_STDOUT=$(<"$WORK_DIR/$label.stdout")
    RUN_STDERR=$(<"$WORK_DIR/$label.stderr")
}

NODE_CODE=204
_node_curl() {
    printf '%s' "$NODE_CODE"
}

run_cmd node_ok _node_apply selector node
assert_eq 0 "$RUN_RC" 'node switch success exit code'
assert_contains "$RUN_STDOUT" '[ OK ] 已切换 [selector] → node' 'node switch success result'
assert_eq '' "$RUN_STDERR" 'node switch success stderr'

NODE_CODE=400
run_cmd node_fail _node_apply selector missing
assert_eq 1 "$RUN_RC" 'node switch failure exit code'
assert_eq '' "$RUN_STDOUT" 'node switch failure stdout'
assert_contains "$RUN_STDERR" '[ERROR] 切换失败' 'node switch failure diagnosis'

_node_delay_member_rows() {
    printf 'node\t12\n'
}

_node_print_delays() {
    cat
}

run_cmd node_delay _node_delay_proxy node https://example.test 5000
assert_eq 0 "$RUN_RC" 'node delay exit code'
assert_eq $'node\t12' "$RUN_STDOUT" 'node delay data remains on stdout'
assert_contains "$RUN_STDERR" '[STEP] 正在测速节点 [node]' 'node delay progress uses stderr'

service_is_active() {
    return 1
}

# shellcheck disable=SC2034  # consumed by clashoff from the sourced command module
http_proxy=http://127.0.0.1:7890
run_cmd off_service clashoff --service-only
assert_eq 1 "$RUN_RC" 'service-only residual proxy exit code'
assert_contains "$RUN_STDOUT" '[ OK ] mihomo 已停止' 'service stop result uses stdout'
assert_contains "$RUN_STDERR" '[WARN] 当前终端代理未关闭' 'residual proxy warning uses stderr'

_update_local_rev() {
    printf 'abc1234\n'
}

_update_fetch() {
    printf 'def5678\n'
}

UPDATE_STATUS='behind 3'
_update_status() {
    printf '%s\n' "$UPDATE_STATUS"
}

run_cmd update_check clashupdate_git true false master
assert_eq 0 "$RUN_RC" 'update check with available version exit code'
assert_contains "$RUN_STDOUT" '[INFO] 当前版本：abc1234（master）' 'current version uses stdout'
assert_contains "$RUN_STDOUT" '[INFO] 最新版本：def5678（master）' 'remote version uses stdout'
assert_contains "$RUN_STDOUT" '[INFO] 有新版本可用（落后 3 个提交）' \
    'available update result uses stdout'
assert_not_contains "$RUN_STDERR" '有新版本可用' \
    'available update result is not mixed into diagnostics'

UPDATE_STATUS=diverged
run_cmd update_check_diverged clashupdate_git true false master
assert_eq 0 "$RUN_RC" 'diverged update check exit code'
assert_contains "$RUN_STDOUT" '远端 master 与当前版本已分叉' \
    'diverged update result uses stdout'
assert_not_contains "$RUN_STDERR" '已分叉' 'diverged result is not mixed into diagnostics'

run_cmd update_unknown clashupdate --definitely-unknown
assert_eq 1 "$RUN_RC" 'unknown update option exit code'
assert_eq '' "$RUN_STDOUT" 'unknown update option keeps stdout clean'
assert_contains "$RUN_STDERR" 'Usage:' 'unknown update option writes help to stderr'

printf 'cmd-ui-contract: ok\n'
