#!/bin/bash
. script/common.sh
. script/clashctl.sh
TEMP_CONFIG_PATH='./resource/config.yaml'
TEMP_CLASH_PATH='./resource/clash-linux-amd64-v3-2023.08.17.gz'
TEMP_UI_PATH='./resource/yacd.tar.xz'

_valid_env
[ -d "$CLASH_BASE_PATH" ] && _error_quit "已安装，如需重新安装请先执行卸载脚本"

gzip -dc "$TEMP_CLASH_PATH" >./resource/clash && chmod +x ./resource/clash
# shellcheck disable=SC2015
_valid_config "$TEMP_CONFIG_PATH" && echo '✅ 配置可用' || {
    read -r -p '😼 输入订阅链接：' URL
    _download_config "$URL" "$TEMP_CONFIG_PATH"
    _valid_config "$TEMP_CONFIG_PATH" || _error_quit "下载失败或配置无效: 请自行粘贴配置内容到 ${TEMP_CONFIG_PATH} 后再执行安装脚本"
}

mkdir -p "$CLASH_BASE_PATH"
/bin/mv -f ./resource/clash "$CLASH_BASE_PATH/clash"
/bin/cp -f "$TEMP_CONFIG_PATH" ./resource/Country.mmdb ./script/* "$CLASH_BASE_PATH"
tar -xf "$TEMP_UI_PATH" -C "$CLASH_BASE_PATH"
echo "source $CLASH_BASE_PATH/common.sh && source $CLASH_BASE_PATH/clashctl.sh" >>"$BASHRC_PATH"

# 服务配置文件
cat <<EOF >/etc/systemd/system/clash.service
[Unit]
Description=Clash 守护进程, Go 语言实现的基于规则的代理.
After=network-online.target

[Service]
Type=simple
Restart=always
ExecStart=${CLASH_BASE_PATH}/clash -d ${CLASH_BASE_PATH} -ext-ui public -ext-ctl 0.0.0.0:9090 -secret ''

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable clash >/dev/null 2>&1 && echo "😼 已设置开机自启" || echo "😾 设置自启失败"
clashon && clashui
