# shellcheck disable=SC2148

init_type=$(cat /proc/1/comm 2>/dev/null)
[ -z "$init_type" ] && {
    init_type=$(ps -p 1 -o comm= 2>/dev/null)
}

[ "$init_type" = 'systemd' ] && {
    init_file_src="init/systemd"
    init_file_target="/etc/systemd/system/${BIN_KERNEL_NAME}.service"

    start="systemctl start $BIN_KERNEL_NAME"
    is_active="systemctl is-active $BIN_KERNEL_NAME"
    stop="systemctl stop $BIN_KERNEL_NAME"
    status="systemctl status $BIN_KERNEL_NAME"
}

[ "$init_type" = 'systemd' ] && {
    init_file_src="init/SysVinit"
    init_file_target="/etc/init.d/$BIN_KERNEL_NAME"

    start="service $BIN_KERNEL_NAME start"
    is_active="systemctl is-active $BIN_KERNEL_NAME"
    stop="service $BIN_KERNEL_NAME stop"
    status="service $BIN_KERNEL_NAME status"
}

[ "$init_type" = 'openrc' ] && {
    init_file_src="init/OpenRC"
    init_file_target="/etc/init.d/$BIN_KERNEL_NAME"
    start="rc-service $BIN_KERNEL_NAME start"
    is_active="rc-service $BIN_KERNEL_NAME status"
    stop="rc-service $BIN_KERNEL_NAME stop"
    status="rc-service $BIN_KERNEL_NAME status"
}

/bin/install -m +x "$init_file_src" "$init_file_target"

start_cmd="${BIN_KERNEL} -d ${CLASH_BASE_DIR} -f ${CLASH_CONFIG_RUNTIME}"
pid_file="/var/run/${BIN_KERNEL_NAME}.pid" # PID 文件路径
log_file="/var/log/${BIN_KERNEL_NAME}.log"
sed -i \
    -e "s|placeholder_cmd|$start_cmd|g" \
    -e "s|placeholder_log|$log_file|g" \
    -e "s|placeholder_pid|$pid_file|g" \
    -e "s|placeholder_kernel|$BIN_KERNEL_NAME|g" \
    "$init_file_target"

sed -i \
    -e "s|placeholder_start|$start|g" \
    -e "s|placeholder_status|$status|g" \
    -e "s|placeholder_stop|$stop|g" \
    -e "s|placeholder_is_active|$is_active|g" \
    "$CLASH_SCRIPT_DIR/clashctl.sh"
