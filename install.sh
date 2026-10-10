#!/usr/bin/env bash

# 同时供安装入口与 clashupdate 使用；source 本文件只加载函数。
_install_method() {
    local home=$1 marker
    if [ -f "$home/.clashctl-install" ] && [ ! -L "$home/.clashctl-install" ]; then
        marker=$(cat -- "$home/.clashctl-install") || return 1
        case "$marker" in
        "$home"$'\ngit') printf 'git\n'; return 0 ;;
        "$home"$'\narchive') printf 'archive\n'; return 0 ;;
        '') printf '安装标记为空，无法识别安装类型，也不能卸载：%s；请备份后重新安装\n' "$home/.clashctl-install" >&2; return 1 ;;
        esac
        printf '安装标记与当前路径不匹配，无法更新或卸载：%s\n' "$home/.clashctl-install" >&2
    fi
    return 1
}

# 自举入口先准备并校验源码，再从该源码加载同一套生命周期锁。
# 锁必须由 main 持有，覆盖落盘、迁移、初始化以及失败恢复。
_install_lock() {
    # shellcheck source=/dev/null
    . "$1/scripts/lib/operation-lock.sh" || return 1
    operation_lock_acquire
}

# 已有目录只凭安装身份和可信脚本布局进入自动更新/迁移分支。
_install_existing_kind() {
    local home=$1 marker owner mode path unsafe
    local -a required
    [ -d "$home" ] && [ ! -L "$home" ] || return 1
    owner=$(stat -c %u -- "$home") || return 1
    mode=$(stat -c %a -- "$home") || return 1
    [ "$owner" = "$(id -u)" ] && [ $((8#$mode & 0022)) -eq 0 ] || return 1
    if [ -e "$home/.clashctl-install" ] || [ -L "$home/.clashctl-install" ] ||
        [ -e "$home/.clashctl-installation" ] || [ -L "$home/.clashctl-installation" ]; then
        required=(install.sh scripts/preflight.sh scripts/lib/common.sh)
    else
        # master 的运行目录只复制卸载器和运行脚本，不含安装器、preflight。
        required=(uninstall.sh scripts/cmd/clashctl.sh scripts/lib/common.sh scripts/lib/service.sh)
    fi
    for path in "${required[@]}"; do
        [ -f "$home/$path" ] && [ ! -L "$home/$path" ] || return 1
        [ "$(stat -c %u -- "$home/$path")" = "$owner" ] || return 1
        mode=$(stat -c %a -- "$home/$path") || return 1
        [ $((8#$mode & 0022)) -eq 0 ] || return 1
    done
    unsafe=$(find "$home/scripts" \( -type l -o ! -user "$owner" -o -perm /022 \) -print -quit) || return 1
    [ -z "$unsafe" ] || return 1
    if [ -e "$home/.clashctl-install" ] || [ -L "$home/.clashctl-install" ]; then
        [ -f "$home/.clashctl-install" ] && [ ! -L "$home/.clashctl-install" ] || return 1
        [ "$(stat -c %u -- "$home/.clashctl-install")" = "$owner" ] &&
            [ "$(stat -c %a -- "$home/.clashctl-install")" = 600 ] || return 1
        [ ! -L "$home/.clashctl-incomplete" ] || return 1
        if [ -e "$home/.env" ] || [ -L "$home/.env" ]; then
            [ -f "$home/.env" ] && [ ! -L "$home/.env" ] &&
                [ "$(stat -c %u -- "$home/.env")" = "$owner" ] || return 1
        fi
        _install_method "$home" >/dev/null || return 1
        printf 'current\n'
        return 0
    fi
    marker="$home/.clashctl-installation"
    if [ -e "$marker" ] || [ -L "$marker" ]; then
        [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
        [ "$(stat -c %u -- "$marker")" = "$owner" ] &&
            [ "$(stat -c %a -- "$marker")" = 600 ] &&
            [ "$(wc -l <"$marker")" -eq 4 ] || return 1
        grep -Fqx 'CLASHCTL_INSTALLATION=clashctl' "$marker" &&
            grep -Fqx 'CLASHCTL_INSTALLATION_FORMAT=1' "$marker" &&
            grep -Fqx "CLASHCTL_INSTALLATION_HOME=$home" "$marker" &&
            grep -Fqx "CLASHCTL_INSTALLATION_UID=$owner" "$marker" || return 1
        printf 'legacy-v2\n'
        return 0
    fi
    # 早期版本没有身份标记，必须同时具有旧版代码特征和实际用户数据。
    [ ! -e "$home/.git" ] && [ ! -L "$home/.git" ] &&
        [ -d "$home/resources" ] && [ ! -L "$home/resources" ] &&
        [ -f "$home/.env" ] && [ ! -L "$home/.env" ] &&
        [ "$(stat -c %u -- "$home/.env")" = "$owner" ] &&
        grep -Fqx 'CLASH_CONFIG_BASE="${CLASH_RESOURCES_DIR}/config.yaml"' "$home/scripts/lib/common.sh" &&
        grep -Fq 'CLASH_PROFILES_DIR="${CLASH_RESOURCES_DIR}/profiles"' "$home/scripts/lib/common.sh" &&
        { [ -f "$home/resources/config.yaml" ] || [ -d "$home/resources/profiles" ]; } || return 1
    printf 'legacy-v1\n'
}

# 与 master 的订阅写锁共用同一个 inode，复制期间保持元数据与配置一致。
_install_legacy_profiles_lock_acquire() {
    local source=$1 kind=$2 path owner path_id fd_id
    path="$source/resources/profiles.lock"
    [ "$kind" != legacy-v2 ] || path="$source/data/profiles.lock"
    if [ -e "$path" ] || [ -L "$path" ]; then
        [ -f "$path" ] && [ ! -L "$path" ] || return 1
        owner=$(stat -c %u -- "$path") || return 1
        [ "$owner" = "$(id -u)" ] || return 1
    fi
    exec {legacy_profiles_fd}>>"$path" || return 1
    path_id=$(stat -c '%d:%i' -- "$path") &&
        fd_id=$(stat -Lc '%d:%i' -- "/proc/self/fd/$legacy_profiles_fd") || {
        _install_legacy_profiles_lock_release
        return 1
    }
    if [ -L "$path" ] || [ "$path_id" != "$fd_id" ]; then
        _install_legacy_profiles_lock_release
        return 1
    fi
    if [ "${3:-wait}" = short ]; then
        flock -w 2 "$legacy_profiles_fd"
    else
        flock -w 60 "$legacy_profiles_fd"
    fi || {
        _install_legacy_profiles_lock_release
        printf '旧版订阅操作尚未结束，请稍后重试迁移\n' >&2
        return 1
    }
}

_install_legacy_profiles_lock_release() {
    [ -n "${legacy_profiles_fd:-}" ] || return 0
    exec {legacy_profiles_fd}>&- || return 1
    legacy_profiles_fd=''
}

_install_legacy_prepare_for_copy() {
    local legacy=$1 kind=$2 kernel=$3 lock_mode=wait
    detect_service_manager
    if [ "$service_manager" = nohup ]; then
        # 旧版从订阅锁内启动 nohup，内核可能继承并一直占有 profiles.lock。
        _install_legacy_service_prepare "$legacy" "$kernel" || return 1
        lock_mode=short
    fi
    _install_legacy_profiles_lock_acquire "$legacy" "$kind" "$lock_mode" || {
        _install_legacy_service_restore "$kernel" || return 1
        return 1
    }
}

_install_legacy_data() {
    local source=$1 kind=$2 stage=$3 destination=$4 item unsafe
    [ ! -L "$source/.env" ] || return 1
    if [ "$kind" = legacy-v2 ]; then
        [ -d "$source/data" ] && [ ! -L "$source/data" ] || return 1
        unsafe=$(find "$source/data" -type l -print -quit) || return 1
        [ -z "$unsafe" ] || return 1
        cp -a -- "$source/data" "$stage/data" || return 1
        if [ -f "$source/.env" ]; then
            cp -a -- "$source/.env" "$stage/.env" || return 1
            # 旧版自定义路径不能覆盖本次迁移的新目标路径。
            sed -i -E '/^[[:space:]]*(export[[:space:]]+)?CLASHCTL_(HOME|SRC)=/d' "$stage/.env" || return 1
        fi
    else
        install -d -m 0700 "$stage/data" "$stage/data/profiles" || return 1
        for item in config.yaml mixin.yaml profiles.yaml profiles.log last-failed.yaml last-failed.raw; do
            [ ! -f "$source/resources/$item" ] ||
                { [ ! -L "$source/resources/$item" ] &&
                    install -m 0600 "$source/resources/$item" "$stage/data/$item"; } || return 1
        done
        if [ -d "$source/resources/profiles" ]; then
            [ ! -L "$source/resources/profiles" ] &&
                unsafe=$(find "$source/resources/profiles" -type l -print -quit) &&
                    [ -z "$unsafe" ] || return 1
            cp -a -- "$source/resources/profiles/." "$stage/data/profiles/" || return 1
        fi
        _install_legacy_profile_paths "$stage/data/profiles.yaml" "$source" "$destination" || return 1
        # 旧版 .env 含旧安装路径；新安装只继承兼容且为字面值的用户选项。
        cp -- "$stage/.env.example" "$stage/.env" || return 1
        awk '/^(CLASHCTL_SUB_|CLASHCTL_NODE_|GH_PROXY=|CLASHCTL_DOWNLOAD_TIMEOUT=|SUBCONVERTER_REPO=)/ {
            pos = index($0, "=")
            key = substr($0, 1, pos - 1)
            value = substr($0, pos + 1)
            if (key ~ /^[A-Za-z_][A-Za-z0-9_]*$/ &&
                (value ~ /^[A-Za-z0-9_./:+?@%-]*$/ ||
                 value ~ /^\047[^\047]*\047$/ ||
                 value ~ /^"[^"$`\\]*"$/)) print
            else printf "旧版选项未迁移（需手动检查）：%s\n", key > "/dev/stderr"
        }' \
            "$source/.env" >>"$stage/.env" || return 1
    fi
    _install_legacy_resources "$source" "$stage" || return 1
}

_install_legacy_resources() {
    local source=$1 stage=$2 item unsafe
    if [ -e "$source/resources/cache.db" ] || [ -L "$source/resources/cache.db" ]; then
        [ -f "$source/resources/cache.db" ] && [ ! -L "$source/resources/cache.db" ] || return 1
        install -m 0600 "$source/resources/cache.db" "$stage/resources/cache.db" || return 1
    fi
    for item in dist proxies rules; do
        [ -e "$source/resources/$item" ] || [ -L "$source/resources/$item" ] || continue
        [ -d "$source/resources/$item" ] && [ ! -L "$source/resources/$item" ] || return 1
        unsafe=$(find "$source/resources/$item" ! -type f ! -type d -print -quit) || return 1
        [ -z "$unsafe" ] || return 1
        install -d "$stage/resources/$item" || return 1
        cp -a -- "$source/resources/$item/." "$stage/resources/$item/" || return 1
    done
}

_install_legacy_profile_paths() {
    local meta=$1 source=$2 destination=$3 tmp
    [ -f "$meta" ] || return 0
    grep -Fq "$source/resources/profiles/" "$meta" || return 0
    tmp=$(mktemp "${meta}.XXXXXX") || return 1
    awk -v old="$source/resources/profiles/" -v new="$destination/data/profiles/" '
        /^[[:space:]]*path:[[:space:]]*/ {
            pos = index($0, old)
            if (pos) $0 = substr($0, 1, pos - 1) new substr($0, pos + length(old))
        }
        { print }
    ' "$meta" >"$tmp" && mv -f -- "$tmp" "$meta" || {
        rm -f -- "$tmp"
        return 1
    }
}

_install_refresh_current() (
    local home=$1 method=$2 local_source=$3 script_dir=$4 branch=$5 proxy=$6
    local work stage
    export CLASHCTL_HOME="$home" CLASHCTL_SRC="$home" CLASHCTL_UPDATE_BRANCH="$branch" GH_PROXY="$proxy"
    if [ "$local_source" = true ]; then
        [ "$method" = archive ] || {
            printf 'Git 安装不能直接覆盖为未提交的本地源码；请使用远端更新或另选安装目录\n' >&2
            return 1
        }
        work=$(mktemp -d "${home}.update.XXXXXX") || return 1
        # 回滚失败时，更新器会标记 keep 并留下 previous.tar 供手动恢复。
        trap '[ -f "$work/keep" ] || rm -rf -- "$work"' EXIT
        stage="$work/source"
        mkdir "$stage" || return 1
        _install_copy_local_source "$script_dir" "$stage" || return 1
        _source_validate "$stage" || return 1
        . "$home/scripts/preflight.sh" || return 1
        . "$home/scripts/cmd/update.sh" || return 1
        operation_lock_acquire || return 1
        # 使用本次安装器的样式，避免旧安装的输出函数改变阶段前缀。
        printf '\n' >&2
        _install_bootstrap_step '应用本地源码更新'
        _update_archive "$stage" "$work"
    else
        . "$home/scripts/preflight.sh" || return 1
        . "$home/scripts/cmd/update.sh" || return 1
        export CLASHCTL_UPDATE_BRANCH="$branch" GH_PROXY="$proxy"
        _update_scripts
    fi
)

_install_copy_local_source() (
    set -o pipefail
    tar -C "$1" --exclude-vcs-ignores \
        --exclude='./.git' --exclude='./.env' --exclude='./.clashctl-*' \
        --exclude='./data' --exclude='./bin' --exclude='./archives' \
        --exclude='./resources/dist' --exclude='./resources/cache.db' \
        --exclude='./resources/proxies' --exclude='./resources/rules' -cf - . |
        tar --no-same-owner --no-same-permissions -xf - -C "$2"
)

# nohup 没有服务文件，只接管命令行、可执行文件和属主都精确匹配旧安装的进程。
_install_legacy_nohup_command() {
    local legacy=$1 kernel=$2 runtime="$legacy/data/runtime.yaml"
    [ "$existing_kind" != legacy-v1 ] || runtime="$legacy/resources/runtime.yaml"
    legacy_nohup_command=("$legacy/bin/$kernel" -d "$legacy/resources" -f "$runtime")
    legacy_nohup_log="$legacy/resources/$kernel.log"
    [ "$existing_kind" != legacy-v2 ] || legacy_nohup_log="$legacy/data/$kernel.log"
}

_install_legacy_nohup_find() {
    local expected=$1 proc pid actual owner exe expected_exe count=0
    expected_exe=$(readlink -m -- "${legacy_nohup_command[0]}") || return 1
    legacy_nohup_found=false
    for proc in /proc/[0-9]*; do
        pid=${proc##*/}
        actual=$(_service_process_argv_hex "$pid" 2>/dev/null) || continue
        if [ "$actual" != "$expected" ]; then
            exe=$(_service_process_exe_path "$pid" 2>/dev/null) || continue
            [ "$exe" = "$expected_exe" ] || continue
            printf '旧版内核进程参数与预期不符（PID %s），请先手动停止\n' "$pid" >&2
            return 1
        fi
        owner=$(stat -c %u -- "$proc" 2>/dev/null) || return 1
        if [ "$owner" != "$(id -u)" ] ||
            ! _service_process_snapshot "$pid" "${legacy_nohup_command[0]}" "$expected"; then
            printf '旧版内核进程无法安全接管（PID %s），请先手动停止\n' "$pid" >&2
            return 1
        fi
        count=$((count + 1))
        if [ "$count" -gt 1 ]; then
            printf '检测到多个旧版内核进程，请先手动停止后重试\n' >&2
            return 1
        fi
        legacy_nohup_found=true
        legacy_nohup_pid=$pid
        legacy_nohup_starttime=$_SERVICE_SNAPSHOT_STARTTIME
        legacy_nohup_argv_hex=$_SERVICE_SNAPSHOT_ARGV
        legacy_nohup_exe_id=$_SERVICE_SNAPSHOT_EXE_ID
    done
}

# 仅在能精确识别旧版服务或进程时接管；备份留在旧目录中，供回滚使用。
_install_legacy_service_prepare() {
    local legacy=$1 kernel=$2 expected target CLASHCTL_KERNEL=$2
    detect_service_manager
    if [ "$service_manager" = nohup ]; then
        _install_legacy_nohup_command "$legacy" "$kernel"
        expected=$(_service_process_values_argv_hex "${legacy_nohup_command[@]}") || return 1
        _install_legacy_nohup_find "$expected" || return 1
        [ "$legacy_nohup_found" = true ] || return 0
        legacy_nohup_active=true
        _service_process_stop_snapshot "$legacy_nohup_pid" "$legacy_nohup_starttime" \
            "$legacy_nohup_argv_hex" "$legacy_nohup_exe_id"
        if _service_process_identity_matches "$legacy_nohup_pid" "$legacy_nohup_starttime" \
            "$legacy_nohup_argv_hex" "$legacy_nohup_exe_id"; then
            printf '旧版内核未能停止，迁移已取消\n' >&2
            _install_legacy_service_restore "$kernel" || true
            return 1
        fi
        return 0
    fi
    target=$(_service_target 2>/dev/null) || return 0
    [ -e "$target" ] || [ -L "$target" ] || return 0
    # shellcheck disable=SC2154  # detect_service_manager 设置
    if [ "$service_manager" != systemd ] || [ -L "$target" ]; then
        printf '检测到旧版同名服务，无法安全自动接管：%s\n' "$target" >&2
        return 1
    fi
    case $existing_kind in
    legacy-v2) expected="ExecStart=$legacy/bin/$kernel -d $legacy/resources -f $legacy/data/runtime.yaml" ;;
    legacy-v1) expected="ExecStart=$legacy/bin/$kernel -d $legacy/resources -f $legacy/resources/runtime.yaml" ;;
    esac
    grep -Fqx -- "$expected" "$target" || {
        printf '同名服务不属于已识别的旧版安装：%s；未接管\n' "$target" >&2
        return 1
    }
    legacy_service_file=$(mktemp "$legacy/.clashctl-service.XXXXXX") || return 1
    cp -p -- "$target" "$legacy_service_file" || {
        rm -f -- "$legacy_service_file"
        legacy_service_file=''
        return 1
    }
    legacy_service_target=$target
    legacy_service_active=false legacy_service_enabled=false
    systemctl is-active --quiet "$kernel" && legacy_service_active=true
    systemctl is-enabled --quiet "$kernel" && legacy_service_enabled=true
    systemctl stop "$kernel" || { _install_legacy_service_restore "$kernel"; return 1; }
    rm -f -- "$target" || { _install_legacy_service_restore "$kernel"; return 1; }
    systemctl daemon-reload || { _install_legacy_service_restore "$kernel"; return 1; }
}

_install_legacy_service_restore() {
    local kernel=$1 expected pid attempt=0
    if [ "${legacy_nohup_active:-false}" = true ]; then
        if _service_process_identity_matches "$legacy_nohup_pid" "$legacy_nohup_starttime" \
            "$legacy_nohup_argv_hex" "$legacy_nohup_exe_id"; then
            return 0
        fi
        expected=$(_service_process_values_argv_hex "${legacy_nohup_command[@]}") || return 1
        _install_legacy_nohup_find "$expected" || return 1
        [ "$legacy_nohup_found" = false ] || return 0
        (
            _install_legacy_profiles_lock_release || exit 1
            operation_lock_close_fd || exit 1
            exec nohup "${legacy_nohup_command[@]}"
        ) </dev/null >>"$legacy_nohup_log" 2>&1 &
        pid=$!
        while [ "$attempt" -lt 100 ]; do
            if _service_process_snapshot "$pid" "${legacy_nohup_command[0]}" "$expected"; then
                legacy_nohup_pid=$pid
                legacy_nohup_starttime=$_SERVICE_SNAPSHOT_STARTTIME
                legacy_nohup_argv_hex=$_SERVICE_SNAPSHOT_ARGV
                legacy_nohup_exe_id=$_SERVICE_SNAPSHOT_EXE_ID
                return 0
            fi
            kill -0 "$pid" 2>/dev/null || break
            attempt=$((attempt + 1))
            sleep 0.01
        done
        printf '无法重启旧版内核，请检查：%s\n' "$legacy_nohup_log" >&2
        return 1
    fi
    [ -n "${legacy_service_file:-}" ] && [ -n "${legacy_service_target:-}" ] || return 0
    cp -p -- "$legacy_service_file" "$legacy_service_target" || return 1
    systemctl daemon-reload || return 1
    [ "$legacy_service_enabled" != true ] || systemctl enable --quiet "$kernel" || return 1
    [ "$legacy_service_active" != true ] || systemctl start "$kernel" || return 1
}

# 恢复资料放在安装目录之外；私有目录同时保护旧版目录中的订阅与密钥。
_install_recovery_path() {
    local home=$1 category=$2 name=${3:-${1##*/}} root path uid
    case $category in backups | failed) ;; *) return 1 ;; esac
    root="${home%/*}/.clashctl-backups"
    [ "$root" != "$home" ] || {
        printf '安装目录不能占用恢复目录：%s\n' "$root" >&2
        return 1
    }
    uid=$(id -u) || return 1
    for path in "$root" "$root/$category"; do
        if [ ! -e "$path" ] && [ ! -L "$path" ]; then
            mkdir -m 0700 -- "$path" || return 1
        fi
        if [ ! -d "$path" ] || [ -L "$path" ] ||
            [ "$(stat -c %u -- "$path")" != "$uid" ] ||
            [ "$(stat -c %a -- "$path")" != 700 ] || [ ! -w "$path" ] || [ ! -x "$path" ]; then
            printf '恢复目录必须属于当前用户、权限为 700，且不能是符号链接：%s\n' "$path" >&2
            return 1
        fi
    done
    path="$root/$category/$name.$(date +%Y%m%d%H%M%S).$$"
    [ ! -e "$path" ] && [ ! -L "$path" ] || {
        printf '恢复路径已存在，未覆盖：%s\n' "$path" >&2
        return 1
    }
    printf '%s\n' "$path"
}

_install_legacy_rollback() {
    local legacy=$1 backup=$2 current=$3 kernel=$4 target failed_home
    if [ -e "$current" ] || [ -L "$current" ]; then
        failed_home=$(_install_recovery_path "$current" failed) || return 1
        if [ "$service_manager" = nohup ] && [ "${CLASH_DATA_DIR:-}" = "$current/data" ]; then
            service_stop_checked || {
                printf '无法停止新内核，已保留新旧目录以供检查\n' >&2
                return 1
            }
        fi
        target=$(_service_target 2>/dev/null) || target=''
        if [ -n "$target" ] && { [ -e "$target" ] || [ -L "$target" ]; }; then
            if [ ! -f "$target" ] || [ -L "$target" ] || ! _service_definition_is_owned "$target" ||
                ! uninstall_service; then
                printf '无法安全移除新服务，已保留新旧目录以供检查：%s\n' "$target" >&2
                return 1
            fi
        fi
        mv -T -- "$current" "$failed_home" || return 1
        printf '失败的新目录保留在：%s\n' "$failed_home" >&2
    fi
    mv -T -- "$backup" "$legacy" || return 1
    _install_legacy_service_restore "$kernel" || return 1
    printf '旧版安装已恢复：%s\n' "$legacy" >&2
}

# 迁移期间的中断与普通错误共用恢复路径；旧目录搬走后必须先回滚路径再启动旧服务。
_install_main_cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    set +e
    _install_legacy_profiles_lock_release
    if [ "${legacy_recovery_required:-false}" = true ]; then
        if [ -n "${legacy_shell_backup:-}" ]; then
            if _install_shell_restore "$legacy_shell_backup"; then
                rm -rf -- "$legacy_shell_backup" || true
            else
                printf '迁移中断后无法恢复 Shell 配置，请检查备份：%s\n' "$legacy_shell_backup" >&2
                rc=1
            fi
        fi
        if [ -n "${backup:-}" ] && [ -d "$backup" ] && [ ! -L "$backup" ]; then
            if { [ ! -e "$legacy_home" ] && [ ! -L "$legacy_home" ]; } ||
                { [ "$legacy_home" = "$install_home" ] && [ -d "$install_home" ] &&
                    [ ! -L "$install_home" ] &&
                    _install_method "$install_home" >/dev/null 2>&1; }; then
                _install_legacy_rollback "$legacy_home" "$backup" "$install_home" "$legacy_kernel" || {
                    printf '迁移中断后无法自动恢复旧版安装，请检查备份：%s\n' "$backup" >&2
                    rc=1
                }
            else
                printf '迁移中断后旧目录与备份同时存在，请手动检查：%s 和 %s\n' "$legacy_home" "$backup" >&2
                rc=1
            fi
        elif [ -d "$legacy_home" ] && [ ! -L "$legacy_home" ]; then
            _install_legacy_service_restore "$legacy_kernel" || {
                printf '迁移中断后无法自动恢复旧版服务，请检查：%s\n' "$legacy_home" >&2
                rc=1
            }
        else
            printf '迁移中断后无法确认旧版目录，请检查：%s 和 %s\n' "$legacy_home" "$backup" >&2
            rc=1
        fi
    fi
    [ -z "${stage:-}" ] || rm -rf -- "$stage"
    exit "$rc"
}

# 旧版迁移最后更新 Shell 引导；若其中某个文件更新失败，恢复此前已改的文件。
_install_shell_snapshot() {
    local directory=$1 rc path index=0
    _install_shell_paths=()
    _install_shell_existed=()
    detect_rc
    for rc in "$SHELL_RC_BASH" "$SHELL_RC_ZSH" "$SHELL_RC_FISH"; do
        [ -n "$rc" ] || continue
        path=$rc
        if [ -e "$rc" ] || [ -L "$rc" ]; then
            [ -f "$rc" ] || return 1
            path=$(readlink -f -- "$rc") || return 1
            cp -p -- "$path" "$directory/$index" || return 1
            _install_shell_existed+=(true)
        else
            _install_shell_existed+=(false)
        fi
        _install_shell_paths+=("$path")
        index=$((index + 1))
    done
}

_install_shell_restore() {
    local directory=$1 index path
    for index in "${!_install_shell_paths[@]}"; do
        path=${_install_shell_paths[$index]}
        if [ "${_install_shell_existed[$index]}" = true ]; then
            cp -p -- "$directory/$index" "$path" || return 1
        else
            [ ! -e "$path" ] && [ ! -L "$path" ] || rm -f -- "$path" || return 1
        fi
    done
}

_source_path_allowed() {
    local path=${1#./}
    [[ -n "$path" && "$path" != /* && "$path" != *[^a-zA-Z0-9_./-]* ]] || return 1
    case "/$path/" in */../* | */./*) return 1 ;; esac
    case "$path" in
    .git | .git/* | .env | .env/* | .clashctl-* | data | data/* | bin | bin/* | archives | archives/* | resources/dist | resources/dist/* | resources/cache.db | resources/proxies | resources/proxies/* | resources/rules | resources/rules/*)
        return 1 ;;
    esac
}

_source_archive() (
    local destination=$1 branch=$2 proxy=$3 archive entries url
    [[ "$branch" =~ ^[a-zA-Z0-9][a-zA-Z0-9_./-]*$ ]] || { printf '分支名称无效\n' >&2; return 1; }
    archive=$(mktemp) || return 1
    entries="${archive}.list"
    trap 'rm -f -- "$archive" "$entries"' EXIT
    url="https://github.com/nelvko/clash-for-linux-install/archive/refs/heads/${branch}.tar.gz"
    [ -z "$proxy" ] || url="${proxy%/}/$url"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --max-time 180 --retry 2 -o "$archive" "$url" || return 1
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout=30 --tries=3 -O "$archive" "$url" || return 1
    else
        printf '下载源码需要 curl 或 wget\n' >&2
        return 1
    fi
    # 仅允许单个顶层目录内的普通文件/目录；拒绝越界路径和链接后再解压。
    tar -tzf "$archive" >"$entries" || return 1
    awk '
        /[^a-zA-Z0-9_.\/-]/ || /^\// || /(^|\/)\.\.?($|\/)/ { exit 1 }
        { split($0, parts, "/"); if (!root) root=parts[1]; if (parts[1]!=root || !index($0,"/")) exit 1 }
        END { if (!root) exit 1 }
    ' "$entries" || { printf '源码归档路径无效\n' >&2; return 1; }
    tar -tvzf "$archive" >"$entries" || return 1
    if LC_ALL=C grep -qv '^[-d]' "$entries"; then
        printf '源码归档包含非普通文件\n' >&2
        return 1
    fi
    tar -xzf "$archive" --strip-components=1 --no-same-owner --no-same-permissions -C "$destination"
)

_source_validate() {
    local directory=$1 file relative
    for file in .env.example install.sh uninstall.sh scripts/preflight.sh scripts/lib/operation-lock.sh scripts/cmd/clashctl.sh scripts/cmd/update.sh; do
        if [ ! -f "$directory/$file" ] || [ -L "$directory/$file" ]; then
            printf '源码不兼容：缺少必需文件 %s\n' "$file" >&2
            return 1
        fi
    done
    while IFS= read -r -d '' file; do
        relative=${file#"$directory/"}
        if ! _source_path_allowed "$relative" || [ -L "$file" ] || { [ ! -d "$file" ] && [ ! -f "$file" ]; }; then
            printf '源码包含不支持的路径：%s\n' "$relative" >&2
            return 1
        fi
        case "$file" in *.sh) bash -n "$file" || return 1 ;; esac
    done < <(find "$directory" -mindepth 1 -path "$directory/.git" -prune -o -print0)
}

_source_manifest() (
    set -o pipefail
    cd -- "$1" || return 1
    find . -path './.git' -prune -o -type f ! -name '.clashctl-*' -print0 |
        sort -z | xargs -0 -r sha256sum
)

# 在线安装的第一个阶段尚无公共库；颜色规则与 _ui_color_enabled 保持一致。
_install_bootstrap_log() {
    local level=$1 msg=$2 prefix color colored=false
    case $level in
    step) prefix='[STEP]'; color=36 ;;
    ok) prefix='[ OK ]'; color=32 ;;
    *) prefix='[INFO]'; color=36 ;;
    esac
    if [ "${NO_COLOR+x}" != x ]; then
        case ${CLASHCTL_COLOR:-auto} in
        always) colored=true ;;
        never) ;;
        *)
            if [ "${CI+x}" != x ] && [ "${TERM:-dumb}" != dumb ] && [ -t 2 ]; then
                colored=true
            fi
            ;;
        esac
    fi
    if [ "$colored" = true ]; then
        if [ "$level" = step ]; then
            printf '\033[1;%sm%s %s\033[0m\n' "$color" "$prefix" "$msg" >&2
        else
            printf '\033[1;%sm%s\033[0m %s\n' "$color" "$prefix" "$msg" >&2
        fi
    else
        printf '%s %s\n' "$prefix" "$msg" >&2
    fi
}

_install_bootstrap_step() { _install_bootstrap_log step "$1"; }

_install_intro() {
    local action=$1 home=$2 home_source=$3 local_source=$4 branch=$5
    if [ "$local_source" = true ]; then
        _install_bootstrap_step "$action（本地源码）"
    else
        _install_bootstrap_step "$action（分支 $branch）"
    fi
    if [ "$home_source" = CLASHCTL_HOME ]; then
        printf '       安装目录: %s（CLASHCTL_HOME）\n' "$home" >&2
    else
        printf '       安装目录: %s\n' "$home" >&2
    fi
}

_install_next_step() {
    local shell=$1 rc_var rc_path load_command command_width=32
    case "$shell" in bash | zsh | fish) ;; *) shell=bash ;; esac
    rc_var=SHELL_RC_${shell^^}
    rc_path=${!rc_var:-}
    if [ -f "$rc_path" ]; then
        printf -v load_command 'source %q' "$rc_path"
        if [[ $rc_path == "$HOME/"* ]]; then
            printf -v load_command 'source ~/%q' "${rc_path#"$HOME/"}"
        fi
    elif [ "$shell" = fish ]; then
        printf -v load_command 'set -gx CLASHCTL_HOME %q; source %q' \
            "$CLASHCTL_HOME" "$CLASHCTL_HOME/scripts/cmd/clashctl.fish"
    else
        printf -v load_command 'export CLASHCTL_HOME=%q; source %q' \
            "$CLASHCTL_HOME" "$CLASHCTL_HOME/scripts/cmd/clashctl.sh"
    fi
    [ "${#load_command}" -le "$command_width" ] || command_width=${#load_command}
    printf '\n在当前终端执行（%s）:\n' "$shell" >&2
    printf '  %-*s  # %s\n' "$command_width" "$load_command" '加载命令' >&2
    if [ ! -s "$CLASH_CONFIG_BASE" ]; then
        printf '  %-*s  # %s\n' "$command_width" 'clashctl sub add --use "<URL>"' '添加并启用订阅' >&2
    fi
    printf '  %-*s  # %s\n' "$command_width" 'clashctl on' '启用当前终端代理' >&2
    if service_is_active >/dev/null 2>&1; then
        printf '  %-*s  # %s\n' "$command_width" 'clashctl ui' '查看面板地址' >&2
    fi
}

_install_complete() {
    printf '\n' >&2
    _install_ui_ok '安装完成'
    [ -z "${1:-}" ] || _ui_detail '旧版备份' "$1"
    # 安装器运行在子进程中；优先识别调用它的 Shell，登录 Shell 只作兜底。
    local shell
    shell=$(readlink "/proc/$PPID/exe" 2>/dev/null) || shell=${SHELL:-bash}
    case ${shell##*/} in bash | zsh | fish) ;; *) shell=${SHELL:-bash} ;; esac
    _install_next_step "${shell##*/}"
}

_install_initialize() {
    export CLASHCTL_SRC="$CLASHCTL_HOME"
    . "$CLASHCTL_SRC/scripts/preflight.sh" || return 1
    [ "${4:-}" != x ] || CLASHCTL_DOWNLOAD_TIMEOUT=$5
    # 参数在 main 中保存，不受 preflight 加载已有 .env 的影响。
    local kernel=${1:-${CLASHCTL_KERNEL:-mihomo}} branch=${2:-${CLASHCTL_UPDATE_BRANCH:-master}}
    local proxy=${3:-} subscription=${7:-} rc secret shell_backup=''
    export -n subscription secret
    export CLASHCTL_KERNEL="$kernel" CLASHCTL_UPDATE_BRANCH="$branch" GH_PROXY="$proxy"
    # shellcheck disable=SC2034  # preflight 中的组件安装与服务定义共用此路径。
    BIN_KERNEL=$(bin_kernel_path) || return 1
    operation_lock_acquire || return 1
    valid_required || return 1
    detect_service_manager
    _service_check_conflict || return 1

    _install_ui_step '准备运行组件'
    install -d -m 0700 "$CLASH_DATA_DIR" "$CLASH_PROFILES_DIR" || return 1
    local source target
    for source in mixin.yaml.example profiles.yaml; do
        target="$CLASH_DATA_DIR/${source%.example}"
        [ -f "$target" ] || install -m 0600 "$CLASH_RESOURCES_DIR/$source" "$target" || return 1
    done
    [ -f "$CLASH_CONFIG_BASE" ] || install -m 0600 /dev/null "$CLASH_CONFIG_BASE" || return 1
    prepare_zip kernel yq || return 1
    # 在写入配置、注册服务之前撤销未初始化凭据；后续丢失 .env 不能按空安装删除。
    command rm -f -- "$CLASHCTL_HOME/.clashctl-uninitialized" || return 1
    [ -f "$CLASHCTL_HOME/.env" ] || install -m 0600 "$CLASHCTL_HOME/.env.example" "$CLASHCTL_HOME/.env" || return 1
    _set_env CLASHCTL_KERNEL "$kernel" || return 1
    _set_env CLASHCTL_UPDATE_BRANCH "$branch" || return 1
    _set_env GH_PROXY "$proxy" || return 1
    _set_env CLASHCTL_DOWNLOAD_TIMEOUT "$CLASHCTL_DOWNLOAD_TIMEOUT" || return 1
    # shellcheck disable=SC2154  # detect_service_manager 设置
    _set_env INIT_TYPE "$service_manager" || return 1
    . "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" || return 1
    # 命令加载器会重新加载 service.sh，清空之前检测到的服务方式与路径。
    detect_service_manager

    _install_ui_step '配置服务与终端命令'
    # 密钥直接写入 Mixin，无主配置时不生成 runtime。
    secret=$("$BIN_YQ" '.secret // ""' "$CLASH_CONFIG_MIXIN") || return 1
    if [ -z "$secret" ]; then
        secret=$(_get_random_val) || return 1
        SECRET=$secret "$BIN_YQ" -i '.secret = env(SECRET)' "$CLASH_CONFIG_MIXIN" || return 1
    fi
    install_service || return 1
    if [ "$service_manager" = nohup ]; then
        _install_ui_info '运行方式: nohup（不设置开机自启）'
    else
        _install_ui_ok "已注册 $service_manager 服务"
    fi

    if [ -z "$subscription" ] && [ ! -s "$CLASH_CONFIG_BASE" ] &&
        [ "${CI+x}" != x ] && ( : </dev/tty ) 2>/dev/null; then
        IFS= read -r -p '       订阅链接（回车跳过，稍后可添加）: ' subscription </dev/tty || subscription=''
    fi
    if [ -n "$subscription" ]; then
        # 订阅失败不算安装失败：组件、命令和服务都已就绪，此时报"安装未完成"会误导用户重装。
        if ! clashsub add --use "$subscription"; then
            _install_ui_warn '订阅添加失败，已跳过；组件与命令安装完成'
            _ui_detail '稍后重试' 'clashctl sub add --use "<URL>"'
        fi
    elif [ -s "$CLASH_CONFIG_BASE" ]; then
        clashstart || return 1
    else
        _install_ui_info '尚未配置订阅，内核未启动'
    fi
    # 订阅生效直接启服；续装时已运行的内核也会跳过 clashstart 的自启步骤。
    if [ -s "$CLASH_CONFIG_BASE" ] && service_is_active >/dev/null 2>&1; then
        service_enable || return 1
        [ "$service_manager" = nohup ] || _install_ui_ok '已设置开机自启'
    elif [ "$service_manager" != nohup ]; then
        _install_ui_info '未启用内核，跳过开机自启设置'
    fi
    if [ -n "${6:-}" ]; then
        shell_backup=$(mktemp -d "${CLASHCTL_HOME}.shell.XXXXXX") || return 1
        _install_shell_snapshot "$shell_backup" || {
            rm -rf -- "$shell_backup"
            return 1
        }
        legacy_shell_backup=$shell_backup
    fi
    rc=0
    apply_rc || rc=$?
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then
        if [ -n "$shell_backup" ]; then
            _install_shell_restore "$shell_backup" || {
                printf '无法恢复迁移前的 Shell 配置，请检查：%s\n' "$shell_backup" >&2
                return 1
            }
            legacy_shell_backup=''
            rm -rf -- "$shell_backup"
        fi
        return "$rc"
    fi
    return 0
}

# 可直接 curl .../install.sh | bash；交互输入从 /dev/tty 读取。
main() (
    set -e
    _install_ui_output() { _install_ui_emit_fd "$@"; }
    # 更新器会再次 source 安装器以复用函数；同一路径执行时不能递归进入 main。
    CLASHCTL_INSTALL_RUNNING=1
    local install_home=${CLASHCTL_HOME:-$HOME/.clashctl}
    local _INSTALL_VERBOSE=${_INSTALL_VERBOSE:-}
    local home_source='默认值（~/.clashctl）'
    [ -z "${CLASHCTL_HOME:-}" ] || home_source=CLASHCTL_HOME
    local branch=${CLASHCTL_UPDATE_BRANCH:-} kernel='' subscription=''
    local proxy=${GH_PROXY:-} proxy_set=${GH_PROXY+x} stage='' arg method
    local requested_timeout=${CLASHCTL_DOWNLOAD_TIMEOUT-} timeout_set=${CLASHCTL_DOWNLOAD_TIMEOUT+x}
    local local_source=false script_dir='' existing_kind='' legacy_home='' legacy_kernel='' backup=''
    local legacy_recovery_required=false legacy_shell_backup=''
    local legacy_service_file='' legacy_service_target='' legacy_service_active=false legacy_service_enabled=false
    local legacy_nohup_active=false legacy_nohup_found=false legacy_nohup_pid='' legacy_nohup_starttime=''
    local legacy_nohup_argv_hex='' legacy_nohup_exe_id='' legacy_nohup_log=''
    local legacy_profiles_fd=''
    local -a legacy_nohup_command=()
    while [ "$#" -gt 0 ]; do
        arg=$1
        shift
        case $arg in
        --branch=*)
            branch=${arg#*=}
            [ -n "$branch" ] && [[ "$branch" != -* ]] || { printf '%s\n' '--branch 需要一个分支名称' >&2; return 1; }
            ;;
        --branch)
            [ "$#" -gt 0 ] && [ -n "$1" ] && [[ "$1" != -* ]] || { printf '%s\n' '--branch 需要一个分支名称' >&2; return 1; }
            branch=$1
            shift
            ;;
        --kernel=*)
            kernel=${arg#*=}
            [ -n "$kernel" ] || { printf '%s\n' '--kernel 需要 mihomo 或 clash' >&2; return 1; }
            ;;
        --kernel)
            [ "$#" -gt 0 ] || { printf '%s\n' '--kernel 需要 mihomo 或 clash' >&2; return 1; }
            kernel=$1
            shift
            ;;
        --sub=*)
            subscription=${arg#*=}
            [ -n "$subscription" ] || { printf '%s\n' '--sub 需要一个订阅链接' >&2; return 1; }
            ;;
        --sub)
            [ "$#" -gt 0 ] && [ -n "$1" ] || { printf '%s\n' '--sub 需要一个订阅链接' >&2; return 1; }
            subscription=$1
            shift
            ;;
        --local) local_source=true ;;
        --verbose) _INSTALL_VERBOSE=1 ;;
        --home=*)
            install_home=${arg#--home=}
            home_source=--home
            [ -n "$install_home" ] || { printf '%s\n' '--home 需要一个绝对路径' >&2; return 1; }
            ;;
        --home)
            [ "$#" -gt 0 ] && [ -n "$1" ] || { printf '%s\n' '--home 需要一个绝对路径' >&2; return 1; }
            install_home=$1
            home_source=--home
            shift
            ;;
        --gh-proxy=*) proxy=${arg#--gh-proxy=}; proxy_set=x ;;
        --gh-proxy)
            [ "$#" -gt 0 ] || { printf '%s\n' '--gh-proxy 需要一个值' >&2; return 1; }
            proxy=$1
            proxy_set=x
            shift
            ;;
        -h | --help)
            cat <<'HELP'
安装或更新 clashctl

用法: bash install.sh [选项]

安装选项:
  --local                 使用本地源码安装，依赖仍按需下载
  --home <路径>           指定安装目录（绝对路径，默认 ~/.clashctl）
  --kernel <内核>         mihomo（默认）或 clash；已有安装不可切换
  --sub <URL>             添加并启用订阅；无现有配置时交互询问

下载与更新:
  --branch <分支>         源码及后续更新分支（新安装默认 master）
                          配合 --local 时，仅设置后续更新分支
  --gh-proxy <URL>        GitHub 下载代理前缀；--gh-proxy= 表示直连
  --verbose               显示源码下载详情、完整下载地址和缓存路径
  -h, --help              显示帮助

环境变量（可选）:
  CLASHCTL_HOME              安装目录
  CLASHCTL_UPDATE_BRANCH     源码及后续更新分支
  GH_PROXY                   GitHub 下载代理前缀
  CLASHCTL_DOWNLOAD_TIMEOUT   依赖下载超时（秒，默认 60）

重复安装沿用已保存配置，命令行参数可覆盖。参数支持 --选项 值 或 --选项=值。
--local 需从本地 install.sh 执行，不支持管道安装。

示例:
  本地源码安装:
    bash install.sh --local --gh-proxy https://gh-proxy.org
  指定分支安装:
    bash install.sh --branch install-update --gh-proxy https://gh-proxy.org

更多说明: docs/guide.md
HELP
            return 0 ;;
        *) printf '未知安装参数\n' >&2; return 1 ;;
        esac
    done
    case $kernel in
    '' | mihomo | clash) ;;
    *) printf '%s\n' '--kernel 仅支持 mihomo 或 clash' >&2; return 1 ;;
    esac
    if [ -f "${BASH_SOURCE[0]:-}" ]; then
        script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
    fi
    if [ "$local_source" = true ] && [ -z "$script_dir" ]; then
        printf '%s\n' '--local 需要从本地源码目录中的 install.sh 执行，不支持管道输入' >&2
        return 1
    fi
    # 服务单元名与内核二进制路径都派生自它，必须在 sourcing 前导出。
    export CLASHCTL_KERNEL="$kernel"
    for arg in tar gzip unzip sha256sum; do
        command -v "$arg" >/dev/null || { printf '缺少依赖: %s\n' "$arg" >&2; return 1; }
    done
    # 服务模板使用绝对路径；拒绝会影响模板或 Shell 解析的字符。
    [[ $install_home == /* && $install_home != *[^a-zA-Z0-9_./-]* ]] || {
        printf '安装目录必须是绝对路径，且只包含字母、数字、_、.、/、-\n' >&2
        return 1
    }
    install_home=$(readlink -m -- "$install_home") || return 1
    if [ "$install_home" = / ] || [ "$install_home" = "$(cd -- "$HOME" && pwd -P)" ]; then
        printf '不能使用根目录或用户主目录作为安装目录\n' >&2
        return 1
    fi
    if [ "$local_source" = true ]; then
        case "$install_home/" in
        "$script_dir/"*) printf '本地安装目录不能位于源码目录内，请通过 --home 指定其他目录\n' >&2; return 1 ;;
        esac
    fi
    if [ -e "$install_home" ] || [ -L "$install_home" ]; then
        existing_kind=$(_install_existing_kind "$install_home") || {
            printf '无法确认现有目录属于 clashctl 安装：%s；未修改目录\n' "$install_home" >&2
            return 1
        }
        if [ "$existing_kind" = current ]; then
            _install_lock "$install_home" || return 1
            # 等待准备/加锁期间，另一操作可能已经卸载或替换此目录。
            [ "$(_install_existing_kind "$install_home")" = current ] || {
                printf '安装目录状态已变化，请重新运行安装器\n' >&2
                return 1
            }
            method=$(_install_method "$install_home") || return 1
            # 先读取已保存的选项；本次显式参数与环境变量优先。
            if [ -f "$install_home/.env" ]; then
                local requested_kernel=$kernel requested_branch=$branch requested_proxy=$proxy
                # shellcheck source=/dev/null
                . "$install_home/.env" || return 1
                if [ -n "$requested_kernel" ] && [ "$requested_kernel" != "${CLASHCTL_KERNEL:-mihomo}" ]; then
                    printf '已有安装不支持切换内核（%s → %s），请使用原内核重试\n' \
                        "${CLASHCTL_KERNEL:-mihomo}" "$requested_kernel" >&2
                    return 1
                fi
                kernel=${requested_kernel:-${CLASHCTL_KERNEL:-mihomo}}
                branch=${requested_branch:-${CLASHCTL_UPDATE_BRANCH:-master}}
                [ "$proxy_set" = x ] && proxy=$requested_proxy || proxy=${GH_PROXY:-}
            else
                kernel=${kernel:-mihomo}
                branch=${branch:-master}
            fi
            export CLASHCTL_HOME="$install_home" CLASHCTL_SRC="$install_home"
            if [ -f "$install_home/.env" ] && [ ! -e "$install_home/.clashctl-uninitialized" ] &&
                [ ! -e "$install_home/.clashctl-incomplete" ]; then
                _install_intro '更新现有安装' "$install_home" "$home_source" "$local_source" "$branch"
                _install_refresh_current "$install_home" "$method" "$local_source" "$script_dir" "$branch" "$proxy" || return 1
            else
                _install_intro '继续未完成的安装' "$install_home" "$home_source" "$local_source" "$branch"
                if [ "$local_source" = true ] && [ "$method" = archive ] && [ "$script_dir" != "$install_home" ]; then
                    _install_refresh_current "$install_home" "$method" "$local_source" "$script_dir" "$branch" "$proxy" || return 1
                fi
            fi
        else
            legacy_home=$install_home
        fi
    else
        # 历史版本默认安装到 ~/clashctl；新默认目录空闲时自动搬迁已验证的旧安装。
        if [ "$install_home" = "$HOME/.clashctl" ] && [ -d "$HOME/clashctl" ]; then
            if existing_kind=$(_install_existing_kind "$HOME/clashctl"); then
                case $existing_kind in
                legacy-v1 | legacy-v2) legacy_home="$HOME/clashctl" ;;
                current)
                    printf '已在旧默认路径发现新版安装，请使用 --home %s 后重试\n' "$HOME/clashctl" >&2
                    return 1
                    ;;
                *) existing_kind='' ;;
                esac
            elif [ -f "$HOME/clashctl/.env" ] &&
                { [ -f "$HOME/clashctl/scripts/cmd/clashctl.sh" ] ||
                    [ -f "$HOME/clashctl/scripts/lib/common.sh" ] ||
                    [ -d "$HOME/clashctl/resources" ]; }; then
                printf '检测到可能的旧版安装，但无法安全确认：%s；请检查归属与脚本权限后重试\n' "$HOME/clashctl" >&2
                return 1
            else
                existing_kind=''
            fi
        fi
    fi
    if [ -n "$legacy_home" ] && [ -f "$legacy_home/.env" ]; then
        local requested_kernel=$kernel requested_branch=$branch requested_proxy=$proxy
        if [ "$existing_kind" = legacy-v2 ]; then
            [ ! -L "$legacy_home/.env" ] &&
                [ "$(stat -c %u -- "$legacy_home/.env")" = "$(id -u)" ] || return 1
            # shellcheck source=/dev/null
            . "$legacy_home/.env" || return 1
            legacy_kernel=${CLASHCTL_KERNEL:-mihomo}
            case $legacy_kernel in mihomo | clash) ;; *) return 1 ;; esac
            kernel=${requested_kernel:-${CLASHCTL_KERNEL:-mihomo}}
            branch=${requested_branch:-${CLASHCTL_UPDATE_BRANCH:-master}}
            [ "$proxy_set" = x ] && proxy=$requested_proxy || proxy=${GH_PROXY:-}
        else
            local old_kernel old_proxy
            old_kernel=$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?CLASHCTL_KERNEL[[:space:]]*=[[:space:]]*(.*)$/\2/p' "$legacy_home/.env" | tail -1)
            case $old_kernel in
            mihomo | "'mihomo'" | '"mihomo"') old_kernel=mihomo ;;
            clash | "'clash'" | '"clash"') old_kernel=clash ;;
            *) printf '旧版 .env 中的 CLASHCTL_KERNEL 无法安全识别，请改为 mihomo 或 clash 后重试\n' >&2; return 1 ;;
            esac
            legacy_kernel=$old_kernel
            kernel=${kernel:-$old_kernel}
            old_proxy=$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?GH_PROXY[[:space:]]*=[[:space:]]*(.*)$/\2/p' "$legacy_home/.env" | tail -1)
            case $old_proxy in
            \'*\' | \"*\") old_proxy=${old_proxy:1:${#old_proxy}-2} ;;
            esac
            [[ $old_proxy != *[^a-zA-Z0-9_./:+?@%-]* ]] || old_proxy=''
            [ "$proxy_set" = x ] || proxy=${old_proxy:-$proxy}
        fi
    fi
    if [ -z "$existing_kind" ] || [ -n "$legacy_home" ]; then
        [ -z "$legacy_home" ] || legacy_kernel=${legacy_kernel:-mihomo}
        branch=${branch:-master}
        if [ -n "$legacy_home" ]; then
            if [ "$legacy_home" = "$install_home" ]; then
                _install_intro '原路径升级' "$install_home" "$home_source" "$local_source" "$branch"
            else
                _install_intro '迁移旧版安装' "$install_home" "$home_source" "$local_source" "$branch"
                printf '       旧版目录: %s\n' "$legacy_home" >&2
            fi
        else
            _install_intro '新安装 clashctl' "$install_home" "$home_source" "$local_source" "$branch"
        fi
        mkdir -p -- "$(dirname -- "$install_home")"
        stage=$(mktemp -d "${install_home}.download.XXXXXX")
        trap _install_main_cleanup EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        [ "$local_source" = true ] || _install_bootstrap_log info "下载源码（分支 $branch）"
        if [ "$local_source" = true ]; then
            method=archive
            # 保留工作区修改；排除运行数据与被 .gitignore 忽略的本地文件。
            _install_copy_local_source "$script_dir" "$stage"
        elif command -v git >/dev/null 2>&1; then
            method=git
            local url=https://github.com/nelvko/clash-for-linux-install.git
            local -a clone_options=(--depth 1 --branch "$branch")
            [ "${_INSTALL_VERBOSE:-}" = 1 ] || clone_options+=(--quiet)
            [ -z "$proxy" ] || url="${proxy%/}/$url"
            git -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=60 \
                clone "${clone_options[@]}" -- "$url" "$stage"
        else
            method=archive
            _source_archive "$stage" "$branch" "$proxy"
            [ ! -e "$stage/.git" ] && [ ! -L "$stage/.git" ] || return 1
        fi
        _source_validate "$stage"
        [ "$local_source" = true ] || _install_bootstrap_log ok '源码已准备'
        _install_lock "$stage" || return 1
        # 源码准备不占锁；取得锁后重新核对目录，避免覆盖并发安装的结果。
        if [ -n "$legacy_home" ]; then
            [ "$(_install_existing_kind "$legacy_home")" = "$existing_kind" ] || {
                printf '旧安装目录状态已变化，请重新运行安装器\n' >&2
                return 1
            }
        fi
        if [ "$legacy_home" != "$install_home" ] &&
            { [ -e "$install_home" ] || [ -L "$install_home" ]; }; then
            printf '安装目录在准备源码期间已被创建，未修改目录：%s\n' "$install_home" >&2
            return 1
        fi
        if [ "$method" = archive ]; then
            _source_manifest "$stage" >"$stage/.clashctl-files"
        fi
        (umask 077; printf '%s\n%s\n' "$install_home" "$method" >"$stage/.clashctl-install")
        (umask 077; printf '%s\n' "$install_home" >"$stage/.clashctl-uninitialized")
        if [ -n "$legacy_home" ]; then
            # 先确认备份与失败现场都能安全保存，再停旧内核或修改旧数据。
            backup=$(_install_recovery_path "$install_home" backups "${legacy_home##*/}") || return 1
            _install_recovery_path "$install_home" failed >/dev/null || return 1
            export CLASHCTL_HOME="$stage" CLASHCTL_SRC="$stage" CLASHCTL_KERNEL="${kernel:-mihomo}"
            . "$stage/scripts/preflight.sh" || return 1
            legacy_recovery_required=true
            _install_legacy_prepare_for_copy "$legacy_home" "$existing_kind" "$legacy_kernel" || {
                printf '无法锁定旧版订阅数据，旧目录未迁移：%s\n' "$legacy_home" >&2
                return 1
            }
            _install_legacy_data "$legacy_home" "$existing_kind" "$stage" "$install_home" || {
                _install_legacy_profiles_lock_release
                _install_legacy_service_restore "$legacy_kernel" || return 1
                printf '旧版数据校验或复制失败，旧目录未迁移：%s\n' "$legacy_home" >&2
                return 1
            }
            export CLASHCTL_HOME="$stage" CLASHCTL_SRC="$stage" CLASHCTL_KERNEL="${kernel:-mihomo}"
            . "$stage/scripts/preflight.sh" || {
                _install_legacy_profiles_lock_release
                _install_legacy_service_restore "$legacy_kernel" || return 1
                return 1
            }
            export CLASHCTL_HOME="$install_home" CLASHCTL_KERNEL="${kernel:-mihomo}"
            [ ! -e "$backup" ] && [ ! -L "$backup" ] || {
                _install_legacy_profiles_lock_release
                _install_legacy_service_restore "$legacy_kernel" || return 1
                return 1
            }
            _install_legacy_service_prepare "$legacy_home" "$legacy_kernel" || {
                _install_legacy_profiles_lock_release
                _install_legacy_service_restore "$legacy_kernel" || return 1
                return 1
            }
            # 旧内核停下后再复制一次运行缓存，避免复制时仍在写入。
            if [ -f "$legacy_home/resources/cache.db" ] && [ ! -L "$legacy_home/resources/cache.db" ]; then
                install -m 0600 "$legacy_home/resources/cache.db" "$stage/resources/cache.db" || {
                    _install_legacy_profiles_lock_release
                    _install_legacy_service_restore "$legacy_kernel"
                    return 1
                }
            fi
            mv -T -- "$legacy_home" "$backup" || {
                _install_legacy_profiles_lock_release
                _install_legacy_service_restore "$legacy_kernel"
                return 1
            }
            _install_legacy_profiles_lock_release
        fi
        if ! mv -T -- "$stage" "$install_home"; then
            [ -z "$backup" ] || _install_legacy_rollback "$legacy_home" "$backup" "$install_home" "$legacy_kernel"
            return 1
        fi
        stage=''
    fi
    export CLASHCTL_HOME="$install_home" CLASHCTL_SRC="$install_home" CLASHCTL_KERNEL="$kernel"
    export CLASHCTL_UPDATE_BRANCH="$branch" GH_PROXY="$proxy"
    if ! { (umask 077; : >"$install_home/.clashctl-incomplete") &&
        _install_initialize "$kernel" "$branch" "$proxy" "$timeout_set" "$requested_timeout" "$backup" "$subscription"; }; then
        if [ -n "$backup" ]; then
            _install_legacy_rollback "$legacy_home" "$backup" "$install_home" "$legacy_kernel" || return 1
        else
            local retry_command branch_arg proxy_arg
            if [ "${CLASHCTL_DOWNLOAD_TIMED_OUT:-0}" = 1 ]; then
                local retry_timeout=${CLASHCTL_DOWNLOAD_TIMEOUT:-60}
                if [[ ! $retry_timeout =~ ^[0-9]+$ ]] || [ "$retry_timeout" -lt 180 ]; then
                    retry_timeout=180
                fi
                printf -v retry_command 'CLASHCTL_DOWNLOAD_TIMEOUT=%q bash %q --home %q' \
                    "$retry_timeout" "$install_home/install.sh" "$install_home"
            else
                printf -v retry_command 'bash %q --home %q' "$install_home/install.sh" "$install_home"
            fi
            printf -v branch_arg ' --branch=%q' "$branch"
            retry_command+=$branch_arg
            if [ -n "$proxy" ] || [ "$proxy_set" = x ]; then
                printf -v proxy_arg ' --gh-proxy=%q' "$proxy"
                retry_command+=$proxy_arg
            fi
            printf '安装未完成，已保留目录：%s\n' "$install_home" >&2
            printf '重试: %s\n' "$retry_command" >&2
        fi
        return 1
    fi
    rm -f -- "$install_home/.clashctl-incomplete" || return 1
    legacy_recovery_required=false
    if [ -n "$legacy_shell_backup" ]; then
        rm -rf -- "$legacy_shell_backup" ||
            printf '无法清理 Shell 配置备份，请手动检查：%s\n' "$legacy_shell_backup" >&2
    fi
    _install_complete "$backup"
)

# 完整读取脚本后才执行，下载中断时不会提前开始安装。
if [ "${CLASHCTL_INSTALL_RUNNING:-}" != 1 ] &&
    { [ -z "${BASH_SOURCE[0]:-}" ] || [ "${BASH_SOURCE[0]}" = "$0" ]; }; then
    main "$@"
fi
