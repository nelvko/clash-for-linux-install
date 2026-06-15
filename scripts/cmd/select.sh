#!/usr/bin/env bash

_select_api_base() {
    if [ -n "$CLASH_SELECT_API_BASE" ]; then
        printf '%s\n' "$CLASH_SELECT_API_BASE"
        return 0
    fi

    _detect_ext_addr
    service_is_active >&/dev/null || service_start >/dev/null
    if ! service_is_active >&/dev/null; then
        _errorcat "无法启动服务，请检查日志"
        return 1
    fi

    CLASH_SELECT_API_BASE="http://${EXT_IP}:${EXT_PORT}"
    printf '%s\n' "$CLASH_SELECT_API_BASE"
}

_select_json_escape() {
    sed 's/\\/\\\\/g; s/"/\\"/g' <<<"$1"
}

_select_urlencode() {
    local value=$1 encoded= char hex
    local LC_ALL=C
    local i

    for ((i = 0; i < ${#value}; i++)); do
        char=${value:i:1}
        case "$char" in
        [a-zA-Z0-9.~_-])
            encoded+="$char"
            ;;
        *)
            printf -v hex '%%%02X' "'$char"
            encoded+="$hex"
            ;;
        esac
    done
    printf '%s\n' "$encoded"
}

_select_api() {
    local method=$1
    local path=$2
    local data=${3:-}
    local base
    base=$(_select_api_base) || return 1

    case "$method" in
    GET)
        curl --silent --show-error --fail --noproxy "*" \
            -H "Authorization: Bearer $(_get_secret)" \
            "${base}${path}"
        ;;
    PUT)
        curl --silent --show-error --fail --noproxy "*" \
            -X PUT \
            -H "Authorization: Bearer $(_get_secret)" \
            -H "Content-Type: application/json" \
            --data "$data" \
            "${base}${path}"
        ;;
    esac
}

