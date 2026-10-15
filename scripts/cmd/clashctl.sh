#!/usr/bin/env bash

# 首次初始化时 .env 尚未创建
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
    -v | --version) sub_cmd=version ;;
    -*)
        _ui_fail "Unknown option: $sub_cmd"
        _ui_fail "Use 'clashctl help' for usage information."
        return 1
        ;;
    esac

    local target="clash${sub_cmd}"
    typeset -f "$target" >/dev/null 2>&1 || {
        _ui_fail "Unknown subcommand: $sub_cmd"
        _ui_fail "Use 'clashctl help' for usage information."
        return 1
    }

    # on/off 需要修改当前 Shell 的代理变量，update 需要把新版本重新载入当前
    # Shell，help/version 为零依赖纯文本；其余命令统一在 Bash 子进程中执行。
    case $sub_cmd in
    on | off | update | help | version) ;;
    *)
        if ! _clashctl_in_bash; then
            _clashctl_run_in_bash "$target" "$@"
            return
        fi
        ;;
    esac

    "$target" "$@"
}
