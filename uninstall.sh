function quit() {
    echo $0 | grep -q install.sh && exit 1
}

[ $(whoami) != root ] && {
    echo "警告: 需要root权限运行!" && quit || return 1
}

[ ! -d /etc/clash ] && {
    echo "clash: has already been uninstalled"
    read -p "按 Enter 键退出，按其它键重新清除代理环境：" answer
    [ "$answer" == "" ] && {
        echo "已退出"
        [ "$0" == ./uninstall.sh ] && exit 1 || return 1
    } || echo "清除中..."
}

unset http_proxy
unset https_proxy
unset HTTP_PROXY
unset HTTPS_PROXY
unset clashon
unset clashoff
unset clashui

# 重载daemon
systemctl stop clash >/dev/null 2>&1
systemctl disable clash >/dev/null 2>&1
rm -f /etc/systemd/system/clash.service
systemctl daemon-reload

rm -rf /etc/clash/
rm -f /usr/local/bin/clash
sed -i '/source \/etc\/clash\/clashctl.sh/d' /etc/bashrc
sed -i '/clashupdate/d' /var/spool/cron/root
echo 'clash: 已卸载，相关配置已清除！'
bash

