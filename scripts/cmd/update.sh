#!/usr/bin/env bash

# clashctl update —— 更新本项目脚本与资源（区别于 upgrade 升级内核）。
# 自动从 GitHub 拉取最新源码，复用 lib/update.sh 的非破坏式部署核心就地更新，
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

    local repo='nelvko/clash-for-linux-install'
    local cur_rev="${CLASHCTL_REV:-unknown}" remote_rev remote_short
    remote_rev=$(_update_remote_sha "$repo")
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

    # 显式清理临时目录（不用 RETURN trap，避免与 deploy_clashctl 内部的 source 交互）
    local _UPDATE_TMP=
    if ! _update_fetch_src "$repo"; then
        [ -n "$_UPDATE_TMP" ] && rm -rf "$_UPDATE_TMP" 2>/dev/null
        return 1
    fi

    CLASHCTL_SRC_REV="$remote_short" deploy_clashctl
    local rc=$?
    [ -n "$_UPDATE_TMP" ] && rm -rf "$_UPDATE_TMP" 2>/dev/null
    return "$rc"
}

# 取远端 master 最新提交 SHA（仅作「已是最新」优化，失败返回空、绝不阻塞）
_update_remote_sha() {
    local repo=$1 sha
    sha=$(
        curl -s \
            --max-time 10 \
            --retry 1 \
            -H 'Accept: application/vnd.github.sha' \
            "https://api.github.com/repos/${repo}/commits/master" 2>/dev/null
    ) || return 0
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] && printf '%s\n' "$sha"
    return 0
}

# 下载并解压最新源码到临时目录，校验结构后设置 CLASHCTL_SRC 指向它。
# 下载发生在备份/部署之前，网络失败只返回非 0，不改动系统。
_update_fetch_src() {
    local repo=$1 ref='master'
    local url="https://codeload.github.com/${repo}/tar.gz/refs/heads/${ref}"
    local proxy_url="${GH_PROXY:+${GH_PROXY%/}/}${url}"
    local tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/clashctl-update.XXXXXX") || {
        _errorcat "创建临时目录失败"
        return 1
    }
    _UPDATE_TMP="$tmp"
    local tarball="$tmp/src.tar.gz"

    _okcat '⏳' "下载最新源码：$proxy_url"
    curl \
        --fail \
        --show-error \
        --insecure \
        --location \
        --max-time "${CLASHCTL_DOWNLOAD_TIMEOUT:-60}" \
        --retry 1 \
        --output "$tarball" \
        "$proxy_url" || {
        _failcat "下载失败，请检查网络或 .env 中的 GH_PROXY"
        return 1
    }

    gzip -tq "$tarball" 2>/dev/null || {
        _failcat "源码包校验失败，请重试"
        return 1
    }
    tar -xf "$tarball" -C "$tmp" || {
        _failcat "源码解压失败"
        return 1
    }

    local top
    top=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d -name "*-${ref}" 2>/dev/null | head -1)
    [[ -d "$top/scripts/cmd" && -f "$top/scripts/preflight.sh" ]] || {
        _failcat "源码结构异常，已中止"
        return 1
    }

    # shellcheck disable=SC2034  # 供 deploy_clashctl（lib/update.sh）使用
    CLASHCTL_SRC="$top"
    return 0
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
