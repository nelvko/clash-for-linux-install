#!/usr/bin/env bash

clashstop() {
    case ${1:-} in
    -h | --help)
        printf '用法: clashctl stop\n停止内核，不修改终端代理环境；会影响所有使用此内核的客户端。\n'
        return 0 ;;
    '') ;;
    *) _ui_fail '用法: clashctl stop'; return 1 ;;
    esac
    if [ -n "${ZSH_VERSION:-}" ]; then
        CLASHCTL_HOME="$CLASHCTL_HOME" bash -c '
            . "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" && clashstop
        '
        return
    fi
    service_stop_checked || return 1
    _ui_ok_out "$CLASHCTL_KERNEL 已停止"
    if [ -n "${http_proxy:-}${https_proxy:-}${all_proxy:-}${HTTP_PROXY:-}${HTTPS_PROXY:-}${ALL_PROXY:-}" ]; then
        _ui_warn '当前终端仍设置了代理，如不再使用请执行 clashctl off'
    fi
    return 0
}
