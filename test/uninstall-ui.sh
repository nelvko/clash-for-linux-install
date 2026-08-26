#!/usr/bin/env bash
set -eo pipefail

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
    grep -Fqs -- "$expected" "$file" || fail "$description: missing [$expected]"
}

assert_not_contains() {
    local file=$1 unexpected=$2 description=$3
    if grep -Fqs -- "$unexpected" "$file"; then
        fail "$description: unexpectedly found [$unexpected]"
    fi
}

export CLASHCTL_KERNEL=mihomo CLASHCTL_UNINSTALL_SOURCE_ONLY=1 CLASHCTL_COLOR=never
# shellcheck source=../uninstall.sh
. "$REPO_DIR/uninstall.sh"

test_managed_shell_cleanup() {
    local home="$WORK_DIR/shell-home" rc="$WORK_DIR/shell-home/.bashrc"
    mkdir -p -- "$home"
    CLASHCTL_HOME="$WORK_DIR/clash home"
    export CLASHCTL_HOME
    cat >"$rc" <<EOF
export USER_SETTING=keep
echo "custom CLASHCTL_HOME note"
# >>> clashctl >>>
export CLASHCTL_HOME=/old/path
[ -s "\$CLASHCTL_HOME/scripts/cmd/clashctl.sh" ] && . "\$CLASHCTL_HOME/scripts/cmd/clashctl.sh"
# <<< clashctl <<<
export CLASHCTL_HOME=$CLASHCTL_HOME
[ -s "\$CLASHCTL_HOME/scripts/cmd/clashctl.sh" ] && . "\$CLASHCTL_HOME/scripts/cmd/clashctl.sh"
# >>> clashctl >>>
incomplete=user-content
EOF

    _remove_source_block "$rc"
    assert_contains "$rc" 'export USER_SETTING=keep' 'unrelated shell setting is preserved'
    assert_contains "$rc" 'custom CLASHCTL_HOME note' 'user text mentioning CLASHCTL_HOME is preserved'
    assert_contains "$rc" '# >>> clashctl >>>' 'incomplete managed block is preserved'
    assert_contains "$rc" 'incomplete=user-content' 'incomplete block content is preserved'
    assert_not_contains "$rc" 'export CLASHCTL_HOME=/old/path' 'complete managed block is removed'
    assert_not_contains "$rc" "export CLASHCTL_HOME=$CLASHCTL_HOME" 'legacy export is removed'
}

SERVICE_RESULT=0
SHELL_RESULT=0
CRON_RESULT=0
CRON_STATE=absent
SERVICE_CALLS=0
SHELL_CALLS=0
REMOVE_MARKER_ON_REVOKE=0
RESTORE_PREFLIGHT_RESULT=0
RESTORE_PREFLIGHT_CALLS=0

_is_root() { return 0; }
tunstatus() { return 1; }
uninstall_replaced_service_preflight() {
    RESTORE_PREFLIGHT_CALLS=$((RESTORE_PREFLIGHT_CALLS + 1))
    return "$RESTORE_PREFLIGHT_RESULT"
}
uninstall_service() {
    SERVICE_CALLS=$((SERVICE_CALLS + 1))
    return "$SERVICE_RESULT"
}
revoke_rc() {
    SHELL_CALLS=$((SHELL_CALLS + 1))
    if [ "$REMOVE_MARKER_ON_REVOKE" -eq 1 ]; then
        /usr/bin/rm -f -- "$CLASHCTL_HOME/.clashctl-installation"
    fi
    return "$SHELL_RESULT"
}
_uninstall_legacy_cron() {
    _UNINSTALL_CRON_STATE=$CRON_STATE
    return "$CRON_RESULT"
}

setup_install() {
    local name=$1
    CLASHCTL_HOME="$WORK_DIR/$name/home"
    CLASHCTL_SRC=$REPO_DIR
    CLASHCTL_REPLACED_SERVICE_BACKUP="$WORK_DIR/$name/original.service.backup"
    export CLASHCTL_HOME CLASHCTL_SRC CLASHCTL_REPLACED_SERVICE_BACKUP
    mkdir -p -- "$CLASHCTL_HOME/scripts/lib" "$CLASHCTL_HOME/scripts/cmd"
    : >"$CLASHCTL_HOME/.env"
    : >"$CLASHCTL_HOME/install.sh"
    : >"$CLASHCTL_HOME/uninstall.sh"
    : >"$CLASHCTL_HOME/scripts/preflight.sh"
    : >"$CLASHCTL_HOME/scripts/lib/common.sh"
    : >"$CLASHCTL_HOME/scripts/cmd/off.sh"
    {
        printf 'CLASHCTL_INSTALLATION=clashctl\n'
        printf 'CLASHCTL_INSTALLATION_FORMAT=1\n'
        printf 'CLASHCTL_INSTALLATION_HOME=%s\n' "$CLASHCTL_HOME"
        printf 'CLASHCTL_INSTALLATION_UID=%s\n' "$(id -u)"
    } >"$CLASHCTL_HOME/.clashctl-installation"
    chmod 0600 "$CLASHCTL_HOME/.clashctl-installation"
    printf 'original service\n' >"$CLASHCTL_REPLACED_SERVICE_BACKUP"
    SERVICE_RESULT=0
    SHELL_RESULT=0
    CRON_RESULT=0
    CRON_STATE=absent
    SERVICE_CALLS=0
    SHELL_CALLS=0
    REMOVE_MARKER_ON_REVOKE=0
    RESTORE_PREFLIGHT_RESULT=0
    RESTORE_PREFLIGHT_CALLS=0
}

