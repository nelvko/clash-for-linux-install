#!/usr/bin/env bash

clashon() {
    local mode
    case "$1" in
    -s | --service)
        mode=service
        ;;
    -e | --env)
        mode=env
        ;;
    -h | --help)
        cat <<EOF

- 开启代理服务，并进入带代理环境的新 Bash
  clashctl on

- 仅开启代理服务
  clashctl on -s
  clashctl on --service

- 仅开启当前终端代理环境
  clashctl on -e
  clashctl on --env-only

EOF
        return 0
        ;;
    esac

    _detect_proxy_port
    if [ "$mode" = "env" ]; then
        service_is_active >/dev/null 2>&1 || {
            _failcat '代理服务未运行，请先执行 clashctl on 或 clashctl on -s'
            return 1
        }
        _okcat '已开启终端代理环境'
        _proxy_exec_shell on
        return 0
    fi

    service_is_active >/dev/null 2>&1 || service_start
    service_is_active >/dev/null 2>&1 || {
        _failcat '启动失败: 执行 clashctl log 查看日志'
        return 1
    }

    if [ "$mode" = "service" ]; then
        _okcat '已启动代理服务'
        return 0
    fi

    _okcat '已开启代理环境'
    _proxy_exec_shell on
}
