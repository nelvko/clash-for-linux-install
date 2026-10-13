#!/usr/bin/env bash

clashtun() {
    case "${1:-}" in
    -h | --help)
        tun_help
        return 0
        ;;
    esac
    if [ -n "${ZSH_VERSION:-}" ]; then
        command -v bash >/dev/null 2>&1 || { _ui_error '未找到 Bash，请安装后重试'; return 127; }
        CLASHCTL_HOME="$CLASHCTL_HOME" bash -c '
            unset ZSH_VERSION
            . "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" && clashtun "$@"
        ' -- "$@"
        return
    fi
    [ "$#" -le 1 ] || { _ui_error '用法: clashctl tun [on|off]'; return 1; }
    case "${1:-}" in
    on)
        tunon
        ;;
    off)
        tunoff
        ;;
    '')
        tunstatus
        ;;
    *) _ui_error '用法: clashctl tun [on|off]'; return 1 ;;
    esac
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
    _tun_check_device_available || return 1
    service_stop >&/dev/null
    "$BIN_YQ" -i '.tun.enable = true' "$CLASH_CONFIG_MIXIN"
    _merge_config
    service_sudo_start || _errorcat 'Tun 模式开启失败' || return
    sleep 1
    tunstatus >&/dev/null || {
        [ "$CLASHCTL_KERNEL" = 'mihomo' ] && {
            "$BIN_YQ" -i '.tun.auto-redirect = false' "$CLASH_CONFIG_MIXIN"
            _merge_config
            service_sudo_stop
            service_sudo_start
            sleep 1
            tunstatus >&/dev/null || _errorcat 'Tun 模式开启失败, 请检查代理内核日志' || return
            _okcat "Tun 模式已开启" && return 0
        }
    }
    _okcat "Tun 模式已开启"
}

tun_help() {
    cat <<EOF

- 查看 Tun 状态
  clashctl tun

- 开启 Tun 模式
  clashctl tun on

- 关闭 Tun 模式
  clashctl tun off

EOF
}
