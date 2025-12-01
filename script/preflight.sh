#!/usr/bin/env bash

# shellcheck disable=SC2034
# shellcheck disable=SC2153

RESOURCES_BASE_DIR='resources'
RESOURCES_CONFIG="${RESOURCES_BASE_DIR}/config.yaml"
RESOURCES_CONFIG_MIXIN="${RESOURCES_BASE_DIR}/mixin.yaml"

ZIP_BASE_DIR="${RESOURCES_BASE_DIR}/zip"
ZIP_UI="${ZIP_BASE_DIR}/yacd.tar.xz"

SCRIPT_BASE_DIR='script'
SCRIPT_INIT_DIR="${SCRIPT_BASE_DIR}/init"
SCRIPT_CMD_DIR="${SCRIPT_BASE_DIR}/cmd"
SCRIPT_CMD_FISH="${SCRIPT_CMD_DIR}/clashctl.fish"

CLASH_CMD_DIR="${CLASH_BASE_DIR}/$SCRIPT_CMD_DIR"

FILE_LOG="${CLASH_RESOURCES_DIR}/log"
FILE_PID="${CLASH_RESOURCES_DIR}/pid"

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
        esac
    done
}

_get_kernel() {
    _load_zip >&/dev/null
    local required_zip=()
    case "${KERNEL_NAME}" in
    clash)
        [ ! -f "$ZIP_CLASH" ] && required_zip+=("clash")
        ;;
    mihomo | *)
        [ ! -f "$ZIP_MIHOMO" ] && required_zip+=("mihomo")
        ;;
    esac
    [ ! -f "$ZIP_YQ" ] && required_zip+=("yq")
    [ ! -f "$ZIP_SUBCONVERTER" ] && required_zip+=("subconverter")

    _download_zip "${required_zip[@]}"

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

    service_enable=(rc-update add "$KERNEL_NAME" default)
    service_disable=(rc-update del "$KERNEL_NAME" default)

    service_start=(rc-service "$KERNEL_NAME" start)
    service_is_active=(rc-service "$KERNEL_NAME" status)
    service_stop=(rc-service "$KERNEL_NAME" stop)
    service_restart=(rc-service "$KERNEL_NAME" restart)
    service_status=(rc-service "$KERNEL_NAME" status)
}

_sysvinit() {
    service_src="${SCRIPT_INIT_DIR}/SysVinit.sh"
    service_target="/etc/init.d/$KERNEL_NAME"

    command -v chkconfig >&/dev/null && {
        service_add=(chkconfig --add "$KERNEL_NAME")
        service_del=(chkconfig --del "$KERNEL_NAME")

        service_enable=(chkconfig "$KERNEL_NAME" on)
        service_disable=(chkconfig "$KERNEL_NAME" off)
    }
    command -v update-rc.d >&/dev/null && {
        service_add=(update-rc.d "$KERNEL_NAME" defaults)
        service_del=(update-rc.d "$KERNEL_NAME" remove)

        service_enable=(update-rc.d "$KERNEL_NAME" enable)
        service_disable=(update-rc.d "$KERNEL_NAME" disable)
    }

    service_start=(service "$KERNEL_NAME" start)
    service_is_active=(service "$KERNEL_NAME" is-active)
    service_stop=(service "$KERNEL_NAME" stop)
    service_restart=(service "$KERNEL_NAME" restart)
    service_status=(service "$KERNEL_NAME" status)
}

_systemd() {
    service_src="${SCRIPT_INIT_DIR}/systemd.sh"
    service_target="/etc/systemd/system/${KERNEL_NAME}.service"

    service_reload=(sudo systemctl daemon-reload)

    service_enable=(sudo systemctl enable "$KERNEL_NAME")
    service_disable=(sudo systemctl disable "$KERNEL_NAME")

    service_start=(sudo systemctl start "$KERNEL_NAME")
    service_is_active=(sudo systemctl is-active "$KERNEL_NAME")
    service_stop=(sudo systemctl stop "$KERNEL_NAME")
    service_restart=(sudo systemctl restart "$KERNEL_NAME")
    service_status=(sudo systemctl status "$KERNEL_NAME")
}

