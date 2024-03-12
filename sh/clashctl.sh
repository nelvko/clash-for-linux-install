
function clashon() {
    # 添加环境变量 设置代理
    cat << EOF > /etc/profile.d/clash.sh
export http_proxy=http://127.0.0.1:7890
export https_proxy=http://127.0.0.1:7890
EOF
    source /etc/profile.d/clash.sh
    systemctl start clash
    
}
function clashoff() {
    # 卸载环境变量
    cat << EOF > /etc/profile.d/clash.sh
unset http_proxy
unset https_proxy
EOF
    source /etc/profile.d/clash.sh
    systemctl stop clash
    
}
function clashui() {
    chmod +x /etc/clash/ui.sh && bash /etc/clash/ui.sh
}
