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
    --threshold <n>   触发检测的错误次数阈值（默认 3）
    --window <s>      错误计数的时间窗口秒数（默认 60）
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
# URL 编码节点名（用于拼接 controller API 路径）
_url_encode_name() {
    printf '%s' "$1" | sed 's/ /%20/g; s/\[/%5B/g; s/\]/%5D/g; s/#/%23/g'
}

# 解析 GLOBAL group 当前实际选中的“底层真实出口节点”。
# group 的 .now 可能仍指向另一个 group（嵌套），递归下钻直到落在一个真实节点上。
# 成功时把节点名打印到 stdout 并返回 0。
_get_active_node() {
    local secret=$1 max_depth=8
    local auth_header=""
    [ -n "$secret" ] && auth_header="Authorization: Bearer $secret"

    local cur="GLOBAL" depth=0 encoded info kind now
    while [ "$depth" -lt "$max_depth" ]; do
        encoded=$(_url_encode_name "$cur")
        info=$(curl -s --noproxy "*" --max-time 5 \
            ${auth_header:+-H "$auth_header"} \
            "http://${EXT_IP}:${EXT_PORT}/proxies/${encoded}")
        [ -z "$info" ] && return 1
        kind=$(echo "$info" | "$BIN_YQ" -p json '.type // ""' 2>/dev/null)
        # 选择器 / 自动测速类 group 才有 .now，否则 cur 本身就是真实节点
        case "$kind" in
        Selector | URLTest | Fallback | LoadBalance | Relay)
            now=$(echo "$info" | "$BIN_YQ" -p json '.now // ""' 2>/dev/null)
            [ -z "$now" ] && { echo "$cur"; return 0; }
            cur="$now"
            depth=$((depth + 1))
            ;;
        *)
            echo "$cur"
            return 0
            ;;
        esac
    done
    echo "$cur"
    return 0
}

# 对“指定节点”做真实 HTTP 连通性探测。
# 用法：_probe_node_url <node> <timeout_ms> <retries> <secret> <url>...
# 任一测试 URL 在任一轮重试中返回 delay>0 即判定可用：把最佳延迟打印到 stdout，返回 0。
# 全部失败返回 1。
_probe_node_url() {
    local node=$1 timeout=$2 retries=$3 secret=$4
    shift 4
    local test_urls=("$@")
    [ -z "$node" ] && return 1

    local auth_header=""
    [ -n "$secret" ] && auth_header="Authorization: Bearer $secret"
    local encoded_name
    encoded_name=$(_url_encode_name "$node")

    local attempt url delay_result delay best_delay=999999
    for ((attempt = 0; attempt < retries; attempt++)); do
        for url in "${test_urls[@]}"; do
            delay_result=$(curl -s --noproxy "*" --max-time $(( (timeout / 1000) + 2 )) \
                ${auth_header:+-H "$auth_header"} \
                "http://${EXT_IP}:${EXT_PORT}/proxies/${encoded_name}/delay?timeout=${timeout}&url=${url}")
            delay=$(echo "$delay_result" | "$BIN_YQ" -p json '.delay // 0' 2>/dev/null)
            if [ -n "$delay" ] && [ "$delay" -gt 0 ] 2>/dev/null; then
                [ "$delay" -lt "$best_delay" ] && best_delay=$delay
            fi
        done
        # 本轮已拿到可用延迟则无需继续重试
        [ "$best_delay" -ne 999999 ] && break
        [ $((attempt + 1)) -lt "$retries" ] && sleep 1
    done

    [ "$best_delay" -eq 999999 ] && return 1
    echo "$best_delay"
    return 0
}

