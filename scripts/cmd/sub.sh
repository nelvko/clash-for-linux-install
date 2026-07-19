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
    list | ls | '')
        shift
        _sub_list "$@"
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

# 订阅数量
_sub_count() {
    local n
    n=$("$BIN_YQ" '.profiles // [] | length' "$CLASH_PROFILES_META" 2>/dev/null)
    printf '%s' "${n:-0}"
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
# fzf 可用则用 fzf（含预览），否则数字菜单回退。
_sub_pick() {
    local prompt=$1
    local names=() name
    while IFS= read -r name; do
        [ -n "$name" ] && names+=("$name")
    done < <(_sub_names)

    [ ${#names[@]} -eq 0 ] && {
        _errorcat "当前无可用订阅，请先添加订阅"
        return 1
    }
    # 即使只有 1 个订阅也进入选择界面：use 会重启内核、del 为破坏性操作，
    # 需用户明确确认，不做隐式自动选择。

    local current i urls=() updateds=()
    current=$(_sub_current)
    for i in "${!names[@]}"; do
        urls+=("$(_sub_get "${names[$i]}" url)")
        updateds+=("$(_sub_get "${names[$i]}" updated)")
    done

    local w namew=0
    for i in "${!names[@]}"; do
        w=$(_dispwidth "${names[$i]}")
        ((w > namew)) && namew=$w
    done

    local marker
    if _sub_has_fzf; then
        local selected status preview_dir preview_args=()
        preview_dir=$(mktemp -d "${TMPDIR:-/tmp}/clashsub-preview.XXXXXX" 2>/dev/null)
        if [ -n "$preview_dir" ]; then
            # fzf 在其子 shell 中展开 {1} 与 $SUB_FZF_PREVIEW_DIR，故此处刻意用单引号
            # shellcheck disable=SC2016
            preview_args=(--preview 'cat "$SUB_FZF_PREVIEW_DIR"/{1}' --preview-window='right:45%:wrap')
            local now
            for i in "${!names[@]}"; do
                now=否
                [ "${names[$i]}" = "$current" ] && now=是
                {
                    printf '订阅\n'
                    printf '  名称：%s\n' "${names[$i]}"
                    printf '  当前：%s\n' "$now"
                    printf '  更新：%s\n' "${updateds[$i]:-—}"
                    printf '  链接：%s\n' "${urls[$i]}"
                } >"$preview_dir/$((i + 1))"
            done
        fi
        selected=$(
            for i in "${!names[@]}"; do
                marker=' '
                [ "${names[$i]}" = "$current" ] && marker='*'
                printf '%s\t%s\t%s %s  %s\n' \
                    "$((i + 1))" \
                    "${names[$i]}" \
                    "$marker" \
                    "$(_pad "${names[$i]}" "$namew")" \
                    "${urls[$i]}"
            done | SUB_FZF_PREVIEW_DIR=$preview_dir fzf \
                --height=80% \
                --layout=reverse \
                --border \
                --delimiter=$'\t' \
                --with-nth=3 \
                --prompt="$prompt" \
                --header='选择订阅，Enter 确认，Esc 退出' \
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

    local tok idxw=${#names[@]}
    idxw=${#idxw} # 序号位数
    for i in "${!names[@]}"; do
        marker=' '
        [ "${names[$i]}" = "$current" ] && marker='*'
        tok="[$((i + 1))]"
        printf '  %-*s %s %s  %s\n' \
            $((idxw + 2)) "$tok" \
            "$marker" \
            "$(_pad "${names[$i]}" "$namew")" \
            "${urls[$i]}" >&2
    done
    local choice
    printf '%s' "$(_okcat '✈️ ' "$prompt")" >&2
    read -r choice
    [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#names[@]} ] && {
        printf '%s\n' "${names[$((choice - 1))]}"
        return 0
    }
    _errorcat "无效选择：$choice"
    return 1
}

########################################
#            子命令
########################################

sub_add() {
    local use_after_add=false name='' url=''

    while [ $# -gt 0 ]; do
        case "$1" in
        -h | --help)
            cat <<EOF

- 添加订阅
  clashctl sub add <url>

- 指定订阅名称
  clashctl sub add -n <name> <url>
  clashctl sub add --name <name> <url>

- 添加后立即使用该订阅
  clashctl sub add -u <url>
  clashctl sub add --use <url>

EOF
            return 0
            ;;
        -u | --use)
            use_after_add=true
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

    _download_config "$CLASH_CONFIG_TEMP" "$url"
    _valid_config "$CLASH_CONFIG_TEMP" || {
        _errorcat "订阅无效，请检查：
    原始订阅：${CLASH_CONFIG_TEMP}.raw
    转换订阅：$CLASH_CONFIG_TEMP
    转换日志：$BIN_SUBCONVERTER_LOG"
        return 1
    }

    [ -z "$name" ] && name=$(_sub_unique_name "$(_sub_default_name "$url")")

    /bin/mkdir -p "$CLASH_PROFILES_DIR"
    local profile_path
    profile_path=$(_sub_filename "$name")
    /bin/mv "$CLASH_CONFIG_TEMP" "$profile_path"

    local now
    now=$(date +"%Y-%m-%d %H:%M:%S")
    PROFILE_NAME=$name PROFILE_PATH=$profile_path PROFILE_URL=$url PROFILE_UPDATED=$now \
        "$BIN_YQ" -i '
            .profiles = (.profiles // []) +
            [{
              "name": strenv(PROFILE_NAME),
              "path": strenv(PROFILE_PATH),
              "url": strenv(PROFILE_URL),
              "updated": strenv(PROFILE_UPDATED)
            }]
        ' "$CLASH_PROFILES_META"

    _logging_sub "➕ 已添加订阅：[$name] $url"
    _okcat '🎉' "订阅已添加：[$name] $url"
    [ "$use_after_add" = true ] && _sub_use "$name"
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

_sub_list() {
    case "${1:-}" in
    -h | --help)
        cat <<EOF

Usage:
  clashctl sub ls

列出全部订阅：当前(*) / 名称 / 更新时间 / 链接。

EOF
        return 0
        ;;
    esac

    local names=() name
    while IFS= read -r name; do
        [ -n "$name" ] && names+=("$name")
    done < <(_sub_names)

    [ ${#names[@]} -eq 0 ] && {
        _okcat '📭' '暂无订阅，使用 clashctl sub add <url> 添加'
        return 0
    }

    local current i urls=() updateds=()
    current=$(_sub_current)
    for i in "${!names[@]}"; do
        urls+=("$(_sub_get "${names[$i]}" url)")
        updateds+=("$(_sub_get "${names[$i]}" updated)")
    done

    local NAME_H='名称' UPD_H='更新时间'
    local namew updw w upd
    namew=$(_dispwidth "$NAME_H")
    updw=$(_dispwidth "$UPD_H")
    for i in "${!names[@]}"; do
        w=$(_dispwidth "${names[$i]}")
        ((w > namew)) && namew=$w
        w=$(_dispwidth "${updateds[$i]:-—}")
        ((w > updw)) && updw=$w
    done

    printf '  %s %s  %s  %s\n' \
        ' ' \
        "$(_pad "$NAME_H" "$namew")" \
        "$(_pad "$UPD_H" "$updw")" \
        '链接'

    local marker
    for i in "${!names[@]}"; do
        marker=' '
        [ "${names[$i]}" = "$current" ] && marker='*'
        upd=${updateds[$i]:-—}
        printf '  %s %s  %s  %s\n' \
            "$marker" \
            "$(_pad "${names[$i]}" "$namew")" \
            "$(_pad "$upd" "$updw")" \
            "${urls[$i]}"
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

EOF
        return 0
        ;;
    esac

    [ "$(_sub_count)" -eq 0 ] && {
        _errorcat "当前无可用订阅，请先添加订阅"
        return 1
    }

    local name=$1
    [ -z "$name" ] && {
        name=$(_sub_pick "请选择要使用的订阅：") || return 1
    }

    _sub_has "$name" || {
        _errorcat "订阅不存在：$name"
        return 1
    }

    local path url
    path=$(_sub_get "$name" path)
    url=$(_sub_get "$name" url)

    cat "$path" >"$CLASH_CONFIG_BASE"
    _merge_config_restart
    PROFILE_NAME=$name "$BIN_YQ" -i '.use = strenv(PROFILE_NAME)' "$CLASH_PROFILES_META"
    _logging_sub "🔥 订阅已切换为：[$name] $url"
    _okcat '🔥' '订阅已生效'
}

_sub_update() {
    case "${1:-}" in
    -h | --help)
        cat <<EOF

Usage:
  clashctl sub update [name] [--convert] [--auto]

更新订阅（重新下载并转换）。省略 name 时更新当前使用的订阅。

Options:
  --convert    使用 subconverter 重新转换订阅格式
  --auto       设置每 2 天自动更新订阅的定时任务

EOF
        return 0
        ;;
    esac

    local arg is_convert=false name=''
    for arg in "$@"; do
        case $arg in
        --auto)
            command -v crontab >/dev/null || _errorcat "未检测到 crontab 命令，请先安装 cron 服务" || return
            crontab -l 2>/dev/null | grep -Fqs "$CLASHCTL_CRON_TAG" || {
                {
                    crontab -l 2>/dev/null | grep -Fv "$CLASHCTL_CRON_TAG"
                    printf '0 0 */2 * * %s sub update %s\n' "$(which clashctl)" "$CLASHCTL_CRON_TAG"
                } | crontab -
            }
            _okcat "已设置定时更新订阅"
            return 0
            ;;
        --convert)
            is_convert=true
            ;;
        -*)
            _errorcat "未知选项：$arg"
            return 1
            ;;
        *)
            [ -z "$name" ] && name=$arg
            ;;
        esac
    done

    [ -z "$name" ] && name=$(_sub_current)
    [ -z "$name" ] && {
        _errorcat "当前无使用中的订阅，请指定订阅名称"
        return 1
    }
    _sub_has "$name" || {
        _errorcat "订阅不存在：$name"
        return 1
    }

    local url path
    url=$(_sub_get "$name" url)
    path=$(_sub_get "$name" path)
    _okcat "✈️ " "更新订阅：[$name] $url"

    if [ "$is_convert" = true ]; then
        _download_convert_config "$CLASH_CONFIG_TEMP" "$url"
    else
        _download_config "$CLASH_CONFIG_TEMP" "$url"
    fi

    _valid_config "$CLASH_CONFIG_TEMP" || {
        _logging_sub "❌ 订阅更新失败：[$name] $url"
        _errorcat "订阅无效：请检查：
    原始订阅：${CLASH_CONFIG_TEMP}.raw
    转换订阅：$CLASH_CONFIG_TEMP
    转换日志：$BIN_SUBCONVERTER_LOG"
        return 1
    }

    _logging_sub "✅ 订阅更新成功：[$name] $url"
    cat "$CLASH_CONFIG_TEMP" >"$path"

    local now
    now=$(date +"%Y-%m-%d %H:%M:%S")
    PROFILE_NAME=$name PROFILE_UPDATED=$now "$BIN_YQ" -i \
        '(.profiles[] | select(.name == strenv(PROFILE_NAME)) | .updated) = strenv(PROFILE_UPDATED)' \
        "$CLASH_PROFILES_META"

    [ "$(_sub_current)" = "$name" ] && {
        _sub_use "$name"
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
  ls                    查看订阅列表
  use [name]            使用订阅（省略 name 则交互选择）
  del <name>            删除订阅（省略 name 则交互选择）
  update [name]         更新订阅（省略 name 则更新当前订阅）
  rename <old> <new>    重命名订阅
  log                   订阅日志

Global Options:
  -h, --help            显示帮助信息

EOF
}
