#!/usr/bin/env fish

# 变量定义
set CLASH_BASE_DIR '/opt/clash'
set CLASH_CONFIG_RAW "$CLASH_BASE_DIR/config.yaml"
set CLASH_CONFIG_RAW_BAK "$CLASH_CONFIG_RAW.bak"
set CLASH_CONFIG_MIXIN "$CLASH_BASE_DIR/mixin.yaml"
set CLASH_CONFIG_RUNTIME "$CLASH_BASE_DIR/runtime.yaml"
set CLASH_CONFIG_URL "$CLASH_BASE_DIR/url"
set CLASH_UPDATE_LOG "$CLASH_BASE_DIR/clashupdate.log"
set URL_CLASH_UI "http://board.zash.run.place"

# 设置定时任务路径
if test -f /etc/os-release
    set os_info (cat /etc/os-release)
    if echo "$os_info" | grep -iqsE "rhel|centos"
        set CLASH_CRON_TAB "/var/spool/cron/$USER"
    else if echo "$os_info" | grep -iqsE "debian|ubuntu"
        set CLASH_CRON_TAB "/var/spool/cron/crontabs/$USER"
    else
        set CLASH_CRON_TAB "/var/spool/cron/$USER"
    end
else
    # 默认路径（适用于 macOS 等系统）
    set CLASH_CRON_TAB "/var/spool/cron/$USER"
end

# 设置二进制文件路径
function _set_bin_vars
    set bin_base_dir "$CLASH_BASE_DIR/bin"
    set -g BIN_CLASH "$bin_base_dir/clash"
    set -g BIN_MIHOMO "$bin_base_dir/mihomo"
    set -g BIN_YQ "$bin_base_dir/yq"
    set -g BIN_SUBCONVERTER_DIR "$bin_base_dir/subconverter"
    set -g BIN_SUBCONVERTER_CONFIG "$BIN_SUBCONVERTER_DIR/pref.yml"
    set -g BIN_SUBCONVERTER_PORT "25500"
    set -g BIN_SUBCONVERTER "$BIN_SUBCONVERTER_DIR/subconverter"
    set -g BIN_SUBCONVERTER_LOG "$BIN_SUBCONVERTER_DIR/latest.log"

    if test -f "$BIN_CLASH"
        set -g BIN_KERNEL $BIN_CLASH
    end
    if test -f "$BIN_MIHOMO"
        set -g BIN_KERNEL $BIN_MIHOMO
    end
    set -g BIN_KERNEL_NAME (basename "$BIN_KERNEL")
end
_set_bin_vars

# 工具函数
function _get_color
    set hex (string replace '#' '' $argv[1])
    set r (math "0x"(string sub --length 2 "$hex"))
    set g (math "0x"(string sub --start 3 --length 2 "$hex"))
    set b (math "0x"(string sub --start 5 --length 2 "$hex"))
    printf "\e[38;2;%d;%d;%dm" "$r" "$g" "$b"
end

function _get_color_msg
    set color (_get_color "$argv[1]")
    set msg $argv[2]
    set reset "\033[0m"
    printf "%b%s%b\n" "$color" "$msg" "$reset"
end

function _okcat
    set color '#c8d6e5'
    set emoji '😼'
    if test (count $argv) -gt 1
        set emoji $argv[1]
        set -e argv[1]
    end
    set msg "$emoji $argv[1]"
    _get_color_msg "$color" "$msg"
    return 0
end

function _failcat
    set color '#fd79a8'
    set emoji '😾'
    if test (count $argv) -gt 1
        set emoji $argv[1]
        set -e argv[1]
    end
    set msg "$emoji $argv[1]"
    _get_color_msg "$color" "$msg" >&2
    return 1
end

function _error_quit
    if test (count $argv) -gt 0
        set color '#f92f60'
        set emoji '📢'
        if test (count $argv) -gt 1
            set emoji $argv[1]
            set -e argv[1]
        end
        set msg "$emoji $argv[1]"
        _get_color_msg "$color" "$msg"
    end
    exec fish -i
end

function _is_root
    test (whoami) = "root"
end

function _is_bind
    set port $argv[1]
    if sudo ss -lnptu >/dev/null 2>&1
        sudo ss -lnptu | grep ":$port\b"
    else
        sudo netstat -lnptu | grep ":$port\b"
    end
