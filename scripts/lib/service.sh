#!/usr/bin/env bash

SCRIPT_INIT_DIR="${CLASHCTL_SRC}/scripts/init"

service_manager=
service_log_path=
service_pid_path=

detect_init() {
    [ -z "$INIT_TYPE" ] && INIT_TYPE=$(readlink /proc/1/exe 2>/dev/null || echo "nohup")
    grep -qsE "docker|kubepods|containerd|podman|lxc" /proc/1/cgroup 2>/dev/null && INIT_TYPE='nohup'
    _is_root || INIT_TYPE='nohup'
    INIT_TYPE=$(basename "$INIT_TYPE")
}

detect_service_manager() {
    detect_init
    case "$INIT_TYPE" in
    *systemd)
        service_manager="systemd"
        ;;
    *openrc*)
        service_manager="openrc"
        ;;
    *busybox*)
        service_manager="nohup"
        command -v openrc-init >&/dev/null && service_manager="openrc"
        ;;
    *runit)
        service_manager="runit"
        ;;
    *init)
        service_manager="sysvinit"
        ;;
    nohup | *)
        service_manager="nohup"
        ;;
    esac

    service_log_path="/var/log/${CLASHCTL_KERNEL}.log"
    service_pid_path="/run/${CLASHCTL_KERNEL}.pid"
    [ "$service_manager" = "nohup" ] && {
        service_log_path="${CLASH_RESOURCES_DIR}/${CLASHCTL_KERNEL}.log"
        service_pid_path="${CLASH_RESOURCES_DIR}/${CLASHCTL_KERNEL}.pid"
    }
}

service_start() {
    detect_service_manager
    case "$service_manager" in
    systemd)
        systemctl start "$CLASHCTL_KERNEL"
        ;;
    sysvinit)
        service "$CLASHCTL_KERNEL" start
        ;;
    openrc)
        rc-service "$CLASHCTL_KERNEL" start
        ;;
    runit)
        sv up "$CLASHCTL_KERNEL"
        ;;
    nohup | *)
        (
            nohup "$BIN_KERNEL" -d "$CLASH_RESOURCES_DIR" -f "$CLASH_CONFIG_RUNTIME" </dev/null >"$service_log_path" 2>&1 &
        )
        ;;
    esac
}

service_sudo_start() {
    _is_root && service_start && return 0
    detect_service_manager
    (
        sudo sh -c "nohup '$BIN_KERNEL' -d '$CLASH_RESOURCES_DIR' -f '$CLASH_CONFIG_RUNTIME' </dev/null > '$service_log_path' 2>&1 &"
        stty opost 2>/dev/null
    )
}

service_sudo_stop() {
    _is_root && service_stop && return 0
    sudo pkill -9 -f "$BIN_KERNEL"
    stty opost 2>/dev/null
}

service_stop() {
    detect_service_manager
    case "$service_manager" in
    systemd)
        systemctl stop "$CLASHCTL_KERNEL"
        ;;
    sysvinit)
        service "$CLASHCTL_KERNEL" stop
        ;;
    openrc)
        rc-service "$CLASHCTL_KERNEL" stop
        ;;
    runit)
        sv down "$CLASHCTL_KERNEL"
        ;;
    nohup | *)
        pkill -9 -f "$BIN_KERNEL"
        ;;
    esac
}

service_restart() {
    detect_service_manager
    case "$service_manager" in
    systemd)
        systemctl restart "$CLASHCTL_KERNEL"
        ;;
    sysvinit)
        service "$CLASHCTL_KERNEL" restart
        ;;
    openrc)
        rc-service "$CLASHCTL_KERNEL" restart
        ;;
    runit)
        sv restart "$CLASHCTL_KERNEL"
        ;;
    nohup | *)
        service_stop >/dev/null 2>&1
        sleep 0.1
        service_start
        ;;
    esac
}

service_status() {
    detect_service_manager
    case "$service_manager" in
    systemd)
        systemctl status "$CLASHCTL_KERNEL" "$@"
        ;;
    sysvinit)
        service "$CLASHCTL_KERNEL" status "$@"
        ;;
    openrc)
        rc-service "$CLASHCTL_KERNEL" status "$@"
        ;;
    runit)
        sv status "$CLASHCTL_KERNEL" "$@"
        ;;
    nohup | *)
        pgrep -fa "$BIN_KERNEL"
        ;;
    esac
}

service_is_active() {
    detect_service_manager
    case "$service_manager" in
    systemd)
        systemctl is-active "$CLASHCTL_KERNEL" >/dev/null 2>&1
        ;;
    sysvinit)
        service "$CLASHCTL_KERNEL" status >/dev/null 2>&1
        ;;
    openrc)
        rc-service "$CLASHCTL_KERNEL" status >/dev/null 2>&1
        ;;
    runit)
        sv status "$CLASHCTL_KERNEL" 2>/dev/null | grep -qs '^run'
        ;;
    nohup | *)
        pgrep -fa "$BIN_KERNEL" >/dev/null 2>&1
        ;;
    esac
}

