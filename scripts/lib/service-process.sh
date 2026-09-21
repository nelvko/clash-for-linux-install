#!/usr/bin/env bash

_SERVICE_PROCESS_HELPER_FILE=$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null) ||
    _SERVICE_PROCESS_HELPER_FILE=${BASH_SOURCE[0]}

_service_process_starttime() {
    local pid=$1 stat rest
    local -a fields=()
    { IFS= read -r stat <"/proc/${pid}/stat"; } 2>/dev/null || return 1
    rest=${stat##*) }
    [ "$rest" != "$stat" ] || return 1
    read -r -a fields <<<"$rest"
    [ "${#fields[@]}" -ge 20 ] || return 1
    case ${fields[19]} in '' | *[!0-9]*) return 1 ;; esac
    printf '%s\n' "${fields[19]}"
}

_service_process_argv_hex() {
    local pid=$1 value
    value=$(od -An -v -tx1 "/proc/${pid}/cmdline" 2>/dev/null |
        tr -d ' \n') || return 1
    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
}

_service_process_values_argv_hex() {
    [ "$#" -gt 0 ] || return 1
    printf '%s\0' "$@" | od -An -v -tx1 | tr -d ' \n'
}

_service_process_exe_id() {
    stat -Lc '%d:%i' -- "/proc/$1/exe" 2>/dev/null
}

_service_process_exe_path() {
    local path
    path=$(readlink -- "/proc/$1/exe" 2>/dev/null) || return 1
    path=${path% (deleted)}
    printf '%s\n' "$path"
}

_service_process_identity_matches() {
    local pid=$1 expected_starttime=$2 expected_argv=$3 expected_exe_id=$4
    local starttime_before starttime_after argv exe_id
    starttime_before=$(_service_process_starttime "$pid") || return 1
    [ "$starttime_before" = "$expected_starttime" ] || return 1
    argv=$(_service_process_argv_hex "$pid") || return 1
    [ "$argv" = "$expected_argv" ] || return 1
    exe_id=$(_service_process_exe_id "$pid") || return 1
    [ "$exe_id" = "$expected_exe_id" ] || return 1
    starttime_after=$(_service_process_starttime "$pid") || return 1
    [ "$starttime_after" = "$starttime_before" ]
}

_service_process_snapshot() {
    local pid=$1 expected_exe=$2 expected_argv=$3
    local expected_path actual_path starttime_before starttime_after argv exe_id
    expected_path=$(readlink -f -- "$expected_exe" 2>/dev/null) || return 1
    starttime_before=$(_service_process_starttime "$pid") || return 1
    argv=$(_service_process_argv_hex "$pid") || return 1
    [ "$argv" = "$expected_argv" ] || return 1
    actual_path=$(_service_process_exe_path "$pid") || return 1
    [ "$actual_path" = "$expected_path" ] || return 1
    exe_id=$(_service_process_exe_id "$pid") || return 1
    starttime_after=$(_service_process_starttime "$pid") || return 1
    [ "$starttime_after" = "$starttime_before" ] || return 1

    _SERVICE_SNAPSHOT_PID=$pid
    _SERVICE_SNAPSHOT_STARTTIME=$starttime_before
    _SERVICE_SNAPSHOT_ARGV=$argv
    _SERVICE_SNAPSHOT_EXE_ID=$exe_id
}

