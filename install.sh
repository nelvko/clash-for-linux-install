#!/bin/bash

n1=$(wc -l < ./resource/config.yaml)
if [ $n1 -lt 0 ]; then
    read -p '订阅链接：' url
    wget --no-check-certificate --timeout=3 -qo ./resource/config.yaml $url
    n2=$(wc -l < ./resource/config.yaml)
    if [ $n2 -eq 0 ]; then
        echo "链接无效，自行粘贴配置到./resource/config.yaml"
    fi
fi

# gzip解压后不保留原文件
cp ./resource/clash-linux-amd64-v3-2023.08.17.gz ./clash_copy
# 解压
gzip -d ./resource/clash-linux-amd64-v3-2023.08.17.gz
# 可执行
mv ./resource/clash-linux-amd64-v3-2023.08.17 /usr/local/bin/clash && chmod +x /usr/local/bin/clash
mv ./clash_copy ./resource/clash-linux-amd64-v3-2023.08.17.gz

# clash配置目录
mkdir -p /etc/clash
tar -xf ./resource/yacd.tar.xz -C /etc/clash/
/bin/cp -f ./resource/config.yaml  /etc/clash/
/bin/cp -f ./resource/Country.mmdb /etc/clash/
/bin/cp -rf ./service/ /etc/clash/

# 创建服务配置文件
cat << EOF > /etc/systemd/system/clash.service
[Unit]
Description=Clash 守护进程, Go 语言实现的基于规则的代理.
After=network-online.target

[Service]
Type=simple
Restart=always
ExecStart=/etc/clash/service/ExecStart.sh
ExecStopPost=/etc/clash/service/ExecStopPost.sh

[Install]
WantedBy=multi-user.target
EOF

# 重新加载 systemd
systemctl daemon-reload

# 开机自启clash
systemctl enable clash
if [ $? -eq 0 ]; then
    echo "clash 设置自启成功!"
else
    echo "clash 设置自启失败!"
fi

# 启动clash服务
systemctl start clash
# 检查服务启动状态
if [ $? -eq 0 ]; then
    echo "clash 启动!"
else
    echo "clash 启动失败!"
fi

# ui面板
chmod +x ./ui.sh
bash ./ui.sh