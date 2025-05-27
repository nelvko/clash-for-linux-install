#!/usr/bin/env bash

_valid_env() {
    _is_root || _error_quit "需要 root 或 sudo 权限执行"
    [ -n "$ZSH_VERSION" ] && [ -n "$BASH_VERSION" ] && _error_quit "仅支持：bash、zsh"
}

_get_kernel() {
    [ -f "$ZIP_CLASH" ] && {
        ZIP_KERNEL=$ZIP_CLASH
        BIN_KERNEL=$BIN_CLASH
    }

    [ -f "$ZIP_MIHOMO" ] && {
        ZIP_KERNEL=$ZIP_MIHOMO
        BIN_KERNEL=$BIN_MIHOMO
    }

    [ ! -f "$ZIP_MIHOMO" ] && [ ! -f "$ZIP_CLASH" ] && {
        # shellcheck disable=SC2155
        local arch=$(uname -m)
        _failcat "${ZIP_BASE_DIR}：未检测到可用的内核压缩包"
        _download_clash "$arch"
        # shellcheck disable=SC2034
        ZIP_KERNEL=$ZIP_CLASH
        BIN_KERNEL=$BIN_CLASH
    }

    KERNEL_NAME=$(basename "$BIN_KERNEL")
}

_get_init() {
    init_type=$(cat /proc/1/comm 2>/dev/null)
    [ -z "$init_type" ] && {
        init_type=$(ps -p 1 -o comm= 2>/dev/null)
    }

    case "${init_type}" in
    systemd)
        service_src="${SCRIPT_INIT_DIR}/systemd.sh"
        service_target="/etc/systemd/system/${KERNEL_NAME}.service"

        service_enable="systemctl enable $KERNEL_NAME >&/dev/null;systemctl daemon-reload"
        service_disable="systemctl disable $KERNEL_NAME >&/dev/null;systemctl daemon-reload"

        service_start="systemctl start $KERNEL_NAME"
        service_is_active="systemctl is-active $KERNEL_NAME"
        service_stop="systemctl stop $KERNEL_NAME"
        service_restart="systemctl restart $KERNEL_NAME"
        service_status="systemctl status $KERNEL_NAME"
        ;;
    init)
        service_src="${SCRIPT_INIT_DIR}/SysVinit.sh"
        service_target="/etc/init.d/$KERNEL_NAME"

        command -v chkconfig >&/dev/null && {
            service_install="chkconfig --add $KERNEL_NAME"
            service_remove="chkconfig --del $KERNEL_NAME"

            service_enable="chkconfig "$KERNEL_NAME" on"
            service_disable="chkconfig "$KERNEL_NAME" off"
        }
        command -v update-rc.d >&/dev/null && {
            service_install="update-rc.d "$KERNEL_NAME" defaults"
            service_remove="update-rc.d "$KERNEL_NAME" remove"

            service_enable="update-rc.d "$KERNEL_NAME" enable"
            service_disable="update-rc.d "$KERNEL_NAME" disable"
        }

        service_start="service $KERNEL_NAME start"
        service_is_active="service $KERNEL_NAME is-active"
        service_stop="service $KERNEL_NAME stop"
        service_restart="service $KERNEL_NAME restart"
        service_status="service $KERNEL_NAME status"
        ;;
    openrc)
        service_src="${SCRIPT_INIT_DIR}/OpenRC.sh"
        service_target="/etc/init.d/$KERNEL_NAME"

        service_enable="rc-update add $KERNEL_NAME default"
        service_disable="rc-update del $KERNEL_NAME default"

        service_start="rc-service $KERNEL_NAME start"
        service_is_active="rc-service $KERNEL_NAME status"
        service_stop="rc-service $KERNEL_NAME stop"
        service_restart="rc-service $KERNEL_NAME restart"
        service_status="rc-service $KERNEL_NAME status"
        ;;
    *)
        _error_quit "不支持的 init 系统：$init_type，请反馈作者适配"
        ;;
    esac
}

_set_init() {
    [ "$1" = "unset" ] && {
        rm -f "$service_target" >&/dev/null
        $service_disable
        $service_remove
        return
    }

    local cmd_path="${BIN_KERNEL}"
    local cmd_arg="-d ${CLASH_RESOURCES_DIR} -f ${CLASH_CONFIG_RUNTIME}"
    local cmd_full="${BIN_KERNEL} -d ${CLASH_RESOURCES_DIR} -f ${CLASH_CONFIG_RUNTIME}"

    local file_pid="${CLASH_RESOURCES_DIR}/pid"
    local file_log="${CLASH_RESOURCES_DIR}/log"
    local KERNEL_DESC="$KERNEL_NAME Daemon, A[nother] Clash Kernel."

    /usr/bin/install -m +x "$service_src" "$service_target"
    $service_install
    $service_enable && _okcat 已设置开机自启
    sed -i \
        -e "s|placeholder_cmd_path|$cmd_path|g" \
        -e "s|placeholder_cmd_args|$cmd_arg|g" \
        -e "s|placeholder_cmd_full|$cmd_full|g" \
        -e "s|placeholder_log_file|$file_log|g" \
        -e "s|placeholder_pid_file|$file_pid|g" \
        -e "s|placeholder_kernel_name|$KERNEL_NAME|g" \
        -e "s|placeholder_kernel_desc|$KERNEL_DESC|g" \
        "$service_target"

    sed -i \
        -e "s|placeholder_start|$service_start|g" \
        -e "s|placeholder_status|$service_status|g" \
        -e "s|placeholder_stop|$service_stop|g" \
        -e "s|placeholder_restart|$service_restart|g" \
        -e "s|placeholder_is_active|$service_is_active|g" \
        "$CLASH_CMD_DIR/clashctl.sh"
}

_download_clash() {
    local arch=$1
    local url sha256sum
    case "$arch" in
    x86_64)
        url=https://downloads.clash.wiki/ClashPremium/clash-linux-amd64-2023.08.17.gz
        sha256sum='92380f053f083e3794c1681583be013a57b160292d1d9e1056e7fa1c2d948747'
        ;;
    *86*)
        url=https://downloads.clash.wiki/ClashPremium/clash-linux-386-2023.08.17.gz
        sha256sum='254125efa731ade3c1bf7cfd83ae09a824e1361592ccd7c0cccd2a266dcb92b5'
        ;;
    armv*)
        url=https://downloads.clash.wiki/ClashPremium/clash-linux-armv5-2023.08.17.gz
        sha256sum='622f5e774847782b6d54066f0716114a088f143f9bdd37edf3394ae8253062e8'
        ;;
    aarch64)
        url=https://downloads.clash.wiki/ClashPremium/clash-linux-arm64-2023.08.17.gz
        sha256sum='c45b39bb241e270ae5f4498e2af75cecc0f03c9db3c0db5e55c8c4919f01afdd'
        ;;
    *)
        _error_quit "未知的架构版本：$arch，请自行下载对应版本至 ${ZIP_BASE_DIR} 目录下：https://downloads.clash.wiki/ClashPremium/"
        ;;
    esac

    _okcat '⏳' "正在下载：clash：${arch} 架构..."
    local clash_zip="${ZIP_BASE_DIR}/$(basename $url)"
    curl \
        --progress-bar \
        --show-error \
        --fail \
        --insecure \
        --connect-timeout 15 \
        --retry 1 \
        --output "$clash_zip" \
        "$url"
    echo $sha256sum "$clash_zip" | sha256sum -c ||
        _error_quit "下载失败：请自行下载对应版本至 ${ZIP_BASE_DIR} 目录下：https://downloads.clash.wiki/ClashPremium/"
}