end

function _is_already_in_use
    set port $argv[1]
    set progress $argv[2]
    _is_bind "$port" | grep -qs -v "$progress"
end

function _get_random_port
    set randomPort (shuf -i 1024-65535 -n 1)
    if not _is_bind "$randomPort"
        echo "$randomPort"
        return
    end
    _get_random_port
end

function _get_proxy_port
    set mixed_port (sudo "$BIN_YQ" '.mixed-port // ""' $CLASH_CONFIG_RUNTIME)
    if test -z "$mixed_port"
        set -g MIXED_PORT 7890
    else
        set -g MIXED_PORT $mixed_port
    end

    if _is_already_in_use "$MIXED_PORT" "$BIN_KERNEL_NAME"
        set newPort (_get_random_port)
        set msg "端口占用：$MIXED_PORT 🎲 随机分配：$newPort"
        sudo "$BIN_YQ" -i ".mixed-port = $newPort" $CLASH_CONFIG_RUNTIME
        set -g MIXED_PORT $newPort
        _failcat '🎯' "$msg"
    end
end

function _get_ui_port
    set ext_addr (sudo "$BIN_YQ" '.external-controller // ""' $CLASH_CONFIG_RUNTIME)
    set ext_port (string split ':' "$ext_addr")[-1]
    if test -z "$ext_port"
        set -g UI_PORT 9090
    else
        set -g UI_PORT $ext_port
    end

    if _is_already_in_use "$UI_PORT" "$BIN_KERNEL_NAME"
        set newPort (_get_random_port)
        set msg "端口占用：$UI_PORT 🎲 随机分配：$newPort"
        sudo "$BIN_YQ" -i ".external-controller = \"0.0.0.0:$newPort\"" $CLASH_CONFIG_RUNTIME
        set -g UI_PORT $newPort
        _failcat '🎯' "$msg"
    end
end

function _valid_config
    if test -e "$argv[1]"; and test (wc -l <"$argv[1]") -gt 1
        set cmd "$BIN_KERNEL -d "(dirname "$argv[1]")" -f $argv[1] -t"
        set msg (eval "$cmd" 2>&1)
        if test $status -ne 0
            eval "$cmd"
            if echo "$msg" | grep -qs "unsupport proxy type"
                set prefix "检测到订阅中包含不受支持的代理协议"
                if test "$BIN_KERNEL_NAME" = "clash"
                    _error_quit "$prefix, 推荐安装使用 mihomo 内核"
                end
                _error_quit "$prefix, 请检查并升级内核版本"
            end
        end
    end
end

function _download_raw_config
    set dest $argv[1]
    set url $argv[2]
    set agent 'clash-verge/v2.0.4'
    if sudo curl \
        --silent \
        --show-error \
        --insecure \
        --connect-timeout 4 \
        --retry 1 \
        --user-agent "$agent" \
        --output "$dest" \
        "$url"
    else
        sudo wget \
            --no-verbose \
            --no-check-certificate \
            --timeout 3 \
            --tries 1 \
            --user-agent "$agent" \
            --output-document "$dest" \
            "$url"
    end
end

function _start_convert
    if _is_already_in_use $BIN_SUBCONVERTER_PORT 'subconverter'
        set newPort (_get_random_port)
        _failcat '🎯' "端口占用：$BIN_SUBCONVERTER_PORT 🎲 随机分配：$newPort"
        if not test -e "$BIN_SUBCONVERTER_CONFIG"
            sudo /bin/cp -f "$BIN_SUBCONVERTER_DIR/pref.example.yml" "$BIN_SUBCONVERTER_CONFIG"
        end
        sudo "$BIN_YQ" -i ".server.port = $newPort" "$BIN_SUBCONVERTER_CONFIG"
        set -g BIN_SUBCONVERTER_PORT $newPort
    end
    set start (date +%s)
    sudo "$BIN_SUBCONVERTER" 2>&1 | sudo tee "$BIN_SUBCONVERTER_LOG" >/dev/null &
    while not _is_bind "$BIN_SUBCONVERTER_PORT" >/dev/null 2>&1
        sleep 1s
        set now (date +%s)
        if test (math "$now - $start") -gt 1
            _error_quit "订阅转换服务未启动，请检查日志：$BIN_SUBCONVERTER_LOG"
        end
    end
