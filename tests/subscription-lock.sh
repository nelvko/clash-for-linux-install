#!/usr/bin/env bash
# 订阅锁不能被后台组件继承；下载后的提交失败只清理本次临时文件。
# shellcheck disable=SC2034  # 配置变量由间接调用的库函数读取。
set -euo pipefail

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK_DIR=$(mktemp -d)
cleanup() {
    local record pid
    for record in "$WORK_DIR"/*.pid; do
        [ -f "$record" ] || continue
        read -r pid <"$record" || continue
        kill -TERM "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    command rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# shellcheck source=../scripts/cmd/sub.sh
. "$REPO_DIR/scripts/cmd/sub.sh"
# shellcheck source=../scripts/lib/convert.sh
. "$REPO_DIR/scripts/lib/convert.sh"
# shellcheck source=../scripts/lib/service.sh
. "$REPO_DIR/scripts/lib/service.sh"

mkdir -m 0700 -- "$WORK_DIR/runtime"
_operation_lock_base() { printf '%s\n' "$WORK_DIR/runtime"; }
CLASH_PROFILES_LOCK="$WORK_DIR/profiles.lock"

cat >"$WORK_DIR/daemon" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$BASHPID" >"$DAEMON_TEST_DIR/$DAEMON_NAME.pid"
: >"$DAEMON_TEST_DIR/$DAEMON_NAME.ready"
exec sleep 30
EOF
chmod 0700 -- "$WORK_DIR/daemon"
export DAEMON_TEST_DIR=$WORK_DIR DAEMON_NAME
BIN_KERNEL="$WORK_DIR/daemon"
BIN_SUBCONVERTER="$WORK_DIR/daemon"
BIN_SUBCONVERTER_CONFIG="$WORK_DIR/pref.yml"
BIN_SUBCONVERTER_LOG="$WORK_DIR/converter.log"
BIN_YQ=fixture_yq
CLASH_RESOURCES_DIR="$WORK_DIR/resources"
CLASH_CONFIG_RUNTIME="$WORK_DIR/runtime.yaml"
service_pid_path="$WORK_DIR/kernel-record"
service_log_path="$WORK_DIR/kernel.log"

# 只替换端口探测和 PID 记录；后台启动与两种锁使用真实实现。
fixture_yq() { printf '25500\n'; }
_detect_subconverter_port() { BIN_SUBCONVERTER_PORT=25500; }
_service_process_record_pid() { return 1; }
_service_process_record_create() { return 0; }
wait_ready() {
    local attempt
    for ((attempt = 0; attempt < 200; attempt++)); do
        [ ! -e "$WORK_DIR/$DAEMON_NAME.ready" ] || return 0
        sleep 0.01
    done
    return 1
}
# shellcheck disable=SC2317  # _start_convert 间接调用此探活替身。
curl() {
    # 启动后的首次探活仍未就绪；后续成功时必须返回 0。
    [ -n "${BIN_SUBCONVERTER_PID:-}" ] || return 1
    if [ ! -e "$WORK_DIR/delayed-health-check" ]; then
        touch "$WORK_DIR/delayed-health-check"
        return 1
    fi
    wait_ready
}
assert_daemon_releases_locks() {
    local start_fn=$1 pid descriptor expected actual
    operation_lock_acquire || fail 'cannot acquire lifecycle lock'
    _with_profiles_lock "$start_fn" || fail "$DAEMON_NAME did not start"
    wait_ready || fail "$DAEMON_NAME startup timed out"
    read -r pid <"$WORK_DIR/$DAEMON_NAME.pid"
    kill -0 "$pid" || fail "$DAEMON_NAME exited before lock check"
    for expected in "$CLASH_PROFILES_LOCK" "$CLASHCTL_OPERATION_LOCK_FILE"; do
        expected=$(stat -Lc '%d:%i' -- "$expected")
        for descriptor in "/proc/$pid/fd"/*; do
            actual=$(stat -Lc '%d:%i' -- "$descriptor" 2>/dev/null) || continue
            [ "$actual" != "$expected" ] || fail "$DAEMON_NAME inherited a lock descriptor"
        done
    done
    command flock -n "$CLASH_PROFILES_LOCK" -c true || fail "$DAEMON_NAME retained subscription lock"
    operation_lock_close_fd || fail 'cannot close lifecycle lock'
    operation_lock_acquire || fail "$DAEMON_NAME retained lifecycle lock"
    operation_lock_close_fd || fail 'cannot release lifecycle lock'
}
DAEMON_NAME=kernel
assert_daemon_releases_locks _service_nohup_start_locked
DAEMON_NAME=converter
assert_daemon_releases_locks _start_convert
unset -f curl

# 下载走真实 _sub_download；网络与元数据提交用替身，取锁仍由 flock 执行。
mkdir -p -- "$CLASH_RESOURCES_DIR"
printf 'downloaded subscription\n' >"$WORK_DIR/download"
printf 'unrelated temporary file\n' >"$CLASH_RESOURCES_DIR/.fetch.keep"
profile="$WORK_DIR/profile.yaml"
printf 'original profile\n' >"$profile"
_download_config() { cp -- "$WORK_DIR/download" "$1"; }
_errorcat() { printf '%s\n' "$*" >&2; }
_ui_emit_fd() { :; }
_logging_sub() { :; }
_sub_has() { [ "$1" = existing ]; }
_sub_url_exists() { return 1; }
_sub_get() {
    case $2 in
    url) printf 'https://fixture.invalid/sub' ;;
    path) printf '%s' "$profile" ;;
    esac
}
commit_status=0
fixture_commit() {
    [ "$commit_status" -eq 0 ] || return "$commit_status"
    /bin/mv -- "$4" "$profile"
}
_sub_add_locked() { fixture_commit "$@"; }
_sub_update_locked() { fixture_commit "$@"; }
flock() {
    # 用真实的锁冲突，缩短生产代码的 60 秒等待以避免测试空耗。
    if [ "${1:-}" = -w ]; then
        shift 2
        command flock -w 0 "$@"
    else
        command flock "$@"
    fi
}
run_write() {
    case $1 in
    add) sub_add --name new https://fixture.invalid/sub ;;
    update) _sub_update_one existing auto ;;
    esac
}
assert_failed_download_cleanup() {
    [ ! -e "$_SUB_DL_FILE" ] || fail 'failed write retained downloaded temporary file'
    [ "$(cat "$profile")" = 'original profile' ] || fail 'failed write changed existing profile'
    [ "$(cat "$CLASH_RESOURCES_DIR/.fetch.keep")" = 'unrelated temporary file' ] ||
        fail 'cleanup removed another operation temporary file'
}
for operation in add update; do
    exec 8>>"$CLASH_PROFILES_LOCK"
    command flock -n 8 || fail 'cannot hold subscription lock'
    rc=0
    run_write "$operation" >"$WORK_DIR/output" 2>&1 || rc=$?
    [ "$rc" -eq 1 ] || fail "$operation did not report lock contention"
    grep -q '另一订阅操作正在进行' "$WORK_DIR/output" || fail 'missing contention diagnostic'
    assert_failed_download_cleanup
    exec 8>&-

    commit_status=23
    rc=0
    run_write "$operation" >"$WORK_DIR/output" 2>&1 || rc=$?
    [ "$rc" -eq 23 ] || fail "$operation lost commit failure status"
    assert_failed_download_cleanup

    commit_status=0
    run_write "$operation" >"$WORK_DIR/output" 2>&1 || fail "$operation successful write failed"
    cmp -s -- "$WORK_DIR/download" "$profile" || fail 'cleanup removed published subscription'
    [ ! -e "$_SUB_DL_FILE" ] || fail 'successful write retained temporary file'
    printf 'original profile\n' >"$profile"
done

printf 'subscription-lock: ok\n'
