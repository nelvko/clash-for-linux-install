#!/usr/bin/env bash

RESOURCES_BASE_DIR=".${CLASH_RESOURCES_DIR#"$CLASH_BASE_DIR"}"
RESOURCES_CONFIG_BASE=".${CLASH_CONFIG_BASE#"$CLASH_BASE_DIR"}"
RESOURCES_CONFIG_MIXIN=".${CLASH_CONFIG_MIXIN#"$CLASH_BASE_DIR"}"

ZIP_BASE_DIR=".${CLASH_RESOURCES_DIR#"$CLASH_BASE_DIR"}/zip"

SCRIPT_BASE_DIR='scripts'
SCRIPT_INIT_DIR="${SCRIPT_BASE_DIR}/init"
SCRIPT_CMD_DIR="${SCRIPT_BASE_DIR}/cmd"
SCRIPT_CMD_FISH="${SCRIPT_CMD_DIR}/clashctl.fish"

CLASH_CMD_DIR="${CLASH_BASE_DIR}/$SCRIPT_CMD_DIR"

FILE_LOG="/var/log/${KERNEL_NAME}.log"
FILE_PID="/run/${KERNEL_NAME}.pid"

_valid_required() {
    local required_cmds=("xz" "pgrep" "curl" "tar" 'unzip')
    local missing=()
    for cmd in "${required_cmds[@]}"; do
        command -v "$cmd" >&/dev/null || missing+=("$cmd")
    done
    [ "${#missing[@]}" -gt 0 ] && _error_quit "请先安装以下命令：${missing[*]}"
}

_valid() {
    _valid_required

    [ -d "$CLASH_BASE_DIR" ] && _error_quit "请先执行卸载脚本,以清除安装路径：$CLASH_BASE_DIR"

    local msg="${CLASH_BASE_DIR}：当前路径不可用，请在 .env 中更换安装路径。"
    mkdir -p "$CLASH_BASE_DIR" || _error_quit "$msg"
    _is_regular_sudo && [[ $CLASH_BASE_DIR == /root* ]] && _error_quit "$msg"

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
        http*)
            CLASH_CONFIG_URL=$arg
            ;;
        esac
    done
}

