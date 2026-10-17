#!/usr/bin/env bash

# shellcheck disable=SC1091  # 独立 source（测试）时补载依赖；经 clashctl.sh 加载时已存在。
declare -F _clashctl_run_in_bash >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../lib/shell.sh"

clashstatus() {
    [ "$#" -le 1 ] || { _ui_fail '用法: clashctl status [--verbose | --help]'; return 1; }
    case "${1:-}" in
    -h | --help) status_help; return ;;
    '' | --verbose) ;;
    *) _ui_fail '用法: clashctl status [--verbose | --help]'; return 1 ;;
    esac

    # 服务探测和格式化统一交给 Bash，保留当前终端环境。
    if ! _clashctl_in_bash; then
        _clashctl_run_in_bash clashstatus "$@"
        return
    fi

    local kernel_state state_label state_color rc pid='—' terminal_label
    local http_address socks_address kernel_label uptime_label='—' tun_label dashboard_url=''
    local version elapsed subscription_label
    if detect_service_manager; then
        kernel_state=$(service_state 2>/dev/null) || kernel_state=unknown
    else
        kernel_state=unknown
    fi
    case $kernel_state in
    running) state_label='运行中'; state_color=32; rc=0 ;;
    stopped) state_label='未运行'; state_color=90; rc=1 ;;
    starting) state_label='启动中'; state_color=33; rc=1 ;;
    stopping) state_label='停止中'; state_color=33; rc=1 ;;
    failed) state_label='异常停止'; state_color=31; rc=1 ;;
    *) state_label='检测失败'; state_color=31; rc=2 ;;
    esac
    case $kernel_state in
    running | starting | stopping)
        pid=$(service_main_pid 2>/dev/null) || pid='无法读取'
        case $pid in '' | *[!0-9]*) pid='无法读取' ;; esac
        ;;
    esac
    terminal_label='未启用'
    if [ -n "${http_proxy:-}${HTTP_PROXY:-}${https_proxy:-}${HTTPS_PROXY:-}${all_proxy:-}${ALL_PROXY:-}" ]; then
        terminal_label='已启用'
    fi
    kernel_label=${CLASHCTL_KERNEL:-mihomo}
    if [ ! -f "$BIN_KERNEL" ] || [ ! -x "$BIN_KERNEL" ]; then
        kernel_label+='（未安装）'
    elif version=$(_kernel_version 2>/dev/null); then
        kernel_label+=" $version"
    else
        kernel_label+='（版本未知）'
    fi
    case $kernel_state in
    running | starting | stopping)
        uptime_label='无法读取'
        if [[ $pid =~ ^[0-9]+$ ]] && elapsed=$(service_uptime "$pid" 2>/dev/null); then
            uptime_label=$(_status_format_uptime "$elapsed") || uptime_label='无法读取'
        fi
        ;;
    esac
    tun_label=$(_status_tun_label "$kernel_state" "$pid")
    subscription_label=$(_status_subscription_label)
    dashboard_url=$(_status_dashboard_url) || dashboard_url=''
    _status_proxy_addresses
    local verbose_pid=''
    if [ "${1:-}" = --verbose ]; then
        verbose_pid=$pid
    fi
    _status_render "$state_label" "$state_color" "$subscription_label" "$terminal_label" "$http_address" "$socks_address" \
        "$kernel_label" "$uptime_label" "$tun_label" "$dashboard_url" "$verbose_pid"
    return "$rc"
}

