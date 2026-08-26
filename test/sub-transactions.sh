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

assert_same() {
    cmp -s -- "$1" "$2" || fail "$3: files differ"
    assert_eq "$(stat -c '%a' "$1")" "$(stat -c '%a' "$2")" "$3 mode"
}

assert_exists() {
    [ -e "$1" ] || [ -L "$1" ] || fail "$2: missing [$1]"
}

assert_absent() {
    if [ -e "$1" ] || [ -L "$1" ]; then
        fail "$2: still exists [$1]"
    fi
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

REAL_YQ=/usr/bin/yq
FAKE_YQ="$WORK_DIR/fake-yq"
cat >"$FAKE_YQ" <<'EOF'
#!/usr/bin/env bash
if [ "${FAIL_YQ_WRITE:-0}" = 1 ] && [ "${1:-}" = -i ]; then
    exit 73
fi
if [ "${FAIL_YQ_AFTER_WRITE:-0}" = 1 ] && [ "${1:-}" = -i ]; then
    "$REAL_YQ" "$@" || exit $?
    exit 73
fi
exec "$REAL_YQ" "$@"
EOF
chmod 0700 "$FAKE_YQ"
export REAL_YQ FAIL_YQ_WRITE=0 FAIL_YQ_AFTER_WRITE=0

# shellcheck source=../scripts/cmd/sub.sh
. "$REPO_DIR/scripts/cmd/sub.sh"

MERGE_RC=0
_valid_sub_nodes() {
    return 0
}

_merge_config_restart() {
    case $MERGE_RC in
    0)
        /bin/cp -- "$CLASH_CONFIG_BASE" "$CLASH_CONFIG_RUNTIME"
        return 0
        ;;
    2)
        /bin/cp -- "$CLASH_CONFIG_BASE" "$CLASH_CONFIG_RUNTIME"
        return 2
        ;;
    *) return "$MERGE_RC" ;;
    esac
}

CASE_DIR='' PROFILE_PATH='' secret_url='https://user:password@example.test/sub?token=top-secret'
setup_case() {
    local label=$1 active=${2:-}
    CASE_DIR="$WORK_DIR/$label"
    CLASH_PROFILES_DIR="$CASE_DIR/profiles"
    CLASH_PROFILES_META="$CASE_DIR/profiles.yaml"
    CLASH_PROFILES_LOG="$CASE_DIR/profiles.log"
    # shellcheck disable=SC2034  # consumed by functions in the sourced command module
    CLASH_PROFILES_LOCK="$CASE_DIR/profiles.lock"
    CLASH_CONFIG_BASE="$CASE_DIR/config.yaml"
    CLASH_CONFIG_RUNTIME="$CASE_DIR/runtime.yaml"
    # shellcheck disable=SC2034  # consumed by functions in the sourced command module
    BIN_YQ=$FAKE_YQ
    PROFILE_PATH="$CLASH_PROFILES_DIR/demo.yaml"
    MERGE_RC=0
    FAIL_YQ_WRITE=0
    FAIL_YQ_AFTER_WRITE=0
    export FAIL_YQ_WRITE FAIL_YQ_AFTER_WRITE

    mkdir -p -- "$CLASH_PROFILES_DIR"
    printf 'proxies: [old-profile]\n' >"$PROFILE_PATH"
    printf 'proxies: [old-base]\n' >"$CLASH_CONFIG_BASE"
    printf 'proxies: [old-runtime]\n' >"$CLASH_CONFIG_RUNTIME"
    chmod 0640 "$PROFILE_PATH" "$CLASH_CONFIG_BASE" "$CLASH_CONFIG_RUNTIME"
    : >"$CLASH_PROFILES_LOG"
    cat >"$CLASH_PROFILES_META" <<EOF
use: "$active"
profiles:
  - name: demo
    path: "$PROFILE_PATH"
    url: "$secret_url"
    updated: "2026-08-26 12:00:00"
    userinfo: "upload=1; download=2; total=10"
EOF
    chmod 0600 "$CLASH_PROFILES_META"
}