end

function _stop_convert
    pkill -9 -f "$BIN_SUBCONVERTER" >/dev/null 2>&1
end

function _download_convert_config
    set dest $argv[1]
    set url $argv[2]
    _start_convert
    set target 'clash'
    set base_url "http://127.0.0.1:$BIN_SUBCONVERTER_PORT/sub"
    set convert_url (curl \
        --get \
        --silent \
        --output /dev/null \
        --data-urlencode "target=$target" \
        --data-urlencode "url=$url" \
        --write-out '%{url_effective}' \
        "$base_url")
    _download_raw_config "$dest" "$convert_url"
    _stop_convert
end

function _download_config
    set dest $argv[1]
    set url $argv[2]
    if test (string sub --length 4 "$url") = 'file'
        return 0
    end
    if not _download_raw_config "$dest" "$url"
        return 1
    end
    _okcat '🍃' '下载成功：内核验证配置...'
    if not _valid_config "$dest"
        _failcat '🍂' "验证失败：尝试订阅转换..."
        if not _download_convert_config "$dest" "$url"
            _failcat '🍂' "转换失败：请检查日志：$BIN_SUBCONVERTER_LOG"
        end
    end
end

# 核心功能函数

function _set_system_proxy
    set auth (sudo "$BIN_YQ" '.authentication[0] // ""' "$CLASH_CONFIG_RUNTIME")
    if test -n "$auth"
        set auth "$auth@"
    end

    set http_proxy_addr "http://$auth"127.0.0.1:"$MIXED_PORT"
    set socks_proxy_addr "socks5h://$auth"127.0.0.1:"$MIXED_PORT"
    set no_proxy_addr "localhost,127.0.0.1,::1"

    set -gx http_proxy $http_proxy_addr
    set -gx https_proxy $http_proxy
    set -gx HTTP_PROXY $http_proxy
    set -gx HTTPS_PROXY $http_proxy

    set -gx all_proxy $socks_proxy_addr
    set -gx ALL_PROXY $all_proxy

    set -gx no_proxy $no_proxy_addr
    set -gx NO_PROXY $no_proxy

    sudo "$BIN_YQ" -i '.system-proxy.enable = true' "$CLASH_CONFIG_MIXIN"
end

function _unset_system_proxy
    set -e http_proxy
    set -e https_proxy
    set -e HTTP_PROXY
    set -e HTTPS_PROXY
    set -e all_proxy
    set -e ALL_PROXY
    set -e no_proxy
    set -e NO_PROXY

    sudo "$BIN_YQ" -i '.system-proxy.enable = false' "$CLASH_CONFIG_MIXIN"
end

function clashon
    _get_proxy_port
    if not systemctl is-active "$BIN_KERNEL_NAME" >/dev/null 2>&1
        if not sudo systemctl start "$BIN_KERNEL_NAME" >/dev/null
            _failcat '启动失败: 执行 clashstatus 查看日志'
            return 1
        end
    end
    _set_system_proxy
    _okcat '已开启代理环境'
end

function watch_proxy
    # 新开交互式shell，且无代理变量时
    if test -z "$http_proxy"; and status is-interactive
        # root用户自动开启代理环境（普通用户会触发sudo验证密码导致卡住）
        if _is_root
            clashon
        end
    end
end

function clashoff
    if sudo systemctl stop "$BIN_KERNEL_NAME"
        _okcat '已关闭代理环境'
    else
        _failcat '关闭失败: 执行 "clashstatus" 查看日志'
        return 1
    end
    _unset_system_proxy
end

function clashrestart
    clashoff >/dev/null 2>&1; and clashon >/dev/null 2>&1
end

function clashproxy
    switch $argv[1]
        case on
            if not systemctl is-active "$BIN_KERNEL_NAME" >/dev/null 2>&1
                _failcat '代理程序未运行，请执行 clashon 开启代理环境'
                return 1
            end
            _set_system_proxy
            _okcat '已开启系统代理'
        case off
            _unset_system_proxy
            _okcat '已关闭系统代理'
        case status
            set system_proxy_status (sudo "$BIN_YQ" '.system-proxy.enable' "$CLASH_CONFIG_MIXIN" 2>/dev/null)
            if test "$system_proxy_status" = "false"
                _failcat "系统代理：关闭"
                return 1
            end
            _okcat "系统代理：开启
