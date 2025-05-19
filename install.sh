# shellcheck disable=SC2148
# shellcheck disable=SC1091
. script/common.sh >&/dev/null
. script/clashctl.sh >&/dev/null

_valid_env

[ -d "$CLASH_BASE_DIR" ] && _error_quit "请先执行卸载脚本,以清除安装路径：$CLASH_BASE_DIR"

_get_kernel

/bin/install -D <(gzip -dc "$ZIP_KERNEL") "${RESOURCES_BIN_DIR}/$BIN_KERNEL_NAME"
tar -xf "$ZIP_SUBCONVERTER" -C "$RESOURCES_BIN_DIR"
tar -xf "$ZIP_YQ" -C "${RESOURCES_BIN_DIR}"
# shellcheck disable=SC2086
/bin/mv -f ${RESOURCES_BIN_DIR}/yq_* "${RESOURCES_BIN_DIR}/yq"

_set_bin "$RESOURCES_BIN_DIR"
_valid_config "$RESOURCES_CONFIG" || {
    echo -n "$(_okcat '✈️ ' '输入订阅：')"
    read -r url
    _okcat '⏳' '正在下载...'
    _download_config "$RESOURCES_CONFIG" "$url" || _error_quit "下载失败: 请将配置内容写入 $RESOURCES_CONFIG 后重新安装"
    _valid_config "$RESOURCES_CONFIG" || _error_quit "配置无效，请检查配置：$RESOURCES_CONFIG，转换日志：$BIN_SUBCONVERTER_LOG"
}
_okcat '✅' '配置可用'
mkdir "$CLASH_BASE_DIR"
echo "$url" >"$CLASH_CONFIG_URL"

/bin/cp -rf "$SCRIPT_BASE_DIR" "$CLASH_BASE_DIR"
/bin/ls "$RESOURCES_BASE_DIR" | grep -Ev 'zip|png' | xargs -I {} /bin/cp -rf "${RESOURCES_BASE_DIR}/{}" "$CLASH_BASE_DIR"
tar -xf "$ZIP_UI" -C "$CLASH_BASE_DIR"

_set_rc
_set_bin
_merge_config_restart
. script/preflight.sh >&/dev/null
setup_init

clashui
_okcat '🎉' 'enjoy 🎉'
# clash
_quit