snapshot_case() {
    /bin/cp -p -- "$CLASH_PROFILES_META" "$CASE_DIR/expected.meta"
    /bin/cp -p -- "$CLASH_CONFIG_BASE" "$CASE_DIR/expected.base"
    /bin/cp -p -- "$CLASH_CONFIG_RUNTIME" "$CASE_DIR/expected.runtime"
    if [ -f "$PROFILE_PATH" ]; then
        /bin/cp -p -- "$PROFILE_PATH" "$CASE_DIR/expected.profile"
    fi
}

RUN_RC=0 RUN_STDOUT='' RUN_STDERR=''
run_cmd() {
    local label=$1
    shift
    set +e
    "$@" >"$CASE_DIR/$label.stdout" 2>"$CASE_DIR/$label.stderr"
    RUN_RC=$?
    set -e
    RUN_STDOUT=$(<"$CASE_DIR/$label.stdout")
    RUN_STDERR=$(<"$CASE_DIR/$label.stderr")
}

assert_no_success() {
    local phrase=$1 description=$2 log=''
    [ ! -f "$CLASH_PROFILES_LOG" ] || log=$(<"$CLASH_PROFILES_LOG")
    assert_not_contains "$RUN_STDOUT" "$phrase" "$description stdout"
    assert_not_contains "$log" "$phrase" "$description log"
    assert_not_contains "$RUN_STDOUT$RUN_STDERR$log" "$secret_url" "$description URL privacy"
}

assert_state_unchanged() {
    local description=$1
    assert_same "$CASE_DIR/expected.meta" "$CLASH_PROFILES_META" "$description metadata"
    assert_same "$CASE_DIR/expected.base" "$CLASH_CONFIG_BASE" "$description base"
    assert_same "$CASE_DIR/expected.runtime" "$CLASH_CONFIG_RUNTIME" "$description runtime"
    [ ! -f "$CASE_DIR/expected.profile" ] ||
        assert_same "$CASE_DIR/expected.profile" "$PROFILE_PATH" "$description profile"
}

setup_case add_mv
snapshot_case
run_cmd add_mv_fail _sub_add_locked new "$secret_url/new" false \
    "$CASE_DIR/missing-download" '' ''
assert_eq 1 "$RUN_RC" 'add mv failure exit code'
assert_state_unchanged 'add mv failure rollback'
assert_absent "$CLASH_PROFILES_DIR/new.yaml" 'add mv failure target'
assert_no_success '订阅已添加' 'add mv failure'

setup_case add_yq
snapshot_case
printf 'proxies: [new-profile]\n' >"$CASE_DIR/download.yaml"
FAIL_YQ_WRITE=1
export FAIL_YQ_WRITE
run_cmd add_yq_fail _sub_add_locked new "$secret_url/new" false \
    "$CASE_DIR/download.yaml" '' ''
assert_eq 1 "$RUN_RC" 'add yq failure exit code'
assert_state_unchanged 'add yq failure rollback'
assert_absent "$CLASH_PROFILES_DIR/new.yaml" 'add yq failure target'
assert_no_success '订阅已添加' 'add yq failure'

setup_case add_success
printf 'proxies: [new-profile]\n' >"$CASE_DIR/download.yaml"
run_cmd add_success _sub_add_locked new "$secret_url/new" false \
    "$CASE_DIR/download.yaml" '' ''
assert_eq 0 "$RUN_RC" 'ordinary add success exit code'
assert_exists "$CLASH_PROFILES_DIR/new.yaml" 'ordinary add profile'
assert_contains "$(<"$CLASH_PROFILES_LOG")" '订阅已添加：[new]' 'ordinary add success log'

setup_case add_log_warning
mkdir -p -- "$CASE_DIR/log-target-directory"
chmod 0755 "$CASE_DIR/log-target-directory"
CLASH_PROFILES_LOG="$CASE_DIR/log-target-directory"
printf 'proxies: [new-profile]\n' >"$CASE_DIR/download.yaml"
run_cmd add_log_warning _sub_add_locked new "$secret_url/new" false \
    "$CASE_DIR/download.yaml" '' ''
