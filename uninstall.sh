systemctl stop clash
rm -rf /etc/clash
rm -f /etc/profile.d/clash.sh
source /etc/profile
rm -f /etc/systemd/system/clash.service
rm -f /usr/local/bin/clash
systemctl daemon-reload
echo clash已卸载，相关配置已清除！