http_proxy： $http_proxy
socks_proxy：$all_proxy"
        case '*'
            echo '用法: clashproxy [on|off|status]
    on      开启系统代理
    off     关闭系统代理
    status  查看系统代理状态'
    end
end

function clashstatus
    sudo systemctl status "$BIN_KERNEL_NAME" $argv
end

function clashui
    _get_ui_port
    # 公网ip
    # ifconfig.me
    set query_url 'api64.ipify.org'
    set public_ip (curl -s --noproxy "*" --connect-timeout 2 $query_url)
    if test -z "$public_ip"
        set public_ip "公网"
    end
    set public_address "http://$public_ip:$UI_PORT/ui"
    # 内网ip
    # ip route get 1.1.1.1 | grep -oP 'src \K\S+'
    set local_ip (hostname -I | awk '{print $1}')
    set local_address "http://$local_ip:$UI_PORT/ui"
    printf "\n"
    printf "╔═══════════════════════════════════════════════╗\n"
    printf "║                %s                  ║\n" "$(_okcat 'Web 控制台')"
    printf "║═══════════════════════════════════════════════║\n"
    printf "║                                               ║\n"
    printf "║     🔓 注意放行端口：%-5s                    ║\n" "$UI_PORT"
    printf "║     🏠 内网：%-31s  ║\n" "$local_address"
    printf "║     🌏 公网：%-31s  ║\n" "$public_address"
    printf "║     ☁️  公共：%-31s  ║\n" "$URL_CLASH_UI"
    printf "║                                               ║\n"
    printf "╚═══════════════════════════════════════════════╝\n"
    printf "\n"
end

function _merge_config_restart
    set backup "/tmp/rt.backup"
    sudo cat "$CLASH_CONFIG_RUNTIME" 2>/dev/null | sudo tee $backup >/dev/null 2>&1
    sudo "$BIN_YQ" eval-all '. as $item ireduce ({}; . *+ $item) | (.. | select(tag == "!!seq")) |= unique' \
        "$CLASH_CONFIG_MIXIN" "$CLASH_CONFIG_RAW" "$CLASH_CONFIG_MIXIN" | sudo tee "$CLASH_CONFIG_RUNTIME" >/dev/null 2>&1
    if not _valid_config "$CLASH_CONFIG_RUNTIME"
        sudo cat $backup | sudo tee "$CLASH_CONFIG_RUNTIME" >/dev/null 2>&1
        _error_quit "验证失败：请检查 Mixin 配置"
    end
    clashrestart
end

function clashsecret
    switch (count $argv)
        case 0
            _okcat "当前密钥："(sudo "$BIN_YQ" '.secret // ""' "$CLASH_CONFIG_RUNTIME")
        case 1
            if sudo "$BIN_YQ" -i ".secret = \"$argv[1]\"" "$CLASH_CONFIG_MIXIN"
                _merge_config_restart
                _okcat "密钥更新成功，已重启生效"
            else
                _failcat "密钥更新失败，请重新输入"
                return 1
            end
        case '*'
            _failcat "密钥不要包含空格或使用引号包围"
    end
end

function _tunstatus
    set tun_status (sudo "$BIN_YQ" '.tun.enable' "$CLASH_CONFIG_RUNTIME")
    if test "$tun_status" = 'true'
        _okcat 'Tun 状态：启用'
    else
        _failcat 'Tun 状态：关闭'
    end
end

function _tunoff
    if not _tunstatus >/dev/null
        return 0
    end
    sudo "$BIN_YQ" -i '.tun.enable = false' "$CLASH_CONFIG_MIXIN"
    if _merge_config_restart
        _okcat "Tun 模式已关闭"
    end
end

function _tunon
    if _tunstatus 2>/dev/null
        return 0
    end
    sudo "$BIN_YQ" -i '.tun.enable = true' "$CLASH_CONFIG_MIXIN"
    _merge_config_restart
    sleep 0.5s
    if sudo journalctl -u "$BIN_KERNEL_NAME" --since "1 min ago" | grep -E -m1 'unsupported kernel version|Start TUN listening error'
        _tunoff >/dev/null 2>&1
        _error_quit '不支持的内核版本'
    end
    _okcat "Tun 模式已开启"
