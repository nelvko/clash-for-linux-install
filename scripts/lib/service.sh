#!/usr/bin/env bash

service_manager=
service_log_path=
service_pid_path=

detect_service_manager() {
    [ -n "$service_manager" ] && return 0
    [ -z "$INIT_TYPE" ] && INIT_TYPE=$(readlink /proc/1/exe 2>/dev/null || echo "nohup")
    grep -qsE "docker|kubepods|containerd|podman|lxc" /proc/1/cgroup 2>/dev/null && INIT_TYPE='nohup'
    _is_root || INIT_TYPE='nohup'
    INIT_TYPE=$(basename "$INIT_TYPE")

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
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        sudo systemctl stop "$CLASHCTL_KERNEL" 2>/dev/null
    else
        sudo pkill -TERM -x "$CLASHCTL_KERNEL" 2>/dev/null
        sleep 0.2
        sudo pkill -KILL -x "$CLASHCTL_KERNEL" 2>/dev/null
    fi
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
        pkill -TERM -x "$CLASHCTL_KERNEL" 2>/dev/null
        sleep 0.2
        pkill -KILL -x "$CLASHCTL_KERNEL" 2>/dev/null
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
        [ $# -gt 0 ] && {
            tail "$@" "$service_log_path"
            return
        }
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

install_service() {
    detect_service_manager

    local template_dir="${CLASHCTL_SRC}/scripts/init"
    local kernel_desc="$CLASHCTL_KERNEL Daemon, A[nother] Clash Kernel."
    local cmd_path="${BIN_KERNEL}"
    local cmd_arg="-d ${CLASH_RESOURCES_DIR} -f ${CLASH_CONFIG_RUNTIME}"
    local cmd_full="${BIN_KERNEL} -d ${CLASH_RESOURCES_DIR} -f ${CLASH_CONFIG_RUNTIME}"
    local service_src service_target

    case "$service_manager" in
    systemd)
        service_src="${template_dir}/systemd.sh"
        service_target="/etc/systemd/system/${CLASHCTL_KERNEL}.service"
        ;;
    sysvinit)
        service_src="${template_dir}/sysvinit.sh"
        service_target="/etc/init.d/${CLASHCTL_KERNEL}"
        ;;
    openrc)
        service_src="${template_dir}/openrc.sh"
        service_target="/etc/init.d/${CLASHCTL_KERNEL}"
        ;;
    runit)
        service_src="${template_dir}/runit.sh"
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
        systemctl daemon-reload || {
            _failcat '❌' '重载 systemd 配置失败'
            exit 1
        }
        _okcat '🧩' "已注册 systemd 服务：$CLASHCTL_KERNEL"

        systemctl enable --quiet "$CLASHCTL_KERNEL" || {
            _failcat '设置开机自启失败'
            return 1
        }
        _okcat '🚀' '已设置开机自启'
        ;;
    sysvinit)
        command -v chkconfig >&/dev/null && {
            chkconfig --add "$CLASHCTL_KERNEL" >/dev/null || {
                _failcat '❌' '注册 SysVinit 服务失败'
                exit 1
            }
            _okcat '🧩' "已注册 SysVinit 服务：$CLASHCTL_KERNEL"

            chkconfig "$CLASHCTL_KERNEL" on >/dev/null || {
                _failcat '设置开机自启失败'
                return 1
            }
            _okcat '🚀' '已设置开机自启'
            return 0
        }

        command -v update-rc.d >&/dev/null && {
            update-rc.d "$CLASHCTL_KERNEL" defaults >/dev/null || {
                _failcat '❌' '注册 SysVinit 服务失败'
                exit 1
            }
            _okcat '🧩' "已注册 SysVinit 服务：$CLASHCTL_KERNEL"

            update-rc.d "$CLASHCTL_KERNEL" enable >/dev/null || {
                _failcat '设置开机自启失败'
                return 1
            }
            _okcat '🚀' '已设置开机自启'
            return 0
        }
        _failcat '❌' '未找到 SysVinit 服务管理命令：chkconfig / update-rc.d'
        exit 1
        ;;
    openrc)
        rc-update add "$CLASHCTL_KERNEL" default >/dev/null || {
            _failcat '设置开机自启失败'
            return 1
        }
        _okcat '🚀' "已注册 OpenRC 服务并设置开机自启：$CLASHCTL_KERNEL"
        ;;

    runit)
        local service_dir
        service_dir="$(dirname -- "$service_target")"

        mkdir -p -- "$service_dir" || {
            _failcat '❌' '创建 runit 服务目录失败'
            return 1
        }

        mkdir -p -- '/etc/runit/runsvdir/default' || {
            _failcat '❌' '创建 runit 自启目录失败'
            return 1
        }

        ln -snf -- "$service_dir" "/etc/runit/runsvdir/default/$CLASHCTL_KERNEL" || {
            _failcat '❌' '设置开机自启失败'
            return 1
        }

        _okcat '🚀' "已注册 runit 服务并设置开机自启：$CLASHCTL_KERNEL"
        ;;

    *)
        _failcat '❌' "不支持的服务管理器：$service_manager"
        return 1
        ;;
    esac
}

uninstall_service() {
    detect_service_manager
    service_stop >&/dev/null
    case "$service_manager" in
    systemd)
        systemctl disable "$CLASHCTL_KERNEL" >&/dev/null
        /usr/bin/rm -f -- "/etc/systemd/system/${CLASHCTL_KERNEL}.service" || {
            _failcat '❌' '移除 systemd 服务失败'
            return 1
        }
        systemctl daemon-reload >/dev/null 2>&1 || {
            _failcat '❌' '重载 systemd 配置失败'
            return 1
        }
        systemctl reset-failed "$CLASHCTL_KERNEL" >&/dev/null

        _okcat '🧹' "已注销 systemd 服务：$CLASHCTL_KERNEL"
        ;;
    sysvinit)
        if command -v chkconfig >/dev/null 2>&1; then
            chkconfig "$CLASHCTL_KERNEL" off >/dev/null 2>&1 || true
            chkconfig --del "$CLASHCTL_KERNEL" >/dev/null 2>&1 || true
        elif command -v update-rc.d >/dev/null 2>&1; then
            update-rc.d "$CLASHCTL_KERNEL" remove >/dev/null 2>&1 || true
        fi
        /usr/bin/rm -f "/etc/init.d/${CLASHCTL_KERNEL}"
        ;;
    openrc)
        rc-update del "$CLASHCTL_KERNEL" default >/dev/null 2>&1 || true
        /usr/bin/rm -f "/etc/init.d/${CLASHCTL_KERNEL}"
        ;;
    runit)
        /usr/bin/rm -f "/etc/runit/runsvdir/default/${CLASHCTL_KERNEL}"
        /usr/bin/rm -rf "/etc/sv/${CLASHCTL_KERNEL}"
        ;;
    nohup | *)
        return 0
        ;;
    esac
}
