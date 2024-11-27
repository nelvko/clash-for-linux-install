#!/bin/bash
source ./script/common.sh
source ./script/clashctl.sh

_valid_root

[ ! -d "$CLASH_BASE_PATH" ] && {
    echo "😾 已卸载或未安装"
    read -r -p "按 Enter 键退出，按其它键重新清除代理环境：" ANSWER
    [ "$ANSWER" = "" ] && _quit || echo "清除中..."
}

clashoff >/dev/null 2>&1
# 重载daemon
systemctl disable clash >/dev/null 2>&1
rm -f /etc/systemd/system/clash.service
systemctl daemon-reload

rm -rf "$CLASH_BASE_PATH"
# 未 export 的变量和函数不会被继承
sed -i '/clashctl.sh/d' /etc/bashrc && exec bash
sed -i '/clashupdate/d' "$CLASH_CRONTAB_TARGET_PATH"
echo '😼 已卸载，相关配置已清除！'
