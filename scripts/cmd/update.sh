#!/usr/bin/env bash

clashupdate() {
    case ${1:-} in
    -h | --help)
        printf '用法: clashupdate\n更新脚本与资源，保留用户配置和内核。来源由 .env 中 CLASHCTL_UPDATE_BRANCH 和 GH_PROXY 配置。\n'
        return 0 ;;
    '') ;;
    *) _ui_error '用法: clashupdate'; return 1 ;;
    esac
    _update_scripts || return 1
    . "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" || {
        _ui_error '脚本已更新，但当前 Shell 加载失败，请重开终端'
        return 1
    }
    _ui_ok_out '更新完成，当前 Shell 已加载新版本'
}
