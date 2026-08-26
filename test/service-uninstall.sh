#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_DIR=$(cd -- "$TEST_DIR/.." && pwd -P)
WORK_DIR=$(mktemp -d)
SYSTEMD_PID=
SYSTEMD_FEED_PID=
cleanup() {
    if [ -n "$SYSTEMD_PID" ]; then
        kill -KILL "$SYSTEMD_PID" 2>/dev/null || true
        wait "$SYSTEMD_PID" 2>/dev/null || true
    fi
    if [ -n "$SYSTEMD_FEED_PID" ]; then
        kill -KILL "$SYSTEMD_FEED_PID" 2>/dev/null || true
        wait "$SYSTEMD_FEED_PID" 2>/dev/null || true
    fi
    /usr/bin/rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT

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
    grep -Fqs -- "$2" "$1" || fail "$3: missing [$2]"
}

assert_not_contains() {
    if grep -Fqs -- "$2" "$1"; then
        fail "$3: unexpectedly found [$2]"
    fi
}

assert_exists() {
    [ -e "$1" ] || [ -L "$1" ] || fail "$2: missing [$1]"
}

assert_absent() {
    if [ -e "$1" ] || [ -L "$1" ]; then
        fail "$2: still exists [$1]"
    fi
}

assert_link() {
    [ -L "$1" ] || fail "$3: not a symlink [$1]"
    assert_eq "$2" "$(readlink -- "$1")" "$3"
}

export CLASHCTL_INSTALL_SOURCE_ONLY=1
# shellcheck source=../install.sh
. "$REPO_DIR/install.sh"
# shellcheck source=../scripts/lib/service-process.sh
. "$REPO_DIR/scripts/lib/service-process.sh"
# shellcheck source=../scripts/lib/service.sh
. "$REPO_DIR/scripts/lib/service.sh"

CASE_DIR=
TEST_TARGET=
TEST_SYSTEMD_ETC_ROOT=
TEST_SYSTEMD_RUN_ROOT=
TEST_SYSTEMD_INSTALLED_LINK=
SYSTEMCTL_LOG=
FAKE_ACTIVE=0
FAKE_ENABLED=0
FAKE_FAIL_ENABLE=0
FAKE_FAIL_RELOAD=0
FAKE_FRAGMENT=
FAKE_EXECSTART=
FAKE_MAINPID=0
TEST_MANAGER=systemd
FAKE_ENABLEMENT_FROM_LINKS=0

service_enablement_systemd_persistent_root() {
    printf '%s\n' "$TEST_SYSTEMD_ETC_ROOT"
}

service_enablement_systemd_runtime_root() {
    printf '%s\n' "$TEST_SYSTEMD_RUN_ROOT"
}

service_enablement_sysv_root() {
    printf '%s\n' "$CASE_DIR/etc"
}

service_enablement_openrc_root() {
    printf '%s\n' "$CASE_DIR/etc/runlevels"
}

service_enablement_runit_link() {
    printf '%s\n' "${TEST_ENABLE_LINK:-$CASE_DIR/runsvdir/mihomo}"
}

service_enablement_systemd_unit_path() {
    printf '%s\n' "$TEST_TARGET"
}

service_enablement_sysv_service_path() {
    printf '%s/init.d/%s\n' "$CASE_DIR/etc" "$1"
}

service_enablement_openrc_service_path() {
    printf '%s/init.d/%s\n' "$CASE_DIR/etc" "$1"
}

service_enablement_runit_service_path() {
    printf '%s/sv/%s\n' "$CASE_DIR/etc" "$1"
}

