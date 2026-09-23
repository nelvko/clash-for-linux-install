#!/usr/bin/env bash

if ! declare -F _service_process_record_pid >/dev/null 2>&1; then
    _service_process_lib_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
    # shellcheck source=scripts/lib/service-process.sh
    . "${_service_process_lib_dir}/service-process.sh"
    unset _service_process_lib_dir
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

_service_nohup_start_locked() {    local pid expected_argv
    expected_argv=$(_service_process_values_argv_hex \
        "$BIN_KERNEL" -d "$CLASH_RESOURCES_DIR" -f "$CLASH_CONFIG_RUNTIME") || return 1
    if _service_process_record_pid "$service_pid_path" >/dev/null 2>&1; then
        [ "$_SERVICE_RECORD_ARGV" = "$expected_argv" ]
        return
    fi
    command rm -f -- "$service_pid_path" || return 1
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
        command rm -f -- "$service_pid_path"
        return 1
    }
}

_service_nohup_stop_locked() {
    [ -e "$service_pid_path" ] || [ -L "$service_pid_path" ] || return 0
    if ! _service_process_record_load "$service_pid_path"; then
        command rm -f -- "$service_pid_path"
        return 0
    fi
    _service_process_stop_recorded "$service_pid_path" || return 1
    [ "${_SERVICE_PROCESS_RECORD_CAN_REMOVE:-0}" -eq 0 ] ||
        command rm -f -- "$service_pid_path"
}

service_start() {
    _require_base_config || return 1
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
        # runit 需要先加入监督目录才能启动；此时主配置与 runtime 必须已有效。
        _valid_config "$CLASH_CONFIG_RUNTIME" || return 1
        service_enable || return 1
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
    if _is_root; then
        service_start
        return
    fi
    _require_base_config || return 1
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
    local owner_uid helper expected_argv rc=0
    owner_uid=$(id -u) || return 1
    helper=${_SERVICE_PROCESS_HELPER_FILE:-}
    [ -r "$helper" ] || return 1
    expected_argv=$(_service_process_values_argv_hex \
        "$BIN_KERNEL" -d "$CLASH_RESOURCES_DIR" -f "$CLASH_CONFIG_RUNTIME") || return 1
    sudo bash "$helper" privileged-stop "$owner_uid" "$CLASHCTL_KERNEL" "$expected_argv" || rc=$?
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

_service_runit_enable_link() {
    printf '%s\n' "/etc/runit/runsvdir/default/${CLASHCTL_KERNEL}"
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
        command rm -f -- "$tmp"
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
        [ "$current_kind" = absent ] ||
            { [ "$current_kind" = symlink ] && [ "$current_target" = "$desired_target" ]; } || return 1
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
        if [ "$current_target" != "$desired_target" ]; then
            return 1
        fi
        command rm -f -- "$enable_link"
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


# 不接管外部同名服务；用户先自行处理冲突。
_service_check_conflict() {
    local target fragment
    detect_service_manager
    target=$(_service_target) || return 0
    if [ -e "$target" ] || [ -L "$target" ]; then
        [ ! -L "$target" ] && _service_definition_is_owned "$target" && return 0
        _ui_error "同名服务已存在，请先处理后重试：$target"
        return 1
    fi
    if [ "$service_manager" = systemd ]; then
        fragment=$(systemctl show "$CLASHCTL_KERNEL.service" -p FragmentPath --value) || return 1
        [ -z "$fragment" ] || { _ui_error "同名服务已存在：$fragment"; return 1; }
    fi
}

install_service() (
    local target candidate mode=0755
    detect_service_manager
    _service_check_conflict || return 1
    target=$(_service_target) || return 0
    candidate=$(mktemp) || return 1
    trap 'rm -f -- "$candidate"' EXIT
    _render_service_unit "$candidate" || return 1
    [ "$service_manager" != systemd ] || mode=0644
    install -D -m "$mode" "$candidate" "$target" || return 1
    [ "$service_manager" != systemd ] || systemctl daemon-reload || return 1
    # 这里只注册服务；有效配置启动成功后才设置自启。
    return 0
)

# stop 与卸载共用，停止用户进程后再处理本用户的特权进程。
service_stop_checked() {
    if service_is_active; then
        service_stop || true
        if service_is_active && _service_privileged_marker_exists; then
            service_sudo_stop || { _ui_error '特权内核未能停止，请先执行 clashctl stop 后重试'; return 1; }
        fi
        service_is_active && { _ui_error '服务未能停止'; return 1; }
    fi
    return 0
}

uninstall_service() {
    local target
    detect_service_manager
    _service_check_conflict || return 1
    service_stop_checked || return 1
    target=$(_service_target) || return 0
    service_disable || return 1
    _service_unregister || return 1
    rm -f -- "$target" || return 1
    [ "$service_manager" != systemd ] || systemctl daemon-reload || return 1
    return 0
}
