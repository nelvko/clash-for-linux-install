#!/usr/bin/env bash

clashupdate() {
    local check=false force=false rollback=false
    local branch=${CLASHCTL_UPDATE_BRANCH:-master}
    while [ $# -gt 0 ]; do
        case $1 in
        -c | --check) check=true ;;
        -f | --force) force=true ;;
        -r | --rollback) rollback=true ;;
        -b | --branch)
            shift
            [ $# -gt 0 ] || {
                _errorcat "--branch 缺少参数"
                return 1
            }
            branch=$1
            ;;
        -h | --help)
            update_help
            return 0
            ;;
        *)
            _errorcat "未知参数：$1"
            update_help
            return 1
            ;;
        esac
        shift
    done

    _update_require_install || return 1

    if [ "$rollback" = true ]; then
        clashupdate_rollback "$branch"
        return $?
    fi

    if _update_is_git_home; then
        clashupdate_git "$check" "$force" "$branch"
    else
        clashupdate_archive "$check" "$force" "$branch"
    fi
}

# ── git 引擎入口（home 即 git 仓库）────────────────────────

clashupdate_git() {
    local check=$1 force=$2 branch=$3
    local fetch_head status kind n

    _okcat "当前版本：$(_update_local_rev)（${branch}）"
    fetch_head=$(_update_fetch "$branch") || {
        _errorcat "无法获取远端版本（网络受限或远端不可达），请检查网络或在 .env 配置 GH_PROXY/CLASHCTL_UPDATE_GIT_URL"
        return 1
    }

    status=$(_update_status "$fetch_head")
    kind=${status%% *}
    n=${status#* }

    if [ "$check" = true ]; then
        _okcat "最新版本：${fetch_head:0:7}（${branch}）"
        case $kind in
        identical)
            _okcat '✅' '已是最新版本'
            ;;
        behind)
            _failcat '🍂' "有新版本可用（落后 ${n} 个提交），执行 clashctl update 更新"
            ;;
        ahead)
            _okcat '✅' "当前版本领先远端 ${n} 个提交（可能为未推送的本地安装），无需更新"
            ;;
        diverged)
            _failcat '🍂' "远端 ${branch} 与当前版本已分叉，执行 clashctl update 将更新到远端版本"
            ;;
        esac
        return 0
    fi

    case $kind in
    identical)
        [ "$force" = true ] || {
            _okcat '✅' "已是最新版本（如需强制重刷：clashctl update --force）"
            return 0
        }
        ;;
    ahead)
        [ "$force" = true ] || {
            _okcat '✅' "当前版本领先远端 ${n} 个提交（可能为未推送的本地安装），已跳过更新（--force 可强制）"
            return 0
        }
        ;;
    behind)
        _okcat '🔖' "发现新版本：落后 ${n} 个提交（→ ${fetch_head:0:7}）"
        ;;
    diverged)
        _okcat '🔖' "远端 ${branch} 与当前版本分叉，将更新到远端版本"
        ;;
    esac

    # 脏树拒绝（bash-it 式）：跟踪文件被本地修改时不覆盖
    local dirty
    dirty=$(_update_dirty) && {
        _errorcat "检测到本地修改了被跟踪的文件，已拒绝更新："
        printf '%s\n' "$dirty" | head -10 >&2
        _errorcat "处理：cd ${CLASHCTL_HOME} && git checkout -- <文件> 丢弃修改，或 git stash 暂存后重试"
        return 1
    }

    _update_check_env || return 1

    # 部署置于子 shell：锁随子 shell 释放，不影响当前交互 shell
    (
        _update_acquire_lock || exit 1
        _update_capture_state
        local prev
        prev=$(git -C "$CLASHCTL_HOME" rev-parse HEAD)
        git -C "$CLASHCTL_HOME" checkout -q "$fetch_head" || {
            _update_release_lock
            _errorcat "checkout 失败，未做任何变更"
            exit 1
        }
        if ! _update_side_effects; then
            # 新代码产不出有效配置：回退 checkout 并重刷副作用，恢复一致
            _errorcat "新版本配置校验失败，正在回退..."
            git -C "$CLASHCTL_HOME" checkout -q "$prev"
            _update_side_effects || true
            _update_release_lock
            _errorcat "已回退到 ${prev:0:7}"
            exit 1
        fi
        _update_release_lock
        _okcat '🔖' "版本：${prev:0:7} → ${fetch_head:0:7}"
        [ -f "$CLASH_CONFIG_MIXIN" ] &&
            _okcat '💡' "mixin.yaml 保留用户版本，上游模板改进需手动对照 ${CLASH_RESOURCES_DIR}/mixin.yaml.example"
    )
    local rc=$?
    [ "$rc" -ne 0 ] && return "$rc"

    # 重载当前 shell 的函数与 .env（其余已开终端不受影响）
    . "${CLASHCTL_HOME}/scripts/cmd/clashctl.sh"
    _okcat '😸' '更新完成。建议新开终端，或执行 source ~/.bashrc 加载新函数'
}

