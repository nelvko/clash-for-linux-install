#!/bin/bash
. script/common.sh
. script/clashctl.sh

_valid_env
[ -d "$CLASH_BASE_PATH" ] && _error_quit "已安装，如需重新安装请先执行卸载脚本"

gzip -dc "$TEMP_CLASH_PATH" >./resource/clash && chmod +x ./resource/clash
# shellcheck disable=SC2015
_valid_config "$TEMP_CONFIG_PATH" && echo '✅ 配置可用' || {
    read -r -p '😼 输入订阅链接：' url
    echo "$url" > resource/url
    _download_config "$url" "$TEMP_CONFIG_PATH" || _error_quit "下载失败: 请自行粘贴配置内容到 ${TEMP_CONFIG_PATH} 后再执行安装脚本"
    _valid_config "$TEMP_CONFIG_PATH" || _error_quit "配置无效：请检查配置内容"
}

mkdir -p "$CLASH_BASE_PATH"
/bin/mv -f ./resource/clash "$CLASH_BASE_PATH/clash"
/bin/cp -rf ./resource/* ./script/* "$CLASH_BASE_PATH"
tar -xf "$TEMP_UI_PATH" -C "$CLASH_BASE_PATH"
echo "source $CLASH_BASE_PATH/common.sh && source $CLASH_BASE_PATH/clashctl.sh" >>"$BASHRC_PATH"
cat "${CLASH_CONFIG_RAW_PATH}" >"${CLASH_CONFIG_MIXIN_PATH}"
sed -i -e '1i\# raw-config-start\n' -e '$a\# raw-config-end\n' "${CLASH_CONFIG_MIXIN_PATH}"

cat <<EOF >/etc/systemd/system/clash.service
[Unit]
Description=Clash 守护进程, Go 语言实现的基于规则的代理.
After=network-online.target

[Service]
Type=simple
Restart=always
ExecStart=${CLASH_BASE_PATH}/clash -d ${CLASH_BASE_PATH} -f ${CLASH_CONFIG_MIXIN_PATH} -ext-ui public -ext-ctl 0.0.0.0:9090 -secret ''

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable clash >/dev/null 2>&1 && _okcat "已设置开机自启" || _failcat "设置自启失败"
clashon && clashui
