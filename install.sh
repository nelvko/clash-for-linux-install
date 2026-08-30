#!/usr/bin/env bash

if [ -n "$SUDO_USER" ]; then
    export HOME=$(eval echo "~$SUDO_USER")
fi

CLASHCTL_SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
. "$CLASHCTL_SRC/scripts/preflight.sh"

valid_env
parse_args "$@"

_okcat "安装内核：$CLASHCTL_KERNEL"
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

if [ -n "$SUDO_USER" ] && [ -d "$CLASHCTL_HOME" ]; then
    SUDO_GROUP=$(id -gn "$SUDO_USER")
    chown -R "${SUDO_USER}:${SUDO_GROUP}" "$CLASHCTL_HOME"
fi

_okcat '🎉' "请执行 source ~/.bashrc 为当前 SHELL 加载 clashctl 命令"