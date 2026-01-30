#!/usr/bin/env bash

THIS_SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE:-${(%):-%N}}")")
. "$THIS_SCRIPT_DIR/common.sh"

_set_system_proxy() {
    local mixed_port=$("$BIN_YQ" '.mixed-port // ""' "$CLASH_CONFIG_RUNTIME")
    local http_port=$("$BIN_YQ" '.port // ""' "$CLASH_CONFIG_RUNTIME")
    local socks_port=$("$BIN_YQ" '.socks-port // ""' "$CLASH_CONFIG_RUNTIME")

    local auth=$("$BIN_YQ" '.authentication[0] // ""' "$CLASH_CONFIG_RUNTIME")
    [ -n "$auth" ] && auth=$auth@

    local bind_addr=$(_get_bind_addr)
    local http_proxy_addr="http://${auth}${bind_addr}:${http_port:-${mixed_port}}"
    local socks_proxy_addr="socks5h://${auth}${bind_addr}:${socks_port:-${mixed_port}}"
    local no_proxy_addr="localhost,127.0.0.1,::1"

    export http_proxy=$http_proxy_addr
    export HTTP_PROXY=$http_proxy

    export https_proxy=$http_proxy
    export HTTPS_PROXY=$https_proxy

    export all_proxy=$socks_proxy_addr
    export ALL_PROXY=$all_proxy

    export no_proxy=$no_proxy_addr
    export NO_PROXY=$no_proxy
}
_unset_system_proxy() {
    unset http_proxy
    unset https_proxy
    unset HTTP_PROXY
    unset HTTPS_PROXY
    unset all_proxy
    unset ALL_PROXY
    unset no_proxy
    unset NO_PROXY
}
_detect_proxy_port() {
    local mixed_port=$("$BIN_YQ" '.mixed-port // ""' "$CLASH_CONFIG_RUNTIME")
    local http_port=$("$BIN_YQ" '.port // ""' "$CLASH_CONFIG_RUNTIME")
    local socks_port=$("$BIN_YQ" '.socks-port // ""' "$CLASH_CONFIG_RUNTIME")
    [ -z "$mixed_port" ] && [ -z "$http_port" ] && [ -z "$socks_port" ] && mixed_port=7890

    local newPort count=0
    local port_list=(
        "mixed_port|mixed-port"
        "http_port|port"
        "socks_port|socks-port"
    )
    clashstatus >&/dev/null && local isActive='true'
    for entry in "${port_list[@]}"; do
        local var_name="${entry%|*}"
        local yaml_key="${entry#*|}"

        eval "local var_val=\${$var_name}"

        [ -n "$var_val" ] && _is_port_used "$var_val" && [ "$isActive" != "true" ] && {
            newPort=$(_get_random_port)
            ((count++))
            _failcat '🎯' "端口冲突：[$yaml_key] $var_val 🎲 随机分配 $newPort"
            "$BIN_YQ" -i ".${yaml_key} = $newPort" "$CLASH_CONFIG_MIXIN"
        }
    done
    ((count)) && _merge_config
}

function clashon() {
    _detect_proxy_port
    clashstatus >&/dev/null || placeholder_start
    clashstatus >&/dev/null || {
        _failcat '启动失败: 执行 clashlog 查看日志'
        return 1
    }
    clashproxy >/dev/null && _set_system_proxy
    _okcat '已开启代理环境'
}

watch_proxy() {
    [ -z "$http_proxy" ] && {
        # [[ "$0" == -* ]] && { # 登录式shell
        [[ $- == *i* ]] && { # 交互式shell
            placeholder_watch_proxy
        }
    }
}

function clashoff() {
    clashstatus >&/dev/null && {
        placeholder_stop >/dev/null
        clashstatus >&/dev/null && _tunstatus >&/dev/null && {
            _tunoff || _error_quit "请先关闭 Tun 模式"
        }
        placeholder_stop >/dev/null
        clashstatus >&/dev/null && {
            _failcat '代理环境关闭失败'
            return 1
        }
    }
    _unset_system_proxy
    _okcat '已关闭代理环境'
}

clashrestart() {
    clashoff >/dev/null
    clashon
}

function clashproxy() {
    case "$1" in
    -h | --help)
        cat <<EOF

- 查看系统代理状态
  clashproxy

- 开启系统代理
  clashproxy on

- 关闭系统代理
  clashproxy off

