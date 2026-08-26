#!/usr/bin/env bash

# allow_convert=false（raw 策略）时，校验失败即失败，不回退 subconverter。
_download_config() {
    local dest=$1
    local url=$2
    local allow_convert=${3:-true}
    [ "${url:0:4}" = 'file' ] || _ui_info_out '正在下载订阅配置'
    _download_raw_config "$dest" "$url" || return 1
    _normalize_sub_config "$dest" || return 1

    _is_html_response "$dest" && {
        _errorcat "订阅响应疑似 HTML 页面，请检查订阅链接或 User-Agent"
        return 1
    }

    _is_native_yaml_config "$dest" && {
        _ui_info_out '检测到原生 Clash/Mihomo 配置'
        _valid_config "$dest" && _valid_sub_nodes "$dest" && return
        [ "$allow_convert" = true ] || {
            _errorcat "raw 模式下原生配置校验失败（未尝试转换），可改用默认策略或 --convert"
            return 1
        }
        _ui_warn_fail '原生配置验证失败，正在尝试订阅转换'
        cat "$dest" >"${dest}.raw"
        _download_convert_config "$dest" "$url" || return
        _normalize_sub_config "$dest" || return
        _valid_config "$dest" && _valid_sub_nodes "$dest"
        return
    }

    _ui_info_out '正在验证订阅配置'
    _valid_config "$dest" && _valid_sub_nodes "$dest" && return

    [ "$allow_convert" = true ] || {
        _errorcat "raw 模式下配置校验失败（未尝试转换），可改用默认策略或 --convert"
        return 1
    }
    _ui_warn_fail '配置验证失败，正在尝试订阅转换'
    cat "$dest" >"${dest}.raw"
    _download_convert_config "$dest" "$url" || return
    _normalize_sub_config "$dest" || return
    _valid_config "$dest" && _valid_sub_nodes "$dest"
}

_normalize_sub_config() {
    local dest=$1

    [ -s "$dest" ] || {
        _errorcat "订阅响应为空，请检查订阅链接"
        return 1
    }

    LC_ALL=C sed -i '1s/^\xEF\xBB\xBF//' "$dest" 2>/dev/null || true
    sed -i 's/\r$//' "$dest" 2>/dev/null || true

    command -v iconv >/dev/null || return 0
    iconv -f UTF-8 -t UTF-8 "$dest" >/dev/null 2>&1 && return 0

    local charset
    for charset in GB18030 GBK BIG5; do
        iconv -f "$charset" -t UTF-8 "$dest" -o "${dest}.utf8" 2>/dev/null && {
            /bin/mv -f "${dest}.utf8" "$dest"
            _ui_ok_out "订阅已从 $charset 转为 UTF-8"
            return 0
        }
    done

    /usr/bin/rm -f "${dest}.utf8" 2>/dev/null
    return 0
}

_is_html_response() {
    LC_ALL=C grep -qiE '<[[:space:]]*(!doctype|html|head|body|title)([[:space:]>]|$)' "$1"
}

