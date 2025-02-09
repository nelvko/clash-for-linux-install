#!/bin/bash
# shellcheck disable=SC2015
# shellcheck disable=SC1091
# shellcheck disable=SC2086
. script/common.sh
. script/clashctl.sh

_valid_env
_get_os

[ -d "$CLASH_BASE_DIR" ] && _error_quit "已安装，如需重新安装请先执行卸载脚本"

gzip -dc $TEMP_CLASH_ZIP >"${TEMP_TOOL_DIR}/clash" && chmod +x "${TEMP_TOOL_DIR}/clash"
tar -xf $TEMP_CONVERT_ZIP -C "$TEMP_TOOL_DIR"
_valid_config "$TEMP_CONFIG" && echo '✅ 配置可用' || {
    read -r -p '😼 输入订阅链接：' url
    _download_config "$url" "$TEMP_CONFIG" || _error_quit "下载失败: 请自行粘贴配置内容到 ${TEMP_CONFIG} 后再执行安装脚本"
    _valid_config "$TEMP_CONFIG" || {
        _failcat "配置无效：尝试在本地进行订阅转换..."
        _convert_config
    }
}
mkdir -p "$CLASH_BASE_DIR"
echo "$url" >"$CLASH_CONFIG_URL"
/bin/cp -rf script "$CLASH_BASE_DIR"
/bin/ls resource | grep -Ev 'zip|png' | xargs -I {} /bin/cp -rf "resource/{}" "$CLASH_BASE_DIR"
tar -xf "$TEMP_UI_ZIP" -C "$CLASH_BASE_DIR"
tar -xf $TEMP_YQ_ZIP -C "${TEMP_TOOL_DIR}" && install -m +x ${TEMP_TOOL_DIR}/yq_* "$TOOL_YQ"

_mark_raw
_concat_config_restart >&/dev/null

cat <<EOF >/etc/systemd/system/clash.service
[Unit]
Description=Clash 守护进程, Go 语言实现的基于规则的代理.
After=network-online.target

[Service]
Type=simple
Restart=always
ExecStart=${TOOL_CLASH} -d ${CLASH_BASE_DIR} -f ${CLASH_CONFIG_RUNTIME} -ext-ui public -secret ''

[Install]
WantedBy=multi-user.target
EOF

echo "source $CLASH_BASE_DIR/script/common.sh && source $CLASH_BASE_DIR/script/clashctl.sh" >>"$BASHRC"
systemctl daemon-reload
systemctl enable clash >&/dev/null && _okcat "已设置开机自启" || _failcat "设置自启失败"
clashon && clashui
clash