EOF
        return 0
        ;;
    on)
        clashstatus >&/dev/null || {
            _failcat "$KERNEL_NAME 未运行，请先执行 clashon"
            return 1
        }
        "$BIN_YQ" -i '._custom.system-proxy.enable = true' "$CLASH_CONFIG_MIXIN"
        _set_system_proxy
        _okcat '已开启系统代理'
        ;;
    off)
        "$BIN_YQ" -i '._custom.system-proxy.enable = false' "$CLASH_CONFIG_MIXIN"
        _unset_system_proxy
        _okcat '已关闭系统代理'
        ;;
    *)
        local system_proxy_enable=$("$BIN_YQ" '._custom.system-proxy.enable' "$CLASH_CONFIG_MIXIN" 2>/dev/null)
        case $system_proxy_enable in
        true)
            _okcat "系统代理：开启
$(env | grep -i 'proxy=')"
            ;;
        *)
            _failcat "系统代理：关闭"
            ;;
        esac
        ;;
    esac
}

function clashstatus() {
    placeholder_status "$@"
    placeholder_is_active >&/dev/null
}

function clashlog() {
    placeholder_log "$@"
}

function clashui() {
    _detect_ext_addr
    clashstatus >&/dev/null || clashon >/dev/null
    local query_url='api64.ipify.org' # ifconfig.me
    local public_ip=$(curl -s --noproxy "*" --location --max-time 2 $query_url)
    local public_address="http://${public_ip:-公网}:${EXT_PORT}/ui"

    local local_ip=$EXT_IP
    local local_address="http://${local_ip}:${EXT_PORT}/ui"
    printf "\n"
    printf "╔═══════════════════════════════════════════════╗\n"
    printf "║                %s                  ║\n" "$(_okcat 'Web 控制台')"
    printf "║═══════════════════════════════════════════════║\n"
    printf "║                                               ║\n"
    printf "║     🔓 注意放行端口：%-5s                    ║\n" "$EXT_PORT"
    printf "║     🏠 内网：%-31s  ║\n" "$local_address"
    printf "║     🌏 公网：%-31s  ║\n" "$public_address"
    printf "║     ☁️  公共：%-31s  ║\n" "$URL_CLASH_UI"
    printf "║                                               ║\n"
    printf "╚═══════════════════════════════════════════════╝\n"
    printf "\n"
}

function clashtui() {
    clashstatus >&/dev/null || {
        _failcat "未检测到内核运行，请先执行 clashon"
        return 1
    }

    local bin="${BIN_BASE_DIR}/clashtui"
    [ -x "$bin" ] || {
        _failcat "未找到可执行文件：$bin"
        _failcat "如需从源码构建：cd \"$CLASH_BASE_DIR/clashtui\" && GOPROXY=\"https://goproxy.cn,direct\" go build -o \"$bin\" ./cmd/clashtui"
        return 1
    }

    "$bin" "$@"
}

