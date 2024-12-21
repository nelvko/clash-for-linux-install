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

_tunstatus() {
    local status=$(grep -A 1 "^tun:" "${CLASH_CONFIG_MIXIN}" | grep -oP '(?<=enable: ).*')
    [ "$status" = 'true' ] && _okcat 'Tun 状态：启用' || _failcat 'Tun 状态：关闭'
}

_tunoff() {
    _tunstatus >/dev/null || return 0
    cat "$CLASH_CONFIG_RAW" >"${CLASH_CONFIG_MIXIN}"
    { clashoff && clashon; } >&/dev/null
    _okcat "Tun 模式已关闭"
}

_tunon() {
    _tunstatus 2>/dev/null && return 0
    sed -i '$a\\n# tun-config-start' "${CLASH_CONFIG_MIXIN}"
    cat "${CLASH_MIXIN_TUN}" >>"${CLASH_CONFIG_MIXIN}"
    sed -i '$a\# tun-config-end\n' "${CLASH_CONFIG_MIXIN}"
    { clashoff && clashon; } >&/dev/null

    journalctl -u clash | grep -qs 'unsupported kernel version' && {
        _tunoff >&/dev/null
        _error_quit '当前系统内核版本不支持'
    }
    _okcat "Tun 模式已开启"
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
        clashtun >&/dev/null && local is_tun=true
        { clashoff && clashon; } >/dev/null 2>&1
        [ "$is_tun" = true ] && clashtun on
        _okcat '配置更新成功，已重启生效'
        echo "$url" >"$CLASH_CONFIG_URL"
        echo "$(date +"%Y-%m-%d %H:%M:%S") 配置更新成功 ✅ $url" >>"${CLASH_UPDATE_LOG}"
    } || {
        echo "$(date +"%Y-%m-%d %H:%M:%S") 配置更新失败 ❌ $url" >>"${CLASH_UPDATE_LOG}"
        _error_quit '配置无效：请检查配置内容'
    }
}

_ls_mixin() {
    /bin/ls "$CLASH_MIXIN_BASE_DIR" | grep -v status | awk '{print NR, $NF}'
}

function clashmixin() {
    case "$1" in
    '')
        _ls_mixin
        ;;
    on)
        target=$(_ls_mixin | grep "$2" | awk '{print $2}')
        grep -qs "$target" "$CLASH_MIXIN_BASE_DIR/status" || echo "$target on" >>"$CLASH_MIXIN_BASE_DIR/status" &&
            sed -i "/$target/s/off/on/" "$CLASH_MIXIN_BASE_DIR/status"
        grep -s on "$CLASH_MIXIN_BASE_DIR/status" | awk '{print $1}'

        # yq ea '. as $item ireduce ({}; . * $item )' "$CLASH_CONFIG_RAW" "$CLASH_MIXIN_BASE_DIR/*on.yaml"
        ;;
    off)
        echo "off"
        ;;
    *)
        echo "Usage"
        ;;
    esac

}

function clash() {
    cat <<EOF | column -t -s '：'
Usage:
    开启代理： clashon
    关闭代理： clashoff
    面板地址： clashui
    Tun模式： clashtun [on|off]
    更新订阅： clashupdate [--auto] [url]
    设置密钥： clashsecret [secret]
EOF
}
