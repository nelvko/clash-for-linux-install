#!/usr/bin/env bash

# shellcheck disable=SC1091
. script/cmd/common.sh >&/dev/null
. script/cmd/clashctl.sh >&/dev/null
. script/preflight.sh >&/dev/null

_valid_env

clashoff >&/dev/null

_get_init
_set_init unset >&/dev/null

rm -rf "$CLASH_BASE_DIR"
rm -rf "$RESOURCES_BIN_DIR"
sed -i '/clashupdate/d' "$CLASH_CRON_TAB" >&/dev/null
_set_rc unset

_okcat '✨' '已卸载，相关配置已清除'
_quit
