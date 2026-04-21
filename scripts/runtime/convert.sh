#!/usr/bin/env bash

_download_config() {
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
        --user-agent "clash-verge/v2.4.0" \
        --output "$dest" \
        "$url" ||
        wget \
            --no-verbose \
            --no-check-certificate \
            --timeout 5 \
            --tries 1 \
            --user-agent "clash-verge/v2.4.0" \
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
    curl --user-agent "clash-verge/v2.4.0" --silent --output "$dest" "$convert_url"
    flag=$?
    _stop_convert
    return $flag
}

_detect_subconverter_port() {
    BIN_SUBCONVERTER_PORT=$("$BIN_YQ" '.server.port' "$BIN_SUBCONVERTER_CONFIG")
    _is_port_used "$BIN_SUBCONVERTER_PORT" && {
        local new_port
        new_port=$(_get_random_port)
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
        sleep 0.5
        now=$(date +%s)
        [ $((now - start)) -gt 2 ] && _error_quit "订阅转换服务未启动，请检查日志：$BIN_SUBCONVERTER_LOG"
    done
}

_stop_convert() {
    pkill -9 -f "$BIN_SUBCONVERTER" >/dev/null 2>&1
}