_status_format_uptime() {
    local seconds=$1 days hours minutes
    [[ $seconds =~ ^[0-9]+$ ]] && [ "${#seconds}" -le 12 ] || return 1
    seconds=$((10#$seconds))
    days=$((seconds / 86400))
    hours=$((seconds / 3600 % 24))
    minutes=$((seconds / 60 % 60))
    seconds=$((seconds % 60))
    if [ "$days" -gt 0 ]; then
        printf '%dd %02dh %02dm %02ds\n' "$days" "$hours" "$minutes" "$seconds"
    elif [ "$hours" -gt 0 ]; then
        printf '%dh %02dm %02ds\n' "$hours" "$minutes" "$seconds"
    elif [ "$minutes" -gt 0 ]; then
        printf '%dm %02ds\n' "$minutes" "$seconds"
    else
        printf '%ds\n' "$seconds"
    fi
}

_status_tun_label() {
    local kernel_state=$1 pid=$2 api_state='' enabled='' device='' link ownership=2 link_rc=0
    case $kernel_state in
    stopped | failed) printf '关闭\n'; return ;;
    running) ;;
    *) printf '无法检测\n'; return ;;
    esac
    if api_state=$(_tun_api_state 2>/dev/null); then
        IFS=$'\t' read -r enabled device <<<"$api_state"
        [ "$enabled" != false ] || { printf '关闭\n'; return; }
    fi
    if [ -z "$device" ]; then
        device=$("$BIN_YQ" '.tun.device // "Meta"' "$CLASH_CONFIG_RUNTIME" 2>/dev/null) || device=''
    fi
    [ -n "$device" ] || device=Meta
    # 网卡名和查询结果只作为终端文字显示，不接收控制字符。
    if [[ $device == *[[:cntrl:]]* ]] || ! command -v ip >/dev/null 2>&1; then
        printf '无法检测\n'
        return
    fi
    link=$(ip -o link show dev "$device" 2>/dev/null) || link_rc=$?
    if [ "$link_rc" -ne 0 ] || [[ ! $link =~ \<([^\>]*,)?UP(,[^\>]*)?\> ]]; then
        if [ "$enabled" = true ] && [ "$link_rc" -le 1 ]; then printf '关闭\n'; else printf '无法检测\n'; fi
        return
    fi
    if [[ $pid =~ ^[0-9]+$ ]]; then
        ownership=0
        _tun_pid_owns_device "$pid" "$device" 2>/dev/null || ownership=$?
    fi
    if [ "$ownership" -eq 0 ] ||
        { [ "$ownership" -eq 2 ] && ! _is_root && [ "$enabled" = true ] && [[ $link == *LOWER_UP* && $link != *NO-CARRIER* ]]; }; then
        printf '已启用（%s）\n' "$device"
    elif [ "$ownership" -eq 1 ] && [ "$enabled" = true ]; then
        printf '关闭\n'
    else
        printf '无法检测\n'
    fi
}

