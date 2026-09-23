#!/usr/bin/env bash

clashoff() {
    case "${1:-}" in
    -h | --help)
        off_help
        return
        ;;
    '') ;;
    *) _ui_fail '用法: clashctl off [--help]'; return 1 ;;
    esac
    unset_system_proxy
    _ui_ok_out "当前终端代理环境已清除，内核运行状态未改变"
}

unset_system_proxy() {
    unset http_proxy
    unset https_proxy
    unset HTTP_PROXY
    unset HTTPS_PROXY
    unset all_proxy
    unset ALL_PROXY
    unset no_proxy
    unset NO_PROXY
}

off_help() {
    cat <<EOF

clashctl off - 关闭当前终端代理，保留内核运行

Usage:
  clashctl off [OPTIONS]

Options:
  -h, --help  显示帮助信息

EOF
}
