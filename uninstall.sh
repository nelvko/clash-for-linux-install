#!/bin/bash
# shellcheck disable=SC1091
. script/common.sh
. script/clashctl.sh

_valid_env

clashoff >&/dev/null

systemctl disable clash >&/dev/null
rm -f /etc/systemd/system/clash.service
systemctl daemon-reload
rm -rf "$CLASH_BASE_DIR"
sed -i '/clashupdate/d' "$CLASH_CRON_TAB" >&/dev/null
sed -i '/clashctl.sh/d' "$BASHRC" >&/dev/null
_okcat '✨' '已卸载，相关配置已清除'
# 未 export 的变量和函数不会被继承
exec bash
