# shellcheck disable=SC2148
# shellcheck disable=SC1091
. script/common.sh >&/dev/null
. script/clashctl.sh >&/dev/null

_valid_env

clashoff >&/dev/null

systemctl disable "$BIN_KERNEL_NAME" >&/dev/null
rm -f "/etc/systemd/system/${BIN_KERNEL_NAME}.service"
systemctl daemon-reload

rm -rf "$CLASH_BASE_DIR"
_set_rc unset
_okcat '✨' '已卸载，相关配置已清除'
_quit