_merge_config() {
    cat "$CLASH_CONFIG_RUNTIME" >"$CLASH_CONFIG_TEMP" 2>/dev/null
    # shellcheck disable=SC2016
    "$BIN_YQ" eval-all '
      ########################################
      #              Load Files              #
      ########################################
      select(fileIndex==0) as $config |
      select(fileIndex==1) as $mixin |
      
      ########################################
      #              Deep Merge              #
      ########################################
      $mixin |= del(._custom) |
      (($config // {}) * $mixin) as $runtime |
      $runtime |
      
      ########################################
      #               Rules                  #
      ########################################
      .rules = (
        ($mixin.rules.prefix // []) +
        ($config.rules // []) +
        ($mixin.rules.suffix // [])
      ) |
      
      ########################################
      #                Proxies               #
      ########################################
      .proxies = (
        ($mixin.proxies.prefix // []) +
        (
          ($config.proxies // []) as $configList |
          ($mixin.proxies.override // []) as $overrideList |
          $configList | map(
            . as $configItem |
            (
              $overrideList[] | select(.name == $configItem.name)
            ) // $configItem
          )
        ) +
        ($mixin.proxies.suffix // [])
      ) |
      
      ########################################
      #             ProxyGroups              #
      ########################################
      .proxy-groups = (
        ($mixin.proxy-groups.prefix // []) +
        (
          ($config.proxy-groups // []) as $configList |
          ($mixin.proxy-groups.override // []) as $overrideList |
          $configList | map(
            . as $configItem |
            (
              $overrideList[] | select(.name == $configItem.name)
            ) // $configItem
          )
        ) +
        ($mixin.proxy-groups.suffix // [])
      )
    ' "$CLASH_CONFIG_BASE" "$CLASH_CONFIG_MIXIN" >"$CLASH_CONFIG_RUNTIME"
    _valid_config "$CLASH_CONFIG_RUNTIME" || {
        cat "$CLASH_CONFIG_TEMP" >"$CLASH_CONFIG_RUNTIME"
        _error_quit "验证失败：请检查 Mixin 配置"
    }
}

_merge_config_restart() {
    _merge_config
    placeholder_stop >/dev/null
    clashstatus >&/dev/null && _tunstatus >&/dev/null && {
        _tunoff || _error_quit "请先关闭 Tun 模式"
    }
    placeholder_stop >/dev/null
    sleep 0.1
    placeholder_start >/dev/null
    sleep 0.1
}
_get_secret() {
    "$BIN_YQ" '.secret // ""' "$CLASH_CONFIG_RUNTIME"
}
function clashsecret() {
    case "$1" in
    -h | --help)
        cat <<EOF

- 查看 Web 密钥
  clashsecret

- 修改 Web 密钥
  clashsecret <new_secret>

EOF
        return 0
        ;;
    esac

    case $# in
    0)
        _okcat "当前密钥：$(_get_secret)"
        ;;
    1)
        "$BIN_YQ" -i ".secret = \"$1\"" "$CLASH_CONFIG_MIXIN" || {
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
    local tun_status=$("$BIN_YQ" '.tun.enable' "${CLASH_CONFIG_RUNTIME}")
    case $tun_status in
    true)
        _okcat 'Tun 状态：启用'
        ;;
    *)
        _failcat 'Tun 状态：关闭'
        ;;
    esac
}
_tunoff() {
    _tunstatus >/dev/null || return 0
    sudo placeholder_stop
    clashstatus >&/dev/null || {
        "$BIN_YQ" -i '.tun.enable = false' "$CLASH_CONFIG_MIXIN"
        _merge_config
        clashon >/dev/null
        _okcat "Tun 模式已关闭"
        return 0
    }
    _tunstatus >&/dev/null && _failcat "Tun 模式关闭失败"
}
_sudo_restart() {
    sudo placeholder_stop
    placeholder_sudo_start
    sleep 0.5
}
_tunon() {
    _tunstatus 2>/dev/null && return 0
    sudo placeholder_stop
    "$BIN_YQ" -i '.tun.enable = true' "$CLASH_CONFIG_MIXIN"
    _merge_config
    placeholder_sudo_start
    sleep 0.5
    clashstatus >&/dev/null || _error_quit "Tun 模式开启失败"
    local fail_msg="Start TUN listening error|unsupported kernel version"
    local ok_msg="Tun adapter listening at|TUN listening iface"
    clashlog | grep -E -m1 -qs "$fail_msg" && {
        [ "$KERNEL_NAME" = 'mihomo' ] && {
            "$BIN_YQ" -i '.tun.auto-redirect = false' "$CLASH_CONFIG_MIXIN"
            _merge_config
            _sudo_restart
        }
        clashlog | grep -E -m1 -qs "$ok_msg" || {
            clashlog | grep -E -m1 "$fail_msg"
            _tunoff >&/dev/null
            _error_quit '系统内核版本不支持 Tun 模式'
        }
    }
    _okcat "Tun 模式已开启"
}

function clashtun() {
    case "$1" in
    -h | --help)
        cat <<EOF

- 查看 Tun 状态
  clashtun

- 开启 Tun 模式
  clashtun on

- 关闭 Tun 模式
  clashtun off
  
EOF
        return 0
        ;;
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

function clashmixin() {
    case "$1" in
    -h | --help)
        cat <<EOF

- 查看 Mixin 配置：$CLASH_CONFIG_MIXIN
  clashmixin

- 编辑 Mixin 配置
  clashmixin -e

- 查看原始订阅配置：$CLASH_CONFIG_BASE
  clashmixin -c

- 查看运行时配置：$CLASH_CONFIG_RUNTIME
  clashmixin -r

EOF
        return 0
        ;;
    -e)
        vim "$CLASH_CONFIG_MIXIN" && {
            _merge_config_restart && _okcat "配置更新成功，已重启生效"
        }
        ;;
    -r)
        less "$CLASH_CONFIG_RUNTIME"
        ;;
    -c)
        less "$CLASH_CONFIG_BASE"
        ;;
    *)
        less "$CLASH_CONFIG_MIXIN"
        ;;
    esac
}

function clashupgrade() {
    for arg in "$@"; do
        case $arg in
        -h | --help)
            cat <<EOF
Usage:
  clashupgrade [OPTIONS]

Options:
  -v, --verbose       输出内核升级日志
  -r, --release       升级至稳定版
  -a, --alpha         升级至测试版
  -h, --help          显示帮助信息

EOF
            return 0
            ;;
        -v | --verbose)
            local log_flag=true
            ;;
        -r | --release)
            channel="release"
            ;;
        -a | --alpha)
            channel="alpha"
            ;;
        *)
            channel=""
            ;;
        esac
    done

    _detect_ext_addr
    clashstatus >&/dev/null || clashon >/dev/null
    _okcat '⏳' "请求内核升级..."
    [ "$log_flag" = true ] && {
        log_cmd=(placeholder_follow_log)
        ("${log_cmd[@]}" &)

    }
    local res=$(
        curl -X POST \
            --silent \
            --noproxy "*" \
            --location \
            -H "Authorization: Bearer $(_get_secret)" \
            "http://${EXT_IP}:${EXT_PORT}/upgrade?channel=$channel"
    )
    [ "$log_flag" = true ] && pkill -9 -f "${log_cmd[*]}"

    grep '"status":"ok"' <<<"$res" && {
        _okcat "内核升级成功"
        return 0
    }
    grep 'already using latest version' <<<"$res" && {
        _okcat "已是最新版本"
        return 0
    }
    _failcat "内核升级失败，请检查网络或稍后重试"
}

