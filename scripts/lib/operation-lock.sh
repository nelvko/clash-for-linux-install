#!/usr/bin/env bash

# Serializes lifecycle operations for one effective uid. The lock lives outside
# CLASHCTL_HOME so uninstalling the installation cannot replace the locked inode.

_operation_lock_emit_error() {
    if declare -F _ui_error >/dev/null 2>&1; then
        _ui_error "$1"
    else
        printf '[ERROR] %s\n' "$1" >&2
    fi
}

_operation_lock_emit_detail() {
    local label=$1
    shift
    if declare -F _ui_detail >/dev/null 2>&1; then
        _ui_detail "$label" "$*"
    else
        printf '        %s: %s\n' "$label" "$*" >&2
    fi
}

_operation_lock_validate_base() {
    local base=$1 expected_owner=$2 mode owner
    [ -n "$base" ] && [ "$base" != / ] && [[ $base == /* ]] || return 1
    ! [[ $base =~ [[:cntrl:]] ]] || return 1
    [ -d "$base" ] && [ ! -L "$base" ] && [ -x "$base" ] && [ -w "$base" ] || return 1
    owner=$(stat -c %u -- "$base" 2>/dev/null) || return 1
    mode=$(stat -c %a -- "$base" 2>/dev/null) || return 1
    case $owner:$mode in
    *[!0-9:]* | :* | *:) return 1 ;;
    esac
    [ "$owner" -eq "$expected_owner" ] && [ $((8#$mode & 0022)) -eq 0 ]
}

_operation_lock_validate_tmp() {
    local mode owner
    [ -d /tmp ] && [ ! -L /tmp ] && [ -x /tmp ] && [ -w /tmp ] || return 1
    owner=$(stat -c %u -- /tmp 2>/dev/null) || return 1
    mode=$(stat -c %a -- /tmp 2>/dev/null) || return 1
    case $owner:$mode in
    *[!0-9:]* | :* | *:) return 1 ;;
    esac
    [ "$owner" -eq 0 ] && [ $((8#$mode & 0002)) -ne 0 ] &&
        [ $((8#$mode & 01000)) -ne 0 ]
}

_operation_lock_base() {
    local uid=$1
    if [ "$uid" -eq 0 ] && _operation_lock_validate_base /run 0; then
        printf '/run\n'
        return 0
    fi
    _operation_lock_validate_tmp || return 1
    printf '/tmp\n'
}

_operation_lock_fd_matches() {
    local fd=$1 file=$2 path_identity fd_identity
    case $fd in '' | *[!0-9]*) return 1 ;; esac
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    [ -e "/proc/self/fd/$fd" ] || return 1
    path_identity=$(stat -c '%d:%i' -- "$file" 2>/dev/null) || return 1
    fd_identity=$(stat -Lc '%d:%i' -- "/proc/self/fd/$fd" 2>/dev/null) || return 1
    [ "$path_identity" = "$fd_identity" ]
}

_operation_lock_has_flock() {
    command -v flock >/dev/null 2>&1
}

operation_lock_acquire() {
    local uid base lock_dir lock_file owner mode links path_identity fd_identity operation_fd

    _operation_lock_has_flock || {
        _operation_lock_emit_error '缺少操作锁依赖 flock，拒绝在无互斥保护下继续'
        _operation_lock_emit_detail '处理' '安装 util-linux（需提供 flock 命令）后重试'
        return 1
    }
    uid=$(id -u) || return 1
    base=$(_operation_lock_base "$uid") || {
        _operation_lock_emit_error '无法使用安全的运行时目录建立操作锁，未修改系统'
        _operation_lock_emit_detail '要求' '运行时目录必须归当前用户所有，且不能被组用户或其他用户写入'
        return 1
    }
    lock_dir="${base}/clashctl-operation-${uid}"
    lock_file="${lock_dir}/operation.lock"

    if ! mkdir -m 0700 -- "$lock_dir" 2>/dev/null; then
        if [ ! -d "$lock_dir" ] || [ -L "$lock_dir" ]; then
            _operation_lock_emit_error '操作锁目录类型不安全，未修改系统'
            _operation_lock_emit_detail '目录' "$lock_dir"
            return 1
        fi
    fi
    owner=$(stat -c %u -- "$lock_dir" 2>/dev/null) || owner=
    mode=$(stat -c %a -- "$lock_dir" 2>/dev/null) || mode=
    if [ "$owner" != "$uid" ] || [ "$mode" != 700 ] || [ -L "$lock_dir" ]; then
        _operation_lock_emit_error '操作锁目录的归属或权限不安全，未修改系统'
        _operation_lock_emit_detail '目录' "$lock_dir"
        _operation_lock_emit_detail '要求' "归当前 uid=${uid} 所有，权限必须为 0700"
        return 1
    fi

    if [ ! -e "$lock_file" ] && [ ! -L "$lock_file" ]; then
        (umask 077; set -o noclobber; : >"$lock_file") 2>/dev/null || true
    fi
    if [ ! -f "$lock_file" ] || [ -L "$lock_file" ]; then
        _operation_lock_emit_error '操作锁文件类型不安全，未修改系统'
        _operation_lock_emit_detail '文件' "$lock_file"
        return 1
    fi
    owner=$(stat -c %u -- "$lock_file" 2>/dev/null) || owner=
    mode=$(stat -c %a -- "$lock_file" 2>/dev/null) || mode=
    links=$(stat -c %h -- "$lock_file" 2>/dev/null) || links=
    if [ "$owner" != "$uid" ] || [ "$mode" != 600 ] || [ "$links" != 1 ]; then
        _operation_lock_emit_error '操作锁文件的归属或权限不安全，未修改系统'
        _operation_lock_emit_detail '文件' "$lock_file"
        _operation_lock_emit_detail '要求' "归当前 uid=${uid} 所有，权限必须为 0600，且不能是硬链接"
        return 1
    fi

    if _operation_lock_fd_matches "${CLASHCTL_OPERATION_LOCK_FD:-}" "$lock_file" &&
        flock -n "$CLASHCTL_OPERATION_LOCK_FD" 2>/dev/null; then
        return 0
    fi
    unset CLASHCTL_OPERATION_LOCK_FD CLASHCTL_OPERATION_LOCK_FILE
    exec {operation_fd}<>"$lock_file" || {
        _operation_lock_emit_error '无法打开 clashctl 操作锁，未修改系统'
        return 1
    }
    path_identity=$(stat -c '%d:%i' -- "$lock_file" 2>/dev/null) || path_identity=
    fd_identity=$(stat -Lc '%d:%i' -- "/proc/self/fd/$operation_fd" 2>/dev/null) || fd_identity=
    local fd_metadata=
    fd_metadata=$(stat -Lc '%u:%a:%h' -- "/proc/self/fd/$operation_fd" 2>/dev/null) || fd_metadata=
    if [ -z "$path_identity" ] || [ "$path_identity" != "$fd_identity" ] || [ -L "$lock_file" ]; then
        exec {operation_fd}>&-
        _operation_lock_emit_error '操作锁文件在打开期间发生变化，未修改系统'
        return 1
    fi
    if [ "$fd_metadata" != "${uid}:600:1" ]; then
        exec {operation_fd}>&-
        _operation_lock_emit_error '操作锁文件在打开期间出现不安全的归属或权限，未修改系统'
        return 1
    fi
    if ! flock -n "$operation_fd" 2>/dev/null; then
        exec {operation_fd}>&-
        _operation_lock_emit_error '另一项 clashctl 安装、更新或卸载正在进行，本次未修改系统'
        _operation_lock_emit_detail '处理' '等待当前操作结束后重试'
        return 1
    fi
    CLASHCTL_OPERATION_LOCK_FD=$operation_fd
    CLASHCTL_OPERATION_LOCK_FILE=$lock_file
    export -n CLASHCTL_OPERATION_LOCK_FD CLASHCTL_OPERATION_LOCK_FILE
}

operation_lock_close_fd() {
    local fd=${CLASHCTL_OPERATION_LOCK_FD:-}
    [ -n "$fd" ] || return 0
    case $fd in *[!0-9]*) return 1 ;; esac
    if [ -e "/proc/self/fd/$fd" ]; then
        exec {CLASHCTL_OPERATION_LOCK_FD}>&- || return 1
    fi
    unset CLASHCTL_OPERATION_LOCK_FD CLASHCTL_OPERATION_LOCK_FILE
}
