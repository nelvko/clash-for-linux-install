#!/usr/bin/env bash

SCRIPT_INIT_DIR="${CLASHCTL_HOME}/scripts/init"

_service_kind=
_service_log_file=
_service_pid_file=

_service_kind_from_init() {
    case "$1" in
    *systemd)
        printf '%s\n' "systemd"
        ;;
    *openrc* | *busybox*)
        if [ "$1" = "${1#*busybox}" ] || command -v openrc-init >/dev/null 2>&1; then
            printf '%s\n' "openrc"
            return 0
        fi
        printf '%s\n' "nohup"
        ;;
    *runit)
        printf '%s\n' "runit"
        ;;
    *init)
        printf '%s\n' "sysvinit"
        ;;
    nohup | *)
        printf '%s\n' "nohup"
        ;;
    esac
}

_resolve_init_type() {
    local detected
    detected=$(readlink /proc/1/exe 2>/dev/null || printf '%s\n' "nohup")
    grep -qsE "docker|kubepods|containerd|podman|lxc" /proc/1/cgroup 2>/dev/null && detected='nohup'
    _is_root || detected='nohup'
    basename "$detected"
}

_refresh_service_context() {
    local resolved_init
    resolved_init=$(_resolve_init_type)
    _service_kind=$(_service_kind_from_init "$resolved_init")

    if [ "$_service_kind" = "nohup" ] || ! _is_root; then
        _service_log_file="${CLASH_RESOURCES_DIR}/${KERNEL_NAME}.log"
        _service_pid_file="${CLASH_RESOURCES_DIR}/${KERNEL_NAME}.pid"
    else
        _service_log_file="/var/log/${KERNEL_NAME}.log"
        _service_pid_file="/run/${KERNEL_NAME}.pid"
    fi
}

service_start() {
    _refresh_service_context
    case "$_service_kind" in
    systemd)
        systemctl start "$KERNEL_NAME"
        ;;
    sysvinit)
        service "$KERNEL_NAME" start
        ;;
    openrc)
        rc-service "$KERNEL_NAME" start
        ;;
    runit)
        sv up "$KERNEL_NAME"
        ;;
    nohup | *)
        (
            nohup "$BIN_KERNEL" -d "$CLASH_RESOURCES_DIR" -f "$CLASH_CONFIG_RUNTIME" </dev/null >"$_service_log_file" 2>&1 &
        )
        ;;
    esac
}

service_sudo_start() {
    _is_root && service_start && return 0
    (
        sudo sh -c "nohup '$BIN_KERNEL' -d '$CLASH_RESOURCES_DIR' -f '$CLASH_CONFIG_RUNTIME' </dev/null > '$_service_log_file' 2>&1 &"
        stty opost 2>/dev/null
    )
}

service_sudo_stop() {
    _is_root && service_stop && return 0
    sudo pkill -9 -f "$BIN_KERNEL"
    stty opost 2>/dev/null
}

service_stop() {
    _refresh_service_context
    case "$_service_kind" in
    systemd)
        systemctl stop "$KERNEL_NAME"
        ;;
    sysvinit)
        service "$KERNEL_NAME" stop
        ;;
    openrc)
        rc-service "$KERNEL_NAME" stop
        ;;
    runit)
        sv down "$KERNEL_NAME"
        ;;
    nohup | *)
        pkill -9 -f "$BIN_KERNEL"
        ;;
    esac
}

service_restart() {
    _refresh_service_context
    case "$_service_kind" in
    systemd)
        systemctl restart "$KERNEL_NAME"
        ;;
    sysvinit)
        service "$KERNEL_NAME" restart
        ;;
    openrc)
        rc-service "$KERNEL_NAME" restart
        ;;
    runit)
        sv restart "$KERNEL_NAME"
        ;;
    nohup | *)
        service_stop >/dev/null 2>&1
        sleep 0.1
        service_start
        ;;
    esac
}

service_status() {
    _refresh_service_context
    case "$_service_kind" in
    systemd)
        systemctl status "$KERNEL_NAME" "$@"
        ;;
    sysvinit)
        service "$KERNEL_NAME" status "$@"
        ;;
    openrc)
        rc-service "$KERNEL_NAME" status "$@"
        ;;
    runit)
        sv status "$KERNEL_NAME" "$@"
        ;;
    nohup | *)
        pgrep -fa "$BIN_KERNEL"
        ;;
    esac
}

service_is_active() {
    _refresh_service_context
    case "$_service_kind" in
    systemd)
        systemctl is-active "$KERNEL_NAME" >/dev/null 2>&1
        ;;
    sysvinit)
        service "$KERNEL_NAME" status >/dev/null 2>&1
        ;;
    openrc)
        rc-service "$KERNEL_NAME" status >/dev/null 2>&1
        ;;
    runit)
        sv status "$KERNEL_NAME" 2>/dev/null | grep -qs '^run'
        ;;
    nohup | *)
        pgrep -fa "$BIN_KERNEL" >/dev/null 2>&1
        ;;
    esac
}

service_log() {
    _refresh_service_context
    case "$_service_kind" in
    systemd)
        journalctl -u "$KERNEL_NAME" "$@"
        ;;
    *)
        if [ $# -gt 0 ]; then
            tail "$@" "$_service_log_file"
            return
        fi
        less "$_service_log_file"
        ;;
    esac
}

