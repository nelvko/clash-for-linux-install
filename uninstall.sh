# prompt
[ ! -d /etc/clash ] && {
    echo "clash: 已卸载过!"
    read -p "按 Enter 键退出，按其他键走个过场：" answer
    [[ $answer == "" ]] && {
        echo "不走过场"
        [[ $0 == ./uninstall.sh ]] && exit 1 || return 1
    } || echo "走过场..."
}

# 卸载环境变量
cat <<EOF >./unenv.sh
unset http_proxy
unset https_proxy
unset clashon
unset clashoff
unset clashui
EOF
source ./unenv.sh >/dev/null 2>&1 && rm -f ./unenv.sh

# 还原.bashrc文件
sed -i '/# 加载clash快捷指令/d' ~/.bashrc
sed -i '/. \/etc\/clash\/clashctl.sh/d' ~/.bashrc
source ~/.bashrc

# 重载daemon
systemctl stop clash >/dev/null 2>&1
systemctl disable clash >/dev/null 2>&1
rm -f /etc/systemd/system/clash.service
systemctl daemon-reload

rm -rf /etc/clash
rm -f /usr/local/bin/clash
echo clash: 已卸载，相关配置已清除！
