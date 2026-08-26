#!/usr/bin/env bash

# 自更新引擎（home 即 git 仓库）：fetch → 状态判定 → 脏树检查 → checkout → 副作用刷新
# 无 .git 的安装（归档装的）回落归档替换模式（保留 .bak 备份信封）

_UPDATE_REPO=nelvko/clash-for-linux-install

_update_require_install() {
    if [ ! -d "$CLASHCTL_HOME" ] || [ ! -f "${CLASHCTL_HOME}/.env" ]; then
        _errorcat "未检测到已安装的 clashctl（${CLASHCTL_HOME}），请先运行 install.sh 安装"
        return 1
    fi
    return 0
}

_update_check_env() {
    [ -w "$CLASHCTL_HOME" ] || {
        _errorcat "安装目录不可写：$CLASHCTL_HOME"
        return 1
    }

    local avail
    avail=$(df -Pk "$CLASHCTL_HOME" 2>/dev/null | awk 'NR==2{print $4}')
    if [ -n "$avail" ] && [ "$avail" -lt 65536 ]; then
        _errorcat "磁盘空间不足（可用 ${avail}KB < 64MB）"
        return 1
    fi

    detect_service_manager
    # shellcheck disable=SC2154  # Set by detect_service_manager.
    if [ "$service_manager" != nohup ] && ! _is_root; then
        _errorcat "当前使用 ${service_manager} 系统服务，更新需要 root 权限；请以 root 用户重新执行"
        return 1
    fi
    return 0
}

_update_is_git_home() {
    [ -d "${CLASHCTL_HOME}/.git" ]
}

# ── git 引擎 ──────────────────────────────────────────────

# 取源地址：CLASHCTL_UPDATE_GIT_URL > GH_PROXY 前缀拼接 > 官方 https
_update_git_url() {
    local url=${CLASHCTL_UPDATE_GIT_URL:-}
    [ -n "$url" ] || {
        url="https://github.com/${_UPDATE_REPO}.git"
        [ -n "${GH_PROXY:-}" ] && url="${GH_PROXY%/}/${url}"
    }
    printf '%s\n' "$url"
}

# fetch 指定分支；成功输出 FETCH_HEAD sha（lowSpeed 防镜像通道停滞挂死）
_update_fetch() {
    local branch=$1
    git -C "$CLASHCTL_HOME" remote set-url origin "$(_update_git_url)" || return 1
    git -C "$CLASHCTL_HOME" -c gc.auto=0 -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=60 \
        fetch -q --depth 50 origin -- "$branch" || return 1
    git -C "$CLASHCTL_HOME" rev-parse FETCH_HEAD
}

# 本地祖先关系判定，输出：identical / behind N / ahead N / diverged
_update_status() {
    local fetch_head=$1 head base n merge_rc
    head=$(git -C "$CLASHCTL_HOME" rev-parse HEAD) || return 1
    if [ "$head" = "$fetch_head" ]; then
        printf 'identical'
        return 0
    fi
    if base=$(git -C "$CLASHCTL_HOME" merge-base "$head" "$fetch_head" 2>/dev/null); then
        merge_rc=0
    else
        merge_rc=$?
    fi
    [ "$merge_rc" -le 1 ] || return 1
    if [ "$base" = "$head" ]; then
        n=$(git -C "$CLASHCTL_HOME" rev-list --count "$head..$fetch_head") || return 1
        printf 'behind %s' "$n"
    elif [ "$base" = "$fetch_head" ]; then
        n=$(git -C "$CLASHCTL_HOME" rev-list --count "$fetch_head..$head") || return 1
        printf 'ahead %s' "$n"
    else
        # 含无共同祖先（换了远端仓库/历史重写），按分叉处理
        printf 'diverged'
    fi
}

