#!/usr/bin/env bash

tunstatus() {
    local device
    device=$("$BIN_YQ" '.tun.device // ""' "$CLASH_CONFIG_RUNTIME")
    [ -z "$device" ] && device="Meta"
    ip link show | grep -qs "$device" && {
        _okcat 'Tun 状态：启用'
        return 0
    }
    _failcat 'Tun 状态：关闭'
    return 1
}

tunoff() {
    tunstatus >/dev/null || return 0
    service_sudo_stop >/dev/null
    service_is_active >&/dev/null || {
        "$BIN_YQ" -i '.tun.enable = false' "$CLASH_CONFIG_MIXIN"
        _merge_config
        service_start
        tunstatus >&/dev/null || _okcat "Tun 模式已关闭"
        return 0
    }
    tunstatus >/dev/null && _failcat "Tun 模式关闭失败"
}

tunon() {
    tunstatus 2>/dev/null && return 0
    service_stop >&/dev/null
    "$BIN_YQ" -i '.tun.enable = true' "$CLASH_CONFIG_MIXIN"
    _merge_config
    service_sudo_start || _error_quit 'Tun 模式开启失败'
    sleep 1
    tunstatus >&/dev/null || {
        [ "$CLASHCTL_KERNEL" = 'mihomo' ] && {
            "$BIN_YQ" -i '.tun.auto-redirect = false' "$CLASH_CONFIG_MIXIN"
            _merge_config
            service_sudo_stop
            service_sudo_start
            sleep 1
            tunstatus >&/dev/null || _error_quit 'Tun 模式开启失败, 请检查代理内核日志'
            _okcat "Tun 模式已开启" && return 0
        }
    }
    _okcat "Tun 模式已开启"
}

clashtun() {
    case "$1" in
    -h | --help)
        help
        return 0
        ;;
    on)
        tunon
        ;;
    off)
        tunoff
        ;;
    *)
        tunstatus
        ;;
    esac
}

help() {
    cat <<EOF

- 查看 Tun 状态
  clashctl tun

- 开启 Tun 模式
  clashctl tun on

- 关闭 Tun 模式
  clashctl tun off

EOF
}