service_log() {
    detect_service_manager
    case "$service_manager" in
    systemd)
        journalctl -u "$CLASHCTL_KERNEL" "$@"
        ;;
    *)
        if [ $# -gt 0 ]; then
            tail "$@" "$service_log_path"
            return
        fi
        less "$service_log_path"
        ;;
    esac
}

service_follow_log() {
    detect_service_manager
    case "$service_manager" in
    systemd)
        journalctl -u "$CLASHCTL_KERNEL" -q -f -n 0
        ;;
    *)
        tail -f -n 0 "$service_log_path"
        ;;
    esac
}

service_read_log() {
    detect_service_manager
    case "$service_manager" in
    systemd)
        journalctl -u "$CLASHCTL_KERNEL" --no-pager
        ;;
    *)
        cat "$service_log_path" 2>/dev/null
        ;;
    esac
}

_install_service() {
    detect_service_manager

    local kernel_desc="$CLASHCTL_KERNEL Daemon, A[nother] Clash Kernel."
    local cmd_path="${BIN_KERNEL}"
    local cmd_arg="-d ${CLASH_RESOURCES_DIR} -f ${CLASH_CONFIG_RUNTIME}"
    local cmd_full="${BIN_KERNEL} -d ${CLASH_RESOURCES_DIR} -f ${CLASH_CONFIG_RUNTIME}"
    local service_src service_target

    case "$service_manager" in
    systemd)
        service_src="${SCRIPT_INIT_DIR}/systemd.sh"
        service_target="/etc/systemd/system/${CLASHCTL_KERNEL}.service"
        ;;
    sysvinit)
        service_src="${SCRIPT_INIT_DIR}/sysvinit.sh"
        service_target="/etc/init.d/${CLASHCTL_KERNEL}"
        ;;
    openrc)
        service_src="${SCRIPT_INIT_DIR}/openrc.sh"
        service_target="/etc/init.d/${CLASHCTL_KERNEL}"
        ;;
    runit)
        service_src="${SCRIPT_INIT_DIR}/runit.sh"
        service_target="/etc/sv/${CLASHCTL_KERNEL}/run"
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
        -e "s#placeholder_log_path#$service_log_path#g" \
        -e "s#placeholder_pid_path#$service_pid_path#g" \
        -e "s#placeholder_kernel_name#$CLASHCTL_KERNEL#g" \
        -e "s#placeholder_kernel_desc#$kernel_desc#g" \
        "$service_target"

    case "$service_manager" in
    systemd)
        systemctl daemon-reload
        systemctl enable "$CLASHCTL_KERNEL" >&/dev/null && _okcat '🚀' '已设置开机自启'
        ;;
    sysvinit)
        if command -v chkconfig >/dev/null 2>&1; then
            chkconfig --add "$CLASHCTL_KERNEL"
            chkconfig "$CLASHCTL_KERNEL" on >/dev/null && _okcat '🚀' '已设置开机自启'
        elif command -v update-rc.d >/dev/null 2>&1; then
            update-rc.d "$CLASHCTL_KERNEL" defaults
            _okcat '🚀' '已设置开机自启'
        fi
        ;;
    openrc)
        rc-update add "$CLASHCTL_KERNEL" default >/dev/null && _okcat '🚀' '已设置开机自启'
        ;;
    runit)
        mkdir -p "$(dirname "$service_target")"
        mkdir -p "/etc/runit/runsvdir/default"
        ln -snf "$(dirname "$service_target")" "/etc/runit/runsvdir/default/${CLASHCTL_KERNEL}"
        _okcat '🚀' '已设置开机自启'
        ;;
    esac
}

_uninstall_service() {
    detect_service_manager
    service_stop >&/dev/null
    case "$service_manager" in
    systemd)
        systemctl disable "$CLASHCTL_KERNEL" >&/dev/null
        rm -f "/etc/systemd/system/${CLASHCTL_KERNEL}.service"
        systemctl daemon-reload >&/dev/null
        ;;
    sysvinit)
        if command -v chkconfig >/dev/null 2>&1; then
            chkconfig "$CLASHCTL_KERNEL" off >/dev/null 2>&1 || true
            chkconfig --del "$CLASHCTL_KERNEL" >/dev/null 2>&1 || true
        elif command -v update-rc.d >/dev/null 2>&1; then
            update-rc.d "$CLASHCTL_KERNEL" remove >/dev/null 2>&1 || true
        fi
        rm -f "/etc/init.d/${CLASHCTL_KERNEL}"
        ;;
    openrc)
        rc-update del "$CLASHCTL_KERNEL" default >/dev/null 2>&1 || true
        rm -f "/etc/init.d/${CLASHCTL_KERNEL}"
        ;;
    runit)
        rm -f "/etc/runit/runsvdir/default/${CLASHCTL_KERNEL}"
        rm -rf "/etc/sv/${CLASHCTL_KERNEL}"
        ;;
    nohup | *)
        return 0
        ;;
    esac
}
