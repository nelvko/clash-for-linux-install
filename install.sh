#!/usr/bin/env bash

# shellcheck disable=SC1091
. script/cmd/clashctl.sh
. script/preflight.sh

_valid_env

[ -d "$CLASH_BASE_DIR" ] && _error_quit "请先执行卸载脚本,以清除安装路径：$CLASH_BASE_DIR"
mkdir -p "$CLASH_BASE_DIR" || _error_quit "无写入权限：$CLASH_BASE_DIR，请前往 .env 文件更换安装路径"

_get_kernel "$@"
_set_bin
[ -z "$CONTAINER_TYPE" ] && _get_init


_okcat "安装内核：$KERNEL_NAME by ${INIT_TYPE:-$CONTAINER_TYPE}"

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

mkdir -p "$CLASH_BASE_DIR"
/bin/cp -rf . "$CLASH_BASE_DIR"
tar -xf "$ZIP_UI" -C "$CLASH_RESOURCES_DIR"
_set_env CLASH_CONFIG_URL "$CLASH_CONFIG_URL"
_merge_config

[ -n "$*" ] && {
    _set_env CONTAINER_TYPE "$CONTAINER_TYPE"
    _set_env KERNEL_NAME "$KERNEL_NAME"
    _set_env IMAGE_KERNEL "$IMAGE_KERNEL"
}

sed -i "/\$placeholder_bin/{
    r /dev/stdin
    d
}" "$CLASH_CMD_DIR/common.sh" <<<"$bin_var"
_set_rc

[ -n "$INIT_TYPE" ] && _set_init
[ -n "$CONTAINER_TYPE" ] && _set_container

clashui
_okcat '🎉' 'enjoy 🎉'
clash
_quit
