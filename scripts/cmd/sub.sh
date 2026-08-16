#!/usr/bin/env bash

# ── 术语约定 ──────────────────────────────────────────────────
#   name    订阅名称：用户可见/输入的唯一键，允许中文/emoji/空格
#   path    该订阅在磁盘上的配置文件路径（权威来源，文件名已安全化）
#   use     顶层字段，记录当前生效订阅的 name
#   _sub_   本文件模块前缀
# ─────────────────────────────────────────────────────────────

clashsub() {
    case "${1:-}" in
    -h | --help)
        sub_help
        return 0
        ;;
    esac

    _sub_migrate

    case "${1:-}" in
    add)
        shift
        sub_add "$@"
        ;;
    del | delete)
        shift
        _sub_del "$@"
        ;;
    list | ls)
        shift
        _sub_list "$@"
        ;;
    '')
        # 裸命令：交互终端直接进选择器（选中即切换），管道/脚本下输出表格
        if [ -t 0 ] && [ -t 1 ]; then
            _sub_use
        else
            _sub_list
        fi
        ;;
    use)
        shift
        _sub_use "$@"
        ;;
    update)
        shift
        _sub_update "$@"
        ;;
    rename)
        shift
        _sub_rename "$@"
        ;;
    log)
        shift
        _sub_log "$@"
        ;;
    *)
        sub_help
        ;;
    esac
}

########################################
#            元数据读取
########################################

# 订阅是否存在
_sub_has() {
    PROFILE_NAME=$1 "$BIN_YQ" -e '.profiles // [] | .[] | select(.name == strenv(PROFILE_NAME)) | .name' \
        "$CLASH_PROFILES_META" >/dev/null 2>&1
}

# 取某订阅的字段（field ∈ path|url|updated），不存在则输出空串
_sub_get() {
    PROFILE_NAME=$1 "$BIN_YQ" ".profiles // [] | .[] | select(.name == strenv(PROFILE_NAME)) | .$2 // \"\"" \
        "$CLASH_PROFILES_META" 2>/dev/null
}

# 逐行输出全部订阅名称（保持文件内顺序）
_sub_names() {
    "$BIN_YQ" '.profiles // [] | .[] | .name' "$CLASH_PROFILES_META" 2>/dev/null
}

# 一次性输出全部订阅字段（TSV：name<TAB>url<TAB>updated<TAB>userinfo，单次 yq）
_sub_rows() {
    "$BIN_YQ" '.profiles // [] | .[] | [.name, (.url // ""), (.updated // ""), (.userinfo // "")] | @tsv' \
        "$CLASH_PROFILES_META" 2>/dev/null
}

# 一次性载入全部订阅到全局并行数组（list/pick 共用，替代逐订阅×逐字段的 _sub_get）：
#   _SUB_NAMES/_SUB_URLS/_SUB_UPDS/_SUB_UIS   原始字段（顺序与文件一致）
#   _SUB_TRAFFICS/_SUB_EXPIRES                 由 userinfo 派生的展示列
#   _SUB_CUR                                   当前生效订阅名
# 只取数不渲染，展示形态由调用方决定。
_sub_load() {
    _SUB_NAMES=() _SUB_URLS=() _SUB_UPDS=() _SUB_UIS=()
    _SUB_TRAFFICS=() _SUB_EXPIRES=()
    _SUB_CUR=$(_sub_current)

    local name url upd ui tf ex
    while IFS=$'\t' read -r name url upd ui; do
        [ -z "$name" ] && continue
        _SUB_NAMES+=("$name")
        _SUB_URLS+=("$url")
        _SUB_UPDS+=("$upd")
        _SUB_UIS+=("$ui")
        IFS=$'\t' read -r tf ex < <(_userinfo_display "$ui")
        _SUB_TRAFFICS+=("$tf")
        _SUB_EXPIRES+=("$ex")
    done < <(_sub_rows)
}

# 当前生效订阅的 name
_sub_current() {
    "$BIN_YQ" '.use // "" | tostring' "$CLASH_PROFILES_META" 2>/dev/null
}

# url 是否已存在
_sub_url_exists() {
    PROFILE_URL=$1 "$BIN_YQ" -e '([.profiles // [] | .[] | select(.url == strenv(PROFILE_URL))] | length) > 0' \
        "$CLASH_PROFILES_META" >/dev/null 2>&1
}

_logging_sub() {
    printf '%s %s\n' "$(date +"%Y-%m-%d %H:%M:%S")" "$1" >>"$CLASH_PROFILES_LOG"
}

########################################
#            并发互斥
########################################
# 串行化所有订阅写操作（含 cron 自动更新）：交互与下载在锁外完成，
# 仅把“改元数据 + 落盘”的临界区放进锁内。加锁实现内部禁止再调用本函数
# （临界区之间改用 _xxx_locked 内层函数组合），以免自我死锁。
# 无 flock 时降级为直接执行（尽力而为）。
_with_profiles_lock() {
    command -v flock >/dev/null 2>&1 || {
        "$@"
        return
    }
    (
        flock -w 60 9 || {
            _errorcat "另一订阅操作正在进行（可能是定时更新），请稍后再试"
            exit 1
        }
        "$@"
    ) 9>>"$CLASH_PROFILES_LOCK"
}

