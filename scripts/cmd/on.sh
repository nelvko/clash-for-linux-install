#!/usr/bin/env bash

clashon() {
    case "${1:-}" in
    -h | --help)
        on_help
        return
        ;;
    -s | --service-only)
        _ui_warn 'on -s/--service-only 是兼容参数，请改用 clashctl start'
        clashstart
        return
        ;;
    -e | --env-only)
        _ui_warn 'on -e/--env-only 是兼容参数；内核未运行时请先执行 clashctl start'
        service_is_active >&/dev/null || {
            _ui_fail "$CLASHCTL_KERNEL 未运行，请先执行 clashctl start"
            return 1
        }
        ;;
    '') clashstart || return ;;
    *) _ui_fail '用法: clashctl on [--help|-s|-e]'; return 1 ;;
    esac
    set_system_proxy || return 1
    _ui_ok_out "当前终端代理已启用"
}

on_help() {
    cat <<EOF

clashctl on - 启用当前终端代理，内核未运行时自动启动

Usage:
  clashctl on [OPTIONS]

Options:
  -s, --service-only  仅启动内核；兼容旧版，请改用 clashctl start
  -e, --env-only      仅启用当前终端代理；要求内核已运行
  -h, --help  显示帮助信息

EOF
}

set_system_proxy() {
    local mixed_port http_port socks_port auth proxy_values
    proxy_values=$(
        "$BIN_YQ" \
            '[.mixed-port // "", .port // "", .socks-port // "", .authentication[0] // ""] | join("|")' \
            "$CLASH_CONFIG_RUNTIME"
    ) || {
        _ui_error '无法读取运行配置中的代理连接信息'
        return 1
    }
    IFS='|' read -r mixed_port http_port socks_port auth <<<"$proxy_values"
    [ -n "$auth" ] && auth=$auth@

    local bind_addr
    bind_addr=$(_get_bind_addr) || return 1
    if [ -z "$mixed_port" ] && { [ -z "$http_port" ] || [ -z "$socks_port" ]; }; then
        _ui_error '运行配置缺少可用的 HTTP 或 SOCKS 代理端口'
        return 1
    fi
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
    return 0
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
