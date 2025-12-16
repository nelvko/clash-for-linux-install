#!/usr/bin/env bash

. scripts/cmd/clashctl.sh
. scripts/preflight.sh

clashoff >&/dev/null

_uninstall_service
_revoke_rc

command -v crontab >&/dev/null && crontab -l | grep -v "clashsub" | crontab -

/usr/bin/rm -r "$CLASH_BASE_DIR"

_okcat '✨' '已卸载，相关配置已清除'
_quit
