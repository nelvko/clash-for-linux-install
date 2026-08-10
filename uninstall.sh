#!/usr/bin/env bash

CLASHCTL_SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
. "$CLASHCTL_SRC/scripts/preflight.sh"
. "$CLASHCTL_SRC/scripts/cmd/off.sh"
. "$CLASHCTL_SRC/scripts/cmd/traffic.sh"

! _is_root && tunstatus >&/dev/null && {
    _errorcat "请先关闭 Tun 模式"
    exit
}
traffic_stop >/dev/null 2>&1 || true
uninstall_service

command -v crontab >&/dev/null && {
    crontab -l 2>/dev/null | grep -Fv "$CLASHCTL_CRON_TAG" | crontab -
}

/usr/bin/rm -rf "$CLASHCTL_HOME"
revoke_rc

_okcat '✨' "已卸载，相关配置已清除"
[ -n "$http_proxy" ] && _failcat '❗' "当前终端仍残留代理环境变量，重开终端即可清除"
