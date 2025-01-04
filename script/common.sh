#!/bin/bash
# shellcheck disable=SC2034
# shellcheck disable=SC2155
GH_PROXY='https://ghgo.xyz/'

TEMP_CONFIG='./resource/config.yaml'
TEMP_CLASH_RAR='./resource/clash-linux-*.gz'
TEMP_UI_RAR='./resource/yacd.tar.xz'

CLASH_BASE_DIR='/opt/clash'
CLASH_CONFIG_URL="${CLASH_BASE_DIR}/url"
CLASH_CONFIG_RAW="${CLASH_BASE_DIR}/config.yaml"
CLASH_CONFIG_RAW_BAK="${CLASH_CONFIG_RAW}.bak"
CLASH_CONFIG_MIXIN="${CLASH_BASE_DIR}/config-mixin.yaml"
CLASH_CONFIG_RUNTIME="${CLASH_BASE_DIR}/config-runtime.yaml"
CLASH_UPDATE_LOG="${CLASH_BASE_DIR}/clashupdate.log"

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
}
_get_os

function _get_value() {
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
        *86*)
            url=https://downloads.clash.wiki/ClashPremium/clash-linux-386-2023.08.17.gz
            sha256sum='254125efa731ade3c1bf7cfd83ae09a824e1361592ccd7c0cccd2a266dcb92b5'
        ;;
        armv*)
            url='https://downloads.clash.wiki/ClashPremium/clash-linux-armv5-2023.08.17.gz'
            sha256sum='622f5e774847782b6d54066f0716114a088f143f9bdd37edf3394ae8253062e8'

        ;;
        aarch64)
            url='https://downloads.clash.wiki/ClashPremium/clash-linux-arm64-2023.08.17.gz'
            sha256sum='c45b39bb241e270ae5f4498e2af75cecc0f03c9db3c0db5e55c8c4919f01afdd'

        ;;
        *)
            _error_quit "未知的架构版本：$1，请自行下载并替换对应版本"
            ;;
    esac
    /bin/rm -rf "$TEMP_CLASH_RAR"
    _failcat "当前CPU架构为：$1，正在下载对应版本"
    wget --timeout=30 \
            --tries=1 \
            --no-check-certificate \
            -O "$TEMP_CLASH_RAR" \
            "$url"
    echo "$sha256sum $TEMP_CLASH_RAR" | sha256sum -c || _error_quit '下载失败，请自行下载并替换对应版本'

}

function _valid_env() {
    [ "$(whoami)" != "root" ] && _error_quit "需要 root 或 sudo 权限执行"
    [ "$(ps -p $$ -o comm=)" != "bash" ] && _error_quit "当前终端不是 bash"
    [ "$(ps -p 1 -o comm=)" != "systemd" ] && _error_quit "系统不具备 systemd"

    local cpu_arch=$(uname -m)
    [ "$cpu_arch" = 'x86_64' ] || _download_clash "$cpu_arch"

}

# 配置文件和clash在同一目录
function _valid_config() {
    [ -e "$1" ] && [ "$(wc -l < "$1")" -gt 1 ] \
        && "$(dirname "$1")/clash" -d "$(dirname "$1")" -f "$1" -t
}

function _download_config() {
    local url=$1
    local output=$2
    local agent='Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:130.0) Gecko/20100101 Firefox/130.0'
    sudo curl --connect-timeout 3 \
        --retry 2 \
        --user-agent "$agent" \
        -k \
        -o "$output" \
        "$url" \
        || sudo wget --timeout=5 \
            --tries=1 \
            --user-agent="$agent" \
            --no-check-certificate \
            -O "$output" \
            "$url"
}
