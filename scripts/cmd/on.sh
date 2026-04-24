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
        help
        ;;
    *)
        on_service_only || return
        on_env_only
        ;;
    esac
}

on_env_only() {
    service_is_active >&/dev/null || {
        _failcat "$CLASHCTL_KERNEL 服务未运行，请使用 clashctl on"
        return 1
    }
    _okcat "终端代理已开启"
    _proxy_exec_shell on
}

on_service_only() {
    _detect_proxy_port
    service_is_active >&/dev/null && {
        _okcat "$CLASHCTL_KERNEL 服务已启动"
        return 0
    }
    service_start
    service_is_active >&/dev/null || {
        _failcat "$CLASHCTL_KERNEL 服务启动失败"
        return 1
    }
    _okcat "$CLASHCTL_KERNEL 服务已启动"
}

help() {
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