assert_eq 0 "$RUN_RC" 'add log failure preserves core success exit code'
assert_exists "$CLASH_PROFILES_DIR/new.yaml" 'add log failure keeps committed profile'
assert_contains "$RUN_STDERR" '写入操作日志失败' 'add log failure warning'
assert_eq 755 "$(stat -c '%a' "$CLASH_PROFILES_LOG")" 'add log failure directory mode'

setup_case add_use_restart
printf 'proxies: [new-profile]\n' >"$CASE_DIR/download.yaml"
MERGE_RC=2
run_cmd add_use_restart _sub_add_locked new "$secret_url/new" true \
    "$CASE_DIR/download.yaml" '' ''
assert_eq 1 "$RUN_RC" 'add --use restart failure exit code'
assert_eq new "$("$REAL_YQ" '.use' "$CLASH_PROFILES_META")" 'add --use persisted use'
assert_same "$CLASH_PROFILES_DIR/new.yaml" "$CLASH_CONFIG_BASE" 'add --use persisted base'
assert_contains "$RUN_STDERR" '配置已切换' 'add --use partial-success diagnosis'
assert_contains "$RUN_STDERR" '服务重启失败' 'add --use restart diagnosis'
assert_not_contains "$RUN_STDERR" '但未能启用' 'add --use avoids false not-enabled diagnosis'

setup_case migrate_yq
cat >"$CLASH_PROFILES_META" <<EOF
use: "7"
profiles:
  - id: 7
    path: "$PROFILE_PATH"
    url: "$secret_url"
    updated: "2026-08-26 12:00:00"
EOF
chmod 0600 "$CLASH_PROFILES_META"
snapshot_case
FAIL_YQ_WRITE=1
export FAIL_YQ_WRITE
run_cmd migrate_yq_fail clashsub ls
assert_eq 1 "$RUN_RC" 'migration yq failure exit code'
assert_state_unchanged 'migration yq failure rollback'
assert_eq '' "$RUN_STDOUT" 'migration failure stops command dispatch'
assert_no_success '已将订阅数据迁移' 'migration yq failure'

setup_case migrate_success
cat >"$CLASH_PROFILES_META" <<EOF
use: "7"
profiles:
  - id: 7
    path: "$PROFILE_PATH"
    url: "$secret_url"
    updated: "2026-08-26 12:00:00"
EOF
chmod 0600 "$CLASH_PROFILES_META"
run_cmd migrate_success _sub_migrate
assert_eq 0 "$RUN_RC" 'migration success exit code'
assert_eq example.test "$("$REAL_YQ" '.profiles[0].name' "$CLASH_PROFILES_META")" \
    'migration strips URL userinfo from generated name'
assert_eq example.test "$("$REAL_YQ" '.use' "$CLASH_PROFILES_META")" 'migration maps active id'
assert_eq false "$("$REAL_YQ" '.profiles[0] | has("id")' "$CLASH_PROFILES_META")" \
    'migration removes old id'
assert_contains "$(<"$CLASH_PROFILES_LOG")" '已将订阅数据迁移' 'migration success log'

setup_case del_yq
snapshot_case
FAIL_YQ_WRITE=1
export FAIL_YQ_WRITE
run_cmd del_yq_fail _sub_del_locked demo
assert_eq 1 "$RUN_RC" 'delete yq failure exit code'
assert_state_unchanged 'delete yq failure rollback'
assert_no_success '订阅已删除' 'delete yq failure'

setup_case del_unsafe_path
outside_profile="$CASE_DIR/outside.yaml"
printf 'must remain\n' >"$outside_profile"
UNSAFE_PATH=$outside_profile "$REAL_YQ" -i \
    '.profiles[0].path = strenv(UNSAFE_PATH)' "$CLASH_PROFILES_META"
/bin/cp -p -- "$CLASH_PROFILES_META" "$CASE_DIR/expected.meta"
/bin/cp -p -- "$outside_profile" "$CASE_DIR/expected.outside"
run_cmd del_unsafe_path _sub_del_locked demo
assert_eq 1 "$RUN_RC" 'unsafe delete path exit code'
assert_same "$CASE_DIR/expected.meta" "$CLASH_PROFILES_META" 'unsafe delete path metadata'
assert_same "$CASE_DIR/expected.outside" "$outside_profile" 'unsafe delete path protected file'
assert_contains "$RUN_STDERR" '路径不安全' 'unsafe delete path diagnosis'
assert_no_success '订阅已删除' 'unsafe delete path'