test_missing_marker_is_rejected() {
    setup_install missing-marker
    /usr/bin/rm -f -- "$CLASHCTL_HOME/.clashctl-installation"
    local stderr="$WORK_DIR/missing-marker/stderr" rc=0
    main --yes >"$WORK_DIR/missing-marker/stdout" 2>"$stderr" || rc=$?
    assert_eq 1 "$rc" 'unmarked directory is rejected'
    assert_eq 0 "$SERVICE_CALLS" 'unmarked directory is rejected before service changes'
    [ -d "$CLASHCTL_HOME" ] || fail 'unmarked directory was deleted'
    assert_contains "$stderr" '身份、结构、归属或权限校验失败' 'marker rejection is actionable'
}

test_unknown_option_uses_stderr() {
    setup_install unknown-option
    local stdout="$WORK_DIR/unknown-option/stdout" stderr="$WORK_DIR/unknown-option/stderr" rc=0
    main --definitely-unknown >"$stdout" 2>"$stderr" || rc=$?
    assert_eq 1 "$rc" 'unknown uninstall option fails'
    [ ! -s "$stdout" ] || fail 'unknown uninstall option polluted stdout with usage text'
    assert_contains "$stderr" 'Usage:' 'unknown uninstall option writes usage to stderr'
    assert_eq 0 "$SERVICE_CALLS" 'unknown uninstall option does not touch the service'
}

test_target_swap_before_delete_is_rejected() {
    setup_install target-swap
    REMOVE_MARKER_ON_REVOKE=1
    local stderr="$WORK_DIR/target-swap/stderr" rc=0
    main --yes >"$WORK_DIR/target-swap/stdout" 2>"$stderr" || rc=$?
    assert_eq 1 "$rc" 'identity change before recursive deletion aborts uninstall'
    [ -d "$CLASHCTL_HOME" ] || fail 'changed installation directory was deleted'
    assert_contains "$stderr" '卸载期间安装目录发生变化' 'identity race is explained'
}

test_explicit_legacy_uninstall() {
    setup_install legacy
    local home=$CLASHCTL_HOME
    /usr/bin/rm -f -- "$CLASHCTL_HOME/.clashctl-installation"
    main --yes --allow-legacy-layout >"$WORK_DIR/legacy/stdout" 2>"$WORK_DIR/legacy/stderr"
    [ ! -e "$home" ] || fail 'explicitly authorized legacy directory was not removed'
}

test_noninteractive_requires_confirmation() {
    setup_install noninteractive
    local stderr="$WORK_DIR/noninteractive/stderr" rc=0
    main >"$WORK_DIR/noninteractive/stdout" 2>"$stderr" || rc=$?
    assert_eq 1 "$rc" 'non-interactive uninstall is rejected without --yes'
    assert_eq 0 "$SERVICE_CALLS" 'service is untouched before explicit authorization'
    [ -d "$CLASHCTL_HOME" ] || fail 'installation directory was removed without authorization'
    assert_contains "$stderr" '非交互卸载需要显式确认' 'authorization failure is actionable'
}

test_service_failure_preserves_everything() {
    setup_install service-failure
    SERVICE_RESULT=1
    local stderr="$WORK_DIR/service-failure/stderr" rc=0
    main --yes >"$WORK_DIR/service-failure/stdout" 2>"$stderr" || rc=$?
    assert_eq 1 "$rc" 'service restore failure aborts uninstall'
    assert_eq 1 "$SERVICE_CALLS" 'service operation was attempted once'
    assert_eq 0 "$SHELL_CALLS" 'shell integration is untouched after service failure'
    [ -d "$CLASHCTL_HOME" ] || fail 'installation directory was removed after service failure'
    [ -f "$CLASHCTL_REPLACED_SERVICE_BACKUP" ] || fail 'service backup was removed after failure'
    assert_contains "$stderr" '安装数据已保留' 'service failure reports retained data'
}

test_restore_preflight_failure_blocks_confirmation_and_mutation() {
    setup_install restore-preflight
    RESTORE_PREFLIGHT_RESULT=1
    local stderr="$WORK_DIR/restore-preflight/stderr" rc=0
    main --yes >"$WORK_DIR/restore-preflight/stdout" 2>"$stderr" || rc=$?
    assert_eq 1 "$rc" 'failed original-service preflight aborts uninstall'
    assert_eq 1 "$RESTORE_PREFLIGHT_CALLS" 'original-service preflight runs once'
    assert_eq 0 "$SERVICE_CALLS" 'failed preflight does not touch the service'
    assert_eq 0 "$SHELL_CALLS" 'failed preflight does not touch shell integration'
    [ -d "$CLASHCTL_HOME" ] || fail 'failed preflight removed installation data'
    assert_contains "$stderr" '卸载尚未开始' 'failed preflight reports the unchanged boundary'
}

