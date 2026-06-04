#!/usr/bin/env bash

# clashctl 更新入口
#   在线更新：bash update.sh
#   本地更新：bash update.sh（本地已有 scripts/update.sh 时直接调用）
#
# 本文件只做一件事：确保完整源码就位，然后交给 scripts/update.sh。

_bootstrap() {
    CLASHCTL_SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

    # 完整源码已就位，直接走更新脚本
    [[ -f "${CLASHCTL_SRC}/scripts/update.sh" ]] && exec bash "${CLASHCTL_SRC}/scripts/update.sh" "$@"

    # 在线更新：下载最新 tarball
    _clr() { local c="\033[38;2;${1};${2};${3}m"; shift 3; printf "%b%s%b\n" "$c" "$*" "\033[0m"; }
    _ok()  { _clr 200 214 229 "😼 $*"; }
    _err() { _clr 249 47 96 "📢 $*" >&2; }

    _ok "正在下载最新源码..."
    local repo='nelvko/clash-for-linux-install' ref='refactor/install-update'
    local url="https://codeload.github.com/${repo}/tar.gz/refs/heads/${ref}"
    local proxy="${GH_PROXY:+${GH_PROXY%/}/}${url}"
    local tmp tarball top
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/clashctl-update.XXXXXX") || { _err "创建临时目录失败"; exit 1; }
    tarball="${tmp}/src.tar.gz"

    curl --fail --show-error --insecure --location \
         --max-time "${CLASHCTL_DOWNLOAD_TIMEOUT:-60}" --retry 1 \
         --output "${tarball}" "${proxy}" || {
        _err "下载失败，请检查网络或设置 GH_PROXY 环境变量后重试"
        rm -rf "${tmp}"; exit 1
    }
    gzip -tq "${tarball}" 2>/dev/null || { _err "源码包校验失败，请重试"; rm -rf "${tmp}"; exit 1; }
    tar -xf "${tarball}" -C "${tmp}" || { _err "源码解压失败"; rm -rf "${tmp}"; exit 1; }
    top=$(find "${tmp}" -mindepth 1 -maxdepth 1 -type d -name "*-${ref}" 2>/dev/null | head -1)
    [[ -d "${top}/scripts/cmd" && -f "${top}/scripts/preflight.sh" ]] || {
        _err "源码结构异常，已中止"; rm -rf "${tmp}"; exit 1
    }
    _ok "源码下载完成，开始更新..."
    exec bash "${top}/scripts/update.sh" "$@"
}
_bootstrap "$@"
