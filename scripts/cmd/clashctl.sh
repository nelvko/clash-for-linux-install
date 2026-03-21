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
    priority)
        shift
        _sub_priority "$@"
        ;;
    failover)
        shift
        _sub_failover "$@"
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
  priority <id> <n>  设置订阅优先级（数字越小优先级越高）
  failover <on|off|status>  自动故障转移（后台运行，检测代理超时后按优先级切换订阅）

Options:
  update:
    --auto        配置自动更新
    --convert     使用订阅转换
  failover on:
    --threshold <n>   触发检测的错误次数阈值（默认 10）
    --window <s>      错误计数的时间窗口秒数（默认 30）
    --timeout <ms>    代理超时毫秒数（默认 3000）
    --cooldown <s>    切换后的冷却秒数（默认 60）
    --recovery <s>    高优先级订阅回切检测间隔秒数（默认 300）
    --test-url <url>  测试地址，可多次指定（默认 gstatic + cloudflare + huawei）
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

    local download_ok=true
    _download_config "$CLASH_CONFIG_TEMP" "$url"
    _valid_config "$CLASH_CONFIG_TEMP" || {
        download_ok=false
        _failcat '⚠️' "订阅暂时无法使用，但仍会添加记录，稍后可通过 update 更新"
    }

    local id=$("$BIN_YQ" '.profiles // [] | (map(.id) | max) // 0 | . + 1' "$CLASH_PROFILES_META")
    local max_priority=$("$BIN_YQ" '.profiles // [] | (map(.priority) | max) // 0 | . + 1' "$CLASH_PROFILES_META")
    local profile_path="${CLASH_PROFILES_DIR}/${id}.yaml"
    if [ "$download_ok" = true ]; then
        mv "$CLASH_CONFIG_TEMP" "$profile_path"
    else
        /usr/bin/rm -f "$CLASH_CONFIG_TEMP" "${CLASH_CONFIG_TEMP}.raw"
    fi

    "$BIN_YQ" -i "
         .profiles = (.profiles // []) + 
         [{
           \"id\": $id,
           \"path\": \"$profile_path\",
           \"url\": \"$url\",
           \"priority\": $max_priority
         }]
    " "$CLASH_PROFILES_META"
    _logging_sub "➕ 已添加订阅：[$id] $url (priority: $max_priority)"
    _okcat '🎉' "订阅已添加：[$id] $url (优先级: $max_priority)"
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
    [ ! -f "$profile_path" ] && {
        _failcat '⚠️' "配置文件不存在，尝试下载..."
        _download_config "$CLASH_CONFIG_TEMP" "$url"
        _valid_config "$CLASH_CONFIG_TEMP" || _error_quit "订阅下载失败，无法使用"
        mv "$CLASH_CONFIG_TEMP" "$profile_path"
    }
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
_sub_priority() {
    local id=$1
    local priority=$2
    [ -z "$id" ] && {
        clashsub ls
        echo -n "$(_okcat '✈️ ' '请输入订阅 id：')"
        read -r id
        [ -z "$id" ] && _error_quit "订阅 id 不能为空"
    }
    _get_path_by_id "$id" >/dev/null || _error_quit "订阅 id 不存在，请检查"
    [ -z "$priority" ] && {
        echo -n "$(_okcat '✈️ ' '请输入优先级（数字越小优先级越高）：')"
        read -r priority
        [ -z "$priority" ] && _error_quit "优先级不能为空"
    }
    [[ "$priority" =~ ^[0-9]+$ ]] || _error_quit "优先级必须为非负整数"
    "$BIN_YQ" -i "(.profiles[] | select(.id == \"$id\")).priority = $priority" "$CLASH_PROFILES_META"
    _logging_sub "🔢 订阅优先级已更新：[$id] priority=$priority"
    _okcat '🔢' "订阅 [$id] 优先级已设置为 $priority"
}
_get_priority_by_id() {
    "$BIN_YQ" -e ".profiles[] | select(.id == \"$1\") | .priority // 999" "$CLASH_PROFILES_META" 2>/dev/null
}
_get_sorted_profile_ids() {
    "$BIN_YQ" '.profiles // [] | sort_by(.priority // 999) | .[].id' "$CLASH_PROFILES_META"
}
_test_all_proxies() {
    local timeout=$1
    shift
    local test_urls=("$@")
    _detect_ext_addr
    local secret=$(_get_secret)
    local auth_header=""
    [ -n "$secret" ] && auth_header="Authorization: Bearer $secret"

    local proxies_json
    proxies_json=$(curl -s --noproxy "*" --max-time 5 \
        ${auth_header:+-H "$auth_header"} \
        "http://${EXT_IP}:${EXT_PORT}/proxies")
    [ -z "$proxies_json" ] && return 1

    local proxy_names
    proxy_names=$(echo "$proxies_json" | "$BIN_YQ" -p json '
        .proxies | to_entries | .[] |
        select(.value.type == "Shadowsocks" or .value.type == "VMess" or .value.type == "Trojan" or
               .value.type == "ShadowsocksR" or .value.type == "Hysteria" or .value.type == "Hysteria2" or
               .value.type == "VLESS" or .value.type == "WireGuard" or .value.type == "TUIC" or
               .value.type == "Snell" or .value.type == "Http" or .value.type == "Socks5") |
        .key
    ' 2>/dev/null)
    [ -z "$proxy_names" ] && return 1

    # 任意一个代理对任意一个测试地址有延迟响应即认为代理可用
    local name encoded_name delay_result delay url
    while IFS= read -r name; do
        encoded_name=$(printf '%s' "$name" | sed 's/ /%20/g; s/\[/%5B/g; s/\]/%5D/g')
        for url in "${test_urls[@]}"; do
            delay_result=$(curl -s --noproxy "*" --max-time $(( (timeout / 1000) + 2 )) \
                ${auth_header:+-H "$auth_header"} \
                "http://${EXT_IP}:${EXT_PORT}/proxies/${encoded_name}/delay?timeout=${timeout}&url=${url}")
            delay=$(echo "$delay_result" | "$BIN_YQ" -p json '.delay // 0' 2>/dev/null)
            [ -n "$delay" ] && [ "$delay" -gt 0 ] 2>/dev/null && return 0
        done
    done <<<"$proxy_names"

    return 1
}
_failover_is_running() {
    [ -f "$CLASH_FAILOVER_PID" ] || return 1
    local pid
    pid=$(cat "$CLASH_FAILOVER_PID" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}
_failover_stop() {
    _failover_is_running || {
        _failcat '故障转移未运行'
        /usr/bin/rm -f "$CLASH_FAILOVER_PID"
        return 1
    }
    local pid
    pid=$(cat "$CLASH_FAILOVER_PID")
    kill "$pid" 2>/dev/null
    /usr/bin/rm -f "$CLASH_FAILOVER_PID"
    _logging_sub "🛑 故障转移已停止 (pid=$pid)"
    _okcat '🛑' "故障转移已停止"
}
_sub_failover() {
    local action=$1
    case "$action" in
    on)
        shift
        _failover_is_running && {
            _failcat '故障转移已在运行中 (pid='"$(cat "$CLASH_FAILOVER_PID")"')'
            return 1
        }
        _failover_start "$@"
        ;;
    off)
        _failover_stop
        ;;
    status)
        if _failover_is_running; then
            _okcat '🔄' "故障转移运行中 (pid=$(cat "$CLASH_FAILOVER_PID"))"
            [ -f "$CLASH_FAILOVER_LOG" ] && _okcat '📄' "日志：$CLASH_FAILOVER_LOG"
        else
            _failcat '故障转移未运行'
        fi
        ;;
    *)
        cat <<EOF