# 脏树检查：仅跟踪文件的修改（未跟踪文件不阻塞——checkout 冲突时 git 会自行拒绝）
# 有改动时输出清单并返回 0（调用方据此拒绝更新）
_update_dirty() {
    local out
    out=$(git -C "$CLASHCTL_HOME" diff --name-status HEAD 2>/dev/null) || return 2
    [ -n "$out" ] || return 1
    printf '%s\n' "$out"
    return 0
}

# git 安装的当前版本（短 sha）
_update_local_rev() {
    _update_is_git_home && git -C "$CLASHCTL_HOME" rev-parse --short HEAD 2>/dev/null ||
        printf '%s' "${CLASHCTL_REV:-unknown}"
}

# 远端分支 HEAD sha（无 git 元数据的安装 --check 时用；git 安装直接 fetch）
_update_remote_sha() {
    local repo=$1 branch=$2 sha
    local api="https://api.github.com/repos/${repo}/commits/${branch}"

    sha=$(curl -s --max-time 10 --retry 1 -H 'Accept: application/vnd.github.sha' "$api" 2>/dev/null)
    if ! [[ $sha =~ ^[0-9a-f]{40}$ ]] && [ -n "${GH_PROXY:-}" ]; then
        sha=$(curl -s --max-time 10 --retry 1 -H 'Accept: application/vnd.github.sha' \
            "${GH_PROXY%/}/${api}" 2>/dev/null)
    fi
    [[ $sha =~ ^[0-9a-f]{40}$ ]] && printf '%s\n' "$sha"
    return 0
}

# 无 .git 安装的 rev 记录来源
_update_source_rev() {
    local src=${1:-$CLASHCTL_SRC}
    git -C "$src" rev-parse HEAD 2>/dev/null || printf 'unknown\n'
}

# ── 副作用引擎（checkout 后刷新安装态）───────────────────────

_update_validate_tree() {
    local root=$1 loader="$1/scripts/cmd/clashctl.sh" file valid=true
    local had_nullglob=false had_globstar=false files=()

    [ -r "$loader" ] || {
        _errorcat '更新后的命令入口缺失或不可读'
        return 1
    }

    shopt -q nullglob && had_nullglob=true
    shopt -q globstar && had_globstar=true
    shopt -s nullglob globstar
    files=("$root"/scripts/**/*.sh)
    [ ! -f "$root/install.sh" ] || files+=("$root/install.sh")
    [ ! -f "$root/uninstall.sh" ] || files+=("$root/uninstall.sh")
    for file in "${files[@]}"; do
        bash -n "$file" || {
            valid=false
            break
        }
    done
    [ "$had_nullglob" = true ] || shopt -u nullglob
    [ "$had_globstar" = true ] || shopt -u globstar

    [ "$valid" = true ] || {
        _errorcat "更新脚本语法校验失败：$file"
        return 1
    }
    # shellcheck disable=SC1090  # Candidate loader path is determined at runtime.
    if ! (set -e; . "$loader"); then
        _errorcat '更新后的命令模块无法完整加载'
        return 1
    fi
    return 0
}

_update_capture_state() {
    _UPDATE_WAS_ACTIVE=false
    service_is_active >/dev/null 2>&1 && _UPDATE_WAS_ACTIVE=true
    return 0
}

# 服务单元差异重注册：内容相同零扰动（ExecStart 路径不变时的常态）；
# install_service 内部可能 exit，必须置于子 shell
_update_unit_refresh() {
    local target candidate

    detect_service_manager
    target=$(_service_target) || return 0

    candidate=$(mktemp) || {
        _errorcat '无法创建服务配置校验文件'
        return 1
    }
    CLASHCTL_SRC="$CLASHCTL_HOME" _render_service_unit "$candidate" || {
        /usr/bin/rm -f -- "$candidate"
        _errorcat "无法生成 ${service_manager} 服务配置"
        return 1
    }
    if cmp -s -- "$candidate" "$target" 2>/dev/null; then
        /usr/bin/rm -f -- "$candidate"
        return 0
    fi
    /usr/bin/rm -f -- "$candidate"
    if (CLASHCTL_SRC="$CLASHCTL_HOME" install_service) >/dev/null 2>&1; then
        _ui_ok_out "服务配置已更新：$target"
    else
        _errorcat "服务配置更新失败：$target"
        return 1
    fi
    return 0
}

