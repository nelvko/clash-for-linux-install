#!/usr/bin/env bash

function clashstatus() {
    # 安装失败或内核文件被移除时给出修复入口
    if [ ! -x "$BIN_KERNEL" ]; then
        _ui_fail "代理内核未安装（$CLASHCTL_KERNEL）"
        _ui_fail "请执行: bash $CLASHCTL_HOME/scripts/cmd/install.sh"
        return 1
    fi
    service_status "$@"
    service_is_active >&/dev/null
}