setup_case del_rm
/usr/bin/rm -f -- "$PROFILE_PATH"
mkdir -p -- "$PROFILE_PATH"
printf 'preserve me\n' >"$PROFILE_PATH/content"
snapshot_case
/bin/cp -p -- "$PROFILE_PATH/content" "$CASE_DIR/expected.directory-content"
run_cmd del_rm_fail _sub_del_locked demo
assert_eq 1 "$RUN_RC" 'delete rm failure exit code'
assert_same "$CASE_DIR/expected.meta" "$CLASH_PROFILES_META" 'delete rm failure metadata'
assert_same "$CASE_DIR/expected.directory-content" "$PROFILE_PATH/content" 'delete rm failure directory content'
assert_no_success '订阅已删除' 'delete rm failure'

setup_case del_success
run_cmd del_success _sub_del_locked demo
assert_eq 0 "$RUN_RC" 'delete success exit code'
assert_absent "$PROFILE_PATH" 'delete success profile'
assert_eq 0 "$("$REAL_YQ" '.profiles | length' "$CLASH_PROFILES_META")" 'delete success metadata'
assert_contains "$(<"$CLASH_PROFILES_LOG")" '订阅已删除：[demo]' 'delete success log'

setup_case update_mv
snapshot_case
run_cmd update_mv_fail _sub_update_locked demo "$secret_url" "$PROFILE_PATH" \
    "$CASE_DIR/missing-download" ''
assert_eq 1 "$RUN_RC" 'update mv failure exit code'
assert_state_unchanged 'update mv failure rollback'
assert_no_success '订阅更新成功' 'update mv failure'

setup_case update_recreated
readded_path="$CLASH_PROFILES_DIR/readded.yaml"
printf 'proxies: [readded-profile]\n' >"$readded_path"
NEW_PATH=$readded_path "$REAL_YQ" -i \
    '.profiles[0].path = strenv(NEW_PATH)' "$CLASH_PROFILES_META"
snapshot_case
/bin/cp -p -- "$readded_path" "$CASE_DIR/expected.readded"
printf 'proxies: [downloaded-profile]\n' >"$CASE_DIR/download.yaml"
run_cmd update_recreated _sub_update_locked demo "$secret_url" "$PROFILE_PATH" \
    "$CASE_DIR/download.yaml" ''
assert_eq 1 "$RUN_RC" 'recreated subscription update exit code'
assert_state_unchanged 'recreated subscription update state'
assert_same "$CASE_DIR/expected.readded" "$readded_path" 'recreated subscription referenced profile'
assert_absent "$CASE_DIR/download.yaml" 'recreated subscription downloaded candidate cleanup'
assert_contains "$RUN_STDERR" '下载期间已发生变化' 'recreated subscription diagnosis'
assert_no_success '订阅更新成功' 'recreated subscription update'

setup_case update_yq
snapshot_case
printf 'proxies: [new-profile]\n' >"$CASE_DIR/download.yaml"
FAIL_YQ_WRITE=1
export FAIL_YQ_WRITE
run_cmd update_yq_fail _sub_update_locked demo "$secret_url" "$PROFILE_PATH" \
    "$CASE_DIR/download.yaml" 'upload=5; total=20'
assert_eq 1 "$RUN_RC" 'update yq failure exit code'
assert_state_unchanged 'update yq failure rollback'
assert_no_success '订阅更新成功' 'update yq failure'

setup_case update_active demo
snapshot_case
printf 'proxies: [new-profile]\n' >"$CASE_DIR/download.yaml"
MERGE_RC=1
run_cmd update_apply_fail _sub_update_locked demo "$secret_url" "$PROFILE_PATH" \
    "$CASE_DIR/download.yaml" ''
assert_eq 1 "$RUN_RC" 'active update apply failure exit code'
assert_state_unchanged 'active update apply failure rollback'
assert_contains "$RUN_STDERR" '订阅已回滚' 'active update rollback diagnosis'
assert_no_success '订阅更新成功' 'active update apply failure'

