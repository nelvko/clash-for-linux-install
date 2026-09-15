#!/usr/bin/env bash

_update_is_git_home() {
    [ -d "$CLASHCTL_HOME/.git" ]
}

_update_scripts() (
    set -o pipefail
    operation_lock_acquire || return 1
    local branch=${CLASHCTL_UPDATE_BRANCH:-master} url target dirty
    if ! _update_is_git_home || [ ! -f "$CLASHCTL_HOME/.env" ]; then
        _ui_error '未找到 Git 安装目录，请先运行安装脚本'
        return 1
    fi
    dirty=$(git -C "$CLASHCTL_HOME" status --porcelain --untracked-files=no) || return 1
    [ -z "$dirty" ] || {
        _ui_error '安装目录存在本地代码修改，请提交或暂存后重试'
        return 1
    }
    url=$(gh_proxy_url 'https://github.com/nelvko/clash-for-linux-install.git')
    _ui_step "下载更新：$branch"
    git -C "$CLASHCTL_HOME" -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=60 \
        fetch --depth 1 -- "$url" "$branch" || return 1
    target=$(git -C "$CLASHCTL_HOME" rev-parse FETCH_HEAD) || return 1
    # 在切换前检查脚本语法；不重新安装组件、重写配置或重启代理。
    local stage file
    stage=$(mktemp -d) || return 1
    trap 'rm -rf -- "$stage"' EXIT
    git -C "$CLASHCTL_HOME" archive "$target" | tar -x -C "$stage" || return 1
    for file in .env.example scripts/cmd/clashctl.sh scripts/cmd/install.sh scripts/cmd/update.sh; do
        [ -f "$stage/$file" ] || { _ui_error "更新版本缺少必需文件：$file"; return 1; }
    done
    for file in .env data bin resources/dist; do
        if [ -e "$stage/$file" ] || [ -L "$stage/$file" ]; then
            _ui_error "更新版本包含用户数据路径，已停止：$file"
            return 1
        fi
    done
    while IFS= read -r -d '' file; do
        bash -n "$file" || return 1
    done < <(find "$stage/scripts" -name '*.sh' -type f -print0)
    git -C "$CLASHCTL_HOME" checkout --detach -q "$target" || return 1
)
