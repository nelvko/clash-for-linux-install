#!/usr/bin/env bash

# clashctl 更新脚本（完整源码已就位）
# 由根 update.sh（在线/本地）引导后 exec 调用，或直接执行 bash scripts/update.sh
#
# 从 GitHub 下载最新 tarball，非破坏式部署到已安装的 $CLASHCTL_HOME，
# 订阅与配置保留。无需 git。

CLASHCTL_SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
. "${CLASHCTL_SRC}/scripts/preflight.sh"

_do_update() {
    local repo='nelvko/clash-for-linux-install' ref='refactor/install-update'
    local remote_rev remote_short
    remote_rev=$(_update_remote_sha "$repo" "$ref")
    remote_short=${remote_rev:0:7}

    local _FETCH_TMP=
    if ! _update_fetch_src "$repo" "$ref"; then
        [ -n "$_FETCH_TMP" ] && rm -rf "$_FETCH_TMP" 2>/dev/null
        return 1
    fi

    CLASHCTL_SRC_REV="$remote_short" deploy_clashctl
    local rc=$?
    [ -n "$_FETCH_TMP" ] && rm -rf "$_FETCH_TMP" 2>/dev/null
    return "$rc"
}
_do_update
exit $?
