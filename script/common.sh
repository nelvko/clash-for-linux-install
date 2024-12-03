#!/bin/bash
# shellcheck disable=SC2034
CLASH_BASE_PATH='/etc/clash'
CLASH_CONFIG_PATH="${CLASH_BASE_PATH}/config.yaml"
CLASH_CONFIG_BAK_PATH="${CLASH_CONFIG_PATH}.bak"
CLASH_CRONTAB_CENTOS_PATH='/var/spool/cron/root'
CLASH_CRONTAB_UBUNTU_PATH='/var/spool/cron/crontabs/root'
[ -e $CLASH_CRONTAB_CENTOS_PATH ] && CLASH_CRONTAB_TARGET_PATH=$CLASH_CRONTAB_CENTOS_PATH
[ -e $CLASH_CRONTAB_UBUNTU_PATH ] && CLASH_CRONTAB_TARGET_PATH=$CLASH_CRONTAB_UBUNTU_PATH

# bash执行   $0为脚本执行路径
# source执行 $0为bash
function _error_quit() {
    RED='\033[0;31m'
    NC='\033[0m' # 无色
    echo -e "${RED}❌ $1${NC}"
    echo "$0" | grep -qs 'bash' && exec bash || exit 1
}

function _valid_env() {
    [ "$(whoami)" != "root" ] && _error_quit "需要 root 或 sudo 权限执行"
    [ "$(ps -p $$ -o comm=)" != "bash" ] && _error_quit "当前终端不是 bash"
    [ "$(ps -p 1 -o comm=)" != "systemd" ] && _error_quit "系统不具备 systemd"
}

function _valid_config() {
    [ -e "$1" ] &&
        clash -d "$(dirname "$1")" -t >&/dev/null
}

# 1url 2output
function _download_config() {
    AGENT='Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:130.0) Gecko/20100101 Firefox/130.0'
    wget --timeout=3 \
        --tries=1 \
        --no-check-certificate \
        --user-agent="$AGENT" \
        -O "$2" \
        "$1"
    _valid_config "$2" ||
        curl --connect-timeout 3 \
            --retry 1 \
            --user-agent "$AGENT" \
            -k -o "$2" \
            "$1"
}
