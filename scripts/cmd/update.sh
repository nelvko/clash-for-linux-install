#!/usr/bin/env bash

clashupdate() {
    case ${1:-} in
    -h | --help)
        printf '用法: clashupdate\n更新脚本与资源，保留用户配置和内核。来源由 .env 中 CLASHCTL_UPDATE_BRANCH 和 GH_PROXY 配置。\n'
        return 0 ;;
    '') ;;
    *) _ui_error '用法: clashupdate'; return 1 ;;
    esac
    _update_scripts || return 1
    . "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" || {
        _ui_error '脚本已更新，但当前 Shell 加载失败，请重开终端'
        return 1
    }
    _ui_ok_out '更新完成，当前 Shell 已加载新版本'
}

_update_scripts() (
    set -o pipefail
    operation_lock_acquire || return 1
    local branch=${CLASHCTL_UPDATE_BRANCH:-master} url target dirty method work stage
    [ -f "$CLASHCTL_HOME/.env" ] || { _ui_error '未找到安装配置'; return 1; }
    # 复用安装入口中的源码下载与检查，不执行初始化。
    # shellcheck source=/dev/null  # 只加载函数，安装入口有执行保护。
    . "$CLASHCTL_HOME/install.sh" || return 1
    method=$(_install_method "$(cd -- "$CLASHCTL_HOME" && pwd -P)") || {
        _ui_error '缺少匹配的安装标记，已停止更新'
        return 1
    }
    work=$(mktemp -d "${CLASHCTL_HOME}.update.XXXXXX") || return 1
    stage="$work/source"
    mkdir "$stage" || return 1
    trap '[ -f "$work/keep" ] || rm -rf -- "$work"' EXIT
    _ui_step "下载更新：$branch"
    if [ "$method" = git ]; then
        if ! command -v git >/dev/null 2>&1 || [ ! -d "$CLASHCTL_HOME/.git" ] || [ -L "$CLASHCTL_HOME/.git" ]; then
            _ui_error '此安装使用 Git，请先恢复 git 命令或仓库；不会自动切换安装类型'
            return 1
        fi
        dirty=$(git -C "$CLASHCTL_HOME" status --porcelain --untracked-files=no) || return 1
        [ -z "$dirty" ] || { _ui_error '安装目录存在本地代码修改，请提交或暂存后重试'; return 1; }
        url=$(gh_proxy_url 'https://github.com/nelvko/clash-for-linux-install.git')
        git -C "$CLASHCTL_HOME" -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=60 \
            fetch --depth 1 -- "$url" "$branch" || return 1
        target=$(git -C "$CLASHCTL_HOME" rev-parse FETCH_HEAD) || return 1
        git -C "$CLASHCTL_HOME" archive "$target" | tar -x -C "$stage" || return 1
    else
        if [ -e "$CLASHCTL_HOME/.git" ] || [ -L "$CLASHCTL_HOME/.git" ]; then
            _ui_error '压缩包安装目录出现 Git 元数据，已停止更新'
            return 1
        fi
        _source_archive "$stage" "$branch" "${GH_PROXY:-}" || return 1
    fi
    [ ! -e "$stage/.git" ] && [ ! -L "$stage/.git" ] || return 1
    _source_validate "$stage" || return 1
    if [ "$method" = git ]; then
        git -C "$CLASHCTL_HOME" checkout --detach -q "$target" || return 1
        (umask 077; printf '%s\ngit\n' "$(cd -- "$CLASHCTL_HOME" && pwd -P)" >"$CLASHCTL_HOME/.clashctl-install")
    else
        _update_archive "$stage" "$work"
    fi
)

# 检查整个目标路径，防止通过目录软链接覆盖安装目录以外的文件。
_update_path_safe() {
    local path=$1
    while [ "$path" != . ]; do
        [ ! -L "$CLASHCTL_HOME/$path" ] || return 1
        path=$(dirname -- "$path")
        [ ! -e "$CLASHCTL_HOME/$path" ] || [ -d "$CLASHCTL_HOME/$path" ] || return 1
    done
}

_update_archive() (
    set -o pipefail
    local stage=$1 work=$2 hash file started=false complete=false failed=false
    local manifest="$CLASHCTL_HOME/.clashctl-files"
    local -a old_files=() new_files=()
    local -A old_set=() new_set=()
    if [ ! -f "$manifest" ] || [ -L "$manifest" ]; then
        _ui_error '源码文件清单缺失，已停止更新'; return 1
    fi
    while read -r hash file; do
        if [[ ! "$hash" =~ ^[0-9a-f]{64}$ ]] || [[ "$file" != ./* ]] ||
            ! _source_path_allowed "$file" || ! _update_path_safe "$file" || [ ! -f "$CLASHCTL_HOME/$file" ]; then
            _ui_error '源码文件清单或安装路径无效'; return 1
        fi
        old_files+=("$file")
        old_set[$file]=1
    done <"$manifest"
    [ "${#old_files[@]}" -gt 0 ] || return 1
    (cd -- "$CLASHCTL_HOME" && sha256sum --status -c .clashctl-files) || {
        _ui_error '安装目录存在本地代码修改或缺失文件，请恢复后重试'
        return 1
    }
    _source_manifest "$stage" >"$stage/.clashctl-files" || return 1
    while read -r hash file; do
        _update_path_safe "$file" || { _ui_error "更新路径无法安全使用：$file"; return 1; }
        if [ -e "$CLASHCTL_HOME/$file" ]; then
            if [ ! -f "$CLASHCTL_HOME/$file" ] || [ "${old_set[$file]:-}" != 1 ]; then
                _ui_error "更新会覆盖非托管文件：$file"
                return 1
            fi
        fi
        new_files+=("$file")
        new_set[$file]=1
    done <"$stage/.clashctl-files"
    tar -cf "$work/previous.tar" -C "$CLASHCTL_HOME" -- "${old_files[@]}" .clashctl-files || return 1
    # 更新失败只恢复程序文件；订阅、组件和运行数据始终不参与替换。
    trap '
        if [ "$started" = true ] && [ "$complete" = false ]; then
            for file in "${new_files[@]}"; do
                [ "${old_set[$file]:-}" = 1 ] || rm -f -- "$CLASHCTL_HOME/$file" || failed=true
            done
            tar -xf "$work/previous.tar" -C "$CLASHCTL_HOME" || failed=true
            if [ "$failed" = true ]; then
                touch "$work/keep"
                _ui_error "恢复源码失败，备份保留在 $work/previous.tar"
            else
                _ui_error "更新未完成，原程序文件已恢复"
            fi
        fi
    ' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    started=true
    tar -cf - -C "$stage" -- "${new_files[@]}" .clashctl-files |
        tar -xf - -C "$CLASHCTL_HOME" || return 1
    for file in "${old_files[@]}"; do
        [ "${new_set[$file]:-}" = 1 ] || rm -f -- "$CLASHCTL_HOME/$file" || return 1
    done
    complete=true
)
