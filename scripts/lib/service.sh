#!/usr/bin/env bash

if ! declare -F _service_process_record_pid >/dev/null 2>&1; then
    _service_process_lib_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
    # shellcheck source=scripts/lib/service-process.sh
    . "${_service_process_lib_dir}/service-process.sh"
    unset _service_process_lib_dir
fi

if ! declare -F service_enablement_restore >/dev/null 2>&1; then
    _service_enablement_lib_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
    # shellcheck source=scripts/lib/service-enablement.sh
    . "${_service_enablement_lib_dir}/service-enablement.sh"
    unset _service_enablement_lib_dir
fi

if ! declare -F operation_lock_close_fd >/dev/null 2>&1; then
    _service_operation_lock_lib_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
    # shellcheck source=scripts/lib/operation-lock.sh
    . "${_service_operation_lock_lib_dir}/operation-lock.sh"
    unset _service_operation_lock_lib_dir
fi

service_manager=
service_log_path=
service_pid_path=
_SERVICE_REPLACED_RESTORE_STATUS=

_service_run_without_operation_lock() {
    if [ -z "${CLASHCTL_OPERATION_LOCK_FD:-}" ]; then
        "$@"
        return
    fi
    (
        operation_lock_close_fd || exit 1
        "$@"
    )
}

_service_owned_pids() {
    _service_process_record_pid "$service_pid_path" 2>/dev/null
}

_service_privileged_marker_exists() {
    local record
    _is_root && return 1
    _service_privileged_runtime_is_secure /run/clashctl || return 1
    record=$(_service_privileged_record_path /run/clashctl "$(id -u)" "$CLASHCTL_KERNEL") || return 1
    _service_privileged_record_is_secure "$record"
}

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
        service_log_path="${CLASH_DATA_DIR}/${CLASHCTL_KERNEL}.log"
        service_pid_path="${CLASH_DATA_DIR}/${CLASHCTL_KERNEL}.pid"
    }
}

_service_nohup_start_locked() {
    local pid expected_argv
    expected_argv=$(_service_process_values_argv_hex \
        "$BIN_KERNEL" -d "$CLASH_RESOURCES_DIR" -f "$CLASH_CONFIG_RUNTIME") || return 1
    if _service_process_record_pid "$service_pid_path" >/dev/null 2>&1; then
        [ "$_SERVICE_RECORD_ARGV" = "$expected_argv" ]
        return
    fi
    /usr/bin/rm -f -- "$service_pid_path" || return 1
    (
        operation_lock_close_fd || exit 1
        exec nohup "$BIN_KERNEL" -d "$CLASH_RESOURCES_DIR" -f "$CLASH_CONFIG_RUNTIME"
    ) </dev/null >"$service_log_path" 2>&1 9>&- &
    pid=$!
    _service_process_record_create \
        "$service_pid_path" "$pid" "$BIN_KERNEL" \
        "$BIN_KERNEL" -d "$CLASH_RESOURCES_DIR" -f "$CLASH_CONFIG_RUNTIME" || {
        if [ "${_SERVICE_SNAPSHOT_PID:-}" = "$pid" ]; then
            _service_process_stop_snapshot \
                "$pid" "$_SERVICE_SNAPSHOT_STARTTIME" \
                "$_SERVICE_SNAPSHOT_ARGV" "$_SERVICE_SNAPSHOT_EXE_ID"
        elif [ "${_SERVICE_PROCESS_BIRTH_PID:-}" = "$pid" ]; then
            _service_process_stop_birth "$pid" "$_SERVICE_PROCESS_BIRTH_STARTTIME"
        fi
        /usr/bin/rm -f -- "$service_pid_path"
        return 1
    }
}

_service_nohup_stop_locked() {
    [ -e "$service_pid_path" ] || [ -L "$service_pid_path" ] || return 0
    if ! _service_process_record_load "$service_pid_path"; then
        /usr/bin/rm -f -- "$service_pid_path"
        return 0
    fi
    _service_process_stop_recorded "$service_pid_path" || return 1
    [ "${_SERVICE_PROCESS_RECORD_CAN_REMOVE:-0}" -eq 0 ] ||
        /usr/bin/rm -f -- "$service_pid_path"
}

service_start() {
    detect_service_manager
    case "$service_manager" in
    systemd)
        _service_run_without_operation_lock systemctl start "$CLASHCTL_KERNEL"
        ;;
    sysvinit)
        _service_run_without_operation_lock service "$CLASHCTL_KERNEL" start
        ;;
    openrc)
        _service_run_without_operation_lock rc-service "$CLASHCTL_KERNEL" start
        ;;
    runit)
        _service_run_without_operation_lock sv up "$CLASHCTL_KERNEL"
        ;;
    nohup | *)
        local lock rc=0
        /usr/bin/install -d "$(dirname -- "$service_pid_path")" || return 1
        _service_process_lock_acquire "$service_pid_path" || return 1
        lock=$_SERVICE_PROCESS_LOCK_PATH
        _service_nohup_start_locked || rc=$?
        _service_process_lock_release "$lock" || rc=1
        return "$rc"
        ;;
    esac
}

