#!/usr/bin/env bash

. script/cmd/clashctl.sh
. script/preflight.sh

_valid_env
_valid_required
_parse_args "$@"

_get_kernel
_set_bin
_get_init

_okcat "安装内核：$KERNEL_NAME by ${INIT_TYPE}"
_okcat '📂' "安装路径：$CLASH_BASE_DIR"

_valid_config "$RESOURCES_CONFIG_RAW" || {
    [ -z "$CLASH_CONFIG_URL" ] && {
        echo -n "$(_okcat '✈️ ' '输入订阅：')"
        read -r CLASH_CONFIG_URL
    }
    _okcat '⏳' '正在下载...'
    _download_config "$RESOURCES_CONFIG_RAW" "$CLASH_CONFIG_URL" || _error_quit "下载失败: 请将配置内容写入 $RESOURCES_CONFIG_RAW 后重新安装"
    _valid_config "$RESOURCES_CONFIG_RAW" || _error_quit "配置无效，请检查：
    原始订阅：${RESOURCES_CONFIG_RAW}.raw
    转换配置：$RESOURCES_CONFIG_RAW
    转换日志：$BIN_SUBCONVERTER_LOG"
}
_okcat '✅' '配置可用'

/bin/cp -rf . "$CLASH_BASE_DIR"
"$BIN_YQ" -i ".secret = \"$(_get_random_val)\"" "$CLASH_CONFIG_MIXIN"
_merge_config
[ -n "$SUDO_USER" ] && chown -R "$SUDO_USER" "$CLASH_BASE_DIR"

_set_envs
_set_init
_set_rc

clashui
clashsecret

_okcat '🎉' 'enjoy 🎉'
clashctl
_quit