# 回退到上一版本（git 安装：checkout HEAD@{1}；归档安装：恢复最近一份 .bak）
clashupdate_rollback() {
    local branch=$1 bak

    if _update_is_git_home; then
        _update_check_env || return 1
        (
            _update_acquire_lock || exit 1
            _update_capture_state
            local prev cur
            cur=$(git -C "$CLASHCTL_HOME" rev-parse --short HEAD)
            git -C "$CLASHCTL_HOME" checkout -q 'HEAD@{1}' || {
                _update_release_lock
                _errorcat "无更早版本可回退（git reflog 只剩当前版本）"
                exit 1
            }
            prev=$(git -C "$CLASHCTL_HOME" rev-parse --short HEAD)
            _update_side_effects || true
            _update_release_lock
            _okcat '🔖' "已回退：${cur} → ${prev}（${branch}）"
        ) || return 1
    else
        bak=$(ls -1t "${CLASHCTL_HOME}"/.bak/clashctl-backup-*.tar.gz 2>/dev/null | head -1)
        [ -n "$bak" ] || {
            _errorcat "无可用备份（${CLASHCTL_HOME}/.bak）"
            return 1
        }
        (
            _update_acquire_lock || exit 1
            _update_capture_state
            _update_archive_restore "$bak" || {
                _update_release_lock
                _errorcat "回滚失败！请手动恢复：$bak"
                exit 1
            }
            _update_side_effects || true
            _update_release_lock
            _okcat '🔖' "已回退到备份：$bak"
        ) || return 1
    fi

    . "${CLASHCTL_HOME}/scripts/cmd/clashctl.sh"
    _okcat '😸' '回退完成。建议新开终端加载旧函数'
}

# ── 归档回落入口（无 .git 的安装）──────────────────────────

clashupdate_archive() {
    local check=$1 force=$2 branch=$3
    local remote rev tmp backup

    rev=$(grep -E '^CLASHCTL_REV=' "${CLASHCTL_HOME}/.env" 2>/dev/null | tail -1 | cut -d= -f2-)
    _okcat "当前版本：${rev:-unknown}（${branch}）"

    remote=$(_update_remote_sha "$_UPDATE_REPO" "$branch")
    if [ "$check" = true ]; then
        [ -n "$remote" ] || {
            _errorcat "无法获取远端版本（网络受限或 API 限流），请检查网络或在 .env 配置 GH_PROXY"
            return 1
        }
        _okcat "最新版本：${remote:0:7}（${branch}）"
        if [ "$remote" = "$rev" ]; then
            _okcat '✅' '已是最新版本'
        else
            _failcat '🍂' '有新版本可用，执行 clashctl update 更新'
        fi
        return 0
    fi

    if [ -n "$remote" ] && [ "$remote" = "$rev" ] && [ "$force" != true ]; then
        _okcat '✅' "已是最新版本（如需强制重新部署：clashctl update --force）"
        return 0
    fi

    _update_check_env || return 1
    (
        _update_acquire_lock || exit 1
        _update_capture_state

        backup=$(_update_archive_backup) || {
            _update_release_lock
            _errorcat "备份失败，已中止（未改动任何文件）"
            exit 1
        }

        tmp=$(mktemp -d) || {
            _update_release_lock
            exit 1
        }
        if ! _update_fetch_archive "$branch" "$tmp"; then
            /usr/bin/rm -rf -- "$tmp"
            _update_release_lock
            _errorcat "下载失败：请检查网络，或在 .env 设置 GH_PROXY=<加速前缀> 后重试"
            exit 1
        fi

        # 替换代码面（data/、.env、bin/、dist/ 不在清单内）
        local item rc=0
        for item in "${_UPDATE_ARCHIVE_PATHS[@]}"; do
            [ -e "${tmp:?}/${item}" ] || continue
            /usr/bin/rm -rf -- "${CLASHCTL_HOME:?}/${item}"
            cp -a "${tmp}/${item}" "${CLASHCTL_HOME}/${item}" || rc=1
        done
        /usr/bin/rm -rf -- "$tmp"
        if [ "$rc" -ne 0 ]; then
            _update_archive_restore "$backup" || {
                _update_release_lock
                _errorcat "回滚失败！请手动恢复：$backup"
                exit 1
            }
            _update_side_effects || true
            _update_release_lock
            _errorcat "部署失败，已回滚到更新前状态；备份保留：$backup"
            exit 1
        fi

        _set_env CLASHCTL_REV "${remote:-unknown}"
        if ! _update_side_effects; then
            _update_archive_restore "$backup"
            _update_side_effects || true
            _update_release_lock
            _errorcat "新版本配置校验失败，已回滚；备份保留：$backup"
            exit 1
        fi
        _update_prune_backups 3
        _update_release_lock
        _okcat '🗄️ ' "备份：$backup"
        _okcat '🔖' "版本：${rev:-unknown} → ${remote:-unknown}"
    ) || return 1

    . "${CLASHCTL_HOME}/scripts/cmd/clashctl.sh"
    _okcat '😸' '更新完成。建议新开终端，或执行 source ~/.bashrc 加载新函数'
}

update_help() {
    cat <<EOF
Usage:
  clashctl update [OPTIONS]

Options:
  -c, --check         仅检查当前与最新版本，不执行更新
  -f, --force         跳过版本比对，强制更新并重刷配置
  -b, --branch <name> 指定更新来源分支（默认 master，可在 .env 配置 CLASHCTL_UPDATE_BRANCH）
  -r, --rollback      回退到上一版本（git 安装回退上一提交，归档安装恢复最近备份）
  -h, --help          显示帮助信息

说明：更新 clashctl 本体脚本与资源（内核升级请用 clashctl upgrade）；
      订阅、mixin、密钥与内核二进制全部保留；本地修改过跟踪文件时更新会被拒绝。

EOF
}
