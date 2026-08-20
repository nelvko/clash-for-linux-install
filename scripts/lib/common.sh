#!/usr/bin/env bash

# shellcheck disable=SC2034
CLASH_RESOURCES_DIR="${CLASHCTL_HOME}/resources"
CLASH_CONFIG_BASE="${CLASH_RESOURCES_DIR}/config.yaml"
CLASH_CONFIG_MIXIN="${CLASH_RESOURCES_DIR}/mixin.yaml"
CLASH_CONFIG_RUNTIME="${CLASH_RESOURCES_DIR}/runtime.yaml"
CLASH_CONFIG_TEMP="${CLASH_RESOURCES_DIR}/temp.yaml"
# 订阅下载/校验失败时保留的调试产物（稳定路径，便于排障）
CLASH_CONFIG_DEBUG="${CLASH_RESOURCES_DIR}/last-failed.yaml"
CLASH_CONFIG_DEBUG_RAW="${CLASH_RESOURCES_DIR}/last-failed.raw"

BIN_BASE_DIR="${CLASHCTL_HOME}/bin"
BIN_KERNEL="${BIN_BASE_DIR}/$CLASHCTL_KERNEL"
BIN_YQ="${BIN_BASE_DIR}/yq"
BIN_SUBCONVERTER_DIR="${BIN_BASE_DIR}/subconverter"
BIN_SUBCONVERTER="${BIN_SUBCONVERTER_DIR}/subconverter"
BIN_SUBCONVERTER_CONFIG="$BIN_SUBCONVERTER_DIR/pref.yml"
BIN_SUBCONVERTER_LOG="${BIN_SUBCONVERTER_DIR}/latest.log"

CLASH_PROFILES_DIR="${CLASH_RESOURCES_DIR}/profiles"
CLASH_PROFILES_META="${CLASH_RESOURCES_DIR}/profiles.yaml"
CLASH_PROFILES_LOG="${CLASH_RESOURCES_DIR}/profiles.log"
CLASH_PROFILES_LOCK="${CLASH_RESOURCES_DIR}/profiles.lock"

CLASHCTL_CRON_TAG="# clashctl-auto-update"

_is_port_used() {
    { ss -tunlp 2>/dev/null || netstat -tunlp 2>/dev/null; } | grep -qs "$1"
}

_is_root() {
    [ "$(id -u)" -eq 0 ]
}

_get_random_port() {
    local fail_count=0
    while [ "$fail_count" -lt 100 ]; do
        local random_port
        random_port=$(shuf -i 1024-65535 -n 1)
        ! _is_port_used "$random_port" && {
            printf '%s\n' "$random_port"
            return 0
        }
        fail_count=$((fail_count + 1))
    done
    _errorcat "未找到可用的代理端口"
}

_get_local_ip() {
    local local_ip iface
    # 取主路由表默认出口网卡的地址：不探测公网 IP（Tun 下 ip route get
    # 会命中策略路由返回 fake-ip 段地址），主表 default 不受 Tun 影响。
    iface=$(ip -4 route show default 2>/dev/null | awk 'NR==1{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
    [ -n "$iface" ] && local_ip=$(ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1)
    [ -z "$local_ip" ] && local_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    printf '%s\n' "$local_ip"
}

_get_random_val() {
    tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 6
}

_color_log() {
    local color="$1"
    local msg="$2"

    # 输出目标非终端（cron / 管道 / 重定向）时不加颜色码，避免污染日志与 cron 邮件。
    # fd1 已随调用方的 >&2 重定向，故此判断对 _okcat 与 _failcat/_errorcat 均成立。
    [ -t 1 ] || {
        printf '%s\n' "$msg"
        return
    }

    local hex="${color#\#}"
    local r=$((16#${hex:0:2}))
    local g=$((16#${hex:2:2}))
    local b=$((16#${hex:4:2}))

    local color_code="\033[38;2;${r};${g};${b}m"
    local reset_code="\033[0m"

    printf "%b%s%b\n" "$color_code" "$msg" "$reset_code"
}

_okcat() {
    local color=#c8d6e5
    local emoji=😼
    [ $# -gt 1 ] && emoji=$1 && shift
    local msg="${emoji} $1"
    _color_log "$color" "$msg"
    return 0
}

_failcat() {
    local color=#fd79a8
    local emoji=😾
    [ $# -gt 1 ] && emoji=$1 && shift
    local msg="${emoji} $1"
    _color_log "$color" "$msg" >&2
    return 1
}

_errorcat() {
    [ $# -gt 0 ] && {
        local color=#f92f60
        local emoji=📢
        [ $# -gt 1 ] && emoji=$1 && shift
        local msg="${emoji} $1"
        _color_log "$color" "$msg" >&2
    }
    return 1
}

# 估算字符串终端显示宽度：CJK/emoji 计 2 列，旗帜按对各计 1（合 2），
# VS16(FE0F) 把前一字符提升为宽。依赖 UTF-8 locale 下的逐字符索引。
_dispwidth() {
    local s=$1 w=0 i c cp
    for ((i = 0; i < ${#s}; i++)); do
        c=${s:i:1}
        printf -v cp '%d' "'$c"
        if ((cp == 0xFE0F)); then
            ((w += 1)) # 变体选择符：补足前一字符到宽
        elif ((cp >= 0x1100 && cp <= 0x115F)) ||
            ((cp >= 0x2E80 && cp <= 0xA4CF)) ||
            ((cp >= 0xAC00 && cp <= 0xD7A3)) ||
            ((cp >= 0xF900 && cp <= 0xFAFF)) ||
            ((cp >= 0xFE30 && cp <= 0xFE4F)) ||
            ((cp >= 0xFF00 && cp <= 0xFF60)) ||
            ((cp >= 0xFFE0 && cp <= 0xFFE6)) ||
            ((cp >= 0x1F300 && cp <= 0x1FAFF)) ||
            ((cp >= 0x20000 && cp <= 0x3FFFD)); then
            ((w += 2))
        else
            ((w += 1))
        fi
    done
    printf '%d' "$w"
}

# 按显示宽度右侧补空格，使字符串占满 target 列
_pad() {
    local s=$1 target=$2 w pad
    w=$(_dispwidth "$s")
    pad=$((target - w))
    ((pad < 0)) && pad=0
    printf '%s%*s' "$s" "$pad" ''
}

_set_env() {
    local key=$1
    local value=$2
    local env_path="${CLASHCTL_HOME}/.env"

    grep -qE "^${key}=" "$env_path" && {
        value=${value//\\/\\\\}
        value=${value//&/\\&}
        value=${value//|/\\|}
        sed -i "s|^${key}=.*|${key}=${value}|" "$env_path"
        return $?
    }
    printf '%s=%s\n' "$key" "$value" >>"$env_path"
}
