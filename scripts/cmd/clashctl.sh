#!/usr/bin/env bash

# 空壳态（已装 clashctl、尚未跑 clashctl install）没有 .env，缺省跳过
[ -f "$CLASHCTL_HOME"/.env ] && . "$CLASHCTL_HOME"/.env

for lib_file in "$CLASHCTL_HOME"/scripts/lib/*.sh; do
    # shellcheck disable=SC1090  # 运行时按安装目录加载公共库
    . "$lib_file"
done

for cmd_file in "$CLASHCTL_HOME"/scripts/cmd/*.sh; do
    case "$cmd_file" in *clashctl.*) continue ;; esac
    # shellcheck disable=SC1090  # 运行时按安装目录加载子命令
    . "$cmd_file"
done

clashctl() {
    local sub_cmd
    sub_cmd=${1:-help}
    shift

    case $sub_cmd in
    -h | --help | help) sub_cmd=help ;;
    esac

    local target="clash${sub_cmd}"
    declare -F "$target" >&/dev/null || {
        _ui_fail "Unknown subcommand: $target"
        _ui_fail "Use 'clashctl help' for usage information."
        return
    }
    "$target" "$@"
}
