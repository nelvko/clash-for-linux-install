#!/bin/bash
# shellcheck disable=SC2155
# clash快捷指令
function clashon() {
    sudo systemctl start clash && echo '😼 已开启代理环境' ||
        echo '😾 启动失败: 执行 "systemctl status clash" 查看日志' || return 1
    local proxy_addr=http://127.0.0.1:7890
    export http_proxy=$proxy_addr
    export https_proxy=$proxy_addr
    export HTTP_PROXY=$proxy_addr
    export HTTPS_PROXY=$proxy_addr
}

function clashoff() {
    sudo systemctl stop clash && echo '😼 已关闭代理环境' ||
        echo '😾 关闭失败: 执行 "systemctl status clash" 查看日志' || return 1
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

function clashsecret() {
    case "$#" in
    0)
        _okcat "当前密钥：$(sed -nE 's/.*secret\s(.*)/\1/p' /etc/systemd/system/clash.service)"
        ;;
    1)
        local secret=$1
        [ -z "$secret" ] && secret=\'\'
        sudo sed -iE s/"secret\s.*"/"secret $secret"/ /etc/systemd/system/clash.service
        sudo systemctl daemon-reload
        { clashoff && clashon; } >/dev/null 2>&1
        _okcat "密钥更新成功，已重启生效"
        ;;
    *)
        _failcat "密钥不要包含空格或使用引号包围"
        ;;
    esac
}

_valid_yq() {
    yq -V >&/dev/null && return 0
    read -r -p '依赖 yq 命令，是否安装？[y/N]: ' flag
    [ "$flag" = "y" ] && {
        sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq &&
            sudo chmod +x /usr/bin/yq
        _okcat 'yq 安装成功'
    } || _failcat '取消安装'

}

_concat_config() {
    _valid_yq
    yq -n "load(\"$CLASH_CONFIG_MIXIN\") * load(\"$CLASH_CONFIG_RAW\")" >"$CLASH_CONFIG_RUNTIME"
}

_tunstatus() {
    local status=$(yq '.tun.enable' "${CLASH_CONFIG_RUNTIME}")
    [ "$status" = 'true' ] && _okcat 'Tun 状态：启用' || _failcat 'Tun 状态：关闭'
}

_tunoff() {
    _tunstatus >/dev/null || return 0
    yq -i '.tun.enable = false' "$CLASH_CONFIG_MIXIN"
    _concat_config
    { clashoff && clashon; } >&/dev/null
    _okcat "Tun 模式已关闭"
}

_tunon() {
    _tunstatus 2>/dev/null && return 0
    yq -i '.tun.enable = true' "$CLASH_CONFIG_MIXIN"
    _concat_config
    { clashoff && clashon; } >&/dev/null
    systemctl status clash | grep -qs 'unsupported kernel version' && {
        _tunoff >&/dev/null
        _error_quit '当前系统内核版本不支持'
    }
    _okcat "Tun 模式已开启"
}

function clashtun() {
    _valid_yq
    case "$1" in
    on)
        _tunon
        ;;
    off)
        _tunoff
        ;;
    *)
        _tunstatus
        ;;
    esac
}

function clashupdate() {
    local url=$(cat "$CLASH_CONFIG_URL")
    local is_auto=false
    case "$1" in
    --auto)
        is_auto=true
        ;;
    log)
        tail "${CLASH_UPDATE_LOG}"
        return $?
        ;;
    *)
        url=$2
        ;;
    esac
    [ "${url:0:4}" != 'http' ] && _error_quit '请正确填写订阅链接'
    [ "$is_auto" = true ] && {
        grep -qs 'clashupdate' "$CLASH_CRON_TAB" ||
            echo "0 0 */2 * * . $BASHRC;clashupdate $url" >>"$CLASH_CRON_TAB" &&
            echo 666
        _okcat "定时任务设置成功" && return 0
    }

    _download_config "$url" "$CLASH_CONFIG_RAW"
    # shellcheck disable=SC2015
    _valid_config "$CLASH_CONFIG_RAW" && {
        _concat_config
        { clashoff && clashon; } >/dev/null 2>&1
        _okcat '配置更新成功，已重启生效'
        echo "$url" >"$CLASH_CONFIG_URL"
        echo "$(date +"%Y-%m-%d %H:%M:%S") 配置更新成功 ✅ $url" >>"${CLASH_UPDATE_LOG}"
    } || {
        echo "$(date +"%Y-%m-%d %H:%M:%S") 配置更新失败 ❌ $url" >>"${CLASH_UPDATE_LOG}"
        _error_quit '配置无效：请检查配置内容'
    }
}

function clashmixin() {
    case "$1" in
    -e)
        sudo vi "$CLASH_CONFIG_MIXIN"
        ;;
    *)
        less "$CLASH_CONFIG_MIXIN"
        _valid_config
        clashon clashoff
        ;;
    esac
}

function clash() {
    cat << EOF | column -t -s '：'
Usage:
    clashon                开启代理：
    clashoff               关闭代理：
    clashui                面板地址：
    clashtun [on|off]      Tun模式：
    clashupdate [auto|log] 更新订阅：
    clashsecret [secret]   查看/设置密钥：
EOF
}
