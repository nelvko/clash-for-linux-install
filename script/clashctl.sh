# shellcheck disable=SC2148
# shellcheck disable=SC2155

# 设置代理环境变量
_set_proxy_env() {
    _get_proxy_port
    local auth=$(sudo "$BIN_YQ" '.authentication[0] // ""' "$CLASH_CONFIG_RUNTIME")
    [ -n "$auth" ] && auth=$auth@

    local http_proxy_addr="http://${auth}127.0.0.1:${MIXED_PORT}"
    local socks_proxy_addr="socks5h://${auth}127.0.0.1:${MIXED_PORT}"
    local no_proxy_addr="localhost,127.0.0.1,::1"

    export http_proxy=$http_proxy_addr
    export https_proxy=$http_proxy
    export HTTP_PROXY=$http_proxy
    export HTTPS_PROXY=$http_proxy

    export all_proxy=$socks_proxy_addr
    export ALL_PROXY=$all_proxy

    export no_proxy=$no_proxy_addr
    export NO_PROXY=$no_proxy

    # 持久化：记录环境变量代理状态到YAML配置
    sudo "$BIN_YQ" -i '.proxy-env.enable = true' "$CLASH_CONFIG_MIXIN"
}

# 卸载代理环境变量
_unset_proxy_env() {
    unset http_proxy
    unset https_proxy
    unset HTTP_PROXY
    unset HTTPS_PROXY
    unset all_proxy
    unset ALL_PROXY
    unset no_proxy
    unset NO_PROXY

    # 持久化：清除环境变量代理状态
    sudo "$BIN_YQ" -i '.proxy-env.enable = false' "$CLASH_CONFIG_MIXIN"
}

function clashon() {
    systemctl is-active "$BIN_KERNEL_NAME" >&/dev/null || {
        sudo systemctl start "$BIN_KERNEL_NAME" >/dev/null || {
            _failcat '启动失败: 执行 clashstatus 查看日志'
            return 1
        }
    }

    # 检查TUN模式状态，如果开启则不设置环境变量
    local tun_status=$(sudo "$BIN_YQ" '.tun.enable' "$CLASH_CONFIG_MIXIN")
    if [ "$tun_status" = 'true' ]; then
        _okcat '代理程序已启动，TUN模式已开启（环境变量代理已禁用）'
    else
        _set_proxy_env
        _okcat '已开启代理环境'
    fi
}



watch_proxy() {
    [ -z "$http_proxy" ] && [[ $- == *i* ]] && {
        local proxy_env_status=$(sudo "$BIN_YQ" '.proxy-env.enable' "$CLASH_CONFIG_MIXIN" 2>/dev/null)
        if [ "$proxy_env_status" = 'true' ]; then
            _set_proxy_env >/dev/null 2>&1
        fi
    }
}

function clashoff() {
    sudo systemctl stop "$BIN_KERNEL_NAME" && _okcat '已关闭代理程序' ||
        _failcat '关闭失败: 执行 "clashstatus" 查看日志' || return 1

    # 同时清除环境变量
    _unset_proxy_env
}

clashrestart() {
    { clashoff && clashon; } >&/dev/null
}

# 独立的环境变量代理控制
function clashproxy() {
    case "$1" in
    on)
        # 检查代理程序是否运行
        systemctl is-active "$BIN_KERNEL_NAME" >&/dev/null || {
            _failcat '代理程序未运行，请先执行 clashon'
            return 1
        }

        # 检查TUN模式状态
        local tun_status=$(sudo "$BIN_YQ" '.tun.enable' "$CLASH_CONFIG_MIXIN")
        if [ "$tun_status" = 'true' ]; then
            _failcat 'TUN模式已开启，无法同时使用环境变量代理'
            return 1
        fi

        _set_proxy_env  # 自动持久化状态
        _okcat '已开启环境变量代理（新shell会话将自动应用）'
        ;;
    off)
        _unset_proxy_env  # 自动持久化状态
        _okcat '已关闭环境变量代理'
        ;;
    status)
        local proxy_env_status=$(sudo "$BIN_YQ" '.proxy-env.enable' "$CLASH_CONFIG_MIXIN" 2>/dev/null)
        if [ -n "$http_proxy" ]; then
            _okcat "环境变量代理：已开启 ($http_proxy)"
        else
            if [ "$proxy_env_status" = 'true' ]; then
                echo "环境变量代理：已配置开启，但当前shell未生效"
                echo "💡 执行 'clash proxy on' 在当前shell中生效"
            else
                _failcat "环境变量代理：已关闭"
            fi
        fi
        ;;
    *)
        cat <<EOF
