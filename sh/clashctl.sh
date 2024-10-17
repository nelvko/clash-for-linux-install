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
    ip=$(curl -s --noproxy "*" ifconfig.me)
    port=`awk '/external-controller/{print $NF}' /etc/clash/config.yaml | awk -F: '/.*:\d*/{print $NF}'`
    cat << EOF
clash: Web面板:
    ● 请注意放行 '$port 端口
    ● 地址1：http://$ip:9090/ui
    ● 地址2：https://clash.razord.top
EOF
}

function _is_valid() {
    grep -qs 'port' $CONFIG_PATH_NEW
}
function _download_config() {
    agent='Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:130.0) Gecko/20100101 Firefox/130.0'
    wget --timeout=3 --tries=1 --no-check-certificate --user-agent="$agent" -O $CONFIG_PATH_NEW "$1"
    _is_valid || \
    curl --connect-timeout 3 \
    --retry 1 \
    --user-agent "$agent" \
    -k -o $CONFIG_PATH_NEW $1
}


function clashupdate() {
    [ "$1" == "url" ] || [ "$1" == "" ] && {
        echo "错误：订阅链接必填"
        return 1
    }
    CONFIG_PATH='/etc/clash/config.yaml'
    CONFIG_PATH_NEW="${CONFIG_PATH}.clashupdate"
    _download_config $1
    _is_valid && {
        cat $CONFIG_PATH_NEW >$CONFIG_PATH
        systemctl restart clash
        echo 'clash: 配置更新成功，已重启生效'
    } || echo '错误：下载失败或配置无效！'
}