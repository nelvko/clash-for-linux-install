# shellcheck disable=SC2148

init_type=$(cat /proc/1/comm 2>/dev/null)
[ -z "$init_type" ] && {
    init_type=$(ps -p 1 -o comm= 2>/dev/null)
}

case "${init_type}" in
# systemd)
#     init_file_src="${SCRIPT_INIT_DIR}/systemd.sh"
#     init_file_target="/etc/systemd/system/${BIN_KERNEL_NAME}.service"
# unset_cmd="systemctl disable $BIN_KERNEL_NAME >&/dev/null;systemctl daemon-reload"

#     start="systemctl start $BIN_KERNEL_NAME"
#     is_active="systemctl is-active $BIN_KERNEL_NAME"
#     stop="systemctl stop $BIN_KERNEL_NAME"
#     status="systemctl status $BIN_KERNEL_NAME"
#     ;;
systemd)
    init_file_src="${SCRIPT_INIT_DIR}/SysVinit.sh"
    init_file_target="/etc/init.d/$BIN_KERNEL_NAME"

    start="service $BIN_KERNEL_NAME start"
    is_active="systemctl is-active $BIN_KERNEL_NAME"
    stop="service $BIN_KERNEL_NAME stop"
    status="service $BIN_KERNEL_NAME status"
    ;;
openrc)
    init_file_src="${SCRIPT_INIT_DIR}/OpenRC.sh"
    init_file_target="/etc/init.d/$BIN_KERNEL_NAME"
    start="rc-service $BIN_KERNEL_NAME start"
    is_active="rc-service $BIN_KERNEL_NAME status"
    stop="rc-service $BIN_KERNEL_NAME stop"
    status="rc-service $BIN_KERNEL_NAME status"
    ;;
*)
    echo "default (none of above)"
    ;;
esac

KERNEL_DESC="$BIN_KERNEL_NAME Daemon, A[nother] Clash Kernel."

cmd_path="${BIN_KERNEL}"
cmd_arg="-d ${CLASH_BASE_DIR} -f ${CLASH_CONFIG_RUNTIME}"
cmd_full="${BIN_KERNEL} -d ${CLASH_BASE_DIR} -f ${CLASH_CONFIG_RUNTIME}"

pid_file="/var/run/${BIN_KERNEL_NAME}.pid"
log_file="/var/log/${BIN_KERNEL_NAME}.log"

setup_init() {
    /bin/install -m +x "$init_file_src" "$init_file_target"
    sed -i \
        -e "s|placeholder_cmd_path|$cmd_path|g" \
        -e "s|placeholder_cmd_args|$cmd_arg|g" \
        -e "s|placeholder_cmd_full|$cmd_full|g" \
        -e "s|placeholder_log_file|$log_file|g" \
        -e "s|placeholder_pid_file|$pid_file|g" \
        -e "s|placeholder_kernel_name|$BIN_KERNEL_NAME|g" \
        -e "s|placeholder_kernel_desc|$KERNEL_DESC|g" \
        "$init_file_target"

    sed -i \
        -e "s|placeholder_start|$start|g" \
        -e "s|placeholder_status|$status|g" \
        -e "s|placeholder_stop|$stop|g" \
        -e "s|placeholder_is_active|$is_active|g" \
        "$CLASH_SCRIPT_DIR/clashctl.sh"
}

unset_int() {
    init_file_target="/etc/init.d/$BIN_KERNEL_NAME"
    rm -f "$init_file_target"
}