function clashsub() {
    case "$1" in
    add)
        shift
        _sub_add "$@"
        ;;
    del)
        shift
        _sub_del "$@"
        ;;
    list | ls | '')
        shift
        _sub_list "$@"
        ;;
    use)
        shift
        _sub_use "$@"
        ;;
    update)
        shift
        _sub_update "$@"
        ;;
    log)
        shift
        _sub_log "$@"
        ;;
    -h | --help | *)
        cat <<EOF
clashsub - Clash 订阅管理工具

Usage: 
  clashsub COMMAND [OPTIONS]

Commands:
  add <url>       添加订阅
  ls              查看订阅
  del <id>        删除订阅
  use <id>        使用订阅
  update [id]     更新订阅
  log             订阅日志

Options:
  update:
    --auto        配置自动更新
    --convert     使用订阅转换
EOF
        ;;
    esac
}
_sub_add() {
    local url=$1
    [ -z "$url" ] && {
        echo -n "$(_okcat '✈️ ' '请输入要添加的订阅链接：')"
        read -r url
        [ -z "$url" ] && _error_quit "订阅链接不能为空"
    }
    _get_url_by_id "$id" >/dev/null && _error_quit "该订阅链接已存在"

    _download_config "$CLASH_CONFIG_TEMP" "$url"
    _valid_config "$CLASH_CONFIG_TEMP" || _error_quit "订阅无效，请检查：
    原始订阅：${CLASH_CONFIG_TEMP}.raw
    转换订阅：$CLASH_CONFIG_TEMP
    转换日志：$BIN_SUBCONVERTER_LOG"

    local id=$("$BIN_YQ" '.profiles // [] | (map(.id) | max) // 0 | . + 1' "$CLASH_PROFILES_META")
    local profile_path="${CLASH_PROFILES_DIR}/${id}.yaml"
    mv "$CLASH_CONFIG_TEMP" "$profile_path"

    "$BIN_YQ" -i "
         .profiles = (.profiles // []) + 
         [{
           \"id\": $id,
           \"path\": \"$profile_path\",
           \"url\": \"$url\"
         }]
    " "$CLASH_PROFILES_META"
    _logging_sub "➕ 已添加订阅：[$id] $url"
    _okcat '🎉' "订阅已添加：[$id] $url"
}
_sub_del() {
    local id=$1
    [ -z "$id" ] && {
        echo -n "$(_okcat '✈️ ' '请输入要删除的订阅 id：')"
        read -r id
        [ -z "$id" ] && _error_quit "订阅 id 不能为空"
    }
    local profile_path url
    profile_path=$(_get_path_by_id "$id") || _error_quit "订阅 id 不存在，请检查"
    url=$(_get_url_by_id "$id")
    use=$("$BIN_YQ" '.use // ""' "$CLASH_PROFILES_META")
    [ "$use" = "$id" ] && _error_quit "删除失败：订阅 $id 正在使用中，请先切换订阅"
    /usr/bin/rm -f "$profile_path"
    "$BIN_YQ" -i "del(.profiles[] | select(.id == \"$id\"))" "$CLASH_PROFILES_META"
    _logging_sub "➖ 已删除订阅：[$id] $url"
    _okcat '🎉' "订阅已删除：[$id] $url"
}
_sub_list() {
    "$BIN_YQ" "$CLASH_PROFILES_META"
}
_sub_use() {
    "$BIN_YQ" -e '.profiles // [] | length == 0' "$CLASH_PROFILES_META" >&/dev/null &&
        _error_quit "当前无可用订阅，请先添加订阅"
    local id=$1
    [ -z "$id" ] && {
        clashsub ls
        echo -n "$(_okcat '✈️ ' '请输入要使用的订阅 id：')"
        read -r id
        [ -z "$id" ] && _error_quit "订阅 id 不能为空"
    }
    local profile_path url
    profile_path=$(_get_path_by_id "$id") || _error_quit "订阅 id 不存在，请检查"
    url=$(_get_url_by_id "$id")
    cat "$profile_path" >"$CLASH_CONFIG_BASE"
    _merge_config_restart
    "$BIN_YQ" -i ".use = $id" "$CLASH_PROFILES_META"
    _logging_sub "🔥 订阅已切换为：[$id] $url"
    _okcat '🔥' '订阅已生效'
}
_get_path_by_id() {
    "$BIN_YQ" -e ".profiles[] | select(.id == \"$1\") | .path" "$CLASH_PROFILES_META" 2>/dev/null
}
_get_url_by_id() {
    "$BIN_YQ" -e ".profiles[] | select(.id == \"$1\") | .url" "$CLASH_PROFILES_META" 2>/dev/null
}
_sub_update() {
    local arg is_convert
    for arg in "$@"; do
        case $arg in
        --auto)
            command -v crontab >/dev/null || _error_quit "未检测到 crontab 命令，请先安装 cron 服务"
            crontab -l | grep -qs 'clashsub update' || {
                (
                    crontab -l 2>/dev/null
                    echo "0 0 */2 * * $SHELL -i -c 'clashsub update'"
                ) | crontab -
            }
            _okcat "已设置定时更新订阅"
            return 0
            ;;
        --convert)
            is_convert=true
            shift
            ;;
        esac
    done
    local id=$1
    [ -z "$id" ] && id=$("$BIN_YQ" '.use // 1' "$CLASH_PROFILES_META")
    local url profile_path
    url=$(_get_url_by_id "$id") || _error_quit "订阅 id 不存在，请检查"
    profile_path=$(_get_path_by_id "$id")
    _okcat "✈️ " "更新订阅：[$id] $url"

    [ "$is_convert" = true ] && {
        _download_convert_config "$CLASH_CONFIG_TEMP" "$url"
    }
    [ "$is_convert" != true ] && {
        _download_config "$CLASH_CONFIG_TEMP" "$url"
    }
    _valid_config "$CLASH_CONFIG_TEMP" || {
        _logging_sub "❌ 订阅更新失败：[$id] $url"
        _error_quit "订阅无效：请检查：
    原始订阅：${CLASH_CONFIG_TEMP}.raw
    转换订阅：$CLASH_CONFIG_TEMP
    转换日志：$BIN_SUBCONVERTER_LOG"
    }
    _logging_sub "✅ 订阅更新成功：[$id] $url"
    cat "$CLASH_CONFIG_TEMP" >"$profile_path"
    use=$("$BIN_YQ" '.use // ""' "$CLASH_PROFILES_META")
    [ "$use" = "$id" ] && clashsub use "$use" && return
    _okcat '订阅已更新'
}
_logging_sub() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") $1" >>"${CLASH_PROFILES_LOG}"
}
_sub_log() {
    tail <"${CLASH_PROFILES_LOG}" "$@"
}

function clashctl() {
    case "$1" in
    on)
        shift
        clashon
        ;;
    off)
        shift
        clashoff
        ;;
    ui)
        shift
        clashui
        ;;
    tui)
        shift
        clashtui "$@"
        ;;
    status)
        shift
        clashstatus "$@"
        ;;
    log)
        shift
        clashlog "$@"
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
    sub)
        shift
        clashsub "$@"
        ;;
    upgrade)
        shift
        clashupgrade "$@"
        ;;
    *)
        (($#)) && shift
        clashhelp "$@"
        ;;
    esac
}

clashhelp() {
    cat <<EOF
    
Usage: 
  clashctl COMMAND [OPTIONS]

Commands:
  on                    开启代理
  off                   关闭代理
  proxy                 系统代理
  status                内核状态
  ui                    面板地址
  tui                   TUI 面板
  sub                   订阅管理
  log                   内核日志
  tun                   Tun 模式
  mixin                 Mixin 配置
  secret                Web 密钥
  upgrade               升级内核

Global Options:
  -h, --help            显示帮助信息

For more help on how to use clashctl, head to https://github.com/nelvko/clash-for-linux-install
EOF
}