service_sudo_start() {
    _is_root && service_start && return 0
    detect_service_manager
    local owner_uid helper rc=0
    owner_uid=$(id -u) || return 1
    helper=${_SERVICE_PROCESS_HELPER_FILE:-}
    [ -r "$helper" ] || return 1
    /usr/bin/install -d "$(dirname -- "$service_log_path")" || return 1
    : >>"$service_log_path" || return 1
    # The caller opens the log as itself; the privileged helper only inherits stdout.
    # shellcheck disable=SC2024
    _service_run_without_operation_lock sudo bash "$helper" privileged-start \
        "$owner_uid" "$CLASHCTL_KERNEL" "$BIN_KERNEL" \
        "$CLASH_RESOURCES_DIR" "$CLASH_CONFIG_RUNTIME" \
        >>"$service_log_path" || rc=$?
    stty opost 2>/dev/null || true
    return "$rc"
}

service_sudo_stop() {
    _is_root && service_stop && return 0
    local owner_uid helper rc=0
    owner_uid=$(id -u) || return 1
    helper=${_SERVICE_PROCESS_HELPER_FILE:-}
    [ -r "$helper" ] || return 1
    sudo bash "$helper" privileged-stop "$owner_uid" "$CLASHCTL_KERNEL" || rc=$?
    stty opost 2>/dev/null || true
    return "$rc"
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
        local lock rc=0
        /usr/bin/install -d "$(dirname -- "$service_pid_path")" || return 1
        _service_process_lock_acquire "$service_pid_path" || return 1
        lock=$_SERVICE_PROCESS_LOCK_PATH
        _service_nohup_stop_locked || rc=$?
        _service_process_lock_release "$lock" || rc=1
        return "$rc"
        ;;
    esac
}

service_restart() {
    detect_service_manager
    case "$service_manager" in
    systemd)
        _service_run_without_operation_lock systemctl restart "$CLASHCTL_KERNEL"
        ;;
    sysvinit)
        _service_run_without_operation_lock service "$CLASHCTL_KERNEL" restart
        ;;
    openrc)
        _service_run_without_operation_lock rc-service "$CLASHCTL_KERNEL" restart
        ;;
    runit)
        _service_run_without_operation_lock sv restart "$CLASHCTL_KERNEL"
        ;;
    nohup | *)
        service_stop >/dev/null 2>&1 || return 1
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
        local pid
        pid=$(_service_owned_pids) || pid=
        if [ -n "$pid" ]; then
            printf '%s\n' "$CLASHCTL_KERNEL 正在运行 (PID $pid)"
        elif _service_privileged_marker_exists; then
            printf '%s\n' "$CLASHCTL_KERNEL 正以特权模式运行"
        else
            return 1
        fi
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
        _service_owned_pids >/dev/null 2>&1 || _service_privileged_marker_exists
        ;;
    esac
}

service_is_enabled() {
    detect_service_manager
    case "$service_manager" in
    systemd)
        systemctl is-enabled --quiet "$CLASHCTL_KERNEL" 2>/dev/null
        ;;
    sysvinit)
        if command -v chkconfig >/dev/null 2>&1; then
            chkconfig "$CLASHCTL_KERNEL" 2>/dev/null | grep -qsE ':[[:space:]]*on'
            return
        fi
        local link
        for link in /etc/rc?.d/S[0-9][0-9]"$CLASHCTL_KERNEL"; do
            [ -L "$link" ] && return 0
        done
        return 1
        ;;
    openrc)
        rc-update show default 2>/dev/null | grep -qs "[[:space:]]${CLASHCTL_KERNEL}[[:space:]]"
        ;;
    runit)
        [ -L "$(_service_runit_enable_link)" ]
        ;;
    nohup | *)
        return 1
        ;;
    esac
}

_service_runit_enable_link() {
    printf '%s\n' "${CLASHCTL_SERVICE_ENABLE_LINK:-/etc/runit/runsvdir/default/${CLASHCTL_KERNEL}}"
}

_service_runit_link_state() {
    local link=$1
    if [ -L "$link" ]; then
        printf 'symlink\t%s\n' "$(readlink -- "$link")"
    elif [ -e "$link" ]; then
        printf 'other\t\n'
    else
        printf 'absent\t\n'
    fi
}

_service_atomic_symlink() {
    local target=$1 link=$2 tmp
    tmp="${link}.clashctl-new.$$.$RANDOM"
    ln -s -- "$target" "$tmp" || return 1
    if ! /bin/mv -fT -- "$tmp" "$link"; then
        /usr/bin/rm -f -- "$tmp"
        return 1
    fi
}

service_enable() {
    detect_service_manager
    case "$service_manager" in
    systemd)
        systemctl enable --quiet "$CLASHCTL_KERNEL"
        ;;
    sysvinit)
        if command -v chkconfig >/dev/null 2>&1; then
            chkconfig --add "$CLASHCTL_KERNEL" >/dev/null &&
                chkconfig "$CLASHCTL_KERNEL" on >/dev/null
        elif command -v update-rc.d >/dev/null 2>&1; then
            update-rc.d "$CLASHCTL_KERNEL" defaults >/dev/null &&
                update-rc.d "$CLASHCTL_KERNEL" enable >/dev/null
        else
            return 127
        fi
        ;;
    openrc)
        rc-update add "$CLASHCTL_KERNEL" default >/dev/null
        ;;
    runit)
        local service_target enable_link desired_target current_kind current_target
        service_target=$(_service_target) || return 1
        enable_link=$(_service_runit_enable_link)
        desired_target=$(dirname -- "$service_target")
        IFS=$'\t' read -r current_kind current_target < <(_service_runit_link_state "$enable_link")
        if [ -n "${CLASHCTL_SERVICE_ENABLE_KIND+x}" ]; then
            if [ "$current_kind" != "${CLASHCTL_SERVICE_ENABLE_KIND:-absent}" ] ||
                [ "$current_target" != "${CLASHCTL_SERVICE_ENABLE_TARGET:-}" ]; then
                [ "$current_kind" = symlink ] && [ "$current_target" = "$desired_target" ] || return 1
            fi
        else
            [ "$current_kind" = absent ] ||
                { [ "$current_kind" = symlink ] && [ "$current_target" = "$desired_target" ]; } || return 1
        fi
        /usr/bin/install -d "$(dirname -- "$enable_link")" &&
            _service_atomic_symlink "$desired_target" "$enable_link"
        ;;
    nohup | *)
        return 0
        ;;
    esac
}

