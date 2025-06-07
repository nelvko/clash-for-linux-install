#!/usr/bin/env bash

# shellcheck disable=SC1091
. script/cmd/common.sh
. "${CLASH_CMD_DIR}/clashctl.sh" 2>/dev/null
. script/preflight.sh unset
_valid_env
clashoff >&/dev/null

_get_kernel
_get_init
_set_init
_set_rc
crontab -l 2>/dev/null | grep -v "clashupdate" | crontab -

rm -rf "$CLASH_BASE_DIR"
rm -rf "$RESOURCES_BIN_DIR"
docker-compose down
_okcat '✨' '已卸载，相关配置已清除'
_quit
