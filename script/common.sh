#!/bin/bash
# shellcheck disable=SC2034
# shellcheck disable=SC2155
GH_PROXY='https://ghgo.xyz'

TEMP_CONFIG='./resource/config.yaml'
TEMP_CLASH_RAR='./resource/clash-linux-amd64-v3-2023.08.17.gz'
TEMP_UI_RAR='./resource/yacd.tar.xz'

CLASH_BASE_DIR='/opt/clash'
CLASH_CONFIG_URL="${CLASH_BASE_DIR}/url"
CLASH_CONFIG_RAW="${CLASH_BASE_DIR}/config.yaml"
CLASH_CONFIG_MIXIN="${CLASH_BASE_DIR}/config-mixin.yaml"
CLASH_CONFIG_RUNTIME="${CLASH_BASE_DIR}/config-runtime.yaml"
CLASH_UPDATE_LOG="${CLASH_BASE_DIR}/clashupdate.log"

function _get_value() {
     sed -En "s/$1:\s(.*)/\1/p" $CLASH_CONFIG_RUNTIME
}
function _get_port() {
    local ext_ctl=$(_get_value 'external-controller')
    EXT_PORT=${ext_ctl##*:}
    EXT_PORT=${EXT_PORT//\'/}
    MIXED_PORT=$(_get_value 'mixed-port')
}

function _get_os() {
    local os_info
    os_info=$(cat /etc/os-release)
    echo "$os_info" | grep -iqs "centos" && {
        CLASH_CRON_TAB='/var/spool/cron/root'
        BASHRC='/etc/bashrc'
    }
    echo "$os_info" | grep -iqsE "debian|ubuntu" && {
        CLASH_CRON_TAB='/var/spool/cron/crontabs/root'
        BASHRC='/etc/bash.bashrc'
    }
}
_get_os

function _mark_raw() {
    sed -i -e '1i\# raw-config-start' -e '$a\# raw-config-end\n' "${CLASH_CONFIG_RAW}"
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

function _valid_env() {
    [ "$(whoami)" != "root" ] && _error_quit "需要 root 或 sudo 权限执行"
    [ "$(ps -p $$ -o comm=)" != "bash" ] && _error_quit "当前终端不是 bash"
    [ "$(ps -p 1 -o comm=)" != "systemd" ] && _error_quit "系统不具备 systemd"
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
    wget --timeout=5 \
        --tries=1 \
        --no-check-certificate \
        --user-agent="$agent" \
        -O "$output" \
        "$url" \
        || curl --connect-timeout 5 \
            --retry 2 \
            --user-agent "$agent" \
            -k -o "$output" \
            "$url"
}