_service_process_record_create() {
    local record=$1 pid=$2 expected_exe=$3
    shift 3
    local expected_argv birth_starttime attempt=0 tmp
    unset _SERVICE_PROCESS_BIRTH_PID _SERVICE_PROCESS_BIRTH_STARTTIME
    unset _SERVICE_SNAPSHOT_PID _SERVICE_SNAPSHOT_STARTTIME
    unset _SERVICE_SNAPSHOT_ARGV _SERVICE_SNAPSHOT_EXE_ID
    birth_starttime=$(_service_process_starttime "$pid") || return 1
    _SERVICE_PROCESS_BIRTH_PID=$pid
    _SERVICE_PROCESS_BIRTH_STARTTIME=$birth_starttime
    expected_argv=$(_service_process_values_argv_hex "$@") || return 1

    while [ "$attempt" -lt 100 ]; do
        if _service_process_snapshot "$pid" "$expected_exe" "$expected_argv"; then
            [ "$_SERVICE_SNAPSHOT_STARTTIME" = "$birth_starttime" ] || return 1
            break
        fi
        kill -0 "$pid" 2>/dev/null || return 1
        attempt=$((attempt + 1))
        sleep 0.01
    done
    [ "${_SERVICE_SNAPSHOT_PID:-}" = "$pid" ] || return 1

    tmp=$(mktemp -- "${record}.new.XXXXXX") || return 1
    if ! (
        umask 077
        printf '%s\n' \
            'version=1' \
            "pid=$_SERVICE_SNAPSHOT_PID" \
            "starttime=$_SERVICE_SNAPSHOT_STARTTIME" \
            "argv=$_SERVICE_SNAPSHOT_ARGV" \
            "exe_id=$_SERVICE_SNAPSHOT_EXE_ID" >"$tmp"
    ) || ! chmod 0600 -- "$tmp" || ! /bin/mv -fT -- "$tmp" "$record"; then
        /usr/bin/rm -f -- "$tmp"
        return 1
    fi
}

_service_process_lock_owner_is_alive() {
    local lock=$1 owner_pid owner_starttime current_starttime
    [ -f "$lock/owner" ] && [ ! -L "$lock/owner" ] || return 1
    read -r owner_pid owner_starttime <"$lock/owner" || return 1
    case $owner_pid in '' | *[!0-9]*) return 1 ;; esac
    case $owner_starttime in '' | *[!0-9]*) return 1 ;; esac
    current_starttime=$(_service_process_starttime "$owner_pid") || return 1
    [ "$current_starttime" = "$owner_starttime" ]
}

_service_process_lock_acquire() {
    local record=$1 lock attempt=0 owner_starttime
    lock="${record}.lock"
    while [ "$attempt" -lt 200 ]; do
        if mkdir -m 0700 -- "$lock" 2>/dev/null; then
            owner_starttime=$(_service_process_starttime "$BASHPID") || {
                rmdir -- "$lock" 2>/dev/null || true
                return 1
            }
            if ! printf '%s %s\n' "$BASHPID" "$owner_starttime" >"$lock/owner"; then
                /usr/bin/rm -f -- "$lock/owner"
                rmdir -- "$lock" 2>/dev/null || true
                return 1
            fi
            _SERVICE_PROCESS_LOCK_PATH=$lock
            return 0
        fi
        [ -d "$lock" ] && [ ! -L "$lock" ] || return 1
        if [ "$attempt" -ge 5 ] && ! _service_process_lock_owner_is_alive "$lock"; then
            /usr/bin/rm -f -- "$lock/owner" 2>/dev/null || return 1
            rmdir -- "$lock" 2>/dev/null || return 1
            attempt=$((attempt + 1))
            continue
        fi
        attempt=$((attempt + 1))
        sleep 0.01
    done
    return 1
}

_service_process_lock_release() {
    local lock=$1
    [ -n "$lock" ] || return 1
    /usr/bin/rm -f -- "$lock/owner" || return 1
    rmdir -- "$lock" || return 1
    [ "${_SERVICE_PROCESS_LOCK_PATH:-}" != "$lock" ] || unset _SERVICE_PROCESS_LOCK_PATH
}

