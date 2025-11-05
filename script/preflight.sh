#!/usr/bin/env bash

# shellcheck disable=SC2034
# shellcheck disable=SC2153
set +o noglob >&/dev/null
setopt glob no_nomatch >&/dev/null

home=$HOME
[[ -n "$SUDO_USER" && $CLASH_BASE_DIR == /root* ]] && {
    home=$(awk -F: -v user="$SUDO_USER" '$1==user{print $6}' /etc/passwd)
    CLASH_BASE_DIR=${CLASH_BASE_DIR/\/root/$home}
    _load_base_dir
}

ZIP_BASE_DIR="${RESOURCES_BASE_DIR}/zip"
ZIP_UI="${ZIP_BASE_DIR}/yacd.tar.xz"

FILE_LOG="${CLASH_RESOURCES_DIR}/log"

_valid_required() {
    local required_cmds=("xz" "pgrep" "curl" "tar")
    local missing=()
    for cmd in "${required_cmds[@]}"; do
        command -v "$cmd" >&/dev/null || missing+=("$cmd")
    done
    [ "${#missing[@]}" -gt 0 ] && _error_quit "请先安装以下命令：${missing[*]}"
}

_valid_env() {
    [ -z "$ZSH_VERSION" ] && [ -z "$BASH_VERSION" ] && _error_quit "仅支持：bash、zsh 执行"
}

_parse_args() {
    for arg in "$@"; do
        case $arg in
        mihomo)
            KERNEL_NAME=mihomo
            ;;
        clash)
            KERNEL_NAME=clash
            ;;
        docker)
            command -v docker >&/dev/null || _error_quit "暂未安装 docker"
            docker info &>/dev/null || _error_quit "当前用户无权限运行 docker，需加入 docker 组或使用 sudo 执行安装"
            INIT_TYPE=docker
            _IS_CONTAINER='true'
            ;;
        esac
    done
}

_get_kernel() {
    [ "$_IS_CONTAINER" = 'true' ] && {
        case "${KERNEL_NAME}" in
        clash)
            IMAGE_KERNEL=$IMAGE_CLASH
            ;;
        mihomo | *)
            IMAGE_KERNEL=$IMAGE_MIHOMO
            ;;
        esac
        return
    }

    _load_zip
    [ ! -f "$ZIP_YQ" ] && required_zip+=("yq")
    [ ! -f "$ZIP_SUBCONVERTER" ] && required_zip+=("subconverter")
    case "${KERNEL_NAME}" in
    clash)
        [ ! -f "$ZIP_CLASH" ] && required_zip+=("clash")
        ;;
    mihomo | *)
        [ ! -f "$ZIP_MIHOMO" ] && required_zip+=("mihomo")
        ;;
    esac

    _download_zip

    case "${KERNEL_NAME}" in
    clash)
        ZIP_KERNEL="$ZIP_CLASH"
        ;;
    mihomo | *)
        ZIP_KERNEL="$ZIP_MIHOMO"
        ;;
    esac
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

    service_reload="sudo systemctl daemon-reload"

    service_enable="sudo systemctl enable $KERNEL_NAME"
    service_disable="sudo systemctl disable $KERNEL_NAME"

    service_start="sudo systemctl start $KERNEL_NAME"
    service_is_active="sudo systemctl is-active $KERNEL_NAME"
    service_stop="sudo systemctl stop $KERNEL_NAME"
    service_restart="sudo systemctl restart $KERNEL_NAME"
    service_status="sudo systemctl status $KERNEL_NAME"
}

_nohup() {
    service_enable=""
    service_disable=""

    service_start="( nohup ${BIN_KERNEL} -d ${CLASH_RESOURCES_DIR} -f ${CLASH_CONFIG_RUNTIME} >\&$FILE_LOG \& )"
    service_is_active="pgrep -f $BIN_KERNEL"
    service_stop="pkill -9 -f $BIN_KERNEL"
    service_restart=""
    service_status="less $FILE_LOG"
}