# .env 补新键（对照新版本的 .env.example；只补缺，绝不覆盖既有键）
_env_add_missing() {
    local src=$1 dst=$2 line key

    [ -f "$src" ] && [ -f "$dst" ] || return 0
    while IFS= read -r line; do
        case "$line" in
        '' | '#'*) continue ;;
        *=*) ;;
        *) continue ;;
        esac
        key=${line%%=*}
        grep -qE "^${key}=" "$dst" && continue
        printf '%s\n' "$line" >>"$dst" || return 1
        _ui_ok_out "新增配置项：$key"
    done <"$src"
    return 0
}

_update_env_refresh() {
    _env_add_missing "${CLASHCTL_HOME}/.env.example" "${CLASHCTL_HOME}/.env" || return 1
}

# data/ 模板补缺（resources/*.example → data/<name>，已存在一律保留用户版本）
_update_data_refresh() {
    local tpl name target
    for tpl in "${CLASH_RESOURCES_DIR}"/*.example; do
        [ -f "$tpl" ] || continue
        name=${tpl##*/}
        name=${name%.example}
        target="${CLASH_DATA_DIR}/${name}"
        [ -e "$target" ] && continue
        cp "$tpl" "$target" || return 1
        _ui_ok_out "新增配置模板：data/${name}"
    done
    return 0
}

# 变更感知刷新运行配置：内容未变不打扰运行中的服务
# 返回 1 = 新代码产不出有效配置（调用方应回退 checkout 并重刷副作用）
_update_runtime_refresh() {
    local was_active=$1
    local snapshot="${CLASH_CONFIG_RUNTIME}.preupdate" rc

    if [ ! -f "$CLASH_CONFIG_RUNTIME" ]; then
        _merge_config >/dev/null 2>&1 && return 0
        _errorcat '无法生成运行配置，更新后置步骤未完成'
        return 1
    fi

    cat "$CLASH_CONFIG_RUNTIME" >"$snapshot" || {
        _errorcat '无法创建运行配置快照'
        return 1
    }
    # 校验失败时 _merge_config 已用 TEMP 将 runtime 回滚为旧配置
    _merge_config || {
        /usr/bin/rm -f -- "$snapshot"
        return 1
    }
    if cmp -s -- "$CLASH_CONFIG_RUNTIME" "$snapshot"; then
        /usr/bin/rm -f -- "$snapshot"
        if [ "$was_active" = true ] && ! service_is_active >/dev/null 2>&1; then
            service_start >/dev/null 2>&1 || {
                _errorcat '代理服务未能恢复运行，请检查代理内核日志'
                return 1
            }
        fi
        return 0
    fi
    /usr/bin/rm -f -- "$snapshot"

    [ "$was_active" = true ] || return 0
    _merge_config_restart
    rc=$?
    [ "$rc" -eq 1 ] && return 1
    if [ "$rc" -eq 2 ]; then
        _errorcat '配置已生成，但服务重启失败，请检查代理内核日志'
        return 1
    fi
    return 0
}

# fish 快照内容有变才重写；bash/zsh 引导块缺失才补
_update_rc_refresh() {
    local rc refresh_rc

    detect_rc
    for rc in "$SHELL_RC_BASH" "$SHELL_RC_ZSH"; do
        if [ -z "$rc" ] || [ ! -f "$rc" ]; then
            continue
        fi
        if _append_source_block "$rc"; then
            continue
        else
            refresh_rc=$?
        fi
        if [ "$refresh_rc" -eq 2 ]; then
            _errorcat "Shell 启动文件中的 clashctl 托管标记不完整：$rc"
        else
            _errorcat "无法更新 Shell 启动文件：$rc"
        fi
        return 1
    done
    if [ -n "$SHELL_RC_FISH" ]; then
        _write_fish_rc || {
            _errorcat "无法更新 Fish 启动文件：$SHELL_RC_FISH"
            return 1
        }
    fi
    return 0
}

