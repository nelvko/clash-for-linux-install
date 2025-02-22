#!/bin/bash
# shellcheck disable=SC2155

function clashon() {
    _get_port
    sudo systemctl start clash && _okcat '已开启代理环境' ||
        _failcat '启动失败: 执行 "clashstatus" 查看日志' || return 1

    local http_proxy_addr="http://127.0.0.1:${MIXED_PORT}"
    local socks_proxy_addr="socks5://127.0.0.1:${MIXED_PORT}"
    local no_proxy_addr="localhost,127.0.0.1,::1"

    export http_proxy=$http_proxy_addr
    export https_proxy=$http_proxy
    export HTTP_PROXY=$http_proxy
    export HTTPS_PROXY=$http_proxy

    export all_proxy=$socks_proxy_addr
    export ALL_PROXY=$all_proxy

    export no_proxy=$no_proxy_addr
    export NO_PROXY=$no_proxy
}

function clashoff() {
    sudo systemctl stop clash && _okcat '已关闭代理环境' ||
        _failcat '关闭失败: 执行 "clashstatus" 查看日志' || return 1

    unset http_proxy
    unset https_proxy
    unset HTTP_PROXY
    unset HTTPS_PROXY
    unset all_proxy
    unset ALL_PROXY
    unset no_proxy
    unset NO_PROXY
}

clashrestart() {
    { clashoff && clashon; } >&/dev/null
}

clashstatus() {
    sudo systemctl status clash "$@"
}

function clashui() {
    # 防止tun模式强制走代理
    clashoff >&/dev/null
    # 查询公网ip
    # ifconfig.me
    # cip.cc
    _get_port
    local public_ip=$(curl -s --noproxy "*" --connect-timeout 2 ifconfig.me)
    local public_address="http://${public_ip:-公网IP}:${UI_PORT}/ui"
    # 内网ip
    # ip route get 1.1.1.1 | grep -oP 'src \K\S+'
    local local_ip=$(hostname -I | awk '{print $1}')
    local local_address="http://${local_ip}:${UI_PORT}/ui"
    printf "\n"
    printf "╔═══════════════════════════════════════════════╗\n"
    printf "║                %s                ║\n" "$(_okcat 'Web 面板地址')"
    printf "║═══════════════════════════════════════════════║\n"
    printf "║                                               ║\n"
    printf "║     🔓 注意放行端口：%-5s                    ║\n" "$UI_PORT"
    printf "║     🏠 内网：%-31s  ║\n" "$local_address"
    printf "║     🌍 公网：%-31s  ║\n" "$public_address"
    printf "║     ☁️  公共：%-31s  ║\n" "$URL_CLASH_UI"
    printf "║                                               ║\n"
    printf "╚═══════════════════════════════════════════════╝\n"
    printf "\n"
    clashon >&/dev/null
}

_merge_config_restart() {
    _valid_config "$CLASH_CONFIG_MIXIN" || _error_quit "Mixin 配置验证失败，请检查"
    sudo "$BIN_YQ" -n "load(\"$CLASH_CONFIG_RAW\") * load(\"$CLASH_CONFIG_MIXIN\")" | sudo tee "$CLASH_CONFIG_RUNTIME" >&/dev/null && clashrestart
}

function clashsecret() {
    case "$#" in
    0)
        _okcat "当前密钥：$(sudo "$BIN_YQ" '.secret // ""' "$CLASH_CONFIG_RUNTIME")"
        ;;
    1)
        local secret=$1
        [ -z "$secret" ] && secret=\"\"
        sudo "$BIN_YQ" -i ".secret = $secret" "$CLASH_CONFIG_MIXIN"
        _merge_config_restart
        _okcat "密钥更新成功，已重启生效"
        ;;
    *)
        _failcat "密钥不要包含空格或使用引号包围"
        ;;
    esac
}

