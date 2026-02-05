#!/usr/bin/env bash
# shellcheck disable=SC2034
. "$(dirname "$(dirname "$THIS_SCRIPT_DIR")")/.env"

CLASH_RESOURCES_DIR="${CLASH_BASE_DIR}/resources"
CLASH_CONFIG_BASE="${CLASH_RESOURCES_DIR}/config.yaml"
CLASH_CONFIG_MIXIN="${CLASH_RESOURCES_DIR}/mixin.yaml"
CLASH_CONFIG_RUNTIME="${CLASH_RESOURCES_DIR}/runtime.yaml"
CLASH_CONFIG_TEMP="${CLASH_RESOURCES_DIR}/temp.yaml"

BIN_BASE_DIR="${CLASH_BASE_DIR}/bin"
BIN_KERNEL="${BIN_BASE_DIR}/$KERNEL_NAME"
BIN_YQ="${BIN_BASE_DIR}/yq"
BIN_SUBCONVERTER_DIR="${BIN_BASE_DIR}/subconverter"
BIN_SUBCONVERTER="${BIN_SUBCONVERTER_DIR}/subconverter"
BIN_SUBCONVERTER_START="$BIN_SUBCONVERTER"
BIN_SUBCONVERTER_STOP="pkill -9 -f $BIN_SUBCONVERTER"
BIN_SUBCONVERTER_CONFIG="$BIN_SUBCONVERTER_DIR/pref.yml"
BIN_SUBCONVERTER_LOG="${BIN_SUBCONVERTER_DIR}/latest.log"

CLASH_PROFILES_DIR="${CLASH_RESOURCES_DIR}/profiles"
CLASH_PROFILES_META="${CLASH_RESOURCES_DIR}/profiles.yaml"
CLASH_PROFILES_LOG="${CLASH_RESOURCES_DIR}/profiles.log"

_is_port_used() {
    local port=$1
    { ss -tunl 2>/dev/null || netstat -tunl; } | grep -qs ":${port}\b"
}

_get_random_port() {
    local randomPort=$(shuf -i 1024-65535 -n 1)
    ! _is_port_used "$randomPort" && { echo "$randomPort" && return; }
    _get_random_port
}

_get_bind_addr() {
    local allowLan bindAddr
    bindAddr=$("$BIN_YQ" '.bind-address // "*"' "$CLASH_CONFIG_RUNTIME")
    allowLan=$("$BIN_YQ" '.allow-lan // false' "$CLASH_CONFIG_RUNTIME")

    case $allowLan in
    true)
        [ "$bindAddr" = "*" ] && bindAddr=$(_get_local_ip)
        ;;
    false)
        bindAddr=127.0.0.1
        ;;
    esac
    echo "$bindAddr"
}

_get_local_ip() {
    local local_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
    [ -z "$local_ip" ] && local_ip=$(hostname -I | awk '{print $1}')
    echo "$local_ip"
}