_service_process_record_load() {
    local record=$1 key value
    local version='' pid='' starttime='' argv='' exe_id='' count=0
    local seen_version=0 seen_pid=0 seen_starttime=0 seen_argv=0 seen_exe_id=0
    unset _SERVICE_RECORD_PID _SERVICE_RECORD_STARTTIME _SERVICE_RECORD_ARGV _SERVICE_RECORD_EXE_ID
    [ -f "$record" ] && [ ! -L "$record" ] || return 1

    while IFS='=' read -r key value; do
        count=$((count + 1))
        case $key in
        version)
            [ "$seen_version" -eq 0 ] || return 1
            seen_version=1
            version=$value
            ;;
        pid)
            [ "$seen_pid" -eq 0 ] || return 1
            seen_pid=1
            pid=$value
            ;;
        starttime)
            [ "$seen_starttime" -eq 0 ] || return 1
            seen_starttime=1
            starttime=$value
            ;;
        argv)
            [ "$seen_argv" -eq 0 ] || return 1
            seen_argv=1
            argv=$value
            ;;
        exe_id)
            [ "$seen_exe_id" -eq 0 ] || return 1
            seen_exe_id=1
            exe_id=$value
            ;;
        *) return 1 ;;
        esac
    done <"$record"

    [ "$count" -eq 5 ] && [ "$version" = 1 ] || return 1
    case $pid in '' | *[!0-9]*) return 1 ;; esac
    [ "$pid" -gt 1 ] || return 1
    case $starttime in '' | *[!0-9]*) return 1 ;; esac
    case $argv in '' | *[!0-9a-f]*) return 1 ;; esac
    [ $(( ${#argv} % 2 )) -eq 0 ] || return 1
    case $exe_id in
    *:*)
        case ${exe_id%%:*} in '' | *[!0-9]*) return 1 ;; esac
        case ${exe_id#*:} in '' | *[!0-9]* | *:*) return 1 ;; esac
        ;;
    *) return 1 ;;
    esac

    _SERVICE_RECORD_PID=$pid
    _SERVICE_RECORD_STARTTIME=$starttime
    _SERVICE_RECORD_ARGV=$argv
    _SERVICE_RECORD_EXE_ID=$exe_id
}

_service_process_record_matches_loaded() {
    _service_process_identity_matches \
        "$_SERVICE_RECORD_PID" "$_SERVICE_RECORD_STARTTIME" \
        "$_SERVICE_RECORD_ARGV" "$_SERVICE_RECORD_EXE_ID"
}

_service_process_record_pid() {
    _service_process_record_load "$1" || return 1
    _service_process_record_matches_loaded || return 1
    printf '%s\n' "$_SERVICE_RECORD_PID"
}

_service_process_stop_snapshot() {
    local pid=$1 starttime=$2 argv=$3 exe_id=$4
    if _service_process_identity_matches "$pid" "$starttime" "$argv" "$exe_id"; then
        kill -TERM "$pid" 2>/dev/null || true
    fi
    sleep 0.05
    if _service_process_identity_matches "$pid" "$starttime" "$argv" "$exe_id"; then
        kill -KILL "$pid" 2>/dev/null || true
    fi
}

_service_process_stop_birth() {
    local pid=$1 starttime=$2 current_starttime
    current_starttime=$(_service_process_starttime "$pid") || return 0
    [ "$current_starttime" = "$starttime" ] || return 0
    kill -TERM "$pid" 2>/dev/null || true
    sleep 0.05
    current_starttime=$(_service_process_starttime "$pid") || return 0
    [ "$current_starttime" = "$starttime" ] || return 0
    kill -KILL "$pid" 2>/dev/null || true
}

_service_process_record_has_identity() {
    local record=$1 pid=$2 starttime=$3 argv=$4 exe_id=$5
    _service_process_record_load "$record" || return 1
    [ "$_SERVICE_RECORD_PID" = "$pid" ] &&
        [ "$_SERVICE_RECORD_STARTTIME" = "$starttime" ] &&
        [ "$_SERVICE_RECORD_ARGV" = "$argv" ] &&
        [ "$_SERVICE_RECORD_EXE_ID" = "$exe_id" ]
}

_service_process_wait_stopped() {
    local record=$1 pid=$2 starttime=$3 argv=$4 exe_id=$5 attempt=0
    while [ "$attempt" -lt 20 ]; do
        _service_process_record_has_identity \
            "$record" "$pid" "$starttime" "$argv" "$exe_id" || return 2
        _service_process_identity_matches "$pid" "$starttime" "$argv" "$exe_id" || return 0
        attempt=$((attempt + 1))
        sleep 0.05
    done
    return 1
}

_service_process_stop_recorded() {
    local record=$1 pid starttime argv exe_id wait_rc=0
    _SERVICE_PROCESS_RECORD_CAN_REMOVE=0
    _service_process_record_load "$record" || return 1
    pid=$_SERVICE_RECORD_PID
    starttime=$_SERVICE_RECORD_STARTTIME
    argv=$_SERVICE_RECORD_ARGV
    exe_id=$_SERVICE_RECORD_EXE_ID
    if ! _service_process_identity_matches "$pid" "$starttime" "$argv" "$exe_id"; then
        _SERVICE_PROCESS_RECORD_CAN_REMOVE=1
        return 0
    fi

    # Validate immediately before each signal. A reused PID never receives KILL.
    _service_process_record_has_identity \
        "$record" "$pid" "$starttime" "$argv" "$exe_id" || return 0
    _service_process_identity_matches "$pid" "$starttime" "$argv" "$exe_id" || return 0
    kill -TERM "$pid" 2>/dev/null || {
        if ! _service_process_identity_matches "$pid" "$starttime" "$argv" "$exe_id"; then
            _service_process_record_has_identity \
                "$record" "$pid" "$starttime" "$argv" "$exe_id" &&
                _SERVICE_PROCESS_RECORD_CAN_REMOVE=1
            return 0
        fi
        return 1
    }
    _service_process_wait_stopped \
        "$record" "$pid" "$starttime" "$argv" "$exe_id" || wait_rc=$?
    if [ "$wait_rc" -eq 0 ]; then
        _SERVICE_PROCESS_RECORD_CAN_REMOVE=1
        return 0
    fi
    [ "$wait_rc" -ne 2 ] || return 0

    _service_process_record_has_identity \
        "$record" "$pid" "$starttime" "$argv" "$exe_id" || return 0
    _service_process_identity_matches "$pid" "$starttime" "$argv" "$exe_id" || {
        _SERVICE_PROCESS_RECORD_CAN_REMOVE=1
        return 0
    }
    kill -KILL "$pid" 2>/dev/null || {
        _service_process_identity_matches "$pid" "$starttime" "$argv" "$exe_id" || {
            _SERVICE_PROCESS_RECORD_CAN_REMOVE=1
            return 0
        }
        return 1
    }
    wait_rc=0
    _service_process_wait_stopped \
        "$record" "$pid" "$starttime" "$argv" "$exe_id" || wait_rc=$?
    if [ "$wait_rc" -eq 0 ]; then
        _SERVICE_PROCESS_RECORD_CAN_REMOVE=1
        return 0
    fi
    [ "$wait_rc" -eq 2 ] && return 0
    return 1
}

_service_privileged_validate_key() {
    case $1 in '' | *[!0-9]*) return 1 ;; esac
    case $2 in '' | *[!a-zA-Z0-9_.-]*) return 1 ;; esac
}

