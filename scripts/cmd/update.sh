#!/usr/bin/env bash

_update_has_control_chars() {
    [[ $1 =~ [[:cntrl:]] ]]
}

_update_reload_shell() {
    local action=$1 loader="${CLASHCTL_HOME}/scripts/cmd/clashctl.sh"

    # shellcheck disable=SC1090  # Installed loader path is determined at runtime.
    if [ ! -r "$loader" ] || ! (set -e; . "$loader"); then
        _errorcat "${action}已写入磁盘，但当前 Shell 重新加载失败；请执行 exec bash 或新开终端"
        return 1
    fi
    # shellcheck disable=SC1090  # Installed loader path is determined at runtime.
    if ! . "$loader"; then
        _errorcat "${action}已写入磁盘，但当前 Shell 重新加载失败；请执行 exec bash 或新开终端"
        return 1
    fi
    return 0
}

clashupdate() {
    local check=false force=false rollback=false
    local branch=${CLASHCTL_UPDATE_BRANCH:-master}
    local operation_rc=0 argument _UPDATE_TERMINAL_RESULT=

    for argument in "$@"; do
        _update_has_control_chars "$argument" || continue
        _errorcat '更新参数不能包含换行、制表符或其他控制字符'
        return 1
    done

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
            update_help >&2
            return 1
            ;;
        esac
        shift
    done

    if _update_has_control_chars "$branch"; then
        _errorcat '更新分支不能包含换行、制表符或其他控制字符'
        return 1
    fi

    _update_require_install || return 1
    operation_lock_acquire || return 1

    if [ "$rollback" = true ]; then
        clashupdate_rollback "$branch" || operation_rc=$?
    elif _update_is_git_home; then
        clashupdate_git "$check" "$force" "$branch" || operation_rc=$?
    else
        clashupdate_archive "$check" "$force" "$branch" || operation_rc=$?
    fi

    if ! operation_lock_close_fd; then
        _ui_error '更新操作已结束，但无法关闭生命周期锁文件描述符'
        operation_rc=1
    elif [ "$operation_rc" -eq 0 ] && [ -n "$_UPDATE_TERMINAL_RESULT" ]; then
        _ui_ok_out "$_UPDATE_TERMINAL_RESULT"
    fi
    return "$operation_rc"
}

# ── git 引擎入口（home 即 git 仓库）────────────────────────

