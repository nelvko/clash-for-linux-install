#!/usr/bin/env bash

# 项目自更新部署核心
#
# 被 preflight.sh（安装/源码侧 update.sh）与 clashctl.sh（运行时 clashctl update）
# 的 lib/*.sh 循环自动 source，两个入口共用同一套非破坏式部署逻辑。
#
# 设计要点：
#   - 只覆盖「代码/静态资源」，绝不触碰「用户数据」（订阅、激活配置、密钥、内核二进制）。
#   - .env 仅补充缺失键，不覆盖已有值；mixin 整体保留用户版本（仅缺失时还原）。
#   - 部署前对 $CLASHCTL_HOME 打包备份，任一步失败自动回滚。

# 校验已安装（valid_env 的反向：home 不存在则报错）
_update_require_install() {
    [[ -d "$CLASHCTL_HOME" && -f "$CLASHCTL_HOME/.env" ]] && return 0
    _errorcat "未检测到已安装的 clashctl（$CLASHCTL_HOME），请先运行 install.sh 安装"
    return 1
}

# preflight 会 source 仓库模板 .env（CLASHCTL_KERNEL/INIT_TYPE 为空），
# .env.install 又可能带有默认内核，二者都可能与真实安装不符。
# 部署前从「已安装的 .env」恢复权威值，并刷新派生路径。
_deploy_restore_env_identity() {
    local env_file="$CLASHCTL_HOME/.env" k i
    [[ -f "$env_file" ]] || return 0
    k=$(grep -E '^CLASHCTL_KERNEL=' "$env_file" | head -1 | cut -d= -f2-)
    i=$(grep -E '^INIT_TYPE=' "$env_file" | head -1 | cut -d= -f2-)
    [[ -n "$k" ]] && CLASHCTL_KERNEL="$k"
    [[ -n "$i" ]] && INIT_TYPE="$i"
    # shellcheck disable=SC2034  # 跨文件使用（service.sh / config.sh）
    BIN_KERNEL="${BIN_BASE_DIR}/$CLASHCTL_KERNEL"
    return 0
}

# 备份当前安装（排除从不改动的 bin/ 与备份目录自身），输出备份文件路径
_update_backup() {
    local stamp dir path
    stamp=$(date +%Y%m%d-%H%M%S)
    dir="$CLASHCTL_HOME/.bak"
    /usr/bin/install -d "$dir" || return 1
    path="$dir/clashctl-backup-${stamp}.tar.gz"
    tar czf "$path" --exclude='./.bak' --exclude='./bin' -C "$CLASHCTL_HOME" . 2>/dev/null || return 1
    printf '%s\n' "$path"
}

# 从备份还原（保留 .bak 与 bin，bin 在更新中从未改动）
_update_restore() {
    local path=$1
    [[ -f "$path" ]] || {
        _errorcat "备份缺失：$path"
        return 1
    }
    find "$CLASHCTL_HOME" -mindepth 1 -maxdepth 1 ! -name '.bak' ! -name 'bin' -exec rm -rf {} + 2>/dev/null
    tar xzf "$path" -C "$CLASHCTL_HOME" || return 1
}

