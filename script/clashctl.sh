#!/bin/bash
# clash快捷指令
function clashon() {
    systemctl start clash && echo '😼 已开启代理环境' ||
        echo '😾 启动失败: 执行 "systemctl status clash" 查看日志' || return 1
    PROXY_ADDR=http://127.0.0.1:7890
    export http_proxy=$PROXY_ADDR
    export https_proxy=$PROXY_ADDR
    export HTTP_PROXY=$PROXY_ADDR
    export HTTPS_PROXY=$PROXY_ADDR
}

function clashoff() {
    systemctl stop clash && echo '😼 已关闭代理环境' ||
        echo '😾 关闭失败: 执行 "systemctl status clash" 查看日志' || return 1
    unset http_proxy
    unset https_proxy
    unset HTTP_PROXY
    unset HTTPS_PROXY
}

function clashui() {
    # 查询公网ip
    # ifconfig.me
    # cip.cc
    PUBLIC_IP=$(curl -s --noproxy "*" ifconfig.me)
    PUBLIC_ADDRESS="http://${PUBLIC_IP}:9090/ui"
    # 内网ip
    # ip route get 1.1.1.1 | grep -oP 'src \K\S+'
    LOCAL_IP=$(hostname -I | awk '{print $1}')
    LOCAL_ADDRESS="http://${LOCAL_IP}:9090/ui"
    printf "\n"
    printf "╔═══════════════════════════════════════════════╗\n"
    printf "║                😼 Web 面板地址                ║\n"
    printf "║═══════════════════════════════════════════════║\n"
    printf "║                                               ║\n"
    printf "║      🔓 请注意放行 9090 端口                  ║\n"
    printf "║      🏠 内网：%-30s  ║\n" "$LOCAL_ADDRESS"
    printf "║      🌍 公网：%-30s  ║\n" "$PUBLIC_ADDRESS"
    printf "║      ☁️  公共：https://clash.razord.top        ║\n"
    printf "║                                               ║\n"
    printf "╚═══════════════════════════════════════════════╝\n"
    printf "\n"
}

function clashupdate() {
    IS_AUTO=false
    URL=""
    for ARG in "$@"; do
        [ "$ARG" = "--auto" ] && IS_AUTO=true
        [ "${ARG:0:4}" = 'http' ] && URL=$ARG
    done

    [ "$URL" = "" ] && _error_quit '请正确填写订阅链接'
    [ "$IS_AUTO" = true ] && {
        grep -qs 'clashupdate' "$CLASH_CRONTAB_TARGET_PATH" || xargs -I {} echo '0 0 */2 * * . /etc/bashrc;clashupdate {}' >>"$CLASH_CRONTAB_TARGET_PATH" <<<"$URL"
        echo "😼 定时任务设置成功" && return 0
    }

    cat "$CLASH_CONFIG_PATH" >"$CLASH_CONFIG_BAK_PATH"
    _download_config "$URL" "$CLASH_CONFIG_PATH"
    # shellcheck disable=SC2015
    _valid_config "$CLASH_CONFIG_PATH" && {
        { clashoff && clashon; } >/dev/null 2>&1
        echo '😼 配置更新成功，已重启生效'
    } || {
        cat "$CLASH_CONFIG_BAK_PATH" >"$CLASH_CONFIG_PATH"
        _error_quit '下载失败或配置无效'
    }
}

function clashsecret() {
    [ $# -eq 0 ] &&
        echo "😼 当前密钥：$(sed -nE 's/.*secret\s(.*)/\1/p' /etc/systemd/system/clash.service)"
    [ $# -eq 1 ] && {
        xargs -I {} sed -iE s/'secret\s.*'/'secret {}'/ /etc/systemd/system/clash.service <<<"$1"
        systemctl daemon-reload
        { clashoff && clashon; } >/dev/null 2>&1
        echo "😼 密钥更新成功，已重启生效"
    }
    [ $# -ge 2 ] &&
        echo "😾 密钥不要包含空格或使用引号包围"
}
