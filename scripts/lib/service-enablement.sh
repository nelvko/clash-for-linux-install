#!/usr/bin/env bash

# Nameref helpers intentionally access caller-owned arrays by their names.
# shellcheck disable=SC2034,SC2178

# Exact service enablement snapshots. Public API:
#   service_enablement_capture MANAGER SERVICE MANIFEST
#   service_enablement_validate MANAGER SERVICE MANIFEST
#   service_enablement_reconcile MANAGER SERVICE MANIFEST
#   service_enablement_preflight_restore MANAGER SERVICE MANIFEST [EXPECTED_CURRENT_MANIFEST]
#   service_enablement_restore MANAGER SERVICE MANIFEST [EXPECTED_CURRENT_MANIFEST]
# On failure, SERVICE_ENABLEMENT_ERROR contains a human-readable diagnostic.

SERVICE_ENABLEMENT_MANIFEST_MAX_BYTES=${SERVICE_ENABLEMENT_MANIFEST_MAX_BYTES:-65536}
SERVICE_ENABLEMENT_MANIFEST_MAX_RECORDS=${SERVICE_ENABLEMENT_MANIFEST_MAX_RECORDS:-512}
SERVICE_ENABLEMENT_PATH_MAX_BYTES=${SERVICE_ENABLEMENT_PATH_MAX_BYTES:-4096}
SERVICE_ENABLEMENT_TARGET_MAX_BYTES=${SERVICE_ENABLEMENT_TARGET_MAX_BYTES:-4096}
SERVICE_ENABLEMENT_ERROR=
SERVICE_ENABLEMENT_STATE=
SERVICE_ENABLEMENT_LINKS=
_SERVICE_ENABLEMENT_RESTORE_DESIRED_STATE=
_SERVICE_ENABLEMENT_RESTORE_CURRENT_STATE=
_SERVICE_ENABLEMENT_RESTORE_DESIRED_RECORDS=()
_SERVICE_ENABLEMENT_RESTORE_CURRENT_RECORDS=()

service_enablement_systemd_persistent_root() {
    printf '%s\n' /etc/systemd/system
}

service_enablement_systemd_runtime_root() {
    printf '%s\n' /run/systemd/system
}

service_enablement_sysv_root() {
    printf '%s\n' /etc
}

service_enablement_openrc_root() {
    printf '%s\n' /etc/runlevels
}

service_enablement_runit_link() {
    printf '/etc/runit/runsvdir/default/%s\n' "$1"
}

service_enablement_systemd_state() {
    systemctl is-enabled "$1.service" 2>/dev/null
}

service_enablement_systemd_reload() {
    systemctl daemon-reload >/dev/null 2>&1
}

service_enablement_systemd_unit_path() {
    systemctl show "$1.service" -p FragmentPath --value 2>/dev/null
}

service_enablement_sysv_service_path() {
    local root
    root=$(service_enablement_sysv_root) || return 1
    printf '%s/init.d/%s\n' "${root%/}" "$1"
}

service_enablement_openrc_service_path() {
    printf '/etc/init.d/%s\n' "$1"
}

service_enablement_runit_service_path() {
    printf '/etc/sv/%s\n' "$1"
}

# Tests may replace this with a deterministic mutation to exercise race checks.
_service_enablement_before_restore_commit() {
    return 0
}

_service_enablement_fail() {
    SERVICE_ENABLEMENT_ERROR=$1
    return 1
}

_service_enablement_validate_args() {
    local manager=$1 service=$2
    case $manager in
    systemd | sysvinit | openrc | runit) ;;
    *) _service_enablement_fail "unsupported service manager: $manager"; return ;;
    esac
    if ! [[ $service =~ ^[A-Za-z0-9][A-Za-z0-9_.@:-]{0,127}$ ]]; then
        _service_enablement_fail "invalid service name: $service"
        return
    fi
}

_service_enablement_validate_absolute_path() {
    local path=$1 rest component
    [ -n "$path" ] && [ "${#path}" -le "$SERVICE_ENABLEMENT_PATH_MAX_BYTES" ] || return 1
    [[ $path == /* ]] && [ "$path" != / ] || return 1
    ! [[ $path =~ [[:cntrl:]] ]] || return 1
    rest=${path#/}
    while :; do
        component=${rest%%/*}
        [ -n "$component" ] && [ "$component" != . ] && [ "$component" != .. ] || return 1
        [ "$component" = "$rest" ] && break
        rest=${rest#*/}
    done
}

_service_enablement_get_path() {
    local output_name=$1 function_name=$2 value
    shift 2
    value=$("$function_name" "$@") || {
        _service_enablement_fail "path provider failed: $function_name"
        return 1
    }
    _service_enablement_validate_absolute_path "$value" || {
        _service_enablement_fail "path provider returned an unsafe path: $function_name"
        return 1
    }
    printf -v "$output_name" '%s' "${value%/}"
}

_service_enablement_prepare_paths() {
    local manager=$1 service=$2
    unset _SERVICE_ENABLEMENT_ROOT_A _SERVICE_ENABLEMENT_ROOT_B _SERVICE_ENABLEMENT_RUNIT_LINK
    case $manager in
    systemd)
        _service_enablement_get_path _SERVICE_ENABLEMENT_ROOT_A \
            service_enablement_systemd_persistent_root || return 1
        _service_enablement_get_path _SERVICE_ENABLEMENT_ROOT_B \
            service_enablement_systemd_runtime_root || return 1
        [ "$_SERVICE_ENABLEMENT_ROOT_A" != "$_SERVICE_ENABLEMENT_ROOT_B" ] || {
            _service_enablement_fail 'systemd persistent and runtime roots must differ'
            return 1
        }
        ;;
    sysvinit)
        _service_enablement_get_path _SERVICE_ENABLEMENT_ROOT_A \
            service_enablement_sysv_root || return 1
        ;;
    openrc)
        _service_enablement_get_path _SERVICE_ENABLEMENT_ROOT_A \
            service_enablement_openrc_root || return 1
        ;;
    runit)
        _service_enablement_get_path _SERVICE_ENABLEMENT_RUNIT_LINK \
            service_enablement_runit_link "$service" || return 1
        [ "${_SERVICE_ENABLEMENT_RUNIT_LINK##*/}" = "$service" ] || {
            _service_enablement_fail 'runit enable link must end with the service name'
            return 1
        }
        ;;
    esac
}

