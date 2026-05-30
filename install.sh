#!/usr/bin/env bash

. scripts/cmd/clashctl.sh
. scripts/preflight.sh

_valid
_parse_args "$@"

_prepare_zip
_detect_init

_okcat "安装内核：$KERNEL_NAME by ${INIT_TYPE}"
_okcat '📦' "安装路径：$CLASH_BASE_DIR"

/bin/cp -rf . "$CLASH_BASE_DIR"
touch "$CLASH_CONFIG_BASE"
_set_envs
_is_regular_sudo && chown -R "$SUDO_USER" "$CLASH_BASE_DIR"

_install_service
_apply_rc


_merge_config
_detect_proxy_port
clashui
clashsecret "$(_get_random_val)" >/dev/null
clashsecret

_okcat '🎉' 'enjoy 🎉'
echo
_okcat '📌' '立即生效：请执行: source ~/.bashrc'
clashctl -h
