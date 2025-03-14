#!/bin/bash
# shellcheck disable=SC2034
# shellcheck disable=SC2155
set +o noglob

URL_GH_PROXY='https://gh-proxy.com/'
URL_CLASH_UI="http://board.zash.run.place"

RESOURCES_BASE_DIR='./resources'
RESOURCES_CONFIG="${RESOURCES_BASE_DIR}/config.yaml"
RESOURCES_CONFIG_MIXIN="${RESOURCES_BASE_DIR}/mixin.yaml"

ZIP_BASE_DIR="${RESOURCES_BASE_DIR}/zip"
ZIP_CLASH="${ZIP_BASE_DIR}/clash*.gz"
ZIP_MIHOMO="${ZIP_BASE_DIR}/mihomo*.gz"
ZIP_YQ="${ZIP_BASE_DIR}/yq*.tar.gz"
ZIP_SUBCONVERTER="${ZIP_BASE_DIR}/subconverter*.tar.gz"
ZIP_UI="${ZIP_BASE_DIR}/yacd.tar.xz"

CLASH_BASE_DIR='/opt/clash'
CLASH_CONFIG_URL="${CLASH_BASE_DIR}/url"
CLASH_CONFIG_RAW="${CLASH_BASE_DIR}/$(basename $RESOURCES_CONFIG)"
CLASH_CONFIG_RAW_BAK="${CLASH_CONFIG_RAW}.bak"
CLASH_CONFIG_MIXIN="${CLASH_BASE_DIR}/$(basename $RESOURCES_CONFIG_MIXIN)"
CLASH_CONFIG_RUNTIME="${CLASH_BASE_DIR}/runtime.yaml"
CLASH_UPDATE_LOG="${CLASH_BASE_DIR}/clashupdate.log"

BIN_BASE_DIR="${CLASH_BASE_DIR}/bin"
BIN_CLASH="${BIN_BASE_DIR}/clash"
BIN_MIHOMO="${BIN_BASE_DIR}/mihomo"
BIN_YQ="${BIN_BASE_DIR}/yq"
BIN_SUBCONVERTER_DIR="${BIN_BASE_DIR}/subconverter"
BIN_SUBCONVERTER_CONFIG="$BIN_SUBCONVERTER_DIR/pref.yml"
BIN_SUBCONVERTER_PORT="25500"
BIN_SUBCONVERTER="${BIN_SUBCONVERTER_DIR}/subconverter"
BIN_SUBCONVERTER_LOG="${BIN_SUBCONVERTER_DIR}/latest.log"

# 默认集成、安装mihomo内核
# 移除/删除mihomo：下载安装clash内核
# shellcheck disable=SC2086
# shellcheck disable=SC2015
function _get_kernel() {
    /bin/ls $ZIP_BASE_DIR 2>/dev/null | grep -qsE 'clash|mihomo' || {
        local cpu_arch=$(uname -m)
        _failcat "${ZIP_BASE_DIR}：未检测到有效的内核压缩包，即将下载内核：clash"
        _download_clash "$cpu_arch"
    }
    _adaptive
    _okcat "安装内核：$BIN_KERNEL_NAME"
}

_adaptive() {
    local os_info=$(cat /etc/os-release)
    echo "$os_info" | grep -iqsE "rhel|centos" && {
        CLASH_CRON_TAB='/var/spool/cron/root'
        BASHRC='/etc/bashrc'
    }
    echo "$os_info" | grep -iqsE "debian|ubuntu" && {
        CLASH_CRON_TAB='/var/spool/cron/crontabs/root'
        BASHRC='/etc/bash.bashrc'
    }

    # shellcheck disable=SC2086
    # shellcheck disable=SC2015
    [ -e $ZIP_MIHOMO ] && {
        ZIP_KERNEL=$ZIP_MIHOMO
        BIN_KERNEL=$BIN_MIHOMO
    } || {
        ZIP_KERNEL=$ZIP_CLASH
        BIN_KERNEL=$BIN_CLASH
    }
    BIN_KERNEL_NAME=$(basename "$BIN_KERNEL")
}
_adaptive