end

function clashtun
    switch $argv[1]
        case on
            _tunon
        case off
            _tunoff
        case '*'
            _tunstatus
    end
end

function clashupdate
    set url (cat "$CLASH_CONFIG_URL")
    set is_auto

    switch $argv[1]
        case auto
            set is_auto true
            if test -n "$argv[2]"
                set url $argv[2]
            end
        case log
            if sudo tail "$CLASH_UPDATE_LOG" 2>/dev/null
            else
                _failcat "暂无更新日志"
            end
            return 0
        case '*'
            if test -n "$argv[1]"
                set url $argv[1]
            end
    end

    # 如果没有提供有效的订阅链接（url为空或者不是http开头），则使用默认配置文件
    if test (string sub --length 4 "$url") != "http"
        _failcat "没有提供有效的订阅链接：使用 $CLASH_CONFIG_RAW 进行更新..."
        set url "file://$CLASH_CONFIG_RAW"
    end

    # 如果是自动更新模式，则设置定时任务
    if test "$is_auto" = true
        if not sudo grep -qs 'clashupdate' "$CLASH_CRON_TAB"
            echo "0 0 */2 * * fish -i -c 'clashupdate $url'" | sudo tee -a "$CLASH_CRON_TAB" >/dev/null 2>&1
        end
        _okcat "已设置定时更新订阅"
        return 0
    end

    _okcat '👌' "正在下载：原配置已备份..."
    sudo cat "$CLASH_CONFIG_RAW" | sudo tee "$CLASH_CONFIG_RAW_BAK" >/dev/null 2>&1

    function _rollback
        _failcat '🍂' "$argv[1]"
        sudo cat "$CLASH_CONFIG_RAW_BAK" | sudo tee "$CLASH_CONFIG_RAW" >/dev/null 2>&1
        _failcat '❌' "["(date +"%Y-%m-%d %H:%M:%S")"] 订阅更新失败：$url" 2>&1 | sudo tee -a "$CLASH_UPDATE_LOG" >/dev/null 2>&1
        _error_quit
    end

    if not _download_config "$CLASH_CONFIG_RAW" "$url"
        _rollback "下载失败：已回滚配置"
    end
    if not _valid_config "$CLASH_CONFIG_RAW"
        _rollback "转换失败：已回滚配置，转换日志：$BIN_SUBCONVERTER_LOG"
    end

    if _merge_config_restart
        _okcat '🍃' '订阅更新成功'
    end
    echo "$url" | sudo tee "$CLASH_CONFIG_URL" >/dev/null 2>&1
    _okcat '✅' "["(date +"%Y-%m-%d %H:%M:%S")"] 订阅更新成功：$url" | sudo tee -a "$CLASH_UPDATE_LOG" >/dev/null 2>&1
end

function clashmixin
    switch $argv[1]
        case -e
            if sudo vim "$CLASH_CONFIG_MIXIN"
                if _merge_config_restart
                    _okcat "配置更新成功，已重启生效"
                end
            end
        case -r
            less -f "$CLASH_CONFIG_RUNTIME"
        case '*'
            less -f "$CLASH_CONFIG_MIXIN"
    end
end

function clashctl
    switch $argv[1]
        case on
            clashon
        case off
            clashoff
        case ui
            clashui
        case status
            set -e argv[1]
            clashstatus $argv
        case proxy
            set -e argv[1]
            clashproxy $argv
        case tun
            set -e argv[1]
            clashtun $argv
        case mixin
            set -e argv[1]
            clashmixin $argv
        case secret
            set -e argv[1]
            clashsecret $argv
        case update
            set -e argv[1]
            clashupdate $argv
        case '*'
            echo '
Usage:
    clash COMMAND  [OPTION]

Commands:
    on                      开启代理
    off                     关闭代理
    proxy    [on|off]       系统代理
    ui                      面板地址
    status                  内核状况
    tun      [on|off]       Tun 模式
    mixin    [-e|-r]        Mixin 配置
    secret   [SECRET]       Web 密钥
    update   [auto|log]     更新订阅
'
    end
end

function mihomoctl
    clashctl $argv
end

function clash
    clashctl $argv
end

function mihomo
    clashctl $argv
end
