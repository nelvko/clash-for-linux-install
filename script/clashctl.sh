#!/bin/bash
# shellcheck disable=SC2155
# clash快捷指令
function clashon() {
    systemctl start clash && _okcat '已开启代理环境' ||
        _failcat '启动失败: 执行 "systemctl status clash" 查看日志' || return 1
    local proxy_addr=http://127.0.0.1:7890
    export http_proxy=$proxy_addr
    export https_proxy=$proxy_addr
    export HTTP_PROXY=$proxy_addr
    export HTTPS_PROXY=$proxy_addr
}

function clashoff() {
    systemctl stop clash && _okcat '已关闭代理环境' ||
        _failcat '关闭失败: 执行 "systemctl status clash" 查看日志' || return 1
    unset http_proxy
    unset https_proxy
    unset HTTP_PROXY
    unset HTTPS_PROXY
}

function clashui() {
    # 防止tun模式强制走代理
    clashoff >&/dev/null
    # 查询公网ip
    # ifconfig.me
    # cip.cc
    local public_ip=$(curl -s --noproxy "*" ifconfig.me)
    local public_address="http://${public_ip}:9090/ui"
    # 内网ip
    # ip route get 1.1.1.1 | grep -oP 'src \K\S+'
    local local_ip=$(hostname -I | awk '{print $1}')
    local local_address="http://${local_ip}:9090/ui"
    printf "\n"
    printf "╔═══════════════════════════════════════════════╗\n"
    printf "║                😼 Web 面板地址                ║\n"
    printf "║═══════════════════════════════════════════════║\n"
    printf "║                                               ║\n"
    printf "║      🔓 请注意放行 9090 端口                  ║\n"
    printf "║      🏠 内网：%-30s  ║\n" "$local_address"
    printf "║      🌍 公网：%-30s  ║\n" "$public_address"
    printf "║      ☁️  公共：https://clash.razord.top        ║\n"
    printf "║                                               ║\n"
    printf "╚═══════════════════════════════════════════════╝\n"
    printf "\n"
    clashon >&/dev/null
}

function clashupdate() {
    local is_auto=false
    local is_log=false
    local url=""
    for arg in "$@"; do
        [ "$arg" = "log" ] && is_log=true
        [ "$arg" = "--auto" ] && is_auto=true
        [ "${arg:0:4}" = 'http' ] && url=$arg
    done

    [ "$is_log" = true ] && {
        tail "${CLASH_UPDATE_LOG_PATH}"
        return $?
    }
    [ "$url" = "" ] && _error_quit '请正确填写订阅链接'
    [ "$is_auto" = true ] && {
        grep -qs 'clashupdate' "$CLASH_CRON_PATH" || xargs -I {} echo "0 0 */2 * * . $BASHRC_PATH;clashupdate {}" >>"$CLASH_CRON_PATH" <<<"$url"
        _okcat "定时任务设置成功" && return 0
    }

    cat "$CLASH_CONFIG_RAW_PATH" >"$CLASH_CONFIG_BAK_PATH"
    _download_config "$url" "$CLASH_CONFIG_RAW_PATH"
    # shellcheck disable=SC2015
    _valid_config "$CLASH_CONFIG_RAW_PATH" && {
        { clashoff && clashon; } >/dev/null 2>&1
        _okcat '配置更新成功，已重启生效'
        echo "$(date +"%Y-%m-%d %H:%M:%S") 配置更新成功✅" >>"${CLASH_UPDATE_LOG_PATH}"
    } || {
        cat "$CLASH_CONFIG_BAK_PATH" >"$CLASH_CONFIG_RAW_PATH"
        echo "$(date +"%Y-%m-%d %H:%M:%S") 配置更新失败❌" >>"${CLASH_UPDATE_LOG_PATH}"
        _error_quit '配置无效：请检查配置内容'
    }
}

function clashsecret() {
    [ $# -eq 0 ] &&
        _okcat "当前密钥：$(sed -nE 's/.*secret\s(.*)/\1/p' /etc/systemd/system/clash.service)"
    [ $# -eq 1 ] && {
        xargs -I {} sed -iE s/'secret\s.*'/'secret {}'/ /etc/systemd/system/clash.service <<<"$1"
        systemctl daemon-reload
        { clashoff && clashon; } >/dev/null 2>&1
        _okcat "密钥更新成功，已重启生效"
    }
    [ $# -ge 2 ] &&
        _failcat "密钥不要包含空格或使用引号包围"
}

_tunoff() {
    cat "$CLASH_CONFIG_RAW_PATH" >"${CLASH_CONFIG_MIXIN_PATH}"
    { clashoff && clashon; } >&/dev/null
    _okcat "tun 模式已关闭"
}

_tunon() {
    grep 'tun:' "${CLASH_CONFIG_MIXIN_PATH}" && {
        echo 已有
        return
    }
    sed -i '$a\# tun-config-start' "${CLASH_CONFIG_MIXIN_PATH}"
    cat "${CLASH_MIXIN_TUN_PATH}" >>"${CLASH_CONFIG_MIXIN_PATH}"
    sed -i '$a\# tun-config-end\n' "${CLASH_CONFIG_MIXIN_PATH}"
    { clashoff && clashon; } >&/dev/null

    journalctl -u clash | grep -qs 'unsupported kernel version' && {
        _tunoff >&/dev/null
        _error_quit '当前系统内核版本不支持'
    }
    _okcat "tun 模式已开启"
}

function clashtun() {
    case "$1" in
    on)
        _tunon
        ;;
    off)
        _tunoff
        ;;
    *)
        _okcat "usage: clashtun on|off"
        ;;
    esac

}

function clash() {
    [ $# -eq 0 ] && cat <<EOF
Usage:
    开启代理: clashon
    关闭代理: clashoff
    Web UI:  clashui
    更新配置文件: clashupdate [--auto]
    查看设置密钥:  clashsecret
    设置 Tun 模式:  clashtun on|off
EOF
}
