#!/usr/bin/env bash

# shellcheck disable=SC1091
. .env
. script/cmd/common.sh
. "${CLASH_CMD_DIR}/clashctl.sh" 2>/dev/null
. script/preflight.sh unset

_valid_env
clashoff >&/dev/null

[ -z "$CONTAINER_TYPE" ] && {
    _get_init
    _set_init
}

[ -n "$CONTAINER_TYPE" ] && {
    docker-compose --profile "$KERNEL_NAME" down
}

_set_rc
crontab -l 2>/dev/null | grep -v "clashupdate" | crontab -

rm -rf "$CLASH_BASE_DIR"

_okcat '✨' '已卸载，相关配置已清除'
_quit