_container() {
    service_start="sudo docker run \
                        -d \
                        --rm \
                        --network host \
                        --name $KERNEL_NAME \
                        -v $CLASH_CONFIG_RUNTIME:/root/.config/${KERNEL_NAME}/config.yaml:ro \
                        -v $CLASH_RESOURCES_DIR:/root/.config/${KERNEL_NAME} \
                        ${URL_CR_PROXY}${IMAGE_KERNEL} >/dev/null"
    service_restart="sudo docker restart $KERNEL_NAME"
    service_is_active="sudo docker inspect -f {{.State.Running}} $KERNEL_NAME 2>/dev/null | grep -q true"
    service_stop="sudo docker stop $KERNEL_NAME"
    service_status="sudo docker logs $KERNEL_NAME"
    service_check_tun="clashstatus"
}
# nohup：无root、容器环境、autodl
_get_init() {
    _set_bin

    [ -z "$INIT_TYPE" ] && {
        INIT_TYPE=$(cat /proc/1/comm 2>/dev/null)
        [ -z "$INIT_TYPE" ] && INIT_TYPE=$(ps -p 1 -o comm= 2>/dev/null)
        _has_root || INIT_TYPE='nohup'
        grep -qsE "docker|kubepods|containerd|podman" /proc/1/cgroup && INIT_TYPE='nohup'
    }
    case "${INIT_TYPE}" in
    systemd)
        _systemd
        service_check_tun="sudo journalctl -u $KERNEL_NAME --since '1 min ago'"
        ;;
    init)
        [ "$(basename "$(readlink -f /sbin/init)")" = "busybox" ] && {
            _openrc
            return
        }
        _sysvinit
        service_check_tun="clashstatus"
        ;;
    docker)
        _container
        ;;
    nohup | *)
        _nohup
        service_check_tun="clashstatus"
        INIT_TYPE='nohup'
        ;;
    esac
}

_set_init() {
    local KERNEL_DESC="$KERNEL_NAME Daemon, A[nother] Clash Kernel."

    local cmd_path="${BIN_KERNEL}"
    local cmd_arg="-d ${CLASH_RESOURCES_DIR} -f ${CLASH_CONFIG_RUNTIME}"
    local cmd_full="${BIN_KERNEL} -d ${CLASH_RESOURCES_DIR} -f ${CLASH_CONFIG_RUNTIME}"

    [ -n "$service_src" ] && {
        /usr/bin/install -m +x "$service_src" "$service_target"
        $service_add
        sed -i \
            -e "s#placeholder_cmd_path#$cmd_path#g" \
            -e "s#placeholder_cmd_args#$cmd_arg#g" \
            -e "s#placeholder_cmd_full#$cmd_full#g" \
            -e "s#placeholder_log_file#$FILE_LOG#g" \
            -e "s#placeholder_pid_file#$FILE_PID#g" \
            -e "s#placeholder_kernel_name#$KERNEL_NAME#g" \
            -e "s#placeholder_kernel_desc#$KERNEL_DESC#g" \
            "$service_target"
    }

    sed -i \
        -e "s#placeholder_bin_kernel#$BIN_KERNEL#g" \
        -e "s#placeholder_start#$service_start#g" \
        -e "s#placeholder_status#$service_status#g" \
        -e "s#placeholder_stop#$service_stop#g" \
        -e "s#placeholder_restart#$service_restart#g" \
        -e "s#placeholder_is_active#$service_is_active#g" \
        -e "s#placeholder_check_tun#$service_check_tun#g" \
        "$CLASH_CMD_DIR/clashctl.sh" "$CLASH_CMD_DIR/common.sh"

    $service_reload
    $service_enable >&/dev/null && _okcat '🚀' '已设置开机自启'

    sed -i "/\$placeholder_bin/{
        r /dev/stdin
        d
    }" "$CLASH_CMD_DIR/common.sh" <<<"$BIN_VAR"

}
_unset_init() {
    $service_disable >&/dev/null
    $service_del
    rm -f "$service_target"
    rm -f "$FILE_PID"
    rm -f "$FILE_LOG"
    $service_reload
}

