#!/usr/bin/env bash

clashoff() {
    case "$1" in
    -e | --env-only)
        off_env_only
        ;;
    -s | --service-only)
        off_service_only || return
        [ -n "$http_proxy" ] && _failcat "警告：当前终端代理未关闭"
        ;;
    -h | --help)
        help
        ;;
    *)
        off_service_only || return
        off_env_only
        ;;
    esac
}

off_env_only() {
    _okcat "终端代理已关闭"
    _proxy_exec_shell off
}
off_service_only() {
    service_is_active >&/dev/null && {
        service_stop >/dev/null
        service_is_active >&/dev/null && tunstatus >&/dev/null && {
            service_sudo_stop || _error_quit "请先关闭 Tun 模式"
        }
        service_is_active >&/dev/null && {
            _failcat "$CLASHCTL_KERNEL 停止失败"
            return 1
        }
    }
    _okcat "$CLASHCTL_KERNEL 已停止"
}

help() {
    cat <<EOF

clashctl off - 关闭代理环境

Usage:
  clashctl off [OPTIONS]

Options:
  -s, --service-only 仅关闭 $CLASHCTL_KERNEL 服务
  -e, --env-only     仅关闭终端代理
  -h, --help         显示帮助信息

EOF
}
