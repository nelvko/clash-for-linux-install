ip=$(curl -s ifconfig.cc | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b")

cat << EOF
clash 面板UI:
    ● 开放9090端口后使用
    ● 地址1：http://$ip:9090/ui
    ● 地址2：https://clash.razord.top
EOF
