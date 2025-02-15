#!/bin/bash
# shellcheck disable=SC1091
. script/common.sh
. script/clashctl.sh

_valid_env
_get_os

[ -d "$CLASH_BASE_DIR" ] && _error_quit "已安装，如需重新安装请先执行卸载脚本"

# shellcheck disable=SC2086
install -D -m +x  <(gzip -dc $ZIP_KERNEL) $BIN_KERNEL
# shellcheck disable=SC2086
tar -xf $ZIP_CONVERT -C "$BIN_BASE_DIR"
_valid_config "$RESOURCES_CONFIG" || {
    read -r -p '😼 输入订阅链接：' url
    _download_config "$url" "$RESOURCES_CONFIG" || _error_quit "下载失败: 请自行粘贴配置内容到 ${RESOURCES_CONFIG} 后再执行安装脚本"
    _valid_config "$RESOURCES_CONFIG" || {
        _failcat "配置无效：尝试进行本地订阅转换..."
        _download_convert_config "$RESOURCES_CONFIG"
        _valid_config "$RESOURCES_CONFIG" || _error_quit '配置无效：请检查配置内容'
    }
}
echo '✅ 配置可用'
echo "$url" >"$CLASH_CONFIG_URL"

/bin/cp -rf script "$CLASH_BASE_DIR"
/bin/ls "$RESOURCES_BASE_DIR" | grep -Ev 'zip|png' | xargs -I {} /bin/cp -rf "${RESOURCES_BASE_DIR}/{}" "$CLASH_BASE_DIR"
tar -xf "$ZIP_UI" -C "$CLASH_BASE_DIR"
# shellcheck disable=SC2086
tar -xf $ZIP_YQ -C "${BIN_BASE_DIR}" && install -m +x ${BIN_BASE_DIR}/yq_* "$BIN_YQ"

_merge_config_restart

cat <<EOF >/etc/systemd/system/clash.service
[Unit]
Description=Clash 守护进程, Go 语言实现的基于规则的代理.
After=network-online.target

[Service]
Type=simple
Restart=always
ExecStart=${BIN_CLASH} -d ${CLASH_BASE_DIR} -f ${CLASH_CONFIG_RUNTIME}

[Install]
WantedBy=multi-user.target
EOF

echo "source $CLASH_BASE_DIR/script/common.sh && source $CLASH_BASE_DIR/script/clashctl.sh" >>"$BASHRC"
systemctl daemon-reload
# shellcheck disable=SC2015
systemctl enable clash >&/dev/null && _okcat "已设置开机自启" || _failcat "设置自启失败"
clashon && clashui
clash