_select_groups() {
    _select_api GET '/proxies' | "$BIN_YQ" -p=json -r '
      .proxies |
      to_entries |
      .[] |
      select(.value.all != null) |
      .key + "\t" + .value.type + "\t" + (.value.now // "")
    '
}

_select_group_names() {
    _select_groups | awk -F '\t' '{print $1}'
}

_select_node_names() {
    local group=$1
    if [ -z "$group" ]; then
        _errorcat "请指定策略组名称"
        return 1
    fi

    local path="/proxies/$(_select_urlencode "$group")"
    _select_api GET "$path" | "$BIN_YQ" -p=json -r '.all[]'
}

_select_node_delay() {
    local node=$1
    local delay_url=${CLASH_SELECT_DELAY_URL:-https://www.gstatic.com/generate_204}
    local timeout=${CLASH_SELECT_DELAY_TIMEOUT:-3000}
    local path="/proxies/$(_select_urlencode "$node")/delay?timeout=${timeout}&url=$(_select_urlencode "$delay_url")"
    local delay

    delay=$(_select_api GET "$path" | "$BIN_YQ" -p=json -r '.delay // ""' 2>/dev/null) || return 1
    [ -n "$delay" ] && printf '%sms\n' "$delay"
}

_select_node_rows() {
    local group=$1
    if [ -z "$group" ]; then
        _errorcat "请指定策略组名称"
        return 1
    fi

    local path="/proxies/$(_select_urlencode "$group")"
    local res now mark tmp_dir node delay
    local nodes=()
    res=$(_select_api GET "$path") || return 1
    now=$("$BIN_YQ" -p=json -r '.now // ""' <<<"$res")

    while IFS= read -r node; do
        [ -n "$node" ] && nodes+=("$node")
    done < <("$BIN_YQ" -p=json -r '.all[]' <<<"$res")

    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/clashselect.XXXXXX") || return 1

    local i
    for i in "${!nodes[@]}"; do
        (
            _select_node_delay "${nodes[$i]}" >"${tmp_dir}/${i}" 2>/dev/null ||
                printf 'timeout\n' >"${tmp_dir}/${i}"
        ) &
    done
    wait

    for i in "${!nodes[@]}"; do
        node=${nodes[$i]}
        mark=' '
        [ "$node" = "$now" ] && mark='*'
        delay=$(cat "${tmp_dir}/${i}" 2>/dev/null)
        [ -n "$delay" ] || delay=timeout
        printf '%s\t%-8s\t%s\n' "$mark" "$delay" "$node"
    done

    rm -rf -- "$tmp_dir"
}

_select_now() {
    local group=$1
    if [ -z "$group" ]; then
        _errorcat "请指定策略组名称"
        return 1
    fi

    local path="/proxies/$(_select_urlencode "$group")"
    _select_api GET "$path" | "$BIN_YQ" -p=json -r '.now'
}

_select_use() {
    local group=$1
    local node=$2
    if [ -z "$group" ]; then
        _errorcat "请指定策略组名称"
        return 1
    fi
    if [ -z "$node" ]; then
        _errorcat "请指定节点名称"
        return 1
    fi

    local path="/proxies/$(_select_urlencode "$group")"
    local body="{\"name\":\"$(_select_json_escape "$node")\"}"
    _select_api PUT "$path" "$body" >/dev/null || {
        _failcat "切换失败：请检查策略组或节点名称"
        return 1
    }
    _okcat "已切换：[$group] -> $node"
}

_select_pick() {
    local title=$1
    shift
    local items=("$@")
    local choice

    ((${#items[@]})) || return 1
    printf "\n%s\n" "$title"

    local i
    for i in "${!items[@]}"; do
        printf "  %2d) %s\n" "$((i + 1))" "${items[$i]}"
    done
    printf "  %2s) %s\n" q 退出
    printf "\n请输入序号："
    read -r choice

    case "$choice" in
    q | Q)
        return 1
        ;;
    '' | *[!0-9]*)
        _failcat "请输入有效序号"
        return 2
        ;;
    esac

    if [ "$choice" -lt 1 ] || [ "$choice" -gt "${#items[@]}" ]; then
        _failcat "序号超出范围"
        return 2
    fi
    SELECT_PICK_RESULT=${items[$((choice - 1))]}
}

_select_fzf() {
    command -v fzf >&/dev/null || return 1
    [ -t 0 ] || return 1

    local group_line group node_line node
    group_line=$(
        _select_groups | fzf \
            --height=80% \
            --layout=reverse \
            --border \
            --prompt='策略组 > ' \
            --header='选择策略组，输入可搜索，Enter 确认，Esc 退出'
    ) || return 130
    group=${group_line%%$'\t'*}
    [ -n "$group" ] || return 130

    node_line=$(
        _select_node_rows "$group" | fzf \
            --height=80% \
            --layout=reverse \
            --border \
            --prompt="${group} > " \
            --header='* 表示当前节点；第二列为实时延迟；Enter 切换，Esc 退出'
    ) || return 130
    node=${node_line#*$'\t'}
    node=${node#*$'\t'}
    [ -n "$node" ] || return 130

    _select_use "$group" "$node"
}

_select_interactive() {
    local groups=() nodes=()
    local line group node now

    _select_fzf
    case $? in
    0)
        return 0
        ;;
    130)
        return 130
        ;;
    esac

    while IFS= read -r line; do
        [ -n "$line" ] && groups+=("$line")
    done < <(_select_group_names)
    _select_pick "请选择策略组：" "${groups[@]}" || return $?
    group=$SELECT_PICK_RESULT
    now=$(_select_now "$group")

    while IFS= read -r line; do
        [ -n "$line" ] && nodes+=("$line")
    done < <(_select_node_rows "$group")
    _okcat "当前节点：$now"
    _select_pick "请选择 [$group] 的节点：" "${nodes[@]}" || return $?
    node=$SELECT_PICK_RESULT
    node=${node#*$'\t'}
    node=${node#*$'\t'}

    _select_use "$group" "$node"
}

clashselect() {
    case "$1" in
    -h | --help)
        cat <<EOF

- 查看可切换策略组
  clashselect ls

- 交互式切换策略组节点
  clashselect

- 查看策略组当前节点
  clashselect now <策略组>

- 查看策略组可选节点与实时延迟
  clashselect nodes <策略组>

- 切换策略组节点
  clashselect use <策略组> <节点>
  clashselect <策略组> <节点>

EOF
        return 0
        ;;
    '')
        _select_interactive
        ;;
    ls | list)
        _select_groups
        ;;
    nodes)
        shift
        _select_node_rows "$@"
        ;;
    now)
        shift
        _select_now "$@"
        ;;
    use)
        shift
        _select_use "$@"
        ;;
    *)
        _select_use "$@"
        ;;
    esac
}