_service_enablement_hex_encode() {
    (set -o pipefail
        LC_ALL=C printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n')
}

_service_enablement_hex_validate() {
    local hex=$1 max_bytes=$2 index byte
    [ -n "$hex" ] && [ $((${#hex} % 2)) -eq 0 ] &&
        [ $((${#hex} / 2)) -le "$max_bytes" ] || return 1
    [[ $hex =~ ^[0-9a-f]+$ ]] || return 1
    for ((index = 0; index < ${#hex}; index += 2)); do
        byte=${hex:index:2}
        [ "$byte" != 00 ] || return 1
    done
}

_service_enablement_hex_decode() {
    local hex=$1 output_name=$2 escaped='' index
    for ((index = 0; index < ${#hex}; index += 2)); do
        escaped+="\\x${hex:index:2}"
    done
    printf -v "$output_name" '%b' "$escaped"
}

_service_enablement_readlink_hex() {
    local path=$1 hex
    hex=$(set -o pipefail
        readlink -n -- "$path" | od -An -v -tx1 | tr -d ' \n') || return 1
    _service_enablement_hex_validate "$hex" "$SERVICE_ENABLEMENT_TARGET_MAX_BYTES" || return 1
    printf '%s\n' "$hex"
}

_service_enablement_systemd_parent_allowed() {
    local name=$1 stem
    case $name in
    *.wants) stem=${name%.wants} ;;
    *.requires) stem=${name%.requires} ;;
    *.upholds) stem=${name%.upholds} ;;
    *) return 1 ;;
    esac
    [[ $stem =~ ^[A-Za-z0-9][A-Za-z0-9_.@:-]{0,255}$ ]]
}

_service_enablement_path_allowed() {
    local manager=$1 service=$2 path=$3 root relative parent leaf prefix
    case $manager in
    systemd)
        for root in "$_SERVICE_ENABLEMENT_ROOT_A" "$_SERVICE_ENABLEMENT_ROOT_B"; do
            [[ $path == "$root/"* ]] || continue
            relative=${path#"$root/"}
            [[ $relative == */* ]] || return 1
            parent=${relative%/*}
            leaf=${relative##*/}
            [[ $parent != */* ]] && [ "$leaf" = "$service.service" ] &&
                _service_enablement_systemd_parent_allowed "$parent"
            return
        done
        return 1
        ;;
    sysvinit)
        [[ $path == "$_SERVICE_ENABLEMENT_ROOT_A/"* ]] || return 1
        relative=${path#"$_SERVICE_ENABLEMENT_ROOT_A/"}
        if [[ $relative == rc.d/* ]]; then
            relative=${relative#rc.d/}
        fi
        [[ $relative == */* ]] || return 1
        parent=${relative%/*}
        leaf=${relative##*/}
        [[ $parent != */* ]] && [[ $parent =~ ^rc[A-Za-z0-9_.-]+\.d$ ]] || return 1
        [ "${#leaf}" -eq $((${#service} + 3)) ] || return 1
        prefix=${leaf:0:3}
        [[ $prefix =~ ^[SK][0-9][0-9]$ ]] && [ "${leaf:3}" = "$service" ]
        ;;
    openrc)
        [[ $path == "$_SERVICE_ENABLEMENT_ROOT_A/"* ]] || return 1
        relative=${path#"$_SERVICE_ENABLEMENT_ROOT_A/"}
        [[ $relative == */* ]] || return 1
        parent=${relative%/*}
        leaf=${relative##*/}
        [[ $parent != */* ]] && [[ $parent =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]] &&
            [ "$leaf" = "$service" ]
        ;;
    runit)
        [ "$path" = "$_SERVICE_ENABLEMENT_RUNIT_LINK" ]
        ;;
    esac
}

_service_enablement_scan_add() {
    local manager=$1 service=$2 path=$3 path_hex target_hex
    _service_enablement_path_allowed "$manager" "$service" "$path" || {
        _service_enablement_fail "enablement path escaped its whitelist: $path"
        return 1
    }
    [ -L "$path" ] || {
        _service_enablement_fail "enablement entry is not a symlink: $path"
        return 1
    }
    path_hex=$(_service_enablement_hex_encode "$path") || return 1
    target_hex=$(_service_enablement_readlink_hex "$path") || {
        _service_enablement_fail "cannot read enablement symlink: $path"
        return 1
    }
    _SERVICE_ENABLEMENT_SCAN_RECORDS+=("${path_hex}:${target_hex}")
    [ "${#_SERVICE_ENABLEMENT_SCAN_RECORDS[@]}" -le "$SERVICE_ENABLEMENT_MANIFEST_MAX_RECORDS" ] || {
        _service_enablement_fail 'enablement snapshot contains too many links'
        return 1
    }
}

_service_enablement_scan_candidate() {
    local manager=$1 service=$2 path=$3
    if [ -L "$path" ]; then
        _service_enablement_scan_add "$manager" "$service" "$path"
    elif [ -e "$path" ]; then
        _service_enablement_fail "refusing non-symlink enablement entry: $path"
    fi
}

_service_enablement_scan_systemd_root() {
    local service=$1 root=$2 parent candidate name
    if [ -L "$root" ] || { [ -e "$root" ] && [ ! -d "$root" ]; }; then
        _service_enablement_fail "unsafe systemd root: $root"
        return 1
    fi
    [ -d "$root" ] || return 0
    for parent in "$root"/*.wants "$root"/*.requires "$root"/*.upholds; do
        [ -e "$parent" ] || [ -L "$parent" ] || continue
        name=${parent##*/}
        _service_enablement_systemd_parent_allowed "$name" || continue
        if [ -L "$parent" ] || [ ! -d "$parent" ]; then
            _service_enablement_fail "unsafe systemd enablement directory: $parent"
            return 1
        fi
        candidate="$parent/$service.service"
        _service_enablement_scan_candidate systemd "$service" "$candidate" || return 1
    done
}

_service_enablement_scan_sysv_runlevels() {
    local service=$1 root=$2 directory candidate name resolved canonical
    if [ -L "$root" ] || { [ -e "$root" ] && [ ! -d "$root" ]; }; then
        _service_enablement_fail "unsafe SysV runlevels root: $root"
        return 1
    fi
    [ -d "$root" ] || return 0
    for directory in "$root"/rc*.d; do
        [ -e "$directory" ] || [ -L "$directory" ] || continue
        name=${directory##*/}
        [[ $name =~ ^rc[A-Za-z0-9_.-]+\.d$ ]] || continue
        if [ -L "$directory" ]; then
            if [ "$root" = "$_SERVICE_ENABLEMENT_ROOT_A" ]; then
                resolved=$(readlink -e -- "$directory") || resolved=
                canonical=$(readlink -e -- "$root/rc.d/$name") || canonical=
                if [ -n "$resolved" ] && [ "$resolved" = "$canonical" ]; then
                    continue
                fi
            fi
            _service_enablement_fail "unsafe SysV runlevel directory: $directory"
            return 1
        fi
        if [ ! -d "$directory" ]; then
            _service_enablement_fail "unsafe SysV runlevel directory: $directory"
            return 1
        fi
        for candidate in "$directory"/S[0-9][0-9]"$service" \
            "$directory"/K[0-9][0-9]"$service"; do
            [ -e "$candidate" ] || [ -L "$candidate" ] || continue
            _service_enablement_scan_candidate sysvinit "$service" "$candidate" || return 1
        done
    done
}

_service_enablement_scan_sysvinit() {
    local service=$1 root=$_SERVICE_ENABLEMENT_ROOT_A
    if [ -L "$root" ] || [ ! -d "$root" ]; then
        _service_enablement_fail "unsafe SysV root: $root"
        return 1
    fi
    _service_enablement_scan_sysv_runlevels "$service" "$root" || return 1
    _service_enablement_scan_sysv_runlevels "$service" "$root/rc.d"
}

_service_enablement_scan_openrc() {
    local service=$1 root=$_SERVICE_ENABLEMENT_ROOT_A directory candidate name
    if [ -L "$root" ] || [ ! -d "$root" ]; then
        _service_enablement_fail "unsafe OpenRC runlevels root: $root"
        return 1
    fi
    for directory in "$root"/*; do
        [ -e "$directory" ] || [ -L "$directory" ] || continue
        name=${directory##*/}
        [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]] || continue
        if [ -L "$directory" ] || [ ! -d "$directory" ]; then
            _service_enablement_fail "unsafe OpenRC runlevel directory: $directory"
            return 1
        fi
        candidate="$directory/$service"
        _service_enablement_scan_candidate openrc "$service" "$candidate" || return 1
    done
}

_service_enablement_sort_scan() {
    local -a sorted=()
    if [ "${#_SERVICE_ENABLEMENT_SCAN_RECORDS[@]}" -gt 0 ]; then
        mapfile -t sorted < <(printf '%s\n' "${_SERVICE_ENABLEMENT_SCAN_RECORDS[@]}" | LC_ALL=C sort)
    fi
    _SERVICE_ENABLEMENT_SCAN_RECORDS=("${sorted[@]}")
}

_service_enablement_systemd_state_valid() {
    case $1 in
    enabled | enabled-runtime | linked | linked-runtime | alias | masked | masked-runtime | \
        static | indirect | generated | transient | disabled | not-found) return 0 ;;
    *) return 1 ;;
    esac
}

_service_enablement_query_systemd_state() {
    local service=$1 state rc=0
    state=$(service_enablement_systemd_state "$service") || rc=$?
    if [ -z "$state" ] || ! _service_enablement_systemd_state_valid "$state"; then
        _service_enablement_fail "invalid systemd enablement state (status $rc): ${state:-empty}"
        return 1
    fi
    printf '%s\n' "$state"
}

_service_enablement_scan() {
    local manager=$1 service=$2 record path_hex path state enabled=0
    _SERVICE_ENABLEMENT_SCAN_RECORDS=()
    case $manager in
    systemd)
        _service_enablement_scan_systemd_root "$service" "$_SERVICE_ENABLEMENT_ROOT_A" || return 1
        _service_enablement_scan_systemd_root "$service" "$_SERVICE_ENABLEMENT_ROOT_B" || return 1
        state=$(_service_enablement_query_systemd_state "$service") || {
            _service_enablement_fail "cannot determine systemd enablement state for $service.service"
            return 1
        }
        ;;
    sysvinit)
        _service_enablement_scan_sysvinit "$service" || return 1
        for record in "${_SERVICE_ENABLEMENT_SCAN_RECORDS[@]}"; do
            path_hex=${record%%:*}
            _service_enablement_hex_decode "$path_hex" path
            [[ ${path##*/} == S* ]] && enabled=1
        done
        if [ "$enabled" -eq 1 ]; then state=enabled; else state=disabled; fi
        ;;
    openrc)
        _service_enablement_scan_openrc "$service" || return 1
        if [ "${#_SERVICE_ENABLEMENT_SCAN_RECORDS[@]}" -gt 0 ]; then state=enabled; else state=disabled; fi
        ;;
    runit)
        _service_enablement_scan_candidate runit "$service" "$_SERVICE_ENABLEMENT_RUNIT_LINK" || return 1
        if [ "${#_SERVICE_ENABLEMENT_SCAN_RECORDS[@]}" -gt 0 ]; then state=enabled; else state=disabled; fi
        ;;
    esac
    _service_enablement_sort_scan
    SERVICE_ENABLEMENT_STATE=$state
}

_service_enablement_links_equal() {
    local left_name=$1 right_name=$2 index
    local -n left=$left_name right=$right_name
    [ "${#left[@]}" -eq "${#right[@]}" ] || return 1
    for ((index = 0; index < ${#left[@]}; index++)); do
        [ "${left[index]}" = "${right[index]}" ] || return 1
    done
}

_service_enablement_records_equal() {
    local left_name=$1 right_name=$2 left_state=$3 right_state=$4
    [ "$left_state" = "$right_state" ] &&
        _service_enablement_links_equal "$left_name" "$right_name"
}

_service_enablement_manifest_secure() {
    local manifest=$1 owner mode size lines
    if [ ! -f "$manifest" ] || [ -L "$manifest" ]; then
        _service_enablement_fail "manifest is not a regular file: $manifest"
        return 1
    fi
    owner=$(stat -c %u -- "$manifest" 2>/dev/null) || return 1
    mode=$(stat -c %a -- "$manifest" 2>/dev/null) || return 1
    size=$(wc -c <"$manifest") || return 1
    lines=$(wc -l <"$manifest") || return 1
    if [ "$owner" -ne "$(id -u)" ] || [ $((8#$mode & 0022)) -ne 0 ]; then
        _service_enablement_fail "manifest permissions are unsafe: $manifest"
        return 1
    fi
    if [ "$size" -gt "$SERVICE_ENABLEMENT_MANIFEST_MAX_BYTES" ] || [ "$lines" -ne 5 ]; then
        _service_enablement_fail "manifest has an invalid size or line count: $manifest"
        return 1
    fi
}

_service_enablement_manifest_load() {
    local manager=$1 service=$2 manifest=$3 links record path_hex target_hex path target
    local previous='' expected_service state
    local LC_ALL=C
    local -a lines=() records=()
    _service_enablement_manifest_secure "$manifest" || return 1
    mapfile -t lines <"$manifest" || return 1
    if [ "${#lines[@]}" -ne 5 ] ||
        [ "${lines[0]}" != 'format=clashctl-service-enablement-v1' ] ||
        [ "${lines[1]}" != "manager=$manager" ]; then
        _service_enablement_fail "manifest header is invalid: $manifest"
        return 1
    fi
    expected_service=$(_service_enablement_hex_encode "$service") || return 1
    [ "${lines[2]}" = "service=$expected_service" ] || {
        _service_enablement_fail 'manifest belongs to a different service'
        return 1
    }
    if [[ ${lines[3]} != state=* ]] || [[ ${lines[4]} != links=* ]]; then
        _service_enablement_fail 'manifest fields are invalid'
        return 1
    fi
    state=${lines[3]#state=}
    links=${lines[4]#links=}
    case $manager in
    systemd) _service_enablement_systemd_state_valid "$state" || {
        _service_enablement_fail "manifest contains an invalid systemd state: $state"; return 1; } ;;
    *) case $state in enabled | disabled) ;; *)
        _service_enablement_fail "manifest contains an invalid enablement state: $state"; return 1 ;;
        esac ;;
    esac
    if [ -n "$links" ]; then
        IFS=, read -r -a records <<<"$links"
        [[ $links != ,* && $links != *, && $links != *,,* ]] || {
            _service_enablement_fail 'manifest link list is not canonical'
            return 1
        }
    fi
    [ "${#records[@]}" -le "$SERVICE_ENABLEMENT_MANIFEST_MAX_RECORDS" ] || {
        _service_enablement_fail 'manifest contains too many links'
        return 1
    }
    _SERVICE_ENABLEMENT_MANIFEST_RECORDS=()
    for record in "${records[@]}"; do
        if [[ $record != *:* ]] || [[ ${record#*:} == *:* ]]; then
            _service_enablement_fail 'manifest link record is malformed'
            return 1
        fi
        path_hex=${record%%:*}
        target_hex=${record#*:}
        if ! _service_enablement_hex_validate "$path_hex" "$SERVICE_ENABLEMENT_PATH_MAX_BYTES" ||
            ! _service_enablement_hex_validate "$target_hex" "$SERVICE_ENABLEMENT_TARGET_MAX_BYTES"; then
            _service_enablement_fail 'manifest contains invalid or oversized hex data'
            return 1
        fi
        [ -z "$previous" ] || [[ $previous < $path_hex ]] || {
            _service_enablement_fail 'manifest links are not uniquely sorted by path'
            return 1
        }
        previous=$path_hex
        _service_enablement_hex_decode "$path_hex" path
        _service_enablement_hex_decode "$target_hex" target
        _service_enablement_path_allowed "$manager" "$service" "$path" || {
            _service_enablement_fail "manifest path escaped its whitelist: $path"
            return 1
        }
        [ -n "$target" ] || {
            _service_enablement_fail "manifest contains an empty symlink target: $path"
            return 1
        }
        _SERVICE_ENABLEMENT_MANIFEST_RECORDS+=("$record")
    done
    if [ "$manager" != systemd ]; then
        local derived=disabled
        case $manager in
        sysvinit)
            for record in "${_SERVICE_ENABLEMENT_MANIFEST_RECORDS[@]}"; do
                path_hex=${record%%:*}
                _service_enablement_hex_decode "$path_hex" path
                [[ ${path##*/} == S* ]] && derived=enabled
            done
            ;;
        openrc | runit)
            [ "${#_SERVICE_ENABLEMENT_MANIFEST_RECORDS[@]}" -eq 0 ] || derived=enabled
            ;;
        esac
        [ "$derived" = "$state" ] || {
            _service_enablement_fail 'manifest state disagrees with its links'
            return 1
        }
    fi
    SERVICE_ENABLEMENT_STATE=$state
    SERVICE_ENABLEMENT_LINKS=$links
}

_service_enablement_manifest_write() {
    local manager=$1 service=$2 state=$3 manifest=$4 directory tmp links='' service_hex record
    directory=${manifest%/*}
    [ "$directory" != "$manifest" ] || directory=.
    if [ -L "$directory" ] || [ ! -d "$directory" ]; then
        _service_enablement_fail "unsafe manifest directory: $directory"
        return 1
    fi
    if [ -e "$manifest" ] || [ -L "$manifest" ]; then
        if [ ! -f "$manifest" ] || [ -L "$manifest" ]; then
            _service_enablement_fail "refusing to replace non-regular manifest: $manifest"
            return 1
        fi
    fi
    service_hex=$(_service_enablement_hex_encode "$service") || return 1
    for record in "${_SERVICE_ENABLEMENT_SCAN_RECORDS[@]}"; do
        if [ -n "$links" ]; then links+=","; fi
        links+=$record
    done
    tmp=$(mktemp "${manifest}.clashctl-new.XXXXXX") || return 1
    chmod 0600 -- "$tmp" || { /usr/bin/rm -f -- "$tmp"; return 1; }
    if ! printf '%s\n' \
        'format=clashctl-service-enablement-v1' \
        "manager=$manager" \
        "service=$service_hex" \
        "state=$state" \
        "links=$links" >"$tmp"; then
        /usr/bin/rm -f -- "$tmp"
        return 1
    fi
    if [ "$(wc -c <"$tmp")" -gt "$SERVICE_ENABLEMENT_MANIFEST_MAX_BYTES" ]; then
        /usr/bin/rm -f -- "$tmp"
        _service_enablement_fail 'enablement manifest exceeds its size limit'
        return 1
    fi
    if [ -f "$manifest" ] && [ ! -L "$manifest" ] && cmp -s -- "$tmp" "$manifest"; then
        /usr/bin/rm -f -- "$tmp"
        return 0
    fi
    /bin/mv -fT -- "$tmp" "$manifest" || {
        /usr/bin/rm -f -- "$tmp"
        return 1
    }
}

service_enablement_capture() {
    local manager=${1:-} service=${2:-} manifest=${3:-}
    local first_state links='' record
    local -a first_records=()
    SERVICE_ENABLEMENT_ERROR=
    SERVICE_ENABLEMENT_STATE=
    SERVICE_ENABLEMENT_LINKS=
    if [ $# -ne 3 ] || [ -z "$manifest" ]; then
        _service_enablement_fail 'capture requires MANAGER SERVICE MANIFEST'
        return 1
    fi
    _service_enablement_validate_args "$manager" "$service" || return 1
    _service_enablement_prepare_paths "$manager" "$service" || return 1
    _service_enablement_scan "$manager" "$service" || return 1
    first_state=$SERVICE_ENABLEMENT_STATE
    first_records=("${_SERVICE_ENABLEMENT_SCAN_RECORDS[@]}")
    _service_enablement_scan "$manager" "$service" || return 1
    _service_enablement_records_equal first_records _SERVICE_ENABLEMENT_SCAN_RECORDS \
        "$first_state" "$SERVICE_ENABLEMENT_STATE" || {
        _service_enablement_fail 'enablement changed while it was being captured'
        return 1
    }
    _service_enablement_manifest_write "$manager" "$service" "$SERVICE_ENABLEMENT_STATE" "$manifest" ||
        return 1
    for record in "${_SERVICE_ENABLEMENT_SCAN_RECORDS[@]}"; do
        [ -z "$links" ] || links+=,
        links+=$record
    done
    SERVICE_ENABLEMENT_LINKS=$links
}

service_enablement_validate() {
    local manager=${1:-} service=${2:-} manifest=${3:-}
    SERVICE_ENABLEMENT_ERROR=
    SERVICE_ENABLEMENT_STATE=
    SERVICE_ENABLEMENT_LINKS=
    [ $# -eq 3 ] || {
        _service_enablement_fail 'validate requires MANAGER SERVICE MANIFEST'
        return 1
    }
    _service_enablement_validate_args "$manager" "$service" || return 1
    _service_enablement_prepare_paths "$manager" "$service" || return 1
    _service_enablement_manifest_load "$manager" "$service" "$manifest"
}

service_enablement_reconcile() {
    local manager=${1:-} service=${2:-} manifest=${3:-} desired_state
    local -a desired_records=()
    SERVICE_ENABLEMENT_ERROR=
    SERVICE_ENABLEMENT_STATE=
    SERVICE_ENABLEMENT_LINKS=
    [ $# -eq 3 ] || {
        _service_enablement_fail 'reconcile requires MANAGER SERVICE MANIFEST'
        return 1
    }
    _service_enablement_validate_args "$manager" "$service" || return 1
    _service_enablement_prepare_paths "$manager" "$service" || return 1
    _service_enablement_manifest_load "$manager" "$service" "$manifest" || return 1
    desired_state=$SERVICE_ENABLEMENT_STATE
    desired_records=("${_SERVICE_ENABLEMENT_MANIFEST_RECORDS[@]}")
    _service_enablement_scan "$manager" "$service" || return 1
    _service_enablement_records_equal desired_records _SERVICE_ENABLEMENT_SCAN_RECORDS \
        "$desired_state" "$SERVICE_ENABLEMENT_STATE" || {
        _service_enablement_fail 'current enablement does not match the manifest'
        return 1
    }
}

_service_enablement_record_find() {
    local records_name=$1 wanted_path_hex=$2 output_name=$3 record
    local -n records=$records_name
    for record in "${records[@]}"; do
        if [ "${record%%:*}" = "$wanted_path_hex" ]; then
            printf -v "$output_name" '%s' "${record#*:}"
            return 0
        fi
    done
    return 1
}

_service_enablement_resolve_link_target() {
    local path=$1 target=$2 output_name=$3 combined normalized
    if [[ $target == /* ]]; then combined=$target; else combined="${path%/*}/$target"; fi
    normalized=$(readlink -m -- "$combined") || return 1
    printf -v "$output_name" '%s' "$normalized"
}

_service_enablement_current_target_owned() {
    local manager=$1 service=$2 path_hex=$3 target_hex=$4 path target expected resolved actual
    _service_enablement_hex_decode "$path_hex" path
    _service_enablement_hex_decode "$target_hex" target
    case $manager in
    systemd) expected=$(service_enablement_systemd_unit_path "$service") || return 1 ;;
    sysvinit) expected=$(service_enablement_sysv_service_path "$service") || return 1 ;;
    openrc) expected=$(service_enablement_openrc_service_path "$service") || return 1 ;;
    runit) expected=$(service_enablement_runit_service_path "$service") || return 1 ;;
    esac
    _service_enablement_validate_absolute_path "$expected" || return 1
    actual=$(readlink -m -- "$expected") || return 1
    _service_enablement_resolve_link_target "$path" "$target" resolved || return 1
    [ "$resolved" = "$actual" ]
}

_service_enablement_preflight_removals() {
    local manager=$1 service=$2 current_name=$3 desired_name=$4 expected_name=${5:-}
    local record path_hex current_target desired_target expected_target
    local -n current=$current_name
    for record in "${current[@]}"; do
        path_hex=${record%%:*}
        current_target=${record#*:}
        desired_target=
        if _service_enablement_record_find "$desired_name" "$path_hex" desired_target &&
            [ "$desired_target" = "$current_target" ]; then
            continue
        fi
        expected_target=
        if [ -n "$expected_name" ] &&
            _service_enablement_record_find "$expected_name" "$path_hex" expected_target &&
            [ "$expected_target" = "$current_target" ]; then
            continue
        fi
        if [ -n "$expected_name" ]; then
            _service_enablement_hex_decode "$path_hex" path
            _service_enablement_fail "current link matches neither snapshot: $path"
            return 1
        fi
        _service_enablement_current_target_owned \
            "$manager" "$service" "$path_hex" "$current_target" || {
            _service_enablement_hex_decode "$path_hex" path
            _service_enablement_fail "refusing to remove an unknown enablement link: $path"
            return 1
        }
    done
}

_service_enablement_preflight_desired() {
    local desired_name=$1 record path_hex target_hex path current_hex
    local -n desired=$desired_name
    for record in "${desired[@]}"; do
        path_hex=${record%%:*}
        target_hex=${record#*:}
        _service_enablement_hex_decode "$path_hex" path
        if [ -L "$path" ]; then
            current_hex=$(_service_enablement_readlink_hex "$path") || return 1
            [ "$current_hex" = "$target_hex" ] || continue
        elif [ -e "$path" ]; then
            _service_enablement_fail "refusing to overwrite a non-symlink: $path"
            return 1
        fi
    done
}

_service_enablement_parent_safe() {
    local manager=$1 path=$2 parent
    parent=${path%/*}
    if [ -L "$parent" ]; then return 1; fi
    if [ -d "$parent" ]; then return 0; fi
    [ "$manager" = systemd ] || return 1
    case $parent in
    "$_SERVICE_ENABLEMENT_ROOT_A"/*.wants | "$_SERVICE_ENABLEMENT_ROOT_A"/*.requires | \
        "$_SERVICE_ENABLEMENT_ROOT_A"/*.upholds | "$_SERVICE_ENABLEMENT_ROOT_B"/*.wants | \
        "$_SERVICE_ENABLEMENT_ROOT_B"/*.requires | "$_SERVICE_ENABLEMENT_ROOT_B"/*.upholds)
        /usr/bin/install -d -m 0755 -- "$parent" || return 1
        [ -d "$parent" ] && [ ! -L "$parent" ]
        ;;
    *) return 1 ;;
    esac
}

_service_enablement_remove_record() {
    local record=$1 path_hex target_hex path current_hex
    path_hex=${record%%:*}
    target_hex=${record#*:}
    _service_enablement_hex_decode "$path_hex" path
    [ -L "$path" ] || return 1
    current_hex=$(_service_enablement_readlink_hex "$path") || return 1
    [ "$current_hex" = "$target_hex" ] || return 1
    /usr/bin/rm -f -- "$path" || return 1
    [ ! -e "$path" ] && [ ! -L "$path" ]
}

_service_enablement_create_record() {
    local manager=$1 record=$2 path_hex target_hex path target
    path_hex=${record%%:*}
    target_hex=${record#*:}
    _service_enablement_hex_decode "$path_hex" path
    _service_enablement_hex_decode "$target_hex" target
    [ ! -e "$path" ] && [ ! -L "$path" ] || return 1
    _service_enablement_parent_safe "$manager" "$path" || return 1
    ln -s -- "$target" "$path"
}

_service_enablement_apply_records() {
    local manager=$1 current_name=$2 desired_name=$3 record path_hex current_target desired_target changed=0
    local -n current=$current_name desired=$desired_name
    for record in "${current[@]}"; do
        path_hex=${record%%:*}
        current_target=${record#*:}
        desired_target=
        if _service_enablement_record_find "$desired_name" "$path_hex" desired_target &&
            [ "$desired_target" = "$current_target" ]; then
            continue
        fi
        _service_enablement_remove_record "$record" || return 1
        changed=1
    done
    for record in "${desired[@]}"; do
        path_hex=${record%%:*}
        desired_target=${record#*:}
        current_target=
        if _service_enablement_record_find "$current_name" "$path_hex" current_target &&
            [ "$current_target" = "$desired_target" ]; then
            continue
        fi
        _service_enablement_create_record "$manager" "$record" || return 1
        changed=1
    done
    _SERVICE_ENABLEMENT_APPLY_CHANGED=$changed
}

_service_enablement_prepare_restore() {
    local manager=${1:-} service=${2:-} manifest=${3:-} expected_manifest=${4:-}
    local desired_state expected_state='' current_state expected_name=''
    local expected_present=0 snapshot_matches=0
    local -a desired_records=() expected_records=() current_records=()

    _service_enablement_manifest_load "$manager" "$service" "$manifest" || return 1
    desired_state=$SERVICE_ENABLEMENT_STATE
    desired_records=("${_SERVICE_ENABLEMENT_MANIFEST_RECORDS[@]}")
    if [ -n "$expected_manifest" ]; then
        _service_enablement_manifest_load "$manager" "$service" "$expected_manifest" || return 1
        expected_state=$SERVICE_ENABLEMENT_STATE
        expected_records=("${_SERVICE_ENABLEMENT_MANIFEST_RECORDS[@]}")
        expected_present=1
        expected_name=expected_records
    fi
    _service_enablement_scan "$manager" "$service" || return 1
    current_state=$SERVICE_ENABLEMENT_STATE
    current_records=("${_SERVICE_ENABLEMENT_SCAN_RECORDS[@]}")
    if [ "$expected_present" -eq 1 ]; then
        if _service_enablement_records_equal current_records desired_records \
            "$current_state" "$desired_state" ||
            _service_enablement_records_equal current_records expected_records \
                "$current_state" "$expected_state"; then
            snapshot_matches=1
        fi
        # Restoring a systemd definition can change is-enabled's state label
        # before its enablement links are restored. The links must still match
        # the complete takeover snapshot. No other cross-combination is safe.
        if [ "$snapshot_matches" -eq 0 ] && [ "$manager" = systemd ] &&
            [ "$current_state" = "$desired_state" ] &&
            _service_enablement_links_equal current_records expected_records; then
            snapshot_matches=1
        fi
        if [ "$snapshot_matches" -eq 0 ]; then
            _service_enablement_fail \
                'current enablement does not exactly match either snapshot'
            return 1
        fi
    fi
    _service_enablement_preflight_removals "$manager" "$service" current_records \
        desired_records "$expected_name" || return 1
    _service_enablement_preflight_desired desired_records || return 1

    _SERVICE_ENABLEMENT_RESTORE_DESIRED_STATE=$desired_state
    _SERVICE_ENABLEMENT_RESTORE_CURRENT_STATE=$current_state
    _SERVICE_ENABLEMENT_RESTORE_DESIRED_RECORDS=("${desired_records[@]}")
    _SERVICE_ENABLEMENT_RESTORE_CURRENT_RECORDS=("${current_records[@]}")
}

service_enablement_preflight_restore() {
    local manager=${1:-} service=${2:-} manifest=${3:-} expected_manifest=${4:-}
    SERVICE_ENABLEMENT_ERROR=
    SERVICE_ENABLEMENT_STATE=
    SERVICE_ENABLEMENT_LINKS=
    [ $# -eq 3 ] || [ $# -eq 4 ] || {
        _service_enablement_fail \
            'preflight restore requires MANAGER SERVICE MANIFEST [EXPECTED_CURRENT_MANIFEST]'
        return 1
    }
    _service_enablement_validate_args "$manager" "$service" || return 1
    _service_enablement_prepare_paths "$manager" "$service" || return 1
    _service_enablement_prepare_restore "$manager" "$service" "$manifest" "$expected_manifest"
}

_service_enablement_rollback_records() {
    local manager=$1 service=$2 state=$3 records_name=$4 owned_name=$5
    local apply_rc=0 reload_rc=0
    local -a current_records=() restore_records=() owned_records=()
    local -n source_records=$records_name source_owned=$owned_name

    restore_records=("${source_records[@]}")
    owned_records=("${source_owned[@]}")
    _service_enablement_scan "$manager" "$service" >/dev/null 2>&1 || return 1
    current_records=("${_SERVICE_ENABLEMENT_SCAN_RECORDS[@]}")
    _service_enablement_preflight_removals "$manager" "$service" current_records \
        restore_records owned_records >/dev/null 2>&1 || return 1
    _service_enablement_preflight_desired restore_records >/dev/null 2>&1 || return 1
    _service_enablement_apply_records "$manager" current_records restore_records || apply_rc=$?
    if [ "$manager" = systemd ]; then
        service_enablement_systemd_reload >/dev/null 2>&1 || reload_rc=$?
    fi
    [ "$apply_rc" -eq 0 ] && [ "$reload_rc" -eq 0 ] || return 1
    _service_enablement_scan "$manager" "$service" >/dev/null 2>&1 || return 1
    _service_enablement_records_equal restore_records _SERVICE_ENABLEMENT_SCAN_RECORDS \
        "$state" "$SERVICE_ENABLEMENT_STATE"
}

service_enablement_restore() {
    local manager=${1:-} service=${2:-} manifest=${3:-} expected_manifest=${4:-}
    local desired_state current_state before_hook_state apply_rc=0 failure
    local -a desired_records=() current_records=() before_hook_records=()
    SERVICE_ENABLEMENT_ERROR=
    SERVICE_ENABLEMENT_STATE=
    SERVICE_ENABLEMENT_LINKS=
    [ $# -eq 3 ] || [ $# -eq 4 ] || {
        _service_enablement_fail \
            'restore requires MANAGER SERVICE MANIFEST [EXPECTED_CURRENT_MANIFEST]'
        return 1
    }
    if [ $# -eq 4 ]; then
        service_enablement_preflight_restore \
            "$manager" "$service" "$manifest" "$expected_manifest" || return 1
    else
        service_enablement_preflight_restore "$manager" "$service" "$manifest" || return 1
    fi
    desired_state=$_SERVICE_ENABLEMENT_RESTORE_DESIRED_STATE
    current_state=$_SERVICE_ENABLEMENT_RESTORE_CURRENT_STATE
    desired_records=("${_SERVICE_ENABLEMENT_RESTORE_DESIRED_RECORDS[@]}")
    current_records=("${_SERVICE_ENABLEMENT_RESTORE_CURRENT_RECORDS[@]}")
    before_hook_state=$current_state
    before_hook_records=("${current_records[@]}")
    _service_enablement_before_restore_commit || {
        _service_enablement_fail 'restore commit hook failed'
        return 1
    }
    _service_enablement_scan "$manager" "$service" || return 1
    _service_enablement_records_equal before_hook_records _SERVICE_ENABLEMENT_SCAN_RECORDS \
        "$before_hook_state" "$SERVICE_ENABLEMENT_STATE" || {
        _service_enablement_fail 'enablement changed before restore commit'
        return 1
    }
    current_records=("${_SERVICE_ENABLEMENT_SCAN_RECORDS[@]}")
    _service_enablement_apply_records "$manager" current_records desired_records || apply_rc=$?
    if [ "$apply_rc" -ne 0 ]; then
        failure=${SERVICE_ENABLEMENT_ERROR:-'failed to apply enablement manifest'}
        if _service_enablement_rollback_records \
            "$manager" "$service" "$before_hook_state" before_hook_records desired_records; then
            SERVICE_ENABLEMENT_ERROR="$failure; previous links were restored"
        else
            SERVICE_ENABLEMENT_ERROR="$failure; rollback was incomplete"
        fi
        return 1
    fi
    if [ "$manager" = systemd ] &&
        { [ "$_SERVICE_ENABLEMENT_APPLY_CHANGED" -eq 1 ] || [ "$current_state" != "$desired_state" ]; }; then
        service_enablement_systemd_reload || {
            if _service_enablement_rollback_records \
                "$manager" "$service" "$before_hook_state" before_hook_records desired_records; then
                _service_enablement_fail \
                    'systemd daemon-reload failed; previous enablement links were restored'
            else
                _service_enablement_fail \
                    'systemd daemon-reload failed and enablement rollback was incomplete'
            fi
            return 1
        }
    fi
    if ! service_enablement_reconcile "$manager" "$service" "$manifest"; then
        failure=${SERVICE_ENABLEMENT_ERROR:-'restored enablement could not be verified'}
        if _service_enablement_rollback_records \
            "$manager" "$service" "$before_hook_state" before_hook_records desired_records; then
            SERVICE_ENABLEMENT_ERROR="$failure; previous links were restored"
        else
            SERVICE_ENABLEMENT_ERROR="$failure; rollback was incomplete"
        fi
        return 1
    fi
}
