#!/usr/bin/env bash

function clashstatus() {
    # 空壳态守卫：clashctl 已装但内核未安装（clashctl install 未完成）
    if [ ! -x "$BIN_KERNEL" ]; then
        _ui_fail "代理内核未安装（$CLASHCTL_KERNEL）"
        _ui_fail "请先运行: clashctl install"
        return 1
    fi
    service_status "$@"
    service_is_active >&/dev/null
}
