#!/usr/bin/env bash

clashui() {
    _detect_ext_addr
    service_is_active >&/dev/null || service_start >/dev/null
    service_is_active >&/dev/null || _error_quit "无法启动服务，请检查日志"

    local query_url='https://api64.ipify.org'
    local public_ip
    public_ip=$(curl -s --noproxy "*" --location --max-time 2 "$query_url")
    local public_address="http://${public_ip:-公网}:${EXT_PORT}/ui"

    local local_ip=$EXT_IP
    local local_address="http://${local_ip}:${EXT_PORT}/ui"

    local common_address='http://board.zash.run.place'
    
    printf "\n"
    printf "╔═══════════════════════════════════════════════╗\n"
    printf "║                %s                  ║\n" "$(_okcat 'Web 控制台')"
    printf "║═══════════════════════════════════════════════║\n"
    printf "║                                               ║\n"
    printf "║     🔓 注意放行端口：%-5s                    ║\n" "$EXT_PORT"
    printf "║     🏠 内网：%-31s  ║\n" "$local_address"
    printf "║     🌏 公网：%-31s  ║\n" "$public_address"
    printf "║     ☁️  公共：%-31s  ║\n" "$common_address"
    printf "║                                               ║\n"
    printf "╚═══════════════════════════════════════════════╝\n"
    printf "\n"
}
