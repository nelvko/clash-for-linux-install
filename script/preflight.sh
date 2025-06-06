#!/usr/bin/env bash

# shellcheck disable=SC2034
# shellcheck disable=SC2153
ZIP_BASE_DIR="${RESOURCES_BASE_DIR}/zip"
ZIP_CLASH=$(echo "${ZIP_BASE_DIR}"/clash*)
ZIP_MIHOMO=$(echo "${ZIP_BASE_DIR}"/mihomo*)
ZIP_YQ=$(echo "${ZIP_BASE_DIR}"/yq*)
ZIP_SUBCONVERTER=$(echo "${ZIP_BASE_DIR}"/subconverter*)
ZIP_UI="${ZIP_BASE_DIR}/yacd.tar.xz"

[ "$1" = 'unset' ] && is_unset=true

_valid_env() {
    _is_root || _error_quit "需要 root 或 sudo 权限执行"
    [ -n "$ZSH_VERSION" ] && [ -n "$BASH_VERSION" ] && _error_quit "仅支持：bash、zsh"
}

_get_kernel() {
    [ "$is_unset" = true ] && {
        KERNEL_NAME=$(basename "${BIN_MIHOMO:-$BIN_CLASH}")
        return
    }
    ZIP_KERNEL=$ZIP_MIHOMO
    BIN_KERNEL=$BIN_MIHOMO
    for arg in "$@"; do
        case "$arg" in
        clash)
            [ ! -f "$ZIP_CLASH" ] && _download_clash "$(uname -m)"
            ZIP_KERNEL=$(echo "${ZIP_BASE_DIR}"/clash*)
            BIN_KERNEL=$BIN_CLASH
            ;;
        docker)
            container='docker'
            ;;
        podman)
            container='podman'
            ;;
        esac
    done
    KERNEL_NAME=$(basename "$BIN_KERNEL")
}

_openrc() {
    service_src="${SCRIPT_INIT_DIR}/OpenRC.sh"
    service_target="/etc/init.d/$KERNEL_NAME"

    service_enable="rc-update add $KERNEL_NAME default"
    service_disable="rc-update del $KERNEL_NAME default"

    service_start="rc-service $KERNEL_NAME start"
    service_is_active="rc-service $KERNEL_NAME status"
    service_stop="rc-service $KERNEL_NAME stop"
    service_restart="rc-service $KERNEL_NAME restart"
    service_status="rc-service $KERNEL_NAME status"
}

_sysvinit() {
    service_src="${SCRIPT_INIT_DIR}/SysVinit.sh"
    service_target="/etc/init.d/$KERNEL_NAME"

    command -v chkconfig >&/dev/null && {
        service_add="chkconfig --add $KERNEL_NAME"
        service_del="chkconfig --del $KERNEL_NAME"

        service_enable="chkconfig $KERNEL_NAME on"
        service_disable="chkconfig $KERNEL_NAME off"
    }
    command -v update-rc.d >&/dev/null && {
        service_add="update-rc.d $KERNEL_NAME defaults"
        service_del="update-rc.d $KERNEL_NAME remove"

        service_enable="update-rc.d $KERNEL_NAME enable"
        service_disable="update-rc.d $KERNEL_NAME disable"
    }

    service_start="service $KERNEL_NAME start"
    service_is_active="service $KERNEL_NAME is-active"
    service_stop="service $KERNEL_NAME stop"
    service_restart="service $KERNEL_NAME restart"
    service_status="service $KERNEL_NAME status"
}

_systemd() {
    service_src="${SCRIPT_INIT_DIR}/systemd.sh"
    service_target="/etc/systemd/system/${KERNEL_NAME}.service"

    service_reload="systemctl daemon-reload"

    service_enable="systemctl enable $KERNEL_NAME"
    service_disable="systemctl disable $KERNEL_NAME"

    service_start="systemctl start $KERNEL_NAME"
    service_is_active="systemctl is-active $KERNEL_NAME"
    service_stop="systemctl stop $KERNEL_NAME"
    service_restart="systemctl restart $KERNEL_NAME"
    service_status="systemctl status $KERNEL_NAME"
}