service_follow_log() {
    _refresh_service_context
    case "$_service_kind" in
    systemd)
        journalctl -u "$KERNEL_NAME" -q -f -n 0
        ;;
    *)
        tail -f -n 0 "$_service_log_file"
        ;;
    esac
}

service_read_log() {
    _refresh_service_context
    case "$_service_kind" in
    systemd)
        journalctl -u "$KERNEL_NAME" --no-pager
        ;;
    *)
        cat "$_service_log_file" 2>/dev/null
        ;;
    esac
}

_merge_config_restart() {
    _merge_config
    service_stop >/dev/null 2>&1 || true
    if service_is_active >/dev/null 2>&1 && _tunstatus >/dev/null 2>&1; then
        _tunoff || _error_quit "请先关闭 Tun 模式"
    fi
    service_stop >/dev/null 2>&1 || true
    sleep 0.1
    service_start >/dev/null
    sleep 0.1
}

_install_service() {
    _refresh_service_context

    local kernel_desc="$KERNEL_NAME Daemon, A[nother] Clash Kernel."
    local cmd_path="${BIN_KERNEL}"
    local cmd_arg="-d ${CLASH_RESOURCES_DIR} -f ${CLASH_CONFIG_RUNTIME}"
    local cmd_full="${BIN_KERNEL} -d ${CLASH_RESOURCES_DIR} -f ${CLASH_CONFIG_RUNTIME}"
    local service_src service_target

    case "$_service_kind" in
    systemd)
        service_src="${SCRIPT_INIT_DIR}/systemd.sh"
        service_target="/etc/systemd/system/${KERNEL_NAME}.service"
        ;;
    sysvinit)
        service_src="${SCRIPT_INIT_DIR}/sysvinit.sh"
        service_target="/etc/init.d/${KERNEL_NAME}"
        ;;
    openrc)
        service_src="${SCRIPT_INIT_DIR}/openrc.sh"
        service_target="/etc/init.d/${KERNEL_NAME}"
        ;;
    runit)
        service_src="${SCRIPT_INIT_DIR}/runit.sh"
        service_target="/etc/sv/${KERNEL_NAME}/run"
        ;;
    nohup | *)
        return 0
        ;;
    esac

    /usr/bin/install -D -m +x "$service_src" "$service_target"
    sed -i \
        -e "s#placeholder_cmd_path#$cmd_path#g" \
        -e "s#placeholder_cmd_args#$cmd_arg#g" \
        -e "s#placeholder_cmd_full#$cmd_full#g" \
        -e "s#placeholder_log_file#$_service_log_file#g" \
        -e "s#placeholder_pid_file#$_service_pid_file#g" \
        -e "s#placeholder_kernel_name#$KERNEL_NAME#g" \
        -e "s#placeholder_kernel_desc#$kernel_desc#g" \
        "$service_target"

    case "$_service_kind" in
    systemd)
        systemctl daemon-reload
        systemctl enable "$KERNEL_NAME" >&/dev/null && _okcat '🚀' '已设置开机自启'
        ;;
    sysvinit)
        if command -v chkconfig >/dev/null 2>&1; then
            chkconfig --add "$KERNEL_NAME"
            chkconfig "$KERNEL_NAME" on >/dev/null && _okcat '🚀' '已设置开机自启'
        elif command -v update-rc.d >/dev/null 2>&1; then
            update-rc.d "$KERNEL_NAME" defaults
            _okcat '🚀' '已设置开机自启'
        fi
        ;;
    openrc)
        rc-update add "$KERNEL_NAME" default >/dev/null && _okcat '🚀' '已设置开机自启'
        ;;
    runit)
        mkdir -p "$(dirname "$service_target")"
        mkdir -p "/etc/runit/runsvdir/default"
        ln -snf "$(dirname "$service_target")" "/etc/runit/runsvdir/default/${KERNEL_NAME}"
        _okcat '🚀' '已设置开机自启'
        ;;
    esac
}

_uninstall_service() {
    _refresh_service_context
    service_stop >&/dev/null
    case "$_service_kind" in
    systemd)
        systemctl disable "$KERNEL_NAME" >&/dev/null
        rm -f "/etc/systemd/system/${KERNEL_NAME}.service"
        systemctl daemon-reload >&/dev/null
        ;;
    sysvinit)
        if command -v chkconfig >/dev/null 2>&1; then
            chkconfig "$KERNEL_NAME" off >/dev/null 2>&1 || true
            chkconfig --del "$KERNEL_NAME" >/dev/null 2>&1 || true
        elif command -v update-rc.d >/dev/null 2>&1; then
            update-rc.d "$KERNEL_NAME" remove >/dev/null 2>&1 || true
        fi
        rm -f "/etc/init.d/${KERNEL_NAME}"
        ;;
    openrc)
        rc-update del "$KERNEL_NAME" default >/dev/null 2>&1 || true
        rm -f "/etc/init.d/${KERNEL_NAME}"
        ;;
    runit)
        rm -f "/etc/runit/runsvdir/default/${KERNEL_NAME}"
        rm -rf "/etc/sv/${KERNEL_NAME}"
        ;;
    nohup | *)
        return 0
        ;;
    esac
}
