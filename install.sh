#!/usr/bin/env bash

# 可直接 curl .../install.sh | bash；交互输入从 /dev/tty 读取。
main() (
    set -e
    local install_home=${CLASHCTL_HOME:-$HOME/.clashctl}
    local branch=${CLASHCTL_UPDATE_BRANCH:-master} kernel=mihomo
    local proxy=${GH_PROXY-https://gh-proxy.org} stage='' arg
    for arg in "$@"; do
        case $arg in
        mihomo | clash) kernel=$arg ;;
        -h | --help)
            printf '用法: bash install.sh [mihomo|clash]\n环境变量: CLASHCTL_HOME、CLASHCTL_UPDATE_BRANCH、GH_PROXY\n'
            return 0 ;;
        *) printf '未知安装参数\n' >&2; return 1 ;;
        esac
    done
    for arg in git curl tar gzip unzip; do
        command -v "$arg" >/dev/null || { printf '缺少依赖: %s\n' "$arg" >&2; return 1; }
    done
    # 服务模板使用绝对路径；拒绝会影响模板或 Shell 解析的字符。
    [[ $install_home == /* && $install_home != / && $install_home != "$HOME" && $install_home != *[^a-zA-Z0-9_./-]* ]] || {
        printf '安装目录必须是绝对路径，且只包含字母、数字、_、.、/、-\n' >&2
        return 1
    }
    if [ -e "$install_home" ] || [ -L "$install_home" ]; then
        printf '安装目录已存在: %s；已安装时请运行 clashupdate\n' "$install_home" >&2
        return 1
    fi
    mkdir -p -- "$(dirname -- "$install_home")"
    stage=$(mktemp -d "${install_home}.download.XXXXXX")
    trap '[ -z "$stage" ] || rm -rf -- "$stage"' EXIT
    local url=https://github.com/nelvko/clash-for-linux-install.git
    [ -z "$proxy" ] || url="${proxy%/}/$url"
    git -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=60 \
        clone --depth 1 --branch "$branch" -- "$url" "$stage"
    [ -f "$stage/scripts/cmd/install.sh" ] || { printf '安装源码不完整\n' >&2; return 1; }
    mv -T -- "$stage" "$install_home"
    stage=''
    export CLASHCTL_HOME="$install_home" CLASHCTL_SRC="$install_home" CLASHCTL_KERNEL="$kernel"
    export CLASHCTL_UPDATE_BRANCH="$branch" GH_PROXY="$proxy"
    . "$install_home/scripts/cmd/install.sh"
    _install_initialize || {
        printf '安装未完成；排查错误后运行 bash %s/scripts/cmd/install.sh 重试\n' "$install_home" >&2
        return 1
    }
)

# 完整读取脚本后才执行，下载中断时不会提前开始安装。
main "$@"
