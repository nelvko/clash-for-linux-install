#!/usr/bin/env bash

main() (
    local answer
    export CLASHCTL_HOME="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
    export CLASHCTL_SRC="$CLASHCTL_HOME"
    case ${1:-} in
    -y | --yes) ;;
    -h | --help) printf '用法: bash uninstall.sh [--yes]\n'; return 0 ;;
    '')
        printf '将删除服务及安装目录 %s，继续？[y/N] ' "$CLASHCTL_HOME"
        read -r answer
        [[ $answer == y || $answer == Y ]] || return 1 ;;
    *) printf '未知参数\n' >&2; return 1 ;;
    esac
    if [ ! -f "$CLASHCTL_HOME/.env" ] || [ ! -d "$CLASHCTL_HOME/.git" ] ||
        [ "$CLASHCTL_HOME" = / ] || [ "$CLASHCTL_HOME" = "$HOME" ]; then
        printf '未找到有效安装目录\n' >&2; return 1
    fi
    . "$CLASHCTL_SRC/scripts/preflight.sh" || return 1
    operation_lock_acquire || return 1
    uninstall_service || return 1
    revoke_rc || return 1
    rm -rf -- "$CLASHCTL_HOME" || return 1
    _ui_ok '卸载完成'
)

main "$@"