test_late_cleanup_failure_preserves_recovery_material() {
    setup_install cleanup-failure
    SHELL_RESULT=1
    local stderr="$WORK_DIR/cleanup-failure/stderr" rc=0
    main --yes >"$WORK_DIR/cleanup-failure/stdout" 2>"$stderr" || rc=$?
    assert_eq 1 "$rc" 'shell cleanup failure is reported'
    assert_eq 1 "$SERVICE_CALLS" 'service step completed before shell cleanup'
    [ -d "$CLASHCTL_HOME" ] || fail 'installation data was removed after cleanup failure'
    [ -f "$CLASHCTL_REPLACED_SERVICE_BACKUP" ] || fail 'backup was removed before uninstall commit'
    assert_contains "$stderr" '服务处理已完成' 'partial completion is reported precisely'
}

test_unavailable_cron_uses_partial_summary() {
    setup_install cron-unavailable
    CRON_STATE=unavailable
    local home=$CLASHCTL_HOME stderr="$WORK_DIR/cron-unavailable/stderr"
    main --yes >"$WORK_DIR/cron-unavailable/stdout" 2>"$stderr"
    [ ! -e "$home" ] || fail 'uninstall without crontab retained installation data'
    assert_contains "$stderr" '未安装 crontab 命令' \
        'unavailable crontab command is reported without claiming cleanup'
    assert_contains "$stderr" '核心已卸载，但旧版定时任务状态未能确认' \
        'unavailable crontab changes the terminal summary'
    assert_not_contains "$stderr" '命令入口与旧版定时任务已清理' \
        'unavailable crontab is not reported as cleaned'
}

test_unreadable_cron_preserves_installation() {
    setup_install cron-unreadable
    CRON_STATE=unreadable
    local stderr="$WORK_DIR/cron-unreadable/stderr" rc=0
    main --yes >"$WORK_DIR/cron-unreadable/stdout" 2>"$stderr" || rc=$?
    assert_eq 1 "$rc" 'unreadable crontab blocks data deletion'
    [ -d "$CLASHCTL_HOME" ] || fail 'unreadable crontab did not preserve installation data'
    assert_contains "$stderr" '无法读取当前用户的 crontab' \
        'unreadable crontab is diagnosed precisely'
    assert_contains "$stderr" '定时任务状态未知；安装数据已保留' \
        'unreadable crontab reports the preserved boundary'
}

test_signal_summary_reports_stage() {
    setup_install 'signal summary'
    local stderr="$WORK_DIR/signal-summary/stderr" rc=0
    mkdir -p -- "$(dirname -- "$stderr")"
    (
        _uninstall_enable_signal_summary "$CLASHCTL_REPLACED_SERVICE_BACKUP"
        _UNINSTALL_STAGE=integration
        kill -INT "$BASHPID"
        exit 99
    ) >"$WORK_DIR/signal-summary/stdout" 2>"$stderr" || rc=$?
    assert_eq 130 "$rc" 'interrupt summary preserves the signal exit status'
    assert_contains "$stderr" '卸载被 INT 信号中断' 'interrupt summary identifies the signal'
    assert_contains "$stderr" '服务处理已完成' 'interrupt summary identifies the completed stage'
    assert_contains "$stderr" '安装数据仍保留' 'interrupt summary identifies retained data'
    assert_contains "$stderr" 'signal\ summary' 'interrupt retry command safely quotes spaces'
}

test_success_commits_data_removal() {
    setup_install success
    local home=$CLASHCTL_HOME backup=$CLASHCTL_REPLACED_SERVICE_BACKUP
    main --yes >"$WORK_DIR/success/stdout" 2>"$WORK_DIR/success/stderr"
    [ ! -e "$home" ] || fail 'successful uninstall retained installation data'
    [ ! -e "$backup" ] || fail 'successful uninstall retained service backup'
    assert_contains "$WORK_DIR/success/stderr" 'clashctl 已卸载' 'successful uninstall is reported'
}

test_managed_shell_cleanup
test_unknown_option_uses_stderr
test_missing_marker_is_rejected
test_target_swap_before_delete_is_rejected
test_explicit_legacy_uninstall
test_noninteractive_requires_confirmation
test_service_failure_preserves_everything
test_restore_preflight_failure_blocks_confirmation_and_mutation
test_late_cleanup_failure_preserves_recovery_material
test_unavailable_cron_uses_partial_summary
test_unreadable_cron_preserves_installation
test_signal_summary_reports_stage
test_success_commits_data_removal

printf 'uninstall-ui: ok\n'