function _detect_ext_addr() {
    local ext_addr=$("$BIN_YQ" '.external-controller // ""' "$CLASH_CONFIG_RUNTIME")
    local ext_ip=${ext_addr%%:*}
    EXT_IP=$ext_ip
    EXT_PORT=${ext_addr##*:}
    [ "$ext_ip" = '0.0.0.0' ] && EXT_IP=$(_get_local_ip)
    _is_port_used "$EXT_PORT" && {
        curl -s --noproxy "*" -H "Authorization: Bearer $(_get_secret)" "127.0.0.1:${EXT_PORT}" | grep -qs "${KERNEL_NAME}" && return 0
        local newPort=$(_get_random_port)
        _failcat '🎯' "端口冲突：[external-controller] ${EXT_PORT} 🎲 随机分配 $newPort"
        EXT_PORT=$newPort
        "$BIN_YQ" -i ".external-controller = \"$ext_ip:$newPort\"" "$CLASH_CONFIG_MIXIN"
        _merge_config
    }
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

function _okcat() {
    local color=#c8d6e5
    local emoji=😼
    [ $# -gt 1 ] && emoji=$1 && shift
    local msg="${emoji} $1"
    _color_log "$color" "$msg"
    return 0
}

function _failcat() {
    local color=#fd79a8
    local emoji=😾
    [ $# -gt 1 ] && emoji=$1 && shift
    local msg="${emoji} $1"
    _color_log "$color" "$msg" >&2
    return 1
}

function _error_quit() {
    [ $# -gt 0 ] && {
        local color=#f92f60
        local emoji=📢
        [ $# -gt 1 ] && emoji=$1 && shift
        local msg="${emoji} $1"
        _color_log "$color" "$msg"
    }
    exec $SHELL -i
}

_download_file() {
    local dest=$1
    local url=$2
    local tmp="${dest}.tmp"

    rm -f "$tmp"
    curl \
        --silent \
        --show-error \
        --fail \
        --insecure \
        --location \
        --connect-timeout 5 \
        --max-time 180 \
        --retry 1 \
        --output "$tmp" \
        "$url" ||
        wget \
            --no-verbose \
            --no-check-certificate \
            --timeout 180 \
            --tries 1 \
            --output-document "$tmp" \
            "$url" ||
        return 1

    [ -s "$tmp" ] || return 1
    /bin/mv -f "$tmp" "$dest"
}

_download_file_any() {
    local dest=$1
    shift

    local url
    for url in "$@"; do
        [ -n "$url" ] || continue
        _download_file "$dest" "$url" && return 0
    done
    return 1
}

_gh_proxy_url() {
    local url=$1
    [ -n "$URL_GH_PROXY" ] || return 1
    [[ "$url" == https://github.com/* || "$url" == http://github.com/* ]] || return 1
    echo "${URL_GH_PROXY%/}/$url"
}

_ensure_mihomo_geodata() {
    local config=$1
    local data_dir
    data_dir=$(dirname "$config")

    local url_geoip_metadb="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb"
    local url_geosite_dat="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat"
    local url_geolite2_asn_mmdb="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/GeoLite2-ASN.mmdb"

    local mirror_geoip_metadb="https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb"
    local mirror_geosite_dat="https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat"
    local mirror_geolite2_asn_mmdb="https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/GeoLite2-ASN.mmdb"

    local file_geoip_metadb="${data_dir}/geoip.metadb"
    local file_geosite_dat="${data_dir}/geosite.dat"
    local file_asn_mmdb="${data_dir}/ASN.mmdb"

    grep -qs 'GEOIP' "$config" && [ ! -f "$file_geoip_metadb" ] && {
        local url1 url2
        url1=$(_gh_proxy_url "$url_geoip_metadb")
        url2="$url_geoip_metadb"
        _okcat '⏳' "下载 GeoData：geoip.metadb"
        _download_file_any "$file_geoip_metadb" "$url1" "$url2" "$mirror_geoip_metadb" ||
            _failcat "GeoData 下载失败：geoip.metadb（请检查网络或 URL_GH_PROXY）"
    }

    grep -qs 'GEOSITE' "$config" && [ ! -f "$file_geosite_dat" ] && {
        local url1 url2
        url1=$(_gh_proxy_url "$url_geosite_dat")
        url2="$url_geosite_dat"
        _okcat '⏳' "下载 GeoData：geosite.dat"
        _download_file_any "$file_geosite_dat" "$url1" "$url2" "$mirror_geosite_dat" ||
            _failcat "GeoData 下载失败：geosite.dat（请检查网络或 URL_GH_PROXY）"
    }

    grep -qs 'IP-ASN' "$config" && [ ! -f "$file_asn_mmdb" ] && {
        local url1 url2
        url1=$(_gh_proxy_url "$url_geolite2_asn_mmdb")
        url2="$url_geolite2_asn_mmdb"
        _okcat '⏳' "下载 GeoData：ASN.mmdb"
        _download_file_any "$file_asn_mmdb" "$url1" "$url2" "$mirror_geolite2_asn_mmdb" ||
            _failcat "GeoData 下载失败：ASN.mmdb（请检查网络或 URL_GH_PROXY）"
    }
}

function _valid_config() {
    local config="$1"
    [[ ! -e "$config" || "$(wc -l <"$config")" -lt 1 ]] && return 1

    local test_cmd test_log
    test_cmd=("$BIN_KERNEL" -d "$(dirname "$config")" -f "$config" -t)

    [ "$KERNEL_NAME" = "mihomo" ] && _ensure_mihomo_geodata "$config"

    test_log=$("${test_cmd[@]}" 2>&1) || {
        # 兜底：处理残缺/旧版 GeoData
        [ "$KERNEL_NAME" = "mihomo" ] && {
            grep -qs "MMDB invalid" <<<"$test_log" && rm -f "$(dirname "$config")/geoip.metadb"
            grep -qs "ASN invalid" <<<"$test_log" && rm -f "$(dirname "$config")/ASN.mmdb"
            _ensure_mihomo_geodata "$config"
            test_log=$("${test_cmd[@]}" 2>&1) && return 0
        }

        printf '%s\n' "$test_log" >&2
        grep -qs "unsupport proxy type" <<<"$test_log" && {
            local prefix="检测到订阅中包含不受支持的代理协议"
            [ "$KERNEL_NAME" = "clash" ] && _error_quit "${prefix}, 推荐安装使用 mihomo 内核"
            _error_quit "${prefix}, 请检查并升级内核版本"
        }
        return 1
    }
}

function _download_config() {
    local dest=$1
    local url=$2
    [ "${url:0:4}" = 'file' ] || _okcat '⏳' '正在下载...'
    _download_raw_config "$dest" "$url" || return 1
    _okcat '🍃' '验证订阅配置...'
    _valid_config "$dest" || {
        _failcat '🍂' "验证失败：尝试订阅转换..."
        cat "$dest" >"${dest}.raw"
        _download_convert_config "$dest" "$url"
    }
}
_download_raw_config() {
    local dest=$1
    local url=$2

    curl \
        --silent \
        --show-error \
        --fail \
        --insecure \
        --location \
        --max-time 5 \
        --retry 1 \
        --user-agent "$CLASH_SUB_UA" \
        --output "$dest" \
        "$url" ||
        wget \
            --no-verbose \
            --no-check-certificate \
            --timeout 5 \
            --tries 1 \
            --user-agent "$CLASH_SUB_UA" \
            --output-document "$dest" \
            "$url"
}
_download_convert_config() {
    local dest=$1
    local url=$2
    local flag
    [ "${url:0:4}" = 'file' ] && return 0
    _start_convert
    local convert_url=$(
        target='clash'
        base_url="http://127.0.0.1:${BIN_SUBCONVERTER_PORT}/sub"
        curl \
            --get \
            --silent \
            --show-error \
            --location \
            --output /dev/null \
            --data-urlencode "target=$target" \
            --data-urlencode "url=$url" \
            --write-out '%{url_effective}' \
            "$base_url"
    )
    curl --user-agent "$CLASH_SUB_UA" --silent --output "$dest" "$convert_url"
    flag=$?
    _stop_convert
    return $flag
}

_detect_subconverter_port() {
    BIN_SUBCONVERTER_PORT=$("$BIN_YQ" '.server.port' "$BIN_SUBCONVERTER_CONFIG")
    _is_port_used "$BIN_SUBCONVERTER_PORT" && {
        local newPort=$(_get_random_port)
        _failcat '🎯' "端口冲突：[subconverter] ${BIN_SUBCONVERTER_PORT} 🎲 随机分配：$newPort"
        BIN_SUBCONVERTER_PORT=$newPort
        "$BIN_YQ" -i ".server.port = $newPort" "$BIN_SUBCONVERTER_CONFIG" 2>/dev/null
    }
}

_start_convert() {
    _detect_subconverter_port
    local check_cmd="curl http://localhost:${BIN_SUBCONVERTER_PORT}/version"
    $check_cmd >&/dev/null && return 0
    ("$BIN_SUBCONVERTER_START" >&"$BIN_SUBCONVERTER_LOG" &)
    local start=$(date +%s)
    while ! $check_cmd >&/dev/null; do
        sleep 0.5s
        local now=$(date +%s)
        [ $((now - start)) -gt 2 ] && _error_quit "订阅转换服务未启动，请检查日志：$BIN_SUBCONVERTER_LOG"
    done
}
_stop_convert() {
    $BIN_SUBCONVERTER_STOP >/dev/null
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