# 下载并校验订阅到独立的临时工作文件（mktemp，避免固定路径的并发互踩）。
#   用法：_sub_download <url> <strategy(auto|raw|convert)>
#     auto    下载；原生且有效则直用，否则回退 subconverter 转换（默认）
#     raw     仅下载，绝不转换（校验失败即失败）
#     convert 始终经 subconverter 转换
#   返回：0 表示已下载且通过内核校验；非 0 表示失败。
# 成功后：_SUB_DL_FILE 指向可原子 mv 到目标的工作文件。
# 失败后：产物落到 last-failed.*（供排障），
#   _SUB_DL_REASON     去除颜色码后的最后一行错误（写入日志）
#   _SUB_DL_DEBUG_HINT 指向已保留调试产物的多行提示（供报错展示）
_sub_download() {
    local url=$1 strategy=${2:-auto}
    local work err_log rc
    _SUB_DL_FILE=''
    _SUB_DL_REASON=''
    _SUB_DL_DEBUG_HINT=''
    FETCH_USERINFO='' # 由 _download_raw_config 在成功时填充（机场流量信息）
    FETCH_FILENAME='' # 由 _download_raw_config 在成功时填充（content-disposition 文件名）

    work=$(mktemp "${CLASH_RESOURCES_DIR}/.fetch.XXXXXX") || {
        _errorcat "无法创建临时文件：$CLASH_RESOURCES_DIR"
        return 1
    }
    err_log="${work}.err"

    case $strategy in
    convert) _download_convert_config "$work" "$url" 2>"$err_log" ;;
    raw) _download_config "$work" "$url" false 2>"$err_log" ;;
    *) _download_config "$work" "$url" true 2>"$err_log" ;;
    esac
    rc=$?
    [ -s "$err_log" ] && cat "$err_log" >&2
    _SUB_DL_REASON=$(sed $'s/\x1b\\[[0-9;]*m//g' "$err_log" 2>/dev/null | awk 'NF{last=$0} END{print last}')
    /usr/bin/rm -f "$err_log"

    [ "$rc" -eq 0 ] && {
        _SUB_DL_FILE=$work
        /usr/bin/rm -f "${work}.raw" # 转换成功遗留的原始订阅，无需保留
        return 0
    }

    # 失败：保留调试产物到稳定路径，并按实际存在的文件拼装提示
    local hint='' converted=false
    { [ "$strategy" = convert ] || [ -f "${work}.raw" ]; } && converted=true
    if [ -s "$work" ]; then
        /bin/mv -f "$work" "$CLASH_CONFIG_DEBUG"
        hint="待检配置：$CLASH_CONFIG_DEBUG"
    else
        /usr/bin/rm -f "$work"
    fi
    [ -f "${work}.raw" ] && {
        /bin/mv -f "${work}.raw" "$CLASH_CONFIG_DEBUG_RAW"
        hint="${hint:+$hint
}原始订阅：$CLASH_CONFIG_DEBUG_RAW"
    }
    [ "$converted" = true ] && hint="${hint:+$hint
}转换日志：$BIN_SUBCONVERTER_LOG"
    _SUB_DL_DEBUG_HINT=$hint
    return "$rc"
}

########################################
#            名称与文件工具
########################################