_service_privileged_record_path() {
    local runtime_dir=$1 owner_uid=$2 kernel=$3
    _service_privileged_validate_key "$owner_uid" "$kernel" || return 1
    printf '%s/%s.%s.process\n' "$runtime_dir" "$owner_uid" "$kernel"
}

_service_privileged_runtime_is_secure() {
    local runtime_dir=$1 metadata
    [ -d "$runtime_dir" ] && [ ! -L "$runtime_dir" ] || return 1
    metadata=$(stat -c '%u:%g:%a' -- "$runtime_dir" 2>/dev/null) || return 1
    [ "$metadata" = 0:0:755 ]
}

_service_privileged_record_is_secure() {
    local record=$1 metadata
    [ -f "$record" ] && [ ! -L "$record" ] || return 1
    metadata=$(stat -c '%u:%g:%a:%h' -- "$record" 2>/dev/null) || return 1
    [ "$metadata" = 0:0:600:1 ]
}

_service_privileged_start_command_locked() {
    local record=$1 expected_exe=$2
    shift 2
    local pid expected_argv
    expected_argv=$(_service_process_values_argv_hex "$@") || return 1
    if [ -e "$record" ] || [ -L "$record" ]; then
        _service_privileged_record_is_secure "$record" || return 1
        if _service_process_record_pid "$record" >/dev/null 2>&1; then
            [ "$_SERVICE_RECORD_ARGV" = "$expected_argv" ] || return 1
            return 0
        fi
        /usr/bin/rm -f -- "$record" || return 1
    fi

    nohup "$@" </dev/null 2>&1 &
    pid=$!
    if _service_process_record_create "$record" "$pid" "$expected_exe" "$@"; then
        if _service_privileged_record_is_secure "$record"; then
            return 0
        fi
        _service_process_stop_recorded "$record" || true
        /usr/bin/rm -f -- "$record"
        return 1
    fi
    if [ "${_SERVICE_SNAPSHOT_PID:-}" = "$pid" ]; then
        _service_process_stop_snapshot \
            "$pid" "$_SERVICE_SNAPSHOT_STARTTIME" \
            "$_SERVICE_SNAPSHOT_ARGV" "$_SERVICE_SNAPSHOT_EXE_ID"
    elif [ "${_SERVICE_PROCESS_BIRTH_PID:-}" = "$pid" ]; then
        _service_process_stop_birth "$pid" "$_SERVICE_PROCESS_BIRTH_STARTTIME"
    fi
    /usr/bin/rm -f -- "$record"
    return 1
}