_nohup() {
    service_enable=(false)
    service_disable=(false)

    service_start=( '(' nohup "$BIN_KERNEL" -d "$CLASH_RESOURCES_DIR" -f "$CLASH_CONFIG_RUNTIME" '>\&' "$FILE_LOG" '\&' ')' )
    service_is_active=(pgrep -f "$BIN_KERNEL")
    service_stop=(pkill -9 -f "$BIN_KERNEL")
    service_status=(less "$FILE_LOG")
}

_get_init() {
    [ -z "$INIT_TYPE" ] && {
        INIT_TYPE=$(readlink /proc/1/exe)
        _has_root || INIT_TYPE='nohup'
        grep -qsE "docker|kubepods|containerd|podman|lxc" /proc/1/cgroup && INIT_TYPE='nohup'
    }
    service_check_tun="clashstatus"
    case "${INIT_TYPE}" in
    *systemd*)
        _systemd
        service_check_tun="sudo journalctl -u $KERNEL_NAME --since '1 min ago'"
        ;;
    *init*)
        _sysvinit
        ;;
    *busybox*)
        _openrc
        ;;
    nohup | *)
        INIT_TYPE='nohup'
        _nohup
        ;;
    esac
    INIT_TYPE=$(basename "$INIT_TYPE")
}

