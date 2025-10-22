#!/usr/bin/env bash

# shellcheck disable=SC2034
# shellcheck disable=SC2155
# shellcheck disable=SC1091

. "$(dirname "$(dirname "$SCRIPT_DIR")")/.env"
[ -n "$SUDO_USER" ] && {
    home=$(awk -F: -v user="$SUDO_USER" '$1==user{print $6}' /etc/passwd)
    CLASH_BASE_DIR=${CLASH_BASE_DIR/\/root/$home}
}
SCRIPT_BASE_DIR='script'
SCRIPT_INIT_DIR="${SCRIPT_BASE_DIR}/init"
SCRIPT_CMD_DIR="${SCRIPT_BASE_DIR}/cmd"
SCRIPT_FISH="${SCRIPT_CMD_DIR}/clashctl.fish"

RESOURCES_BASE_DIR='resources'
RESOURCES_CONFIG="${RESOURCES_BASE_DIR}/config.yaml"
RESOURCES_CONFIG_MIXIN="${RESOURCES_BASE_DIR}/mixin.yaml"

CLASH_RESOURCES_DIR="${CLASH_BASE_DIR}/$RESOURCES_BASE_DIR"
CLASH_CMD_DIR="${CLASH_BASE_DIR}/$SCRIPT_CMD_DIR"
CLASH_CONFIG_RAW="${CLASH_BASE_DIR}/$RESOURCES_CONFIG"
CLASH_CONFIG_RAW_BAK="${CLASH_CONFIG_RAW}.bak"
CLASH_CONFIG_MIXIN="${CLASH_BASE_DIR}/$RESOURCES_CONFIG_MIXIN"
CLASH_CONFIG_RUNTIME="${CLASH_RESOURCES_DIR}/runtime.yaml"
CLASH_UPDATE_LOG="${CLASH_RESOURCES_DIR}/clashupdate.log"

BIN_SUBCONVERTER_PORT=25500
$placeholder_bin

[ -n "$BASH_VERSION" ] && {
    EXEC_SHELL=bash
}
[ -n "$ZSH_VERSION" ] && {
    EXEC_SHELL=zsh
}
[ -n "$fish_version" ] && {
    EXEC_SHELL=fish
}

