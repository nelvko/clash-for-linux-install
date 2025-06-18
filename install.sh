#!/usr/bin/env bash

# shellcheck disable=SC1091
. script/cmd/clashctl.sh
. script/preflight.sh

_valid_env
_get_kernel "$@"

[ -z "$CONTAINER_TYPE" ] && _get_init

[ -d "$CLASH_BASE_DIR" ] && _error_quit "请先执行卸载脚本,以清除安装路径：$CLASH_BASE_DIR"

_okcat "安装内核：$KERNEL_NAME by ${INIT_TYPE:-$CONTAINER_TYPE}"

_set_bin
_valid_config "$(pwd)/$RESOURCES_CONFIG" || {
    echo -n "$(_okcat '✈️ ' '输入订阅：')"
    read -r url
    _okcat '⏳' '正在下载...'
    _download_config "$(pwd)/$RESOURCES_CONFIG" "$url" || _error_quit "下载失败: 请将配置内容写入 $RESOURCES_CONFIG 后重新安装"
    _valid_config "$(pwd)/$RESOURCES_CONFIG" || _error_quit "配置无效，请检查配置：$RESOURCES_CONFIG，转换日志：$BIN_SUBCONVERTER_LOG"
}
_okcat '✅' '配置可用'

mkdir -p "$CLASH_BASE_DIR"
/bin/cp -rf . "$CLASH_BASE_DIR"
_set_env CLASH_CONFIG_URL "$url"
[ -n "$*" ] && {
    _set_env CONTAINER_TYPE "$CONTAINER_TYPE"
    _set_env KERNEL_NAME "$KERNEL_NAME"
}

tar -xf "$ZIP_UI" -C "$CLASH_RESOURCES_DIR"

sed -i "/\$placeholder_bin/{
    r /dev/stdin
    d
}" "$CLASH_CMD_DIR/common.sh" <<<"$bin_var"
_set_rc

[ -n "$INIT_TYPE" ] && _set_init
[ -n "$CONTAINER_TYPE" ] && _set_container

_merge_config

clashui
_okcat '🎉' 'enjoy 🎉'
clash
_quit
