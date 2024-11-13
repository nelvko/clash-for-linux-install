#!/bin/bash
CONFIG_PATH='/etc/clash/config.yaml'
CONFIG_PATH_BAK="${CONFIG_PATH}.bak"
CRONTAB_PATH_1='/var/spool/cron/root'
CRONTAB_PATH_2='/var/spool/cron/crontabs/root'
[ -e $CRONTAB_PATH_1 ] && TARGET_PATH=$CRONTAB_PATH_1
[ -e $CRONTAB_PATH_2 ] && TARGET_PATH=$CRONTAB_PATH_2

function is_valid() {
    grep -qs 'port' "$1"
}
# 1url 2output
function download_config() {
    agent='Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:130.0) Gecko/20100101 Firefox/130.0'
    wget --timeout=3 --tries=1 --no-check-certificate --user-agent="$agent" -O "$2" "$1"
    is_valid ||
        curl --connect-timeout 3 \
            --retry 1 \
            --user-agent "$agent" \
            -k -o "$CONFIG_PATH" "$1"
}

function quit() {
    echo "$0" | grep -qs install.sh && exit 1
}
# clash快捷指令
function clashon() {
    addr=http://127.0.0.1:7890
    export http_proxy=$addr
    export https_proxy=$addr
    export HTTP_PROXY=$addr
    export HTTPS_PROXY=$addr
    systemctl start clash && echo 'clash: 已开启代理环境！' || echo 'clash: 启动失败: 执行 "systemctl status clash" 查看日志'
}

function clashoff() {
    unset http_proxy
    unset https_proxy
    unset HTTP_PROXY
    unset HTTPS_PROXY
    systemctl stop clash && echo 'clash: 已关闭代理环境!' || echo 'clash: 关闭失败: 执行 "systemctl status clash" 查看日志'
}

function clashui() {
    # 查询公网ip
    # ifconfig.me
    # cip.cc
    ip=$(curl -s --noproxy "*" ifconfig.me)
    cat <<EOF
clash: Web面板:
    ● 请注意放行 9090 端口
    ● 地址1：http://$ip:9090/ui
    ● 地址2：https://clash.razord.top
EOF
}

function clashupdate() {
    IS_AUTO=false
    URL=""
    for arg in "$@"; do
        [ "$arg" = "--auto" ] && IS_AUTO=true
        [ "${arg:0:4}" = 'http' ] && URL=$arg
    done

    [ "$URL" = "" ] && echo '错误：请正确填写订阅链接！' && return 1
    [ "$IS_AUTO" = true ] && {
        grep -qs clashupdate "$TARGET_PATH" || xargs -I {} echo '0 0 */2 * * . /etc/bashrc;clashupdate {}' >>"$TARGET_PATH" <<<"$URL"
        echo "clash: 定时任务设置成功!" && return 0
    }

    cat "$CONFIG_PATH" >"$CONFIG_PATH_BAK"
    download_config "$URL" "$CONFIG_PATH"
    # shellcheck disable=SC2015
    is_valid "$CONFIG_PATH" && {
        systemctl restart clash
        echo 'clash: 配置更新成功，已重启生效'
    } || {
        cat "$CONFIG_PATH_BAK" >"$CONFIG_PATH"
        echo '错误：下载失败或配置无效！'
    }
}