_set_init() {
    local kernel_desc="$KERNEL_NAME Daemon, A[nother] Clash Kernel."

    local cmd_path="${BIN_KERNEL}"
    local cmd_arg="-d ${CLASH_RESOURCES_DIR} -f ${CLASH_CONFIG_RUNTIME}"
    local cmd_full="${BIN_KERNEL} -d ${CLASH_RESOURCES_DIR} -f ${CLASH_CONFIG_RUNTIME}"

    [ -n "$service_src" ] && {
        /usr/bin/install -m +x "$service_src" "$service_target"
        ((${#service_add[@]})) && "${service_add[@]}"
        sed -i \
            -e "s#placeholder_cmd_path#$cmd_path#g" \
            -e "s#placeholder_cmd_args#$cmd_arg#g" \
            -e "s#placeholder_cmd_full#$cmd_full#g" \
            -e "s#placeholder_log_file#$FILE_LOG#g" \
            -e "s#placeholder_pid_file#$FILE_PID#g" \
            -e "s#placeholder_kernel_name#$KERNEL_NAME#g" \
            -e "s#placeholder_kernel_desc#$kernel_desc#g" \
            "$service_target"
    }

    sed -i \
        -e "s#placeholder_start#${service_start[*]}#g" \
        -e "s#placeholder_status#${service_status[*]}#g" \
        -e "s#placeholder_stop#${service_stop[*]}#g" \
        -e "s#placeholder_is_active#${service_is_active[*]}#g" \
        -e "s#placeholder_check_tun#${service_check_tun[*]}#g" \
        "$CLASH_CMD_DIR/clashctl.sh" "$CLASH_CMD_DIR/common.sh"

    ((${#service_reload[@]})) && "${service_reload[@]}"
    "${service_enable[@]}" >&/dev/null && _okcat '🚀' '已设置开机自启'
}
_unset_init() {
    _get_init
    "${service_disable[@]}" >&/dev/null
    ((${#service_del[@]})) && "${service_del[@]}"
    rm -f "$service_target"
    ((${#service_reload[@]})) && "${service_reload[@]}"
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
    [ -n "$SHELL_RC_FISH" ] && /usr/bin/install "$SCRIPT_CMD_FISH" "$SHELL_RC_FISH"
    source "$CLASH_CMD_DIR/clashctl.sh"
}
_unset_rc() {
    _get_rc
    sed -i "\|clashctl.sh|d" "$SHELL_RC_BASH" "$SHELL_RC_ZSH" 2>/dev/null
    rm -f "$SHELL_RC_FISH" 2>/dev/null
}

# shellcheck disable=SC2155
_download_zip() {
    (($#)) || return 0
    local arch=$(uname -m)
    local url_clash url_mihomo url_yq url_subconverter

    case "$arch" in
    x86_64)
        url_clash=https://downloads.clash.wiki/ClashPremium/clash-linux-amd64-2023.08.17.gz
        url_mihomo=https://github.com/MetaCubeX/mihomo/releases/download/${VERSION_MIHOMO}/mihomo-linux-amd64-${VERSION_MIHOMO}.gz
        url_yq=https://github.com/mikefarah/yq/releases/download/${VERSION_YQ}/yq_linux_amd64.tar.gz
        url_subconverter=https://github.com/tindy2013/subconverter/releases/download/${VERSION_SUBCONVERTER}/subconverter_linux64.tar.gz
        ;;
    *86*)
        url_clash=https://downloads.clash.wiki/ClashPremium/clash-linux-386-2023.08.17.gz
        url_mihomo=https://github.com/MetaCubeX/mihomo/releases/download/${VERSION_MIHOMO}/mihomo-linux-386-${VERSION_MIHOMO}.gz
        url_yq=https://github.com/mikefarah/yq/releases/download/${VERSION_YQ}/yq_linux_386.tar.gz
        url_subconverter=https://github.com/tindy2013/subconverter/releases/download/${VERSION_SUBCONVERTER}/subconverter_linux32.tar.gz
        ;;
    armv*)
        url_clash=https://downloads.clash.wiki/ClashPremium/clash-linux-armv5-2023.08.17.gz
        url_mihomo=https://github.com/MetaCubeX/mihomo/releases/download/${VERSION_MIHOMO}/mihomo-linux-armv7-${VERSION_MIHOMO}.gz
        url_yq=https://github.com/mikefarah/yq/releases/download/${VERSION_YQ}/yq_linux_arm.tar.gz
        url_subconverter=https://github.com/tindy2013/subconverter/releases/download/${VERSION_SUBCONVERTER}/subconverter_armv7.tar.gz
        ;;
    aarch64)
        url_clash=https://downloads.clash.wiki/ClashPremium/clash-linux-arm64-2023.08.17.gz
        url_mihomo=https://github.com/MetaCubeX/mihomo/releases/download/${VERSION_MIHOMO}/mihomo-linux-arm64-${VERSION_MIHOMO}.gz
        url_yq=https://github.com/mikefarah/yq/releases/download/${VERSION_YQ}/yq_linux_arm64.tar.gz
        url_subconverter=https://github.com/tindy2013/subconverter/releases/download/${VERSION_SUBCONVERTER}/subconverter_aarch64.tar.gz
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

    local item target_zip=()
    for item in "$@"; do
        local url="${urls[$item]}"
        local proxy_url="${URL_GH_PROXY}${url}"
        [ "$item" != 'clash' ] && url="$proxy_url"
        _okcat '⏳' "正在下载：${item}：$url"
        local target="${ZIP_BASE_DIR}/$(basename "$url")"
        curl \
            --progress-bar \
            --show-error \
            --fail \
            --insecure \
            --location \
            --retry 1 \
            --output "$target" \
            "$url"
        target_zip+=("$target")
    done
    _valid_zip "${target_zip[@]}"
    _load_zip >&/dev/null
}
_load_zip() {
    ZIP_CLASH=$(echo "${ZIP_BASE_DIR}"/clash*)
    ZIP_MIHOMO=$(echo "${ZIP_BASE_DIR}"/mihomo*)
    ZIP_YQ=$(echo "${ZIP_BASE_DIR}"/yq*)
    ZIP_SUBCONVERTER=$(echo "${ZIP_BASE_DIR}"/subconverter*)
}

_valid_zip() {
    (($#)) || return 1
    local item fail_zip=()
    for item in "$@"; do
        gzip -t "$item" || fail_zip+=("$item")
    done

    ((${#fail_zip[@]})) && _error_quit "文件验证失败：${fail_zip[*]} 请删除后重试，或自行下载对应版本至 ${ZIP_BASE_DIR} 目录"
}
_set_bin() {
    _valid_zip "$ZIP_KERNEL" "$ZIP_YQ" "$ZIP_SUBCONVERTER"
    /usr/bin/install -D <(gzip -dc "$ZIP_KERNEL") "$BIN_KERNEL"
    tar -xf "$ZIP_YQ" -C "${BIN_BASE_DIR}"
    /bin/mv -f "${BIN_BASE_DIR}"/yq_* "${BIN_BASE_DIR}/yq"
    tar -xf "$ZIP_SUBCONVERTER" -C "$BIN_BASE_DIR"
    /bin/cp "$BIN_SUBCONVERTER_DIR/pref.example.yml" "$BIN_SUBCONVERTER_CONFIG"
    tar -xf "$ZIP_UI" -C "$CLASH_RESOURCES_DIR"
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

_quit() {
    [ -n "$SUDO_USER" ] && _has_root && [ "$SUDO_USER" != 'root' ] && exec su "$SUDO_USER"
    _get_shell
    exec "$EXEC_SHELL" -i
}
