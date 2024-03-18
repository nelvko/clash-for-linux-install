# clash快捷指令

function clashon() {
    cat <<EOF >/etc/clash/clashenv.sh
export http_proxy=http://127.0.0.1:7890
export https_proxy=http://127.0.0.1:7890
EOF
    source /etc/clash/clashenv.sh
    systemctl start clash && echo 'clash: 启动!' || echo 'clash: 启动失败: 执行 "systemctl status clash" 查看日志'
}

function clashoff() {
    cat <<EOF >/etc/clash/clashenv.sh
unset http_proxy
unset https_proxy
EOF
    source /etc/clash/clashenv.sh
    systemctl stop clash && echo 'clash: 成功关闭代理!' || echo 'clash: 关闭失败: 执行 "systemctl status clash" 查看日志'
}

function clashui() {
    source /etc/clash/ui.sh
}