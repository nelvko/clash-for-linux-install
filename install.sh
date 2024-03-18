#!/bin/bash

[[ $(whoami) != root ]] && {
    echo "警告: 需要root用户运行!"
    [[ $0 == ./install.sh ]] && exit 1 || return 1
}

[ -d /etc/clash ] && {
    echo "clash: 已安装过!"
    read -p "按 Enter 键覆盖安装，按其他键退出：" answer
    [[ $answer == "" ]] && echo "开始覆盖安装 clash..." || {
        echo "退出安装"
        [[ $0 == ./install.sh ]] && exit 1 || return 1
    }
}

config='./resource/config.yaml'
clash_zip='./resource/clash-linux-amd64-v3-2023.08.17.gz'
ui_zip='./resource/yacd.tar.xz'

is_valid() {
    grep 'port' $config >/dev/null 2>&1
}
invalid() {
    echo "配置无效: 自行粘贴配置到$config" && [[ $0 == ./install.sh ]] && exit 1 || return 0
}

if [ ! -f $config ]; then
    read -p '订阅链接：' url
    if wget --tries=1 --timeout=3 --no-check-certificate -O $config "$url" && is_valid; then
        echo 配置可用√
    else
        touch $config && invalid && return 1
    fi
else
    is_valid || { invalid && return 1; }
fi

gzip -dc $clash_zip >./clash && chmod +x ./clash
/usr/bin/mv -f ./clash /usr/local/bin/clash

# clash配置目录
mkdir -p /etc/clash
tar -xf $ui_zip -C /etc/clash/
/bin/cp -f $config /etc/clash/
/bin/cp -f ./resource/Country.mmdb /etc/clash/
/bin/cp -f ./sh/ui.sh /etc/clash/
/bin/cp -f ./sh/clashctl.sh /etc/clash/

grep clashctl ~/.bashrc >/dev/null 2>&1 || cat <<EOF >>~/.bashrc
# 加载clash快捷指令
. /etc/clash/clashctl.sh
EOF
source ~/.bashrc

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

clashon && clashui
