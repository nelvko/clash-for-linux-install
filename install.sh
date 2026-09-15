#!/usr/bin/env bash

_install_initialize() {
    [ ! -f "$CLASHCTL_HOME/.env" ] || . "$CLASHCTL_HOME/.env"
    local kernel=${CLASHCTL_KERNEL:-mihomo} branch=${CLASHCTL_UPDATE_BRANCH:-master}
    local proxy=${GH_PROXY:-} subscription='' rc secret
    export -n subscription secret
    export CLASHCTL_SRC="$CLASHCTL_HOME"
    . "$CLASHCTL_SRC/scripts/preflight.sh" || return 1
    export CLASHCTL_KERNEL="$kernel" CLASHCTL_UPDATE_BRANCH="$branch" GH_PROXY="$proxy"
    BIN_KERNEL=$(bin_kernel_path)
    operation_lock_acquire || return 1
    valid_required || return 1
    detect_service_manager
    _service_check_conflict || return 1

    _ui_step '准备运行组件'
    install -d -m 0700 "$CLASH_DATA_DIR" "$CLASH_PROFILES_DIR" || return 1
    local source target
    for source in mixin.yaml.example profiles.yaml; do
        target="$CLASH_DATA_DIR/${source%.example}"
        [ -f "$target" ] || install -m 0600 "$CLASH_RESOURCES_DIR/$source" "$target" || return 1
    done
    [ -f "$CLASH_CONFIG_BASE" ] || install -m 0600 /dev/null "$CLASH_CONFIG_BASE" || return 1
    prepare_zip kernel yq || return 1
    [ -f "$CLASHCTL_HOME/.env" ] || install -m 0600 "$CLASHCTL_HOME/.env.example" "$CLASHCTL_HOME/.env" || return 1
    _set_env CLASHCTL_KERNEL "$kernel" || return 1
    _set_env CLASHCTL_UPDATE_BRANCH "$branch" || return 1
    _set_env GH_PROXY "$proxy" || return 1
    # shellcheck disable=SC2154  # detect_service_manager 设置
    _set_env INIT_TYPE "$service_manager" || return 1
    . "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" || return 1

    _ui_step '初始化配置与服务'
    _merge_config || return 1
    _detect_proxy_port || return 1
    _detect_ext_addr || return 1
    secret=$(_get_secret) || return 1
    if [ -z "$secret" ]; then
        secret=$(_get_random_val) || return 1
        SECRET=$secret "$BIN_YQ" -i '.secret = env(SECRET)' "$CLASH_CONFIG_MIXIN" || return 1
        _merge_config || return 1
    fi
    install_service || return 1
    service_start || return 1
    sleep 1
    service_is_active || { _ui_error '服务未能启动，请检查内核日志'; return 1; }
    apply_rc || { rc=$?; [ "$rc" -eq 2 ] || return "$rc"; }

    if [ "${CI+x}" != x ] && ( : </dev/tty ) 2>/dev/null; then
        IFS= read -r -s -p '订阅链接（回车跳过）: ' subscription </dev/tty || subscription=''
        printf '\n' >/dev/tty
    fi
    if [ -n "$subscription" ]; then
        clashsub add --use "$subscription" || return 1
    fi
    _ui_ok '安装完成'
    _ui_detail '加载命令' "重开终端，或执行 export CLASHCTL_HOME=$CLASHCTL_HOME; source \$CLASHCTL_HOME/scripts/cmd/clashctl.sh"
    _ui_detail '更新脚本' 'clashupdate'
}

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
    # 服务单元名与内核二进制路径都派生自它，必须在 sourcing 前导出。
    export CLASHCTL_KERNEL="$kernel"
    for arg in git curl tar gzip unzip; do
        command -v "$arg" >/dev/null || { printf '缺少依赖: %s\n' "$arg" >&2; return 1; }
    done
    # 服务模板使用绝对路径；拒绝会影响模板或 Shell 解析的字符。
    [[ $install_home == /* && $install_home != / && $install_home != "$HOME" && $install_home != *[^a-zA-Z0-9_./-]* ]] || {
        printf '安装目录必须是绝对路径，且只包含字母、数字、_、.、/、-\n' >&2
        return 1
    }
    if [ -e "$install_home" ] || [ -L "$install_home" ]; then
        # 允许直接执行安装目录中的脚本重试初始化，不覆盖或重新下载目录。
        local script_dir=''
        if [ -f "${BASH_SOURCE[0]:-}" ]; then
            script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
        fi
        if [ ! -d "$install_home/.git" ] || [ "$script_dir" != "$(cd -- "$install_home" && pwd -P)" ]; then
            printf '安装目录已存在: %s；已安装时请运行 clashupdate\n' "$install_home" >&2
            return 1
        fi
    else
        mkdir -p -- "$(dirname -- "$install_home")"
        stage=$(mktemp -d "${install_home}.download.XXXXXX")
        trap '[ -z "$stage" ] || rm -rf -- "$stage"' EXIT
        local url=https://github.com/nelvko/clash-for-linux-install.git
        [ -z "$proxy" ] || url="${proxy%/}/$url"
        git -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=60 \
            clone --depth 1 --branch "$branch" -- "$url" "$stage"
        [ -f "$stage/scripts/preflight.sh" ] || { printf '安装源码不完整\n' >&2; return 1; }
        mv -T -- "$stage" "$install_home"
        stage=''
    fi
    export CLASHCTL_HOME="$install_home" CLASHCTL_SRC="$install_home" CLASHCTL_KERNEL="$kernel"
    export CLASHCTL_UPDATE_BRANCH="$branch" GH_PROXY="$proxy"
    _install_initialize || {
        printf '安装未完成；排查错误后运行 CLASHCTL_HOME=%s bash %s/install.sh 重试\n' "$install_home" "$install_home" >&2
        return 1
    }
)

# 完整读取脚本后才执行，下载中断时不会提前开始安装。
main "$@"
