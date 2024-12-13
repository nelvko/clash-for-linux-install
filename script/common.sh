#!/bin/bash
# shellcheck disable=SC2034
TEMP_CONFIG_PATH='./resource/config.yaml'
TEMP_CLASH_PATH='./resource/clash-linux-amd64-v3-2023.08.17.gz'
TEMP_UI_PATH='./resource/yacd.tar.xz'

CLASH_BASE_PATH='/opt/clash'
CLASH_CONFIG_PATH="${CLASH_BASE_PATH}/config.yaml"
CLASH_CONFIG_BAK_PATH="${CLASH_CONFIG_PATH}.bak"
CLASH_UPDATE_LOG_PATH="${CLASH_BASE_PATH}/clashupdate.log"

function _get_os() {
    local os_info
    os_info=$(cat /etc/os-release)
    echo "$os_info" | grep -iqs "centos" && {
        CLASH_CRON_PATH='/var/spool/cron/root'
        BASHRC_PATH='/etc/bashrc'
    }
    echo "$os_info" | grep -iqsE "debian|ubuntu" && {
        CLASH_CRON_PATH='/var/spool/cron/crontabs/root'
        BASHRC_PATH='/etc/bash.bashrc'
    }
}
_get_os

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
    "$(dirname "$1")/clash" -d "$(dirname "$1")" -t >&/dev/null
}

function _download_config() {
    local url=$1
    local output=$2
    local agent='Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:130.0) Gecko/20100101 Firefox/130.0'
    wget --timeout=3 \
        --tries=1 \
        --no-check-certificate \
        --user-agent="$agent" \
        -O "$output" \
        "$url" ||
        curl --connect-timeout 3 \
            --retry 1 \
            --user-agent "$agent" \
            -k -o "$output" \
            "$url"
}
