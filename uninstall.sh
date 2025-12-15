#!/usr/bin/env bash

. scripts/cmd/clashctl.sh
. scripts/preflight.sh
. "$CLASH_CMD_DIR/clashctl.sh" 2>/dev/null

clashoff >&/dev/null

_uninstall_service
_revoke_rc

command -v crontab >&/dev/null && crontab -l | grep -v "clashsub" | crontab -

rm -rf "$CLASH_BASE_DIR" >&/dev/null || _error_quit '请使用 sudo 执行'

_okcat '✨' '已卸载，相关配置已清除'
_quit
