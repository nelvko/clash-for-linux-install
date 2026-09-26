#!/usr/bin/env bash

main() (
    _install_ui_output() { _install_ui_emit_fd "$@"; }
    local answer='' initialized=true script_home install_home marker cache
    [ "$#" -le 1 ] || { printf '用法: bash uninstall.sh [--yes]\n' >&2; return 1; }
    case ${1:-} in
    -y | --yes) answer=y ;;
    -h | --help)
        printf '用法: bash uninstall.sh [--yes]\n安装目录：脚本所在的安装目录优先，否则使用 CLASHCTL_HOME 或 ~/.clashctl。\n停止内核，移除服务、Shell 引导和安装目录。\n订阅、自定义配置、内核及日志都会删除，请提前备份。\n--yes  跳过确认，不跳过安装归属与停止检查。\n'
        return 0 ;;
    '') ;;
    *) printf '未知参数\n' >&2; return 1 ;;
    esac
    script_home="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || return 1
    # 源码入口只定位安装；存在标记时必须校验本目录，不绕过损坏或复制的标记。
    if [ -e "$script_home/.clashctl-install" ] || [ -L "$script_home/.clashctl-install" ]; then
        install_home=$script_home
    else
        install_home=${CLASHCTL_HOME:-$HOME/.clashctl}
    fi
    if [ ! -d "$install_home" ]; then
        printf '未找到 clashctl 安装：%s\n' "$install_home" >&2
        return 1
    fi
    install_home=$(cd -- "$install_home" && pwd -P) || return 1
    export CLASHCTL_HOME="$install_home"
    export CLASHCTL_SRC="$CLASHCTL_HOME"
    if [ ! -f "$CLASHCTL_HOME/install.sh" ] || [ ! -f "$CLASHCTL_HOME/scripts/preflight.sh" ] ||
        [ "$CLASHCTL_HOME" = / ] || [ "$CLASHCTL_HOME" = "$(cd -- "$HOME" && pwd -P)" ]; then
        printf '无效的 clashctl 安装目录：%s\n' "$install_home" >&2; return 1
    fi
    # 安装标记不依赖 Git；严格匹配物理路径，复制后的目录不能卸载。
    marker=''
    if [ -f "$install_home/.clashctl-install" ] && [ ! -L "$install_home/.clashctl-install" ]; then
        marker=$(cat -- "$install_home/.clashctl-install") || return 1
    fi
    case "$marker" in
    "$install_home"$'\ngit' | "$install_home"$'\narchive') ;;
    *)
        printf '安装标记不匹配，已取消卸载：%s\n' "$install_home" >&2
        return 1 ;;
    esac
    . "$CLASHCTL_SRC/scripts/lib/operation-lock.sh" || return 1
    operation_lock_acquire || return 1
    if [ ! -e "$install_home/.env" ] && [ ! -L "$install_home/.env" ]; then
        if [ -f "$install_home/.clashctl-uninitialized" ] &&
            [ ! -L "$install_home/.clashctl-uninitialized" ] &&
            [ "$(cat -- "$install_home/.clashctl-uninitialized")" = "$install_home" ]; then
            initialized=false
        else
            printf '.env 缺失，无法确认服务状态，已保留安装目录：%s\n请从备份恢复 .env 后重试；不要直接删除目录。\n' "$install_home" >&2
            return 1
        fi
    fi
    printf '将卸载 clashctl 并删除 %s（含订阅和自定义配置）' "$install_home"
    if [ "$answer" = y ]; then
        printf '\n'
    else
        printf '，继续？[y/N] '
        IFS= read -r answer || { printf '\n未收到确认，已取消；无人值守卸载请显式使用 --yes。\n' >&2; return 1; }
        [[ $answer == y || $answer == Y ]] || return 1
    fi
    if [ "$initialized" = true ]; then
        # 必须从本次安装的 .env 读取内核，不能沿用调用终端的安装状态。
        if [ ! -f "$CLASHCTL_HOME/.env" ] || [ ! -r "$CLASHCTL_HOME/.env" ]; then
            printf '.env 无法读取，已保留安装目录\n' >&2; return 1
        fi
        unset CLASHCTL_KERNEL INIT_TYPE
        . "$CLASHCTL_SRC/scripts/preflight.sh" || return 1
        if [ "$CLASHCTL_HOME" != "$install_home" ] || [ "$CLASHCTL_SRC" != "$install_home" ]; then
            _install_ui_error '.env 改写了安装路径，已停止卸载'
            return 1
        fi
        case ${CLASHCTL_KERNEL:-} in
        mihomo | clash) ;;
        *) _install_ui_error '.env 中缺少有效的内核信息，已保留安装目录'; return 1 ;;
        esac
        uninstall_service || return 1
        revoke_rc || return 1
    fi
    command rm -rf -- "$install_home" || return 1
    if declare -F _install_ui_ok_out >/dev/null 2>&1; then
        _install_ui_ok_out '卸载完成'
    else
        printf '[ OK ] 卸载完成\n'
    fi
    cache="${XDG_CACHE_HOME:-$HOME/.cache}/clashctl/proxy.fish"
    if [ -e "$cache" ] || [ -L "$cache" ]; then
        printf '保留了无法确认安装归属的 Fish 代理缓存，请检查后手动清理：%s\n' "$cache"
    fi
    if [ -n "${http_proxy:-}${https_proxy:-}${HTTP_PROXY:-}${HTTPS_PROXY:-}${all_proxy:-}${ALL_PROXY:-}${no_proxy:-}${NO_PROXY:-}" ]; then
        printf '当前终端可能仍保留代理变量；本脚本无法修改父 Shell，请按需在原终端执行：\n'
        printf '  bash/zsh: unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY\n'
        printf '  fish: set -e http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY\n'
    fi
)

main "$@"