# 从订阅链接派生默认名称（取 host；file:// → local）
_sub_default_name() {
    local url=$1 host
    case $url in
    file://*) host=local ;;
    *)
        host=${url#*://}
        host=${host%%/*}
        host=${host%%\?*}
        host=${host%%:*}
        ;;
    esac
    [ -z "$host" ] && host=sub
    printf '%s' "$host"
}

# 清洗 content-disposition 文件名为可用订阅名（保留中文等 Unicode）：
# 去扩展名、路径分隔符与控制字符、首尾空白；非法（空/以 - 开头）则输出空串
_sub_sanitize_name() {
    local s=$1
    s=${s%.*}      # 去最后一个扩展名，如 .yaml/.txt
    s=${s//\//_}   # 路径分隔符 → _
    s=$(printf '%s' "$s" | tr -d '\000-\037\177')
    s="${s#"${s%%[![:space:]]*}"}" # 去前导空白
    s="${s%"${s##*[![:space:]]}"}" # 去尾随空白
    case $s in -*) s='' ;; esac
    printf '%s' "$s"
}

# 基于 base 生成未占用的名称（冲突则追加 -2/-3…）
_sub_unique_name() {
    local base=$1 name=$1 n=1
    while _sub_has "$name"; do
        n=$((n + 1))
        name="${base}-${n}"
    done
    printf '%s' "$name"
}

# 校验用户提供的名称
_sub_validate_name() {
    local name=$1
    [ -z "$name" ] && {
        _errorcat "订阅名称不能为空"
        return 1
    }
    case $name in
    -*)
        _errorcat "订阅名称不能以 - 开头：$name"
        return 1
        ;;
    esac
    return 0
}

# 由名称派生安全的磁盘文件路径（非 [A-Za-z0-9._-] → _，冲突追加 -2/-3…）
_sub_filename() {
    local name=$1 safe path n=1
    safe=$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_')
    [ -z "$safe" ] && safe=sub
    path="${CLASH_PROFILES_DIR}/${safe}.yaml"
    while [ -e "$path" ]; do
        n=$((n + 1))
        path="${CLASH_PROFILES_DIR}/${safe}-${n}.yaml"
    done
    printf '%s' "$path"
}

# 一次性把旧的数字 id 模型迁移为 name 模型（幂等：以 id 字段存在为哨兵）
_sub_migrate() {
    [ -f "$CLASH_PROFILES_META" ] || return 0
    "$BIN_YQ" -e '([.profiles // [] | .[] | select(has("id"))] | length) > 0' \
        "$CLASH_PROFILES_META" >/dev/null 2>&1 || return 0

    local count i url name
    count=$("$BIN_YQ" '.profiles // [] | length' "$CLASH_PROFILES_META")
    for ((i = 0; i < count; i++)); do
        IDX=$i "$BIN_YQ" -e '.profiles[env(IDX)] | has("name")' "$CLASH_PROFILES_META" >/dev/null 2>&1 && continue
        url=$(IDX=$i "$BIN_YQ" '.profiles[env(IDX)].url // ""' "$CLASH_PROFILES_META")
        name=$(_sub_unique_name "$(_sub_default_name "$url")")
        IDX=$i PROFILE_NAME=$name "$BIN_YQ" -i '.profiles[env(IDX)].name = strenv(PROFILE_NAME)' "$CLASH_PROFILES_META"
    done

    # 顶层 use 若是旧的数字 id，映射为对应 name
    local use mapped
    use=$("$BIN_YQ" '.use // "" | tostring' "$CLASH_PROFILES_META")
    if [ -n "$use" ] && [[ "$use" =~ ^[0-9]+$ ]]; then
        mapped=$(PROFILE_ID=$use "$BIN_YQ" \
            '.profiles // [] | .[] | select((.id // "" | tostring) == strenv(PROFILE_ID)) | .name // ""' \
            "$CLASH_PROFILES_META" | head -n1)
        if [ -n "$mapped" ]; then
            PROFILE_NAME=$mapped "$BIN_YQ" -i '.use = strenv(PROFILE_NAME)' "$CLASH_PROFILES_META"
        else
            "$BIN_YQ" -i '.use = ""' "$CLASH_PROFILES_META"
        fi
    fi

    "$BIN_YQ" -i 'del(.profiles[].id)' "$CLASH_PROFILES_META"
    _logging_sub "🔄 已将订阅数据迁移为 name 模式"
}

########################################
#            交互式选择
########################################

_sub_has_fzf() {
    command -v fzf >&/dev/null && [ -t 0 ]
}

_sub_hint_fzf() {
    [ "${_SUB_FZF_HINT_SHOWN:-false}" = true ] && return 0
    [ -t 0 ] || return 0
    command -v fzf >&/dev/null && return 0

    _SUB_FZF_HINT_SHOWN=true
    _okcat '💡' '未检测到 fzf，已使用编号选择；安装 fzf 可启用搜索式选择界面。' >&2
}

# 交互选择一个订阅：选中的 name 输出到 stdout，菜单打到 stderr。
# fzf 可用则用 fzf（列表行内嵌流量/到期，链接在 preview），否则数字菜单回退。
_sub_pick() {
    local prompt=$1
    _sub_load

    [ ${#_SUB_NAMES[@]} -eq 0 ] && {
        _errorcat "当前无可用订阅，请先添加订阅"
        return 1
    }
    # 即使只有 1 个订阅也进入选择界面：use 会重启内核、del 为破坏性操作，
    # 需用户明确确认，不做隐式自动选择。

    local i w namew=0 trafw=0 expw=0
    for i in "${!_SUB_NAMES[@]}"; do
        w=$(_dispwidth "${_SUB_NAMES[$i]}")
        ((w > namew)) && namew=$w
        w=$(_dispwidth "${_SUB_TRAFFICS[$i]}")
        ((w > trafw)) && trafw=$w
        w=$(_dispwidth "${_SUB_EXPIRES[$i]}")
        ((w > expw)) && expw=$w
    done

    # 列标题行（与数据行同宽对齐），fzf 与编号菜单共用
    local col_header
    col_header="$(_pad '名称' "$namew")  $(_pad '流量' "$trafw")  到期"

    local marker
    if _sub_has_fzf; then
        local selected status preview_dir preview_args=()
        preview_dir=$(mktemp -d "${TMPDIR:-/tmp}/clashsub-preview.XXXXXX" 2>/dev/null)
        if [ -n "$preview_dir" ]; then
            # fzf 在其子 shell 中展开 {1} 与 $SUB_FZF_PREVIEW_DIR，故此处刻意用单引号
            # shellcheck disable=SC2016
            preview_args=(--preview 'cat "$SUB_FZF_PREVIEW_DIR"/{1}' --preview-window='right:45%:wrap')
            local now
            for i in "${!_SUB_NAMES[@]}"; do
                now=否
                [ "${_SUB_NAMES[$i]}" = "$_SUB_CUR" ] && now=是
                {
                    printf '订阅\n'
                    printf '  名称：%s\n' "${_SUB_NAMES[$i]}"
                    printf '  当前：%s\n' "$now"
                    printf '  更新：%s\n' "${_SUB_UPDS[$i]:-—}"
                    printf '  流量：%s\n' "${_SUB_TRAFFICS[$i]}"
                    printf '  到期：%s\n' "${_SUB_EXPIRES[$i]}"
                    printf '  链接：%s\n' "${_SUB_URLS[$i]}"
                } >"$preview_dir/$((i + 1))"
            done
        fi
        selected=$(
            for i in "${!_SUB_NAMES[@]}"; do
                marker=' '
                [ "${_SUB_NAMES[$i]}" = "$_SUB_CUR" ] && marker='*'
                printf '%s\t%s\t%s %s  %s  %s\n' \
                    "$((i + 1))" \
                    "${_SUB_NAMES[$i]}" \
                    "$marker" \
                    "$(_pad "${_SUB_NAMES[$i]}" "$namew")" \
                    "$(_pad "${_SUB_TRAFFICS[$i]}" "$trafw")" \
                    "${_SUB_EXPIRES[$i]}"
            done | SUB_FZF_PREVIEW_DIR=$preview_dir fzf \
                --height=80% \
                --layout=reverse \
                --border \
                --delimiter=$'\t' \
                --with-nth=3 \
                --prompt="$prompt" \
                --header="  $col_header
选择订阅，Enter 确认，Esc 退出" \
                "${preview_args[@]}"
        )
        status=$?
        [ -n "$preview_dir" ] && rm -rf -- "$preview_dir"
        [ "$status" -eq 0 ] || return 1
        [ -n "$selected" ] || return 1
        selected=${selected#*$'\t'}
        printf '%s\n' "${selected%%$'\t'*}"
        return 0
    fi

    _sub_hint_fzf

    local tok idxw=${#_SUB_NAMES[@]}
    idxw=${#idxw} # 序号位数
    # 序号列宽 + 标记列（空格偏移）后输出标题，与数据行对齐
    printf '  %*s   %s\n' "$((idxw + 2))" '' "$col_header" >&2
    for i in "${!_SUB_NAMES[@]}"; do
        marker=' '
        [ "${_SUB_NAMES[$i]}" = "$_SUB_CUR" ] && marker='*'
        tok="[$((i + 1))]"
        printf '  %-*s %s %s  %s  %s\n' \
            $((idxw + 2)) "$tok" \
            "$marker" \
            "$(_pad "${_SUB_NAMES[$i]}" "$namew")" \
            "$(_pad "${_SUB_TRAFFICS[$i]}" "$trafw")" \
            "${_SUB_EXPIRES[$i]}" >&2
    done
    local choice
    printf '%s' "$(_okcat '✈️ ' "$prompt")" >&2
    read -r choice
    [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#_SUB_NAMES[@]} ] && {
        printf '%s\n' "${_SUB_NAMES[$((choice - 1))]}"
        return 0
    }
    _errorcat "无效选择：$choice"
    return 1
}

########################################
#            子命令
########################################

sub_add() {
    local use_after_add=false name='' url='' strategy=auto

    while [ $# -gt 0 ]; do
        case "$1" in
        -h | --help)
            cat <<EOF

Usage:
  clashctl sub add [OPTIONS] <url>   # 省略 url 时交互式输入

Options:
  -n, --name <name>   指定订阅名称（省略时自动取机场名/链接 host）
  -u, --use           添加后立即使用该订阅
  --convert           始终经 subconverter 转换（默认 auto：原生有效则直用，否则回退转换）
  --raw               仅下载，不转换（校验失败即失败）
  -t, --timeout <秒>  单次命令级下载超时（默认 ${CLASHCTL_SUB_TIMEOUT:-20} 秒，可在 .env 全局配置）
  --ua <UA>           单次命令级下载 UA（默认 ${CLASHCTL_SUB_UA:-clash-verge/v2.4.0}，可在 .env 全局配置）

EOF
            return 0
            ;;
        -u | --use)
            use_after_add=true
            ;;
        --convert)
            [ "$strategy" = raw ] && {
                _errorcat "--convert 与 --raw 互斥"
                return 1
            }
            strategy=convert
            ;;
        --raw)
            [ "$strategy" = convert ] && {
                _errorcat "--raw 与 --convert 互斥"
                return 1
            }
            strategy=raw
            ;;
        -n | --name)
            [ -n "${2-}" ] || {
                _errorcat "选项 $1 需要一个名称参数"
                return 1
            }
            name=$2
            shift
            ;;
        --name=*)
            name="${1#*=}"
            ;;
        -t | --timeout)
            [ -n "${2-}" ] || {
                _errorcat "选项 $1 需要一个超时参数（秒）"
                return 1
            }
            CLASHCTL_SUB_TIMEOUT=$2
            shift
            ;;
        --timeout=*)
            CLASHCTL_SUB_TIMEOUT="${1#*=}"
            ;;
        --ua)
            [ -n "${2-}" ] || {
                _errorcat "选项 $1 需要一个 UA 参数"
                return 1
            }
            # shellcheck disable=SC2034  # 供 scripts/lib/convert.sh 读取
            CLASHCTL_SUB_UA=$2
            shift
            ;;
        --ua=*)
            # shellcheck disable=SC2034  # 供 scripts/lib/convert.sh 读取
            CLASHCTL_SUB_UA="${1#*=}"
            [ -n "$CLASHCTL_SUB_UA" ] || {
                _errorcat "选项 $1 需要一个 UA 参数"
                return 1
            }
            ;;
        --)
            shift
            break
            ;;
        -*)
            _errorcat "未知选项：$1"
            return 1
            ;;
        *)
            [ -n "$url" ] && {
                _errorcat "仅支持一个订阅链接"
                return 1
            }
            url=$1
            ;;
        esac
        shift
    done

    [ -z "$url" ] && [ $# -gt 0 ] && url=$1
    [ -z "$url" ] && {
        printf '%s' "$(_okcat '✈️ ' '请输入要添加的订阅链接：')"
        read -r url
        [ -z "$url" ] && {
            _errorcat "订阅链接不能为空"
            return 1
        }
    }

    if [ -n "$name" ]; then
        _sub_validate_name "$name" || return 1
        _sub_has "$name" && {
            _errorcat "订阅名称已存在：$name"
            return 1
        }
    fi

    _sub_url_exists "$url" && {
        _errorcat "该订阅链接已存在：$url"
        return 1
    }

    _sub_download "$url" "$strategy" || {
        _errorcat "订阅无效，请检查：
${_SUB_DL_DEBUG_HINT:-转换日志：$BIN_SUBCONVERTER_LOG}"
        return 1
    }

    _with_profiles_lock _sub_add_locked "$name" "$url" "$use_after_add" "$_SUB_DL_FILE" "$FETCH_USERINFO" "$FETCH_FILENAME"
}

# 临界区：确定唯一名称/路径、落盘、写入元数据（可选立即启用）
_sub_add_locked() {
    local name=$1 url=$2 use_after_add=$3 dl_file=$4 userinfo=$5 filename=$6

    # 下载期间可能已有并发操作占用了同名/同链接，锁内再权威校验一次
    if [ -n "$name" ]; then
        _sub_has "$name" && {
            /usr/bin/rm -f "$dl_file"
            _errorcat "订阅名称已存在：$name"
            return 1
        }
    else
        # 默认名优先取 content-disposition 文件名（多为机场名），否则回退链接 host
        local base
        base=$(_sub_sanitize_name "$filename")
        [ -z "$base" ] && base=$(_sub_default_name "$url")
        name=$(_sub_unique_name "$base")
    fi
    _sub_url_exists "$url" && {
        /usr/bin/rm -f "$dl_file"
        _errorcat "该订阅链接已存在：$url"
        return 1
    }

    /bin/mkdir -p "$CLASH_PROFILES_DIR"
    local profile_path
    profile_path=$(_sub_filename "$name")
    /bin/mv "$dl_file" "$profile_path"

    local now
    now=$(date +"%Y-%m-%d %H:%M:%S")
    PROFILE_NAME=$name PROFILE_PATH=$profile_path PROFILE_URL=$url PROFILE_UPDATED=$now PROFILE_USERINFO=$userinfo \
        "$BIN_YQ" -i '
            .profiles = (.profiles // []) +
            [{
              "name": strenv(PROFILE_NAME),
              "path": strenv(PROFILE_PATH),
              "url": strenv(PROFILE_URL),
              "updated": strenv(PROFILE_UPDATED),
              "userinfo": strenv(PROFILE_USERINFO)
            }]
        ' "$CLASH_PROFILES_META"

    _logging_sub "➕ 已添加订阅：[$name] $url"
    _okcat '🎉' "订阅已添加：[$name] $url"
    [ "$use_after_add" = true ] && _sub_use_locked "$name"
}

_sub_del() {
    case "${1:-}" in
    -h | --help)
        cat <<EOF

Usage:
  clashctl sub del <name>

删除指定订阅（正在使用中的订阅需先切换）。省略 name 时交互选择。

EOF
        return 0
        ;;
    esac

    local name=$1
    [ -z "$name" ] && {
        name=$(_sub_pick "请选择要删除的订阅：") || return 1
    }

    _sub_has "$name" || {
        _errorcat "订阅不存在：$name"
        return 1
    }

    _with_profiles_lock _sub_del_locked "$name"
}

_sub_del_locked() {
    local name=$1
    _sub_has "$name" || {
        _errorcat "订阅不存在：$name"
        return 1
    }

    [ "$(_sub_current)" = "$name" ] && {
        _errorcat "删除失败：订阅 [$name] 正在使用中，请先切换订阅"
        return 1
    }

    local path url
    path=$(_sub_get "$name" path)
    url=$(_sub_get "$name" url)

    /usr/bin/rm -f "$path"
    PROFILE_NAME=$name "$BIN_YQ" -i 'del(.profiles[] | select(.name == strenv(PROFILE_NAME)))' "$CLASH_PROFILES_META"
    _logging_sub "➖ 已删除订阅：[$name] $url"
    _okcat '🎉' "订阅已删除：[$name] $url"
}

# 字节数转人类可读（B/KB/MB/GB/...）
_fmt_bytes() {
    awk -v b="${1:-0}" 'BEGIN{
        if (b <= 0) { print "0B"; exit }
        split("B KB MB GB TB PB", u, " ");
        i = 1; while (b >= 1024 && i < 6) { b /= 1024; i++ }
        if (i == 1) printf "%d%s", b, u[i]; else printf "%.2f%s", b, u[i];
    }'
}

# 解析 subscription-userinfo 原始串，输出：used<TAB>total<TAB>expire（bytes / epoch）
_userinfo_fields() {
    local s=${1//;/ } kv k v upload=0 download=0 total=0 expire=0
    for kv in $s; do
        k=${kv%%=*}
        v=${kv#*=}
        [[ $v =~ ^[0-9]+$ ]] || continue
        case $k in
        upload) upload=$v ;;
        download) download=$v ;;
        total) total=$v ;;
        expire) expire=$v ;;
        esac
    done
    printf '%s\t%s\t%s' "$((upload + download))" "$total" "$expire"
}

# 由 userinfo 原始串生成展示用「流量」「到期」两字段（无信息为 —），以 TAB 分隔
_userinfo_display() {
    local raw=$1 used total expire traffic exp
    [ -z "$raw" ] && {
        printf '%s\t%s' '—' '—'
        return
    }
    IFS=$'\t' read -r used total expire < <(_userinfo_fields "$raw")
    if [ "${total:-0}" -gt 0 ] 2>/dev/null; then
        traffic="$(_fmt_bytes "$used")/$(_fmt_bytes "$total")"
    elif [ "${used:-0}" -gt 0 ] 2>/dev/null; then
        traffic=$(_fmt_bytes "$used")
    else
        traffic='—'
    fi
    if [ "${expire:-0}" -gt 0 ] 2>/dev/null; then
        exp=$(date -d "@$expire" +%Y-%m-%d 2>/dev/null || printf '—')
    else
        exp='—'
    fi
    printf '%s\t%s' "$traffic" "$exp"
}

_sub_list() {
    case "${1:-}" in
    -h | --help)
        cat <<EOF

Usage:
  clashctl sub ls

列出全部订阅（纯输出，不交互）：当前(*) / 名称 / 更新时间 / 流量 / 到期 / 链接。

EOF
        return 0
        ;;
    esac

    _sub_load

    [ ${#_SUB_NAMES[@]} -eq 0 ] && {
        _okcat '📭' '暂无订阅，使用 clashctl sub add <url> 添加'
        return 0
    }

    local NAME_H='名称' UPD_H='更新时间' TRAF_H='流量' EXP_H='到期'
    local namew updw trafw expw w i upd
    namew=$(_dispwidth "$NAME_H")
    updw=$(_dispwidth "$UPD_H")
    trafw=$(_dispwidth "$TRAF_H")
    expw=$(_dispwidth "$EXP_H")
    for i in "${!_SUB_NAMES[@]}"; do
        w=$(_dispwidth "${_SUB_NAMES[$i]}")
        ((w > namew)) && namew=$w
        w=$(_dispwidth "${_SUB_UPDS[$i]:-—}")
        ((w > updw)) && updw=$w
        w=$(_dispwidth "${_SUB_TRAFFICS[$i]}")
        ((w > trafw)) && trafw=$w
        w=$(_dispwidth "${_SUB_EXPIRES[$i]}")
        ((w > expw)) && expw=$w
    done

    printf '  %s %s  %s  %s  %s  %s\n' \
        ' ' \
        "$(_pad "$NAME_H" "$namew")" \
        "$(_pad "$UPD_H" "$updw")" \
        "$(_pad "$TRAF_H" "$trafw")" \
        "$(_pad "$EXP_H" "$expw")" \
        '链接'

    local marker
    for i in "${!_SUB_NAMES[@]}"; do
        marker=' '
        [ "${_SUB_NAMES[$i]}" = "$_SUB_CUR" ] && marker='*'
        upd=${_SUB_UPDS[$i]:-—}
        printf '  %s %s  %s  %s  %s  %s\n' \
            "$marker" \
            "$(_pad "${_SUB_NAMES[$i]}" "$namew")" \
            "$(_pad "$upd" "$updw")" \
            "$(_pad "${_SUB_TRAFFICS[$i]}" "$trafw")" \
            "$(_pad "${_SUB_EXPIRES[$i]}" "$expw")" \
            "${_SUB_URLS[$i]}"
    done
    return 0
}

_sub_use() {
    case "${1:-}" in
    -h | --help)
        cat <<EOF

Usage:
  clashctl sub use [name]

切换到指定订阅并使订阅生效。省略 name 时交互选择（* 为当前）。
裸 clashctl sub 在交互终端下同此。

EOF
        return 0
        ;;
    esac

    local name=$1
    [ -z "$name" ] && {
        name=$(_sub_pick "请选择要使用的订阅：") || return 1
    }

    _sub_has "$name" || {
        _errorcat "订阅不存在：$name"
        return 1
    }

    _with_profiles_lock _sub_use_locked "$name"
}

_sub_use_locked() {
    local name=$1 rc
    _sub_has "$name" || {
        _errorcat "订阅不存在：$name"
        return 1
    }

    local path url
    path=$(_sub_get "$name" path)
    url=$(_sub_get "$name" url)

    [ -f "$path" ] && [ -s "$path" ] || {
        _errorcat "订阅配置文件缺失或为空：$path"
        return 1
    }
    _valid_sub_nodes "$path" || return 1

    # 切换前备份 BASE：合并校验失败（rc=1）时连同运行配置一起回滚，避免 BASE 与 runtime 不一致
    cat "$CLASH_CONFIG_BASE" >"${CLASH_CONFIG_BASE}.bak" || {
        _errorcat "无法备份当前配置（磁盘已满？），已取消切换"
        return 1
    }
    cat "$path" >"$CLASH_CONFIG_BASE"
    _merge_config_restart
    rc=$?
    if [ "$rc" -eq 1 ]; then
        cat "${CLASH_CONFIG_BASE}.bak" >"$CLASH_CONFIG_BASE" || {
            _errorcat "回滚失败，原配置备份在 ${CLASH_CONFIG_BASE}.bak，请手动恢复"
            return 1
        }
        /usr/bin/rm -f "${CLASH_CONFIG_BASE}.bak"
        _errorcat "订阅 [$name] 校验未通过（含 Mixin 合并结果），已回滚"
        return 1
    fi
    /usr/bin/rm -f "${CLASH_CONFIG_BASE}.bak"

    PROFILE_NAME=$name "$BIN_YQ" -i '.use = strenv(PROFILE_NAME)' "$CLASH_PROFILES_META"
    _logging_sub "🔥 订阅已切换为：[$name] $url"
    # rc=2：配置本身已切换成功（BASE/runtime 均为新配置），仅服务重启失败
    if [ "$rc" -eq 2 ]; then
        _failcat '🍂' "配置已切换，但服务重启失败，请检查代理内核日志"
        return 1
    fi
    _okcat '🔥' '订阅已生效'
}

_sub_update() {
    case "${1:-}" in
    -h | --help)
        cat <<EOF

Usage:
  clashctl sub update [name] [--all] [--convert | --raw] [-t <秒>] [--ua <UA>]

更新订阅（重新下载）。省略 name 时更新当前使用的订阅；无当前订阅时交互选择
（非交互环境需指定 name 或 --all）。

Options:
  --all        更新全部订阅
  --convert    始终经 subconverter 转换（默认 auto：原生有效则直用，否则回退转换）
  --raw        仅下载，不转换（校验失败即失败）
  -t, --timeout <秒>  单次命令级下载超时（默认 ${CLASHCTL_SUB_TIMEOUT:-20} 秒，可在 .env 全局配置）
  --ua <UA>    单次命令级下载 UA（默认 ${CLASHCTL_SUB_UA:-clash-verge/v2.4.0}，可在 .env 全局配置）

EOF
        return 0
        ;;
    esac

    local strategy=auto name='' all=false
    while [ $# -gt 0 ]; do
        case "$1" in
        --all)
            all=true
            ;;
        --convert)
            [ "$strategy" = raw ] && {
                _errorcat "--convert 与 --raw 互斥"
                return 1
            }
            strategy=convert
            ;;
        --raw)
            [ "$strategy" = convert ] && {
                _errorcat "--raw 与 --convert 互斥"
                return 1
            }
            strategy=raw
            ;;
        -t | --timeout)
            [ -n "${2-}" ] || {
                _errorcat "选项 $1 需要一个超时参数（秒）"
                return 1
            }
            CLASHCTL_SUB_TIMEOUT=$2
            shift
            ;;
        --timeout=*)
            CLASHCTL_SUB_TIMEOUT="${1#*=}"
            ;;
        --ua)
            [ -n "${2-}" ] || {
                _errorcat "选项 $1 需要一个 UA 参数"
                return 1
            }
            # shellcheck disable=SC2034  # 供 scripts/lib/convert.sh 读取
            CLASHCTL_SUB_UA=$2
            shift
            ;;
        --ua=*)
            # shellcheck disable=SC2034  # 供 scripts/lib/convert.sh 读取
            CLASHCTL_SUB_UA="${1#*=}"
            [ -n "$CLASHCTL_SUB_UA" ] || {
                _errorcat "选项 $1 需要一个 UA 参数"
                return 1
            }
            ;;
        --)
            shift
            break
            ;;
        -*)
            _errorcat "未知选项：$1"
            return 1
            ;;
        *)
            [ -z "$name" ] && name=$1
            ;;
        esac
        shift
    done

    [ "$all" = true ] && {
        [ -n "$name" ] && {
            _errorcat "--all 不能与订阅名同时指定"
            return 1
        }
        local names=() n rc=0
        while IFS= read -r n; do
            [ -n "$n" ] && names+=("$n")
        done < <(_sub_names)
        [ ${#names[@]} -eq 0 ] && {
            _errorcat "当前无可用订阅，请先添加订阅"
            return 1
        }
        for n in "${names[@]}"; do
            _sub_update_one "$n" "$strategy" || rc=1
        done
        return "$rc"
    }

    [ -z "$name" ] && name=$(_sub_current)
    [ -z "$name" ] && {
        # 无当前订阅：交互终端回退选择，非交互环境保持可脚本的明确报错
        if [ -t 0 ] && [ -t 1 ]; then
            name=$(_sub_pick "请选择要更新的订阅：") || return 1
        else
            _errorcat "当前无使用中的订阅，请指定订阅名称或使用 --all"
            return 1
        fi
    }
    _sub_update_one "$name" "$strategy"
}

# 更新单个订阅：下载/校验在锁外，提交在锁内（供单个与 --all 复用）
_sub_update_one() {
    local name=$1 strategy=$2
    _sub_has "$name" || {
        _errorcat "订阅不存在：$name"
        return 1
    }

    local url path
    url=$(_sub_get "$name" url)
    path=$(_sub_get "$name" path)
    _okcat "✈️ " "更新订阅：[$name] $url"

    _sub_download "$url" "$strategy" || {
        _logging_sub "❌ 订阅更新失败：[$name] $url${_SUB_DL_REASON:+ — ${_SUB_DL_REASON}}"
        _errorcat "订阅无效：请检查：
${_SUB_DL_DEBUG_HINT:-转换日志：$BIN_SUBCONVERTER_LOG}"
        return 1
    }

    _with_profiles_lock _sub_update_locked "$name" "$url" "$path" "$_SUB_DL_FILE" "$FETCH_USERINFO"
}

_sub_update_locked() {
    local name=$1 url=$2 path=$3 dl_file=$4 userinfo=$5

    # 下载期间该订阅可能已被并发删除，锁内复检
    _sub_has "$name" || {
        /usr/bin/rm -f "$dl_file"
        _errorcat "订阅不存在（可能已被删除）：$name"
        return 1
    }

    _logging_sub "✅ 订阅更新成功：[$name] $url"
    /bin/mv -f "$dl_file" "$path"

    local now
    now=$(date +"%Y-%m-%d %H:%M:%S")
    PROFILE_NAME=$name PROFILE_UPDATED=$now "$BIN_YQ" -i \
        '(.profiles[] | select(.name == strenv(PROFILE_NAME)) | .updated) = strenv(PROFILE_UPDATED)' \
        "$CLASH_PROFILES_META"
    # 仅在本次抓到流量信息时更新，避免转换路径的空值覆盖既有数据
    [ -n "$userinfo" ] && PROFILE_NAME=$name PROFILE_USERINFO=$userinfo "$BIN_YQ" -i \
        '(.profiles[] | select(.name == strenv(PROFILE_NAME)) | .userinfo) = strenv(PROFILE_USERINFO)' \
        "$CLASH_PROFILES_META"

    [ "$(_sub_current)" = "$name" ] && {
        _sub_use_locked "$name"
        return
    }
    _okcat '订阅已更新'
}

_sub_rename() {
    case "${1:-}" in
    -h | --help)
        cat <<EOF

Usage:
  clashctl sub rename <old> <new>

重命名订阅。省略参数时交互选择并提示输入新名称。

EOF
        return 0
        ;;
    esac

    local old=$1 new=$2

    [ -z "$old" ] && {
        old=$(_sub_pick "请选择要重命名的订阅：") || return 1
    }
    _sub_has "$old" || {
        _errorcat "订阅不存在：$old"
        return 1
    }

    [ -z "$new" ] && {
        printf '%s' "$(_okcat '✈️ ' "请输入 [$old] 的新名称：")"
        read -r new
    }
    _sub_validate_name "$new" || return 1
    [ "$new" = "$old" ] && {
        _okcat "名称未变化：$old"
        return 0
    }
    _sub_has "$new" && {
        _errorcat "订阅名称已存在：$new"
        return 1
    }

    _with_profiles_lock _sub_rename_locked "$old" "$new"
}

_sub_rename_locked() {
    local old=$1 new=$2
    _sub_has "$old" || {
        _errorcat "订阅不存在：$old"
        return 1
    }
    _sub_has "$new" && {
        _errorcat "订阅名称已存在：$new"
        return 1
    }

    OLD_NAME=$old NEW_NAME=$new "$BIN_YQ" -i \
        '(.profiles[] | select(.name == strenv(OLD_NAME)) | .name) = strenv(NEW_NAME)' \
        "$CLASH_PROFILES_META"
    [ "$(_sub_current)" = "$old" ] && {
        NEW_NAME=$new "$BIN_YQ" -i '.use = strenv(NEW_NAME)' "$CLASH_PROFILES_META"
    }

    _logging_sub "✏️ 订阅重命名：[$old] → [$new]"
    _okcat '✏️' "订阅已重命名：[$old] → [$new]"
}

_sub_log() {
    [ $# -gt 0 ] && {
        tail "$@" "$CLASH_PROFILES_LOG"
        return
    }
    tail "$CLASH_PROFILES_LOG"
}

sub_help() {
    cat <<EOF

clashctl sub - 订阅管理工具

Usage:
  clashctl sub COMMAND [OPTIONS]

Commands:
  add [-n NAME] <url>   添加订阅（-n 指定名称，-u 添加后立即使用）
  (无子命令)            交互选择并切换订阅；非交互环境输出列表
  ls                    查看订阅列表（纯输出，不交互）
  use [name]            使用订阅（省略 name 则交互选择）
  del <name>            删除订阅（省略 name 则交互选择）
  update [name]         更新订阅（省略 name 则更新当前订阅，--all 更新全部）
  rename <old> <new>    重命名订阅
  log                   订阅日志

Global Options:
  -h, --help            显示帮助信息

EOF
}
