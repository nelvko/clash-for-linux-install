#!/usr/bin/env bash

CLASHCTL_SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
. "$CLASHCTL_SRC/scripts/preflight.sh"

_valid
_parse_args "$@"

_okcat "安装内核：$CLASHCTL_KERNEL by ${INIT_TYPE}"
_okcat '📦' "安装路径：$CLASHCTL_HOME"

_prepare_zip

_install_service
_install_cli

_merge_config
_detect_proxy_port
clashctl ui
[ -z "$(_get_secret)" ] && clashctl secret "$(_get_random_val)" >/dev/null
clashctl secret

_valid_config "$CLASH_CONFIG_BASE" && {
    CLASHCTL_SUB_URL="file://$CLASH_CONFIG_BASE"
}
clashctl sub add -u "$CLASHCTL_SUB_URL" && clashctl on