# 探测“当前订阅实际正在使用的出口节点”是否真的可用（带重试）。
# 这是触发判断 / 切换验证 / 回切对比 三条线统一使用的健康判据：
# 始终测“真正在走流量的那个节点”，而不是“随便哪个节点能通”。
# 成功时把延迟打印到 stdout 并返回 0。
# 用法：_probe_active_node <timeout_ms> <retries> <url>...
_probe_active_node() {
    local timeout=$1 retries=$2
    shift 2
    local test_urls=("$@")
    _detect_ext_addr
    local secret
    secret=$(_get_secret)

    local node
    node=$(_get_active_node "$secret") || return 1
    [ -z "$node" ] && return 1

    _probe_node_url "$node" "$timeout" "$retries" "$secret" "${test_urls[@]}"
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
    # 先杀子进程树，再杀主进程
    pkill -TERM -P "$pid" 2>/dev/null
    kill "$pid" 2>/dev/null
    sleep 1
    pkill -KILL -P "$pid" 2>/dev/null
    kill -KILL "$pid" 2>/dev/null
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
  --threshold <n>   触发检测的错误次数阈值（默认 3）
  --window <s>      错误计数的时间窗口秒数（默认 60）
  --timeout <ms>    代理超时毫秒数（默认 3000）
  --cooldown <s>    切换后的冷却秒数（默认 60）
  --recovery <s>    高优先级订阅回切检测间隔秒数（默认 300）
  --test-url <url>  测试地址，可多次指定（默认 gstatic + cloudflare + huawei）
EOF
        ;;
    esac
}
_failover_start() {
    local threshold=3
    local window=60
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

    # 保存启动参数，供 update.sh 重启时恢复
    local _args="--threshold $threshold --window $window --timeout $timeout --cooldown $cooldown --recovery $recovery"
    for _u in "${test_urls[@]}"; do _args+=" --test-url $_u"; done
    echo "$_args" >"$CLASH_FAILOVER_ARGS"

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

    # 仅匹配“反映链路整体超时/不可达”的内核错误；
    # 不再匹配 connection refused / dial error 等单连接、单站点级别的噪声，
    # 这些噪声并不代表当前出口节点失效，曾导致大量误切。
    local error_pattern='i/o timeout|context deadline exceeded|all proxies.*(dead|timeout)|no available proxy|net/http: TLS handshake timeout'
    # 确认故障时对“当前实际出口”重复探测的轮数：连续全部失败才判定真故障
    local confirm_retries=3
    local error_times=()
    local last_switch_time=0
    local last_test_pass_time=0
    local test_pass_cooldown=180

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

        # 测试通过冷却期内忽略
        if [ $((now - last_test_pass_time)) -lt "$test_pass_cooldown" ]; then
            error_times=()
            continue
        fi

        # 达到阈值后，主动探测“当前实际出口节点”是否真的不可用。
        # 用重试做多数表决，避免单次网络抖动 / controller 繁忙造成误判。
        _failcat '⚠️' "检测到 ${error_count} 次错误 (${window}s 内)，探测当前出口节点..."
        local active_delay
        if active_delay=$(_probe_active_node "$timeout" "$confirm_retries" "${test_urls[@]}"); then
            _okcat '✅' "当前出口节点可用 (${active_delay}ms)，忽略错误（可能是目标站点本身故障，${test_pass_cooldown}s 内不再检测）"
            error_times=()
            last_test_pass_time=$(date +%s)
            continue
        fi

        # 连续 confirm_retries 轮均失败，确认当前出口真故障，执行切换
        local current_use
        current_use=$("$BIN_YQ" '.use // ""' "$CLASH_PROFILES_META")
        _failcat '⚠️' "订阅 [$current_use] 当前出口节点连续 ${confirm_retries} 次探测失败，开始切换..."
        _logging_sub "⚠️ 订阅 [$current_use] 当前出口节点不可用"

        _do_failover_switch "$current_use" "$timeout" "${test_urls[@]}"
        error_times=()
        last_switch_time=$(date +%s)
    done < <(placeholder_follow_log)
}
# 等待内核加载新配置后“真正就绪”：轮询当前出口节点直到能解析出 .now。
# 避免旧逻辑里固定 sleep 2 在内核尚未加载完成时就去验证导致的误判。
# 返回 0 表示就绪。
_wait_kernel_ready() {
    local secret=$1 max_wait=${2:-10}
    local i node
    for ((i = 0; i < max_wait; i++)); do
        node=$(_get_active_node "$secret")
        [ -n "$node" ] && return 0
        sleep 1
    done
    return 1
}

