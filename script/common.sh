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
function _quit() {
    echo "$0" | grep -qs 'bash' && exec bash || exit 1
}

function _valid_root() {
    [ "$(whoami)" != "root" ] && {
        echo "❌ 需要 root 或 sudo 权限执行!" && _quit
    }
    [ "$(ps -p $$ -o comm=)" != "bash" ] && {
        echo "❌ 当前终端不是 bash" && _quit
    }
    [ "$(ps -p 1 -o comm=)" != "systemd" ] && {
        echo "❌ 系统不具备 systemd" && _quit
    }
}

function _valid_config() {
    grep -qs 'port' "$1"
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
    _valid_config "$2" || \
    curl --connect-timeout 3 \
         --retry 1 \
         --user-agent "$AGENT" \
         -k -o "$2" \
         "$1"
}
