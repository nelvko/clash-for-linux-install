#!/usr/bin/env bash

clashoff() {
    case "${1:-}" in
    -h | --help)
        off_help
        return
        ;;
    -s | --service-only)
        _ui_warn 'off -s/--service-only 是兼容参数，请改用 clashctl stop'
        clashstop
        return
        ;;
    -e | --env-only)
        _ui_warn 'off -e/--env-only 是兼容参数，请直接使用 clashctl off'
        ;;
    '') ;;
    *) _ui_fail '用法: clashctl off [--help|-s|-e]'; return 1 ;;
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
  -s, --service-only  仅停止内核；兼容旧版，请改用 clashctl stop
  -e, --env-only      仅清除当前终端代理；兼容旧版，请直接使用 clashctl off
  -h, --help  显示帮助信息

EOF
}
