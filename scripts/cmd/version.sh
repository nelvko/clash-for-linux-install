#!/usr/bin/env bash

clashversion() {
    case "$1" in
    -h | --help)
        cat <<'EOF'
Usage:
  clashctl version

显示脚本版本（git 安装为当前提交，归档安装为安装时记录）、跟进分支、
已装内核版本与依赖钉版。
EOF
        return 0
        ;;
    esac

    local rev branch kernel
    if _update_is_git_home; then
        rev=$(git -C "$CLASHCTL_HOME" rev-parse --short HEAD 2>/dev/null)
        local date
        date=$(git -C "$CLASHCTL_HOME" log -1 --pretty=%cd --date=short 2>/dev/null)
        [ -n "$date" ] && rev="${rev}（${date}）"
        branch=$(git -C "$CLASHCTL_HOME" rev-parse --abbrev-ref HEAD 2>/dev/null)
    else
        rev=${CLASHCTL_REV:-unknown}
    fi
    branch=${branch:-${CLASHCTL_UPDATE_BRANCH:-master}}

    kernel=$(timeout 5 "$BIN_KERNEL" -v 2>/dev/null | grep -oE 'v[0-9][0-9A-Za-z.-]*' | head -1)
    kernel=${kernel:-unknown}

    _ui_info_out "clashctl：${rev:-unknown}"
    _ui_info_out "分支：$branch"
    _ui_info_out "内核（已装）：$kernel"
    _ui_info_out "依赖钉版：mihomo ${DEFAULT_VERSION_MIHOMO} / yq ${DEFAULT_VERSION_YQ} / subconverter ${DEFAULT_VERSION_SUBCONVERTER} / UI ${DEFAULT_VERSION_UI}"
    _ui_info_out '更新策略：最新版优先，查询失败回退内置钉版'
}
