#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_DIR=$(cd -- "$TEST_DIR/.." && pwd -P)
WORK_DIR=$(mktemp -d)
PIDS=()
cleanup() {
    local pid
    for pid in "${PIDS[@]}"; do
        kill -CONT "$pid" 2>/dev/null || true
        kill -KILL "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    /usr/bin/rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    local file=$1 expected=$2 description=$3
    grep -Fqs -- "$expected" "$file" || fail "$description: missing [$expected]"
}

assert_process_does_not_hold_file() {
    local pid=$1 file=$2 description=$3 expected actual descriptor
    expected=$(stat -Lc '%d:%i' -- "$file") || fail "$description: cannot stat lock file"
    for descriptor in "/proc/$pid/fd"/*; do
        actual=$(stat -Lc '%d:%i' -- "$descriptor" 2>/dev/null) || continue
        [ "$actual" != "$expected" ] || fail "$description"
    done
}

wait_for_file() {
    local file=$1 pid=$2 description=$3 attempt=0
    while [ "$attempt" -lt 200 ]; do
        [ -e "$file" ] && return 0
        kill -0 "$pid" 2>/dev/null || fail "$description: process exited early"
        attempt=$((attempt + 1))
        sleep 0.01
    done
    fail "$description: timed out"
}

# shellcheck source=../scripts/lib/operation-lock.sh
. "$REPO_DIR/scripts/lib/operation-lock.sh"

LOCK_BASE="$WORK_DIR/runtime"
mkdir -m 0700 -- "$LOCK_BASE"

# Keep tests away from the host runtime directory while retaining production validation.
_operation_lock_base() {
    _operation_lock_validate_base "$LOCK_BASE" "$1" || return 1
    printf '%s\n' "$LOCK_BASE"
}

test_contention_and_crash_release() {
    local ready="$WORK_DIR/holder.ready" stderr="$WORK_DIR/contention.stderr" holder rc=0
    (
        operation_lock_acquire || exit 1
        : >"$ready"
        kill -STOP "$BASHPID"
    ) &
    holder=$!
    PIDS+=("$holder")
    wait_for_file "$ready" "$holder" 'operation lock holder'

    operation_lock_acquire 2>"$stderr" || rc=$?
    [ "$rc" -eq 1 ] || fail "contending acquisition returned $rc instead of 1"
    assert_contains "$stderr" '另一项 clashctl 安装、更新或卸载正在进行' \
        'contention diagnostic'

    kill -KILL "$holder"
    wait "$holder" 2>/dev/null || true
    operation_lock_acquire || fail 'lock was not released after holder was killed'
    local lock_file=$CLASHCTL_OPERATION_LOCK_FILE
    operation_lock_close_fd || fail 'could not close acquired operation lock fd'
    [ -f "$lock_file" ] || fail 'persistent lock file was removed on release'
}

test_missing_flock_fails_closed() {
    local stderr="$WORK_DIR/missing-flock.stderr" rc=0
    # shellcheck disable=SC2317  # Called indirectly by operation_lock_acquire.
    _operation_lock_has_flock() { return 1; }
    operation_lock_acquire 2>"$stderr" || rc=$?
    [ "$rc" -eq 1 ] || fail "missing flock returned $rc instead of 1"
    assert_contains "$stderr" '缺少操作锁依赖 flock' 'missing flock diagnostic'
    _operation_lock_has_flock() { command -v flock >/dev/null 2>&1; }
}

test_unsafe_runtime_and_lock_directory_are_rejected() {
    local stderr="$WORK_DIR/unsafe-base.stderr" rc=0 lock_dir
    chmod 0777 -- "$LOCK_BASE"
    operation_lock_acquire 2>"$stderr" || rc=$?
    [ "$rc" -eq 1 ] || fail "unsafe runtime directory returned $rc instead of 1"
    assert_contains "$stderr" '安全的运行时目录' 'unsafe runtime directory diagnostic'
    chmod 0700 -- "$LOCK_BASE"

    operation_lock_acquire || fail 'could not prepare lock directory security test'
    lock_dir=${CLASHCTL_OPERATION_LOCK_FILE%/*}
    operation_lock_close_fd
    chmod 0770 -- "$lock_dir"
    rc=0
    operation_lock_acquire 2>"$WORK_DIR/unsafe-lock-dir.stderr" || rc=$?
    [ "$rc" -eq 1 ] || fail "unsafe lock directory returned $rc instead of 1"
    assert_contains "$WORK_DIR/unsafe-lock-dir.stderr" '操作锁目录的归属或权限不安全' \
        'unsafe lock directory diagnostic'
    chmod 0700 -- "$lock_dir"
}

test_nohup_daemon_does_not_inherit_lock_fd() {
    local fake_kernel="$WORK_DIR/fake-kernel" ready="$WORK_DIR/fake-kernel.ready"
    local daemon_pid attempt=0
    # shellcheck disable=SC2016  # The generated helper expands these at runtime.
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'printf "%s\n" "$BASHPID" >"$OPERATION_LOCK_DAEMON_READY"' \
        'kill -STOP "$BASHPID"' >"$fake_kernel"
    chmod 0700 -- "$fake_kernel"

    # shellcheck source=../scripts/lib/service.sh
    . "$REPO_DIR/scripts/lib/service.sh"
    BIN_KERNEL=$fake_kernel
    CLASHCTL_KERNEL=mihomo
    CLASH_RESOURCES_DIR="$WORK_DIR/resources"
    CLASH_CONFIG_RUNTIME="$WORK_DIR/runtime.yaml"
    service_pid_path="$WORK_DIR/mihomo.pid"
    service_log_path="$WORK_DIR/mihomo.log"
    OPERATION_LOCK_DAEMON_READY=$ready
    export BIN_KERNEL CLASHCTL_KERNEL CLASH_RESOURCES_DIR CLASH_CONFIG_RUNTIME
    export OPERATION_LOCK_DAEMON_READY service_pid_path service_log_path
    _service_process_record_pid() { return 1; }
    _service_process_record_create() { return 0; }

    operation_lock_acquire || fail 'could not acquire lock for daemon inheritance test'
    _service_nohup_start_locked || fail 'fake nohup service did not start'
    while [ "$attempt" -lt 200 ]; do
        if [ -s "$ready" ]; then
            read -r daemon_pid <"$ready"
            break
        fi
        attempt=$((attempt + 1))
        sleep 0.01
    done
    [ -n "$daemon_pid" ] || fail 'could not identify fake nohup daemon'
    PIDS+=("$daemon_pid")
    assert_process_does_not_hold_file \
        "$daemon_pid" "$CLASHCTL_OPERATION_LOCK_FILE" \
        'nohup daemon inherited operation lock fd'

    operation_lock_close_fd || fail 'could not release parent operation lock'
    (
        operation_lock_acquire || exit 1
        operation_lock_close_fd
    ) || fail 'daemon retained the operation lock after installer released it'
}

test_sysv_style_background_child_does_not_inherit_lock_fd() {
    local ready="$WORK_DIR/sysv-child.ready" child_pid attempt=0

    # shellcheck disable=SC2034  # Read dynamically by service_start.
    service_manager=sysvinit
    service() {
        (
            printf '%s\n' "$BASHPID" >"$ready"
            kill -STOP "$BASHPID"
        ) &
    }
    operation_lock_acquire || fail 'could not acquire lock for SysV inheritance test'
    service_start || fail 'fake SysV service did not start'
    while [ "$attempt" -lt 200 ]; do
        if [ -s "$ready" ]; then
            read -r child_pid <"$ready"
            break
        fi
        attempt=$((attempt + 1))
        sleep 0.01
    done
    [ -n "$child_pid" ] || fail 'could not identify fake SysV background child'
    PIDS+=("$child_pid")
    assert_process_does_not_hold_file \
        "$child_pid" "$CLASHCTL_OPERATION_LOCK_FILE" \
        'SysV-style background child inherited operation lock fd'
    operation_lock_close_fd || fail 'could not release operation lock after SysV test'
}

test_update_holds_lifecycle_lock_for_dispatch() {
    local dispatch_checked=0

    # shellcheck source=../scripts/cmd/update.sh
    . "$REPO_DIR/scripts/cmd/update.sh"
    _update_require_install() { return 0; }
    _update_is_git_home() { return 0; }
    clashupdate_git() {
        local inherited_fd=${CLASHCTL_OPERATION_LOCK_FD:-}
        if [ -z "$inherited_fd" ] || [ ! -e "/proc/self/fd/$inherited_fd" ]; then
            fail 'update dispatch started without the lifecycle lock'
        fi
        dispatch_checked=1
        return 0
    }

    clashupdate --check || fail 'locked update dispatch failed'
    [ "$dispatch_checked" -eq 1 ] || fail 'update dispatch did not run'
    [ -z "${CLASHCTL_OPERATION_LOCK_FD:-}" ] || fail 'update retained lifecycle lock fd'
    operation_lock_acquire || fail 'update did not release lifecycle lock'
    operation_lock_close_fd || fail 'could not close post-update test lock'
}

test_contention_and_crash_release
test_missing_flock_fails_closed
test_unsafe_runtime_and_lock_directory_are_rejected
test_nohup_daemon_does_not_inherit_lock_fd
test_sysv_style_background_child_does_not_inherit_lock_fd
test_update_holds_lifecycle_lock_for_dispatch

printf 'operation-lock: ok\n'
