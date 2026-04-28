#!/usr/bin/env bash

CLASHCTL_SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
. "$CLASHCTL_SRC/scripts/preflight.sh"

valid_env
parse_args "$@"

_okcat "安装内核：$CLASHCTL_KERNEL by ${INIT_TYPE}"
_okcat '📦' "安装路径：$CLASHCTL_HOME"

prepare_zip

install_service
install_clashctl

_merge_config
_detect_proxy_port
clashui
[ -z "$(_get_secret)" ] && clashsecret "$(_get_random_val)" >/dev/null
clashsecret

_valid_config "$CLASH_CONFIG_BASE" && {
    CLASHCTL_SUB_URL="file://$CLASH_CONFIG_BASE"
}
clashsub add --use "$CLASHCTL_SUB_URL"
