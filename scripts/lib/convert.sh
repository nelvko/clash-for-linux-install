#!/usr/bin/env bash

_download_config() {
    local dest=$1
    local url=$2
    [ "${url:0:4}" = 'file' ] || _okcat '⏳' '正在下载...'
    _download_raw_config "$dest" "$url" || return 1
    _normalize_sub_config "$dest" || return 1

    _is_html_response "$dest" && {
        _errorcat "订阅响应疑似 HTML 页面，请检查订阅链接或 User-Agent"
        return 1
    }

    _is_native_yaml_config "$dest" && {
        _okcat '🍃' '检测到原生 Clash/Mihomo 配置'
        _valid_config "$dest" && _valid_sub_nodes "$dest" && return
        _failcat '🍂' "原生配置验证失败：尝试订阅转换..."
        cat "$dest" >"${dest}.raw"
        _download_convert_config "$dest" "$url" || return
        _normalize_sub_config "$dest" || return
        _valid_sub_nodes "$dest"
        return
    }

    _okcat '🍃' '验证订阅配置...'
    _valid_config "$dest" && _valid_sub_nodes "$dest" && return

    _failcat '🍂' "验证失败：尝试订阅转换..."
    cat "$dest" >"${dest}.raw"
    _download_convert_config "$dest" "$url" || return
    _normalize_sub_config "$dest" || return
    _valid_sub_nodes "$dest"
}

_normalize_sub_config() {
    local dest=$1

    [ -s "$dest" ] || {
        _errorcat "订阅响应为空，请检查订阅链接"
        return 1
    }

    LC_ALL=C sed -i '1s/^\xEF\xBB\xBF//' "$dest" 2>/dev/null || true
    sed -i 's/\r$//' "$dest" 2>/dev/null || true

    command -v iconv >/dev/null || return 0
    iconv -f UTF-8 -t UTF-8 "$dest" >/dev/null 2>&1 && return 0

    local charset
    for charset in GB18030 GBK BIG5; do
        iconv -f "$charset" -t UTF-8 "$dest" -o "${dest}.utf8" 2>/dev/null && {
            /bin/mv -f "${dest}.utf8" "$dest"
            _okcat '🔤' "订阅已从 $charset 转为 UTF-8"
            return 0
        }
    done

    /usr/bin/rm -f "${dest}.utf8" 2>/dev/null
    return 0
}

_is_html_response() {
    LC_ALL=C grep -qiE '<[[:space:]]*(!doctype|html|head|body|title)([[:space:]>]|$)' "$1"
}

_is_native_yaml_config() {
    "$BIN_YQ" -e '
      ((.proxies // []) | type == "!!seq" and length > 0) or
      ((.proxy-providers // {}) | type == "!!map" and length > 0)
    ' "$1" >/dev/null 2>&1
}

_valid_sub_nodes() {
    local config=$1 count
    count=$("$BIN_YQ" '
      ((.proxies // []) | length) +
      ((.proxy-providers // {}) | length)
    ' "$config" 2>/dev/null) || return 0

    [ "${count:-0}" -gt 0 ] || {
        _errorcat "订阅未解析出任何节点，请检查订阅内容或转换器版本"
        return 1
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
        --max-time "$CLASHCTL_SUB_TIMEOUT" \
        --retry 1 \
        --user-agent "$CLASHCTL_SUB_UA" \
        --output "$dest" \
        "$url" ||
        wget \
            --no-verbose \
            --no-check-certificate \
            --timeout "$CLASHCTL_SUB_TIMEOUT" \
            --tries 1 \
            --user-agent "$CLASHCTL_SUB_UA" \
            --output-document "$dest" \
            "$url"
}

_download_convert_config() {
    local dest=$1
    local url=$2
    local flag

    [ "${url:0:4}" = 'file' ] && return 0

    _start_convert
    local convert_url
    convert_url=$(
        local target='clash'
        local base_url="http://127.0.0.1:${BIN_SUBCONVERTER_PORT}/sub"
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
    curl --user-agent "$CLASHCTL_SUB_UA" --silent --output "$dest" "$convert_url"
    flag=$?
    _stop_convert
    return $flag
}

_detect_subconverter_port() {
    BIN_SUBCONVERTER_PORT=$("$BIN_YQ" '.server.port' "$BIN_SUBCONVERTER_CONFIG")
    _is_port_used "$BIN_SUBCONVERTER_PORT" && {
        local new_port
        new_port=$(_get_random_port) || return
        _failcat '🎯' "端口冲突：[subconverter] ${BIN_SUBCONVERTER_PORT} 🎲 随机分配：$new_port"
        BIN_SUBCONVERTER_PORT=$new_port
        "$BIN_YQ" -i ".server.port = $new_port" "$BIN_SUBCONVERTER_CONFIG" 2>/dev/null
    }
}

_start_convert() {
    _detect_subconverter_port

    local check_url="http://localhost:${BIN_SUBCONVERTER_PORT}/version"
    curl --silent --fail "$check_url" >/dev/null 2>&1 && return 0

    "$BIN_SUBCONVERTER" >"$BIN_SUBCONVERTER_LOG" 2>&1 &

    local start now
    start=$(date +%s)
    while ! curl --silent --fail "$check_url" >/dev/null 2>&1; do
        sleep 0.2
        now=$(date +%s)
        [ $((now - start)) -gt 10 ] && { _errorcat "订阅转换服务未启动，请检查日志：$BIN_SUBCONVERTER_LOG"; return 1; }
    done
}

_stop_convert() {
    pkill -TERM -x subconverter 2>/dev/null
    sleep 0.2
    pkill -KILL -x subconverter 2>/dev/null
    return 0
}