service_disable() {
    detect_service_manager
    case "$service_manager" in
    systemd)
        systemctl disable --quiet "$CLASHCTL_KERNEL"
        ;;
    sysvinit)
        if command -v chkconfig >/dev/null 2>&1; then
            chkconfig "$CLASHCTL_KERNEL" off >/dev/null
        elif command -v update-rc.d >/dev/null 2>&1; then
            update-rc.d "$CLASHCTL_KERNEL" disable >/dev/null
        else
            return 127
        fi
        ;;
    openrc)
        rc-update del "$CLASHCTL_KERNEL" default >/dev/null
        ;;
    runit)
        local enable_link current_kind current_target desired_target=
        enable_link=$(_service_runit_enable_link)
        IFS=$'\t' read -r current_kind current_target < <(_service_runit_link_state "$enable_link")
        [ "$current_kind" != absent ] || return 0
        [ "$current_kind" = symlink ] || return 1
        desired_target=$(_service_target 2>/dev/null) || desired_target=
        [ -z "$desired_target" ] || desired_target=$(dirname -- "$desired_target")
        if [ "$current_target" != "$desired_target" ] &&
            [ "$current_target" != "${CLASHCTL_SERVICE_ENABLE_TARGET:-}" ]; then
            return 1
        fi
        /usr/bin/rm -f -- "$enable_link"
        ;;
    nohup | *)
        return 0
        ;;
    esac
}

_service_unregister() {
    detect_service_manager
    case "$service_manager" in
    sysvinit)
        if command -v chkconfig >/dev/null 2>&1; then
            chkconfig --del "$CLASHCTL_KERNEL" >/dev/null
        elif command -v update-rc.d >/dev/null 2>&1; then
            update-rc.d -f "$CLASHCTL_KERNEL" remove >/dev/null
        else
            return 127
        fi
        ;;
    *) return 0 ;;
    esac
}

_service_restore_enablement() {
    local was_enabled=${1:-0} runit_target=${2:-}

    if [ "$service_manager" = runit ] && [ "$was_enabled" = 1 ] && [ -n "$runit_target" ]; then
        local enable_link
        enable_link=$(_service_runit_enable_link)
        /usr/bin/install -d "$(dirname -- "$enable_link")" &&
            _service_atomic_symlink "$runit_target" "$enable_link"
        return
    fi
    if [ "$was_enabled" != 1 ]; then
        service_is_enabled || return 0
        service_disable
        return
    fi
    service_is_enabled && return 0
    service_enable
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

# 输出当前 init 系统的服务单元路径；无服务管理器（nohup）时返回 1
_service_target() {
    detect_service_manager

    case "$service_manager" in
    systemd)
        printf '%s\n' "/etc/systemd/system/${CLASHCTL_KERNEL}.service"
        ;;
    sysvinit | openrc)
        printf '%s\n' "/etc/init.d/${CLASHCTL_KERNEL}"
        ;;
    runit)
        printf '%s\n' "/etc/sv/${CLASHCTL_KERNEL}/run"
        ;;
    *)
        return 1
        ;;
    esac
}

# 将服务单元模板渲染（替换占位符）到 <dst>；无服务管理器时返回 1
_render_service_unit() {
    local dst=$1
    detect_service_manager

    local template_dir="${CLASHCTL_SRC}/scripts/init"
    local kernel_desc="$CLASHCTL_KERNEL Daemon, A[nother] Clash Kernel."
    local cmd_path="${BIN_KERNEL}"
    local cmd_arg="-d ${CLASH_RESOURCES_DIR} -f ${CLASH_CONFIG_RUNTIME}"
    local cmd_full="${BIN_KERNEL} -d ${CLASH_RESOURCES_DIR} -f ${CLASH_CONFIG_RUNTIME}"
    local service_src

    case "$service_manager" in
    systemd)
        service_src="${template_dir}/systemd.sh"
        ;;
    sysvinit)
        service_src="${template_dir}/sysvinit.sh"
        ;;
    openrc)
        service_src="${template_dir}/openrc.sh"
        ;;
    runit)
        service_src="${template_dir}/runit.sh"
        ;;
    *)
        return 1
        ;;
    esac

    /usr/bin/install -D -m 0644 "$service_src" "$dst" || return 1
    sed -i \
        -e "s#placeholder_cmd_path#$cmd_path#g" \
        -e "s#placeholder_cmd_args#$cmd_arg#g" \
        -e "s#placeholder_cmd_full#$cmd_full#g" \
        -e "s#placeholder_log_path#$service_log_path#g" \
        -e "s#placeholder_pid_path#$service_pid_path#g" \
        -e "s#placeholder_kernel_name#$CLASHCTL_KERNEL#g" \
        -e "s#placeholder_kernel_desc#$kernel_desc#g" \
        "$dst"
}

