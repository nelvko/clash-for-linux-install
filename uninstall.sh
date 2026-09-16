#!/usr/bin/env bash

main() (
    local answer='' initialized=false install_home
    case ${1:-} in
    -y | --yes) answer=y ;;
    -h | --help) printf '用法: bash uninstall.sh [--yes]\n'; return 0 ;;
    '') ;;
    *) printf '未知参数\n' >&2; return 1 ;;
    esac
    install_home="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || return 1
    export CLASHCTL_HOME="$install_home"
    export CLASHCTL_SRC="$CLASHCTL_HOME"
    if [ ! -f "$CLASHCTL_HOME/install.sh" ] || [ ! -f "$CLASHCTL_HOME/scripts/preflight.sh" ] ||
        [ ! -d "$CLASHCTL_HOME/.git" ] || [ -L "$CLASHCTL_HOME/.git" ] ||
        [ "$CLASHCTL_HOME" = / ] || [ "$CLASHCTL_HOME" = "$(cd -- "$HOME" && pwd -P)" ]; then
        printf '未找到有效安装目录\n' >&2; return 1
    fi
    # .git 和 .env 也可能存在于源码目录，只有安装器写入的路径标记能授权删除。
    if [ ! -f "$install_home/.git/clashctl-home" ] || [ -L "$install_home/.git/clashctl-home" ] ||
        [ "$(cat -- "$install_home/.git/clashctl-home")" != "$install_home" ]; then
        printf '缺少匹配的安装标记，拒绝卸载此目录：%s\n请运行实际安装目录中的 uninstall.sh；源码目录和旧版未标记目录不会被删除。\n' "$install_home" >&2
        return 1
    fi
    . "$CLASHCTL_SRC/scripts/lib/operation-lock.sh" || return 1
    operation_lock_acquire || return 1
    [ ! -e "$CLASHCTL_HOME/.env" ] && [ ! -L "$CLASHCTL_HOME/.env" ] || initialized=true
    if [ "$answer" != y ]; then
        if [ "$initialized" = true ]; then
            printf '将删除当前安装的服务、Shell 引导及目录 %s，继续？[y/N] ' "$CLASHCTL_HOME"
        else
            printf '尚未初始化，仅删除目录 %s，继续？[y/N] ' "$CLASHCTL_HOME"
        fi
        read -r answer
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
            _ui_error '.env 改写了安装路径，已停止卸载'
            return 1
        fi
        case ${CLASHCTL_KERNEL:-} in
        mihomo | clash) ;;
        *) _ui_error '.env 中缺少有效的内核信息，已保留安装目录'; return 1 ;;
        esac
        uninstall_service || return 1
        revoke_rc || return 1
    fi
    rm -rf -- "$install_home" || return 1
    printf '[ OK ] 卸载完成\n'
)

main "$@"