_prepare_zip() {
    _load_zip >&/dev/null
    local required_zips=()
    case "${KERNEL_NAME}" in
    clash)
        [ ! -f "$ZIP_CLASH" ] && required_zips+=("clash")
        ;;
    mihomo | *)
        [ ! -f "$ZIP_MIHOMO" ] && required_zips+=("mihomo")
        ;;
    esac
    [ ! -f "$ZIP_YQ" ] && required_zips+=("yq")
    [ ! -f "$ZIP_SUBCONVERTER" ] && required_zips+=("subconverter")

    _download_zip "${required_zips[@]}"

    case "${KERNEL_NAME}" in
    clash)
        ZIP_KERNEL="$ZIP_CLASH"
        ;;
    mihomo | *)
        ZIP_KERNEL="$ZIP_MIHOMO"
        ;;
    esac
    BIN_KERNEL="${BIN_BASE_DIR}/$KERNEL_NAME"
    _unzip_zip
}
_load_zip() {
    ZIP_CLASH=$(echo "${ZIP_BASE_DIR}"/clash*)
    ZIP_MIHOMO=$(echo "${ZIP_BASE_DIR}"/mihomo*)
    ZIP_YQ=$(echo "${ZIP_BASE_DIR}"/yq*)
    ZIP_SUBCONVERTER=$(echo "${ZIP_BASE_DIR}"/subconverter*)
}
_download_zip() {
    (($#)) || return 0
    local url_clash url_mihomo url_yq url_subconverter
    local arch=$(uname -m)
    case "$arch" in
    x86_64)
        local flags=$(grep -m1 '^flags' /proc/cpuinfo)
        local level=v1
        grep -qw sse4_2 <<<"$flags" && grep -qw popcnt <<<"$flags" && level=v2
        grep -qw avx2 <<<"$flags" && grep -qw fma <<<"$flags" && level=v3
        VERSION_MIHOMO=${level}-$VERSION_MIHOMO

        url_clash=https://downloads.clash.wiki/ClashPremium/clash-linux-amd64-2023.08.17.gz
        url_mihomo=https://github.com/MetaCubeX/mihomo/releases/download/${VERSION_MIHOMO##*-}/mihomo-linux-amd64-${VERSION_MIHOMO}.gz
        url_yq=https://github.com/mikefarah/yq/releases/download/${VERSION_YQ}/yq_linux_amd64.tar.gz
        url_subconverter=https://github.com/tindy2013/subconverter/releases/download/${VERSION_SUBCONVERTER}/subconverter_linux64.tar.gz
        ;;
    *86*)
        url_clash=https://downloads.clash.wiki/ClashPremium/clash-linux-386-2023.08.17.gz
        url_mihomo=https://github.com/MetaCubeX/mihomo/releases/download/${VERSION_MIHOMO##*-}/mihomo-linux-386-${VERSION_MIHOMO}.gz
        url_yq=https://github.com/mikefarah/yq/releases/download/${VERSION_YQ}/yq_linux_386.tar.gz
        url_subconverter=https://github.com/tindy2013/subconverter/releases/download/${VERSION_SUBCONVERTER}/subconverter_linux32.tar.gz
        ;;
    armv*)
        url_clash=https://downloads.clash.wiki/ClashPremium/clash-linux-armv5-2023.08.17.gz
        url_mihomo=https://github.com/MetaCubeX/mihomo/releases/download/${VERSION_MIHOMO##*-}/mihomo-linux-armv7-${VERSION_MIHOMO}.gz
        url_yq=https://github.com/mikefarah/yq/releases/download/${VERSION_YQ}/yq_linux_arm.tar.gz
        url_subconverter=https://github.com/tindy2013/subconverter/releases/download/${VERSION_SUBCONVERTER}/subconverter_armv7.tar.gz
        ;;
    aarch64)
        url_clash=https://downloads.clash.wiki/ClashPremium/clash-linux-arm64-2023.08.17.gz
        url_mihomo=https://github.com/MetaCubeX/mihomo/releases/download/${VERSION_MIHOMO##*-}/mihomo-linux-arm64-${VERSION_MIHOMO}.gz
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

    local item target_zips=()
    _okcat '🖥️ ' "系统架构：$arch $level"
    for item in "$@"; do
        local url="${urls[$item]}"
        local proxy_url="${URL_GH_PROXY:+${URL_GH_PROXY%/}/}${url}"
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
        target_zips+=("$target")
    done
    _valid_zip "${target_zips[@]}"
    _load_zip >&/dev/null
}
_valid_zip() {
    (($#)) || return 1
    local zip fail_zips=()
    for zip in "$@"; do
        gzip -tq "$zip" || unzip -tqq "$zip" || fail_zips+=("$zip")
    done

    ((${#fail_zips[@]})) && _error_quit "文件验证失败：${fail_zips[*]} 请删除后重试，或自行下载对应版本至 ${ZIP_BASE_DIR} 目录"
}
_unzip_zip() {
    _valid_zip "$ZIP_KERNEL" "$ZIP_YQ" "$ZIP_SUBCONVERTER" "$ZIP_UI"
    /usr/bin/install -D <(gzip -dc "$ZIP_KERNEL") "$BIN_KERNEL"
    tar -xf "$ZIP_YQ" -C "${BIN_BASE_DIR}"
    /bin/mv -f "${BIN_BASE_DIR}"/yq_* "${BIN_BASE_DIR}/yq"
    tar -xf "$ZIP_SUBCONVERTER" -C "$BIN_BASE_DIR"
    /bin/cp "$BIN_SUBCONVERTER_DIR/pref.example.yml" "$BIN_SUBCONVERTER_CONFIG"
    unzip -oqq "$ZIP_UI" -d "$RESOURCES_BASE_DIR" 2>/dev/null || tar -xf "$ZIP_UI" -C "$RESOURCES_BASE_DIR"
}

# shellcheck disable=SC2206
_detect_init() {
    [ -z "$INIT_TYPE" ] && INIT_TYPE=$(readlink /proc/1/exe)
    grep -qsE "docker|kubepods|containerd|podman|lxc" /proc/1/cgroup && INIT_TYPE='nohup'
    _is_root || {
        INIT_TYPE='nohup'
        FILE_LOG="${CLASH_RESOURCES_DIR}/${KERNEL_NAME}.log"
        FILE_PID="${CLASH_RESOURCES_DIR}/${KERNEL_NAME}.pid"
    }

    service_log=(less '<' $FILE_LOG)
    service_follow_log=(tail -f -n 0 $FILE_LOG)
    service_watch_proxy=(clashon)
    _is_regular_sudo && {
        service_watch_proxy=(_failcat "'未检测到代理变量，可执行 clashon 开启代理环境'")
        _SUDO=sudo
    }

    case "${INIT_TYPE}" in
    *systemd)
        service_log=($_SUDO journalctl -u "$KERNEL_NAME")
        service_follow_log=("${service_log[@]}" -q -f -n 0)
        _systemd
        ;;
    *init)
        _sysvinit
        ;;
    *busybox)
        command -v openrc-init >&/dev/null && _openrc
        ;;
    *openrc*)
        _openrc
        ;;
    *runit)
        _runit
        ;;
    nohup | *)
        INIT_TYPE='nohup'
        _nohup
        ;;
    esac
    INIT_TYPE=$(basename "$INIT_TYPE")
}
_openrc() {
    service_src="${SCRIPT_INIT_DIR}/OpenRC.sh"
    service_target="/etc/init.d/$KERNEL_NAME"

    service_enable=(rc-update add "$KERNEL_NAME" default)
    service_disable=(rc-update del "$KERNEL_NAME" default)

    service_start=(rc-service "$KERNEL_NAME" start)
    service_stop=(rc-service "$KERNEL_NAME" stop)
    service_restart=(rc-service "$KERNEL_NAME" restart)
    service_status=(rc-service "$KERNEL_NAME" status)
}
_runit() {
    service_src="${SCRIPT_INIT_DIR}/runit.sh"
    service_target="/etc/sv/${KERNEL_NAME}/run"
    service_del=(rm -rf "/etc/sv/${KERNEL_NAME:-mihomo}")

    service_reload=(sleep 2)
    service_enable=(ln -s "$(dirname "$service_target")" "/etc/runit/runsvdir/default/${KERNEL_NAME}")
    service_disable=(rm -f "/etc/runit/runsvdir/current/${KERNEL_NAME}")

    service_start=(sv up "$KERNEL_NAME")
    service_stop=(sv down "$KERNEL_NAME")
    service_restart=(sv restart "$KERNEL_NAME")
    service_status=(sv status "$KERNEL_NAME")
    service_is_active=(sv status "$KERNEL_NAME" \| grep -qs '^run')
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
    service_stop=(service "$KERNEL_NAME" stop)
    service_restart=(service "$KERNEL_NAME" restart)
    service_status=(service "$KERNEL_NAME" status)
}
# shellcheck disable=SC2206
_systemd() {
    service_src="${SCRIPT_INIT_DIR}/systemd.sh"
    service_target="/etc/systemd/system/${KERNEL_NAME}.service"

    service_reload=($_SUDO systemctl daemon-reload)

    service_enable=($_SUDO systemctl enable "$KERNEL_NAME")
    service_disable=($_SUDO systemctl disable "$KERNEL_NAME")

    service_start=($_SUDO systemctl start "$KERNEL_NAME")
    service_stop=($_SUDO systemctl stop "$KERNEL_NAME")
    service_restart=($_SUDO systemctl restart "$KERNEL_NAME")
    service_status=($_SUDO systemctl status "$KERNEL_NAME")
}
_nohup() {
    service_enable=(false)
    service_disable=(false)

    service_start=('(' nohup "$BIN_KERNEL" -d "$CLASH_RESOURCES_DIR" -f "$CLASH_CONFIG_RUNTIME" '>\&' "$FILE_LOG" '\&' ')')
    service_status=(pgrep -fa "$BIN_KERNEL")
    service_stop=(pkill -9 -f "$BIN_KERNEL")
}