_restore_service_unit() {
    local target=$1 rollback=$2 had_target=$3 staged

    if [ "$had_target" = true ]; then
        staged=$(mktemp "${target}.clashctl-restore.XXXXXX") || return 1
        if ! cp -aT -- "$rollback" "$staged" || ! /bin/mv -fT -- "$staged" "$target"; then
            /usr/bin/rm -f -- "$staged"
            return 1
        fi
    else
        /usr/bin/rm -f -- "$target" || return 1
    fi
    [ "$service_manager" != systemd ] || systemctl daemon-reload >/dev/null 2>&1 || return 1
    [ "$had_target" != true ] || /usr/bin/rm -f -- "$rollback"
    return 0
}

_service_install_failed() {
    local message=$1 target=$2 rollback=$3 had_target=$4
    if _restore_service_unit "$target" "$rollback" "$had_target"; then
        _ui_error "$message；已恢复写入前的服务定义"
    else
        _ui_error "$message；自动恢复失败"
        if [ -e "$rollback" ] || [ -L "$rollback" ]; then
            _ui_detail '临时备份' "$rollback"
        fi
    fi
    return 1
}

install_service() {
    detect_service_manager

    local service_target candidate staged rollback had_target=false mode=0755
    service_target=$(_service_target) || {
        _ui_info "服务模式: nohup（无需注册系统服务）"
        return 0
    }
    [ "$service_manager" != systemd ] || mode=0644

    candidate=$(mktemp) || {
        _ui_error '无法创建服务配置临时文件'
        return 1
    }
    _render_service_unit "$candidate" || {
        /usr/bin/rm -f -- "$candidate"
        _ui_error "无法生成 ${service_manager} 服务配置"
        return 1
    }

    staged=$(mktemp "${service_target}.clashctl-new.XXXXXX") || {
        /usr/bin/rm -f -- "$candidate"
        _ui_error "无法创建服务配置暂存文件: $service_target"
        return 1
    }
    if [ -e "$service_target" ] || [ -L "$service_target" ]; then
        rollback=$(mktemp "${service_target}.clashctl-rollback.XXXXXX") || {
            /usr/bin/rm -f -- "$candidate" "$staged"
            _ui_error "无法创建服务配置回滚文件: $service_target"
            return 1
        }
        cp -aT -- "$service_target" "$rollback" || {
            /usr/bin/rm -f -- "$candidate" "$staged" "$rollback"
            _ui_error "无法暂存现有服务配置: $service_target"
            return 1
        }
        had_target=true
    fi
    /usr/bin/install -D -m "$mode" "$candidate" "$staged" &&
        /bin/mv -fT -- "$staged" "$service_target"
    local write_rc=$?
    /usr/bin/rm -f -- "$candidate" "$staged"
    if [ "$write_rc" -ne 0 ]; then
        [ "$had_target" != true ] || /usr/bin/rm -f -- "$rollback"
        _ui_error "无法写入服务配置: $service_target"
        return 1
    fi

    case "$service_manager" in
    systemd)
        systemctl daemon-reload || {
            _service_install_failed '重载 systemd 配置失败' "$service_target" "$rollback" "$had_target"
            return 1
        }

        service_enable || {
            _service_install_failed '设置 systemd 开机自启失败' "$service_target" "$rollback" "$had_target"
            return 1
        }
        _ui_info "systemd 已接受服务启用请求，正在核验链接与状态"
        ;;
    sysvinit)
        service_enable || {
            _service_install_failed '注册或启用 SysVinit 服务失败' "$service_target" "$rollback" "$had_target"
            return 1
        }
        _ui_info "SysVinit 已接受服务启用请求，正在核验各 runlevel"
        ;;
    openrc)
        service_enable || {
            _service_install_failed '设置 OpenRC 开机自启失败' "$service_target" "$rollback" "$had_target"
            return 1
        }
        _ui_info "OpenRC 已接受服务启用请求，正在核验各 runlevel"
        ;;

    runit)
        service_enable || {
            _service_install_failed '设置 runit 开机自启失败' "$service_target" "$rollback" "$had_target"
            return 1
        }

        _ui_info "runit 启用入口已写入，正在核验链接目标"
        ;;

    *)
        _service_install_failed "不支持的服务管理器: $service_manager" "$service_target" "$rollback" "$had_target"
        return 1
        ;;
    esac

    [ "$had_target" != true ] || /usr/bin/rm -f -- "$rollback"
    return 0
}

_service_same_object() {
    local left=$1 right=$2
    if [ -L "$left" ] || [ -L "$right" ]; then
        [ -L "$left" ] && [ -L "$right" ] &&
            [ "$(readlink -- "$left")" = "$(readlink -- "$right")" ]
        return
    fi
    cmp -s -- "$left" "$right"
}

_service_definition_is_owned() {
    local target=$1 command_line
    command_line="$BIN_KERNEL -d $CLASH_RESOURCES_DIR -f $CLASH_CONFIG_RUNTIME"
    case $service_manager in
    systemd)
        grep -Fqx -- "ExecStart=$command_line" "$target" 2>/dev/null
        ;;
    sysvinit)
        grep -Fqx -- "cmd=\"$command_line\"" "$target" 2>/dev/null
        ;;
    openrc)
        grep -Fqx -- "command=\"$BIN_KERNEL\"" "$target" 2>/dev/null &&
            grep -Fqx -- "command_args=\"-d $CLASH_RESOURCES_DIR -f $CLASH_CONFIG_RUNTIME\"" \
                "$target" 2>/dev/null
        ;;
    runit)
        grep -Fqx -- "exec $command_line >$service_log_path 2>&1" "$target" 2>/dev/null
        ;;
    *) return 1 ;;
    esac
}

_service_systemd_property() {
    systemctl show "${CLASHCTL_KERNEL}.service" -p "$1" --value 2>/dev/null
}