# 仅保留最新 N 份备份（依赖时间戳文件名按字典序=时间序）
_update_prune_backups() {
    local keep=${1:-3} dir="$CLASHCTL_HOME/.bak"
    shopt -s nullglob
    local files=("$dir"/clashctl-backup-*.tar.gz)
    shopt -u nullglob
    local total=${#files[@]}
    ((total > keep)) || return 0
    local remove=$((total - keep)) i
    for ((i = 0; i < remove; i++)); do
        /usr/bin/rm -f "${files[i]}"
    done
    return 0
}

# 部署一个代码目录：删除旧目录后整体覆盖（带「删除上游已移除文件」语义）
# 仅用于 scripts/{cmd,lib,init} 等纯代码目录，绝不用于 resources/
_deploy_dir() {
    local rel=$1 src="$CLASHCTL_SRC/$1" dst="$CLASHCTL_HOME/$1"
    [[ -d "$src" ]] || {
        _failcat "源缺少目录：$rel"
        return 1
    }
    /usr/bin/install -d "$(dirname "$dst")"
    /usr/bin/rm -rf "$dst"
    /bin/cp -a "$src" "$dst"
}

# 部署单个文件（源不存在则跳过，视为该版本未提供）
_deploy_file() {
    local rel=$1 mode=${2:-644} src="$CLASHCTL_SRC/$1" dst="$CLASHCTL_HOME/$1"
    [[ -f "$src" ]] || return 0
    /usr/bin/install -D -m "$mode" "$src" "$dst"
}

# .env 只补缺失键：已存在的键（含用户值与自动生成值）一律保留不动
_env_add_missing() {
    local src=$1 dst=$2 line key
    [[ -f "$src" ]] || return 0
    [[ -f "$dst" ]] || {
        /usr/bin/install -m 644 "$src" "$dst"
        return 0
    }
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" != *=* ]] && continue
        key=${line%%=*}
        key=${key// /}
        [[ -z "$key" ]] && continue
        grep -qE "^[[:space:]]*${key}=" "$dst" && continue
        printf '%s\n' "$line" >>"$dst"
        _okcat '➕' "新增配置项：$key"
    done <"$src"
    return 0
}

# 把依赖下载代理/超时持久化进已安装 .env，供 clashctl update 联网使用。
# 仅当 .env 中无非空值时写入，绝不覆盖用户既有设置。
_deploy_persist_proxy() {
    local env_file="$CLASHCTL_HOME/.env"
    [[ -f "$env_file" ]] || return 0
    [[ -n "${GH_PROXY:-}" ]] && ! grep -qE '^GH_PROXY=.+' "$env_file" && _set_env GH_PROXY "$GH_PROXY"
    [[ -n "${CLASHCTL_DOWNLOAD_TIMEOUT:-}" ]] && ! grep -qE '^CLASHCTL_DOWNLOAD_TIMEOUT=.+' "$env_file" &&
        _set_env CLASHCTL_DOWNLOAD_TIMEOUT "$CLASHCTL_DOWNLOAD_TIMEOUT"
    return 0
}

# 记录部署版本（git 短 SHA）：
#   CLASHCTL_SRC_REV  由 clashctl update 从 GitHub API 取得后传入
#   否则尝试 git rev-parse（源码侧克隆可用）
#   都取不到则记 unknown
_deploy_record_rev() {
    local rev="${CLASHCTL_SRC_REV:-}"
    [[ -z "$rev" ]] && rev=$(git -C "$CLASHCTL_SRC" rev-parse --short HEAD 2>/dev/null)
    [[ -z "$rev" ]] && rev=unknown
    _set_env CLASHCTL_REV "$rev"
}

# 重新注册 init 服务（仅在受支持的 init 系统下；nohup 跳过）。
# install_service 内部可能 exit，故置于子 shell 隔离，且为尽力而为——
# 失败仅告警，不触发回滚（脚本更新本身已完成）。
_deploy_service() {
    detect_service_manager
    # shellcheck disable=SC2154  # service_manager 由 detect_service_manager（service.sh）赋值
    [[ "$service_manager" == "nohup" ]] && return 0
    if (install_service) >&/dev/null; then
        _okcat '🧩' "已刷新服务注册：$CLASHCTL_KERNEL"
    else
        _failcat '⚠️ ' "服务重新注册未完成（不影响脚本更新，可稍后 source ~/.bashrc 重试）"
    fi
    return 0
}

# 用（可能更新过的）合并逻辑重建 runtime.yaml；仅当内容确有变化且服务在运行时才重启
_deploy_refresh_runtime() {
    local was_active=false
    service_is_active >&/dev/null && was_active=true

    [[ -f "$CLASH_CONFIG_RUNTIME" ]] || {
        _merge_config
        return
    }

    local snapshot="${CLASH_CONFIG_RUNTIME}.preupdate"
    /bin/cp -f "$CLASH_CONFIG_RUNTIME" "$snapshot"
    _merge_config || {
        /bin/rm -f "$snapshot"
        return 1
    }

    local changed=false
    cmp -s "$CLASH_CONFIG_RUNTIME" "$snapshot" || changed=true
    /bin/rm -f "$snapshot"

    [[ "$was_active" == true && "$changed" == true ]] && {
        _okcat '🔄' "运行时配置已更新，重启服务生效"
        _merge_config_restart || return 1
    }
    return 0
}

# 实际部署步骤；任一步失败返回非 0，由 deploy_clashctl 触发回滚
_deploy_apply() {
    _deploy_dir "scripts/cmd" || return 1
    _deploy_dir "scripts/lib" || return 1
    _deploy_dir "scripts/init" || return 1
    _deploy_file "uninstall.sh" 755 || return 1
    _deploy_file "resources/Country.mmdb" 644 || return 1
    _deploy_file "resources/geosite.dat" 644 || return 1
    # 用户数据不碰：config.yaml / runtime.yaml / profiles.yaml / profiles/ / bin/
    [[ -f "$CLASH_CONFIG_MIXIN" ]] || _deploy_file "resources/mixin.yaml" 644 || return 1
    _env_add_missing "$CLASHCTL_SRC/.env" "$CLASHCTL_HOME/.env" || return 1
    _deploy_persist_proxy
    _deploy_record_rev
    _deploy_service
    _deploy_refresh_runtime || return 1
    return 0
}

# 部署编排：校验 -> 修正身份 -> 备份 -> 部署 -> 成功剪枝+重载 / 失败回滚
# 安装时由 install_clashctl 直接复用 _deploy_persist_proxy/_deploy_record_rev；
# 更新时由 update.sh / clashupdate 调用本函数。
deploy_clashctl() {
    _update_require_install || return 1
    _deploy_restore_env_identity
    detect_service_manager

    local was_active=false
    service_is_active >&/dev/null && was_active=true

    _okcat '📦' "更新路径：$CLASHCTL_HOME"
    _okcat '📥' "更新源：$CLASHCTL_SRC"

    local backup
    backup=$(_update_backup) || {
        _errorcat "备份失败，已中止更新（未改动任何文件）"
        return 1
    }
    _okcat '🗄️ ' "已备份当前安装：$backup"

    if _deploy_apply; then
        _update_prune_backups 3
        . "$CLASHCTL_HOME/scripts/cmd/clashctl.sh"
        _okcat '🎉' "更新完成，当前版本：${CLASHCTL_REV:-unknown}"
        return 0
    fi

    _errorcat "更新失败，正在回滚..."
    if _update_restore "$backup"; then
        [[ "$was_active" == true ]] && service_restart >&/dev/null
        . "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" 2>/dev/null
        _errorcat "已回滚到更新前状态；备份保留：$backup"
    else
        _errorcat "回滚失败！请手动从备份恢复：$backup"
    fi
    return 1
}
