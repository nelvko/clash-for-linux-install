#!/usr/bin/env bash

# shellcheck disable=SC1091
. script/cmd/clashctl.sh
. script/preflight.sh

_valid_env

_parse_args "$@"

_valid_required

[ -d "$CLASH_BASE_DIR" ] && _error_quit "请先执行卸载脚本,以清除安装路径：$CLASH_BASE_DIR"
mkdir -p "$CLASH_RESOURCES_DIR" || _error_quit "无写入权限：$CLASH_BASE_DIR，请前往 .env 文件更换安装路径"

_get_kernel
_get_init

_okcat "安装内核：$KERNEL_NAME by ${INIT_TYPE}"
_okcat "安装路径：$CLASH_BASE_DIR"

_valid_config "$(pwd)/$RESOURCES_CONFIG" || {
    [ -z "$CLASH_CONFIG_URL" ] && {
        echo -n "$(_okcat '✈️ ' '输入订阅：')"
        read -r CLASH_CONFIG_URL
    }
    _okcat '⏳' '正在下载...'
    _download_config "$(pwd)/$RESOURCES_CONFIG" "$CLASH_CONFIG_URL" || _error_quit "下载失败: 请将配置内容写入 $RESOURCES_CONFIG 后重新安装"
    _valid_config "$(pwd)/$RESOURCES_CONFIG" || _error_quit "配置无效，请检查配置：$RESOURCES_CONFIG，转换日志：$BIN_SUBCONVERTER_LOG"
}
_okcat '✅' '配置可用'

/bin/cp -rf . "$CLASH_BASE_DIR"
_merge_config

_set_envs
_set_rc
_set_init

clashui
clashsecret "$(_get_random_val)" >/dev/null
clashsecret

_okcat '🎉' 'enjoy 🎉'
clashctl
_quit