_service_privileged_start_command_at() {
    local runtime_dir=$1 owner_uid=$2 kernel=$3 expected_exe=$4
    shift 4
    local record lock rc=0
    [ "$(id -u)" -eq 0 ] || return 1
    _service_privileged_validate_key "$owner_uid" "$kernel" || return 1
    if [ -e "$runtime_dir" ] || [ -L "$runtime_dir" ]; then
        _service_privileged_runtime_is_secure "$runtime_dir" || return 1
    else
        /usr/bin/install -d -m 0755 -o 0 -g 0 -- "$runtime_dir" || return 1
        _service_privileged_runtime_is_secure "$runtime_dir" || return 1
    fi
    record=$(_service_privileged_record_path "$runtime_dir" "$owner_uid" "$kernel") || return 1
    _service_process_lock_acquire "$record" || return 1
    lock=$_SERVICE_PROCESS_LOCK_PATH
    _service_privileged_start_command_locked "$record" "$expected_exe" "$@" || rc=$?
    _service_process_lock_release "$lock" || rc=1
    return "$rc"
}

_service_privileged_start_at() {
    local runtime_dir=$1 owner_uid=$2 kernel=$3 bin=$4 resources=$5 config=$6
    _service_privileged_start_command_at \
        "$runtime_dir" "$owner_uid" "$kernel" "$bin" \
        "$bin" -d "$resources" -f "$config"
}

_service_privileged_stop_at() {
    local runtime_dir=$1 owner_uid=$2 kernel=$3 record lock rc=0
    [ "$(id -u)" -eq 0 ] || return 1
    _service_privileged_validate_key "$owner_uid" "$kernel" || return 1
    [ -e "$runtime_dir" ] || [ -L "$runtime_dir" ] || return 0
    _service_privileged_runtime_is_secure "$runtime_dir" || return 1
    record=$(_service_privileged_record_path "$runtime_dir" "$owner_uid" "$kernel") || return 1
    _service_process_lock_acquire "$record" || return 1
    lock=$_SERVICE_PROCESS_LOCK_PATH
    if [ -e "$record" ] || [ -L "$record" ]; then
        if ! _service_privileged_record_is_secure "$record" ||
            ! _service_process_stop_recorded "$record"; then
            rc=1
        elif [ "${_SERVICE_PROCESS_RECORD_CAN_REMOVE:-0}" -ne 0 ]; then
            /usr/bin/rm -f -- "$record" || rc=1
        fi
    fi
    _service_process_lock_release "$lock" || rc=1
    return "$rc"
}

_service_process_privileged_cli() {
    local action=${1:-}
    [ "$#" -gt 0 ] && shift
    [ "$(id -u)" -eq 0 ] || return 1
    umask 077
    case $action in
    privileged-start)
        [ "$#" -eq 5 ] || return 2
        _service_privileged_start_at /run/clashctl "$@"
        ;;
    privileged-stop)
        [ "$#" -eq 2 ] || return 2
        _service_privileged_stop_at /run/clashctl "$@"
        ;;
    *) return 2 ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    _service_process_privileged_cli "$@"
    exit $?
fi