_status_dashboard_url() {
    local values controller ui_dir host port
    values=$("$BIN_YQ" -er 'select(tag == "!!map") |
        [.external-controller // "", .external-ui // ""] | @tsv' "$CLASH_CONFIG_RUNTIME" 2>/dev/null) || return 1
    values=${values//$'\t'/$'\x1f'}
    IFS=$'\x1f' read -r controller ui_dir <<<"$values"
    [ -n "$controller" ] && [ -n "$ui_dir" ] || return 1
    case $ui_dir in
    /*) ;;
    *) ui_dir="$CLASH_RESOURCES_DIR/$ui_dir" ;;
    esac
    [ -f "$ui_dir/index.html" ] || return 1
    [[ $controller == *:* ]] || return 1
    port=$(_status_proxy_port "${controller##*:}") || return 1
    host=$(_status_local_host "${controller%:*}") || return 1
    printf 'http://%s:%s/ui\n' "$host" "$port"
}

_status_subscription_label() {
    local subscription='未选择'
    if [ -e "$CLASH_PROFILES_META" ]; then
        subscription=$(_sub_current 2>/dev/null) || subscription='无法读取'
        [ -n "$subscription" ] || subscription='未选择'
        subscription=${subscription//[[:cntrl:]]/ }
    fi
    printf '%s\n' "$subscription"
}

# 仅从运行配置生成可复制的连接地址，不调整端口或修改配置。
# http_address/socks_address 由 clashstatus 的局部变量接收。
_status_proxy_addresses() {
    http_address='未配置'
    socks_address='未配置'
    [ -e "$CLASH_CONFIG_RUNTIME" ] || return 0

    local values mixed_port http_port socks_port bind_addr allow_lan host port auth_base64 auth='' auth_prefix=''
    if ! values=$("$BIN_YQ" -er 'select(tag == "!!map") |
        [.mixed-port // 0, .port // 0, .socks-port // 0,
         .bind-address // "*", .allow-lan // false,
         (.authentication[0] // "" | @base64)] | @tsv' "$CLASH_CONFIG_RUNTIME" 2>/dev/null); then
        http_address='无法读取'
        socks_address='无法读取'
        return 0
    fi
    # 非空白分隔符保留空字段；认证字段用 base64 避免换行、制表符干扰拆分。
    values=${values//$'\t'/$'\x1f'}
    IFS=$'\x1f' read -r mixed_port http_port socks_port bind_addr allow_lan auth_base64 <<<"$values"
    if [ -n "$auth_base64" ]; then
        if ! auth=$(printf '%s' "$auth_base64" | base64 --decode 2>/dev/null && printf '.'); then
            http_address='无法读取'
            socks_address='无法读取'
            return 0
        fi
        auth=${auth%.}
        if [ -n "$auth" ]; then
            case $auth in
            *:*) auth_prefix="$(_status_urlencode "${auth%%:*}"):$(_status_urlencode "${auth#*:}")@" ;;
            *) auth_prefix="$(_status_urlencode "$auth")@" ;;
            esac
        fi
    fi
    case $allow_lan in
    false) host=127.0.0.1 ;;
    true)
        if ! host=$(_status_local_host "$bind_addr"); then
            http_address='无法读取'
            socks_address='无法读取'
            return 0
        fi
        ;;
    *)
        http_address='无法读取'
        socks_address='无法读取'
        return 0
        ;;
    esac
    if port=$(_status_proxy_port "$http_port" "$mixed_port"); then
        http_address="http://${auth_prefix}${host}:${port}"
    fi
    if port=$(_status_proxy_port "$socks_port" "$mixed_port"); then
        socks_address="socks5h://${auth_prefix}${host}:${port}"
    fi
}

_status_local_host() {
    local host=$1
    case $host in
    '' | '*' | 0.0.0.0) host=127.0.0.1 ;;
    :: | '[::]') host='::1' ;;
    esac
    host=${host#\[}
    host=${host%\]}
    # 拒绝控制字符及 URL 中的凭据、路径，避免破坏终端布局。
    case $host in '' | *[!a-zA-Z0-9.:%_-]*) return 1 ;; esac
    case $host in *:*) host="[${host//%/%25}]" ;; esac
    printf '%s\n' "$host"
}

_status_proxy_port() {
    local port=${1:-0}
    [ "$port" != 0 ] || port=${2:-0}
    [[ $port =~ ^[0-9]+$ ]] && [ "${#port}" -le 5 ] || return 1
    ((10#$port > 0 && 10#$port <= 65535)) || return 1
    printf '%d\n' "$((10#$port))"
}

_status_urlencode() {
    local LC_ALL=C value=$1 encoded='' character code index
    for ((index = 0; index < ${#value}; index++)); do
        character=${value:index:1}
        case $character in
        [a-zA-Z0-9._~-]) encoded+=$character ;;
        *)
            printf -v code '%%%02X' "'$character"
            encoded+=$code
            ;;
        esac
    done
    printf '%s' "$encoded"
}

_status_render() {
    local state_label=$1 state_color=$2 subscription_label=$3 terminal_label=$4 http_address=$5 socks_address=$6
    local kernel_label=$7 uptime_label=$8 tun_label=$9 dashboard_url=${10} verbose_pid=${11:-}
    local -a labels=('内核' '管理方式' '状态' '运行时长' '已选订阅' '' '终端代理' 'TUN' '' '代理地址' 'HTTP(S)' 'SOCKS5')
    local -a values=("$kernel_label" "${service_manager:-未知}" "$state_label" "$uptime_label" "$subscription_label" '' "$terminal_label" "$tun_label" '' '' "$http_address" "$socks_address")
    if [ -n "$dashboard_url" ]; then
        labels+=('Web 面板')
        values+=("$dashboard_url")
    fi
    if [ -n "$verbose_pid" ]; then
        local log_location=${service_log_path:-无法读取}
        if declare -F service_log_location >/dev/null 2>&1; then
            log_location=$(service_log_location) || log_location='无法读取'
        else
            case ${service_manager:-} in
            systemd) log_location="journalctl -u ${CLASHCTL_KERNEL:-mihomo}" ;;
            systemd-user) log_location="journalctl --user -u ${CLASHCTL_KERNEL:-mihomo}" ;;
            esac
        fi
        labels+=('' 'PID' '主配置' '运行配置' '日志')
        values+=('' "$verbose_pid" "$CLASH_CONFIG_BASE" "$CLASH_CONFIG_RUNTIME" "$log_location")
    fi
    local index label value columns=${COLUMNS:-} size styled=0 color utf8=0
    case ${LC_ALL:-${LC_CTYPE:-${LANG:-}}} in *UTF-8* | *UTF8* | *utf-8* | *utf8*) utf8=1 ;; esac
    if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && [ "$utf8" -eq 1 ]; then
        case $columns in
        '' | *[!0-9]*)
            # 保存 stdout 的终端描述符，兼容 stdin 重定向及无控制终端的 PTY。
            {
                size=$(stty size <&3 2>/dev/null) || size='0 80'
            } 3<&1
            columns=${size##* }
            ;;
        esac
        # 窄终端使用纯文本；长值由终端自然折行，不截断地址。
        case $columns in '' | *[!0-9]*) columns=80 ;; esac
        [ "${#columns}" -le 5 ] || columns=80
        [ "$columns" -gt 0 ] || columns=80
        [ "$columns" -lt 40 ] || styled=1
    fi
    if [ "$styled" -eq 0 ]; then
        for ((index = 0; index < ${#labels[@]}; index++)); do
            label=${labels[index]}
            value=${values[index]}
            if [ -n "$value" ]; then
                printf '%s：%s\n' "$label" "$value"
            else
                printf '%s\n' "$label"
            fi
        done
        return 0
    fi

    local rule_width=48
    [ "$rule_width" -lt "$columns" ] || rule_width=$((columns - 1))
    printf '\n── '
    if _ui_color_enabled 1; then
        printf '\033[1mclashctl\033[0m'
    else
        printf 'clashctl'
    fi
    printf ' '
    _status_rule "$((rule_width - 12))"
    printf '\n\n'
    for ((index = 0; index < ${#labels[@]}; index++)); do
        label=${labels[index]}
        value=${values[index]}
        if [ -z "$label" ]; then
            printf '\n'
            continue
        fi
        if [ -z "$value" ]; then
            printf '  %s\n' "$label"
            continue
        fi
        printf '  %s  ' "$(_pad "$label" 8)"
        color=''
        case $label in
        状态) color=$state_color ;;
        终端代理)
            if [ "$terminal_label" = 已启用 ]; then color=32; else color=90; fi
            ;;
        TUN)
            case $tun_label in
            已启用*) color=32 ;;
            关闭) color=90 ;;
            *) color=33 ;;
            esac
            ;;
        esac
        if [ -n "$color" ] && _ui_color_enabled 1; then
            printf '\033[%sm%s\033[0m\n' "$color" "$value"
        else
            printf '%s\n' "$value"
        fi
    done
    printf '\n'
    _status_rule "$rule_width"
    printf '\n\n'
}

_status_rule() {
    local count=$1 index
    for ((index = 0; index < count; index++)); do printf '─'; done
}

status_help() {
    cat <<'EOF'

clashctl status - 查看内核、终端代理状态及代理地址

Usage:
  clashctl status [OPTIONS]

Options:
      --verbose  显示 PID、配置路径和日志位置
  -h, --help     显示帮助信息

交互终端使用标题和分组显示，管道或窄终端中使用纯文本。
包含内核版本、运行时长和实际 TUN 状态；已安装 Web 面板时显示地址。
代理地址来自运行配置，包含已配置的认证信息，可直接复制使用。
查询不会启动内核或修改配置。
退出码：0 内核运行中；1 内核未运行或正在启停；2 状态检测失败。

EOF
}
