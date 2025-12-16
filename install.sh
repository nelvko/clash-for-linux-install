#!/usr/bin/env bash

. scripts/cmd/clashctl.sh
. scripts/preflight.sh

_valid
_parse_args "$@"

_prepare_zip
_detect_init

_okcat "安装内核：$KERNEL_NAME by ${INIT_TYPE}"
_okcat '📦' "安装路径：$CLASH_BASE_DIR"

_valid_config "$RESOURCES_CONFIG_BASE" || {
    [ -z "$CLASH_CONFIG_URL" ] && {
        echo -n "$(_okcat '✈️ ' '输入订阅：')"
        read -r CLASH_CONFIG_URL
    }
    _okcat '⏳' '正在下载...'
    _download_config "$RESOURCES_CONFIG_BASE" "$CLASH_CONFIG_URL" || _error_quit "下载失败: 请将配置内容写入 $RESOURCES_CONFIG_BASE 后重新安装"
    _valid_config "$RESOURCES_CONFIG_BASE" || _error_quit "订阅无效，请检查：
    原始订阅：${RESOURCES_CONFIG_BASE}.raw
    转换订阅：$RESOURCES_CONFIG_BASE
    转换日志：$BIN_SUBCONVERTER_LOG"
}
_okcat '✅' '配置可用'

/bin/cp -rf . "$CLASH_BASE_DIR"
_set_envs

_install_service
_apply_rc

clashsecret "$(_get_random_val)" >/dev/null
clashui
clashsecret

_is_regular_sudo && chown -R "$SUDO_USER" "$CLASH_BASE_DIR"

clashctl
clashon
_okcat '🎉' 'enjoy 🎉'
_quit