_service_systemd_execstart_is_owned() {
    local value=$1
    case $value in
    "$BIN_KERNEL" | "$BIN_KERNEL "* | *" path=$BIN_KERNEL ;"*) return 0 ;;
    *) return 1 ;;
    esac
}

_service_systemd_main_pid_is_owned() {
    local pid=$1 expected_path actual_path expected_argv actual_argv
    local starttime_before starttime_after
    case $pid in '' | *[!0-9]*) return 1 ;; esac
    [ "$pid" -gt 1 ] || return 1
    expected_path=$(readlink -f -- "$BIN_KERNEL" 2>/dev/null) || return 1
    expected_argv=$(_service_process_values_argv_hex \
        "$BIN_KERNEL" -d "$CLASH_RESOURCES_DIR" -f "$CLASH_CONFIG_RUNTIME") || return 1
    starttime_before=$(_service_process_starttime "$pid") || return 1
    actual_path=$(_service_process_exe_path "$pid") || return 1
    [ "$actual_path" = "$expected_path" ] || return 1
    actual_argv=$(_service_process_argv_hex "$pid") || return 1
    [ "$actual_argv" = "$expected_argv" ] || return 1
    starttime_after=$(_service_process_starttime "$pid") || return 1
    [ "$starttime_after" = "$starttime_before" ]
}

_service_systemd_loaded_unit_is_owned() {
    local expected_target=$1 fragment execstart main_pid current_main_pid
    fragment=$(_service_systemd_property FragmentPath) || return 1
    [ "$fragment" = "$expected_target" ] || return 1
    execstart=$(_service_systemd_property ExecStart) || return 1
    _service_systemd_execstart_is_owned "$execstart" || return 1
    main_pid=$(_service_systemd_property MainPID) || return 1
    _service_systemd_main_pid_is_owned "$main_pid" || return 1
    current_main_pid=$(_service_systemd_property MainPID) || return 1
    [ "$current_main_pid" = "$main_pid" ]
}

_service_vendor_provider_exists() {
    local source=$1
    [ -e "$source" ] || [ -L "$source" ]
}

_service_runit_uninstall_preflight() {
    local link=$1 expected=$2 original_kind=$3 original_target=$4
    local current_kind=absent current_target=
    [ -n "$link" ] || return 0
    if [ -L "$link" ]; then
        current_kind=symlink
        current_target=$(readlink -- "$link") || {
            _ui_error '无法读取 runit 自启入口，拒绝卸载'
            _ui_detail '入口' "$link"
            return 1
        }
    elif [ -e "$link" ]; then
        current_kind=other
    fi
    if [ "$current_kind" = symlink ] && [ "$current_target" = "$expected" ]; then
        return 0
    fi
    if [ "$current_kind" = "$original_kind" ] && [ "$current_target" = "$original_target" ]; then
        return 0
    fi
    _ui_error "runit 自启入口已被其他操作修改，拒绝覆盖: $link"
    return 1
}

