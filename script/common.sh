#!/bin/bash
# shellcheck disable=SC2034
# shellcheck disable=SC2155
GH_PROXY='https://gh-proxy.com/'
URL_YQ="https://github.com/mikefarah/yq/releases/tag/v4.45.1"

TEMP_RESOURCE='./resource'
TEMP_TOOL_DIR="${TEMP_RESOURCE}/tool"
TEMP_CONFIG="${TEMP_RESOURCE}/config.yaml"

ZIP_BASE_DIR="${TEMP_RESOURCE}/zip"
ZIP_CLASH="${ZIP_BASE_DIR}/clash*.gz"
ZIP_YQ="${ZIP_BASE_DIR}/yq*.tar.gz"
ZIP_CONVERT="${ZIP_BASE_DIR}/subconverter*.tar.gz"
ZIP_UI="${ZIP_BASE_DIR}/yacd.tar.xz"

CLASH_BASE_DIR='/opt/clash'
CLASH_CONFIG_URL="${CLASH_BASE_DIR}/url"
CLASH_CONFIG_RAW="${CLASH_BASE_DIR}/config.yaml"
CLASH_CONFIG_RAW_BAK="${CLASH_CONFIG_RAW}.bak"
CLASH_CONFIG_MIXIN="${CLASH_BASE_DIR}/mixin.yaml"
CLASH_CONFIG_RUNTIME="${CLASH_BASE_DIR}/runtime.yaml"
CLASH_UPDATE_LOG="${CLASH_BASE_DIR}/clashupdate.log"

TOOL_BASE_DIR="${CLASH_BASE_DIR}/tool"
TOOL_CLASH="${TOOL_BASE_DIR}/clash"
TOOL_YQ="${TOOL_BASE_DIR}/yq"
TOOL_SUBCONVERTER="${TOOL_BASE_DIR}/subconverter/subconverter"

function _get_os() {
    local os_info=$(cat /etc/os-release)
    echo "$os_info" | grep -iqsE "rhel|centos" && {
        CLASH_CRON_TAB='/var/spool/cron/root'
        BASHRC='/etc/bashrc'
    }
    echo "$os_info" | grep -iqsE "debian|ubuntu" && {
        CLASH_CRON_TAB='/var/spool/cron/crontabs/root'
        BASHRC='/etc/bash.bashrc'
    }

    local cpu_arch=$(uname -m)
    # shellcheck disable=SC2086
    { /bin/ls $ZIP_CLASH | grep clash; } >&/dev/null || _download_clash "$cpu_arch"
}

_get_value() {
    sed -En "s/$1:\s(.*)/\1/p" $CLASH_CONFIG_RUNTIME
}
function _get_port() {
    local ext_ctl=$(_get_value 'external-controller')
    EXT_PORT=${ext_ctl##*:}
    EXT_PORT=${EXT_PORT//\'/}
    MIXED_PORT=$(_get_value 'mixed-port')

    [ -z "$MIXED_PORT" ] && MIXED_PORT=7890
    [ -z "$EXT_PORT" ] && EXT_PORT=9090
}

function _mark_raw() {
    sudo sed -i -e '1i\# raw-config-start' -e '$a\# raw-config-end\n' "${CLASH_CONFIG_RAW}"
}

function _okcat() {
    echo "😼 $1" && return 0
}

function _failcat() {
    echo "😾 $1" >&2 && return 1
}

# bash执行   $0为脚本执行路径
# source执行 $0为bash
function _error_quit() {
    local red='\033[0;31m'
    local nc='\033[0m' # 无色
    echo -e "${red}❌ $1${nc}"
    echo "$0" | grep -qs 'bash' && exec bash || exit 1
}

function _download_clash() {
    local url sha256sum
    case "$1" in
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
        # shellcheck disable=SC2086
        /bin/rm -rf $ZIP_CLASH
        _error_quit "未知的架构版本：$1，请自行下载对应版本至 ${ZIP_BASE_DIR} 目录下：https://downloads.clash.wiki/ClashPremium/"
        ;;
    esac
    _failcat "当前CPU架构为：$1，正在下载对应版本..."
    wget --timeout=30 \
        --tries=1 \
        --no-check-certificate \
        --directory-prefix "$ZIP_BASE_DIR" \
        "$url"
    # shellcheck disable=SC2086
    echo $sha256sum $ZIP_CLASH | sha256sum -c || {
        /bin/rm -rf $ZIP_CLASH
        _error_quit "下载失败：请自行下载对应版本至 ${ZIP_BASE_DIR} 目录下：https://downloads.clash.wiki/ClashPremium/"
    }

}

function _valid_env() {
    [ "$(whoami)" != "root" ] && _error_quit "需要 root 或 sudo 权限执行"
    [ "$(ps -p $$ -o comm=)" != "bash" ] && _error_quit "当前终端不是 bash"
    [ "$(ps -p 1 -o comm=)" != "systemd" ] && _error_quit "系统不具备 systemd"
}

function _valid_config() {
    local bin_path="${TOOL_CLASH}"
    [ ! -e "$bin_path" ] && bin_path="${TEMP_TOOL_DIR}/clash"

    [ -e "$1" ] && [ "$(wc -l <"$1")" -gt 1 ] &&
        "${bin_path}" -d "$(dirname "$1")" -f "$1" -t
}

function _download_config() {
    local url=$1
    local output=$2
    local agent='Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:130.0) Gecko/20100101 Firefox/130.0'
    sudo curl --connect-timeout 4 \
        --retry 1 \
        --user-agent "$agent" \
        -k \
        -o "$output" \
        "$url" ||
        sudo wget --timeout=5 \
            --tries=1 \
            --user-agent="$agent" \
            --no-check-certificate \
            -O "$output" \
            "$url"
}

function _convert_url() {
    local raw_url="$1"
    local base_url="http://127.0.0.1:25500/sub?target=clash&url="

    urlencode() {
        local LANG=C
        local length="${#1}"
        for ((i = 0; i < length; i++)); do
            c="${1:i:1}"
            case "$c" in
            [a-zA-Z0-9.~_-]) printf "%s" "$c" ;;
            *) printf '%%%02X' "'$c" ;;
            esac
        done
        echo
    }

    local encoded_url=$(urlencode "$raw_url")

    echo "${base_url}${encoded_url}"
}

_start_convert() {
    local bin_path="${TOOL_SUBCONVERTER}"
    [ ! -e "$bin_path" ] && bin_path="${TEMP_TOOL_DIR}/subconverter/subconverter"
    # 子shell运行，屏蔽kill时的输出
    (sudo ${bin_path} >&/dev/null &)
    local start=$(date +%s%3N)
    while ! sudo lsof -i :25500 >&/dev/null; do
        sleep 0.05
        local now=$(date +%s%3N)
        [ $(("$now" - "$start")) -gt 500 ] && _error_quit '订阅转换服务未启动，请检查25500端口是否被占用'
    done
}

_stop_convert() {
    pkill -9 -f subconverter >&/dev/null
}

function _convert_config() {
    _start_convert
    _download_config "$(_convert_url "$url")" "$1"
    _stop_convert
}
