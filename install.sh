#!/bin/bash
# define
CONFIG_PATH='./resource/config.yaml'
CLASH_PATH='./resource/clash-linux-amd64-v3-2023.08.17.gz'
UI_PATH='./resource/yacd.tar.xz'
function quit() {
    echo $0 | grep -q install.sh && exit 1
}
function is_valid() {
    grep -q 'port' $CONFIG_PATH
}
function download_config() {
    agent='Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:130.0) Gecko/20100101 Firefox/130.0'
    wget --timeout=3 --tries=1 --no-check-certificate --user-agent="$agent" -O $CONFIG_PATH "$1"
    is_valid || \
    curl --connect-timeout 3 \
         --retry 1 \
         --user-agent "$agent" \
         -k -o $CONFIG_PATH $1
}

# begin
[ $(whoami) != root ] && {
    echo "警告: 需要root权限!" && quit || return 1
}

[ -d /etc/clash ] && {
    echo "clash: 已安装，如需重新安装请先执行卸载脚本" && quit || return 1
}

is_valid && echo '配置可用√' || {
    read -p '输入订阅链接：' url
    download_config $url
    is_valid || echo "配置无效或下载失败: 自行粘贴配置内容到 ${CONFIG_PATH} 并重新运行" && quit || return 1
}
echo -------------------------

gzip -dc $CLASH_PATH >./clash && chmod +x ./clash
/usr/bin/mv -f ./clash /usr/local/bin/clash

# clash配置目录
mkdir -p /etc/clash
tar -xf $UI_PATH -C /etc/clash/
/bin/cp -f $CONFIG_PATH /etc/clash/
/bin/cp -f ./resource/Country.mmdb /etc/clash/
/bin/cp -f ./sh/clashctl.sh /etc/clash/

echo 'source /etc/clash/clashctl.sh' >>/etc/bashrc
source /etc/clash/clashctl.sh
# 定时任务：更新配置
echo '0 0 */2 * * . /etc/bashrc;clashupdate url' >>/var/spool/cron/root
# 服务配置文件
cat <<EOF >/etc/systemd/system/clash.service
[Unit]
Description=Clash 守护进程, Go 语言实现的基于规则的代理.
After=network-online.target

[Service]
Type=simple
Restart=always
ExecStart=/usr/local/bin/clash -d /etc/clash -ext-ui public -ext-ctl 0.0.0.0:9090

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload

systemctl enable clash >/dev/null 2>&1 && echo "clash: 设置自启成功!" || echo "clash: 设置自启失败!"

clashui && clashon
bash
