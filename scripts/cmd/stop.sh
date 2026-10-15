#!/usr/bin/env bash

# shellcheck disable=SC1091  # 独立 source（测试）时补载依赖；经 clashctl.sh 加载时已存在。
declare -F _clashctl_run_in_bash >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../lib/shell.sh"

clashstop() {
    case ${1:-} in
    -h | --help)
        printf '用法: clashctl stop\n停止内核，不修改终端代理环境；会影响所有使用此内核的客户端。\n'
        return 0 ;;
    '') ;;
    *) _ui_fail '用法: clashctl stop'; return 1 ;;
    esac
    if ! _clashctl_in_bash; then
        _clashctl_run_in_bash clashstop "$@"
        return
    fi
    service_stop_checked || return 1
    _ui_ok_out "$CLASHCTL_KERNEL 已停止"
    if [ -n "${http_proxy:-}${https_proxy:-}${all_proxy:-}${HTTP_PROXY:-}${HTTPS_PROXY:-}${ALL_PROXY:-}" ]; then
        _ui_warn '当前终端仍设置了代理，如不再使用请执行 clashctl off'
    fi
    return 0
}