clashupdate_git() {
    local check=$1 force=$2 branch=$3
    local fetch_head status kind n

    _ui_info_out "当前版本：$(_update_local_rev)（${branch}）"
    _ui_step "检查远端版本：${branch}"
    fetch_head=$(_update_fetch "$branch") || {
        _errorcat "无法获取远端版本（网络受限或远端不可达），请检查网络或在 .env 配置 GH_PROXY/CLASHCTL_UPDATE_GIT_URL"
        return 1
    }

    status=$(_update_status "$fetch_head") || {
        _errorcat '无法比较本地与远端版本，更新未开始'
        return 1
    }
    kind=${status%% *}
    n=${status#* }
    case $kind in
    identical | behind | ahead | diverged) ;;
    *)
        _errorcat '远端版本状态无效，更新未开始'
        return 1
        ;;
    esac

    if [ "$check" = true ]; then
        _ui_info_out "最新版本：${fetch_head:0:7}（${branch}）"
        case $kind in
        identical)
            _ui_ok_out '已是最新版本'
            ;;
        behind)
            _ui_info_out "有新版本可用（落后 ${n} 个提交），执行 clashctl update 更新"
            ;;
        ahead)
            _ui_ok_out "当前版本领先远端 ${n} 个提交（可能为未推送的本地安装），无需更新"
            ;;
        diverged)
            _ui_info_out "远端 ${branch} 与当前版本已分叉，执行 clashctl update 将更新到远端版本"
            ;;
        esac
        return 0
    fi

    case $kind in
    identical)
        [ "$force" = true ] || {
            _ui_ok_out "已是最新版本（如需强制重刷：clashctl update --force）"
            return 0
        }
        ;;
    ahead)
        [ "$force" = true ] || {
            _ui_ok_out "当前版本领先远端 ${n} 个提交（可能为未推送的本地安装），已跳过更新（--force 可强制）"
            return 0
        }
        ;;
    behind)
        _ui_info "发现新版本：落后 ${n} 个提交（→ ${fetch_head:0:7}）"
        ;;
    diverged)
        _ui_info "远端 ${branch} 与当前版本分叉，将更新到远端版本"
        ;;
    esac

    # 脏树拒绝（bash-it 式）：跟踪文件被本地修改时不覆盖
    local dirty dirty_rc
    if dirty=$(_update_dirty); then
        _errorcat "检测到本地修改了被跟踪的文件，已拒绝更新："
        printf '%s\n' "$dirty" | head -10 >&2
        _errorcat "处理：cd ${CLASHCTL_HOME} && git checkout -- <文件> 丢弃修改，或 git stash 暂存后重试"
        return 1
    else
        dirty_rc=$?
    fi
    if [ "$dirty_rc" -ne 1 ]; then
        _errorcat '无法检查本地文件修改，更新未开始'
        return 1
    fi

    _update_check_env || return 1

    # 部署前校验提交与官方一致（镜像篡改防护；直连不可达时降级警告）
    _update_verify_commit "$branch" "$fetch_head" || return 1

    # 部署置于子 shell：锁随子 shell 释放，不影响当前交互 shell
    (
        _update_acquire_lock || exit 1
        _update_capture_state
        local prev restore_rc=0
        prev=$(git -C "$CLASHCTL_HOME" rev-parse HEAD) || {
            _update_release_lock
            _errorcat '无法读取当前版本，更新未开始'
            exit 1
        }
        _ui_step "部署更新：${prev:0:7} → ${fetch_head:0:7}"
        git -C "$CLASHCTL_HOME" checkout -q "$fetch_head" || {
            _update_release_lock
            _errorcat "checkout 失败，未做任何变更"
            exit 1
        }
        _ui_step '刷新环境、配置与服务状态'
        if ! _update_side_effects; then
            _ui_error '更新后置步骤失败，正在自动恢复'
            git -C "$CLASHCTL_HOME" checkout -q "$prev" || restore_rc=1
            if [ "$restore_rc" -eq 0 ]; then
                _ui_step '恢复更新前的环境、配置与服务状态'
                _update_side_effects || restore_rc=1
            fi
            _update_release_lock
            if [ "$restore_rc" -eq 0 ]; then
                _errorcat "更新失败；代码已恢复到 ${prev:0:7}，配置与服务已重新刷新"
            else
                _ui_error '更新失败，且自动恢复不完整'
                _ui_detail '原版本' "${prev:0:7}"
                _ui_detail '处理' '检查当前版本与服务状态后重试；Git reflog 保留了更新前版本'
            fi
            exit 1
        fi
        _update_release_lock
        _ui_ok_out "版本：${prev:0:7} → ${fetch_head:0:7}"
        if [ -f "$CLASH_CONFIG_MIXIN" ] &&
            git -C "$CLASHCTL_HOME" diff --name-only "$prev" "$fetch_head" --
                resources/mixin.yaml.example 2>/dev/null | grep -q .; then
            _ui_warn "mixin.yaml 保留用户版本，上游模板本次有更新，可对照 ${CLASH_RESOURCES_DIR}/mixin.yaml.example"
        fi
        exit 0
    )
    local rc=$?
    [ "$rc" -ne 0 ] && return "$rc"

    # 重载当前 shell 的函数与 .env（其余已开终端不受影响）
    _update_reload_shell '更新' || return 1
    _UPDATE_TERMINAL_RESULT='更新完成，当前 Shell 已自动加载新版本。'
    return 0
}