_get_init() {
    [ -n "$container" ] && return
    init_type=$(cat /proc/1/comm 2>/dev/null)
    [ -z "$init_type" ] && {
        init_type=$(ps -p 1 -o comm= 2>/dev/null)
    }

    case "${init_type}" in
    systemd)
        _systemd
        ;;
    init)
        [ "$(basename $(readlink -f /sbin/init))" = "busybox" ] && _openrc || _sysvinit
        ;;
    *)
        _error_quit "不支持的 init 系统：$init_type，请反馈作者适配"
        ;;
    esac
}

_set_container() {
    service_start='docker start mihomo'
    service_restart='docker restart mihomo'
    service_is_active='docker inspect -f {{.State.Running}} mihomo 2>/dev/null | grep -q true'
    service_stop="docker stop mihomo"
    service_status='docker stats mihomo'

    sed -i \
        -e "s|placeholder_kernel_name|$KERNEL_NAME|g" \
        -e "s|placeholder_bin_kernel|$BIN_KERNEL|g" \
        -e "s|placeholder_start|$service_start|g" \
        -e "s|placeholder_status|$service_status|g" \
        -e "s|placeholder_stop|$service_stop|g" \
        -e "s|placeholder_restart|$service_restart|g" \
        -e "s#placeholder_is_active#$service_is_active#g" \
        "$CLASH_CMD_DIR/clashctl.sh" "$CLASH_CMD_DIR/common.sh"

}
_set_init() {
    [ -n "$container" ] && {
        _set_container
        return
    }

    file_pid="/run/${KERNEL_NAME}.pid"
    file_log="/var/log/${KERNEL_NAME}.log"

    [ "$is_unset" = true ] && {
        $service_disable >&/dev/null
        $service_del
        rm -f "$service_target"
        rm -f "$file_pid"
        rm -f "$file_log"
        $service_reload
        return
    }

    /usr/bin/install -m +x "$service_src" "$service_target"
    $service_add

    local file_pid="/run/${KERNEL_NAME}.pid"
    local file_log="/var/log/${KERNEL_NAME}.log"
    local KERNEL_DESC="$KERNEL_NAME Daemon, A[nother] Clash Kernel."

    local cmd_path="${BIN_KERNEL}"
    local cmd_arg="-d ${CLASH_RESOURCES_DIR} -f ${CLASH_CONFIG_RUNTIME}"
    local cmd_full="${BIN_KERNEL} -d ${CLASH_RESOURCES_DIR} -f ${CLASH_CONFIG_RUNTIME}"

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
        -e "s|placeholder_kernel_name|$KERNEL_NAME|g" \
        -e "s|placeholder_bin_kernel|$BIN_KERNEL|g" \
        -e "s|placeholder_start|$service_start|g" \
        -e "s|placeholder_status|$service_status|g" \
        -e "s|placeholder_stop|$service_stop|g" \
        -e "s|placeholder_restart|$service_restart|g" \
        -e "s|placeholder_is_active|$service_is_active|g" \
        "$CLASH_CMD_DIR/clashctl.sh" "$CLASH_CMD_DIR/common.sh"

    $service_reload
    $service_enable >&/dev/null && _okcat '🚀' '已设置开机自启'
}

_set_rc() {
    home=$HOME
    [ -n "$SUDO_USER" ] && {
        home=$(awk -F: -v user="$SUDO_USER" '$1==user{print $6}' /etc/passwd)
    }
    command -v bash >&/dev/null && {
        SHELL_RC_BASH="${home}/.bashrc"
    }
    command -v zsh >&/dev/null && {
        SHELL_RC_ZSH="${home}/.zshrc"
    }
    command -v fish >&/dev/null && {
        SHELL_RC_FISH="${home}/.config/fish/conf.d/clashctl.fish"
    }

    [ "$is_unset" = true ] && {
        sed -i "\|$CLASH_CMD_DIR|d" "$SHELL_RC_BASH" "$SHELL_RC_ZSH" 2>/dev/null
        rm -f "$SHELL_RC_FISH" 2>/dev/null
        return
    }

    echo "source $CLASH_CMD_DIR/common.sh && source $CLASH_CMD_DIR/clashctl.sh && watch_proxy" |
        tee -a "$SHELL_RC_BASH" "$SHELL_RC_ZSH" >&/dev/null
    [ -n "$SHELL_RC_FISH" ] && /usr/bin/install "$SCRIPT_FISH" "$SHELL_RC_FISH"
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
    clash_zip="${ZIP_BASE_DIR}/$(basename $url)"
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
