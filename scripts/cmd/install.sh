#!/usr/bin/env bash

# shellcheck disable=SC2030,SC2031  # 安装和按需下载各自在子 shell 中设置路径

# UI 和订阅转换器沿用按需下载。
_ci_provision() (
    export CLASHCTL_SRC="$CLASHCTL_HOME"
    operation_lock_acquire || return 1
    . "$CLASHCTL_SRC/scripts/preflight.sh" || return 1
    provision_component "$1"
)

_install_initialize() (
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
)

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    export CLASHCTL_HOME="$(cd -- "$(dirname -- "$0")/../.." && pwd -P)"
    _install_initialize
fi