_get_rc() {
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
}
_set_rc() {
    _get_rc
    echo "source $CLASH_CMD_DIR/clashctl.sh && watch_proxy" |
        tee -a "$SHELL_RC_BASH" "$SHELL_RC_ZSH" >&/dev/null
    [ -n "$SHELL_RC_FISH" ] && /usr/bin/install "$SCRIPT_FISH" "$SHELL_RC_FISH"
}
_unset_rc() {
    _get_rc
    sed -i "\|clashctl.sh|d" "$SHELL_RC_BASH" "$SHELL_RC_ZSH" 2>/dev/null
    rm -f "$SHELL_RC_FISH" 2>/dev/null
}

# shellcheck disable=SC2155
_download_zip() {
    local arch=$(uname -m)
    local url_clash url_mihomo url_yq url_subconverter

    case "$arch" in
    x86_64)
        url_clash=https://downloads.clash.wiki/ClashPremium/clash-linux-amd64-2023.08.17.gz
        url_mihomo=https://github.com/MetaCubeX/mihomo/releases/download/v1.19.15/mihomo-linux-amd64-v1.19.15.gz
        url_yq=https://github.com/mikefarah/yq/releases/download/v4.48.1/yq_linux_amd64.tar.gz
        url_subconverter=https://github.com/tindy2013/subconverter/releases/download/v0.9.0/subconverter_linux64.tar.gz
        ;;
    *86*)
        url_clash=https://downloads.clash.wiki/ClashPremium/clash-linux-386-2023.08.17.gz
        url_mihomo=https://github.com/MetaCubeX/mihomo/releases/download/v1.19.15/mihomo-linux-386-v1.19.15.gz
        url_yq=https://github.com/mikefarah/yq/releases/download/v4.48.1/yq_linux_386.tar.gz
        url_subconverter=https://github.com/tindy2013/subconverter/releases/download/v0.9.0/subconverter_linux32.tar.gz
        ;;
    armv*)
        url_clash=https://downloads.clash.wiki/ClashPremium/clash-linux-armv5-2023.08.17.gz
        url_mihomo=https://github.com/MetaCubeX/mihomo/releases/download/v1.19.15/mihomo-linux-armv7-v1.19.15.gz
        url_yq=https://github.com/mikefarah/yq/releases/download/v4.48.1/yq_linux_arm.tar.gz
        url_subconverter=https://github.com/tindy2013/subconverter/releases/download/v0.9.0/subconverter_armv7.tar.gz
        ;;
    aarch64)
        url_clash=https://downloads.clash.wiki/ClashPremium/clash-linux-arm64-2023.08.17.gz
        url_mihomo=https://github.com/MetaCubeX/mihomo/releases/download/v1.19.15/mihomo-linux-arm64-v1.19.15.gz
        url_yq=https://github.com/mikefarah/yq/releases/download/v4.48.1/yq_linux_arm64.tar.gz
        url_subconverter=https://github.com/tindy2013/subconverter/releases/download/v0.9.0/subconverter_aarch64.tar.gz
        ;;
    *)
        _error_quit "未知的架构版本：$arch，请自行下载对应版本至 ${ZIP_BASE_DIR} 目录"
        ;;
    esac

    local -A urls=(
        [clash]="$url_clash"
        [mihomo]="$url_mihomo"
        [yq]="$url_yq"
        [subconverter]="$url_subconverter"
    )

    local key fail_zip
    for key in "${required_zip[@]}"; do
        local url="${urls[$key]}"
        local proxy_url="${URL_GH_PROXY}${url}"
        [ "$key" != 'clash' ] && url="$proxy_url"
        _okcat '⏳' "正在下载：${key}..."
        local target="${ZIP_BASE_DIR}/$(basename "$url")"
        curl \
            --progress-bar \
            --show-error \
            --fail \
            --insecure \
            --location \
            --max-time 30 \
            --retry 1 \
            --output "$target" \
            "$url" || fail_zip+=("$key")
    done

    [ ${#fail_zip[@]} -gt 0 ] && _error_quit "下载失败：${fail_zip[*]}，请自行下载对应版本至 ${ZIP_BASE_DIR} 目录"
    _load_zip
}
_load_zip() {
    ZIP_CLASH=$(echo "${ZIP_BASE_DIR}"/clash*)
    ZIP_MIHOMO=$(echo "${ZIP_BASE_DIR}"/mihomo*)
    ZIP_YQ=$(echo "${ZIP_BASE_DIR}"/yq*)
    ZIP_SUBCONVERTER=$(echo "${ZIP_BASE_DIR}"/subconverter*)
}
# shellcheck disable=SC2016
_bin_host() {
    valid_config_cmd='$BIN_KERNEL -d $(dirname $1) -f $1 -t'
    BIN_BASE_DIR="${CLASH_BASE_DIR}/bin"
    BIN_KERNEL="${BIN_BASE_DIR}/$KERNEL_NAME"
    BIN_YQ="${BIN_BASE_DIR}/yq"
    BIN_SUBCONVERTER_DIR="${BIN_BASE_DIR}/subconverter"
    BIN_SUBCONVERTER="${BIN_SUBCONVERTER_DIR}/subconverter"
    BIN_SUBCONVERTER_START="($BIN_SUBCONVERTER >& $BIN_SUBCONVERTER_LOG &)"
    BIN_SUBCONVERTER_STOP="pkill -9 -f $BIN_SUBCONVERTER"
    BIN_SUBCONVERTER_CONFIG="$BIN_SUBCONVERTER_DIR/pref.yml"
    BIN_SUBCONVERTER_LOG="${BIN_SUBCONVERTER_DIR}/latest.log"
}
# shellcheck disable=SC2329
_bin_container() {
    valid_config_cmd='sudo docker run \
                            --rm \
                            -v $1:/root/.config/${KERNEL_NAME}/config.yaml:ro \
                            -v $(dirname $1):/root/.config/${KERNEL_NAME} \
                            ${URL_CR_PROXY}${IMAGE_KERNEL} \
                            -t'
    yq1() {
        sudo docker run \
            --rm \
            -i \
            -u "$(id -u):$(id -u)" \
            -v "${CLASH_BASE_DIR}":"${CLASH_BASE_DIR}" \
            "${URL_CR_PROXY}"mikefarah/yq "$@"
    }
    BIN_YQ="yq1"
    BIN_SUBCONVERTER_START="sudo docker run \
                                --rm \
                                -d \
                                -p ${BIN_SUBCONVERTER_PORT}:25500 \
                                --network bridge \
                                --name subconverter \
                                ${URL_CR_PROXY}tindy2013/subconverter"
    BIN_SUBCONVERTER_STOP="sudo docker stop subconverter"
    BIN_SUBCONVERTER_LOG="sudo docker logs subconverter"
}

_set_bin() {
    local _bin_var
    [ "$_IS_CONTAINER" != 'true' ] && {
        _bin_host
        _bin_var=_bin_host
        /usr/bin/install -D <(gzip -dc "$ZIP_KERNEL") "$BIN_KERNEL"
        tar -xf "$ZIP_YQ" -C "${BIN_BASE_DIR}"
        /bin/mv -f "${BIN_BASE_DIR}"/yq_* "${BIN_BASE_DIR}/yq"
        tar -xf "$ZIP_SUBCONVERTER" -C "$BIN_BASE_DIR"
        /bin/cp "$BIN_SUBCONVERTER_DIR/pref.example.yml" "$BIN_SUBCONVERTER_CONFIG"
    }

    [ "$_IS_CONTAINER" = 'true' ] && {
        _bin_container
        _bin_var=_bin_container

    }
    tar -xf "$ZIP_UI" -C "$CLASH_RESOURCES_DIR"
    BIN_VAR=$(typeset -f $_bin_var | sed '1,2d;$d')
}

_set_env() {
    local key=$1
    local value=$2
    local env_path="${CLASH_BASE_DIR}/.env"

    grep -qE "^${key}=" "$env_path" && {
        value=${value//&/\\&}
        sed -i "s|^${key}=.*|${key}=${value}|" "$env_path"
        return $?
    }
    echo "${key}=${value}" >>"$env_path"
}

_set_envs() {
    _set_env CLASH_CONFIG_URL "$CLASH_CONFIG_URL"
    _set_env INIT_TYPE "$INIT_TYPE"
    _set_env KERNEL_NAME "$KERNEL_NAME"
    _set_env CLASH_BASE_DIR "$CLASH_BASE_DIR"

}

_get_random_val() {
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 6
}