_tunstatus() {
    local status=$(sudo "$BIN_YQ" '.tun.enable' "${CLASH_CONFIG_RUNTIME}")
    # shellcheck disable=SC2015
    [ "$status" = 'true' ] && _okcat 'Tun 状态：启用' || _failcat 'Tun 状态：关闭'
}

_tunoff() {
    _tunstatus >/dev/null || return 0
    sudo "$BIN_YQ" -i '.tun.enable = false' "$CLASH_CONFIG_MIXIN"
    _merge_config_restart && _okcat "Tun 模式已关闭"
}

_tunon() {
    _tunstatus 2>/dev/null && return 0
    sudo "$BIN_YQ" -i '.tun.enable = true' "$CLASH_CONFIG_MIXIN"
    _merge_config_restart
    clashstatus -l | grep -qs 'unsupported kernel version' && {
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
    local is_auto

    case "$1" in
    auto)
        is_auto=true
        [ -n "$2" ] && url=$2
        ;;
    log)
        tail "${CLASH_UPDATE_LOG}"
        return $?
        ;;
    *)
        [ -n "$1" ] && url=$1
        ;;
    esac

    # 如果没有提供有效的订阅链接（url为空或者不是http开头），则使用默认配置文件
    [ "${url:0:4}" != "http" ] && {
        _failcat "没有提供有效的订阅链接，使用${CLASH_CONFIG_RAW}进行更新..."
        url="file://$CLASH_CONFIG_RAW"
    }

    # 如果是自动更新模式，则设置定时任务
    [ "$is_auto" = true ] && {
        sudo grep -qs 'clashupdate' "$CLASH_CRON_TAB" || echo "0 0 */2 * * . $BASHRC;clashupdate $url" | sudo tee -a "$CLASH_CRON_TAB" >&/dev/null
        _okcat "定时任务设置成功" && return 0
    }
    sudo cat "$CLASH_CONFIG_RAW" | sudo tee "$CLASH_CONFIG_RAW_BAK" >&/dev/null
    _download_config "$url" "$CLASH_CONFIG_RAW"

    # 校验并更新配置
    _valid_config "$CLASH_CONFIG_RAW" || _download_convert_config "$CLASH_CONFIG_RAW" "$url"
    _valid_config "$CLASH_CONFIG_RAW" || {
        echo "$(date +"%Y-%m-%d %H:%M:%S") 配置更新失败 ❌ $url" | sudo tee -a "${CLASH_UPDATE_LOG}" >&/dev/null
        sudo cat "$CLASH_CONFIG_RAW_BAK" | sudo tee "$CLASH_CONFIG_RAW" >&/dev/null
        _error_quit '下载失败或配置无效：已回滚配置'
    }
    _merge_config_restart && _okcat '配置更新成功，已重启生效'
    echo "$url" | sudo tee "$CLASH_CONFIG_URL" >&/dev/null
    echo "$(date +"%Y-%m-%d %H:%M:%S") 配置更新成功 ✅ $url" | sudo tee -a "${CLASH_UPDATE_LOG}" >&/dev/null
}

function clashmixin() {
    case "$1" in
    -e)
        sudo vim "$CLASH_CONFIG_MIXIN" && {
            _merge_config_restart && _okcat "配置更新成功，已重启生效"
        }
        ;;
    -r)
        less "$CLASH_CONFIG_RUNTIME"
        ;;
    *)
        less "$CLASH_CONFIG_MIXIN"
        ;;
    esac
}

function clash() {
    printf "%b\n" "$(
        cat <<EOF | column -t -s ',' | sed -E 's|(clash)(\w*)|\1\\e[38;2;141;145;165m\2\\e[0m|g'
Usage:
    clash                    命令一览,
    clashon                  开启代理,
    clashoff                 关闭代理,
    clashui                  面板地址,
    clashstatus              内核状况,
    clashtun     [on|off]    Tun 模式,
    clashmixin   [-e|-r]     Mixin 配置,
    clashsecret  [secret]    Web 密钥,
    clashupdate  [auto|log]  更新订阅,
EOF
    )"
}