用法: clashproxy [on|off|status]
    on      开启环境变量代理（系统代理）
    off     关闭环境变量代理
    status  查看环境变量代理状态
EOF
        ;;
    esac
}

function clashstatus() {
    sudo systemctl status "$BIN_KERNEL_NAME" "$@"
}

function clashui() {
    _get_ui_port
    # 公网ip
    # ifconfig.me
    local query_url='api64.ipify.org'
    local public_ip=$(curl -s --noproxy "*" --connect-timeout 2 $query_url)
    local public_address="http://${public_ip:-公网}:${UI_PORT}/ui"
    # 内网ip
    # ip route get 1.1.1.1 | grep -oP 'src \K\S+'
    local local_ip=$(hostname -I | awk '{print $1}')
    local local_address="http://${local_ip}:${UI_PORT}/ui"
    printf "\n"
    printf "╔═══════════════════════════════════════════════╗\n"
    printf "║                %s                  ║\n" "$(_okcat 'Web 控制台')"
    printf "║═══════════════════════════════════════════════║\n"
    printf "║                                               ║\n"
    printf "║     🔓 注意放行端口：%-5s                    ║\n" "$UI_PORT"
    printf "║     🏠 内网：%-31s  ║\n" "$local_address"
    printf "║     🌏 公网：%-31s  ║\n" "$public_address"
    printf "║     ☁️  公共：%-31s  ║\n" "$URL_CLASH_UI"
    printf "║                                               ║\n"
    printf "╚═══════════════════════════════════════════════╝\n"
    printf "\n"
}

_merge_config_restart() {
    local backup="/tmp/rt.backup"
    sudo cat "$CLASH_CONFIG_RUNTIME" 2>/dev/null | sudo tee $backup >&/dev/null
    sudo "$BIN_YQ" eval-all '. as $item ireduce ({}; . *+ $item) | (.. | select(tag == "!!seq")) |= unique' \
        "$CLASH_CONFIG_MIXIN" "$CLASH_CONFIG_RAW" "$CLASH_CONFIG_MIXIN" | sudo tee "$CLASH_CONFIG_RUNTIME" >&/dev/null
    _valid_config "$CLASH_CONFIG_RUNTIME" || {
        sudo cat $backup | sudo tee "$CLASH_CONFIG_RUNTIME" >&/dev/null
        _error_quit "验证失败：请检查 Mixin 配置"
    }
    clashrestart
}

function clashsecret() {
    case "$#" in
    0)
        _okcat "当前密钥：$(sudo "$BIN_YQ" '.secret // ""' "$CLASH_CONFIG_RUNTIME")"
        ;;
    1)
        sudo "$BIN_YQ" -i ".secret = \"$1\"" "$CLASH_CONFIG_MIXIN" || {
            _failcat "密钥更新失败，请重新输入"
            return 1
        }
        _merge_config_restart
        _okcat "密钥更新成功，已重启生效"
        ;;
    *)
        _failcat "密钥不要包含空格或使用引号包围"
        ;;
    esac
}

