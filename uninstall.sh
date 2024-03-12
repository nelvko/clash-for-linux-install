
# 卸载环境变量
cat << EOF > /etc/profile.d/clash.sh
unset http_proxy
unset https_proxy
unset clashon
unset clashoff
unset clashui
EOF
source /etc/profile.d/clash.sh
systemctl stop clash
rm -rf /etc/clash    
rm -f /etc/profile.d/clash*.sh
source /etc/profile

rm -f /etc/systemd/system/clash.service
rm -f /usr/local/bin/clash
systemctl daemon-reload
echo clash已卸载，相关配置已清除！