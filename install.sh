#!/usr/bin/env bash
CLASHCTL_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

. "$CLASHCTL_ROOT/.env"
. "$CLASHCTL_ROOT"/scripts/runtime/common.sh
. "$CLASHCTL_ROOT/scripts/preflight.sh"
. "$CLASHCTL_ROOT"/scripts/runtime/convert.sh
. "$CLASHCTL_ROOT"/scripts/runtime/env.sh
. "$CLASHCTL_ROOT"/scripts/runtime/kernel.sh
. "$CLASHCTL_ROOT"/scripts/runtime/service.sh

_valid
_parse_args "$@"

_detect_init

_okcat "安装内核：$KERNEL_NAME by ${INIT_TYPE}"
_okcat '📦' "安装路径：$CLASHCTL_HOME"

_prepare_zip

_install_service
_install_cli
_set_envs

_merge_config
_detect_proxy_port
clashctl ui
[ -z "$(_get_secret)" ] && clashctl secret "$(_get_random_val)" >/dev/null
clashctl secret

_valid_config "$CLASH_CONFIG_BASE" && {
    CLASH_CONFIG_URL="file://$CLASH_CONFIG_BASE"
}
clashctl sub add -u "$CLASH_CONFIG_URL" && clashctl on