_tunstatus() {
    local tun_status=$(sudo "$BIN_YQ" '.tun.enable' "${CLASH_CONFIG_RUNTIME}")
    # shellcheck disable=SC2015
    [ "$tun_status" = 'true' ] && _okcat 'Tun 状态：启用' || _failcat 'Tun 状态：关闭'
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
    sleep 0.5s
    sudo journalctl -u "$BIN_KERNEL_NAME" --since "1 min ago" | grep -E -m1 'unsupported kernel version|Start TUN listening error' && {
        _tunoff >&/dev/null
        _error_quit '不支持的内核版本'
    }

    # 开启TUN模式时卸载环境变量，避免冲突
    _unset_proxy_env
    _okcat "Tun 模式已开启，已自动卸载环境变量代理"
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
        sudo tail "${CLASH_UPDATE_LOG}" 2>/dev/null || _failcat "暂无更新日志"
        return 0
        ;;
    *)
        [ -n "$1" ] && url=$1
        ;;
    esac

    # 如果没有提供有效的订阅链接（url为空或者不是http开头），则使用默认配置文件
    [ "${url:0:4}" != "http" ] && {
        _failcat "没有提供有效的订阅链接：使用 ${CLASH_CONFIG_RAW} 进行更新..."
        url="file://$CLASH_CONFIG_RAW"
    }

    # 如果是自动更新模式，则设置定时任务
    [ "$is_auto" = true ] && {
        sudo grep -qs 'clashupdate' "$CLASH_CRON_TAB" || echo "0 0 */2 * * $_SHELL -i -c 'clashupdate $url'" | sudo tee -a "$CLASH_CRON_TAB" >&/dev/null
        _okcat "已设置定时更新订阅" && return 0
    }

    _okcat '👌' "正在下载：原配置已备份..."
    sudo cat "$CLASH_CONFIG_RAW" | sudo tee "$CLASH_CONFIG_RAW_BAK" >&/dev/null

    _rollback() {
        _failcat '🍂' "$1"
        sudo cat "$CLASH_CONFIG_RAW_BAK" | sudo tee "$CLASH_CONFIG_RAW" >&/dev/null
        _failcat '❌' "[$(date +"%Y-%m-%d %H:%M:%S")] 订阅更新失败：$url" 2>&1 | sudo tee -a "${CLASH_UPDATE_LOG}" >&/dev/null
        _error_quit
    }

    _download_config "$CLASH_CONFIG_RAW" "$url" || _rollback "下载失败：已回滚配置"
    _valid_config "$CLASH_CONFIG_RAW" || _rollback "转换失败：已回滚配置，转换日志：$BIN_SUBCONVERTER_LOG"

    _merge_config_restart && _okcat '🍃' '订阅更新成功'
    echo "$url" | sudo tee "$CLASH_CONFIG_URL" >&/dev/null
    _okcat '✅' "[$(date +"%Y-%m-%d %H:%M:%S")] 订阅更新成功：$url" | sudo tee -a "${CLASH_UPDATE_LOG}" >&/dev/null
}

function clashmixin() {
    case "$1" in
    -e)
        sudo vim "$CLASH_CONFIG_MIXIN" && {
            _merge_config_restart && _okcat "配置更新成功，已重启生效"
        }
        ;;
    -r)
        less -f "$CLASH_CONFIG_RUNTIME"
        ;;
    *)
        less -f "$CLASH_CONFIG_MIXIN"
        ;;
    esac
}

function clashctl() {
    case "$1" in
    on)
        clashon
        ;;
    off)
        clashoff
        ;;
    ui)
        clashui
        ;;
    status)
        shift
        clashstatus "$@"
        ;;
    proxy)
        shift
        clashproxy "$@"
        ;;
    tun)
        shift
        clashtun "$@"
        ;;
    mixin)
        shift
        clashmixin "$@"
        ;;
    secret)
        shift
        clashsecret "$@"
        ;;
    update)
        shift
        clashupdate "$@"
        ;;
    *)
        cat <<EOF

Usage:
    clash      COMMAND  [OPTION]
    mihomo     COMMAND  [OPTION]
    clashctl   COMMAND  [OPTION]
    mihomoctl  COMMAND  [OPTION】

Commands:
    on                      开启代理程序
    off                     关闭代理程序
    proxy    [on|off|status] 环境变量代理控制
    ui                      面板地址
    status                  内核状况
    tun      [on|off]       Tun 模式
    mixin    [-e|-r]        Mixin 配置
    secret   [SECRET]       Web 密钥
    update   [auto|log]     更新订阅

说明:
    - on/off: 控制代理程序启停
    - proxy: 独立控制环境变量代理（系统代理）
    - tun: TUN模式与环境变量代理互斥

EOF
        ;;
    esac
}

function mihomoctl() {
    clashctl "$@"
}

function clash() {
    clashctl "$@"
}

function mihomo() {
    clashctl "$@"
}
