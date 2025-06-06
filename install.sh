#!/usr/bin/env bash

# shellcheck disable=SC1091
. script/cmd/common.sh >&/dev/null
. script/cmd/clashctl.sh >&/dev/null
. script/preflight.sh >&/dev/null

_valid_env
_get_kernel "$@"
_get_init

[ -d "$CLASH_BASE_DIR" ] && _error_quit "请先执行卸载脚本,以清除安装路径：$CLASH_BASE_DIR"

_okcat "安装内核：$KERNEL_NAME by ${init_type:-$container}"

[ -z "$container" ] && {
    /usr/bin/install -D <(gzip -dc "$ZIP_KERNEL") "$BIN_KERNEL"
    tar -xf "$ZIP_YQ" -C "${BIN_BASE_DIR}"
    /bin/mv -f "${BIN_BASE_DIR}"/yq_* "${BIN_BASE_DIR}/yq"
    tar -xf "$ZIP_SUBCONVERTER" -C "$BIN_BASE_DIR"
    /bin/cp "$BIN_SUBCONVERTER_DIR/pref.example.yml" "$BIN_SUBCONVERTER_CONFIG"
}

[ -n "$container" ] && {
    _start_convert
}

_valid_config "$RESOURCES_CONFIG" || {
    echo -n "$(_okcat '✈️ ' '输入订阅：')"
    read -r url
    _okcat '⏳' '正在下载...'
    _download_config "$RESOURCES_CONFIG" "$url" || _error_quit "下载失败: 请将配置内容写入 $RESOURCES_CONFIG 后重新安装"
    _valid_config "$RESOURCES_CONFIG" || _error_quit "配置无效，请检查配置：$RESOURCES_CONFIG，转换日志：$BIN_SUBCONVERTER_LOG"
}
_okcat '✅' '配置可用'

mkdir -p /opt/clash
/bin/ls . | xargs -I {} /bin/cp -rf "$(pwd)/{}" "$CLASH_BASE_DIR"
tar -xf "$ZIP_UI" -C "$CLASH_RESOURCES_DIR"
echo "$url" >"$CLASH_CONFIG_URL"

_set_rc
_set_init
_merge_config

[ -n "$container" ] && {
    _get_proxy_port
    _get_ui_port
    docker-compose up -d
}

# clashui
_okcat '🎉' 'enjoy 🎉'
# clash
_quit