_service_replaced_enablement_preflight() {
    local format_set=0 manager=${CLASHCTL_REPLACED_SERVICE_MANAGER:-}
    local format=${CLASHCTL_REPLACED_SERVICE_ENABLEMENT_FORMAT:-}
    local original_state=${CLASHCTL_REPLACED_SERVICE_ENABLEMENT_STATE:-}
    local original_links=${CLASHCTL_REPLACED_SERVICE_ENABLEMENT_LINKS:-}
    local installed_state=${CLASHCTL_REPLACED_SERVICE_INSTALLED_ENABLEMENT_STATE:-}
    local installed_links=${CLASHCTL_REPLACED_SERVICE_INSTALLED_ENABLEMENT_LINKS:-}

    _SERVICE_REPLACED_ENABLEMENT_MODE=legacy
    _SERVICE_REPLACED_ENABLEMENT_ORIGINAL=
    _SERVICE_REPLACED_ENABLEMENT_INSTALLED=
    [ "${CLASHCTL_REPLACED_SERVICE_ENABLEMENT_FORMAT+x}" != x ] || format_set=1
    [ "${CLASHCTL_REPLACED_SERVICE_ENABLEMENT_STATE+x}" != x ] || format_set=1
    [ "${CLASHCTL_REPLACED_SERVICE_ENABLEMENT_LINKS+x}" != x ] || format_set=1
    [ "${CLASHCTL_REPLACED_SERVICE_INSTALLED_ENABLEMENT_STATE+x}" != x ] || format_set=1
    [ "${CLASHCTL_REPLACED_SERVICE_INSTALLED_ENABLEMENT_LINKS+x}" != x ] || format_set=1
    [ "$format_set" -eq 1 ] || return 0

    if [ "${CLASHCTL_REPLACED_SERVICE_MANAGER+x}" != x ] ||
        [ "${CLASHCTL_REPLACED_SERVICE_ENABLEMENT_FORMAT+x}" != x ] ||
        [ "${CLASHCTL_REPLACED_SERVICE_ENABLEMENT_STATE+x}" != x ] ||
        [ "${CLASHCTL_REPLACED_SERVICE_ENABLEMENT_LINKS+x}" != x ] ||
        [ "${CLASHCTL_REPLACED_SERVICE_INSTALLED_ENABLEMENT_STATE+x}" != x ] ||
        [ "${CLASHCTL_REPLACED_SERVICE_INSTALLED_ENABLEMENT_LINKS+x}" != x ]; then
        _ui_error '原服务的精确自启恢复元数据不完整，拒绝卸载'
        return 1
    fi
    [ "$format" = clashctl-service-enablement-v1 ] || {
        _ui_error "不支持的原服务自启快照格式: ${format:-空}"
        return 1
    }
    [ "$manager" = "$service_manager" ] || {
        _ui_error '安装时与当前服务管理器不一致，拒绝恢复原服务'
        _ui_detail '安装时' "$manager"
        _ui_detail '当前' "$service_manager"
        return 1
    }

    _SERVICE_REPLACED_ENABLEMENT_ORIGINAL="${CLASHCTL_HOME}/.service-enablement.original"
    _SERVICE_REPLACED_ENABLEMENT_INSTALLED="${CLASHCTL_HOME}/.service-enablement.installed"
    if ! service_enablement_validate "$manager" "$CLASHCTL_KERNEL" \
        "$_SERVICE_REPLACED_ENABLEMENT_ORIGINAL"; then
        _ui_error '安装前的服务自启快照无效或已丢失'
        _ui_detail '原因' "${SERVICE_ENABLEMENT_ERROR:-未知错误}"
        _ui_detail '快照' "$_SERVICE_REPLACED_ENABLEMENT_ORIGINAL"
        return 1
    fi
    if [ "$SERVICE_ENABLEMENT_STATE" != "$original_state" ] ||
        [ "$SERVICE_ENABLEMENT_LINKS" != "$original_links" ]; then
        _ui_error '安装前的服务自启快照与安装记录不一致'
        return 1
    fi
    if ! service_enablement_validate "$manager" "$CLASHCTL_KERNEL" \
        "$_SERVICE_REPLACED_ENABLEMENT_INSTALLED"; then
        _ui_error 'clashctl 安装后的服务自启快照无效或已丢失'
        _ui_detail '原因' "${SERVICE_ENABLEMENT_ERROR:-未知错误}"
        _ui_detail '快照' "$_SERVICE_REPLACED_ENABLEMENT_INSTALLED"
        return 1
    fi
    if [ "$SERVICE_ENABLEMENT_STATE" != "$installed_state" ] ||
        [ "$SERVICE_ENABLEMENT_LINKS" != "$installed_links" ]; then
        _ui_error 'clashctl 安装后的服务自启快照与安装记录不一致'
        return 1
    fi
    if ! service_enablement_preflight_restore "$manager" "$CLASHCTL_KERNEL" \
        "$_SERVICE_REPLACED_ENABLEMENT_ORIGINAL" \
        "$_SERVICE_REPLACED_ENABLEMENT_INSTALLED"; then
        _ui_error '当前服务自启状态已被其他操作修改，拒绝卸载'
        _ui_detail '原因' "${SERVICE_ENABLEMENT_ERROR:-未知错误}"
        _ui_detail '处理' '确认服务链接归属并恢复到安装后状态，再重新执行卸载'
        return 1
    fi
    _SERVICE_REPLACED_ENABLEMENT_MODE=exact
    return 0
}

_replaced_service_preflight() {
    local source=${CLASHCTL_REPLACED_SERVICE_SOURCE:-}
    local target=${CLASHCTL_REPLACED_SERVICE_TARGET:-}
    local backup=${CLASHCTL_REPLACED_SERVICE_BACKUP:-}
    local expected_target metadata_present=0

    [ "${CLASHCTL_REPLACED_SERVICE_ENABLEMENT_FORMAT+x}" != x ] || metadata_present=1

    if [ -z "$source" ] && [ -z "$target" ] && [ -z "$backup" ] &&
        [ "$metadata_present" -eq 0 ]; then
        return 2
    fi
    _service_replaced_enablement_preflight || return 1
    expected_target=$(_service_target) || expected_target=
    if [ -z "$target" ] || [ "$target" != "$expected_target" ]; then
        _ui_error '原服务恢复目标与当前服务管理器不匹配，拒绝卸载'
        return 1
    fi
    case ${CLASHCTL_REPLACED_SERVICE_WAS_ACTIVE:-0}:${CLASHCTL_REPLACED_SERVICE_WAS_ENABLED:-0} in
    0:0 | 0:1 | 1:0 | 1:1) ;;
    *) _ui_error '原服务运行或启用状态记录无效，拒绝卸载'; return 1 ;;
    esac
    if [ "$_SERVICE_REPLACED_ENABLEMENT_MODE" = legacy ] &&
        { [ -z "$source" ] || [ -z "$backup" ]; }; then
        _ui_error '原服务恢复元数据不完整，拒绝卸载'
        return 1
    fi
    if [ -n "$source" ]; then
        if [ -z "$backup" ] || { [ ! -e "$backup" ] && [ ! -L "$backup" ]; }; then
            _ui_error "原服务备份不存在，拒绝卸载: ${backup:-未记录}"
            return 1
        fi
    elif [ -n "$backup" ] || [ "${CLASHCTL_REPLACED_SERVICE_WAS_ACTIVE:-0}" = 1 ]; then
        _ui_error '无原服务定义时不应存在定义备份或运行中状态，拒绝卸载'
        return 1
    fi
    if [ -n "$source" ] && [ "$source" != "$target" ] && [ "$service_manager" = systemd ]; then
        _service_vendor_provider_exists "$source" "$target" || {
            _ui_error 'systemd 原服务 provider 已不存在，拒绝删除当前 override'
            _ui_detail '保留备份' "$backup"
            return 1
        }
    fi
    return 0
}

uninstall_replaced_service_preflight() {
    local rc=0
    detect_service_manager
    _replaced_service_preflight || rc=$?
    [ "$rc" -ne 1 ]
}

