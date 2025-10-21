#!/usr/bin/env bash

# shellcheck disable=SC1091
. .env
. script/cmd/common.sh
. "${CLASH_CMD_DIR}/clashctl.sh" 2>/dev/null
. script/preflight.sh

_valid_env
clashoff >&/dev/null

_unset_init
_unset_rc

command -v crontab && crontab -l | grep -v "clashupdate" | crontab -

rm -rf "$CLASH_BASE_DIR" >&/dev/null || _error_quit '请使用 sudo 执行'

_okcat '✨' '已卸载，相关配置已清除'
_quit
