#!/usr/bin/env bash

# clashctl 安装入口
#   在线安装：curl -fsSL <raw_url> | bash -s -- [mihomo|clash] [订阅URL]
#   本地安装：bash install.sh [mihomo|clash] [订阅URL]
#
# 本文件只做一件事：确保完整源码就位，然后交给 scripts/install.sh。

_bootstrap() {
    CLASHCTL_SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

    # 完整源码已就位（本地安装 / git clone），直接走安装脚本
    [[ -f "${CLASHCTL_SRC}/scripts/install.sh" ]] && exec bash "${CLASHCTL_SRC}/scripts/install.sh" "$@"

    # 在线安装：下载完整源码 tarball
    _clr() { local c="\033[38;2;${1};${2};${3}m"; shift 3; printf "%b%s%b\n" "$c" "$*" "\033[0m"; }
    _ok()  { _clr 200 214 229 "😼 $*"; }
    _err() { _clr 249 47 96 "📢 $*" >&2; }

    _ok "检测到在线安装，正在下载完整源码..."
    local repo='nelvko/clash-for-linux-install' ref='refactor/install-update'
    local url="https://codeload.github.com/${repo}/tar.gz/refs/heads/${ref}"
    local proxy="${GH_PROXY:+${GH_PROXY%/}/}${url}"
    local tmp tarball top
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/clashctl-install.XXXXXX") || { _err "创建临时目录失败"; exit 1; }
    tarball="${tmp}/src.tar.gz"

    curl --fail --show-error --insecure --location \
         --max-time "${CLASHCTL_DOWNLOAD_TIMEOUT:-60}" --retry 1 \
         --output "${tarball}" "${proxy}" || {
        _err "下载失败，请检查网络或设置 GH_PROXY 环境变量后重试（如：GH_PROXY=https://gh-proxy.org/）"
        rm -rf "${tmp}"; exit 1
    }
    gzip -tq "${tarball}" 2>/dev/null || { _err "源码包校验失败，请重试"; rm -rf "${tmp}"; exit 1; }
    tar -xf "${tarball}" -C "${tmp}" || { _err "源码解压失败"; rm -rf "${tmp}"; exit 1; }
    top=$(find "${tmp}" -mindepth 1 -maxdepth 1 -type d -name "*-${ref}" 2>/dev/null | head -1)
    [[ -d "${top}/scripts/cmd" && -f "${top}/scripts/preflight.sh" ]] || {
        _err "源码结构异常，已中止"; rm -rf "${tmp}"; exit 1
    }
    _ok "源码下载完成，开始安装..."
    exec bash "${top}/scripts/install.sh" "$@"
}
_bootstrap "$@"