# 回退到上一版本（git 安装：checkout HEAD@{1}；归档安装：恢复最近一份 .bak）
clashupdate_rollback() {
    local branch=$1 bak backups=()

    if _update_is_git_home; then
        _update_check_env || return 1
        (
            _update_acquire_lock || exit 1
            _update_capture_state
            local cur cur_short target target_short restore_rc=0
            cur=$(git -C "$CLASHCTL_HOME" rev-parse HEAD) || {
                _update_release_lock
                _errorcat '无法读取当前版本，回退未开始'
                exit 1
            }
            target=$(git -C "$CLASHCTL_HOME" rev-parse 'HEAD@{1}') || {
                _update_release_lock
                _errorcat "无更早版本可回退（git reflog 只剩当前版本）"
                exit 1
            }
            cur_short=${cur:0:7}
            target_short=${target:0:7}
            _ui_step "回退版本：${cur_short} → ${target_short}"
            git -C "$CLASHCTL_HOME" checkout -q "$target" || {
                _update_release_lock
                _errorcat '无法切换到目标版本，回退未生效'
                exit 1
            }
            _ui_step '刷新环境、配置与服务状态'
            if ! _update_side_effects; then
                _ui_error '回退后置步骤失败，正在恢复回退前版本'
                git -C "$CLASHCTL_HOME" checkout -q "$cur" || restore_rc=1
                if [ "$restore_rc" -eq 0 ]; then
                    _ui_step '恢复回退前的环境、配置与服务状态'
                    _update_side_effects || restore_rc=1
                fi
                _update_release_lock
                if [ "$restore_rc" -eq 0 ]; then
                    _errorcat "回退失败；已恢复到 ${cur_short}"
                else
                    _ui_error '回退失败，且自动恢复不完整'
                    _ui_detail '原版本' "$cur_short"
                    _ui_detail '处理' '检查当前版本与服务状态后重试'
                fi
                exit 1
            fi
            _update_release_lock
            _ui_ok_out "已回退：${cur_short} → ${target_short}（${branch}）"
        ) || return 1
    else
        shopt -s nullglob
        backups=("${CLASHCTL_HOME}"/.bak/clashctl-backup-*.tar.gz)
        shopt -u nullglob
        [ ${#backups[@]} -gt 0 ] || {
            _errorcat "无可用备份（${CLASHCTL_HOME}/.bak）"
            return 1
        }
        bak=${backups[${#backups[@]}-1]}
        (
            _update_acquire_lock || exit 1
            _update_capture_state
            _ui_step "恢复备份：$bak"
            _update_archive_restore "$bak" || {
                _update_release_lock
                _errorcat "回滚失败！请手动恢复：$bak"
                exit 1
            }
            _ui_step '刷新环境、配置与服务状态'
            _update_side_effects || {
                _update_release_lock
                _errorcat "备份文件已恢复，但配置或服务状态刷新失败：$bak"
                exit 1
            }
            _update_release_lock
            _ui_ok_out "已回退到备份：$bak"
        ) || return 1
    fi

    _update_reload_shell '回退' || return 1
    _UPDATE_TERMINAL_RESULT='回退完成。建议新开终端加载旧函数'
    return 0
}

# ── 归档回落入口（无 .git 的安装）──────────────────────────

clashupdate_archive() {
    local check=$1 force=$2 branch=$3
    local remote rev tmp backup

    rev=$(grep -E '^CLASHCTL_REV=' "${CLASHCTL_HOME}/.env" 2>/dev/null | tail -1 | cut -d= -f2-)
    _ui_info_out "当前版本：${rev:-unknown}（${branch}）"

    _ui_step "检查远端版本：${branch}"
    remote=$(_update_remote_sha "$_UPDATE_REPO" "$branch")
    if [ "$check" = true ]; then
        [ -n "$remote" ] || {
            _errorcat "无法获取远端版本（网络受限或 API 限流），请检查网络或在 .env 配置 GH_PROXY"
            return 1
        }
        _ui_info_out "最新版本：${remote:0:7}（${branch}）"
        if [ "$remote" = "$rev" ]; then
            _ui_ok_out '已是最新版本'
        else
            _ui_info_out '有新版本可用，执行 clashctl update 更新'
        fi
        return 0
    fi

    if [ -n "$remote" ] && [ "$remote" = "$rev" ] && [ "$force" != true ]; then
        _ui_ok_out "已是最新版本（如需强制重新部署：clashctl update --force）"
        return 0
    fi

    _update_check_env || return 1
    (
        _update_acquire_lock || exit 1
        _update_capture_state
        local item deploy_rc=0 restore_rc=0 code_restore_rc=0 revision_changed=false

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
        if ! _update_validate_archive_tree "$tmp"; then
            /usr/bin/rm -rf -- "$tmp"
            _update_release_lock
            _errorcat '更新归档不完整，已中止（尚未部署任何文件）'
            exit 1
        fi

        _ui_step '创建更新前备份'
        backup=$(_update_archive_backup) || {
            /usr/bin/rm -rf -- "$tmp"
            _update_release_lock
            _errorcat "备份失败，已中止（未改动任何文件）"
            exit 1
        }

        # 替换代码面（data/、.env、bin/、dist/ 不在清单内）
        _ui_step '部署更新文件'
        mixin_example_before=$(sha256sum -- "$CLASH_RESOURCES_DIR/mixin.yaml.example" 2>/dev/null ||
            printf 'none')
        for item in "${_UPDATE_ARCHIVE_PATHS[@]}"; do
            [ -e "${tmp:?}/${item}" ] || continue
            /usr/bin/rm -rf -- "${CLASHCTL_HOME:?}/${item}"
            cp -a "${tmp}/${item}" "${CLASHCTL_HOME}/${item}" || deploy_rc=1
        done
        /usr/bin/rm -rf -- "$tmp"
        if [ "$deploy_rc" -ne 0 ]; then
            _errorcat '部分更新文件写入失败'
        fi

        if [ "$deploy_rc" -eq 0 ]; then
            if _set_env CLASHCTL_REV "${remote:-unknown}"; then
                revision_changed=true
            else
                _errorcat '无法写入更新后的版本记录'
                deploy_rc=1
            fi
        fi
        if [ "$deploy_rc" -eq 0 ]; then
            _ui_step '刷新环境、配置与服务状态'
            _update_side_effects || deploy_rc=1
        fi

        if [ "$deploy_rc" -ne 0 ]; then
            _ui_error '更新部署未完成，正在自动恢复'
            _update_archive_restore "$backup" || {
                code_restore_rc=1
                restore_rc=1
            }
            if [ "$code_restore_rc" -eq 0 ]; then
                if [ "$revision_changed" = true ]; then
                    _set_env CLASHCTL_REV "${rev:-unknown}" || restore_rc=1
                fi
                _ui_step '恢复更新前的环境、配置与服务状态'
                _update_side_effects || restore_rc=1
            fi
            _update_release_lock
            if [ "$restore_rc" -eq 0 ]; then
                _errorcat "更新失败；代码已恢复到更新前版本，配置与服务已重新刷新；备份保留：$backup"
            else
                _ui_error '更新失败，且自动恢复不完整'
                _ui_detail '备份' "$backup"
                _ui_detail '处理' '检查安装目录与服务状态；必要时手动恢复该备份'
            fi
            exit 1
        fi
        _update_prune_backups 3 || _ui_warn '更新已部署，但旧备份清理失败'
        _update_release_lock
        _ui_info_out "备份：$backup"
        _ui_info_out "版本：${rev:-unknown} → ${remote:-unknown}"
        mixin_example_after=$(sha256sum -- "$CLASH_RESOURCES_DIR/mixin.yaml.example" 2>/dev/null ||
            printf 'none')
        if [ -f "$CLASH_CONFIG_MIXIN" ] && [ "$mixin_example_before" != "$mixin_example_after" ]; then
            _ui_warn "mixin.yaml 保留用户版本，上游模板本次有更新，可对照 ${CLASH_RESOURCES_DIR}/mixin.yaml.example"
        fi
    ) || return 1

    _update_reload_shell '更新' || return 1
    _UPDATE_TERMINAL_RESULT='更新完成，当前 Shell 已自动加载新版本。'
    return 0
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
      订阅、mixin、密钥与内核二进制全部保留；本地修改过跟踪文件时更新会被拒绝；
      脚本、配置、服务与 Shell 集成全部刷新成功后才会报告完成，失败时尝试自动恢复。

EOF
}