setup_case update_success
printf 'proxies: [new-profile]\n' >"$CASE_DIR/download.yaml"
run_cmd update_success _sub_update_locked demo "$secret_url" "$PROFILE_PATH" \
    "$CASE_DIR/download.yaml" 'upload=5; total=20'
assert_eq 0 "$RUN_RC" 'update success exit code'
assert_contains "$(<"$PROFILE_PATH")" 'new-profile' 'update success profile'
assert_eq 'upload=5; total=20' \
    "$("$REAL_YQ" '.profiles[0].userinfo' "$CLASH_PROFILES_META")" \
    'update success userinfo'
assert_contains "$(<"$CLASH_PROFILES_LOG")" '订阅更新成功：[demo]' 'update success log'

setup_case rename_yq demo
snapshot_case
FAIL_YQ_WRITE=1
export FAIL_YQ_WRITE
run_cmd rename_yq_fail _sub_rename_locked demo renamed
assert_eq 1 "$RUN_RC" 'rename yq failure exit code'
assert_state_unchanged 'rename yq failure rollback'
assert_no_success '订阅已重命名' 'rename yq failure'

setup_case rename_success demo
run_cmd rename_success _sub_rename_locked demo renamed
assert_eq 0 "$RUN_RC" 'active rename success exit code'
assert_eq renamed "$("$REAL_YQ" '.use' "$CLASH_PROFILES_META")" 'active rename use field'
assert_eq renamed "$("$REAL_YQ" '.profiles[0].name' "$CLASH_PROFILES_META")" 'active rename profile name'

setup_case use_yq
snapshot_case
FAIL_YQ_WRITE=1
export FAIL_YQ_WRITE
run_cmd use_yq_fail _sub_use_locked demo
assert_eq 1 "$RUN_RC" 'use yq failure exit code'
assert_state_unchanged 'use yq failure rollback'
assert_no_success '订阅已切换为' 'use yq failure'

setup_case use_merge
snapshot_case
MERGE_RC=1
run_cmd use_merge_fail _sub_use_locked demo
assert_eq 1 "$RUN_RC" 'use merge failure exit code'
assert_state_unchanged 'use merge failure rollback'
assert_contains "$RUN_STDERR" '已回滚' 'use merge rollback diagnosis'
assert_no_success '订阅已切换为' 'use merge failure'

setup_case use_success
run_cmd use_success _sub_use_locked demo
assert_eq 0 "$RUN_RC" 'use success exit code'
assert_eq demo "$("$REAL_YQ" '.use' "$CLASH_PROFILES_META")" 'use success metadata'
assert_same "$PROFILE_PATH" "$CLASH_CONFIG_BASE" 'use success base'
assert_same "$PROFILE_PATH" "$CLASH_CONFIG_RUNTIME" 'use success runtime'
assert_contains "$(<"$CLASH_PROFILES_LOG")" '订阅已切换为：[demo]' 'use success log'

setup_case use_restart
MERGE_RC=2
run_cmd use_restart_fail _sub_use_locked demo
assert_eq 1 "$RUN_RC" 'use restart failure exit code'
assert_eq demo "$("$REAL_YQ" '.use' "$CLASH_PROFILES_META")" 'restart failure keeps persisted use'
assert_same "$PROFILE_PATH" "$CLASH_CONFIG_BASE" 'restart failure keeps new base'
assert_same "$PROFILE_PATH" "$CLASH_CONFIG_RUNTIME" 'restart failure keeps new runtime'
assert_contains "$RUN_STDERR" '服务重启失败' 'restart failure diagnosis'
assert_no_success '订阅已切换为' 'use restart failure'
assert_contains "$(<"$CLASH_PROFILES_LOG")" '[ERROR]' 'restart failure error log'

if find "$WORK_DIR" \( -name '*.meta.??????' -o -name '*.base.??????' \
    -o -name '*.profile.??????' -o -name '*.next.??????' -o -name '.delete.??????' \) \
    -print -quit | grep -q .; then
    fail 'rollback artifacts remain after transaction tests'
fi

printf 'sub-transactions: ok\n'