_test_systemd_has_link() {
    local root=$1 link
    for link in "$root"/*.wants/mihomo.service "$root"/*.requires/mihomo.service; do
        [ -L "$link" ] && return 0
    done
    return 1
}

service_enablement_systemd_state() {
    if [ -L "$TEST_TARGET" ] && [ "$(readlink -- "$TEST_TARGET")" = /dev/null ]; then
        printf '%s\n' masked
    elif _test_systemd_has_link "$TEST_SYSTEMD_ETC_ROOT"; then
        printf '%s\n' enabled
    elif _test_systemd_has_link "$TEST_SYSTEMD_RUN_ROOT"; then
        printf '%s\n' enabled-runtime
    else
        printf '%s\n' disabled
    fi
}

_test_systemd_remove_links() {
    local root link
    for root in "$TEST_SYSTEMD_ETC_ROOT" "$TEST_SYSTEMD_RUN_ROOT"; do
        for link in "$root"/*.wants/mihomo.service "$root"/*.requires/mihomo.service; do
            if [ -e "$link" ] || [ -L "$link" ]; then
                /usr/bin/rm -f -- "$link"
            fi
        done
    done
}

_test_systemd_refresh_enabled() {
    local state
    state=$(service_enablement_systemd_state)
    case $state in disabled | not-found | masked | masked-runtime) FAKE_ENABLED=0 ;; *) FAKE_ENABLED=1 ;; esac
}

detect_service_manager() {
    service_manager=$TEST_MANAGER
    service_log_path="$CASE_DIR/service.log"
    service_pid_path="$CASE_DIR/service.pid"
    export service_manager service_log_path service_pid_path
}

_service_target() {
    case $TEST_TARGET in "$WORK_DIR"/*) printf '%s\n' "$TEST_TARGET" ;; *) return 1 ;; esac
}

systemctl() {
    local command=${1:-} arg property='' next_is_property=0
    printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
    case $command in
    is-active) [ "$FAKE_ACTIVE" -eq 1 ] ;;
    is-enabled)
        [ "$FAKE_ENABLEMENT_FROM_LINKS" -eq 0 ] || _test_systemd_refresh_enabled
        [ "$FAKE_ENABLED" -eq 1 ]
        ;;
    stop)
        FAKE_ACTIVE=0
        if [ -n "$SYSTEMD_PID" ]; then
            kill -TERM "$SYSTEMD_PID" 2>/dev/null || true
            wait "$SYSTEMD_PID" 2>/dev/null || true
            SYSTEMD_PID=
        fi
        ;;
    start) FAKE_ACTIVE=1 ;;
    disable)
        _test_systemd_remove_links
        FAKE_ENABLED=0
        ;;
    enable)
        [ "$FAKE_FAIL_ENABLE" -eq 0 ] || return 1
        mkdir -p -- "$(dirname -- "$TEST_SYSTEMD_INSTALLED_LINK")"
        /usr/bin/rm -f -- "$TEST_SYSTEMD_INSTALLED_LINK"
        ln -s -- "$TEST_TARGET" "$TEST_SYSTEMD_INSTALLED_LINK"
        FAKE_ENABLED=1
        ;;
    daemon-reload)
        [ "$FAKE_FAIL_RELOAD" -eq 0 ] || return 1
        [ "$FAKE_ENABLEMENT_FROM_LINKS" -eq 0 ] || _test_systemd_refresh_enabled
        return 0
        ;;
    show)
        for arg in "$@"; do
            if [ "$next_is_property" -eq 1 ]; then
                property=$arg
                break
            fi
            [ "$arg" != -p ] || next_is_property=1
        done
        case $property in
        FragmentPath) printf '%s\n' "$FAKE_FRAGMENT" ;;
        ExecStart) printf '%s\n' "$FAKE_EXECSTART" ;;
        MainPID) printf '%s\n' "$FAKE_MAINPID" ;;
        *) fail "unexpected systemctl property: $*" ;;
        esac
        ;;
    *) fail "unexpected systemctl call: $*" ;;
    esac
}

setup_case() {
    local name=$1
    CASE_DIR="$WORK_DIR/$name"
    TEST_TARGET="$CASE_DIR/etc/systemd/mihomo.service"
    TEST_SYSTEMD_ETC_ROOT="$CASE_DIR/etc/systemd/system"
    TEST_SYSTEMD_RUN_ROOT="$CASE_DIR/run/systemd/system"
    TEST_SYSTEMD_INSTALLED_LINK="$TEST_SYSTEMD_ETC_ROOT/multi-user.target.wants/mihomo.service"
    SYSTEMCTL_LOG="$CASE_DIR/systemctl.log"
    CLASHCTL_HOME="$CASE_DIR/home"
    CLASHCTL_KERNEL=mihomo
    BIN_KERNEL="$CLASHCTL_HOME/bin/mihomo"
    CLASH_RESOURCES_DIR="$CLASHCTL_HOME/resources"
    CLASH_CONFIG_RUNTIME="$CLASHCTL_HOME/data/runtime.yaml"
    service_manager=systemd
    TEST_MANAGER=systemd
    export service_manager
    FAKE_ACTIVE=1
    FAKE_ENABLED=1
    FAKE_FAIL_ENABLE=0
    FAKE_FAIL_RELOAD=0
    FAKE_FRAGMENT=$TEST_TARGET
    FAKE_EXECSTART="{ path=$BIN_KERNEL ; argv[]=$BIN_KERNEL -d $CLASH_RESOURCES_DIR -f $CLASH_CONFIG_RUNTIME ; }"
    FAKE_MAINPID=0
    SYSTEMD_PID=
    SYSTEMD_FEED_PID=
    FAKE_ENABLEMENT_FROM_LINKS=0
    mkdir -p -- \
        "$(dirname -- "$TEST_TARGET")" \
        "$(dirname -- "$BIN_KERNEL")" \
        "$(dirname -- "$CLASH_CONFIG_RUNTIME")" \
        "$TEST_SYSTEMD_ETC_ROOT" "$TEST_SYSTEMD_RUN_ROOT"
    : >"$SYSTEMCTL_LOG"
    export CLASHCTL_HOME CLASHCTL_KERNEL BIN_KERNEL CLASH_RESOURCES_DIR CLASH_CONFIG_RUNTIME
    unset CLASHCTL_REPLACED_SERVICE_SOURCE CLASHCTL_REPLACED_SERVICE_TARGET
    unset CLASHCTL_REPLACED_SERVICE_BACKUP CLASHCTL_REPLACED_SERVICE_WAS_ACTIVE
    unset CLASHCTL_REPLACED_SERVICE_WAS_ENABLED CLASHCTL_REPLACED_SERVICE_ENABLE_LINK
    unset CLASHCTL_REPLACED_SERVICE_ENABLE_KIND CLASHCTL_REPLACED_SERVICE_ENABLE_TARGET
    unset CLASHCTL_REPLACED_SERVICE_EXPECTED_ENABLE_TARGET CLASHCTL_SERVICE_ENABLE_LINK
    unset CLASHCTL_REPLACED_SERVICE_MANAGER CLASHCTL_REPLACED_SERVICE_ENABLEMENT_FORMAT
    unset CLASHCTL_REPLACED_SERVICE_ENABLEMENT_STATE CLASHCTL_REPLACED_SERVICE_ENABLEMENT_LINKS
    unset CLASHCTL_REPLACED_SERVICE_INSTALLED_ENABLEMENT_STATE
    unset CLASHCTL_REPLACED_SERVICE_INSTALLED_ENABLEMENT_LINKS
    unset CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL CLASHCTL_SERVICE_ENABLEMENT_INSTALLED
    unset _SERVICE_REPLACED_ENABLEMENT_MODE _SERVICE_REPLACED_ENABLEMENT_ORIGINAL
    unset _SERVICE_REPLACED_ENABLEMENT_INSTALLED
}

write_installed_target() {
    printf '[Service]\nExecStart=%s -d %s -f %s\n' \
        "$BIN_KERNEL" "$CLASH_RESOURCES_DIR" "$CLASH_CONFIG_RUNTIME" >"$TEST_TARGET"
}

setup_replaced_service() {
    local was_enabled=$1 was_active=$2
    local original_state original_links installed_state installed_links
    local original_link="$TEST_SYSTEMD_RUN_ROOT/multi-user.target.wants/mihomo.service"
    write_installed_target
    CLASHCTL_REPLACED_SERVICE_SOURCE=$TEST_TARGET
    CLASHCTL_REPLACED_SERVICE_TARGET=$TEST_TARGET
    CLASHCTL_REPLACED_SERVICE_BACKUP="$CASE_DIR/original.service.backup"
    CLASHCTL_REPLACED_SERVICE_WAS_ENABLED=$was_enabled
    CLASHCTL_REPLACED_SERVICE_WAS_ACTIVE=$was_active
    export CLASHCTL_REPLACED_SERVICE_SOURCE CLASHCTL_REPLACED_SERVICE_TARGET
    export CLASHCTL_REPLACED_SERVICE_BACKUP CLASHCTL_REPLACED_SERVICE_WAS_ENABLED
    export CLASHCTL_REPLACED_SERVICE_WAS_ACTIVE
    printf '[Service]\nExecStart=/opt/original/mihomo\n' >"$CLASHCTL_REPLACED_SERVICE_BACKUP"
    chmod 0710 "$CLASHCTL_REPLACED_SERVICE_BACKUP"

    FAKE_ENABLEMENT_FROM_LINKS=1
    CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL="$CLASHCTL_HOME/.service-enablement.original"
    CLASHCTL_SERVICE_ENABLEMENT_INSTALLED="$CLASHCTL_HOME/.service-enablement.installed"
    mkdir -p -- "$CLASHCTL_HOME"
    _test_systemd_remove_links
    if [ "$was_enabled" -eq 1 ]; then
        mkdir -p -- "$(dirname -- "$original_link")"
        ln -s -- /opt/original/mihomo.service "$original_link"
    fi
    service_enablement_capture systemd mihomo "$CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL" ||
        fail "cannot capture original enablement fixture: $SERVICE_ENABLEMENT_ERROR"
    original_state=$SERVICE_ENABLEMENT_STATE
    original_links=$SERVICE_ENABLEMENT_LINKS
    mkdir -p -- "$(dirname -- "$TEST_SYSTEMD_INSTALLED_LINK")"
    ln -s -- "$TEST_TARGET" "$TEST_SYSTEMD_INSTALLED_LINK"
    service_enablement_capture systemd mihomo "$CLASHCTL_SERVICE_ENABLEMENT_INSTALLED" ||
        fail "cannot capture installed enablement fixture: $SERVICE_ENABLEMENT_ERROR"
    installed_state=$SERVICE_ENABLEMENT_STATE
    installed_links=$SERVICE_ENABLEMENT_LINKS

    CLASHCTL_REPLACED_SERVICE_MANAGER=systemd
    CLASHCTL_REPLACED_SERVICE_ENABLEMENT_FORMAT=clashctl-service-enablement-v1
    CLASHCTL_REPLACED_SERVICE_ENABLEMENT_STATE=$original_state
    CLASHCTL_REPLACED_SERVICE_ENABLEMENT_LINKS=$original_links
    CLASHCTL_REPLACED_SERVICE_INSTALLED_ENABLEMENT_STATE=$installed_state
    CLASHCTL_REPLACED_SERVICE_INSTALLED_ENABLEMENT_LINKS=$installed_links
    export CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL CLASHCTL_SERVICE_ENABLEMENT_INSTALLED
    export CLASHCTL_REPLACED_SERVICE_MANAGER CLASHCTL_REPLACED_SERVICE_ENABLEMENT_FORMAT
    export CLASHCTL_REPLACED_SERVICE_ENABLEMENT_STATE CLASHCTL_REPLACED_SERVICE_ENABLEMENT_LINKS
    export CLASHCTL_REPLACED_SERVICE_INSTALLED_ENABLEMENT_STATE
    export CLASHCTL_REPLACED_SERVICE_INSTALLED_ENABLEMENT_LINKS
    _test_systemd_refresh_enabled
}

setup_replaced_service_legacy() {
    local was_enabled=$1 was_active=$2
    write_installed_target
    CLASHCTL_REPLACED_SERVICE_SOURCE=$TEST_TARGET
    CLASHCTL_REPLACED_SERVICE_TARGET=$TEST_TARGET
    CLASHCTL_REPLACED_SERVICE_BACKUP="$CASE_DIR/original.service.backup"
    CLASHCTL_REPLACED_SERVICE_WAS_ENABLED=$was_enabled
    CLASHCTL_REPLACED_SERVICE_WAS_ACTIVE=$was_active
    export CLASHCTL_REPLACED_SERVICE_SOURCE CLASHCTL_REPLACED_SERVICE_TARGET
    export CLASHCTL_REPLACED_SERVICE_BACKUP CLASHCTL_REPLACED_SERVICE_WAS_ENABLED
    export CLASHCTL_REPLACED_SERVICE_WAS_ACTIVE
    printf '[Service]\nExecStart=/opt/original/mihomo\n' >"$CLASHCTL_REPLACED_SERVICE_BACKUP"
    chmod 0710 "$CLASHCTL_REPLACED_SERVICE_BACKUP"
    FAKE_ENABLEMENT_FROM_LINKS=0
    FAKE_ENABLED=1
}

test_missing_backup_has_no_side_effects() {
    setup_case missing-backup
    setup_replaced_service 1 1
    local installed_copy="$CASE_DIR/installed.copy" rc=0
    cp -a -- "$TEST_TARGET" "$installed_copy"
    /usr/bin/rm -f -- "$CLASHCTL_REPLACED_SERVICE_BACKUP"

    uninstall_service >"$CASE_DIR/stdout" 2>"$CASE_DIR/stderr" || rc=$?
    assert_eq 1 "$rc" 'missing original backup aborts uninstall'
    cmp -s -- "$installed_copy" "$TEST_TARGET" || fail 'target changed before backup preflight'
    assert_not_contains "$SYSTEMCTL_LOG" 'stop mihomo' 'service was stopped before backup preflight'
    assert_not_contains "$SYSTEMCTL_LOG" 'disable --quiet mihomo' 'service was disabled before backup preflight'
    assert_contains "$CASE_DIR/stderr" '原服务备份不存在' 'missing backup is explained'
}

test_restore_disabled_stopped_state() {
    setup_case restore-disabled
    setup_replaced_service 0 0
    uninstall_service >"$CASE_DIR/stdout" 2>"$CASE_DIR/stderr"
    cmp -s -- "$CLASHCTL_REPLACED_SERVICE_BACKUP" "$TEST_TARGET" ||
        fail 'original definition was not restored'
    assert_eq 710 "$(stat -c %a -- "$TEST_TARGET")" 'original service mode is restored'
    assert_eq 0 "$FAKE_ENABLED" 'original disabled state is restored'
    assert_eq 0 "$FAKE_ACTIVE" 'original stopped state is restored'
    assert_absent "$TEST_SYSTEMD_INSTALLED_LINK" \
        'installed persistent wants link is removed for disabled original service'
    assert_eq disabled "$(service_enablement_systemd_state)" \
        'disabled state is restored exactly'
    [ -f "$CLASHCTL_REPLACED_SERVICE_BACKUP" ] || fail 'backup was deleted before uninstall commit'
}

test_restore_enabled_running_state() {
    setup_case restore-running
    setup_replaced_service 1 1
    uninstall_service >"$CASE_DIR/stdout" 2>"$CASE_DIR/stderr"
    assert_eq 1 "$FAKE_ENABLED" 'original enabled state is restored'
    assert_eq 1 "$FAKE_ACTIVE" 'original running state is restored'
    assert_contains "$SYSTEMCTL_LOG" 'stop mihomo' 'installed service is stopped'
    assert_contains "$SYSTEMCTL_LOG" 'start mihomo' 'original service is restarted'
    assert_link "$TEST_SYSTEMD_RUN_ROOT/multi-user.target.wants/mihomo.service" \
        /opt/original/mihomo.service 'original runtime wants link is restored exactly'
    assert_absent "$TEST_SYSTEMD_INSTALLED_LINK" \
        'installed persistent wants link is removed after original restore'
    assert_eq enabled-runtime "$(service_enablement_systemd_state)" \
        'runtime enablement state survives uninstall'
    [ -f "$CLASHCTL_REPLACED_SERVICE_BACKUP" ] || fail 'successful restore removed commit backup early'
}

test_restore_failure_retains_backup() {
    setup_case restore-failure
    setup_replaced_service 1 1
    FAKE_FAIL_RELOAD=1
    local rc=0
    uninstall_service >"$CASE_DIR/stdout" 2>"$CASE_DIR/stderr" || rc=$?
    assert_eq 1 "$rc" 'failed systemd reload aborts uninstall'
    [ -f "$CLASHCTL_REPLACED_SERVICE_BACKUP" ] || fail 'restore failure removed original backup'
    cmp -s -- "$CLASHCTL_REPLACED_SERVICE_BACKUP" "$TEST_TARGET" ||
        fail 'definition restore did not complete before enabled-state failure'
    assert_contains "$CASE_DIR/stderr" '未能完整恢复' 'partial restore is reported'
}

test_missing_owned_target_refuses_unknown_active_service() {
    setup_case missing-target
    FAKE_ACTIVE=1
    FAKE_ENABLED=1
    FAKE_FRAGMENT="$CASE_DIR/vendor/mihomo.service"
    FAKE_EXECSTART='{ path=/opt/vendor/mihomo ; argv[]=/opt/vendor/mihomo ; }'
    FAKE_MAINPID=9876
    local rc=0
    uninstall_service >"$CASE_DIR/stdout" 2>"$CASE_DIR/stderr" || rc=$?
    assert_eq 1 "$rc" 'missing unit with unknown active process is rejected'
    assert_eq 1 "$FAKE_ACTIVE" 'unrelated same-name service remains active'
    assert_eq 1 "$FAKE_ENABLED" 'unrelated same-name service remains enabled'
    assert_not_contains "$SYSTEMCTL_LOG" 'stop mihomo' 'missing owned target does not stop provider service'
    assert_not_contains "$SYSTEMCTL_LOG" 'disable --quiet mihomo' 'missing owned target does not disable provider service'
    assert_contains "$CASE_DIR/stderr" '无法确认进程归属' 'ownership refusal is explained'
    assert_not_contains "$CASE_DIR/stderr" '已注销' 'refused uninstall does not report success'
}

test_missing_target_stops_proven_loaded_service() {
    setup_case missing-target-owned
    local input_fifo="$CASE_DIR/kernel.input"
    cp -- /usr/bin/grep "$BIN_KERNEL"
    chmod 0700 "$BIN_KERNEL"
    CLASH_RESOURCES_DIR=skip
    printf '%s\n' never-match >"$CLASH_CONFIG_RUNTIME"
    mkfifo -- "$input_fifo"
    sleep 30 >"$input_fifo" &
    SYSTEMD_FEED_PID=$!
    "$BIN_KERNEL" -d "$CLASH_RESOURCES_DIR" -f "$CLASH_CONFIG_RUNTIME" \
        <"$input_fifo" >/dev/null &
    SYSTEMD_PID=$!
    FAKE_MAINPID=$SYSTEMD_PID
    FAKE_EXECSTART="{ path=$BIN_KERNEL ; argv[]=$BIN_KERNEL -d $CLASH_RESOURCES_DIR -f $CLASH_CONFIG_RUNTIME ; }"
    FAKE_ACTIVE=1
    FAKE_ENABLED=1

    uninstall_service >"$CASE_DIR/stdout" 2>"$CASE_DIR/stderr"
    assert_eq 0 "$FAKE_ACTIVE" 'proven loaded clashctl service is stopped'
    assert_eq 0 "$FAKE_ENABLED" 'proven loaded clashctl service is disabled'
    assert_contains "$SYSTEMCTL_LOG" 'stop mihomo' 'proven loaded service receives stop'
    [ -z "$SYSTEMD_PID" ] || fail 'systemd stop stub retained the proven process PID'
    kill -TERM "$SYSTEMD_FEED_PID" 2>/dev/null || true
    wait "$SYSTEMD_FEED_PID" 2>/dev/null || true
    SYSTEMD_FEED_PID=
}

test_normal_uninstall_removes_owned_service() {
    setup_case normal
    write_installed_target
    mkdir -p -- "$(dirname -- "$TEST_SYSTEMD_INSTALLED_LINK")"
    ln -s -- "$TEST_TARGET" "$TEST_SYSTEMD_INSTALLED_LINK"
    FAKE_ENABLEMENT_FROM_LINKS=1
    uninstall_service >"$CASE_DIR/stdout" 2>"$CASE_DIR/stderr"
    [ ! -e "$TEST_TARGET" ] || fail 'owned service definition was not removed'
    assert_eq 0 "$FAKE_ACTIVE" 'owned service is stopped'
    assert_absent "$TEST_SYSTEMD_INSTALLED_LINK" 'owned enablement link is removed'
    assert_eq disabled "$(service_enablement_systemd_state)" 'owned service is disabled'
}

test_binary_path_in_comment_does_not_prove_ownership() {
    setup_case foreign-comment
    printf '# old path: %s\n[Service]\nExecStart=/opt/foreign/mihomo\n' \
        "$BIN_KERNEL" >"$TEST_TARGET"
    local rc=0
    uninstall_service >"$CASE_DIR/stdout" 2>"$CASE_DIR/stderr" || rc=$?
    assert_eq 1 "$rc" 'binary path in a comment does not prove service ownership'
    [ -e "$TEST_TARGET" ] || fail 'foreign service definition was deleted'
    assert_eq 1 "$FAKE_ACTIVE" 'foreign service was not stopped'
    assert_not_contains "$SYSTEMCTL_LOG" 'stop mihomo' 'foreign commented unit receives no stop'
}

test_administrator_link_change_blocks_uninstall() {
    local external_target=/opt/administrator/mihomo.service rc=0 installed_copy
    setup_case enablement-conflict
    setup_replaced_service 0 0
    installed_copy="$CASE_DIR/installed.copy"
    cp -a -- "$TEST_TARGET" "$installed_copy"
    /usr/bin/rm -f -- "$TEST_SYSTEMD_INSTALLED_LINK"
    ln -s -- "$external_target" "$TEST_SYSTEMD_INSTALLED_LINK"

    uninstall_service >"$CASE_DIR/stdout" 2>"$CASE_DIR/stderr" || rc=$?
    assert_eq 1 "$rc" 'administrator-modified wants link blocks uninstall'
    assert_link "$TEST_SYSTEMD_INSTALLED_LINK" "$external_target" \
        'administrator-modified wants link is preserved'
    cmp -s -- "$installed_copy" "$TEST_TARGET" ||
        fail 'service definition changed before enablement conflict preflight'
    assert_eq 1 "$FAKE_ACTIVE" 'enablement conflict does not stop the installed service'
    assert_not_contains "$SYSTEMCTL_LOG" 'stop mihomo' \
        'enablement conflict is detected before stopping the service'
    assert_not_contains "$SYSTEMCTL_LOG" 'disable --quiet mihomo' \
        'enablement conflict is detected before disabling the service'
    assert_exists "$CLASHCTL_REPLACED_SERVICE_BACKUP" \
        'enablement conflict retains original definition backup'
    assert_exists "$CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL" \
        'enablement conflict retains original enablement snapshot'
    assert_exists "$CLASHCTL_SERVICE_ENABLEMENT_INSTALLED" \
        'enablement conflict retains installed enablement snapshot'
    assert_contains "$CASE_DIR/stderr" '拒绝' 'enablement conflict explains the refusal'
}

test_legacy_enablement_fields_still_restore() {
    setup_case legacy-enable-fields
    setup_replaced_service_legacy 1 1

    uninstall_service >"$CASE_DIR/stdout" 2>"$CASE_DIR/stderr"
    assert_eq 1 "$FAKE_ENABLED" 'legacy enabled boolean is restored'
    assert_eq 1 "$FAKE_ACTIVE" 'legacy active boolean is restored'
    assert_contains "$SYSTEMCTL_LOG" 'enable --quiet mihomo' \
        'legacy metadata uses the compatibility enable path'
    [ "${CLASHCTL_REPLACED_SERVICE_MANAGER+x}" != x ] ||
        fail 'legacy fixture unexpectedly published precise manager metadata'
}

test_runit_restored_link_survives_uninstall_retry() {
    local original_target='../../legacy/services/mihomo'
    local disable_calls=0 start_calls=0 rc=0
    setup_case runit-retry
    TEST_MANAGER=runit
    TEST_ENABLE_LINK="$CASE_DIR/runsvdir/mihomo"
    mkdir -p -- "$(dirname -- "$TEST_ENABLE_LINK")"
    printf 'exec %s -d %s -f %s >%s 2>&1\n' \
        "$BIN_KERNEL" "$CLASH_RESOURCES_DIR" "$CLASH_CONFIG_RUNTIME" \
        "$CASE_DIR/service.log" >"$TEST_TARGET"
    CLASHCTL_REPLACED_SERVICE_SOURCE=$TEST_TARGET
    CLASHCTL_REPLACED_SERVICE_TARGET=$TEST_TARGET
    CLASHCTL_REPLACED_SERVICE_BACKUP="$CASE_DIR/original.service.backup"
    CLASHCTL_REPLACED_SERVICE_WAS_ENABLED=1
    CLASHCTL_REPLACED_SERVICE_WAS_ACTIVE=1
    CLASHCTL_REPLACED_SERVICE_ENABLE_LINK=$TEST_ENABLE_LINK
    CLASHCTL_REPLACED_SERVICE_ENABLE_KIND=symlink
    CLASHCTL_REPLACED_SERVICE_ENABLE_TARGET=$original_target
    CLASHCTL_REPLACED_SERVICE_EXPECTED_ENABLE_TARGET=$(dirname -- "$TEST_TARGET")
    CLASHCTL_SERVICE_ENABLE_LINK=$TEST_ENABLE_LINK
    export CLASHCTL_REPLACED_SERVICE_SOURCE CLASHCTL_REPLACED_SERVICE_TARGET
    export CLASHCTL_REPLACED_SERVICE_BACKUP CLASHCTL_REPLACED_SERVICE_WAS_ENABLED
    export CLASHCTL_REPLACED_SERVICE_WAS_ACTIVE CLASHCTL_REPLACED_SERVICE_ENABLE_LINK
    export CLASHCTL_REPLACED_SERVICE_ENABLE_KIND CLASHCTL_REPLACED_SERVICE_ENABLE_TARGET
    export CLASHCTL_REPLACED_SERVICE_EXPECTED_ENABLE_TARGET CLASHCTL_SERVICE_ENABLE_LINK
    printf '%s\n' '# original runit service' >"$CLASHCTL_REPLACED_SERVICE_BACKUP"
    ln -s -- "$CLASHCTL_REPLACED_SERVICE_EXPECTED_ENABLE_TARGET" "$TEST_ENABLE_LINK"
    FAKE_ACTIVE=1

    service_is_active() { [ "$FAKE_ACTIVE" -eq 1 ]; }
    service_stop() { FAKE_ACTIVE=0; }
    service_start() {
        start_calls=$((start_calls + 1))
        [ "$start_calls" -gt 1 ] || return 1
        FAKE_ACTIVE=1
    }
    service_is_enabled() { [ -L "$TEST_ENABLE_LINK" ]; }
    service_disable() {
        disable_calls=$((disable_calls + 1))
        /usr/bin/rm -f -- "$TEST_ENABLE_LINK"
    }

    uninstall_service >"$CASE_DIR/first.stdout" 2>"$CASE_DIR/first.stderr" || rc=$?
    assert_eq 1 "$rc" 'first uninstall reports original runit start failure'
    assert_eq "$original_target" "$(readlink -- "$TEST_ENABLE_LINK")" \
        'first uninstall leaves the restored original runit link intact'
    assert_eq 1 "$disable_calls" 'first uninstall disables only the clashctl link'

    uninstall_service >"$CASE_DIR/second.stdout" 2>"$CASE_DIR/second.stderr"
    assert_eq "$original_target" "$(readlink -- "$TEST_ENABLE_LINK")" \
        'retry preserves the restored original runit link'
    assert_eq 1 "$disable_calls" 'retry does not disable the already restored original link'
    assert_eq 1 "$FAKE_ACTIVE" 'retry starts the original runit service'
}

test_missing_backup_has_no_side_effects
test_restore_disabled_stopped_state
test_restore_enabled_running_state
test_restore_failure_retains_backup
test_missing_owned_target_refuses_unknown_active_service
test_missing_target_stops_proven_loaded_service
test_normal_uninstall_removes_owned_service
test_binary_path_in_comment_does_not_prove_ownership
test_administrator_link_change_blocks_uninstall
test_legacy_enablement_fields_still_restore
test_runit_restored_link_survives_uninstall_retry

printf 'service-uninstall: ok\n'
