#!/usr/bin/env bash

_detect_proxy_port() {
    local mixed_port http_port socks_port
    mixed_port=$("$BIN_YQ" '.mixed-port // ""' "$CLASH_CONFIG_RUNTIME")
    http_port=$("$BIN_YQ" '.port // ""' "$CLASH_CONFIG_RUNTIME")
    socks_port=$("$BIN_YQ" '.socks-port // ""' "$CLASH_CONFIG_RUNTIME")

    [ -z "$mixed_port" ] && [ -z "$http_port" ] && [ -z "$socks_port" ] && mixed_port=7890

    local count=0
    local service_active=false
    service_is_active >&/dev/null && service_active=true

    local entries=(
        "mixed-port:$mixed_port"
        "port:$http_port"
        "socks-port:$socks_port"
    )

    local entry yaml_key port new_port
    for entry in "${entries[@]}"; do
        yaml_key=${entry%%:*}
        port=${entry#*:}

        [ -n "$port" ] && _is_port_used "$port" && [ "$service_active" != "true" ] && {
            new_port=$(_get_random_port)
            count=$((count + 1))
            _failcat '🎯' "端口冲突：[$yaml_key] $port 🎲 随机分配 $new_port"
            "$BIN_YQ" -i ".${yaml_key} = $new_port" "$CLASH_CONFIG_MIXIN"
        }
    done

    [ "$count" -gt 0 ] && _merge_config
}

_proxy_resolve_env() {
    local mixed_port http_port socks_port auth bind_addr
    mixed_port=$("$BIN_YQ" '.mixed-port // ""' "$CLASH_CONFIG_RUNTIME")
    http_port=$("$BIN_YQ" '.port // ""' "$CLASH_CONFIG_RUNTIME")
    socks_port=$("$BIN_YQ" '.socks-port // ""' "$CLASH_CONFIG_RUNTIME")
    auth=$("$BIN_YQ" '.authentication[0] // ""' "$CLASH_CONFIG_RUNTIME")
    [ -n "$auth" ] && auth="${auth}@"

    bind_addr=$(_get_bind_addr)

    PROXY_HTTP_ADDR="http://${auth}${bind_addr}:${http_port:-${mixed_port}}"
    PROXY_SOCKS_ADDR="socks5h://${auth}${bind_addr}:${socks_port:-${mixed_port}}"
    PROXY_NO_ADDR="localhost,127.0.0.1,::1"
}

_proxy_export_env() {
    _proxy_resolve_env

    export http_proxy="$PROXY_HTTP_ADDR"
    export HTTP_PROXY="$PROXY_HTTP_ADDR"
    export https_proxy="$PROXY_HTTP_ADDR"
    export HTTPS_PROXY="$PROXY_HTTP_ADDR"
    export all_proxy="$PROXY_SOCKS_ADDR"
    export ALL_PROXY="$PROXY_SOCKS_ADDR"
    export no_proxy="$PROXY_NO_ADDR"
    export NO_PROXY="$PROXY_NO_ADDR"
}

_proxy_unset_env() {
    unset http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
}

_proxy_exec_shell() {
    local mode=$1

    [ -t 0 ] && [ -t 1 ] || return 0

    case "$mode" in
    on)
        _proxy_export_env
        ;;
    off)
        _proxy_unset_env
        ;;
    esac

    exec $SHELL
}
