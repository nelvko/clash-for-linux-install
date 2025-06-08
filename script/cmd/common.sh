#!/usr/bin/env bash

# shellcheck disable=SC2034
# shellcheck disable=SC2155

URL_GH_PROXY='https://gh-proxy.com/'
export URL_CR_PROXY='docker.gh-proxy.com/'
URL_CLASH_UI="http://board.zash.run.place"

SCRIPT_BASE_DIR='script'
SCRIPT_INIT_DIR="${SCRIPT_BASE_DIR}/init"
SCRIPT_CMD_DIR="${SCRIPT_BASE_DIR}/cmd"
SCRIPT_FISH="${SCRIPT_CMD_DIR}/clashctl.fish"

RESOURCES_BASE_DIR='resources'
RESOURCES_CONFIG="${RESOURCES_BASE_DIR}/config.yaml"
RESOURCES_CONFIG_MIXIN="${RESOURCES_BASE_DIR}/mixin.yaml"

CLASH_BASE_DIR='/opt/clash'
CLASH_RESOURCES_DIR="${CLASH_BASE_DIR}/$RESOURCES_BASE_DIR"
CLASH_CMD_DIR="${CLASH_BASE_DIR}/$SCRIPT_CMD_DIR"
CLASH_CONFIG_URL="${CLASH_RESOURCES_DIR}/url"
CLASH_CONFIG_RAW="${CLASH_BASE_DIR}/$RESOURCES_CONFIG"
CLASH_CONFIG_RAW_BAK="${CLASH_CONFIG_RAW}.bak"
CLASH_CONFIG_MIXIN="${CLASH_BASE_DIR}/$RESOURCES_CONFIG_MIXIN"
CLASH_CONFIG_RUNTIME="${CLASH_RESOURCES_DIR}/runtime.yaml"
CLASH_UPDATE_LOG="${CLASH_RESOURCES_DIR}/clashupdate.log"

BIN_BASE_DIR="${CLASH_BASE_DIR}/bin"
BIN_CLASH="${BIN_BASE_DIR}/clash"
BIN_MIHOMO="${BIN_BASE_DIR}/mihomo"
BIN_KERNEL="${BIN_BASE_DIR}/placeholder_bin_kernel"
KERNEL_NAME="placeholder_kernel_name"
BIN_YQ="${BIN_BASE_DIR}/yq"

[ -n "$BASH_VERSION" ] && {
    EXEC_SHELL=bash
}
[ -n "$ZSH_VERSION" ] && {
    EXEC_SHELL=zsh
}
[ -n "$fish_version" ] && {
    EXEC_SHELL=fish
}

yq1() {
    docker run --rm -i -u "$(id -u):$(id -u)" -v "${CLASH_BASE_DIR}":${CLASH_BASE_DIR} "${URL_CR_PROXY}"mikefarah/yq "$@"
}
BIN_YQ="yq1"

BIN_SUBCONVERTER_DIR="${BIN_BASE_DIR}/subconverter"
BIN_SUBCONVERTER_CONFIG="$BIN_SUBCONVERTER_DIR/pref.yml"
export BIN_SUBCONVERTER_PORT="25500"
export MIXED_PORT=7890
export UI_PORT=9090

# BIN_SUBCONVERTER="${BIN_SUBCONVERTER_DIR}/subconverter"
BIN_SUBCONVERTER="docker-compose -f ${CLASH_BASE_DIR}/docker-compose.yaml  up -d subconverter"
BIN_SUBCONVERTER="docker-compose -f docker-compose.yaml  up -d subconverter"
BIN_SUBCONVERTER_LOG="${BIN_SUBCONVERTER_DIR}/latest.log"

_get_random_port() {
    local randomPort=$(shuf -i 1024-65535 -n 1)
    ! _is_bind "$randomPort" && { echo "$randomPort" && return; }
    _get_random_port
}
_format_port() {
    printf %-5d "$1"
}
function _get_proxy_port() {
    local mixed_port=$("$BIN_YQ" '.mixed-port // ""' $CLASH_CONFIG_RUNTIME)
    MIXED_PORT=${mixed_port:-7890}

    _is_already_in_use "$MIXED_PORT" "$KERNEL_NAME" && {
        local newPort=$(_get_random_port)
        local msg="端口占用：$(_format_port "$MIXED_PORT") 🎲 随机分配：$newPort"
        "$BIN_YQ" -i ".mixed-port = $newPort" $CLASH_CONFIG_RUNTIME
        MIXED_PORT=$newPort
        _failcat '🎯' "$msg"
    }
}

function _get_ui_port() {
    local ext_addr=$("$BIN_YQ" '.external-controller // ""' $CLASH_CONFIG_RUNTIME)
    local ext_port=${ext_addr##*:}
    UI_PORT=${ext_port:-9090}

    _is_already_in_use "$UI_PORT" "$KERNEL_NAME" && {
        local newPort=$(_get_random_port)
        local msg="端口占用：$(_format_port "$UI_PORT") 🎲 随机分配：$newPort"
        "$BIN_YQ" -i ".external-controller = \"0.0.0.0:$newPort\"" $CLASH_CONFIG_RUNTIME
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
    local user=root
    [ -n "$SUDO_USER" ] && user=$SUDO_USER
    exec sudo -u "$user" -- "$EXEC_SHELL" -i
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
    { sudo ss -anptu 2>/dev/null || sudo netstat -anptu; } | grep ":${port}\b"
}

_is_already_in_use() {
    local port=$1
    local progress=$2
    _is_bind "$port" >&/dev/null && {
        _is_bind "$port" | grep -qs "$progress" && return 1
        docker ps --format '{{.Names}} {{.Ports}}' | grep "$port" | grep -qs "$progress" && return 1
        return 0
    }
    return 1
}

function _is_root() {
    [ "$(whoami)" = "root" ]
}

function _valid_config() {
    [ -e "$1" ] && [ "$(wc -l <"$1")" -gt 1 ] && {
        local cmd msg
        # cmd="$BIN_KERNEL -d $(dirname "$1") -f $1 -t"
        cmd="docker run --rm -v $1:/root/.config/mihomo/config.yaml:ro ${URL_CR_PROXY}metacubex/mihomo -t"
        msg=$(eval "$cmd") || {
            eval "$cmd"
            echo "$msg" | grep -qs "unsupport proxy type" && _error_quit "不支持的代理协议，请安装 mihomo 内核"
        }
    }
}

_download_raw_config() {
    local dest=$1
    local url=$2
    # local agent='clash-verge/v2.0.4'
    sudo curl \
        --silent \
        --show-error \
        --insecure \
        --connect-timeout 4 \
        --retry 1 \
        --output "$dest" \
        "$url" ||
        sudo wget \
            --no-verbose \
            --no-check-certificate \
            --timeout 3 \
            --tries 1 \
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
    # _stop_convert
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
    # 子shell运行，屏蔽kill时的输出
    # (sudo "$BIN_SUBCONVERTER" 2>&1 | sudo tee "$BIN_SUBCONVERTER_LOG" >/dev/null &)
    $BIN_SUBCONVERTER
    local start=$(date +%s)
    while ! curl "http://localhost:${BIN_SUBCONVERTER_PORT}/version" >&/dev/null; do
        sleep 0.5s
        local now=$(date +%s)
        [ $((now - start)) -gt 2 ] && _error_quit "订阅转换服务未启动，请检查日志：$BIN_SUBCONVERTER_LOG"
    done
}
_stop_convert() {
    # pkill -9 -f "$BIN_SUBCONVERTER" >&/dev/null
    docker stop subconverter >/dev/null
}