_restore_replaced_service_after_uninstall() {
    local source=${CLASHCTL_REPLACED_SERVICE_SOURCE:-}
    local target=${CLASHCTL_REPLACED_SERVICE_TARGET:-}
    local backup=${CLASHCTL_REPLACED_SERVICE_BACKUP:-}
    local was_active=${CLASHCTL_REPLACED_SERVICE_WAS_ACTIVE:-0}
    local was_enabled=${CLASHCTL_REPLACED_SERVICE_WAS_ENABLED:-0}
    local link=${CLASHCTL_REPLACED_SERVICE_ENABLE_LINK:-}
    local original_kind=${CLASHCTL_REPLACED_SERVICE_ENABLE_KIND:-absent}
    local original_target=${CLASHCTL_REPLACED_SERVICE_ENABLE_TARGET:-}
    local provider staged='' enablement_rc=0

    _SERVICE_REPLACED_RESTORE_STATUS='尚未修改原服务定义'

    if [ "$source" = "$target" ]; then
        staged=$(mktemp "${target}.clashctl-restore.XXXXXX") || {
            _ui_error "无法创建原服务恢复暂存文件；备份保留在: $backup"
            return 1
        }
        if ! cp -aT -- "$backup" "$staged" || ! /bin/mv -fT -- "$staged" "$target"; then
            /usr/bin/rm -f -- "$staged"
            _ui_error "恢复原服务定义失败；备份保留在: $backup"
            return 1
        fi
        _SERVICE_REPLACED_RESTORE_STATUS='原服务定义已写回；服务管理器状态尚未确认'
    else
        /usr/bin/rm -f -- "$target" || {
            _ui_error '移除 clashctl 服务定义失败，尚未恢复原服务'
            _ui_detail '目标' "$target"
            [ -z "$backup" ] || _ui_detail '保留备份' "$backup"
            return 1
        }
        _SERVICE_REPLACED_RESTORE_STATUS='clashctl 服务定义已移除；原 provider 尚未确认'
    fi
    if [ "$service_manager" = systemd ]; then
        systemctl daemon-reload >/dev/null 2>&1 || {
            _ui_error '恢复原服务后重载 systemd 失败'
            return 1
        }
        if [ -n "$source" ] && [ "$source" != "$target" ]; then
            provider=$(systemctl show -p FragmentPath --value "${CLASHCTL_KERNEL}.service" 2>/dev/null) || provider=
            if [ "$provider" != "$source" ] ||
                { [ ! -e "$source" ] && [ ! -L "$source" ]; }; then
                _ui_error '移除 override 后没有可用的 systemd provider'
                _ui_detail '保留备份' "$backup"
                return 1
            fi
        fi
    fi
    _SERVICE_REPLACED_RESTORE_STATUS='原服务定义已恢复；自启与运行状态尚未恢复'

    if [ "${_SERVICE_REPLACED_ENABLEMENT_MODE:-legacy}" = exact ]; then
        service_enablement_restore "$service_manager" "$CLASHCTL_KERNEL" \
            "$_SERVICE_REPLACED_ENABLEMENT_ORIGINAL" \
            "$_SERVICE_REPLACED_ENABLEMENT_INSTALLED" || enablement_rc=$?
        if [ "$enablement_rc" -ne 0 ]; then
            _ui_error '恢复安装前的精确自启状态失败'
            _ui_detail '原因' "${SERVICE_ENABLEMENT_ERROR:-未知错误}"
            _ui_detail '原始快照' "$_SERVICE_REPLACED_ENABLEMENT_ORIGINAL"
            _ui_detail '安装快照' "$_SERVICE_REPLACED_ENABLEMENT_INSTALLED"
            return 1
        fi
    elif [ "$service_manager" = runit ]; then
        CLASHCTL_SERVICE_ENABLE_LINK=$link
        export CLASHCTL_SERVICE_ENABLE_LINK
        if [ "$original_kind" = symlink ]; then
            _service_restore_enablement 1 "$original_target" >/dev/null 2>&1 || {
                _ui_error '恢复 runit 原自启入口失败'
                _ui_detail '入口' "$link"
                _ui_detail '期望目标' "$original_target"
                _ui_detail '重试' "保留安装目录后重新执行 bash $CLASHCTL_HOME/uninstall.sh --yes"
                return 1
            }
        else
            service_disable >/dev/null 2>&1 || {
                _ui_error '移除 clashctl 写入的 runit 自启入口失败'
                _ui_detail '入口' "$link"
                _ui_detail '重试' "保留安装目录后重新执行 bash $CLASHCTL_HOME/uninstall.sh --yes"
                return 1
            }
        fi
    else
        _service_restore_enablement "$was_enabled" >/dev/null 2>&1 || {
            _ui_error '恢复原服务自启状态失败'
            return 1
        }
    fi
    if [ "${_SERVICE_REPLACED_ENABLEMENT_MODE:-legacy}" != exact ] &&
        [ "$was_enabled" = 1 ]; then
        service_is_enabled || {
            _ui_error '恢复原服务自启状态失败'
            return 1
        }
    elif [ "${_SERVICE_REPLACED_ENABLEMENT_MODE:-legacy}" != exact ] && service_is_enabled; then
        _ui_error '恢复原服务禁用状态失败'
        return 1
    fi
    _SERVICE_REPLACED_RESTORE_STATUS='原服务定义和自启状态已恢复；运行状态尚未恢复'
    if [ "$was_active" = 1 ]; then
        service_start >/dev/null 2>&1 || true
        service_is_active || {
            _ui_error '恢复原服务运行状态失败'
            return 1
        }
    elif service_is_active; then
        _ui_error '恢复原服务停止状态失败'
        return 1
    fi

    _SERVICE_REPLACED_RESTORE_STATUS='原服务定义、自启与运行状态均已恢复'
    _ui_ok "已恢复安装前的同名服务${source:+: $source}"
    return 0
}

