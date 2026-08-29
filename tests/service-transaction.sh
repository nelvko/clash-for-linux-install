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

assert_exists() {
    [ -e "$1" ] || [ -L "$1" ] || fail "$2: missing [$1]"
}

assert_absent() {
    if [ -e "$1" ] || [ -L "$1" ]; then
        fail "$2: still exists [$1]"
    fi
}

assert_safe_path() {
    case ${1:-} in
    "$WORK_DIR"/*) ;;
    *) fail "$2 escaped the test workspace: [${1:-empty}]" ;;
    esac
}

export CLASHCTL_INSTALL_SOURCE_ONLY=1
# shellcheck source=../install.sh
. "$REPO_DIR/install.sh"
# shellcheck source=../scripts/lib/install-transaction.sh
. "$REPO_DIR/scripts/lib/install-transaction.sh"
# shellcheck source=../scripts/lib/service.sh
. "$REPO_DIR/scripts/lib/service.sh"

TEST_MANAGER=
TEST_SERVICE_TARGET=
TEST_ENABLE_LINK=
TEST_SYSTEMD_ETC_ROOT=
TEST_SYSTEMD_RUN_ROOT=
TEST_SYSTEMD_INSTALLED_LINK=
CASE_DIR=
SYSTEMCTL_LOG=
SV_LOG=
FAKE_ACTIVE=0
FAKE_ENABLED=0
FAKE_FAIL_ENABLE=0
FAKE_FAIL_RELOAD=0
FAKE_RUNNING_DEFINITION=stopped

service_enablement_systemd_persistent_root() {
    assert_safe_path "$TEST_SYSTEMD_ETC_ROOT" 'systemd persistent root'
    printf '%s\n' "$TEST_SYSTEMD_ETC_ROOT"
}

service_enablement_systemd_runtime_root() {
    assert_safe_path "$TEST_SYSTEMD_RUN_ROOT" 'systemd runtime root'
    printf '%s\n' "$TEST_SYSTEMD_RUN_ROOT"
}

service_enablement_sysv_root() {
    printf '%s\n' "$CASE_DIR/etc"
}

service_enablement_openrc_root() {
    printf '%s\n' "$CASE_DIR/etc/runlevels"
}

service_enablement_runit_link() {
    assert_safe_path "$TEST_ENABLE_LINK" 'runit snapshot link'
    printf '%s\n' "$TEST_ENABLE_LINK"
}

service_enablement_systemd_unit_path() {
    assert_safe_path "$TEST_SERVICE_TARGET" 'systemd current unit'
    printf '%s\n' "$TEST_SERVICE_TARGET"
}

service_enablement_sysv_service_path() {
    printf '%s/init.d/%s\n' "$CASE_DIR/etc" "$1"
}

service_enablement_openrc_service_path() {
    printf '%s/init.d/%s\n' "$CASE_DIR/etc" "$1"
}

service_enablement_runit_service_path() {
    printf '%s\n' "$(dirname -- "$TEST_SERVICE_TARGET")"
}

_test_systemd_has_link() {
    local root=$1 link
    for link in "$root"/*.wants/mihomo.service "$root"/*.requires/mihomo.service; do
        [ -L "$link" ] && return 0
    done
    return 1
}

service_enablement_systemd_state() {
    if [ -L "$TEST_SERVICE_TARGET" ] && [ "$(readlink -- "$TEST_SERVICE_TARGET")" = /dev/null ]; then
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
}

_install_service_target() {
    assert_safe_path "$TEST_SERVICE_TARGET" 'installer service target'
    printf '%s\n' "$TEST_SERVICE_TARGET"
}

_service_target() {
    assert_safe_path "$TEST_SERVICE_TARGET" 'service library target'
    printf '%s\n' "$TEST_SERVICE_TARGET"
}

_install_service_enable_link() {
    [ "$1" = runit ] || return 1
    assert_safe_path "$TEST_ENABLE_LINK" 'runit enable link'
    printf '%s\n' "$TEST_ENABLE_LINK"
}

_install_existing_service() {
    local target=$2
    assert_safe_path "$target" 'existing service probe'
    if [ -e "$target" ] || [ -L "$target" ]; then
        printf '%s\n' "$target"
        return 0
    fi
    return 1
}

_render_service_unit() {
    local destination=$1
    assert_safe_path "$destination" 'rendered service candidate'
    printf '# clashctl test unit\nExecStart=%s -d %s\n' \
        "$BIN_KERNEL" "$CLASH_RESOURCES_DIR" >"$destination"
}

systemctl() {
    local command=${1:-}
    printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
    case $command in
    is-active)
        [ "$FAKE_ACTIVE" -eq 1 ]
        ;;
    is-enabled)
        _test_systemd_refresh_enabled
        [ "$FAKE_ENABLED" -eq 1 ]
        ;;
    stop)
        FAKE_ACTIVE=0
        FAKE_RUNNING_DEFINITION=stopped
        ;;
    start)
        FAKE_ACTIVE=1
        if grep -Fqs "$BIN_KERNEL" "$TEST_SERVICE_TARGET" 2>/dev/null; then
            FAKE_RUNNING_DEFINITION=clashctl
        else
            FAKE_RUNNING_DEFINITION=original
        fi
        ;;
    enable)
        [ "$FAKE_FAIL_ENABLE" -eq 0 ] || return 1
        mkdir -p -- "$(dirname -- "$TEST_SYSTEMD_INSTALLED_LINK")"
        /usr/bin/rm -f -- "$TEST_SYSTEMD_INSTALLED_LINK"
        ln -s -- "$TEST_SERVICE_TARGET" "$TEST_SYSTEMD_INSTALLED_LINK"
        FAKE_ENABLED=1
        ;;
    disable)
        _test_systemd_remove_links
        FAKE_ENABLED=0
        ;;
    daemon-reload)
        [ "$FAKE_FAIL_RELOAD" -eq 0 ] || return 1
        _test_systemd_refresh_enabled
        ;;
    show)
        case " $* " in
        *' --property=ActiveState '*)
            [ "$FAKE_ACTIVE" -eq 1 ] && printf '%s\n' active || printf '%s\n' inactive
            ;;
        *) printf '%s\n' "$TEST_SERVICE_TARGET" ;;
        esac
        ;;
    reset-failed)
        return 0
        ;;
    *)
        fail "unexpected systemctl call: $*"
        ;;
    esac
}

sv() {
    local command=${1:-}
    printf '%s\n' "$*" >>"$SV_LOG"
    case $command in
    status)
        if [ "$FAKE_ACTIVE" -eq 1 ]; then
            printf 'run: %s: (pid 4242) 1s\n' "$CLASHCTL_KERNEL"
        else
            printf 'down: %s: 1s\n' "$CLASHCTL_KERNEL"
        fi
        ;;
    up)
        FAKE_ACTIVE=1
        FAKE_RUNNING_DEFINITION=clashctl
        ;;
    down)
        FAKE_ACTIVE=0
        FAKE_RUNNING_DEFINITION=stopped
        ;;
    *)
        fail "unexpected sv call: $*"
        ;;
    esac
}

setup_case() {
    local manager=$1
    CASE_DIR=$(mktemp -d "$WORK_DIR/${manager}.XXXXXX")
    assert_safe_path "$CASE_DIR" 'case directory'
    TEST_MANAGER=$manager
    TEST_SERVICE_TARGET="$CASE_DIR/etc/service/mihomo"
    TEST_ENABLE_LINK="$CASE_DIR/etc/runsvdir/mihomo"
    TEST_SYSTEMD_ETC_ROOT="$CASE_DIR/etc/systemd/system"
    TEST_SYSTEMD_RUN_ROOT="$CASE_DIR/run/systemd/system"
    TEST_SYSTEMD_INSTALLED_LINK="$TEST_SYSTEMD_ETC_ROOT/multi-user.target.wants/mihomo.service"
    SYSTEMCTL_LOG="$CASE_DIR/systemctl.log"
    SV_LOG="$CASE_DIR/sv.log"

    HOME="$CASE_DIR/user-home"
    CLASHCTL_HOME="$CASE_DIR/clashctl-home"
    CLASHCTL_SRC="$CASE_DIR/source"
    CLASHCTL_KERNEL=mihomo
    CLASH_DATA_DIR="$CLASHCTL_HOME/data"
    CLASH_RESOURCES_DIR="$CLASHCTL_HOME/resources"
    CLASH_CONFIG_RUNTIME="$CLASH_DATA_DIR/runtime.yaml"
    BIN_KERNEL="$CLASHCTL_HOME/bin/mihomo"
    TMPDIR="$CASE_DIR/tmp"
    INIT_TYPE=$manager
    # shellcheck disable=SC2034  # consumed dynamically by the sourced service library
    service_manager=$manager service_log_path="$CASE_DIR/service.log" service_pid_path="$CASE_DIR/service.pid"
    CLASHCTL_ALLOW_UNIT_OVERWRITE=1
    CLASHCTL_NON_INTERACTIVE=1
    CLASHCTL_COLOR=never
    FAKE_ACTIVE=0
    FAKE_ENABLED=0
    FAKE_FAIL_ENABLE=0
    FAKE_FAIL_RELOAD=0
    FAKE_RUNNING_DEFINITION=stopped
    _INSTALL_SERVICE_TRANSACTION=0

    unset CLASHCTL_SERVICE_MANAGER CLASHCTL_SERVICE_TARGET
    unset CLASHCTL_SERVICE_TARGET_EXISTED CLASHCTL_SERVICE_SOURCE
    unset CLASHCTL_SERVICE_BACKUP CLASHCTL_SERVICE_BACKUP_CREATED
    unset CLASHCTL_SERVICE_WAS_ACTIVE CLASHCTL_SERVICE_WAS_ENABLED
    unset CLASHCTL_SERVICE_CONFLICT CLASHCTL_SERVICE_ENABLE_LINK
    unset CLASHCTL_SERVICE_ENABLE_KIND CLASHCTL_SERVICE_ENABLE_TARGET
    unset CLASHCTL_SERVICE_EXPECTED_ENABLE_TARGET CLASHCTL_SERVICE_JOURNAL
    unset CLASHCTL_SERVICE_JOURNAL_VERSION CLASHCTL_SERVICE_JOURNAL_KERNEL
    unset CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL CLASHCTL_SERVICE_ENABLEMENT_INSTALLED
    unset CLASHCTL_SERVICE_ENABLEMENT_STATE CLASHCTL_SERVICE_ENABLEMENT_LINKS

    mkdir -p -- "$HOME" "$CLASHCTL_HOME" "$CLASH_DATA_DIR" \
        "$CLASH_RESOURCES_DIR" "$(dirname -- "$BIN_KERNEL")" "$TMPDIR" \
        "$(dirname -- "$TEST_SERVICE_TARGET")" "$(dirname -- "$TEST_ENABLE_LINK")" \
        "$TEST_SYSTEMD_ETC_ROOT" "$TEST_SYSTEMD_RUN_ROOT" "$CLASHCTL_SRC"
    cp -- "$REPO_DIR/.env.example" "$CLASHCTL_SRC/.env.example"
    : >"$SYSTEMCTL_LOG"
    : >"$SV_LOG"
    export HOME CLASHCTL_HOME CLASHCTL_SRC CLASHCTL_KERNEL CLASH_DATA_DIR
    export CLASH_RESOURCES_DIR CLASH_CONFIG_RUNTIME BIN_KERNEL TMPDIR INIT_TYPE
    export CLASHCTL_ALLOW_UNIT_OVERWRITE CLASHCTL_NON_INTERACTIVE CLASHCTL_COLOR
}

write_original_service() {
    printf '# original service\nExecStart=/opt/original/mihomo\n' >"$TEST_SERVICE_TARGET"
    chmod 0710 "$TEST_SERVICE_TARGET"
    cp -a -- "$TEST_SERVICE_TARGET" "$CASE_DIR/original.snapshot"
}

begin_takeover() {
    _install_impact_scan "$CLASHCTL_HOME" "$CLASHCTL_KERNEL" "$TEST_MANAGER" \
        >"$CASE_DIR/impact.stdout" 2>"$CASE_DIR/impact.stderr"
    assert_eq 1 "$CLASHCTL_SERVICE_CONFLICT" 'foreign service conflict is captured'

    _install_begin_service_transaction \
        >"$CASE_DIR/begin.stdout" 2>"$CASE_DIR/begin.stderr"
    assert_safe_path "$CLASHCTL_SERVICE_JOURNAL" 'service journal'
    assert_safe_path "$CLASHCTL_SERVICE_BACKUP" 'service backup'
    assert_exists "$CLASHCTL_SERVICE_JOURNAL" 'transaction journal is written before mutation'
    assert_exists "$CLASHCTL_SERVICE_BACKUP" 'original service is backed up before mutation'
    assert_eq "$CLASHCTL_HOME/.service-enablement.original" \
        "$CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL" 'original enablement snapshot uses the fixed path'
    assert_eq '' "$CLASHCTL_SERVICE_ENABLEMENT_INSTALLED" \
        'journal must not claim an installed enablement snapshot before capture'
    assert_contains "$CLASHCTL_SERVICE_JOURNAL" 'CLASHCTL_SERVICE_ENABLEMENT_INSTALLED=' \
        'initial journal records that the installed snapshot is pending'
    assert_exists "$CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL" \
        'original enablement snapshot exists before mutation'
    assert_eq 600 "$(stat -c '%a' "$CLASHCTL_SERVICE_JOURNAL")" 'journal permissions'
    assert_eq 600 "$(stat -c '%a' "$CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL")" \
        'original enablement snapshot permissions'

    _install_stop_existing_service \
        >"$CASE_DIR/stop.stdout" 2>"$CASE_DIR/stop.stderr"
    install_service >"$CASE_DIR/install.stdout" 2>"$CASE_DIR/install.stderr"
    _install_capture_installed_enablement \
        >"$CASE_DIR/installed-enablement.stdout" 2>"$CASE_DIR/installed-enablement.stderr"
    assert_eq "$CLASHCTL_HOME/.service-enablement.installed" \
        "$CLASHCTL_SERVICE_ENABLEMENT_INSTALLED" 'installed snapshot uses the fixed path after capture'
    assert_exists "$CLASHCTL_SERVICE_ENABLEMENT_INSTALLED" \
        'installed enablement snapshot exists before service start'
    assert_eq 600 "$(stat -c '%a' "$CLASHCTL_SERVICE_ENABLEMENT_INSTALLED")" \
        'installed enablement snapshot permissions'
    service_start >"$CASE_DIR/start.stdout" 2>"$CASE_DIR/start.stderr"
    assert_eq 1 "$FAKE_ACTIVE" 'clashctl service is active before late-stage failure'
    assert_eq clashctl "$FAKE_RUNNING_DEFINITION" 'new service definition is running'
}

assert_successful_rollback() {
    local expected_enabled=$1 expected_active=$2 description=$3
    cmp -s -- "$CASE_DIR/original.snapshot" "$TEST_SERVICE_TARGET" ||
        fail "$description: original service content was not restored"
    assert_eq 710 "$(stat -c '%a' "$TEST_SERVICE_TARGET")" \
        "$description: original service mode"
    assert_eq "$expected_enabled" "$FAKE_ENABLED" "$description: enabled state"
    assert_eq "$expected_active" "$FAKE_ACTIVE" "$description: active state"
    if [ "$expected_active" -eq 1 ]; then
        assert_eq original "$FAKE_RUNNING_DEFINITION" "$description: running definition"
    fi
    assert_absent "$CLASHCTL_SERVICE_JOURNAL" "$description: journal cleanup"
    assert_absent "$CLASHCTL_SERVICE_BACKUP" "$description: backup cleanup"
    assert_absent "$CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL" \
        "$description: original enablement snapshot cleanup"
    assert_absent "$CLASHCTL_SERVICE_ENABLEMENT_INSTALLED" \
        "$description: installed enablement snapshot cleanup"
}

create_systemd_original_runtime_link() {
    local target=/opt/original/mihomo.service
    local link="$TEST_SYSTEMD_RUN_ROOT/multi-user.target.wants/mihomo.service"
    mkdir -p -- "$(dirname -- "$link")"
    ln -s -- "$target" "$link"
}

test_systemd_disabled_stopped_late_rollback() {
    setup_case systemd
    write_original_service
    FAKE_ENABLED=0
    FAKE_ACTIVE=0
    begin_takeover

    _install_abort_service_transaction \
        >"$CASE_DIR/abort.stdout" 2>"$CASE_DIR/abort.stderr"
    assert_successful_rollback 0 0 'disabled/stopped late rollback'
    assert_contains "$CASE_DIR/abort.stderr" '已恢复安装前的服务定义、自启与运行状态' \
        'successful late rollback is reported truthfully'
}

test_systemd_enabled_running_late_rollback() {
    setup_case systemd
    write_original_service
    create_systemd_original_runtime_link
    FAKE_ENABLED=1
    FAKE_ACTIVE=1
    FAKE_RUNNING_DEFINITION=original
    begin_takeover
    assert_contains "$SYSTEMCTL_LOG" 'stop mihomo' 'active original service is stopped before takeover'

    _install_abort_service_transaction \
        >"$CASE_DIR/abort.stdout" 2>"$CASE_DIR/abort.stderr"
    assert_successful_rollback 1 1 'enabled/running late rollback'
    assert_eq enabled-runtime "$(service_enablement_systemd_state)" \
        'runtime-enabled state is restored exactly'
    assert_eq /opt/original/mihomo.service \
        "$(readlink -- "$TEST_SYSTEMD_RUN_ROOT/multi-user.target.wants/mihomo.service")" \
        'runtime wants link target is restored byte-for-byte'
    assert_absent "$TEST_SYSTEMD_INSTALLED_LINK" \
        'persistent link created by takeover is removed'
}

test_restore_failure_retains_recovery_material() {
    setup_case systemd
    write_original_service
    create_systemd_original_runtime_link
    FAKE_ENABLED=1
    FAKE_ACTIVE=1
    FAKE_RUNNING_DEFINITION=original
    begin_takeover
    local journal=$CLASHCTL_SERVICE_JOURNAL backup=$CLASHCTL_SERVICE_BACKUP

    FAKE_FAIL_RELOAD=1
    if _install_abort_service_transaction \
        >"$CASE_DIR/abort.stdout" 2>"$CASE_DIR/abort.stderr"; then
        fail 'restore unexpectedly succeeded when systemd reload failed'
    fi
    assert_exists "$journal" 'failed restore retains transaction journal'
    assert_exists "$backup" 'failed restore retains original service backup'
    assert_exists "$CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL" \
        'failed restore retains original enablement snapshot'
    assert_exists "$CLASHCTL_SERVICE_ENABLEMENT_INSTALLED" \
        'failed restore retains installed enablement snapshot'
    assert_contains "$CASE_DIR/abort.stderr" '事务快照和备份均已保留' \
        'failed restore reports retained recovery material'

    FAKE_FAIL_RELOAD=0
    _install_restore_service >"$CASE_DIR/retry.stdout" 2>"$CASE_DIR/retry.stderr"
    assert_successful_rollback 1 1 'retry after restore failure'
}

setup_runit_original() {
    local link_target=$1
    setup_case runit
    write_original_service
    ln -s -- "$link_target" "$TEST_ENABLE_LINK"
    FAKE_ENABLED=1
    FAKE_ACTIVE=0
}

test_runit_relative_link_round_trip() {
    local original_target='../../legacy/services/mihomo'
    setup_runit_original "$original_target"
    begin_takeover
    assert_eq "$(dirname -- "$TEST_SERVICE_TARGET")" "$(readlink -- "$TEST_ENABLE_LINK")" \
        'runit takeover points the enable link at the new service directory'

    _install_abort_service_transaction \
        >"$CASE_DIR/abort.stdout" 2>"$CASE_DIR/abort.stderr"
    assert_eq "$original_target" "$(readlink -- "$TEST_ENABLE_LINK")" \
        'runit relative enable link is restored byte-for-byte'
    cmp -s -- "$CASE_DIR/original.snapshot" "$TEST_SERVICE_TARGET" ||
        fail 'runit original service definition was not restored'
    assert_absent "$CLASHCTL_SERVICE_JOURNAL" 'runit successful rollback cleans journal'
    assert_absent "$CLASHCTL_SERVICE_BACKUP" 'runit successful rollback cleans backup'
}

test_runit_regular_enable_entry_is_rejected() {
    setup_case runit
    write_original_service
    printf 'USER-DATA\n' >"$TEST_ENABLE_LINK"

    if _install_impact_scan "$CLASHCTL_HOME" "$CLASHCTL_KERNEL" runit \
        >"$CASE_DIR/impact.stdout" 2>"$CASE_DIR/impact.stderr"; then
        fail 'runit takeover accepted a regular-file enable entry'
    fi
    assert_eq USER-DATA "$(<"$TEST_ENABLE_LINK")" 'regular enable entry remains unchanged'
    assert_contains "$CASE_DIR/impact.stderr" '无法完整读取现有服务的自启状态' \
        'regular enable entry rejection explains the conflict'
    assert_absent "$CLASHCTL_HOME/.service-transaction" \
        'regular enable entry rejection does not start a transaction'
}

test_runit_external_link_change_blocks_rollback() {
    local original_target='../../legacy/services/mihomo'
    local external_target='../../external/services/mihomo'
    setup_runit_original "$original_target"
    begin_takeover
    local journal=$CLASHCTL_SERVICE_JOURNAL backup=$CLASHCTL_SERVICE_BACKUP

    /usr/bin/rm -f -- "$TEST_ENABLE_LINK"
    ln -s -- "$external_target" "$TEST_ENABLE_LINK"
    if _install_abort_service_transaction \
        >"$CASE_DIR/abort.stdout" 2>"$CASE_DIR/abort.stderr"; then
        fail 'runit rollback overwrote an externally modified enable link'
    fi
    assert_eq "$external_target" "$(readlink -- "$TEST_ENABLE_LINK")" \
        'external runit link change is preserved'
    assert_exists "$journal" 'runit link conflict retains transaction journal'
    assert_exists "$backup" 'runit link conflict retains service backup'
    assert_contains "$CASE_DIR/abort.stderr" '自启' \
        'runit link conflict is reported'
}

test_runit_external_link_change_blocks_install() {
    local original_target='../../legacy/services/mihomo'
    local external_target='../../external/services/mihomo'
    setup_runit_original "$original_target"
    _install_impact_scan "$CLASHCTL_HOME" "$CLASHCTL_KERNEL" runit \
        >"$CASE_DIR/impact.stdout" 2>"$CASE_DIR/impact.stderr"
    _install_begin_service_transaction \
        >"$CASE_DIR/begin.stdout" 2>"$CASE_DIR/begin.stderr"
    _install_stop_existing_service \
        >"$CASE_DIR/stop.stdout" 2>"$CASE_DIR/stop.stderr"
    local journal=$CLASHCTL_SERVICE_JOURNAL backup=$CLASHCTL_SERVICE_BACKUP

    /usr/bin/rm -f -- "$TEST_ENABLE_LINK"
    ln -s -- "$external_target" "$TEST_ENABLE_LINK"
    if install_service >"$CASE_DIR/install.stdout" 2>"$CASE_DIR/install.stderr"; then
        fail 'runit install overwrote an externally modified enable link'
    fi
    assert_eq "$external_target" "$(readlink -- "$TEST_ENABLE_LINK")" \
        'external runit link remains unchanged during failed install'
    cmp -s -- "$CASE_DIR/original.snapshot" "$TEST_SERVICE_TARGET" ||
        fail 'failed runit enable restored the pre-write service definition incorrectly'
    assert_exists "$journal" 'runit install conflict retains transaction journal'
    assert_exists "$backup" 'runit install conflict retains original service backup'

    /usr/bin/rm -f -- "$journal" "$backup" "$TEST_ENABLE_LINK"
    ln -s -- "$original_target" "$TEST_ENABLE_LINK"
    _INSTALL_SERVICE_TRANSACTION=0
    trap - INT TERM HUP
}

test_systemd_external_link_change_blocks_rollback() {
    local external_target=/opt/administrator/mihomo.service
    setup_case systemd
    write_original_service
    begin_takeover
    local journal=$CLASHCTL_SERVICE_JOURNAL backup=$CLASHCTL_SERVICE_BACKUP

    /usr/bin/rm -f -- "$TEST_SYSTEMD_INSTALLED_LINK"
    ln -s -- "$external_target" "$TEST_SYSTEMD_INSTALLED_LINK"
    if _install_abort_service_transaction \
        >"$CASE_DIR/abort.stdout" 2>"$CASE_DIR/abort.stderr"; then
        fail 'systemd rollback overwrote an administrator-modified wants link'
    fi
    assert_eq "$external_target" "$(readlink -- "$TEST_SYSTEMD_INSTALLED_LINK")" \
        'administrator systemd link change is preserved'
    assert_exists "$journal" 'systemd link conflict retains transaction journal'
    assert_exists "$backup" 'systemd link conflict retains service backup'
    assert_exists "$CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL" \
        'systemd link conflict retains original enablement snapshot'
    assert_exists "$CLASHCTL_SERVICE_ENABLEMENT_INSTALLED" \
        'systemd link conflict retains installed enablement snapshot'
    assert_contains "$CASE_DIR/abort.stderr" '自启' \
        'systemd link conflict is reported as an enablement conflict'

    /usr/bin/rm -f -- "$TEST_SYSTEMD_INSTALLED_LINK"
    ln -s -- "$TEST_SERVICE_TARGET" "$TEST_SYSTEMD_INSTALLED_LINK"
    _install_restore_service >"$CASE_DIR/retry.stdout" 2>"$CASE_DIR/retry.stderr"
    assert_successful_rollback 0 0 'retry after systemd link conflict'
}

test_systemd_masked_state_round_trip() {
    setup_case systemd
    ln -s -- /dev/null "$TEST_SERVICE_TARGET"
    cp -a -- "$TEST_SERVICE_TARGET" "$CASE_DIR/original.snapshot"
    FAKE_ACTIVE=0
    begin_takeover
    assert_eq masked "$(manifest_state "$CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL")" \
        'masked original state is captured'
    assert_eq enabled "$(manifest_state "$CLASHCTL_SERVICE_ENABLEMENT_INSTALLED")" \
        'installed persistent state is captured'

    _install_abort_service_transaction \
        >"$CASE_DIR/abort.stdout" 2>"$CASE_DIR/abort.stderr"
    [ -L "$TEST_SERVICE_TARGET" ] || fail 'masked service definition was not restored as a symlink'
    assert_eq /dev/null "$(readlink -- "$TEST_SERVICE_TARGET")" \
        'masked service definition target is restored'
    assert_eq masked "$(service_enablement_systemd_state)" \
        'masked systemd state is restored exactly'
    assert_absent "$TEST_SYSTEMD_INSTALLED_LINK" \
        'takeover wants link is removed when restoring a mask'
    assert_absent "$CLASHCTL_SERVICE_JOURNAL" 'masked rollback cleans journal'
    assert_absent "$CLASHCTL_SERVICE_BACKUP" 'masked rollback cleans backup'
}

test_interrupted_journal_without_installed_snapshot_recovers() {
    local journal
    setup_case systemd
    write_original_service
    _install_impact_scan "$CLASHCTL_HOME" "$CLASHCTL_KERNEL" systemd \
        >"$CASE_DIR/impact.stdout" 2>"$CASE_DIR/impact.stderr"
    _install_begin_service_transaction \
        >"$CASE_DIR/begin.stdout" 2>"$CASE_DIR/begin.stderr"
    _install_stop_existing_service \
        >"$CASE_DIR/stop.stdout" 2>"$CASE_DIR/stop.stderr"
    install_service >"$CASE_DIR/install.stdout" 2>"$CASE_DIR/install.stderr"
    journal=$CLASHCTL_SERVICE_JOURNAL
    assert_eq '' "$CLASHCTL_SERVICE_ENABLEMENT_INSTALLED" \
        'interrupted transaction claims an installed snapshot before capture'
    assert_contains "$journal" 'CLASHCTL_SERVICE_ENABLEMENT_INSTALLED=' \
        'interrupted journal marks the installed snapshot as pending'

    _install_journal_load "$journal" || fail 'pending-snapshot journal was rejected after restart'
    assert_eq '' "$CLASHCTL_SERVICE_ENABLEMENT_INSTALLED" \
        'pending installed snapshot was not preserved by journal load'
    _install_restore_service >"$CASE_DIR/restore.stdout" 2>"$CASE_DIR/restore.stderr"
    assert_successful_rollback 0 0 'rollback with a pending installed snapshot'
    assert_contains "$CASE_DIR/restore.stderr" '补全' \
        'pending installed snapshot recovery is explained'
}

manifest_state() {
    sed -n 's/^state=//p' "$1"
}

test_install_env_persists_exact_enablement_metadata() {
    local original_state original_links installed_state installed_links env_file
    setup_case systemd
    write_original_service
    create_systemd_original_runtime_link
    begin_takeover
    service_enablement_validate systemd mihomo "$CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL" ||
        fail "valid original manifest was rejected: $SERVICE_ENABLEMENT_ERROR"
    original_state=$SERVICE_ENABLEMENT_STATE
    original_links=$SERVICE_ENABLEMENT_LINKS
    service_enablement_validate systemd mihomo "$CLASHCTL_SERVICE_ENABLEMENT_INSTALLED" ||
        fail "valid installed manifest was rejected: $SERVICE_ENABLEMENT_ERROR"
    installed_state=$SERVICE_ENABLEMENT_STATE
    installed_links=$SERVICE_ENABLEMENT_LINKS

    if ! (
        # shellcheck source=../scripts/lib/common.sh
        . "$REPO_DIR/scripts/lib/common.sh"
        _set_envs() {
            # shellcheck disable=SC2317
            return 0
        }
        _write_install_env mihomo iu >"$CASE_DIR/env.stdout" 2>"$CASE_DIR/env.stderr"
    ); then
        fail "install env write failed: $(<"$CASE_DIR/env.stderr")"
    fi
    env_file=$CLASHCTL_SRC/.env
    (
        unset CLASHCTL_REPLACED_SERVICE_MANAGER CLASHCTL_REPLACED_SERVICE_ENABLEMENT_FORMAT
        unset CLASHCTL_REPLACED_SERVICE_ENABLEMENT_STATE CLASHCTL_REPLACED_SERVICE_ENABLEMENT_LINKS
        unset CLASHCTL_REPLACED_SERVICE_INSTALLED_ENABLEMENT_STATE
        unset CLASHCTL_REPLACED_SERVICE_INSTALLED_ENABLEMENT_LINKS
        # shellcheck disable=SC1090
        . "$env_file"
        assert_eq systemd "$CLASHCTL_REPLACED_SERVICE_MANAGER" \
            'install env records the replaced service manager'
        assert_eq clashctl-service-enablement-v1 \
            "$CLASHCTL_REPLACED_SERVICE_ENABLEMENT_FORMAT" \
            'install env records the enablement manifest format'
        assert_eq "$original_state" "$CLASHCTL_REPLACED_SERVICE_ENABLEMENT_STATE" \
            'install env records the original enablement state'
        assert_eq "$original_links" "$CLASHCTL_REPLACED_SERVICE_ENABLEMENT_LINKS" \
            'install env records the original enablement links'
        assert_eq "$installed_state" "$CLASHCTL_REPLACED_SERVICE_INSTALLED_ENABLEMENT_STATE" \
            'install env records the installed enablement state'
        assert_eq "$installed_links" "$CLASHCTL_REPLACED_SERVICE_INSTALLED_ENABLEMENT_LINKS" \
            'install env records the installed enablement links'
    )
    assert_eq enabled-runtime "$original_state" 'env test original state'
    assert_eq enabled "$installed_state" 'env test installed state'
    [ -n "$original_links" ] || fail 'env test original links are empty'
    [ -n "$installed_links" ] || fail 'env test installed links are empty'

    _install_end_service_transaction
    assert_exists "$CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL" \
        'committed install retains original enablement snapshot for uninstall'
    assert_exists "$CLASHCTL_SERVICE_ENABLEMENT_INSTALLED" \
        'committed install retains installed enablement snapshot for uninstall'
    assert_absent "$CLASHCTL_SERVICE_JOURNAL" 'committed install removes transaction journal'
}

test_clean_install_persists_exact_enablement_metadata() {
    local env_file
    setup_case systemd
    _install_impact_scan "$CLASHCTL_HOME" "$CLASHCTL_KERNEL" systemd \
        >"$CASE_DIR/impact.stdout" 2>"$CASE_DIR/impact.stderr"
    assert_eq 0 "$CLASHCTL_SERVICE_CONFLICT" 'clean install has no service conflict'
    _install_begin_service_transaction \
        >"$CASE_DIR/begin.stdout" 2>"$CASE_DIR/begin.stderr"
    install_service >"$CASE_DIR/install.stdout" 2>"$CASE_DIR/install.stderr"
    _install_capture_installed_enablement \
        >"$CASE_DIR/installed-enablement.stdout" 2>"$CASE_DIR/installed-enablement.stderr"

    if ! (
        # shellcheck source=../scripts/lib/common.sh
        . "$REPO_DIR/scripts/lib/common.sh"
        _set_envs() {
            # shellcheck disable=SC2317
            return 0
        }
        _write_install_env mihomo iu >"$CASE_DIR/env.stdout" 2>"$CASE_DIR/env.stderr"
    ); then
        fail "clean install env write failed: $(<"$CASE_DIR/env.stderr")"
    fi
    env_file=$CLASHCTL_SRC/.env
    (
        unset CLASHCTL_REPLACED_SERVICE_MANAGER CLASHCTL_REPLACED_SERVICE_SOURCE
        unset CLASHCTL_REPLACED_SERVICE_TARGET CLASHCTL_REPLACED_SERVICE_BACKUP
        unset CLASHCTL_REPLACED_SERVICE_ENABLEMENT_FORMAT
        unset CLASHCTL_REPLACED_SERVICE_ENABLEMENT_STATE CLASHCTL_REPLACED_SERVICE_ENABLEMENT_LINKS
        unset CLASHCTL_REPLACED_SERVICE_INSTALLED_ENABLEMENT_STATE
        unset CLASHCTL_REPLACED_SERVICE_INSTALLED_ENABLEMENT_LINKS
        # shellcheck disable=SC1090
        . "$env_file"
        assert_eq systemd "${CLASHCTL_REPLACED_SERVICE_MANAGER:-}" \
            'clean install records the service manager'
        assert_eq '' "${CLASHCTL_REPLACED_SERVICE_SOURCE:-}" \
            'clean install records that no service definition was replaced'
        assert_eq "$TEST_SERVICE_TARGET" "${CLASHCTL_REPLACED_SERVICE_TARGET:-}" \
            'clean install records the uninstall target'
        assert_eq clashctl-service-enablement-v1 \
            "${CLASHCTL_REPLACED_SERVICE_ENABLEMENT_FORMAT:-}" \
            'clean install records exact enablement metadata'
        assert_eq disabled "${CLASHCTL_REPLACED_SERVICE_ENABLEMENT_STATE:-}" \
            'clean install records the original disabled state'
        assert_eq enabled "${CLASHCTL_REPLACED_SERVICE_INSTALLED_ENABLEMENT_STATE:-}" \
            'clean install records the installed enabled state'
        [ -n "${CLASHCTL_REPLACED_SERVICE_INSTALLED_ENABLEMENT_LINKS:-}" ] ||
            fail 'clean install did not record its enablement link'
    )

    _install_end_service_transaction
    assert_exists "$CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL" \
        'clean install retains the original enablement snapshot for uninstall'
    assert_exists "$CLASHCTL_SERVICE_ENABLEMENT_INSTALLED" \
        'clean install retains the installed enablement snapshot for uninstall'
    assert_eq 600 "$(stat -c '%a' "$CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL")" \
        'clean install original snapshot permissions'
    assert_eq 600 "$(stat -c '%a' "$CLASHCTL_SERVICE_ENABLEMENT_INSTALLED")" \
        'clean install installed snapshot permissions'
    assert_absent "$CLASHCTL_SERVICE_JOURNAL" \
        'clean install removes the committed transaction journal'
}

test_owned_partial_install_discards_transaction_restore_state() {
    local env_file backup original installed
    setup_case systemd
    printf '# clashctl partial unit\nExecStart=%s -d %s -f %s\n' \
        "$BIN_KERNEL" "$CLASH_RESOURCES_DIR" "$CLASH_CONFIG_RUNTIME" \
        >"$TEST_SERVICE_TARGET"
    mkdir -p -- "$(dirname -- "$TEST_SYSTEMD_INSTALLED_LINK")"
    ln -s -- "$TEST_SERVICE_TARGET" "$TEST_SYSTEMD_INSTALLED_LINK"

    _install_impact_scan "$CLASHCTL_HOME" "$CLASHCTL_KERNEL" systemd \
        >"$CASE_DIR/impact.stdout" 2>"$CASE_DIR/impact.stderr"
    assert_eq 0 "$CLASHCTL_SERVICE_CONFLICT" \
        'owned partial install is not treated as a foreign conflict'
    assert_eq "$TEST_SERVICE_TARGET" "$CLASHCTL_SERVICE_SOURCE" \
        'owned partial install is retained for transaction rollback'
    _install_begin_service_transaction \
        >"$CASE_DIR/begin.stdout" 2>"$CASE_DIR/begin.stderr"
    install_service >"$CASE_DIR/install.stdout" 2>"$CASE_DIR/install.stderr"
    _install_capture_installed_enablement \
        >"$CASE_DIR/installed-enablement.stdout" 2>"$CASE_DIR/installed-enablement.stderr"
    backup=$CLASHCTL_SERVICE_BACKUP
    original=$CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL
    installed=$CLASHCTL_SERVICE_ENABLEMENT_INSTALLED

    if ! (
        # shellcheck source=../scripts/lib/common.sh
        . "$REPO_DIR/scripts/lib/common.sh"
        _set_envs() {
            # shellcheck disable=SC2317
            return 0
        }
        _write_install_env mihomo iu >"$CASE_DIR/env.stdout" 2>"$CASE_DIR/env.stderr"
    ); then
        fail "owned partial install env write failed: $(<"$CASE_DIR/env.stderr")"
    fi
    env_file=$CLASHCTL_SRC/.env
    if grep -q '^CLASHCTL_REPLACED_SERVICE_' "$env_file"; then
        fail 'owned partial install was persisted as an external service to restore'
    fi

    _install_end_service_transaction
    assert_absent "$original" \
        'owned partial install removes its transaction original snapshot after commit'
    assert_absent "$installed" \
        'owned partial install removes its transaction installed snapshot after commit'
    assert_absent "$backup" \
        'owned partial install removes its transaction definition backup after commit'
    assert_absent "$CLASHCTL_SERVICE_JOURNAL" \
        'owned partial install removes its transaction journal after commit'
    assert_exists "$TEST_SYSTEMD_INSTALLED_LINK" \
        'owned partial install remains enabled after the successful refresh'
}

test_journal_load_rejects_corruption() {
    setup_case systemd
    write_original_service
    _install_impact_scan "$CLASHCTL_HOME" "$CLASHCTL_KERNEL" systemd \
        >"$CASE_DIR/impact.stdout" 2>"$CASE_DIR/impact.stderr"
    _install_begin_service_transaction \
        >"$CASE_DIR/begin.stdout" 2>"$CASE_DIR/begin.stderr"
    local journal=$CLASHCTL_SERVICE_JOURNAL backup=$CLASHCTL_SERVICE_BACKUP
    local pristine="$CASE_DIR/journal.pristine" candidate="$CASE_DIR/journal.candidate"
    cp -a -- "$journal" "$pristine"

    _install_journal_load "$journal" || fail 'valid service journal was rejected'
    assert_eq systemd "$CLASHCTL_SERVICE_MANAGER" 'valid journal publishes manager only after validation'
    assert_eq "$TEST_SERVICE_TARGET" "$CLASHCTL_SERVICE_TARGET" 'valid journal publishes target'

    cp -a -- "$pristine" "$journal"
    printf 'CLASHCTL_SERVICE_WAS_ACTIVE=0\n' >>"$journal"
    if _install_journal_load "$journal"; then
        fail 'journal loader accepted a duplicate field'
    fi
    [ "${CLASHCTL_SERVICE_MANAGER+x}" != x ] || fail 'invalid journal retained stale manager state'

    awk '$0 !~ /^CLASHCTL_SERVICE_WAS_ENABLED=/' "$pristine" >"$candidate"
    chmod 0600 "$candidate"
    /bin/mv -f -- "$candidate" "$journal"
    if _install_journal_load "$journal"; then
        fail 'journal loader accepted a missing field'
    fi

    sed 's/^CLASHCTL_SERVICE_WAS_ACTIVE=.*/CLASHCTL_SERVICE_WAS_ACTIVE=2/' \
        "$pristine" >"$candidate"
    chmod 0600 "$candidate"
    /bin/mv -f -- "$candidate" "$journal"
    if _install_journal_load "$journal"; then
        fail 'journal loader accepted an invalid boolean'
    fi

    /usr/bin/rm -f -- "$journal"
    ln -s -- "$pristine" "$journal"
    if _install_journal_load "$journal"; then
        fail 'journal loader accepted a symbolic-link snapshot'
    fi

    /usr/bin/rm -f -- "$journal" "$backup"
    _INSTALL_SERVICE_TRANSACTION=0
    trap - INT TERM HUP
}

test_systemd_disabled_stopped_late_rollback
test_systemd_enabled_running_late_rollback
test_restore_failure_retains_recovery_material
test_runit_relative_link_round_trip
test_runit_regular_enable_entry_is_rejected
test_runit_external_link_change_blocks_rollback
test_runit_external_link_change_blocks_install
test_systemd_external_link_change_blocks_rollback
test_systemd_masked_state_round_trip
test_interrupted_journal_without_installed_snapshot_recovers
test_install_env_persists_exact_enablement_metadata
test_clean_install_persists_exact_enablement_metadata
test_owned_partial_install_discards_transaction_restore_state
test_journal_load_rejects_corruption

printf 'service-transaction: ok\n'
