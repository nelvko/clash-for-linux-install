#!/bin/bash

# 环境变量 设置代理
cat << EOF > /etc/profile.d/clash.sh
export http_proxy=http://127.0.0.1:7890
export https_proxy=http://127.0.0.1:7890
EOF
source /etc/profile.d/clash.sh

# clash 启动！
/usr/local/bin/clash -d /etc/clash -ext-ui public