#!/bin/bash
source ./script/common.sh
source ./script/clashctl.sh

_valid_root

[ ! -d "$CLASH_BASE_PATH" ] && {
    echo "clash: has already been uninstalled"
    read -r -p "按 Enter 键退出，按其它键重新清除代理环境：" ANSWER
    [ "$ANSWER" = "" ] && _quit || echo "清除中..."
}

clashoff
# 重载daemon
systemctl disable clash >/dev/null 2>&1
rm -f /etc/systemd/system/clash.service
systemctl daemon-reload

rm -rf "$CLASH_BASE_PATH"
sed -i '/clashctl.sh/d' /etc/bashrc
sed -i '/clashupdate/d' "$TARGET_PATH"
echo 'clash: 已卸载，相关配置已清除！'
