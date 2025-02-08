#!/bin/bash
# shellcheck disable=SC2015
# shellcheck disable=SC1091
. script/common.sh
. script/clashctl.sh

_valid_env

[ -d "$CLASH_BASE_DIR" ] && _error_quit "已安装，如需重新安装请先执行卸载脚本"

# shellcheck disable=SC2086
gzip -dc $TEMP_CLASH_RAR >"${TEMP_RESOURCE}/clash" && chmod +x "${TEMP_RESOURCE}/clash"
tar -xf $TEMP_CONVERT_RAR -C "$TEMP_RESOURCE"
_valid_config "$TEMP_CONFIG" && echo '✅ 配置可用' || {
    read -r -p '😼 输入订阅链接：' url
    _download_config "$url" "$TEMP_CONFIG" || _error_quit "下载失败: 请自行粘贴配置内容到 ${TEMP_CONFIG} 后再执行安装脚本"
    _valid_config "$TEMP_CONFIG" || {
        _failcat "配置无效：将在本地转换订阅后重试..."
        retry_convert
    }
}
mkdir -p "$CLASH_BASE_DIR"
echo "$url" >"$CLASH_CONFIG_URL"
/bin/cp -rf script "$CLASH_BASE_DIR"
/bin/ls resource | grep -Ev 'gz|png|xz' | xargs -I {} /bin/cp -rf "resource/{}" "$CLASH_BASE_DIR"
tar -xf "$TEMP_UI_RAR" -C "$CLASH_BASE_DIR"
# shellcheck disable=SC2086
/bin/cp -f $TEMP_YQ_BIN "$YQ_BIN" && chmod +x "$YQ_BIN"

_mark_raw
_concat_config_restart >&/dev/null

cat <<EOF >/etc/systemd/system/clash.service
[Unit]
Description=Clash 守护进程, Go 语言实现的基于规则的代理.
After=network-online.target

[Service]
Type=simple
Restart=always
ExecStart=${CLASH_BASE_DIR}/clash -d ${CLASH_BASE_DIR} -f ${CLASH_CONFIG_RUNTIME} -ext-ui public -secret ''

[Install]
WantedBy=multi-user.target
EOF

echo "source $CLASH_BASE_DIR/script/common.sh && source $CLASH_BASE_DIR/script/clashctl.sh" >>"$BASHRC"
systemctl daemon-reload
systemctl enable clash >/dev/null 2>&1 && _okcat "已设置开机自启" || _failcat "设置自启失败"
clashon && clashui
clash
