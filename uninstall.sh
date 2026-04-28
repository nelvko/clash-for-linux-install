#!/usr/bin/env bash

CLASHCTL_SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
. "$CLASHCTL_SRC/scripts/preflight.sh"

! _is_root && clashtun >&/dev/null && _error_quit "请先关闭 Tun 模式"
uninstall_service

command -v crontab >&/dev/null && {
    crontab -l 2>/dev/null | grep -Fv "$CLASHCTL_CRON_TAG" | crontab -
}

/usr/bin/rm -rf "$CLASHCTL_HOME"

echo '✨' '已卸载，相关配置已清除'