用法: clashsub failover <on|off|status> [OPTIONS]

  on      启动故障转移（后台运行）
  off     停止故障转移
  status  查看故障转移状态

Options (on):
  --threshold <n>   触发检测的错误次数阈值（默认 10）
  --window <s>      错误计数的时间窗口秒数（默认 30）
  --timeout <ms>    代理超时毫秒数（默认 3000）
  --cooldown <s>    切换后的冷却秒数（默认 60）
  --recovery <s>    高优先级订阅回切检测间隔秒数（默认 300）
  --test-url <url>  测试地址，可多次指定（默认 gstatic + cloudflare + huawei）
EOF
        ;;
    esac
}
_failover_start() {
    local threshold=10
    local window=30
    local timeout=3000
    local cooldown=60
    local recovery=300
    local test_urls=(
        "https://www.gstatic.com/generate_204"
        "https://cp.cloudflare.com/generate_204"
        "https://connectivitycheck.platform.hicloud.com/generate_204"
    )
    local custom_urls=()

    while [ $# -gt 0 ]; do
        case "$1" in
        --threshold)
            threshold=$2
            shift 2
            ;;
        --window)
            window=$2
            shift 2
            ;;
        --timeout)
            timeout=$2
            shift 2
            ;;
        --cooldown)
            cooldown=$2
            shift 2
            ;;
        --recovery)
            recovery=$2
            shift 2
            ;;
        --test-url)
            custom_urls+=("$2")
            shift 2
            ;;
        *)
            shift
            ;;
        esac
    done
    [ ${#custom_urls[@]} -gt 0 ] && test_urls=("${custom_urls[@]}")

    clashstatus >&/dev/null || {
        _failcat "$KERNEL_NAME 未运行，请先执行 clashon"
        return 1
    }

    _failover_loop "$threshold" "$window" "$timeout" "$cooldown" "$recovery" "${test_urls[@]}" \
        >>"$CLASH_FAILOVER_LOG" 2>&1 &
    echo $! >"$CLASH_FAILOVER_PID"

    _okcat '🔄' "故障转移已启动（后台运行 pid=$!）"
    _okcat '🔄' "错误阈值: ${threshold} 次/${window}s  超时: ${timeout}ms  冷却: ${cooldown}s  回切: ${recovery}s"
    _okcat '🔄' "测试地址: ${test_urls[*]}"
    _okcat '📄' "日志：$CLASH_FAILOVER_LOG"
    _logging_sub "🔄 故障转移已启动 (pid=$!, threshold=${threshold}, window=${window}s, timeout=${timeout}ms, cooldown=${cooldown}s, recovery=${recovery}s)"
}
_failover_loop() {
    local threshold=$1
    local window=$2
    local timeout=$3
    local cooldown=$4
    local recovery=$5
    shift 5
    local test_urls=("$@")

    _failover_recovery_check "$recovery" "$timeout" "${test_urls[@]}" &
    local recovery_pid=$!
    trap "kill $recovery_pid 2>/dev/null; wait $recovery_pid 2>/dev/null" EXIT

    local error_pattern='i/o timeout|connection refused|dial .* error|context deadline exceeded|all proxies.*dead|no available proxy'
    local error_times=()
    local last_switch_time=0

    while IFS= read -r line; do
        echo "$line" | grep -iqE "$error_pattern" || continue

        local now
        now=$(date +%s)

        # 冷却期内忽略
        [ $((now - last_switch_time)) -lt "$cooldown" ] && continue

        # 记录错误时间，清理窗口外的旧记录
        error_times+=("$now")
        local new_times=()
        for t in "${error_times[@]}"; do
            [ $((now - t)) -le "$window" ] && new_times+=("$t")
        done
        error_times=("${new_times[@]}")

        local error_count=${#error_times[@]}
        [ "$error_count" -lt "$threshold" ] && continue

        # 达到阈值，用多个测试地址调用 API 确认所有代理都超时
        _failcat '⚠️' "检测到 ${error_count} 次错误 (${window}s 内)，验证代理状态..."
        if _test_all_proxies "$timeout" "${test_urls[@]}"; then
            _okcat '✅' "代理延迟测试通过，忽略错误（可能是目标站点本身故障）"
            error_times=()
            continue
        fi

        # 确认所有代理对所有测试地址都超时，执行切换
        local current_use
        current_use=$("$BIN_YQ" '.use // ""' "$CLASH_PROFILES_META")
        _failcat '⚠️' "订阅 [$current_use] 所有代理超时，开始切换..."
        _logging_sub "⚠️ 订阅 [$current_use] 所有代理超时"

        _do_failover_switch "$current_use" "$timeout" "${test_urls[@]}"
        error_times=()
        last_switch_time=$(date +%s)
    done < <(placeholder_follow_log)
}
_tcp_latency() {
    local host=$1 port=$2 timeout_s=$3
    local start end ms
    start=$(date +%s%N 2>/dev/null) || start=$(date +%s)000000000
    if timeout "$timeout_s" bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null ||
        nc -z -w "$timeout_s" "$host" "$port" 2>/dev/null; then
        end=$(date +%s%N 2>/dev/null) || end=$(date +%s)000000000
        ms=$(( (end - start) / 1000000 ))
        [ "$ms" -le 0 ] && ms=1
        echo "$ms"
        return 0
    fi
    return 1
}
_probe_config_best_latency() {
    local config=$1
    local timeout_ms=$2
    local timeout_s=$(( (timeout_ms / 1000) + 1 ))

    local endpoints
    endpoints=$("$BIN_YQ" '.proxies[] | .server + ":" + (.port | tostring)' "$config" 2>/dev/null | head -n 5)
    [ -z "$endpoints" ] && return 1

    local best_ms=999999 ep host port ms
    while IFS= read -r ep; do
        host="${ep%%:*}"
        port="${ep##*:}"
        [ -z "$host" ] || [ -z "$port" ] && continue
        ms=$(_tcp_latency "$host" "$port" "$timeout_s") || continue
        [ "$ms" -lt "$best_ms" ] && best_ms=$ms
    done <<<"$endpoints"
    [ "$best_ms" -eq 999999 ] && return 1
    echo "$best_ms"
    return 0
}
_get_current_best_delay() {
    local timeout=$1
    shift
    local test_urls=("$@")
    _detect_ext_addr
    local secret=$(_get_secret)
    local auth_header=""
    [ -n "$secret" ] && auth_header="Authorization: Bearer $secret"

    local proxies_json
    proxies_json=$(curl -s --noproxy "*" --max-time 5 \
        ${auth_header:+-H "$auth_header"} \
        "http://${EXT_IP}:${EXT_PORT}/proxies")
    [ -z "$proxies_json" ] && return 1

    local proxy_names
    proxy_names=$(echo "$proxies_json" | "$BIN_YQ" -p json '
        .proxies | to_entries | .[] |
        select(.value.type == "Shadowsocks" or .value.type == "VMess" or .value.type == "Trojan" or
               .value.type == "ShadowsocksR" or .value.type == "Hysteria" or .value.type == "Hysteria2" or
               .value.type == "VLESS" or .value.type == "WireGuard" or .value.type == "TUIC" or
               .value.type == "Snell" or .value.type == "Http" or .value.type == "Socks5") |
        .key
    ' 2>/dev/null)
    [ -z "$proxy_names" ] && return 1

    local best_delay=999999 name encoded_name delay_result delay url
    while IFS= read -r name; do
        encoded_name=$(printf '%s' "$name" | sed 's/ /%20/g; s/\[/%5B/g; s/\]/%5D/g')
        for url in "${test_urls[@]}"; do
            delay_result=$(curl -s --noproxy "*" --max-time $(( (timeout / 1000) + 2 )) \
                ${auth_header:+-H "$auth_header"} \
                "http://${EXT_IP}:${EXT_PORT}/proxies/${encoded_name}/delay?timeout=${timeout}&url=${url}")
            delay=$(echo "$delay_result" | "$BIN_YQ" -p json '.delay // 0' 2>/dev/null)
            [ -n "$delay" ] && [ "$delay" -gt 0 ] 2>/dev/null && [ "$delay" -lt "$best_delay" ] && best_delay=$delay
        done
    done <<<"$proxy_names"
    [ "$best_delay" -eq 999999 ] && return 1
    echo "$best_delay"
    return 0
}
_failover_recovery_check() {
    local interval=$1
    local timeout=$2
    shift 2
    local test_urls=("$@")

    while true; do
        sleep "$interval"

        local current_use best_id
        current_use=$("$BIN_YQ" '.use // ""' "$CLASH_PROFILES_META")
        best_id=$(_get_sorted_profile_ids | head -n1)

        [ -z "$best_id" ] && continue
        [ "$current_use" = "$best_id" ] && continue

        # 第一关：重新下载高优先级订阅配置，验证订阅源是否可达
        local best_url
        best_url=$(_get_url_by_id "$best_id")
        _download_config "$CLASH_CONFIG_TEMP" "$best_url"
        if ! _valid_config "$CLASH_CONFIG_TEMP"; then
            /usr/bin/rm -f "$CLASH_CONFIG_TEMP" "${CLASH_CONFIG_TEMP}.raw"
            _failcat '🔙' "高优先级订阅 [$best_id] 仍无法下载，保持 [$current_use]"
            continue
        fi

        # 第二关：TCP 探活并测延迟
        local candidate_ms
        candidate_ms=$(_probe_config_best_latency "$CLASH_CONFIG_TEMP" "$timeout")
        if [ -z "$candidate_ms" ]; then
            /usr/bin/rm -f "$CLASH_CONFIG_TEMP" "${CLASH_CONFIG_TEMP}.raw"
            _failcat '🔙' "高优先级订阅 [$best_id] 代理节点不可达，保持 [$current_use]"
            continue
        fi

        # 第三关：与当前代理延迟对比，候选更低才切换
        local current_ms
        current_ms=$(_get_current_best_delay "$timeout" "${test_urls[@]}") || current_ms=999999
        if [ "$candidate_ms" -ge "$current_ms" ]; then
            /usr/bin/rm -f "$CLASH_CONFIG_TEMP" "${CLASH_CONFIG_TEMP}.raw"
            _failcat '🔙' "高优先级订阅 [$best_id] 延迟 ${candidate_ms}ms >= 当前 ${current_ms}ms，保持 [$current_use]"
            continue
        fi

        local _fp
        _fp=$(_get_path_by_id "$best_id")
        mv "$CLASH_CONFIG_TEMP" "$_fp"

        # 全部通过，执行切换
        clashsub use "$best_id" >/dev/null 2>&1
        _okcat '🔙' "高优先级订阅 [$best_id] 已恢复 (${candidate_ms}ms < ${current_ms}ms)，切换回"
        _logging_sub "🔙 回切：高优先级订阅 [$best_id] 已恢复 (${candidate_ms}ms < ${current_ms}ms)，从 [$current_use] 切换回"
    done
}
_do_failover_switch() {
    local current_use=$1
    local timeout=$2
    shift 2
    local test_urls=("$@")

    local sorted_ids next_id found_current=false switched=false
    sorted_ids=$(_get_sorted_profile_ids)

    # 从当前订阅之后按优先级查找下一个可用订阅
    while IFS= read -r next_id; do
        [ "$next_id" = "$current_use" ] && { found_current=true; continue; }
        [ "$found_current" = true ] && {
            local _fp _url
            _fp=$(_get_path_by_id "$next_id")
            if [ ! -f "$_fp" ]; then
                _failcat '⚠️' "订阅 [$next_id] 无配置文件，尝试下载..."
                _url=$(_get_url_by_id "$next_id")
                _download_config "$CLASH_CONFIG_TEMP" "$_url"
                if _valid_config "$CLASH_CONFIG_TEMP"; then
                    mv "$CLASH_CONFIG_TEMP" "$_fp"
                else
                    /usr/bin/rm -f "$CLASH_CONFIG_TEMP" "${CLASH_CONFIG_TEMP}.raw"
                    _failcat '⏭️' "订阅 [$next_id] 下载失败，跳过"
                    continue
                fi
            fi
            _okcat '🔄' "尝试切换到订阅 [$next_id]..."
            clashsub use "$next_id" >/dev/null 2>&1
            sleep 2
            if _test_all_proxies "$timeout" "${test_urls[@]}"; then
                _okcat '✅' "订阅 [$next_id] 代理可用，切换成功"
                _logging_sub "✅ 故障转移：切换到订阅 [$next_id] 成功"
                switched=true
                break
            else
                _failcat '❌' "订阅 [$next_id] 代理也超时，继续尝试..."
                _logging_sub "❌ 订阅 [$next_id] 代理超时"
            fi
        }
    done <<<"$sorted_ids"

    # 如果后面的都不行，从头开始尝试（循环）
    [ "$switched" = false ] && {
        while IFS= read -r next_id; do
            [ "$next_id" = "$current_use" ] && break
            local _fp _url
            _fp=$(_get_path_by_id "$next_id")
            if [ ! -f "$_fp" ]; then
                _failcat '⚠️' "订阅 [$next_id] 无配置文件，尝试下载..."
                _url=$(_get_url_by_id "$next_id")
                _download_config "$CLASH_CONFIG_TEMP" "$_url"
                if _valid_config "$CLASH_CONFIG_TEMP"; then
                    mv "$CLASH_CONFIG_TEMP" "$_fp"
                else
                    /usr/bin/rm -f "$CLASH_CONFIG_TEMP" "${CLASH_CONFIG_TEMP}.raw"
                    _failcat '⏭️' "订阅 [$next_id] 下载失败，跳过"
                    continue
                fi
            fi
            _okcat '🔄' "尝试切换到订阅 [$next_id]..."
            clashsub use "$next_id" >/dev/null 2>&1
            sleep 2
            if _test_all_proxies "$timeout" "${test_urls[@]}"; then
                _okcat '✅' "订阅 [$next_id] 代理可用，切换成功"
                _logging_sub "✅ 故障转移：切换到订阅 [$next_id] 成功"
                switched=true
                break
            else
                _failcat '❌' "订阅 [$next_id] 代理也超时，继续尝试..."
                _logging_sub "❌ 订阅 [$next_id] 代理超时"
            fi
        done <<<"$sorted_ids"
    }

    [ "$switched" = false ] && {
        _failcat '🚨' "所有订阅代理均超时，等待下次错误触发重试..."
        _logging_sub "🚨 所有订阅代理均超时"
    }
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
