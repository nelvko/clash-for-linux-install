#!/usr/bin/env bash

# clashctl update —— 更新本项目脚本与资源（区别于 upgrade 升级内核）。
# 从 GitHub 下载 tarball，复用 lib/update.sh 的非破坏式部署核心就地更新，
# 更新前自动备份、失败自动回滚，订阅/密钥/mixin/激活配置全部保留。

clashupdate() {
    local arg force=false check_only=false
    for arg in "$@"; do
        case $arg in
        -h | --help)
            update_help
            return 0
            ;;
        -f | --force)
            force=true
            ;;
        -c | --check)
            check_only=true
            ;;
        *) ;;
        esac
    done

    local repo='nelvko/clash-for-linux-install' ref='refactor/install-update'
    local cur_rev="${CLASHCTL_REV:-unknown}" remote_rev remote_short
    remote_rev=$(_update_remote_sha "$repo" "$ref")
    remote_short=${remote_rev:0:7}

    if [ -n "$remote_short" ]; then
        _okcat '🔖' "当前版本：${cur_rev}　最新版本：${remote_short}"
    else
        _failcat '🔖' "无法获取远端版本（网络受限或 API 限流），将直接尝试更新"
    fi

    [ "$check_only" = true ] && return 0

    [ "$force" != true ] && [ -n "$remote_short" ] && [ "$cur_rev" = "$remote_short" ] && {
        _okcat '✅' "已是最新版本（如需强制重新部署：clashctl update --force）"
        return 0
    }

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

update_help() {
    cat <<EOF

clashctl update - 更新 clashctl 项目脚本与资源（区别于 upgrade 升级内核）

Usage:
  clashctl update [OPTIONS]

Options:
  -c, --check     仅检查当前与最新版本，不执行更新
  -f, --force     跳过"已是最新"检测，强制重新部署
  -h, --help      显示帮助信息

说明：
  update   更新本项目（脚本/资源）；更新前自动备份，失败自动回滚，订阅与配置保留。
  upgrade  升级代理内核（mihomo / clash）。

EOF
}