_is_native_yaml_config() {
    "$BIN_YQ" -e '
      ((.proxies // []) | type == "!!seq" and length > 0) or
      ((.proxy-providers // {}) | type == "!!map" and length > 0)
    ' "$1" >/dev/null 2>&1
}

_valid_sub_nodes() {
    local config=$1 count
    count=$("$BIN_YQ" '
      ((.proxies // []) | length) +
      ((.proxy-providers // {}) | length)
    ' "$config" 2>/dev/null) || return 0

    [ "${count:-0}" -gt 0 ] || {
        _errorcat "订阅未解析出任何节点，请检查订阅内容或转换器版本"
        return 1
    }
}

# curl 配置文件的双引号值只识别少量反斜杠转义。拒绝控制字符并转义
# 反斜杠/双引号，避免订阅 URL 注入额外选项。
_curl_config_add() {
    local config=$1 option=$2 value=${3-} cleaned

    cleaned=$(printf '%s' "$value" | LC_ALL=C tr -d '\001-\037\177')
    if [ "$cleaned" != "$value" ]; then
        _errorcat "curl 请求参数包含不支持的控制字符"
        return 1
    fi

    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '%s = "%s"\n' "$option" "$value" >>"$config"
}

_curl_private_cleanup() {
    local path
    local -a paths=()
    for path in "${1:-}" "${2:-}"; do
        [ -z "$path" ] || paths+=("$path")
    done
    [ "${#paths[@]}" -eq 0 ] || /usr/bin/rm -f -- "${paths[@]}" || {
        _errorcat '无法清理 curl 私有临时文件'
        return 1
    }
}

_curl_private_exit_cleanup() {
    local request_rc=$?
    trap - EXIT HUP INT TERM
    if ! _curl_private_cleanup "${config:-}" "${header:-}" && [ "$request_rc" -eq 0 ]; then
        request_rc=1
    fi
    exit "$request_rc"
}

# 敏感请求只把私有配置路径放入 curl argv；订阅 URL 留在 0600 配置中。
# 子 shell 隔离 trap，确保成功、失败和信号退出都会删除配置。
_curl_private_request() (
    local kind=$1 dest=$2 subscription_url=$3
    local config header='' rc request_url userinfo='' filename=''

    command -v curl >/dev/null 2>&1 || {
        _errorcat "缺少订阅下载依赖：curl"
        exit 127
    }

    umask 077
    config=$(mktemp "${CLASH_RESOURCES_DIR}/.curl-config.XXXXXX") || {
        _errorcat "无法创建 curl 私有配置"
        exit 1
    }

    trap '_curl_private_exit_cleanup' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    chmod 0600 -- "$config" || {
        _errorcat "无法保护 curl 私有配置"
        exit 1
    }

    case $kind in
    raw)
        header=$(mktemp "${CLASH_RESOURCES_DIR}/.header.XXXXXX" 2>/dev/null) || header=
        printf '%s\n' silent fail insecure location retry-connrefused >"$config" || exit 1
        _curl_config_add "$config" connect-timeout "${CLASHCTL_SUB_CONNECT_TIMEOUT:-5}" || exit 1
        _curl_config_add "$config" max-time "${CLASHCTL_SUB_TIMEOUT:-20}" || exit 1
        _curl_config_add "$config" retry "${CLASHCTL_SUB_RETRY:-2}" || exit 1
        _curl_config_add "$config" retry-delay 1 || exit 1
        _curl_config_add "$config" user-agent "$CLASHCTL_SUB_UA" || exit 1
        [ -z "$header" ] || _curl_config_add "$config" dump-header "$header" || exit 1
        _curl_config_add "$config" output "$dest" || exit 1
        _curl_config_add "$config" url "$subscription_url" || exit 1
        ;;
    convert)
        request_url="http://127.0.0.1:${BIN_SUBCONVERTER_PORT}/sub"
        printf '%s\n' get silent fail location >"$config" || exit 1
        _curl_config_add "$config" max-time "${CLASHCTL_SUB_TIMEOUT:-20}" || exit 1
        _curl_config_add "$config" user-agent "$CLASHCTL_SUB_UA" || exit 1
        _curl_config_add "$config" data-urlencode target=clash || exit 1
        _curl_config_add "$config" data-urlencode "url=$subscription_url" || exit 1
        _curl_config_add "$config" output "$dest" || exit 1
        _curl_config_add "$config" url "$request_url" || exit 1
        ;;
    health)
        printf '%s\n' silent fail >"$config" || exit 1
        _curl_config_add "$config" noproxy '*' || exit 1
        _curl_config_add "$config" max-time 1 || exit 1
        _curl_config_add "$config" output /dev/null || exit 1
        _curl_config_add "$config" url "$subscription_url" || exit 1
        ;;
    *)
        _errorcat "未知 curl 请求类型"
        exit 2
        ;;
    esac

    # --disable 必须先于 --config，防止用户 .curlrc 开启 verbose/trace 泄漏 URL。
    # 原生错误也不直接进入订阅日志；调用方只收到不含 URL 的稳定诊断。
    if curl --disable --config "$config" 2>/dev/null; then
        if [ "$kind" = raw ]; then
            if [ -n "$header" ]; then
                userinfo=$(_header_value "$header" 'subscription-userinfo') || userinfo=
                filename=$(_attachment_filename "$header") || filename=
            fi
            printf '%s\n%s\n' "$userinfo" "$filename"
        fi
        exit 0
    else
        rc=$?
        case $kind in
        raw) _errorcat "订阅下载请求失败（curl 错误码 $rc）" || : ;;
        convert) _errorcat "订阅转换请求失败（curl 错误码 $rc）" || : ;;
        health) ;;
        esac
        exit "$rc"
    fi
)

_download_raw_config() {
    local dest=$1
    local url=$2

    # curl 子进程返回两行已解析的响应头元数据；原始头文件随私有配置一并清理。
    local metadata rc
    local -a values=()

    if metadata=$(_curl_private_request raw "$dest" "$url"); then
        rc=0
        mapfile -t values <<<"$metadata"
        # shellcheck disable=SC2034  # 供 sub.sh 读取
        FETCH_USERINFO=${values[0]:-}
        # shellcheck disable=SC2034
        FETCH_FILENAME=${values[1]:-}
    else
        rc=$?
    fi
    return "$rc"
}

# 取响应头某字段值（大小写不敏感；重定向时 curl 累积多段头，取最后一段）
_header_value() {
    local header_file=$1 key=$2
    grep -i "^[[:space:]]*${key}:" "$header_file" 2>/dev/null |
        tail -1 | cut -d: -f2- | tr -d '\r' |
        sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//'
}

# 从 content-disposition 提取文件名；优先 RFC 5987 的 filename*=（百分号编码解回 UTF-8）
_attachment_filename() {
    local header_file=$1 disposition filename
    disposition=$(_header_value "$header_file" 'content-disposition')
    [ -z "$disposition" ] && return 0

    filename=$(grep -oE "filename\*=[^;]*" <<<"$disposition" | head -1)
    if [ -n "$filename" ]; then
        filename=${filename#filename\*=}
        filename=${filename#*\'\'} # 去掉 charset''lang 前缀，如 UTF-8''
        filename=$(printf '%b' "${filename//%/\\x}")
    else
        filename=$(grep -oE 'filename="?[^";]*' <<<"$disposition" | head -1)
        filename=${filename#filename=}
        filename=${filename#\"}
    fi
    printf '%s\n' "$filename"
}

_download_convert_config() {
    local dest=$1
    local url=$2
    local rc

    [ "${url:0:4}" = 'file' ] && return 0

    # 子 shell + trap 确保任何退出路径（含 Ctrl-C）都回收自己拉起的 subconverter。
    # 一次请求完成转换并落盘，订阅 URL 仅进入私有 curl 配置，不进入进程参数。
    (
        trap '_subconverter_exit_cleanup' EXIT
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM
        _start_convert || exit 1
        if _curl_private_request convert "$dest" "$url"; then
            _subconverter_log_event INFO "转换请求完成（端口 $BIN_SUBCONVERTER_PORT）" || :
            exit 0
        else
            rc=$?
            _subconverter_log_event ERROR "转换请求失败（curl 错误码 $rc，端口 $BIN_SUBCONVERTER_PORT）" || :
            exit "$rc"
        fi
    )
}

_subconverter_exit_cleanup() {
    local request_rc=$?
    trap - EXIT HUP INT TERM
    if ! _stop_convert && [ "$request_rc" -eq 0 ]; then
        request_rc=1
    fi
    exit "$request_rc"
}

_detect_subconverter_port() {
    local configured_port new_port

    configured_port=$("$BIN_YQ" '.server.port' "$BIN_SUBCONVERTER_CONFIG" 2>/dev/null) || {
        _errorcat "无法读取 subconverter 端口配置：$BIN_SUBCONVERTER_CONFIG"
        return 1
    }
    case $configured_port in
    '' | *[!0-9]*)
        _errorcat "subconverter 端口配置无效：$configured_port"
        return 1
        ;;
    esac
    if [ "$configured_port" -lt 1 ] || [ "$configured_port" -gt 65535 ]; then
        _errorcat "subconverter 端口超出范围：$configured_port"
        return 1
    fi

    new_port=$(_get_random_port) || return
    case $new_port in
    '' | *[!0-9]*)
        _errorcat "无法为 subconverter 分配有效端口"
        return 1
        ;;
    esac
    if [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        _errorcat "无法为 subconverter 分配有效端口"
        return 1
    fi
    if _is_port_used "$configured_port"; then
        _ui_warn_fail "端口冲突：[subconverter] $configured_port；已随机分配 $new_port" || :
    fi
    BIN_SUBCONVERTER_PORT=$new_port
}

_subconverter_log_reset() {
    local tmp

    tmp=$(mktemp "${BIN_SUBCONVERTER_LOG}.XXXXXX") || {
        _errorcat "无法创建安全的 subconverter 日志"
        return 1
    }
    chmod 0600 -- "$tmp" || {
        /usr/bin/rm -f -- "$tmp"
        _errorcat "无法保护 subconverter 日志"
        return 1
    }
    printf '%s [INFO] 独占转换实例启动；第三方请求日志因可能包含订阅凭据，不会持久化\n' \
        "$(date +'%Y-%m-%dT%H:%M:%S%z')" >"$tmp" || {
        /usr/bin/rm -f -- "$tmp"
        _errorcat "无法初始化安全的 subconverter 日志"
        return 1
    }
    /bin/mv -fT -- "$tmp" "$BIN_SUBCONVERTER_LOG" || {
        /usr/bin/rm -f -- "$tmp"
        _errorcat "无法提交安全的 subconverter 日志"
        return 1
    }
}

_subconverter_log_event() {
    local level=$1
    shift
    (
        umask 077
        printf '%s [%s] %s\n' "$(date +'%Y-%m-%dT%H:%M:%S%z')" "$level" "$*" >>"$BIN_SUBCONVERTER_LOG"
        chmod 0600 -- "$BIN_SUBCONVERTER_LOG"
    )
}

_prepare_subconverter_runtime() {
    BIN_SUBCONVERTER_RUN_CONFIG=$(mktemp "${BIN_SUBCONVERTER_DIR}/.pref.runtime.XXXXXX") || {
        _errorcat "无法创建 subconverter 私有运行配置"
        return 1
    }
    chmod 0600 -- "$BIN_SUBCONVERTER_RUN_CONFIG" || {
        _errorcat "无法保护 subconverter 私有运行配置"
        return 1
    }
    /bin/cp -- "$BIN_SUBCONVERTER_CONFIG" "$BIN_SUBCONVERTER_RUN_CONFIG" || {
        _errorcat "无法复制 subconverter 运行配置"
        return 1
    }
    chmod 0600 -- "$BIN_SUBCONVERTER_RUN_CONFIG" || return 1
    "$BIN_YQ" -i ".server.port = $BIN_SUBCONVERTER_PORT" "$BIN_SUBCONVERTER_RUN_CONFIG" 2>/dev/null || {
        _errorcat "无法写入 subconverter 私有端口配置"
        return 1
    }

    BIN_SUBCONVERTER_PRIVATE_LOG=$(mktemp "${BIN_SUBCONVERTER_DIR}/.subconverter-log.XXXXXX") || {
        _errorcat "无法创建 subconverter 私有请求日志"
        return 1
    }
    chmod 0600 -- "$BIN_SUBCONVERTER_PRIVATE_LOG" || {
        _errorcat "无法保护 subconverter 私有请求日志"
        return 1
    }
}

_subconverter_process_is_alive() {
    local pid=$1 stat rest state

    kill -0 "$pid" 2>/dev/null || return 1
    IFS= read -r stat <"/proc/$pid/stat" 2>/dev/null || return 1
    rest=${stat##*) }
    [ "$rest" != "$stat" ] || return 1
    state=${rest%% *}
    [ "$state" != Z ] && [ "$state" != X ]
}

_start_convert() {
    BIN_SUBCONVERTER_PID=
    BIN_SUBCONVERTER_RUN_CONFIG=
    BIN_SUBCONVERTER_PRIVATE_LOG=

    [ -x "$BIN_SUBCONVERTER" ] || {
        _errorcat "subconverter 未找到或不可执行：$BIN_SUBCONVERTER"
        return 1
    }
    command -v curl >/dev/null 2>&1 || {
        _errorcat "缺少订阅转换依赖：curl"
        return 1
    }
    [ -r "$BIN_SUBCONVERTER_CONFIG" ] || {
        _errorcat "subconverter 配置不可读：$BIN_SUBCONVERTER_CONFIG"
        return 1
    }
    _subconverter_log_reset || return 1
    _detect_subconverter_port || return 1
    _prepare_subconverter_runtime || {
        _stop_convert
        return 1
    }

    # 每次使用私有配置启动独占实例；既不复用其他实例，也不改写共享 pref.yml。
    local check_url="http://localhost:${BIN_SUBCONVERTER_PORT}/version"
    (
        umask 077
        if declare -F operation_lock_close_fd >/dev/null 2>&1; then
            operation_lock_close_fd || exit 1
        fi
        exec "$BIN_SUBCONVERTER" --file "$BIN_SUBCONVERTER_RUN_CONFIG"
    ) >"$BIN_SUBCONVERTER_PRIVATE_LOG" 2>&1 &
    BIN_SUBCONVERTER_PID=$!

    local start now process_rc
    start=$SECONDS
    while :; do
        if ! _subconverter_process_is_alive "$BIN_SUBCONVERTER_PID"; then
            if wait "$BIN_SUBCONVERTER_PID" 2>/dev/null; then process_rc=0; else process_rc=$?; fi
            BIN_SUBCONVERTER_PID=
            _subconverter_log_event ERROR \
                "实例启动时提前退出（状态 $process_rc，端口 $BIN_SUBCONVERTER_PORT）；请检查依赖版本与 $BIN_SUBCONVERTER_CONFIG" || :
            _errorcat "订阅转换服务启动失败（状态 $process_rc），请检查依赖版本与配置：$BIN_SUBCONVERTER_CONFIG"
            _stop_convert
            return 1
        fi
        if _curl_private_request health /dev/null "$check_url" >/dev/null 2>&1; then
            sleep 0.05
            _subconverter_process_is_alive "$BIN_SUBCONVERTER_PID" && break
        fi
        sleep 0.2
        now=$SECONDS
        [ $((now - start)) -ge 10 ] && {
            _subconverter_log_event ERROR \
                "实例未在 10 秒内就绪（端口 $BIN_SUBCONVERTER_PORT）；请检查依赖版本与 $BIN_SUBCONVERTER_CONFIG" || :
            _errorcat "订阅转换服务未在 10 秒内启动，请检查依赖版本与配置：$BIN_SUBCONVERTER_CONFIG"
            _stop_convert
            return 1
        }
    done
    _subconverter_log_event INFO "实例已就绪（端口 $BIN_SUBCONVERTER_PORT）" || :
}

_stop_convert() {
    local attempt pid cleanup_rc=0

    # 只回收本次独占实例；原始请求日志和私有配置在所有退出路径上销毁。
    if [ -n "${BIN_SUBCONVERTER_PID:-}" ]; then
        pid=$BIN_SUBCONVERTER_PID
        kill -TERM "$pid" 2>/dev/null || :
        for ((attempt = 0; attempt < 10; attempt++)); do
            if ! _subconverter_process_is_alive "$pid"; then
                wait "$pid" 2>/dev/null || :
                pid=
                break
            fi
            sleep 0.02
        done
        if [ -n "$pid" ]; then
            kill -KILL "$pid" 2>/dev/null || :
            wait "$pid" 2>/dev/null || :
        fi
    fi
    BIN_SUBCONVERTER_PID=
    if [ -n "${BIN_SUBCONVERTER_PRIVATE_LOG:-}" ]; then
        if /usr/bin/rm -f -- "$BIN_SUBCONVERTER_PRIVATE_LOG"; then
            BIN_SUBCONVERTER_PRIVATE_LOG=
        else
            _errorcat "无法清理 subconverter 私有请求日志：$BIN_SUBCONVERTER_PRIVATE_LOG" || :
            cleanup_rc=1
        fi
    fi
    if [ -n "${BIN_SUBCONVERTER_RUN_CONFIG:-}" ]; then
        if /usr/bin/rm -f -- "$BIN_SUBCONVERTER_RUN_CONFIG"; then
            BIN_SUBCONVERTER_RUN_CONFIG=
        else
            _errorcat "无法清理 subconverter 私有运行配置：$BIN_SUBCONVERTER_RUN_CONFIG" || :
            cleanup_rc=1
        fi
    fi
    return "$cleanup_rc"
}
