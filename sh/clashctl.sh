# clash快捷指令
function clashon() {
    addr=http://127.0.0.1:7890
    export http_proxy=$addr
    export https_proxy=$addr
    export HTTP_PROXY=$addr
    export HTTPS_PROXY=$addr
    systemctl start clash && echo 'clash: 已开启代理环境！' || echo 'clash: 启动失败: 执行 "systemctl status clash" 查看日志'
}

function clashoff() {
    unset http_proxy
    unset https_proxy
    unset HTTP_PROXY
    unset HTTPS_PROXY
    systemctl stop clash && echo 'clash: 已关闭代理环境!' || echo 'clash: 关闭失败: 执行 "systemctl status clash" 查看日志'
}

function clashui() {
    # 查询公网ip
    # ifconfig.me
    # cip.cc
    ip=$(curl -s ifconfig.me)
    cat << EOF
clash: Web面板:
    ● 开放9090端口后使用
    ● 地址1：http://$ip:9090/ui
    ● 地址2：https://clash.razord.top
EOF
}

function clashupdate() {
    [ "$1" = "url" ] && return 1
    CONFIG_PATH='/etc/clash/config.yaml'
    wget --tries=1 --timeout=3 --user-agent='Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:130.0) Gecko/20100101 Firefox/130.0' --no-check-certificate -O $CONFIG_PATH "$1" || \
    curl --user-agent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:130.0) Gecko/20100101 Firefox/130.0' -k -o $CONFIG_PATH $1
}