_update_side_effects() {
    _update_validate_tree "$CLASHCTL_HOME" || return 1
    _update_env_refresh || {
        _errorcat '无法补充新版本所需的环境配置项'
        return 1
    }
    _update_data_refresh || {
        _errorcat '无法安装新版本所需的配置模板'
        return 1
    }
    _update_unit_refresh || return 1
    _update_runtime_refresh "$_UPDATE_WAS_ACTIVE" || return 1
    _update_rc_refresh || return 1
    return 0
}

# ── 锁（与 clashsub 共用 profiles.lock）────────────────────

_update_acquire_lock() {
    command -v flock >/dev/null 2>&1 || {
        _ui_warn_fail '系统无 flock，已降级为无锁更新（请避免并发执行订阅/更新操作）'
        return 0
    }
    exec 9>>"$CLASH_PROFILES_LOCK" || return 1
    flock -w 60 9 || {
        exec 9>&-
        _errorcat "另一订阅/更新操作正在进行，请稍后再试"
        return 1
    }
}

_update_release_lock() {
    command -v flock >/dev/null 2>&1 || return 0
    flock -u 9 2>/dev/null
    {
        exec 9>&-
    } 2>/dev/null
    return 0
}

# ── 归档回落模式（无 .git 的安装）──────────────────────────

# 归档模式替换清单（备份=回滚 rm 同清单；data/、.env、bin/、dist/ 永不触碰）
_UPDATE_ARCHIVE_PATHS=(
    scripts
    install.sh
    uninstall.sh
    .env.example
    resources/Country.mmdb
    resources/geosite.dat
    resources/mixin.yaml.example
)

_update_archive_backup() {
    local ts bak item items=()

    /usr/bin/install -d "${CLASHCTL_HOME}/.bak" || return 1
    for item in "${_UPDATE_ARCHIVE_PATHS[@]}"; do
        [ -e "${CLASHCTL_HOME:?}/${item}" ] && items+=("$item")
    done
    [ ${#items[@]} -gt 0 ] || return 1

    ts=$(date +%Y%m%d-%H%M%S)
    bak="${CLASHCTL_HOME}/.bak/clashctl-backup-${ts}.tar.gz"
    tar czf "$bak" -C "$CLASHCTL_HOME" "${items[@]}" || {
        /usr/bin/rm -f -- "$bak"
        return 1
    }
    printf '%s\n' "$bak"
}

_update_archive_restore() {
    local bak=$1 item

    for item in "${_UPDATE_ARCHIVE_PATHS[@]}"; do
        /usr/bin/rm -rf -- "${CLASHCTL_HOME:?}/${item}"
    done
    tar xzf "$bak" -C "$CLASHCTL_HOME" || return 1
}

_update_prune_backups() {
    local keep=${1:-3} backups remove

    shopt -s nullglob
    backups=("${CLASHCTL_HOME}"/.bak/clashctl-backup-*.tar.gz)
    shopt -u nullglob
    [ ${#backups[@]} -gt "$keep" ] || return 0
    remove=$(( ${#backups[@]} - keep ))
    /usr/bin/rm -f -- "${backups[@]:0:remove}"
    return 0
}

# 下载归档并解出到 <dst>（顶层剥壳）；成功返回 0
_update_fetch_archive() {
    local branch=$1 dst=$2 url

    /usr/bin/install -d "$dst" || return 1
    url="https://codeload.github.com/${_UPDATE_REPO}/tar.gz/refs/heads/${branch}"
    url="${GH_PROXY:+${GH_PROXY%/}/}${url}"
    _ui_step '下载更新归档'
    curl -sSL --fail --max-time "${CLASHCTL_DOWNLOAD_TIMEOUT:-60}" --retry 1 "$url" |
        tar -xzf - --strip-components=1 -C "$dst"
}
