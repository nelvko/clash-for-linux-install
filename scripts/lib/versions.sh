#!/usr/bin/env bash

# shellcheck disable=SC2034  # 默认值由 preflight.sh 与 version.sh 读取
# ── 依赖钉版（本文件为唯一事实源，升级依赖时随同一提交更新）──────
# ── 用户可用 .env/环境变量覆盖 VERSION_* 同名键；CLASHCTL_CHECK_ ──
# ── LATEST_VERSION=1（默认）时最新版查询成功则优先最新，钉版仅为──
# ── 查询失败时的兜底。`clashctl version` 可查看当前生效版本。────
DEFAULT_VERSION_MIHOMO=v1.19.27
DEFAULT_VERSION_YQ=v4.53.3
DEFAULT_VERSION_SUBCONVERTER=v0.9.9
DEFAULT_VERSION_UI=v3.20.0

# 依赖仓库默认值（可在 .env/环境变量覆盖）
[ -n "${SUBCONVERTER_REPO:-}" ] || SUBCONVERTER_REPO=asdlokj1qpi233/subconverter

# 安装/更新下载默认值（.env 物化前或环境变量未设时兜底；GH_PROXY 显式置空 = 直连）
[ "${GH_PROXY+x}" = x ] || GH_PROXY=https://gh-proxy.org
[ "${CLASHCTL_DOWNLOAD_TIMEOUT+x}" = x ] || CLASHCTL_DOWNLOAD_TIMEOUT=60
