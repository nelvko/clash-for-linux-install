#!/usr/bin/env bash

clashoff() {
    case "$1" in
    -e | --env)
        _proxy_exec_shell off
        ;;
    -h | --help)
        _help
        return 0
        ;;
    esac

    service_is_active >&/dev/null && {
        service_stop >&/dev/null
        service_is_active >&/dev/null && _tunstatus >&/dev/null && {
            _tunoff || _error_quit "请先关闭 Tun 模式"
        }
        service_stop >&/dev/null
        service_is_active >&/dev/null && {
            _failcat '代理服务关闭失败'
            return 1
        }
    }

    _okcat '已关闭代理环境'
    _proxy_exec_shell off
}

_help() {
    cat <<EOF

- 关闭代理服务，并进入清理代理环境的新 Bash
  clashctl off

- 仅关闭代理服务
  clashctl off -s
  clashctl off --service-only

- 仅清理当前终端代理环境
  clashctl off -e
  clashctl off --env-only

EOF
}
