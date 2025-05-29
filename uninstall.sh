#!/usr/bin/env bash

# shellcheck disable=SC1091
. script/cmd/common.sh >&/dev/null
. "$CLASH_CMD_DIR/clashctl.sh" >&/dev/null
. script/preflight.sh >&/dev/null

_valid_env

clashoff >&/dev/null

_get_init
_set_init unset >&/dev/null
_set_rc unset
crontab -l 2>/dev/null | grep -v "clashupdate" | crontab

rm -rf "$CLASH_BASE_DIR"
rm -rf "$RESOURCES_BIN_DIR"

_okcat '✨' '已卸载，相关配置已清除'
_quit
