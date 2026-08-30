#!/usr/bin/env bash

. "$CLASHCTL_HOME"/.env

for lib_file in "$CLASHCTL_HOME"/scripts/lib/*.sh; do
    . "$lib_file"
done

for cmd_file in "$CLASHCTL_HOME"/scripts/cmd/*.sh; do
    case "$cmd_file" in *clashctl.*) continue ;; esac
    . "$cmd_file"
done

clashctl() {
    local sub_cmd
    sub_cmd=${1:-help}
    shift 2>/dev/null || :

    case $sub_cmd in
    -h | --help | help) sub_cmd=help ;;
    esac

    local target="clash${sub_cmd}"
    # bash 用 declare -F 检查函数；zsh 的 declare -F 是声明浮点变量（恒返回 0）
    # → 统一用 command -v（两 shell 语义一致）
    command -v "$target" >&/dev/null || {
        _failcat "Unknown subcommand: $target"
        _failcat "Use 'clashctl help' for usage information."
        return
    }
    "$target" "$@"
}
