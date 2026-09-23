#!/usr/bin/env bash

clashstart() {
    case ${1:-} in
    -h | --help)
        printf '用法: clashctl start\n启动内核，不修改当前终端代理环境；已运行时保持原状。\n'
        return 0 ;;
    '') ;;
    *) _ui_fail '用法: clashctl start'; return 1 ;;
    esac
    if [ -n "${ZSH_VERSION:-}" ]; then
        CLASHCTL_HOME="$CLASHCTL_HOME" bash -c '
            . "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" && clashstart
        '
        return
    fi
    if service_is_active >&/dev/null; then
        _ui_ok_out "$CLASHCTL_KERNEL 已运行"
        return 0
    fi
    if [ ! -x "$BIN_KERNEL" ]; then
        _ui_error "代理内核未安装（$CLASHCTL_KERNEL）"
        _ui_detail '修复' "CLASHCTL_HOME=$CLASHCTL_HOME bash $CLASHCTL_HOME/install.sh"
        return 1
    fi
    _require_base_config || return 1
    _merge_config || return 1
    _detect_proxy_port || return 1
    _detect_ext_addr || return 1
    service_start || return 1
    service_is_active >&/dev/null || {
        _ui_fail "$CLASHCTL_KERNEL 启动失败"
        return 1
    }
    service_enable || return 1
    _ui_ok_out "$CLASHCTL_KERNEL 已启动"
}