# 试探性切换到指定订阅并用“真实出口探测”验证。
# 成功（出口节点真实可用）时把延迟打印到 stdout，返回 0；失败返回 1（调用方负责回滚）。
# 用法：_switch_and_verify <profile_id> <timeout_ms> <retries> <url>...
_switch_and_verify() {
    local target_id=$1 timeout=$2 retries=$3
    shift 3
    local test_urls=("$@")

    clashsub use "$target_id" >/dev/null 2>&1
    _detect_ext_addr
    local secret
    secret=$(_get_secret)
    _wait_kernel_ready "$secret" 10 || return 1

    _probe_active_node "$timeout" "$retries" "${test_urls[@]}"
}
# 后台安全下载验证：不调用 _download_config/_valid_config，避免 _error_quit 杀死后台进程
_safe_download_and_validate() {
    local dest=$1 url=$2
    _download_raw_config "$dest" "$url" >/dev/null 2>&1 || return 1
    [ -f "$dest" ] && [ "$(wc -l < "$dest" 2>/dev/null)" -gt 1 ] \
        && "$BIN_KERNEL" -d "$(dirname "$dest")" -f "$dest" -t >/dev/null 2>&1
}
_failover_recovery_check() {
    local interval=$1
    local timeout=$2
    shift 2
    local test_urls=("$@")
    local verify_retries=2

    while true; do
        sleep "$interval"

        local current_use best_id
        current_use=$("$BIN_YQ" '.use // ""' "$CLASH_PROFILES_META")
        best_id=$(_get_sorted_profile_ids | head -n1)

        [ -z "$best_id" ] && continue
        # 已经在用最高优先级订阅 → 无需回切
        [ "$current_use" = "$best_id" ] && continue

        # 第一关：回切的前提是“当前订阅出口确实不可用”。
        # 故障转移的语义是：只有当前节点不能用才换。若当前出口仍然可用，
        # 即使高优先级订阅延迟更低也绝不切换——延迟高低不是切换依据，
        # 否则会出现“节点明明能用却被反复切换”的抖动。
        if _probe_active_node "$timeout" "$verify_retries" "${test_urls[@]}" >/dev/null 2>&1; then
            continue
        fi

        # 走到这里说明当前订阅出口已不可用，尝试回切到高优先级订阅。
        # 第二关：尝试下载高优先级订阅最新配置，失败则回退到本地文件
        local best_url downloaded=false
        local _fp
        _fp=$(_get_path_by_id "$best_id")
        best_url=$(_get_url_by_id "$best_id")
        if _safe_download_and_validate "$CLASH_CONFIG_TEMP" "$best_url"; then
            downloaded=true
        else
            /usr/bin/rm -f "$CLASH_CONFIG_TEMP" "${CLASH_CONFIG_TEMP}.raw"
            if [ ! -f "$_fp" ]; then
                _failcat '🔙' "高优先级订阅 [$best_id] 无法下载且无本地配置，保持 [$current_use]"
                continue
            fi
        fi

        # 第三关：试探性切换到高优先级订阅，用与触发线一致的“真实出口探测”验证。
        # 只判断“是否可用”，不比较延迟。可用则切回，不可用则回滚。
        [ "$downloaded" = true ] && mv "$CLASH_CONFIG_TEMP" "$_fp"

        if _switch_and_verify "$best_id" "$timeout" "$verify_retries" "${test_urls[@]}" >/dev/null 2>&1; then
            _okcat '🔙' "高优先级订阅 [$best_id] 已恢复可用，切换回（原 [$current_use] 出口不可用）"
            _logging_sub "🔙 回切：高优先级订阅 [$best_id] 已恢复可用，从 [$current_use] 切换回"
        else
            # 高优先级订阅仍不可用 → 回滚到原订阅，维持现状
            _switch_and_verify "$current_use" "$timeout" "$verify_retries" "${test_urls[@]}" >/dev/null 2>&1 \
                || clashsub use "$current_use" >/dev/null 2>&1
            _failcat '🔙' "高优先级订阅 [$best_id] 仍不可用，保持 [$current_use]"
        fi
    done
}
# 尝试切换到指定订阅并验证其“实际出口节点”真实可用。
# 成功返回 0，失败返回 1。供 _do_failover_switch 复用，消除重复逻辑。
_try_switch_to() {
    local next_id=$1 timeout=$2 retries=$3
    shift 3
    local test_urls=("$@")

    local _fp _url
    _fp=$(_get_path_by_id "$next_id")
    if [ ! -f "$_fp" ]; then
        _failcat '⚠️' "订阅 [$next_id] 无配置文件，尝试下载..."
        _url=$(_get_url_by_id "$next_id")
        if _safe_download_and_validate "$CLASH_CONFIG_TEMP" "$_url"; then
            mv "$CLASH_CONFIG_TEMP" "$_fp"
        else
            /usr/bin/rm -f "$CLASH_CONFIG_TEMP" "${CLASH_CONFIG_TEMP}.raw"
            _failcat '⏭️' "订阅 [$next_id] 下载失败，跳过"
            return 1
        fi
    fi

    _okcat '🔄' "尝试切换到订阅 [$next_id]..."
    # 切换后等待内核就绪，再验证“真正在用的出口节点”是否可用（带重试），
    # 而不是旧逻辑里 sleep 2 + 任意节点可用即算成功。
    local delay
    if delay=$(_switch_and_verify "$next_id" "$timeout" "$retries" "${test_urls[@]}"); then
        _okcat '✅' "订阅 [$next_id] 出口节点可用 (${delay}ms)，切换成功"
        _logging_sub "✅ 故障转移：切换到订阅 [$next_id] 成功 (${delay}ms)"
        return 0
    fi
    _failcat '❌' "订阅 [$next_id] 出口节点不可用，继续尝试..."
    _logging_sub "❌ 订阅 [$next_id] 出口节点不可用"
    return 1
}
_do_failover_switch() {
    local current_use=$1
    local timeout=$2
    shift 2
    local test_urls=("$@")
    local verify_retries=2

    local sorted_ids next_id found_current=false switched=false
    sorted_ids=$(_get_sorted_profile_ids)

    # 第一轮：从当前订阅之后按优先级依次尝试
    while IFS= read -r next_id; do
        [ "$next_id" = "$current_use" ] && { found_current=true; continue; }
        [ "$found_current" = true ] || continue
        if _try_switch_to "$next_id" "$timeout" "$verify_retries" "${test_urls[@]}"; then
            switched=true
            break
        fi
    done <<<"$sorted_ids"

    # 第二轮：若后面的都不行，从头回绕到当前订阅之前的候选
    [ "$switched" = false ] && {
        while IFS= read -r next_id; do
            [ "$next_id" = "$current_use" ] && break
            if _try_switch_to "$next_id" "$timeout" "$verify_retries" "${test_urls[@]}"; then
                switched=true
                break
            fi
        done <<<"$sorted_ids"
    }

    [ "$switched" = false ] && {
        _failcat '🚨' "所有订阅出口节点均不可用，等待下次错误触发重试..."
        _logging_sub "🚨 所有订阅出口节点均不可用"
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