uninstall_service() {
    detect_service_manager
    local target restore_rc=0 source=${CLASHCTL_REPLACED_SERVICE_SOURCE:-}
    local backup=${CLASHCTL_REPLACED_SERVICE_BACKUP:-}
    local runit_link=${CLASHCTL_REPLACED_SERVICE_ENABLE_LINK:-}
    local runit_expected=${CLASHCTL_REPLACED_SERVICE_EXPECTED_ENABLE_TARGET:-}
    local runit_kind=${CLASHCTL_REPLACED_SERVICE_ENABLE_KIND:-absent}
    local runit_target=${CLASHCTL_REPLACED_SERVICE_ENABLE_TARGET:-}
    local owns_current_service=0 runit_link_owned=0 restored_definition=0
    local current_kind current_target loaded_fragment exact_enablement=0

    target=$(_service_target) || target=
    _replaced_service_preflight || restore_rc=$?
    [ "$restore_rc" -ne 1 ] || return 1
    [ "${_SERVICE_REPLACED_ENABLEMENT_MODE:-none}" != exact ] || exact_enablement=1

    if [ -n "$target" ] && { [ -e "$target" ] || [ -L "$target" ]; }; then
        if [ "$restore_rc" -eq 0 ] && [ "$source" = "$target" ] &&
            _service_same_object "$target" "$backup"; then
            owns_current_service=0
            restored_definition=1
        elif ! _service_definition_is_owned "$target"; then
            _ui_error "服务定义不再属于 clashctl，拒绝删除: $target"
            return 1
        else
            owns_current_service=1
        fi
    fi
    if [ "$service_manager" = systemd ] && [ -n "$target" ] &&
        [ ! -e "$target" ] && [ ! -L "$target" ] && service_is_active; then
        if _service_systemd_loaded_unit_is_owned "$target"; then
            owns_current_service=1
        elif [ "$restore_rc" -eq 0 ] && [ "$source" != "$target" ]; then
            loaded_fragment=$(_service_systemd_property FragmentPath) || loaded_fragment=
            if [ "$loaded_fragment" != "$source" ]; then
                _ui_error 'systemd 服务定义已缺失且服务仍在运行，无法确认进程归属，拒绝卸载'
                return 1
            fi
        else
            _ui_error 'systemd 服务定义已缺失且服务仍在运行，无法确认进程归属，拒绝卸载'
            return 1
        fi
    fi
    if [ "$service_manager" = runit ] && [ "$exact_enablement" -eq 0 ]; then
        [ -n "$runit_link" ] || runit_link=$(_service_runit_enable_link)
        [ -n "$runit_expected" ] || runit_expected=$(dirname -- "$target")
        _service_runit_uninstall_preflight \
            "$runit_link" "$runit_expected" "$runit_kind" "$runit_target" || return 1
        IFS=$'\t' read -r current_kind current_target < <(_service_runit_link_state "$runit_link")
        if [ "$restored_definition" -eq 0 ] && [ "$current_kind" = symlink ] &&
            [ "$current_target" = "$runit_expected" ]; then
            runit_link_owned=1
        fi
        CLASHCTL_SERVICE_ENABLE_LINK=$runit_link
        export CLASHCTL_SERVICE_ENABLE_LINK
    fi

    [ "$service_manager" != nohup ] || owns_current_service=1
    if [ "$owns_current_service" -eq 1 ] && service_is_active; then
        service_stop >/dev/null 2>&1 || true
        service_is_active && {
            _ui_error "$CLASHCTL_KERNEL 服务仍在运行，已取消卸载"
            return 1
        }
    fi
    if [ "$exact_enablement" -eq 0 ] &&
        { [ "$owns_current_service" -eq 1 ] || [ "$runit_link_owned" -eq 1 ]; } &&
        service_is_enabled; then
        service_disable >/dev/null 2>&1 || true
        service_is_enabled && {
            _ui_error '禁用 clashctl 服务失败，已取消卸载'
            return 1
        }
    fi

    if [ "$restore_rc" -eq 0 ]; then
        _restore_replaced_service_after_uninstall || {
            _ui_error '安装前的同名服务未能完整恢复，卸载已中止'
            _ui_detail '恢复进度' "${_SERVICE_REPLACED_RESTORE_STATUS:-状态未知}"
            _ui_detail '保留目录' "$CLASHCTL_HOME"
            [ -z "$backup" ] || _ui_detail '保留备份' "$backup"
            return 1
        }
        return 0
    fi

    if [ "$service_manager" = sysvinit ]; then
        _service_unregister || {
            _ui_error '注销 SysVinit 服务失败'
            return 1
        }
    fi

    [ -z "$target" ] || /usr/bin/rm -f -- "$target" || {
        _ui_error "移除服务定义失败: $target"
        return 1
    }
    [ "$service_manager" != systemd ] || systemctl daemon-reload >/dev/null 2>&1 || {
        _ui_error '重载 systemd 配置失败'
        return 1
    }
    if [ "$service_manager" = runit ]; then
        rmdir "$(dirname -- "$target")" >/dev/null 2>&1 || true
    fi
    _ui_ok "已注销 ${service_manager} 服务: $CLASHCTL_KERNEL"
    return 0
}
