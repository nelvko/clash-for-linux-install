#!/usr/bin/env bash

clashui() {
    _detect_ext_addr
    if ! service_is_active >/dev/null 2>&1; then
        local service_ready=0 _
        _ui_step "启动 ${CLASHCTL_KERNEL} 服务"
        service_start >/dev/null 2>&1 || {
            _ui_error "无法启动 ${CLASHCTL_KERNEL} 服务"
            _ui_detail '查看日志' 'clashctl log'
            return 1
        }
        for _ in {1..20}; do
            if service_is_active >/dev/null 2>&1; then
                service_ready=1
                break
            fi
            sleep 0.25
        done
        if [ "$service_ready" -ne 1 ]; then
            _ui_error "${CLASHCTL_KERNEL} 服务未能进入运行状态"
            _ui_detail '查看日志' 'clashctl log'
            return 1
        fi
        _ui_ok "${CLASHCTL_KERNEL} 服务已启动"
    fi

    local query_url='https://api64.ipify.org'
    local public_ip public_address public_host local_host=$EXT_IP
    case $local_host in \[*\]) ;; *:*) local_host="[$local_host]" ;; esac
    local local_address="http://${local_host}:${EXT_PORT}/ui"
    local common_address='http://board.zash.run.place'

    public_ip=$(curl --silent --fail --noproxy '*' --location --max-time 2 "$query_url" 2>/dev/null) || public_ip=
    case $public_ip in
    '' | *[!0-9A-Fa-f:.]*)
        public_address="未检测到（使用服务器公网 IP 与端口 ${EXT_PORT}）"
        ;;
    *:*)
        public_host="[${public_ip}]"
        public_address="http://${public_host}:${EXT_PORT}/ui"
        ;;
    *)
        public_address="http://${public_ip}:${EXT_PORT}/ui"
        ;;
    esac

    _ui_blank
    _ui_header 'Web 控制台'
    _ui_detail '内网地址' "$local_address"
    _ui_detail '公网地址' "$public_address"
    _ui_detail '公共面板' "$common_address"
    _ui_detail '访问端口' "${EXT_PORT}/tcp（公网访问时需在防火墙放行）"
    _ui_detail '访问密钥' '运行 clashctl secret 查看'
}