_set_env() {
    local key=$1
    local value=$2
    local env_path="${CLASH_BASE_DIR}/.env"

    grep -qE "^${key}=" "$env_path" && {
        value=${value//&/\\&}
        sed -i "s|^${key}=.*|${key}=${value}|" "$env_path"
        return $?
    }
    echo "${key}=${value}" >>"$env_path"
}

_get_random_port() {
    local randomPort=$(shuf -i 1024-65535 -n 1)
    ! _is_bind "$randomPort" && { echo "$randomPort" && return; }
    _get_random_port
}
_format_port() {
    printf %-5d "$1"
}
function _get_proxy_port() {
    local mixed_port=$("$BIN_YQ" '.mixed-port // ""' "$CLASH_CONFIG_RUNTIME")
    MIXED_PORT=${mixed_port:-7890}

    _is_already_in_use "$MIXED_PORT" "$KERNEL_NAME" && {
        local newPort=$(_get_random_port)
        local msg="端口占用：$(_format_port "$MIXED_PORT") 🎲 随机分配：$newPort"
        "$BIN_YQ" -i ".mixed-port = $newPort" "$CLASH_CONFIG_RUNTIME"
        MIXED_PORT=$newPort
        _failcat '🎯' "$msg"
    }
}

function _get_ui_port() {
    local ext_addr=$("$BIN_YQ" '.external-controller // ""' "$CLASH_CONFIG_RUNTIME")
    local ext_port=${ext_addr##*:}
    UI_PORT=${ext_port:-9090}

    _is_already_in_use "$UI_PORT" "$KERNEL_NAME" && {
        local newPort=$(_get_random_port)
        local msg="端口占用：$(_format_port "$UI_PORT") 🎲 随机分配：$newPort"
        "$BIN_YQ" -i ".external-controller = \"0.0.0.0:$newPort\"" "$CLASH_CONFIG_RUNTIME"
        UI_PORT=$newPort
        _failcat '🎯' "$msg"
    }
}

function _get_subconverter_port() {
    _is_already_in_use $BIN_SUBCONVERTER_PORT 'subconverter' && {
        local newPort=$(_get_random_port)
        _failcat '🎯' "端口占用：$(_format_port "$BIN_SUBCONVERTER_PORT") 🎲 随机分配：$newPort"
        "$BIN_YQ" -i ".server.port = $newPort" "$BIN_SUBCONVERTER_CONFIG" 2>/dev/null
        BIN_SUBCONVERTER_PORT=$newPort
    }
}

_get_color() {
    local hex="${1#\#}"
    local r=$((16#${hex:0:2}))
    local g=$((16#${hex:2:2}))
    local b=$((16#${hex:4:2}))
    printf "\e[38;2;%d;%d;%dm" "$r" "$g" "$b"
}
_get_color_msg() {
    local color=$(_get_color "$1")
    local msg=$2
    local reset="\033[0m"
    printf "%b%s%b\n" "$color" "$msg" "$reset"
}

_get_random_val() {
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 6
}

function _okcat() {
    local color=#c8d6e5
    local emoji=😼
    [ $# -gt 1 ] && emoji=$1 && shift
    local msg="${emoji} $1"
    _get_color_msg "$color" "$msg" && return 0
}

function _failcat() {
    local color=#fd79a8
    local emoji=😾
    [ $# -gt 1 ] && emoji=$1 && shift
    local msg="${emoji} $1"
    _get_color_msg "$color" "$msg" >&2 && return 1
}

function _quit() {
    _has_root && command -v sudo >&/dev/null && {
        local user=root
        [ -n "$SUDO_USER" ] && user=$SUDO_USER
        exec sudo -u "$user" -- "$EXEC_SHELL" -i
    }
    exec "$EXEC_SHELL" -i
}

function _error_quit() {
    [ $# -gt 0 ] && {
        local color=#f92f60
        local emoji=📢
        [ $# -gt 1 ] && emoji=$1 && shift
        local msg="${emoji} $1"
        _get_color_msg "$color" "$msg"
    }
    exec $EXEC_SHELL -i
}

_is_bind() {
    local port=$1
    { ss -lnptu 2>/dev/null || netstat -lnptu; } | grep ":${port}\b"
}

_is_already_in_use() {
    local port=$1
    local progress=$2
    _is_bind "$port" >&/dev/null && {
        _is_bind "$port" | grep -qs "$progress" && return 1
        [ -n "$CONTAINER_TYPE" ] && sudo docker ps --format '{{.Names}} {{.Ports}}' | grep "$port" | grep -qs "$progress" && return 1
        return 0
    }
    return 1
}

function _has_root() {
    [ "$(id -u)" -eq 0 ]
}

# function _is_root() {
#     [ "$(id -un)" = "root" ]
# }

# function _is_sudo() {
#     [ -n "$SUDO_USER" ]
# }

function _valid_config() {
    [ -e "$1" ] && [ "$(wc -l <"$1")" -gt 1 ] && {
        local msg
        msg=$(eval "$valid_config_cmd") || {
            eval "$valid_config_cmd"
            echo "$msg" | grep -qs "unsupport proxy type" && {
                local proxy_type=$(awk -F': ' '{print $3}' <<<"$msg" | awk '{print $1}')
                _error_quit "订阅中包含不支持的代理协议：${proxy_type}，请安装使用 mihomo 内核"
            }
        }
    }
}

_download_raw_config() {
    local dest=$1
    local url=$2
    local agent='clash-verge/v2.0.4'

    curl \
        --silent \
        --show-error \
        --insecure \
        --connect-timeout 4 \
        --retry 1 \
        --user-agent "$agent" \
        --output "$dest" \
        "$url" ||
        wget \
            --no-verbose \
            --no-check-certificate \
            --timeout 3 \
            --tries 1 \
            --user-agent "$agent" \
            --output-document "$dest" \
            "$url"
}
_download_convert_config() {
    local dest=$1
    local url=$2
    _start_convert
    local convert_url=$(
        target='clash'
        base_url="http://127.0.0.1:${BIN_SUBCONVERTER_PORT}/sub"
        curl \
            --get \
            --silent \
            --output /dev/null \
            --data-urlencode "target=$target" \
            --data-urlencode "url=$url" \
            --write-out '%{url_effective}' \
            "$base_url"
    )
    _download_raw_config "$dest" "$convert_url"
    _stop_convert
}
function _download_config() {
    local dest=$1
    local url=$2
    [ "${url:0:4}" = 'file' ] && return 0
    _download_raw_config "$dest" "$url" || return 1
    _okcat '🍃' '下载成功：内核验证配置...'
    _valid_config "$dest" || {
        _failcat '🍂' "验证失败：尝试订阅转换..."
        _download_convert_config "$dest" "$url" || _failcat '🍂' "转换失败：请检查日志：$BIN_SUBCONVERTER_LOG"
    }
}

_start_convert() {
    _get_subconverter_port
    local test_cmd="curl http://localhost:${BIN_SUBCONVERTER_PORT}/version"
    $test_cmd >&/dev/null && return 0
    eval "$BIN_SUBCONVERTER_START >/dev/null"
    local start=$(date +%s)
    while ! $test_cmd >&/dev/null; do
        sleep 0.5s
        local now=$(date +%s)
        [ $((now - start)) -gt 2 ] && _error_quit "订阅转换服务未启动，请检查日志：$BIN_SUBCONVERTER_LOG"
    done
}
_stop_convert() {
    $BIN_SUBCONVERTER_STOP >/dev/null
}
