ip=$(curl -s ifconfig.cc | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b")

# 输出变量中的IP地址
echo "clash面板地址：http://$ip:9090/ui"
