#!/bin/bash
# shellcheck disable=SC1091
. script/common.sh
. script/clashctl.sh

_valid_env
_get_kernel
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
        _download_convert_config "$RESOURCES_CONFIG" "$url"
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

_merge_config_restart >/dev/null

cat <<EOF >/etc/systemd/system/clash.service
[Unit]
Description=$(basename "$BIN_KERNEL") Daemon, A[nother] Clash Kernel.
After=network.target NetworkManager.service systemd-networkd.service iwd.service

[Service]
Type=simple
LimitNPROC=500
LimitNOFILE=1000000
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_TIME CAP_SYS_PTRACE CAP_DAC_READ_SEARCH CAP_DAC_OVERRIDE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_TIME CAP_SYS_PTRACE CAP_DAC_READ_SEARCH CAP_DAC_OVERRIDE
Restart=always
ExecStartPre=/usr/bin/sleep 1s
ExecStart=${BIN_KERNEL} -d ${CLASH_BASE_DIR} -f ${CLASH_CONFIG_RUNTIME}
ExecReload=/bin/kill -HUP $MAINPID

[Install]
WantedBy=multi-user.target
EOF

[ -n "$(tail -1 "$BASHRC")" ] && echo >> "$BASHRC"
echo "source $CLASH_BASE_DIR/script/common.sh && source $CLASH_BASE_DIR/script/clashctl.sh" >>"$BASHRC"

systemctl daemon-reload
clashon
# shellcheck disable=SC2015
systemctl enable clash >&/dev/null && _okcat "已设置开机自启" || _failcat "设置自启失败"
clashui
clash
