#!/usr/bin/env bash

clashon() {
    case "$1" in
    -e | --env-only)
        on_env_only
        ;;
    -s | --service-only)
        on_service_only
        ;;
    -h | --help)
        on_help
        ;;
    *)
        on_service_only || return
        on_env_only
        ;;
    esac
}

on_env_only() {
    service_is_active >&/dev/null || {
        _failcat "$CLASHCTL_KERNEL 未运行，请使用 clashctl on 开启代理环境"
        return 1
    }
    set_system_proxy
    _okcat "终端代理已启用"
}

on_service_only() {
    service_is_active >&/dev/null && {
        _okcat "$CLASHCTL_KERNEL 已运行"
        return 0
    }
    _detect_proxy_port
    service_start
    service_is_active >&/dev/null || {
        _failcat "$CLASHCTL_KERNEL 启动失败"
        return 1
    }
    _okcat "$CLASHCTL_KERNEL 已启动"
}

on_help() {
    cat <<EOF

clashctl on - 开启代理环境

Usage:
  clashctl on [OPTIONS]

Options:
  -s, --service-only 仅启动 $CLASHCTL_KERNEL 服务
  -e, --env-only     仅开启终端代理
  -h, --help         显示帮助信息

EOF
}

set_system_proxy() {
    local mixed_port http_port socks_port auth
    IFS='|' read -r mixed_port http_port socks_port auth < <(
        "$BIN_YQ" '[.mixed-port // "", .port // "", .socks-port // "", .authentication[0] // ""] | join("|")' "$CLASH_CONFIG_RUNTIME"
    )
    [ -n "$auth" ] && auth=$auth@

    local bind_addr=$(_get_bind_addr)
    local http_proxy_addr="http://${auth}${bind_addr}:${http_port:-${mixed_port}}"
    local socks_proxy_addr="socks5h://${auth}${bind_addr}:${socks_port:-${mixed_port}}"
    local no_proxy_addr="localhost,127.0.0.1,::1"

    export http_proxy=$http_proxy_addr
    export HTTP_PROXY=$http_proxy

    export https_proxy=$http_proxy
    export HTTPS_PROXY=$https_proxy

    export all_proxy=$socks_proxy_addr
    export ALL_PROXY=$all_proxy

    export no_proxy=$no_proxy_addr
    export NO_PROXY=$no_proxy
}

_dump_proxy_env_fish() {
    local v val
    for v in http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY; do
        val=${!v}
        [ -z "$val" ] && continue
        val=${val//\\/\\\\}
        val=${val//\'/\\\'}
        printf "set -gx %s '%s'\n" "$v" "$val"
    done
}