_install_service() {
    local kernel_desc="$KERNEL_NAME Daemon, A[nother] Clash Kernel."

    local cmd_path="${BIN_KERNEL}"
    local cmd_arg="-d ${CLASH_RESOURCES_DIR} -f ${CLASH_CONFIG_RUNTIME}"
    local cmd_full="${BIN_KERNEL} -d ${CLASH_RESOURCES_DIR} -f ${CLASH_CONFIG_RUNTIME}"

    [ -n "$service_src" ] && {
        /usr/bin/install -D -m +x "$service_src" "$service_target"
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
        -e "s#placeholder_is_active#${service_is_active[*]}#g" \
        -e "s#placeholder_stop#${service_stop[*]}#g" \
        -e "s#placeholder_log#${service_log[*]}#g" \
        -e "s#placeholder_follow_log#${service_follow_log[*]}#g" \
        -e "s#placeholder_watch_proxy#${service_watch_proxy[*]}#g" \
        "$CLASH_CMD_DIR/clashctl.sh" "$CLASH_CMD_DIR/common.sh"

    "${service_enable[@]}" >&/dev/null && _okcat '🚀' '已设置开机自启'
    ((${#service_reload[@]})) && "${service_reload[@]}"
}
_uninstall_service() {
    _detect_init
    "${service_disable[@]}" >&/dev/null
    ((${#service_del[@]})) && "${service_del[@]}"
    rm -f "$service_target"
    ((${#service_reload[@]})) && "${service_reload[@]}"
}

_detect_rc() {
    local home=$HOME
    _is_regular_sudo && home=$(awk -F: -v user="$SUDO_USER" '$1==user{print $6}' /etc/passwd)

    command -v bash >&/dev/null && {
        SHELL_RC_BASH="${home}/.bashrc"
    }
    command -v zsh >&/dev/null && {
        SHELL_RC_ZSH="${home}/.zshrc"
    }
    command -v fish >&/dev/null && {
        SHELL_RC_FISH="${home}/.config/fish/conf.d/clashctl.fish"
    }
    start_flag="# clashctl START"
    end_flag="# clashctl END"
}
_apply_rc() {
    _detect_rc
    local source_clashctl=". $CLASH_CMD_DIR/clashctl.sh"
    # shellcheck disable=SC2086
    tee -a "$SHELL_RC_BASH" $SHELL_RC_ZSH >/dev/null <<EOF
$start_flag
# 加载 clashctl 命令
$source_clashctl
# 自动开启代理环境
watch_proxy
$end_flag
EOF
    [ -n "$SHELL_RC_FISH" ] && /usr/bin/install "$SCRIPT_CMD_FISH" "$SHELL_RC_FISH"
    $source_clashctl
}
_revoke_rc() {
    _detect_rc
    sed -i.bak "/$start_flag/,/$end_flag/d" "$SHELL_RC_BASH" "$SHELL_RC_ZSH" 2>/dev/null
    [ -n "$SHELL_RC_FISH" ] && rm -f "$SHELL_RC_FISH" 2>/dev/null
}

_set_envs() {
    _set_env CLASH_CONFIG_URL "$CLASH_CONFIG_URL"
    _set_env INIT_TYPE "$INIT_TYPE"
    _set_env KERNEL_NAME "$KERNEL_NAME"
    _set_env CLASH_BASE_DIR "$CLASH_BASE_DIR"
    _set_env VERSION_MIHOMO "$VERSION_MIHOMO"
}

_get_random_val() {
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 6
}

_is_regular_sudo() {
    _is_root && [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != 'root' ]
}
_is_root() {
    [ "$(id -u)" -eq 0 ]
}

_quit() {
    _is_regular_sudo && exec su "$SUDO_USER"
    exec "$SHELL" -i
}
