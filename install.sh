#!/bin/bash
# shellcheck disable=SC1091
. script/common.sh
. script/clashctl.sh

_valid_env

[ -d "$CLASH_BASE_DIR" ] && _error_quit "请先执行卸载脚本,以清除安装路径：$CLASH_BASE_DIR"

_get_kernel
# shellcheck disable=SC2086
install -D -m +x <(gzip -dc $ZIP_KERNEL) "$BIN_KERNEL"
# shellcheck disable=SC2086
tar -xf $ZIP_SUBCONVERTER -C "$BIN_BASE_DIR"
# shellcheck disable=SC2086
tar -xf $ZIP_YQ -C "${BIN_BASE_DIR}" && install -m +x ${BIN_BASE_DIR}/yq_* "$BIN_YQ"

_valid_config "$RESOURCES_CONFIG" || {
    prompt=$(_okcat '✈️ ' '输入订阅链接：')
    read -p "$prompt" -r url
    _okcat '⏳' '正在下载...'
    # start=$(date +%s)>&/dev/null
    _download_config "$RESOURCES_CONFIG" "$url" || {
        rm -rf "$CLASH_BASE_DIR"
        _error_quit "下载失败: 请将配置内容写入 $RESOURCES_CONFIG 后重新安装"
    }
    _valid_config "$RESOURCES_CONFIG" || {
        rm -rf "$CLASH_BASE_DIR"
        _error_quit "配置无效，请检查：$RESOURCES_CONFIG"
    }
}
# end=$(date +%s) >&/dev/null
# _okcat '⌛' $((end-start))s
_okcat '✅' '配置可用'
echo "$url" >"$CLASH_CONFIG_URL"

/bin/cp -rf script "$CLASH_BASE_DIR"
/bin/ls "$RESOURCES_BASE_DIR" | grep -Ev 'zip|png' | xargs -I {} /bin/cp -rf "${RESOURCES_BASE_DIR}/{}" "$CLASH_BASE_DIR"
tar -xf "$ZIP_UI" -C "$CLASH_BASE_DIR"

_merge_config_restart

cat <<EOF >/etc/systemd/system/clash.service
[Unit]
Description=$BIN_KERNEL_NAME Daemon, A[nother] Clash Kernel.

[Service]
Type=simple
Restart=always
ExecStart=${BIN_KERNEL} -d ${CLASH_BASE_DIR} -f ${CLASH_CONFIG_RUNTIME}

[Install]
WantedBy=multi-user.target
EOF

[ -n "$(tail -1 "$BASHRC")" ] && echo >>"$BASHRC"
echo "source $CLASH_BASE_DIR/script/common.sh && source $CLASH_BASE_DIR/script/clashctl.sh" >>"$BASHRC"

systemctl daemon-reload
clashon
# shellcheck disable=SC2015
systemctl enable clash >&/dev/null && _okcat '🚀' "已设置开机自启" || _failcat '💥' "设置自启失败"
_okcat '🎉' 'enjoy 🎉'
clashui
clash
