#!/usr/bin/env bash

clashversion() {
    case "${1:-}" in
    -h | --help)
        cat <<'EOF'
Usage:
  clashctl version

显示脚本提交版本、跟进分支、
已装内核版本与依赖钉版。
EOF
        return 0
        ;;
    esac

    local rev branch=${CLASHCTL_UPDATE_BRANCH:-master} kernel
    rev=$(git -C "$CLASHCTL_HOME" rev-parse --short HEAD 2>/dev/null)

    kernel=$(timeout 5 "$BIN_KERNEL" -v 2>/dev/null | grep -oE 'v[0-9][0-9A-Za-z.-]*' | head -1)
    kernel=${kernel:-unknown}

    _ui_info_out "clashctl：${rev:-unknown}"
    _ui_info_out "分支：$branch"
    _ui_info_out "内核（已装）：$kernel"
    _ui_info_out "依赖钉版：mihomo ${DEFAULT_VERSION_MIHOMO} / yq ${DEFAULT_VERSION_YQ} / subconverter ${DEFAULT_VERSION_SUBCONVERTER} / UI ${DEFAULT_VERSION_UI}"
    _ui_info_out '更新策略：最新版优先，查询失败回退内置钉版'
}