_is_bind() {
    sudo awk '{print $2}' /proc/net/tcp | grep -qsi ":$(printf "%x" "$1")"
}

_random_port() {
    local randomPort
    while :; do
        randomPort=$((RANDOM % 64512 + 1024))
        grep -q "$(printf ":%04X" $randomPort)" /proc/net/tcp || {
            echo $randomPort
            break
        }
    done
}

function _get_port() {
    local mixed_port=$(sudo $BIN_YQ '.mixed-port // ""' $CLASH_CONFIG_RUNTIME)
    local ext_addr=$(sudo $BIN_YQ '.external-controller // ""' $CLASH_CONFIG_RUNTIME)
    local ext_port=${ext_addr##*:}

    MIXED_PORT=${mixed_port:-7890}
    UI_PORT=${ext_port:-9090}

    # 端口占用场景
    local port
    for port in $MIXED_PORT $UI_PORT; do
        _is_bind "$port" && {
            [ "$port" = "$MIXED_PORT" ] && {
                local newPort=$(_random_port)
                local msg="端口占用：${MIXED_PORT} 🎲 随机分配：$newPort"
                sudo "$BIN_YQ" -i ".mixed-port = $newPort" $CLASH_CONFIG_RUNTIME
                MIXED_PORT=$newPort
                _failcat '🎯' "$msg"
                continue
            }
            [ "$port" = "$UI_PORT" ] && {
                newPort=$(_random_port)
                msg="端口占用：${UI_PORT} 🎲 随机分配：$newPort"
                sudo "$BIN_YQ" -i ".external-controller = \"0.0.0.0:$newPort\"" $CLASH_CONFIG_RUNTIME
                UI_PORT=$newPort
                _failcat '🎯' "$msg"
            }
        }
    done
}

function _color() {
    local hex="${1#\#}"
    local r=$((16#${hex:0:2}))
    local g=$((16#${hex:2:2}))
    local b=$((16#${hex:4:2}))
    printf "\e[38;2;%d;%d;%dm" "$r" "$g" "$b"
}

function _color_msg() {
    local color=$(_color "$1")
    local msg=$2
    local reset="\033[0m"
    printf "%b%s%b\n" "$color" "$msg" "$reset"
}

function _okcat() {
    local color=#c8d6e5
    local emoji=😼
    [ $# -gt 1 ] && emoji=$1 && shift
    local msg="${emoji} $1"
    _color_msg "$color" "$msg" && return 0
}

function _failcat() {
    local color=#fd79a8
    local emoji=😾
    [ $# -gt 1 ] && emoji=$1 && shift
    local msg="${emoji} $1"
    _color_msg "$color" "$msg" >&2 && return 1
}

# bash执行   $0为脚本执行路径
# source执行 $0为bash
function _error_quit() {
    [ $# -gt 0 ] && {
        local color=#f92f60
        local emoji=📢
        [ $# -gt 1 ] && emoji=$1 && shift
        local msg="${emoji} $1"
        _color_msg "$color" "$msg"
    }
    echo "$0" | grep -qs 'bash' && exec bash || exit 1
}

_download_clash() {
    local url sha256sum
    case "$1" in
    x86_64)
        url=https://downloads.clash.wiki/ClashPremium/clash-linux-amd64-2023.08.17.gz
        sha256sum='92380f053f083e3794c1681583be013a57b160292d1d9e1056e7fa1c2d948747'
        ;;
    *86*)
        url=https://downloads.clash.wiki/ClashPremium/clash-linux-386-2023.08.17.gz
        sha256sum='254125efa731ade3c1bf7cfd83ae09a824e1361592ccd7c0cccd2a266dcb92b5'
        ;;
    armv*)
        url=https://downloads.clash.wiki/ClashPremium/clash-linux-armv5-2023.08.17.gz
        sha256sum='622f5e774847782b6d54066f0716114a088f143f9bdd37edf3394ae8253062e8'
        ;;
    aarch64)
        url=https://downloads.clash.wiki/ClashPremium/clash-linux-arm64-2023.08.17.gz
        sha256sum='c45b39bb241e270ae5f4498e2af75cecc0f03c9db3c0db5e55c8c4919f01afdd'
        ;;
    *)
        _error_quit "未知的架构版本：$1，请自行下载对应版本至 ${ZIP_BASE_DIR} 目录下：https://downloads.clash.wiki/ClashPremium/"
        ;;
    esac
    _failcat "当前 CPU 架构为：$1，正在下载对应版本..."
    wget \
        --timeout=30 \
        --quiet \
        --tries=1 \
        --no-check-certificate \
        --directory-prefix "$ZIP_BASE_DIR" \
        "$url"
    # shellcheck disable=SC2086
    echo $sha256sum $ZIP_CLASH | sha256sum -c ||
        _error_quit "下载失败：请自行下载对应版本至 ${ZIP_BASE_DIR} 目录下：https://downloads.clash.wiki/ClashPremium/"

}

function _valid_env() {
    [ "$(whoami)" != "root" ] && _error_quit "需要 root 或 sudo 权限执行"
    [ "$(ps -p $$ -o comm=)" != "bash" ] && _error_quit "当前终端不是 bash"
    [ "$(ps -p 1 -o comm=)" != "systemd" ] && _error_quit "系统不具备 systemd"
}

function _valid_config() {
    [ -e "$1" ] && [ "$(wc -l <"$1")" -gt 1 ] && {
        local test_cmd="$BIN_KERNEL -d $(dirname "$1") -f $1 -t"
        $test_cmd >/dev/null || {
            $test_cmd | grep "unsupport proxy type" &&
                _error_quit "不支持的代理协议，请安装 mihomo 内核"
        }
    }
}

_download_raw_config() {
    local dest=$1
    local url=$2
    local agent='Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:130.0) Gecko/20100101 Firefox/130.0'
    sudo curl \
        --silent \
        --show-error \
        --insecure \
        --connect-timeout 4 \
        --retry 1 \
        --user-agent "$agent" \
        --output "$dest" \
        "$url" ||
        sudo wget \
            --no-verbose \
            --no-check-certificate \
            --timeout 3 \
            --tries 1 \
            --user-agent "$agent" \
            --output-document "$dest" \
            "$url"
}

_convert_url() {
    # 不支持中文域名编码
    urlencode() {
        local LANG=C
        local length="${#1}"
        for ((i = 0; i < length; i++)); do
            c="${1:i:1}"
            case "$c" in
            [a-zA-Z0-9.~_-]) printf "%s" "$c" ;;
            *) printf '%%%02X' "'$c" ;;
            esac
        done
        echo
    }

    local target='clash'
    local base_url="http://127.0.0.1:${BIN_SUBCONVERTER_PORT}/sub?target=${target}&url="
    local encoded_url=$(urlencode "$1")
    echo "${base_url}${encoded_url}"
}

_start_convert() {
    _is_bind $BIN_SUBCONVERTER_PORT && {
        local newPort=$(_random_port)
        _failcat '🎯' "端口占用：$BIN_SUBCONVERTER_PORT 🎲 随机分配：$newPort"
        [ ! -e $BIN_SUBCONVERTER_CONFIG ] && {
            sudo /bin/mv -f $BIN_SUBCONVERTER_DIR/pref.example.yml $BIN_SUBCONVERTER_CONFIG
        }
        sudo $BIN_YQ -i ".server.port = $newPort" $BIN_SUBCONVERTER_CONFIG
        BIN_SUBCONVERTER_PORT=$newPort
    }
    local start=$(date +%s)
    # 子shell运行，屏蔽kill时的输出
    (sudo $BIN_SUBCONVERTER >&$BIN_SUBCONVERTER_LOG &)
    while ! _is_bind "$BIN_SUBCONVERTER_PORT" >&/dev/null; do
        sleep 0.05s
        local now=$(date +%s)
        [ $((now - start)) -gt 1 ] && _error_quit "订阅转换服务未启动，请检查日志：$BIN_SUBCONVERTER_LOG"
    done
}

_stop_convert() {
    pkill -9 -f $BIN_SUBCONVERTER >&/dev/null
}

_download_convert_config() {
    local dest=$1
    local url=$2
    _start_convert
    _download_raw_config "$dest" "$(_convert_url "$url")"
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
