#!/usr/bin/env bash

# shellcheck disable=SC2034
CLASH_RESOURCES_DIR="${CLASHCTL_HOME}/resources"
CLASH_CONFIG_BASE="${CLASH_RESOURCES_DIR}/config.yaml"
CLASH_CONFIG_MIXIN="${CLASH_RESOURCES_DIR}/mixin.yaml"
CLASH_CONFIG_RUNTIME="${CLASH_RESOURCES_DIR}/runtime.yaml"
CLASH_CONFIG_TEMP="${CLASH_RESOURCES_DIR}/temp.yaml"

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

CLASHCTL_CRON_TAG="# clashctl-auto-update"

_is_macos() {
    [ "$(uname -s)" = "Darwin" ]
}

_is_port_used() {
    if _is_macos; then
        { lsof -nP -iTCP:"$1" -iUDP:"$1" 2>/dev/null || netstat -an 2>/dev/null; } | grep -qs "[.:]$1[[:space:]]"
        return
    fi
    { ss -tunlp 2>/dev/null || netstat -tunlp 2>/dev/null; } | grep -qs "$1"
}

_is_root() {
    [ "$(id -u)" -eq 0 ]
}

_get_random_port() {
    local fail_count=0
    while [ "$fail_count" -lt 100 ]; do
        local random_port
        if command -v shuf >&/dev/null; then
            random_port=$(shuf -i 1024-65535 -n 1)
        elif command -v jot >&/dev/null; then
            random_port=$(jot -r 1 1024 65535)
        else
            random_port=$((RANDOM % 64512 + 1024))
        fi
        ! _is_port_used "$random_port" && {
            printf '%s\n' "$random_port"
            return 0
        }
        fail_count=$((fail_count + 1))
    done
    _errorcat "未找到可用的代理端口"
}

_get_local_ip() {
    local local_ip
    if _is_macos; then
        local iface
        iface=$(route get 1.1.1.1 2>/dev/null | awk '/interface:/{print $2}')
        [ -n "$iface" ] && local_ip=$(ipconfig getifaddr "$iface" 2>/dev/null)
    else
        local_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
        [ -z "$local_ip" ] && local_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    printf '%s\n' "$local_ip"
}

_get_random_val() {
    LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 6
}

_color_log() {
    local color="$1"
    local msg="$2"

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

_set_env() {
    local key=$1
    local value=$2
    local env_path="${CLASHCTL_HOME}/.env"

    grep -qE "^${key}=" "$env_path" && {
        value=${value//\\/\\\\}
        value=${value//&/\\&}
        value=${value//|/\\|}
        _sed_inplace "s|^${key}=.*|${key}=${value}|" "$env_path"
        return $?
    }
    printf '%s=%s\n' "$key" "$value" >>"$env_path"
}

_sed_inplace() {
    if _is_macos; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

_install_file() {
    local mode=$1 src=$2 target=$3
    /usr/bin/install -d "$(dirname -- "$target")"
    /usr/bin/install -m "$mode" "$src" "$target"
}
