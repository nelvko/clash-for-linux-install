#!/usr/bin/env bash

# 仅支持 bash：sh/dash（curl | sh）执行时给明确提示而非语法乱码
[ -n "${BASH_VERSION:-}" ] || {
    echo "[ERROR] 本安装程序仅支持 Bash：bash install.sh" >&2
    exit 1
}

_INSTALL_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
_REPO=nelvko/clash-for-linux-install
_BRANCH_DEFAULT=master
_INSTALL_STREAM_COMPLETE=0
_INSTALL_SERVICE_TRANSACTION=0
_INSTALL_CONTROLLER_HEADER_FILE=
_INSTALL_STAGE_DIR=
_INSTALL_HOME_STATE=
_INSTALL_TARGET_HOME=
_INSTALL_INCOMPLETE_SUMMARY_SHOWN=0
_INSTALL_MARKER_NAME=.clashctl-installation
[ "${CLASHCTL_INSTALL_SOURCE_ONLY:-}" = 1 ] || trap 'rc=$?; trap - EXIT; if declare -F _install_exit_guard >/dev/null; then _install_exit_guard "$rc"; else printf "%s\n" "[ERROR] 安装脚本下载不完整，未执行安装；请重新下载后再试" >&2; exit 1; fi' EXIT

_install_trusted_git_source() {
    local candidate=$1 root owner mode
    command -v git >/dev/null 2>&1 || return 1
    command -v stat >/dev/null 2>&1 || return 1
    root=$(git -C "$candidate" rev-parse --show-toplevel 2>/dev/null) || return 1
    [ "$root" = "$candidate" ] || return 1
    owner=$(stat -c %u -- "$candidate" 2>/dev/null) || return 1
    mode=$(stat -c %a -- "$candidate" 2>/dev/null) || return 1
    [ "$owner" -eq "$(id -u)" ] || return 1
    [ $((8#$mode & 0022)) -eq 0 ] || return 1
    git -C "$candidate" ls-files --error-unmatch \
        install.sh scripts/preflight.sh scripts/lib/common.sh >/dev/null 2>&1
}

CLASHCTL_SRC=
if [ "$(basename -- "${BASH_SOURCE[0]}")" = install.sh ] &&
    _install_trusted_git_source "$_INSTALL_SCRIPT_DIR"; then
    CLASHCTL_SRC=$_INSTALL_SCRIPT_DIR
fi

_install_exit_guard() {
    local rc=${1:-0}
    trap - EXIT

    if declare -F _install_cleanup_controller_header >/dev/null; then
        _install_cleanup_controller_header || rc=1
    fi
    if [ "${_INSTALL_SERVICE_TRANSACTION:-0}" = 1 ]; then
        if [ -f "${CLASHCTL_HOME:-}/.env" ]; then
            if declare -F _install_end_service_transaction >/dev/null; then
                _install_end_service_transaction || rc=1
            else
                printf '%s\n' '[ERROR] 安装已提交，但无法安全清理服务事务' >&2
                rc=1
            fi
        else
            printf '%s\n' '[WARN] 安装在服务配置提交前中止，正在恢复原服务状态' >&2
            _install_restore_service || rc=1
            rc=1
        fi
    fi
    if [ -n "${_INSTALL_STAGE_DIR:-}" ] &&
        declare -F _install_discard_stage >/dev/null; then
        _install_discard_stage "$_INSTALL_STAGE_DIR" || rc=1
    fi
    if [ "$rc" -ne 0 ] && [ "${_INSTALL_STREAM_COMPLETE:-0}" = 1 ] &&
        declare -F _install_report_incomplete_home >/dev/null; then
        _install_report_incomplete_home || true
    fi
    if [ "${_INSTALL_STREAM_COMPLETE:-0}" != 1 ]; then
        printf '%s\n' '[ERROR] 安装脚本下载不完整，未执行安装；请重新下载后再试' >&2
        rc=1
    fi
    exit "$rc"
}

# install.sh 需要在源码下载前独立输出；进入安装目录后由 common.sh 提供同名实现。
_ui_color_enabled() {
    local fd=${1:-2}
    [ "${NO_COLOR+x}" != x ] || return 1
    case ${CLASHCTL_COLOR:-auto} in
    always) return 0 ;;
    never) return 1 ;;
    esac
    [ "${CI+x}" != x ] || return 1
    [ "${TERM:-dumb}" != dumb ] || return 1
    [ -t "$fd" ]
}

_ui_emit() {
    local level=${1:-info}
    [ $# -gt 0 ] && shift
    local msg="$*" prefix color
    case $level in
    step) prefix='[STEP]' color=36 ;;
    ok) prefix='[ OK ]' color=32 ;;
    warn) prefix='[WARN]' color=33 ;;
    error) prefix='[ERROR]' color=31 ;;
    question) prefix='[ ? ]' color=35 ;;
    header) prefix='[INFO]' color='1;36' ;;
    info | *) prefix='[INFO]' color=36 ;;
    esac
    if _ui_color_enabled 2; then
        printf '\033[%sm%s\033[0m %s\n' "$color" "$prefix" "$msg" >&2
    else
        printf '%s %s\n' "$prefix" "$msg" >&2
    fi
    return 0
}

_ui_step() { _ui_emit step "$*"; }
_ui_info() { _ui_emit info "$*"; }
_ui_ok() { _ui_emit ok "$*"; }
_ui_warn() { _ui_emit warn "$*"; }
_ui_error() { _ui_emit error "$*"; }
_ui_header() { _ui_emit header "$*"; }
_ui_blank() { printf '\n' >&2; }
_ui_detail() {
    local label=${1:-}
    [ $# -gt 0 ] && shift
    [ $# -gt 0 ] && printf '        %s: %s\n' "$label" "$*" >&2 || printf '        %s\n' "$label" >&2
    return 0
}
_ui_confirm() {
    local prompt=${1:-} answer
    [ "${CI+x}" != x ] && [ -t 0 ] && [ -t 2 ] || return 2
    if _ui_color_enabled 2; then
        printf '\033[35m[ ? ]\033[0m %s [y/N] ' "$prompt" >&2
    else
        printf '[ ? ] %s [y/N] ' "$prompt" >&2
    fi
    IFS= read -r answer || {
        printf '\n' >&2
        return 1
    }
    case $answer in
    y | Y | yes | YES | Yes) return 0 ;;
    *) return 1 ;;
    esac
}

# Bash 局部变量会继承同名 export 属性；同时清除当前局部与被遮蔽全局的导出状态。
_install_private_locals() {
    local variable
    for variable in "$@"; do
        declare -g +x "$variable"
        export -n "${variable?}"
    done
}

_install_has_control_chars() {
    local value=$1 cleaned
    _install_private_locals value
    cleaned=$(printf '%s' "$value" | LC_ALL=C tr -d '\001-\037\177')
    [ "$cleaned" != "$value" ]
}

_install_validate_input() {
    local label=$1 value=$2
    _install_private_locals value
    if _install_has_control_chars "$value"; then
        _ui_error "${label}不能包含控制字符"
        return 1
    fi
}

_install_generate_secret() {
    local secret='' part='' _
    _install_private_locals secret part
    for _ in {1..8}; do
        part=$(_get_random_val) || return 1
        case $part in '' | *[!a-zA-Z0-9]*) return 1 ;; esac
        secret+=$part
        if [ "${#secret}" -ge 32 ]; then
            printf '%s' "${secret:0:32}"
            return 0
        fi
    done
    return 1
}

_install_read_subscription_file() {
    local file=$1 fd path_identity fd_identity owner mode size value='' raw=''
    local before after nul_found=0
    _install_private_locals value raw
    if [ ! -f "$file" ] || [ -L "$file" ]; then
        _ui_error '订阅输入文件必须是普通文件且不能是符号链接'
        return 1
    fi
    exec {fd}<"$file" || {
        _ui_error '无法打开订阅输入文件'
        return 1
    }
    path_identity=$(stat -c '%d:%i' -- "$file" 2>/dev/null) || path_identity=
    fd_identity=$(stat -Lc '%d:%i' -- "/proc/self/fd/$fd" 2>/dev/null) || fd_identity=
    if [ -z "$path_identity" ] || [ "$path_identity" != "$fd_identity" ] || [ -L "$file" ]; then
        exec {fd}<&-
        _ui_error '订阅输入文件在打开期间发生变化，拒绝继续'
        return 1
    fi
    before=$(stat -Lc '%d:%i:%u:%a:%s:%y:%z' -- "/proc/self/fd/$fd" 2>/dev/null) || {
        exec {fd}<&-
        return 1
    }
    owner=$(stat -Lc %u -- "/proc/self/fd/$fd" 2>/dev/null) || {
        exec {fd}<&-
        return 1
    }
    mode=$(stat -Lc %a -- "/proc/self/fd/$fd" 2>/dev/null) || {
        exec {fd}<&-
        return 1
    }
    size=$(stat -Lc %s -- "/proc/self/fd/$fd" 2>/dev/null) || {
        exec {fd}<&-
        return 1
    }
    if [ "$owner" -ne "$(id -u)" ] || { [ "$mode" != 400 ] && [ "$mode" != 600 ]; }; then
        exec {fd}<&-
        _ui_error '订阅输入文件的归属或权限不安全'
        _ui_detail '要求' "归当前 uid=$(id -u) 所有，权限必须为 0400 或 0600"
        return 1
    fi
    if [ "$size" -eq 0 ] || [ "$size" -gt 16384 ]; then
        exec {fd}<&-
        _ui_error '订阅输入文件为空或超过 16 KiB 限制'
        return 1
    fi
    if IFS= read -r -d '' -u "$fd" raw; then
        nul_found=1
    fi
    after=$(stat -Lc '%d:%i:%u:%a:%s:%y:%z' -- "/proc/self/fd/$fd" 2>/dev/null) || after=
    exec {fd}<&-
    if [ "$before" != "$after" ]; then
        _ui_error '订阅输入文件在读取期间发生变化，拒绝继续'
        return 1
    fi
    if [ "$nul_found" -eq 1 ]; then
        _ui_error '订阅输入文件包含 NUL 字节'
        return 1
    fi
    case $raw in *$'\n') value=${raw%$'\n'} ;; *) value=$raw ;; esac
    if [[ $value == *$'\n'* ]]; then
        _ui_error '订阅输入文件只能包含一行 URL'
        return 1
    fi
    if [ -z "$value" ]; then
        _ui_error '订阅输入文件中的 URL 不能为空'
        return 1
    fi
    _install_validate_input '订阅链接' "$value" || return 1
    printf '%s' "$value"
}

_install_reexec() {
    local script=$1 home=$2 branch=$3 kernel=$4 subscription_file=${5:-}
    local -a args=(--home "$home" --branch "$branch")
    [ -z "$subscription_file" ] || args+=(--subscription-file "$subscription_file")
    args+=("$kernel")
    exec bash "$script" "${args[@]}"
}

# 主体包进 main 函数：管道/下载截断只拿到半截时，bash 解析未闭合函数直接报语法错误、零执行
main() {
    umask 077
    local home=${CLASHCTL_HOME:-} branch=${CLASHCTL_UPDATE_BRANCH:-$_BRANCH_DEFAULT}
    local kernel=${CLASHCTL_KERNEL:-mihomo} sub_url=
    local proxy=${GH_PROXY-https://gh-proxy.org} home_source=default
    local source_dir=${CLASHCTL_LOCAL_SOURCE:-$CLASHCTL_SRC}
    local subscription_file=${CLASHCTL_SUBSCRIPTION_FILE:-} install_arg
    _install_private_locals sub_url
    [ -z "${CLASHCTL_HOME:-}" ] || home_source=CLASHCTL_HOME

    if [ -n "${CLASHCTL_SUB_URL:-}" ]; then
        _ui_error '不再支持通过 CLASHCTL_SUB_URL 传递订阅链接，以免泄漏到子进程环境'
        _ui_detail '自动化' '改用 --subscription-file <0600 文件>'
        _ui_detail '交互安装' '不提供订阅参数，稍后在隐藏输入提示中填写'
        return 1
    fi

    for install_arg in "$@"; do
        _install_validate_input '命令行参数' "$install_arg" || return 1
    done

    while [ $# -gt 0 ]; do
        case $1 in
        mihomo | clash) kernel=$1 ;;
        http://* | https://* | file://*)
            _ui_error '不再支持把订阅链接直接放入命令行，以免写入 Shell 历史或进程参数'
            _ui_detail '自动化' '将 URL 写入权限为 0600 的单行文件，再使用 --subscription-file'
            _ui_detail '交互安装' '省略订阅参数，稍后在隐藏输入提示中填写'
            return 1
            ;;
        --home)
            shift
            [ $# -gt 0 ] || {
                _ui_error '--home 缺少路径参数'
                return 1
            }
            home=$1 home_source=--home
            ;;
        --home=*)
            home=${1#*=}
            [ -n "$home" ] || {
                _ui_error '--home 缺少路径参数'
                return 1
            }
            home_source=--home
            ;;
        --branch)
            shift
            [ $# -gt 0 ] || {
                _ui_error '--branch 缺少分支参数'
                return 1
            }
            branch=$1
            ;;
        --branch=*)
            branch=${1#*=}
            [ -n "$branch" ] || {
                _ui_error '--branch 缺少分支参数'
                return 1
            }
            ;;
        --source-dir)
            shift
            [ $# -gt 0 ] || {
                _ui_error '--source-dir 缺少路径参数'
                return 1
            }
            source_dir=$1
            ;;
        --source-dir=*)
            source_dir=${1#*=}
            [ -n "$source_dir" ] || {
                _ui_error '--source-dir 缺少路径参数'
                return 1
            }
            ;;
        --subscription-file)
            shift
            [ $# -gt 0 ] || {
                _ui_error '--subscription-file 缺少文件路径'
                return 1
            }
            subscription_file=$1
            ;;
        --subscription-file=*)
            subscription_file=${1#*=}
            [ -n "$subscription_file" ] || {
                _ui_error '--subscription-file 缺少文件路径'
                return 1
            }
            ;;
        --allow-legacy-layout) CLASHCTL_ALLOW_LEGACY_LAYOUT=1 ;;
        --take-over-service) CLASHCTL_ALLOW_UNIT_OVERWRITE=1 ;;
        --non-interactive) CLASHCTL_NON_INTERACTIVE=1 ;;
        --verbose) CLASHCTL_VERBOSE=1 ;;
        --no-color) CLASHCTL_COLOR=never ;;
        --color)
            shift
            [ $# -gt 0 ] || {
                _ui_error '--color 缺少模式参数: auto、always 或 never'
                return 1
            }
            CLASHCTL_COLOR=$1
            ;;
        --color=*) CLASHCTL_COLOR=${1#*=} ;;
        -h | --help)
            usage
            return 0
            ;;
        *)
            case ${1,,} in
            http://* | https://* | file://*)
                _ui_error '不再支持把订阅链接直接放入命令行，以免写入 Shell 历史或进程参数'
                _ui_detail '自动化' '将 URL 写入权限为 0600 的单行文件，再使用 --subscription-file'
                ;;
            *)
                _ui_error '存在未知参数；参数内容未回显'
                ;;
            esac
            usage >&2
            return 1
            ;;
        esac
        shift
    done
    [ -n "$home" ] || home="${HOME}/.clashctl"
    _install_validate_input '安装路径' "$home" || return 1
    _install_validate_input '分支名称' "$branch" || return 1
    _install_validate_input '订阅输入文件' "$subscription_file" || return 1
    _install_validate_input '本地源码路径' "$source_dir" || return 1
    _install_validate_input '下载代理地址' "$proxy" || return 1
    _install_validate_input '用户主目录' "${HOME:-}" || return 1
    if [ "${CLASHCTL_UPDATE_GIT_URL+x}" = x ]; then
        _install_validate_input 'Git 下载地址' "$CLASHCTL_UPDATE_GIT_URL" || return 1
    fi
    home=$(_install_absolute_path "$home") || {
        _ui_error "无法解析安装路径: $home"
        return 1
    }
    _INSTALL_TARGET_HOME=$home
    if [ -z "$source_dir" ] && [ "$_INSTALL_SCRIPT_DIR" = "$home" ] &&
        _install_marker_validate "$home"; then
        source_dir=$home
    fi
    if [ -n "$source_dir" ]; then
        source_dir=$(_install_absolute_path "$source_dir") || {
            _ui_error "无法解析本地源码路径: $source_dir"
            return 1
        }
        if [ ! -f "$source_dir/install.sh" ] || [ ! -f "$source_dir/scripts/preflight.sh" ]; then
            _ui_error "本地源码目录不完整: $source_dir"
            return 1
        fi
        if ! _install_layout_is_trusted "$source_dir"; then
            _ui_error '本地源码目录的脚本归属、权限或结构不安全'
            _ui_detail '目录' "$source_dir"
            return 1
        fi
        CLASHCTL_SRC=$source_dir
        export CLASHCTL_LOCAL_SOURCE=$source_dir
    fi
    if [ -n "$subscription_file" ]; then
        subscription_file=$(_install_absolute_path "$subscription_file") || {
            _ui_error '无法解析 --subscription-file 指定的路径'
            return 1
        }
        sub_url=$(_install_read_subscription_file "$subscription_file") || return 1
    fi
    _install_validate_input '订阅链接' "$sub_url" || return 1
    _install_validate_home_path "$home" "$source_dir" || return 1
    case ${CLASHCTL_COLOR:-auto} in
    auto | always | never) ;;
    *)
        _ui_error "无效颜色模式: ${CLASHCTL_COLOR}（可选 auto、always、never）"
        return 1
        ;;
    esac
    export CLASHCTL_COLOR
    [ -z "${CLASHCTL_VERBOSE:-}" ] || export CLASHCTL_VERBOSE
    [ -z "${CLASHCTL_NON_INTERACTIVE:-}" ] || export CLASHCTL_NON_INTERACTIVE
    [ -z "${CLASHCTL_ALLOW_UNIT_OVERWRITE:-}" ] || export CLASHCTL_ALLOW_UNIT_OVERWRITE
    [ -z "${CLASHCTL_ALLOW_LEGACY_LAYOUT:-}" ] || export CLASHCTL_ALLOW_LEGACY_LAYOUT
    case ${sub_url,,} in
    '' | http://* | https://* | file://*) ;;
    *)
        _ui_error '订阅链接必须以 http://、https:// 或 file:// 开头'
        return 1
        ;;
    esac
    case $kernel in
    mihomo | clash) ;;
    *)
        _ui_error "不支持的内核: $kernel（可选 mihomo 或 clash）"
        return 1
        ;;
    esac

    local install_manager
    install_manager=$(_install_detect_service_manager)
    if [ "${CLASHCTL_INSTALL_SESSION:-}" != 1 ]; then
        _install_plan "$home" "$home_source" "$kernel" "$branch" \
            "$install_manager" "$sub_url" "$source_dir"
        export CLASHCTL_INSTALL_SESSION=1
    fi

    # 先验证目标目录，再询问或执行任何接管操作。
    _require_empty_home "$home" || return 1

    if [ "$_INSTALL_HOME_STATE" = resume ]; then
        if [ -z "$CLASHCTL_SRC" ] || [ "$CLASHCTL_SRC" != "$home" ]; then
            _install_refuse_incomplete_source_change \
                "$home" "$branch" "$kernel" "$subscription_file"
            return 1
        fi
        _ui_info "使用未完成目录内已验证的程序文件继续安装: $home"
    fi

    unset CLASHCTL_SUBSCRIPTION_FILE CLASHCTL_SUB_URL

    if [ -z "$CLASHCTL_SRC" ]; then
        local download_stage
        _install_create_stage "$home" download_stage || return 1
        if ! _fetch_into "$download_stage" "$branch" "$proxy" ||
            ! _install_finalize_stage "$download_stage" "$home"; then
            _install_discard_stage "$download_stage" || true
            return 1
        fi
        export CLASHCTL_LOCAL_SOURCE=$home
        _install_reexec "${home}/install.sh" "$home" "$branch" "$kernel" "$subscription_file"
    fi

    if [ "${CLASHCTL_SRC}" != "$home" ]; then
        local source_stage
        _install_create_stage "$home" source_stage || return 1
        _ui_step '准备安装文件'
        if command -v git >/dev/null 2>&1 && [ -d "${CLASHCTL_SRC}/.git" ]; then
            _ui_detail '本地源码' "$CLASHCTL_SRC"
            local -a clone_args=(-q)
            [ ! -t 2 ] || [ "${CLASHCTL_VERBOSE:-}" != 1 ] || clone_args+=(--progress)
            git clone "${clone_args[@]}" "$CLASHCTL_SRC" "$source_stage" || {
                _ui_error '复制本地 Git 仓库失败'
                _install_discard_stage "$source_stage" || true
                return 1
            }
        else
            _ui_detail '本地源码' "$CLASHCTL_SRC"
            cp -a -- "$CLASHCTL_SRC"/. "$source_stage"/ || {
                _ui_error '复制本地源码失败'
                _install_discard_stage "$source_stage" || true
                return 1
            }
        fi
        if ! _install_finalize_stage "$source_stage" "$home"; then
            _install_discard_stage "$source_stage" || true
            return 1
        fi
        _ui_ok '安装文件已就绪'
        export CLASHCTL_LOCAL_SOURCE=$home
        _install_reexec "${home}/install.sh" "$home" "$branch" "$kernel" "$subscription_file"
    fi

    export CLASHCTL_HOME="$home"
    . "${CLASHCTL_SRC}/scripts/lib/operation-lock.sh" || {
        _ui_error '加载操作锁模块失败，未修改共享状态'
        return 1
    }
    operation_lock_acquire || return 1
    . "${CLASHCTL_SRC}/scripts/lib/common.sh" || {
        _ui_error '加载安装公共库失败'
        return 1
    }
    export CLASHCTL_KERNEL="$kernel" CLASHCTL_UPDATE_BRANCH="$branch"
    . "${CLASHCTL_SRC}/scripts/preflight.sh" || {
        _ui_error '加载安装预检模块失败'
        return 1
    }
    detect_service_manager
    install_manager=$service_manager

    if [ -f "${CLASHCTL_HOME}/.service-transaction" ]; then
        _ui_step '恢复上次中断的服务事务'
        _install_journal_load "${CLASHCTL_HOME}/.service-transaction" || {
            _ui_error '服务事务快照无效，拒绝继续安装'
            _ui_detail '快照' "${CLASHCTL_HOME}/.service-transaction"
            return 1
        }
        INIT_TYPE=$CLASHCTL_SERVICE_MANAGER
        service_manager=
        export INIT_TYPE
        _INSTALL_SERVICE_TRANSACTION=1
        if ! _install_restore_service; then
            _INSTALL_SERVICE_TRANSACTION=0
            return 1
        fi
        _INSTALL_SERVICE_TRANSACTION=0
        service_manager=
        detect_service_manager
        install_manager=$service_manager
        _ui_ok '上次中断的服务事务已恢复'
    fi

    _ui_step '检查系统环境'
    valid_required || return 1
    _ui_ok "环境检查通过: Linux/$(uname -m) · ${install_manager}"

    _install_impact_scan "$home" "$kernel" "$install_manager" || return 1

    if [ -z "$sub_url" ] && [ "${CLASHCTL_NON_INTERACTIVE:-}" != 1 ] &&
        [ "${CI+x}" != x ] && [ -t 0 ] && [ -t 2 ]; then
        sub_url=$(_install_read_subscription) || return 1
        [ -z "$sub_url" ] || _ui_info '已接收初始订阅（链接不会写入安装输出）'
    fi

    _ui_step '准备运行组件'
    /usr/bin/install -d -m 0700 "$CLASH_DATA_DIR" "${CLASH_DATA_DIR}/profiles" || {
        _ui_error "无法创建数据目录: $CLASH_DATA_DIR"
        return 1
    }
    if [ ! -f "${CLASH_CONFIG_MIXIN}" ] &&
        ! /usr/bin/install -m 0600 "${CLASH_RESOURCES_DIR}/mixin.yaml.example" "${CLASH_CONFIG_MIXIN}"; then
        _ui_error "无法初始化 Mixin 配置: $CLASH_CONFIG_MIXIN"
        return 1
    fi
    if [ ! -f "${CLASH_PROFILES_META}" ] &&
        ! /usr/bin/install -m 0600 "${CLASH_RESOURCES_DIR}/profiles.yaml" "${CLASH_PROFILES_META}"; then
        _ui_error "无法初始化订阅元数据: $CLASH_PROFILES_META"
        return 1
    fi
    touch "$CLASH_CONFIG_BASE" || {
        _ui_error "无法创建基础配置: $CLASH_CONFIG_BASE"
        return 1
    }
    chmod 0600 "$CLASH_CONFIG_BASE" "$CLASH_CONFIG_MIXIN" "$CLASH_PROFILES_META" || {
        _ui_error '无法收紧配置文件权限'
        return 1
    }
    prepare_zip || return 1
    _ui_ok '运行组件已准备完成'

    _load_install_commands || return 1

    _ui_step '初始化运行配置'
    _merge_config || return 1
    _detect_proxy_port || return 1
    _detect_ext_addr || return 1
    local existing_secret
    _install_private_locals existing_secret
    existing_secret=$(_get_secret) || {
        _ui_error '无法读取 Web 访问密钥'
        return 1
    }
    if [ -z "$existing_secret" ]; then
        local generated_secret
        _install_private_locals generated_secret
        generated_secret=$(_install_generate_secret) || {
            _ui_error '无法生成 Web 访问密钥'
            return 1
        }
        SECRET=$generated_secret "$BIN_YQ" -i '.secret = env(SECRET)' "$CLASH_CONFIG_MIXIN" || {
            _ui_error '无法生成 Web 访问密钥'
            return 1
        }
        unset generated_secret
        _merge_config || return 1
        _ui_ok 'Web 访问密钥已生成（不会在输出中显示）'
    else
        _ui_ok '已保留现有 Web 访问密钥'
    fi
    _ui_ok '运行配置校验通过'

    _ui_step "配置 ${install_manager} 服务"
    _install_begin_service_transaction || return 1
    if ! _install_stop_existing_service; then
        _install_abort_service_transaction || true
        return 1
    fi
    if ! install_service; then
        _install_abort_service_transaction || true
        return 1
    fi
    if ! _install_capture_installed_enablement; then
        _install_abort_service_transaction || true
        return 1
    fi
    local service_error="${CLASH_DATA_DIR}/install-service-error.log"
    if ! service_start >"$service_error" 2>&1; then
        chmod 0600 "$service_error" 2>/dev/null || true
        _ui_error "启动 $kernel 服务失败"
        _install_service_diagnostic "$install_manager" "$service_error"
        _install_abort_service_transaction || true
        return 1
    fi
    /usr/bin/rm -f -- "$service_error"
    _install_wait_service || {
        _install_service_diagnostic "$install_manager" "$service_error"
        _install_abort_service_transaction || true
        return 1
    }
    _ui_ok "$kernel 服务已启动"

    _install_wait_controller || {
        _ui_error '控制器未在预期时间内响应'
        _install_service_diagnostic "$install_manager" "$service_error"
        _install_abort_service_transaction || true
        return 1
    }

    local subscription_status='未配置' current_subscription current_url=
    _install_private_locals current_url
    current_subscription=$(_sub_current) || {
        _ui_error '读取订阅状态失败'
        _install_abort_service_transaction || true
        return 1
    }
    if [ -n "$current_subscription" ]; then
        current_url=$(_sub_get "$current_subscription" url) || {
            _ui_error '读取当前订阅信息失败'
            _install_abort_service_transaction || true
            return 1
        }
    fi
    if [ -n "$sub_url" ] && [ -n "$current_subscription" ] &&
        [ "$current_url" = "$sub_url" ]; then
        subscription_status=$current_subscription
        _ui_info "初始订阅已存在并保持生效: [$subscription_status]"
    elif [ -n "$sub_url" ]; then
        _ui_step '配置初始订阅'
        if ! clashsub add --use "$sub_url" >/dev/null; then
            _ui_error '初始订阅未能生效；安装已中止，正在恢复安装前的服务状态'
            _ui_detail '调试文件' "$CLASH_CONFIG_DEBUG"
            _install_abort_service_transaction || true
            return 1
        fi
        subscription_status=$(_sub_current) || {
            _ui_error '初始订阅已写入，但无法确认当前订阅；安装已中止，正在恢复服务状态'
            _install_abort_service_transaction || true
            return 1
        }
        if [ -z "$subscription_status" ]; then
            _ui_error '初始订阅已写入，但未被设为当前订阅；安装已中止，正在恢复服务状态'
            _install_abort_service_transaction || true
            return 1
        fi
        _ui_ok "初始订阅已生效: [$subscription_status]"
    elif [ -n "$current_subscription" ]; then
        subscription_status=$current_subscription
        _ui_info "保留上次安装已写入的订阅: [$subscription_status]"
    elif _valid_config "$CLASH_CONFIG_BASE"; then
        subscription_status='本地配置'
        _ui_info '保留上次安装留下的本地配置'
    else
        _ui_warn '未配置初始订阅；安装后可使用 clashctl sub add <URL> 添加'
    fi

    _ui_step '验证并完成安装'
    _install_wait_controller || {
        _ui_error '应用初始配置后，控制器未能响应'
        _install_service_diagnostic "$install_manager" "$service_error"
        _install_abort_service_transaction || true
        return 1
    }
    if ! _write_install_env "$kernel" "$branch"; then
        _install_abort_service_transaction || true
        return 1
    fi
    local transaction_state=complete
    _install_end_service_transaction || transaction_state=incomplete

    _install_finish "$install_manager" "$subscription_status" "$transaction_state"
}

_install_plan() {
    local home=$1 home_source=$2 kernel=$3 branch=$4 manager=$5 sub_url=$6 source_dir=${7:-}
    local privilege="普通用户 (uid=$(id -u))" service_name=$kernel
    local source="${_REPO} · ${branch}" service_target='' shell_plan shell_target
    local service_action='启动后台进程并验证；不配置系统级开机自启'
    local -a shell_targets=()
    case $home_source in
    default) home_source=默认 ;;
    CLASHCTL_HOME) home_source=CLASHCTL_HOME ;;
    --home) home_source='--home' ;;
    esac
    [ "$(id -u)" -ne 0 ] || privilege=root
    [ "$manager" != systemd ] || service_name="${kernel}.service"
    [ -z "$source_dir" ] || source="本地源码 · ${source_dir}"
    if service_target=$(_install_service_target "$manager" "$kernel"); then
        service_action='写入服务定义 · 设置开机自启 · 启动并验证'
    else
        service_target='不写入系统服务定义'
    fi
    command -v bash >/dev/null 2>&1 && [ -f "${HOME}/.bashrc" ] &&
        shell_targets+=("${HOME}/.bashrc")
    command -v zsh >/dev/null 2>&1 && [ -f "${HOME}/.zshrc" ] &&
        shell_targets+=("${HOME}/.zshrc")
    command -v fish >/dev/null 2>&1 &&
        shell_targets+=("${HOME}/.config/fish/conf.d/clashctl.fish")
    if [ ${#shell_targets[@]} -gt 0 ]; then
        shell_plan=${shell_targets[0]}
        for shell_target in "${shell_targets[@]:1}"; do
            shell_plan+=" · ${shell_target}"
        done
    else
        shell_plan='未检测到可更新的启动文件；安装后提供手动加载命令'
    fi

    _ui_blank
    _ui_header 'clashctl 安装计划'
    _ui_detail '来源' "$source"
    _ui_detail '系统' "Linux/$(uname -m) · ${privilege}"
    _ui_detail '程序目录' "${home}（${home_source}）"
    _ui_detail '运行数据' "${home}/data（配置、订阅、运行文件与诊断文件）"
    _ui_detail '代理内核' "$kernel"
    _ui_detail '服务管理' "$manager · $service_name"
    _ui_detail '服务定义' "$service_target"
    _ui_detail '服务动作' "$service_action"
    _ui_detail 'Shell 集成' "$shell_plan"
    if [ -n "$sub_url" ]; then
        _ui_detail '初始订阅' '已提供（链接已隐藏）'
    elif [ "${CLASHCTL_NON_INTERACTIVE:-}" = 1 ] || [ "${CI+x}" = x ] ||
        [ ! -t 0 ] || [ ! -t 2 ]; then
        _ui_detail '初始订阅' '未提供；本次将跳过'
    else
        _ui_detail '初始订阅' '执行前隐藏输入（可留空跳过）'
    fi
    _ui_blank
}

_install_absolute_path() {
    local path=$1 component normalized=/ separator='' probe suffix='' physical
    local -a components=() stack=()

    case $path in
    /*) ;;
    *) path="${PWD}/${path}" ;;
    esac
    IFS=/ read -r -a components <<<"$path"
    for component in "${components[@]}"; do
        case $component in
        '' | .) ;;
        ..)
            if [ ${#stack[@]} -gt 0 ]; then
                unset 'stack[${#stack[@]}-1]'
            fi
            ;;
        *) stack+=("$component") ;;
        esac
    done
    for component in "${stack[@]}"; do
        normalized+="${separator}${component}"
        separator=/
    done

    probe=$normalized
    while [ ! -d "$probe" ]; do
        [ "$probe" != / ] || return 1
        component=${probe##*/}
        suffix="/${component}${suffix}"
        probe=${probe%/*}
        [ -n "$probe" ] || probe=/
    done
    physical=$(cd -P -- "$probe" && pwd -P) || return 1
    if [ "$physical" = / ]; then
        printf '/%s\n' "${suffix#/}"
    else
        printf '%s%s\n' "$physical" "$suffix"
    fi
}

_install_owned_directory() {
    local path=$1 owner mode
    [ -d "$path" ] && [ ! -L "$path" ] || return 1
    owner=$(stat -c %u -- "$path" 2>/dev/null) || return 1
    mode=$(stat -c %a -- "$path" 2>/dev/null) || return 1
    [ "$owner" -eq "$(id -u)" ] && [ $((8#$mode & 0022)) -eq 0 ]
}

_install_owned_file() {
    local path=$1 owner mode
    [ -f "$path" ] && [ ! -L "$path" ] || return 1
    owner=$(stat -c %u -- "$path" 2>/dev/null) || return 1
    mode=$(stat -c %a -- "$path" 2>/dev/null) || return 1
    [ "$owner" -eq "$(id -u)" ] && [ $((8#$mode & 0022)) -eq 0 ]
}

_install_layout_is_trusted() {
    local home=$1 path unsafe uid
    local -a required=(
        "$home/install.sh"
        "$home/uninstall.sh"
        "$home/scripts/preflight.sh"
        "$home/scripts/lib/common.sh"
    )
    _install_owned_directory "$home" || return 1
    for path in "${required[@]}"; do
        _install_owned_file "$path" || return 1
    done
    if [ -e "$home/.env" ] || [ -L "$home/.env" ]; then
        _install_owned_file "$home/.env" || return 1
    fi
    uid=$(id -u)
    unsafe=$(find "$home/scripts" \
        \( -type l -o ! -user "$uid" -o -perm /022 \) -print -quit 2>/dev/null) || return 1
    [ -z "$unsafe" ]
}

_install_marker_validate() {
    local directory=$1 expected_home=${2:-$1}
    local marker="$directory/$_INSTALL_MARKER_NAME" owner mode line key value
    local -A marker_values=() marker_seen=()

    [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
    owner=$(stat -c %u -- "$marker" 2>/dev/null) || return 1
    mode=$(stat -c %a -- "$marker" 2>/dev/null) || return 1
    [ "$owner" -eq "$(id -u)" ] && [ "$mode" = 600 ] || return 1

    while IFS= read -r line || [ -n "$line" ]; do
        case $line in *=*) ;; *) return 1 ;; esac
        key=${line%%=*}
        value=${line#*=}
        case $key in
        CLASHCTL_INSTALLATION | CLASHCTL_INSTALLATION_FORMAT | CLASHCTL_INSTALLATION_HOME | CLASHCTL_INSTALLATION_UID)
            [ "${marker_seen[$key]:-0}" -eq 0 ] || return 1
            _install_has_control_chars "$value" && return 1
            marker_values[$key]=$value
            marker_seen[$key]=1
            ;;
        *) return 1 ;;
        esac
    done <"$marker"

    [ "${marker_seen[CLASHCTL_INSTALLATION]:-0}" -eq 1 ] &&
        [ "${marker_seen[CLASHCTL_INSTALLATION_FORMAT]:-0}" -eq 1 ] &&
        [ "${marker_seen[CLASHCTL_INSTALLATION_HOME]:-0}" -eq 1 ] &&
        [ "${marker_seen[CLASHCTL_INSTALLATION_UID]:-0}" -eq 1 ] &&
        [ "${marker_values[CLASHCTL_INSTALLATION]}" = clashctl ] &&
        [ "${marker_values[CLASHCTL_INSTALLATION_FORMAT]}" = 1 ] &&
        [ "${marker_values[CLASHCTL_INSTALLATION_HOME]}" = "$expected_home" ] &&
        [ "${marker_values[CLASHCTL_INSTALLATION_UID]}" = "$(id -u)" ]
}

_install_marker_write() {
    local directory=$1 canonical_home=${2:-$1}
    local marker="$directory/$_INSTALL_MARKER_NAME" tmp
    _install_owned_directory "$directory" || return 1
    _install_validate_input '安装标记路径' "$canonical_home" || return 1
    tmp=$(mktemp "${marker}.tmp.XXXXXX") || return 1
    chmod 0600 "$tmp" || {
        /usr/bin/rm -f -- "$tmp"
        return 1
    }
    {
        printf 'CLASHCTL_INSTALLATION=clashctl\n'
        printf 'CLASHCTL_INSTALLATION_FORMAT=1\n'
        printf 'CLASHCTL_INSTALLATION_HOME=%s\n' "$canonical_home"
        printf 'CLASHCTL_INSTALLATION_UID=%s\n' "$(id -u)"
    } >"$tmp" || {
        /usr/bin/rm -f -- "$tmp"
        return 1
    }
    /bin/mv -f -- "$tmp" "$marker" || {
        /usr/bin/rm -f -- "$tmp"
        return 1
    }
    _install_marker_validate "$directory" "$canonical_home"
}

_install_validate_home_path() {
    local home=$1 source_dir=${2:-} canonical_user_home=
    case $home in
    / | /bin | /boot | /dev | /etc | /home | /lib | /lib32 | /lib64 | /media | /mnt | /opt | \
        /proc | /root | /run | /sbin | /srv | /sys | /tmp | /usr | /var)
        _ui_error "安装路径指向系统关键目录，拒绝继续: $home"
        return 1
        ;;
    esac
    if [ -n "${HOME:-}" ]; then
        canonical_user_home=$(_install_absolute_path "$HOME") || canonical_user_home=
        if [ -n "$canonical_user_home" ] && [ "$home" = "$canonical_user_home" ]; then
            _ui_error '安装路径不能是整个用户主目录'
            _ui_detail '建议路径' "${canonical_user_home}/.clashctl"
            return 1
        fi
    fi
    if [ -n "$source_dir" ]; then
        if [ "$home" = "$source_dir" ] &&
            { [ "${CLASHCTL_INSTALL_SESSION:-0}" = 1 ] || [ "$_INSTALL_SCRIPT_DIR" = "$home" ]; } &&
            _install_marker_validate "$home"; then
            return 0
        fi
        case $home in
        "$source_dir" | "$source_dir"/*)
            _ui_error '安装目录不能等于或位于源码目录内部'
            _ui_detail '源码目录' "$source_dir"
            return 1
            ;;
        esac
        case $source_dir in
        "$home"/*)
            _ui_error '安装目录不能包含当前源码目录'
            _ui_detail '源码目录' "$source_dir"
            return 1
            ;;
        esac
    fi
}

_install_create_stage() {
    local home=$1 output_var=$2 parent created_stage
    parent=$(dirname -- "$home")
    if [ ! -e "$parent" ]; then
        /usr/bin/install -d -m 0700 -- "$parent" || {
            _ui_error "无法创建安装目录的父目录: $parent"
            return 1
        }
    fi
    if [ ! -d "$parent" ] || [ ! -w "$parent" ] || [ ! -x "$parent" ]; then
        _ui_error "安装目录的父目录不可写: $parent"
        return 1
    fi
    created_stage=$(mktemp -d "${home}.installing.XXXXXX") || {
        _ui_error '无法创建安装暂存目录'
        return 1
    }
    chmod 0700 "$created_stage" || {
        /usr/bin/rm -rf -- "$created_stage"
        return 1
    }
    _INSTALL_STAGE_DIR=$created_stage
    printf -v "$output_var" '%s' "$created_stage"
}

_install_discard_stage() {
    local stage=${1:-${_INSTALL_STAGE_DIR:-}} owner mode
    [ -n "$stage" ] && [ "$stage" = "${_INSTALL_STAGE_DIR:-}" ] || return 1
    case ${stage##*/} in *.installing.*) ;; *) return 1 ;; esac
    [ -d "$stage" ] && [ ! -L "$stage" ] || return 1
    owner=$(stat -c %u -- "$stage" 2>/dev/null) || return 1
    mode=$(stat -c %a -- "$stage" 2>/dev/null) || return 1
    [ "$owner" -eq "$(id -u)" ] && [ $((8#$mode & 0022)) -eq 0 ] || return 1
    /usr/bin/rm -rf -- "$stage" || return 1
    _INSTALL_STAGE_DIR=
}

_install_reset_stage() {
    local stage=$1
    _install_discard_stage "$stage" || return 1
    mkdir -m 0700 -- "$stage" || return 1
    _install_owned_directory "$stage" || return 1
    _INSTALL_STAGE_DIR=$stage
}

_install_finalize_stage() {
    local stage=$1 home=$2 first
    if ! _install_layout_is_trusted "$stage"; then
        _ui_error '安装文件的归属、权限或目录结构校验失败'
        return 1
    fi
    if ! _install_marker_write "$stage" "$home"; then
        _ui_error '无法写入可信安装标记'
        return 1
    fi
    if [ -e "$home" ] || [ -L "$home" ]; then
        _install_owned_directory "$home" || {
            _ui_error "目标目录在安装期间发生变化，拒绝覆盖: $home"
            return 1
        }
        first=$(find "$home" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null) || return 1
        [ -z "$first" ] || {
            _ui_error "目标目录在安装期间出现新内容，拒绝覆盖: $home"
            return 1
        }
        rmdir -- "$home" || return 1
    fi
    if ! /bin/mv -T -- "$stage" "$home"; then
        _ui_error '无法原子提交安装文件'
        _ui_detail '暂存目录' "$stage"
        return 1
    fi
    _INSTALL_STAGE_DIR=
    if ! _install_layout_is_trusted "$home" || ! _install_marker_validate "$home"; then
        _ui_error '安装文件已提交，但最终身份校验失败；目录已保留以便排查'
        _ui_detail '目录' "$home"
        return 1
    fi
    _INSTALL_HOME_STATE=resume
}

_install_read_subscription() {
    local answer
    _install_private_locals answer
    _ui_blank
    if _ui_color_enabled 2; then
        printf '\033[35m[ ? ]\033[0m 初始订阅 URL（可留空跳过，输入不会显示）: ' >&2
    else
        printf '[ ? ] 初始订阅 URL（可留空跳过，输入不会显示）: ' >&2
    fi
    IFS= read -r -s answer || {
        printf '\n' >&2
        _ui_error '读取订阅链接失败'
        return 1
    }
    printf '\n' >&2
    _install_validate_input '订阅链接' "$answer" || return 1
    case $answer in
    '' | http://* | https://* | file://*) printf '%s' "$answer" ;;
    *)
        _ui_error '订阅链接必须以 http://、https:// 或 file:// 开头'
        return 1
        ;;
    esac
}

_install_detect_service_manager() {
    local init_type=${INIT_TYPE:-}
    [ -n "$init_type" ] || init_type=$(readlink /proc/1/exe 2>/dev/null || printf nohup)
    grep -qsE 'docker|kubepods|containerd|podman|lxc' /proc/1/cgroup 2>/dev/null && init_type='nohup'
    [ "$(id -u)" -eq 0 ] || init_type='nohup'
    init_type=$(basename "$init_type")
    case $init_type in
    *systemd) printf systemd ;;
    *openrc*) printf openrc ;;
    *busybox*) command -v openrc-init >/dev/null 2>&1 && printf openrc || printf nohup ;;
    *runit) printf runit ;;
    *init) printf sysvinit ;;
    *) printf nohup ;;
    esac
}

_install_service_target() {
    local manager=$1 kernel=$2
    case $manager in
    systemd) printf '/etc/systemd/system/%s.service\n' "$kernel" ;;
    sysvinit | openrc) printf '/etc/init.d/%s\n' "$kernel" ;;
    runit) printf '/etc/sv/%s/run\n' "$kernel" ;;
    *) return 1 ;;
    esac
}

_install_existing_service() {
    local manager=$1 target=$2 kernel=$3 fragment path
    if [ -e "$target" ] || [ -L "$target" ]; then
        printf '%s\n' "$target"
        return 0
    fi
    [ "$manager" = systemd ] || return 1
    if command -v systemctl >/dev/null 2>&1; then
        fragment=$(systemctl show -p FragmentPath --value "${kernel}.service" 2>/dev/null)
        if [ -n "$fragment" ] && { [ -e "$fragment" ] || [ -L "$fragment" ]; }; then
            printf '%s\n' "$fragment"
            return 0
        fi
    fi
    for path in "/usr/lib/systemd/system/${kernel}.service" "/lib/systemd/system/${kernel}.service"; do
        if [ -e "$path" ] || [ -L "$path" ]; then
            printf '%s\n' "$path"
            return 0
        fi
    done
    return 1
}

_install_service_active_state() {
    local manager=$1 kernel=$2 output='' rc=0
    case $manager in
    systemd)
        output=$(systemctl show --property=ActiveState --value "${kernel}.service" 2>/dev/null) ||
            return 1
        case $output in
        active | reloading) printf '%s\n' active ;;
        inactive | failed) printf '%s\n' inactive ;;
        *) return 1 ;;
        esac
        ;;
    sysvinit)
        service "$kernel" status >/dev/null 2>&1 || rc=$?
        case $rc in
        0) printf '%s\n' active ;;
        1 | 2 | 3) printf '%s\n' inactive ;;
        *) return 1 ;;
        esac
        ;;
    openrc)
        rc-service "$kernel" status >/dev/null 2>&1 || rc=$?
        case $rc in
        0) printf '%s\n' active ;;
        3 | 16) printf '%s\n' inactive ;;
        *) return 1 ;;
        esac
        ;;
    runit)
        output=$(sv status "$kernel" 2>/dev/null) || rc=$?
        [ "$rc" -eq 0 ] || return 1
        case $output in
        run:*) printf '%s\n' active ;;
        down:*) printf '%s\n' inactive ;;
        *) return 1 ;;
        esac
        ;;
    *) return 1 ;;
    esac
}

_install_capture_service_runtime_state() {
    local manager=$1 kernel=$2 state check
    state=$(_install_service_active_state "$manager" "$kernel") || {
        case $manager in
        systemd) check="systemctl show --property=ActiveState ${kernel}.service" ;;
        sysvinit) check="service ${kernel} status" ;;
        openrc) check="rc-service ${kernel} status" ;;
        runit) check="sv status ${kernel}" ;;
        *) check="${manager} 服务状态查询" ;;
        esac
        _ui_error "无法确定现有 ${kernel} 服务是否正在运行，拒绝接管"
        _ui_detail '状态检查' "$check"
        _ui_detail '处理' '确认服务管理器可用且服务状态稳定后重新运行安装'
        return 1
    }
    case $state in
    active) CLASHCTL_SERVICE_WAS_ACTIVE=1 ;;
    inactive) CLASHCTL_SERVICE_WAS_ACTIVE=0 ;;
    *) return 1 ;;
    esac
    export CLASHCTL_SERVICE_WAS_ACTIVE
}

_install_service_is_enabled() {
    local manager=$1 kernel=$2
    case $manager in
    systemd) systemctl is-enabled --quiet "$kernel" 2>/dev/null ;;
    sysvinit)
        if command -v chkconfig >/dev/null 2>&1; then
            chkconfig "$kernel" 2>/dev/null | grep -qsE ':[[:space:]]*on'
            return
        fi
        local link
        for link in /etc/rc?.d/S[0-9][0-9]"$kernel"; do
            [ -L "$link" ] && return 0
        done
        return 1
        ;;
    openrc) rc-update show default 2>/dev/null | grep -qs "[[:space:]]${kernel}[[:space:]]" ;;
    runit) [ -L "${CLASHCTL_SERVICE_ENABLE_LINK:-/etc/runit/runsvdir/default/$kernel}" ] ;;
    *) return 1 ;;
    esac
}

_install_service_enable_link() {
    local manager=$1 kernel=$2
    [ "$manager" = runit ] || return 1
    printf '/etc/runit/runsvdir/default/%s\n' "$kernel"
}

_install_enablement_supported() {
    case ${1:-} in systemd | sysvinit | openrc | runit) return 0 ;; esac
    return 1
}

_install_retain_enablement_snapshots() {
    _install_enablement_supported "${CLASHCTL_SERVICE_MANAGER:-}" || return 1
    [ "${CLASHCTL_SERVICE_CONFLICT:-0}" = 1 ] || [ -z "${CLASHCTL_SERVICE_SOURCE:-}" ]
}

_install_enablement_state_label() {
    case ${1:-} in
    enabled) printf '已启用' ;;
    enabled-runtime) printf '已临时启用' ;;
    linked) printf '已链接' ;;
    linked-runtime) printf '已临时链接' ;;
    alias) printf '别名单元' ;;
    masked) printf '已屏蔽' ;;
    masked-runtime) printf '已临时屏蔽' ;;
    static) printf '静态单元' ;;
    indirect) printf '间接启用' ;;
    generated) printf '生成单元' ;;
    transient) printf '临时单元' ;;
    disabled) printf '未启用' ;;
    not-found) printf '未注册' ;;
    *) printf '未知 (%s)' "${1:-空}" ;;
    esac
}

_install_enablement_has_artifacts() {
    [ -n "${CLASHCTL_SERVICE_ENABLEMENT_LINKS:-}" ] && return 0
    case ${CLASHCTL_SERVICE_ENABLEMENT_STATE:-disabled} in
    disabled | not-found) return 1 ;;
    *) return 0 ;;
    esac
}

_install_remove_enablement_manifest() {
    local manifest=$1
    [ -e "$manifest" ] || [ -L "$manifest" ] || return 0
    if [ ! -f "$manifest" ] || [ -L "$manifest" ]; then
        _ui_error '服务自启快照不是可信的普通文件，拒绝覆盖或删除'
        _ui_detail '快照' "$manifest"
        return 1
    fi
    /usr/bin/rm -f -- "$manifest"
}

_install_capture_original_enablement() {
    local home=$1 manager=$2 kernel=$3 installed_manifest
    CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL=
    CLASHCTL_SERVICE_ENABLEMENT_INSTALLED=
    CLASHCTL_SERVICE_ENABLEMENT_STATE=disabled
    CLASHCTL_SERVICE_ENABLEMENT_LINKS=
    export CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL CLASHCTL_SERVICE_ENABLEMENT_INSTALLED
    export CLASHCTL_SERVICE_ENABLEMENT_STATE CLASHCTL_SERVICE_ENABLEMENT_LINKS
    _install_enablement_supported "$manager" || return 0

    CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL="$home/.service-enablement.original"
    installed_manifest="$home/.service-enablement.installed"
    export CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL CLASHCTL_SERVICE_ENABLEMENT_INSTALLED
    _install_remove_enablement_manifest "$installed_manifest" || return 1
    if ! service_enablement_capture \
        "$manager" "$kernel" "$CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL"; then
        _ui_error '无法完整读取现有服务的自启状态'
        _ui_detail '原因' "${SERVICE_ENABLEMENT_ERROR:-未知错误}"
        return 1
    fi
    CLASHCTL_SERVICE_ENABLEMENT_STATE=$SERVICE_ENABLEMENT_STATE
    CLASHCTL_SERVICE_ENABLEMENT_LINKS=$SERVICE_ENABLEMENT_LINKS
    export CLASHCTL_SERVICE_ENABLEMENT_STATE CLASHCTL_SERVICE_ENABLEMENT_LINKS
}

_install_capture_enable_link() {
    local link=${CLASHCTL_SERVICE_ENABLE_LINK:-}
    CLASHCTL_SERVICE_ENABLE_KIND=absent
    CLASHCTL_SERVICE_ENABLE_TARGET=
    [ -n "$link" ] || return 0

    if [ -L "$link" ]; then
        CLASHCTL_SERVICE_ENABLE_KIND=symlink
        CLASHCTL_SERVICE_ENABLE_TARGET=$(readlink -- "$link") || return 1
    elif [ -e "$link" ]; then
        CLASHCTL_SERVICE_ENABLE_KIND=other
    fi
    export CLASHCTL_SERVICE_ENABLE_KIND CLASHCTL_SERVICE_ENABLE_TARGET
}

_install_next_backup() {
    local target=$1 stamp backup i=1
    stamp=$(date +%Y%m%d-%H%M%S)
    backup="${target}.clashctl-bak.${stamp}"
    while [ -e "$backup" ] || [ -L "$backup" ]; do
        backup="${target}.clashctl-bak.${stamp}.${i}"
        i=$((i + 1))
    done
    printf '%s\n' "$backup"
}

# 只读识别所有支持的 init；真正备份延迟到写服务配置之前。
_install_impact_scan() {
    local home=$1 kernel=$2 manager=$3 legacy="${HOME}/clashctl"
    local target source service_name runtime_state=已停止 enable_state=未启用

    CLASHCTL_SERVICE_MANAGER=$manager
    CLASHCTL_SERVICE_TARGET=
    CLASHCTL_SERVICE_TARGET_EXISTED=0
    CLASHCTL_SERVICE_SOURCE=
    CLASHCTL_SERVICE_BACKUP=
    CLASHCTL_SERVICE_BACKUP_CREATED=0
    CLASHCTL_SERVICE_WAS_ACTIVE=0
    CLASHCTL_SERVICE_WAS_ENABLED=0
    CLASHCTL_SERVICE_CONFLICT=0
    CLASHCTL_SERVICE_ENABLE_LINK=
    CLASHCTL_SERVICE_ENABLE_KIND=absent
    CLASHCTL_SERVICE_ENABLE_TARGET=
    CLASHCTL_SERVICE_EXPECTED_ENABLE_TARGET=
    CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL=
    CLASHCTL_SERVICE_ENABLEMENT_INSTALLED=
    CLASHCTL_SERVICE_ENABLEMENT_STATE=disabled
    CLASHCTL_SERVICE_ENABLEMENT_LINKS=
    export CLASHCTL_SERVICE_MANAGER CLASHCTL_SERVICE_TARGET CLASHCTL_SERVICE_TARGET_EXISTED
    export CLASHCTL_SERVICE_SOURCE CLASHCTL_SERVICE_BACKUP CLASHCTL_SERVICE_BACKUP_CREATED
    export CLASHCTL_SERVICE_WAS_ACTIVE CLASHCTL_SERVICE_WAS_ENABLED CLASHCTL_SERVICE_CONFLICT
    export CLASHCTL_SERVICE_ENABLE_LINK CLASHCTL_SERVICE_ENABLE_KIND CLASHCTL_SERVICE_ENABLE_TARGET
    export CLASHCTL_SERVICE_EXPECTED_ENABLE_TARGET
    export CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL CLASHCTL_SERVICE_ENABLEMENT_INSTALLED
    export CLASHCTL_SERVICE_ENABLEMENT_STATE CLASHCTL_SERVICE_ENABLEMENT_LINKS

    if [ -d "$legacy" ] && [ "$legacy" != "$home" ]; then
        _ui_warn '检测到旧版安装数据，本次不会自动迁移'
        _ui_detail '旧版目录' "$legacy"
        _ui_detail '迁移配置' "cp $legacy/resources/{config,mixin,profiles}.yaml $home/data/"
        _ui_detail '迁移订阅' "cp -a $legacy/resources/profiles/. $home/data/profiles/"
        _ui_blank
    fi

    target=$(_install_service_target "$manager" "$kernel") || return 0
    export CLASHCTL_SERVICE_MANAGER=$manager CLASHCTL_SERVICE_TARGET=$target
    _install_capture_original_enablement "$home" "$manager" "$kernel" || return 1
    enable_state=$(_install_enablement_state_label "$CLASHCTL_SERVICE_ENABLEMENT_STATE")
    if CLASHCTL_SERVICE_ENABLE_LINK=$(_install_service_enable_link "$manager" "$kernel"); then
        CLASHCTL_SERVICE_EXPECTED_ENABLE_TARGET=$(dirname -- "$target")
        export CLASHCTL_SERVICE_ENABLE_LINK CLASHCTL_SERVICE_EXPECTED_ENABLE_TARGET
        _install_capture_enable_link || {
            _ui_error '无法读取 runit 自启入口'
            return 1
        }
        if [ "$CLASHCTL_SERVICE_ENABLE_KIND" = other ]; then
            _ui_error "runit 自启入口不是符号链接: $CLASHCTL_SERVICE_ENABLE_LINK"
            _ui_detail '处理' '请先移走该文件，再重新运行安装'
            return 1
        fi
    fi
    CLASHCTL_SERVICE_TARGET_EXISTED=0
    [ ! -e "$target" ] && [ ! -L "$target" ] || CLASHCTL_SERVICE_TARGET_EXISTED=1
    export CLASHCTL_SERVICE_TARGET_EXISTED

    source=$(_install_existing_service "$manager" "$target" "$kernel") || source=
    CLASHCTL_SERVICE_SOURCE=$source
    export CLASHCTL_SERVICE_SOURCE
    if [ -n "$source" ]; then
        CLASHCTL_SERVICE_BACKUP=$(_install_next_backup "$target")
        export CLASHCTL_SERVICE_BACKUP
    elif ! _install_enablement_has_artifacts; then
        return 0
    fi
    _install_capture_service_runtime_state "$manager" "$kernel" || return 1
    CLASHCTL_SERVICE_WAS_ENABLED=0
    _install_service_is_enabled "$manager" "$kernel" && CLASHCTL_SERVICE_WAS_ENABLED=1
    export CLASHCTL_SERVICE_WAS_ACTIVE CLASHCTL_SERVICE_WAS_ENABLED
    [ "$CLASHCTL_SERVICE_WAS_ACTIVE" != 1 ] || runtime_state=运行中
    if ! _install_enablement_supported "$manager"; then
        [ "$CLASHCTL_SERVICE_WAS_ENABLED" != 1 ] || enable_state=已启用
    fi

    # 同一安装目录留下的半安装服务可直接刷新，但仍会在写入前留档。
    if [ -n "$source" ] && [ "$source" = "$target" ] &&
        declare -F _service_definition_is_owned >/dev/null 2>&1 &&
        _service_definition_is_owned "$source"; then
        return 0
    fi

    CLASHCTL_SERVICE_CONFLICT=1
    export CLASHCTL_SERVICE_CONFLICT
    service_name=$kernel
    [ "$manager" != systemd ] || service_name="${kernel}.service"
    _ui_blank
    _ui_warn "发现现有服务: $service_name"
    _ui_detail '现有定义' "${source:-未找到（仅检测到启用、链接或屏蔽状态）}"
    _ui_detail '当前状态' "$runtime_state · $enable_state"
    _ui_detail '当前进度' '仅完成只读检查；服务定义、自启状态和运行状态均未修改'
    _ui_detail '将执行' '如正在运行则先停止，备份现有定义，再由 clashctl 接管'
    _ui_detail '写入位置' "$target"
    if [ -n "$CLASHCTL_SERVICE_BACKUP" ]; then
        _ui_detail '备份位置' "$CLASHCTL_SERVICE_BACKUP"
    else
        _ui_detail '定义备份' '不需要（当前没有可备份的服务定义）'
    fi
    _ui_detail '失败处理' '自动尝试恢复原状态；若恢复不完整，将保留事务快照与备份'
    _ui_blank

    if [ "${CLASHCTL_ALLOW_UNIT_OVERWRITE:-}" = 1 ]; then
        _ui_info '已通过 --take-over-service / CLASHCTL_ALLOW_UNIT_OVERWRITE=1 授权接管'
        return 0
    fi
    if [ "${CLASHCTL_NON_INTERACTIVE:-}" = 1 ] || [ "${CI+x}" = x ]; then
        _ui_error '非交互安装不会接管现有服务'
        _ui_detail '重新执行' '添加 --take-over-service'
        return 1
    fi
    local confirm_rc=0
    _ui_confirm "停止并接管 ${service_name}？" || confirm_rc=$?
    if [ "$confirm_rc" -eq 0 ]; then
        _ui_ok '已确认接管；现有服务尚未被修改'
        return 0
    fi
    if [ "$confirm_rc" -eq 2 ]; then
        _ui_error '当前环境无法交互确认服务接管'
        _ui_detail '非交互授权' '添加 --take-over-service'
        _ui_detail '保留目录' "$home"
        _ui_detail '继续安装' '使用相同参数重试；安装器会复用可信的未完成目录'
        _INSTALL_INCOMPLETE_SUMMARY_SHOWN=1
    else
        _ui_info '安装已取消；现有服务未被修改'
        _ui_detail '保留目录' "$home"
        _ui_detail '继续安装' '重新运行安装命令，并在确认后接管服务'
        _ui_detail '放弃安装' '确认目录内无所需数据后，可删除上述未完成安装目录'
        _INSTALL_INCOMPLETE_SUMMARY_SHOWN=1
    fi
    return 1
}

_install_journal_write() {
    local journal="${CLASHCTL_HOME}/.service-transaction" tmp value
    local -a values=(
        "$CLASHCTL_KERNEL"
        "${CLASHCTL_SERVICE_MANAGER:-}"
        "${CLASHCTL_SERVICE_TARGET:-}"
        "${CLASHCTL_SERVICE_SOURCE:-}"
        "${CLASHCTL_SERVICE_BACKUP:-}"
        "${CLASHCTL_SERVICE_ENABLE_LINK:-}"
        "${CLASHCTL_SERVICE_ENABLE_TARGET:-}"
        "${CLASHCTL_SERVICE_EXPECTED_ENABLE_TARGET:-}"
        "${CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL:-}"
        "${CLASHCTL_SERVICE_ENABLEMENT_INSTALLED:-}"
    )
    for value in "${values[@]}"; do
        if _install_has_control_chars "$value"; then
            _ui_error '服务快照包含不支持的控制字符'
            return 1
        fi
    done

    tmp=$(mktemp "${journal}.tmp.XXXXXX") || return 1
    chmod 0600 "$tmp" || {
        /usr/bin/rm -f -- "$tmp"
        return 1
    }
    {
        printf 'CLASHCTL_SERVICE_JOURNAL_VERSION=2\n'
        printf 'CLASHCTL_SERVICE_JOURNAL_KERNEL=%s\n' "$CLASHCTL_KERNEL"
        printf 'CLASHCTL_SERVICE_MANAGER=%s\n' "${CLASHCTL_SERVICE_MANAGER:-}"
        printf 'CLASHCTL_SERVICE_TARGET=%s\n' "${CLASHCTL_SERVICE_TARGET:-}"
        printf 'CLASHCTL_SERVICE_TARGET_EXISTED=%s\n' "${CLASHCTL_SERVICE_TARGET_EXISTED:-0}"
        printf 'CLASHCTL_SERVICE_SOURCE=%s\n' "${CLASHCTL_SERVICE_SOURCE:-}"
        printf 'CLASHCTL_SERVICE_BACKUP=%s\n' "${CLASHCTL_SERVICE_BACKUP:-}"
        printf 'CLASHCTL_SERVICE_BACKUP_CREATED=%s\n' "${CLASHCTL_SERVICE_BACKUP_CREATED:-0}"
        printf 'CLASHCTL_SERVICE_WAS_ACTIVE=%s\n' "${CLASHCTL_SERVICE_WAS_ACTIVE:-0}"
        printf 'CLASHCTL_SERVICE_WAS_ENABLED=%s\n' "${CLASHCTL_SERVICE_WAS_ENABLED:-0}"
        printf 'CLASHCTL_SERVICE_CONFLICT=%s\n' "${CLASHCTL_SERVICE_CONFLICT:-0}"
        printf 'CLASHCTL_SERVICE_ENABLE_LINK=%s\n' "${CLASHCTL_SERVICE_ENABLE_LINK:-}"
        printf 'CLASHCTL_SERVICE_ENABLE_KIND=%s\n' "${CLASHCTL_SERVICE_ENABLE_KIND:-absent}"
        printf 'CLASHCTL_SERVICE_ENABLE_TARGET=%s\n' "${CLASHCTL_SERVICE_ENABLE_TARGET:-}"
        printf 'CLASHCTL_SERVICE_EXPECTED_ENABLE_TARGET=%s\n' "${CLASHCTL_SERVICE_EXPECTED_ENABLE_TARGET:-}"
        printf 'CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL=%s\n' "${CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL:-}"
        printf 'CLASHCTL_SERVICE_ENABLEMENT_INSTALLED=%s\n' "${CLASHCTL_SERVICE_ENABLEMENT_INSTALLED:-}"
    } >"$tmp" || {
        /usr/bin/rm -f -- "$tmp"
        return 1
    }
    /bin/mv -f -- "$tmp" "$journal" || {
        /usr/bin/rm -f -- "$tmp"
        return 1
    }
    CLASHCTL_SERVICE_JOURNAL=$journal
    export CLASHCTL_SERVICE_JOURNAL
}

_install_journal_load() {
    local journal=$1 owner mode size line key value manager target source backup expected_target expected_link
    local original installed original_state original_links
    local -a journal_keys=(
        CLASHCTL_SERVICE_JOURNAL_VERSION
        CLASHCTL_SERVICE_JOURNAL_KERNEL
        CLASHCTL_SERVICE_MANAGER
        CLASHCTL_SERVICE_TARGET
        CLASHCTL_SERVICE_TARGET_EXISTED
        CLASHCTL_SERVICE_SOURCE
        CLASHCTL_SERVICE_BACKUP
        CLASHCTL_SERVICE_BACKUP_CREATED
        CLASHCTL_SERVICE_WAS_ACTIVE
        CLASHCTL_SERVICE_WAS_ENABLED
        CLASHCTL_SERVICE_CONFLICT
        CLASHCTL_SERVICE_ENABLE_LINK
        CLASHCTL_SERVICE_ENABLE_KIND
        CLASHCTL_SERVICE_ENABLE_TARGET
        CLASHCTL_SERVICE_EXPECTED_ENABLE_TARGET
        CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL
        CLASHCTL_SERVICE_ENABLEMENT_INSTALLED
    )
    local -A parsed=() seen=()

    for key in "${journal_keys[@]}"; do
        unset "$key"
    done
    unset CLASHCTL_SERVICE_JOURNAL
    [ -f "$journal" ] && [ ! -L "$journal" ] || return 1
    owner=$(stat -c %u -- "$journal" 2>/dev/null) || return 1
    mode=$(stat -c %a -- "$journal" 2>/dev/null) || return 1
    size=$(stat -c %s -- "$journal" 2>/dev/null) || return 1
    [ "$owner" -eq "$(id -u)" ] && [ $((8#$mode & 0077)) -eq 0 ] &&
        [ "$size" -le 65536 ] || return 1

    while IFS= read -r line || [ -n "$line" ]; do
        case $line in *=*) ;; *) return 1 ;; esac
        key=${line%%=*}
        value=${line#*=}
        case $key in
        CLASHCTL_SERVICE_JOURNAL_VERSION|CLASHCTL_SERVICE_JOURNAL_KERNEL|CLASHCTL_SERVICE_MANAGER|\
            CLASHCTL_SERVICE_TARGET|CLASHCTL_SERVICE_TARGET_EXISTED|CLASHCTL_SERVICE_SOURCE|\
            CLASHCTL_SERVICE_BACKUP|CLASHCTL_SERVICE_BACKUP_CREATED|CLASHCTL_SERVICE_WAS_ACTIVE|\
            CLASHCTL_SERVICE_WAS_ENABLED|CLASHCTL_SERVICE_CONFLICT|CLASHCTL_SERVICE_ENABLE_LINK|\
            CLASHCTL_SERVICE_ENABLE_KIND|CLASHCTL_SERVICE_ENABLE_TARGET|CLASHCTL_SERVICE_EXPECTED_ENABLE_TARGET|\
            CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL|CLASHCTL_SERVICE_ENABLEMENT_INSTALLED)
            [ "${seen[$key]:-0}" -eq 0 ] || return 1
            printf '%s' "$value" | LC_ALL=C grep -q '[[:cntrl:]]' && return 1
            parsed[$key]=$value
            seen[$key]=1
            ;;
        *) return 1 ;;
        esac
    done <"$journal"

    for key in "${journal_keys[@]}"; do
        [ "${seen[$key]:-0}" -eq 1 ] || return 1
    done
    [ "${parsed[CLASHCTL_SERVICE_JOURNAL_VERSION]}" = 2 ] || return 1
    [ "${parsed[CLASHCTL_SERVICE_JOURNAL_KERNEL]}" = "$CLASHCTL_KERNEL" ] || return 1
    manager=${parsed[CLASHCTL_SERVICE_MANAGER]}
    case $manager in systemd | sysvinit | openrc | runit | nohup) ;; *) return 1 ;; esac
    for key in CLASHCTL_SERVICE_TARGET_EXISTED CLASHCTL_SERVICE_BACKUP_CREATED \
        CLASHCTL_SERVICE_WAS_ACTIVE CLASHCTL_SERVICE_WAS_ENABLED CLASHCTL_SERVICE_CONFLICT; do
        case ${parsed[$key]} in 0 | 1) ;; *) return 1 ;; esac
    done
    case ${parsed[CLASHCTL_SERVICE_ENABLE_KIND]} in absent | symlink) ;; *) return 1 ;; esac

    expected_target=$(_install_service_target "$manager" "$CLASHCTL_KERNEL") || expected_target=
    target=${parsed[CLASHCTL_SERVICE_TARGET]}
    source=${parsed[CLASHCTL_SERVICE_SOURCE]}
    backup=${parsed[CLASHCTL_SERVICE_BACKUP]}
    original=${parsed[CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL]}
    installed=${parsed[CLASHCTL_SERVICE_ENABLEMENT_INSTALLED]}
    [ "$target" = "$expected_target" ] || return 1

    if _install_enablement_supported "$manager"; then
        [ "$original" = "${CLASHCTL_HOME}/.service-enablement.original" ] || return 1
        service_enablement_validate "$manager" "$CLASHCTL_KERNEL" "$original" || return 1
        original_state=$SERVICE_ENABLEMENT_STATE
        original_links=$SERVICE_ENABLEMENT_LINKS
        if [ -n "$installed" ]; then
            [ "$installed" = "${CLASHCTL_HOME}/.service-enablement.installed" ] || return 1
            service_enablement_validate "$manager" "$CLASHCTL_KERNEL" "$installed" || return 1
        fi
    else
        [ -z "$original" ] && [ -z "$installed" ] || return 1
        original_state=disabled
        original_links=
    fi

    if [ -n "$source" ]; then
        [ -n "$target" ] && [ -n "$backup" ] || return 1
        [ "${parsed[CLASHCTL_SERVICE_BACKUP_CREATED]}" = 1 ] || return 1
        case $backup in "${target}.clashctl-bak."*) ;; *) return 1 ;; esac
        case $manager in
        systemd)
            if [ "$source" != "$target" ]; then
                case $source in /*/${CLASHCTL_KERNEL}.service) ;; *) return 1 ;; esac
            fi
            ;;
        *) [ "$source" = "$target" ] || return 1 ;;
        esac
        if [ "$source" = "$target" ]; then
            [ "${parsed[CLASHCTL_SERVICE_TARGET_EXISTED]}" = 1 ] || return 1
        else
            [ "${parsed[CLASHCTL_SERVICE_TARGET_EXISTED]}" = 0 ] || return 1
        fi
    else
        [ -z "$backup" ] || return 1
        [ "${parsed[CLASHCTL_SERVICE_BACKUP_CREATED]}" = 0 ] || return 1
        [ "${parsed[CLASHCTL_SERVICE_TARGET_EXISTED]}" = 0 ] || return 1
        if [ "${parsed[CLASHCTL_SERVICE_CONFLICT]}" = 1 ]; then
            [ -n "$original_links" ] || case $original_state in
                disabled | not-found) return 1 ;;
            esac
        fi
    fi

    if [ "$manager" = runit ]; then
        expected_link=$(_install_service_enable_link "$manager" "$CLASHCTL_KERNEL") || return 1
        [ "${parsed[CLASHCTL_SERVICE_ENABLE_LINK]}" = "$expected_link" ] || return 1
        [ "${parsed[CLASHCTL_SERVICE_EXPECTED_ENABLE_TARGET]}" = "$(dirname -- "$target")" ] || return 1
        if [ "${parsed[CLASHCTL_SERVICE_ENABLE_KIND]}" = absent ]; then
            [ -z "${parsed[CLASHCTL_SERVICE_ENABLE_TARGET]}" ] || return 1
        else
            [ -n "${parsed[CLASHCTL_SERVICE_ENABLE_TARGET]}" ] || return 1
        fi
    else
        [ "${parsed[CLASHCTL_SERVICE_ENABLE_KIND]}" = absent ] || return 1
        [ -z "${parsed[CLASHCTL_SERVICE_ENABLE_LINK]}" ] || return 1
        [ -z "${parsed[CLASHCTL_SERVICE_ENABLE_TARGET]}" ] || return 1
        [ -z "${parsed[CLASHCTL_SERVICE_EXPECTED_ENABLE_TARGET]}" ] || return 1
    fi

    for key in "${journal_keys[@]}"; do
        printf -v "$key" '%s' "${parsed[$key]}"
        export "${key?}"
    done
    CLASHCTL_SERVICE_JOURNAL=$journal
    export CLASHCTL_SERVICE_JOURNAL
}

_install_snapshot_service() {
    local manager=${CLASHCTL_SERVICE_MANAGER:-nohup} target=${CLASHCTL_SERVICE_TARGET:-}
    local expected_source=${CLASHCTL_SERVICE_SOURCE:-} current_source='' verification=''
    local confirmed_active=${CLASHCTL_SERVICE_WAS_ACTIVE:-0}

    if _install_enablement_supported "$manager"; then
        [ -n "${CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL:-}" ] || {
            _ui_error '缺少确认阶段的服务自启快照，拒绝开始事务'
            return 1
        }
        verification=$(mktemp "${CLASHCTL_HOME}/.service-enablement.confirm.XXXXXX") || return 1
        if ! service_enablement_capture "$manager" "$CLASHCTL_KERNEL" "$verification"; then
            /usr/bin/rm -f -- "$verification" 2>/dev/null || true
            _ui_error '确认后无法重新读取服务自启状态，安装已中止'
            _ui_detail '原因' "${SERVICE_ENABLEMENT_ERROR:-未知错误}"
            return 1
        fi
        if ! cmp -s -- "$CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL" "$verification"; then
            /usr/bin/rm -f -- "$verification" 2>/dev/null || true
            _ui_error '服务自启状态在确认后发生变化，安装已中止'
            _ui_detail '处理' '检查服务链接或屏蔽状态后重新运行安装'
            return 1
        fi
        if ! /usr/bin/rm -f -- "$verification"; then
            _ui_error '无法清理服务自启复核快照，未修改现有服务'
            _ui_detail '快照' "$verification"
            return 1
        fi
        verification=
        service_enablement_validate \
            "$manager" "$CLASHCTL_KERNEL" "$CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL" || return 1
        CLASHCTL_SERVICE_ENABLEMENT_STATE=$SERVICE_ENABLEMENT_STATE
        CLASHCTL_SERVICE_ENABLEMENT_LINKS=$SERVICE_ENABLEMENT_LINKS
        export CLASHCTL_SERVICE_ENABLEMENT_STATE CLASHCTL_SERVICE_ENABLEMENT_LINKS
    fi

    if [ -n "$target" ]; then
        current_source=$(_install_existing_service "$manager" "$target" "$CLASHCTL_KERNEL") || current_source=
        if [ "$current_source" != "$expected_source" ]; then
            _ui_error '同名服务在确认后发生变化，安装已中止'
            _ui_detail '确认时' "${expected_source:-不存在}"
            _ui_detail '当前' "${current_source:-不存在}"
            _ui_detail '处理' '检查服务状态后重新运行安装'
            return 1
        fi
        CLASHCTL_SERVICE_SOURCE=$current_source
        CLASHCTL_SERVICE_TARGET_EXISTED=0
        [ ! -e "$target" ] && [ ! -L "$target" ] || CLASHCTL_SERVICE_TARGET_EXISTED=1
        _install_capture_service_runtime_state "$manager" "$CLASHCTL_KERNEL" || return 1
        if [ "$CLASHCTL_SERVICE_WAS_ACTIVE" != "$confirmed_active" ]; then
            _ui_error '服务运行状态在确认后发生变化，安装已中止'
            _ui_detail '确认时' "$([ "$confirmed_active" = 1 ] && printf '运行中' || printf '已停止')"
            _ui_detail '当前' "$([ "$CLASHCTL_SERVICE_WAS_ACTIVE" = 1 ] && printf '运行中' || printf '已停止')"
            _ui_detail '处理' '等待服务状态稳定后重新运行安装'
            return 1
        fi
        CLASHCTL_SERVICE_WAS_ENABLED=0
        _install_service_is_enabled "$manager" "$CLASHCTL_KERNEL" && CLASHCTL_SERVICE_WAS_ENABLED=1
        if [ "$manager" = runit ]; then
            _install_capture_enable_link || return 1
            [ "$CLASHCTL_SERVICE_ENABLE_KIND" != other ] || {
                _ui_error "runit 自启入口已变为普通文件: $CLASHCTL_SERVICE_ENABLE_LINK"
                return 1
            }
        fi
    else
        CLASHCTL_SERVICE_WAS_ACTIVE=0
        service_is_active >/dev/null 2>&1 && CLASHCTL_SERVICE_WAS_ACTIVE=1
        CLASHCTL_SERVICE_WAS_ENABLED=0
    fi
    export CLASHCTL_SERVICE_SOURCE CLASHCTL_SERVICE_TARGET_EXISTED
    export CLASHCTL_SERVICE_WAS_ACTIVE CLASHCTL_SERVICE_WAS_ENABLED

    if [ -n "$current_source" ]; then
        if [ -z "${CLASHCTL_SERVICE_BACKUP:-}" ] ||
            [ -e "$CLASHCTL_SERVICE_BACKUP" ] || [ -L "$CLASHCTL_SERVICE_BACKUP" ]; then
            CLASHCTL_SERVICE_BACKUP=$(_install_next_backup "$target")
            export CLASHCTL_SERVICE_BACKUP
        fi
        cp -a -- "$current_source" "$CLASHCTL_SERVICE_BACKUP" || {
            _ui_error "无法备份现有服务配置: $CLASHCTL_SERVICE_BACKUP"
            return 1
        }
        CLASHCTL_SERVICE_BACKUP_CREATED=1
        export CLASHCTL_SERVICE_BACKUP_CREATED
        _ui_ok "现有服务配置已备份: $CLASHCTL_SERVICE_BACKUP"
    fi
    _install_journal_write || {
        _ui_error '无法写入服务事务快照，未修改现有服务'
        if [ "${CLASHCTL_SERVICE_BACKUP_CREATED:-0}" = 1 ]; then
            if /usr/bin/rm -f -- "${CLASHCTL_SERVICE_BACKUP:-}"; then
                CLASHCTL_SERVICE_BACKUP_CREATED=0
                export CLASHCTL_SERVICE_BACKUP_CREATED
            else
                _ui_warn '服务尚未修改，但临时备份未能清理'
                _ui_detail '临时备份' "$CLASHCTL_SERVICE_BACKUP"
            fi
        fi
        return 1
    }
}

_install_capture_installed_enablement() {
    local manager=${CLASHCTL_SERVICE_MANAGER:-nohup}
    local installed_manifest="${CLASHCTL_HOME}/.service-enablement.installed"
    _install_enablement_supported "$manager" || return 0
    if ! service_enablement_capture \
        "$manager" "$CLASHCTL_KERNEL" "$installed_manifest"; then
        _ui_error '服务启用命令已执行，但无法验证最终自启状态'
        _ui_detail '原因' "${SERVICE_ENABLEMENT_ERROR:-未知错误}"
        return 1
    fi
    CLASHCTL_SERVICE_ENABLEMENT_INSTALLED=$installed_manifest
    export CLASHCTL_SERVICE_ENABLEMENT_INSTALLED
    _install_journal_write || {
        _ui_error '服务已启用，但无法更新事务快照；正在回滚'
        return 1
    }
    if [ "$SERVICE_ENABLEMENT_STATE" != enabled ]; then
        _ui_error '服务启用命令未产生预期的持久自启状态'
        _ui_detail '当前状态' "$(_install_enablement_state_label "$SERVICE_ENABLEMENT_STATE")"
        _ui_detail '快照' "$CLASHCTL_SERVICE_ENABLEMENT_INSTALLED"
        return 1
    fi
    _ui_ok "${CLASHCTL_SERVICE_MANAGER} 服务已注册并验证启用: $CLASHCTL_KERNEL"
}

_install_begin_service_transaction() {
    _install_snapshot_service || return 1
    _INSTALL_SERVICE_TRANSACTION=1
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
}

_install_cleanup_enablement_manifests() {
    local manifest rc=0
    for manifest in "${CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL:-}" \
        "${CLASHCTL_SERVICE_ENABLEMENT_INSTALLED:-}"; do
        [ -n "$manifest" ] || continue
        _install_remove_enablement_manifest "$manifest" || rc=1
    done
    return "$rc"
}

_install_end_service_transaction() {
    local rc=0 journal_removed=0 snapshots_removed=0 value
    local journal=${CLASHCTL_SERVICE_JOURNAL:-${CLASHCTL_HOME}/.service-transaction}
    local backup=${CLASHCTL_SERVICE_BACKUP:-}
    if ! /usr/bin/rm -f -- "$journal" 2>/dev/null; then
        rc=1
    else
        journal_removed=1
    fi
    if [ "$journal_removed" -eq 1 ] && ! _install_retain_enablement_snapshots; then
        if _install_cleanup_enablement_manifests; then
            snapshots_removed=1
        else
            rc=1
        fi
    fi
    if [ "$journal_removed" -eq 1 ] && [ "$snapshots_removed" -eq 1 ] &&
        [ "${CLASHCTL_SERVICE_BACKUP_CREATED:-0}" = 1 ]; then
        /usr/bin/rm -f -- "$backup" 2>/dev/null || rc=1
    fi
    _INSTALL_SERVICE_TRANSACTION=0
    trap - INT TERM HUP
    if [ "$rc" -ne 0 ]; then
        _ui_warn '安装已提交，但未能清理全部事务临时文件'
        [ "$journal_removed" -eq 1 ] || _ui_detail '事务快照' "$journal"
        for value in "${CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL:-}" \
            "${CLASHCTL_SERVICE_ENABLEMENT_INSTALLED:-}"; do
            [ -n "$value" ] && { [ -e "$value" ] || [ -L "$value" ]; } &&
                _ui_detail '自启快照' "$value"
        done
        if [ -n "$backup" ] && { [ -e "$backup" ] || [ -L "$backup" ]; }; then
            _ui_detail '服务备份' "$backup"
        fi
        _ui_detail '处理' '确认当前服务正常后，检查并清理上述残留文件'
    fi
    return "$rc"
}

_install_stop_existing_service() {
    [ "${CLASHCTL_SERVICE_WAS_ACTIVE:-0}" = 1 ] || return 0
    _ui_info "停止安装前的 $CLASHCTL_KERNEL 服务"
    service_stop >/dev/null 2>&1 || {
        _ui_error "无法停止现有 $CLASHCTL_KERNEL 服务，未接管服务定义"
        return 1
    }
    local _
    for _ in {1..20}; do
        service_is_active >/dev/null 2>&1 || {
            _ui_ok "现有 $CLASHCTL_KERNEL 服务已停止"
            return 0
        }
        sleep 0.1
    done
    _ui_error "现有 $CLASHCTL_KERNEL 服务仍在运行，未接管服务定义"
    return 1
}

_install_same_service_object() {
    local left=$1 right=$2
    if [ -L "$left" ] || [ -L "$right" ]; then
        [ -L "$left" ] && [ -L "$right" ] &&
            [ "$(readlink -- "$left")" = "$(readlink -- "$right")" ]
        return
    fi
    cmp -s -- "$left" "$right"
}

_install_restore_enablement_preflight() {
    local manager=${CLASHCTL_SERVICE_MANAGER:-}
    local original=${CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL:-}
    local installed=${CLASHCTL_SERVICE_ENABLEMENT_INSTALLED:-}

    [ -n "$original" ] || return 0
    if [ -n "$installed" ]; then
        if service_enablement_preflight_restore \
            "$manager" "$CLASHCTL_KERNEL" "$original" "$installed"; then
            return 0
        fi
        _ui_error '当前服务自启状态与事务快照不一致，拒绝自动恢复'
        _ui_detail '原因' "${SERVICE_ENABLEMENT_ERROR:-未知错误}"
        _ui_detail '安装前快照' "$original"
        _ui_detail '安装后快照' "$installed"
        return 1
    fi

    if ! service_enablement_preflight_restore "$manager" "$CLASHCTL_KERNEL" "$original"; then
        _ui_error '当前服务自启状态无法证明由本次安装产生，拒绝自动恢复'
        _ui_detail '原因' "${SERVICE_ENABLEMENT_ERROR:-未知错误}"
        _ui_detail '安装前快照' "$original"
        return 1
    fi

    installed="${CLASHCTL_HOME}/.service-enablement.installed"
    _ui_info '事务中断时尚未记录安装后自启状态，正在补全恢复快照'
    if ! service_enablement_capture "$manager" "$CLASHCTL_KERNEL" "$installed"; then
        _ui_error '无法补全安装后的服务自启快照，拒绝自动恢复'
        _ui_detail '原因' "${SERVICE_ENABLEMENT_ERROR:-未知错误}"
        _ui_detail '快照' "$installed"
        return 1
    fi
    CLASHCTL_SERVICE_ENABLEMENT_INSTALLED=$installed
    export CLASHCTL_SERVICE_ENABLEMENT_INSTALLED
    if ! _install_journal_write; then
        _ui_error '无法把补全的自启快照写入服务事务记录，拒绝自动恢复'
        _ui_detail '事务快照' "${CLASHCTL_SERVICE_JOURNAL:-${CLASHCTL_HOME}/.service-transaction}"
        _ui_detail '自启快照' "$installed"
        return 1
    fi
    if ! service_enablement_preflight_restore \
        "$manager" "$CLASHCTL_KERNEL" "$original" "$installed"; then
        _ui_error '补全快照后服务自启状态再次发生变化，拒绝自动恢复'
        _ui_detail '原因' "${SERVICE_ENABLEMENT_ERROR:-未知错误}"
        _ui_detail '处理' '检查服务链接后重新运行安装以重试恢复'
        return 1
    fi
    _ui_ok '安装后自启快照已补全，恢复边界已确认'
}

_install_restore_preflight() {
    local target=${CLASHCTL_SERVICE_TARGET:-} source=${CLASHCTL_SERVICE_SOURCE:-}
    local backup=${CLASHCTL_SERVICE_BACKUP:-} current_kind current_target

    if [ -n "$source" ] && { [ ! -e "$backup" ] && [ ! -L "$backup" ]; }; then
        _ui_error "原服务备份不存在，无法自动恢复: $backup"
        return 1
    fi
    if [ -n "$target" ] && { [ -e "$target" ] || [ -L "$target" ]; }; then
        if [ -n "$source" ] && [ "$source" = "$target" ] &&
            _install_same_service_object "$target" "$backup"; then
            :
        elif ! grep -Fqs "${CLASHCTL_HOME}/bin/${CLASHCTL_KERNEL}" "$target" 2>/dev/null; then
            _ui_error "服务定义已被其他操作修改，拒绝覆盖: $target"
            return 1
        fi
    fi
    _install_restore_enablement_preflight || return 1
    if [ "${CLASHCTL_SERVICE_MANAGER:-}" = runit ] &&
        [ -z "${CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL:-}" ]; then
        if [ -L "$CLASHCTL_SERVICE_ENABLE_LINK" ]; then
            current_kind=symlink
            current_target=$(readlink -- "$CLASHCTL_SERVICE_ENABLE_LINK") || return 1
        elif [ -e "$CLASHCTL_SERVICE_ENABLE_LINK" ]; then
            current_kind=other
            current_target=
        else
            current_kind=absent
            current_target=
        fi
        if [ "$current_kind" = symlink ] &&
            [ "$current_target" = "${CLASHCTL_SERVICE_EXPECTED_ENABLE_TARGET:-}" ]; then
            return 0
        fi
        if [ "$current_kind" != "${CLASHCTL_SERVICE_ENABLE_KIND:-absent}" ] ||
            [ "$current_target" != "${CLASHCTL_SERVICE_ENABLE_TARGET:-}" ]; then
            _ui_error "runit 自启入口已被其他操作修改: $CLASHCTL_SERVICE_ENABLE_LINK"
            return 1
        fi
    fi
    return 0
}

_install_restore_definition() {
    local manager=${CLASHCTL_SERVICE_MANAGER:-} target=${CLASHCTL_SERVICE_TARGET:-}
    local source=${CLASHCTL_SERVICE_SOURCE:-} backup=${CLASHCTL_SERVICE_BACKUP:-} provider staged=
    [ -n "$target" ] || return 0

    if [ -n "$source" ] && [ "$source" = "$target" ]; then
        staged=$(mktemp "${target}.clashctl-restore.XXXXXX") || {
            _ui_error '无法创建原服务定义的恢复暂存文件'
            _ui_detail '目标' "$target"
            _ui_detail '备份' "$backup"
            return 1
        }
        if ! cp -aT -- "$backup" "$staged" || ! /bin/mv -fT -- "$staged" "$target"; then
            /usr/bin/rm -f -- "$staged" 2>/dev/null || true
            _ui_error '无法原子恢复安装前的服务定义'
            _ui_detail '目标' "$target"
            _ui_detail '备份' "$backup"
            return 1
        fi
    else
        /usr/bin/rm -f -- "$target" || {
            _ui_error '无法移除 clashctl 写入的服务定义'
            _ui_detail '目标' "$target"
            [ -z "$backup" ] || _ui_detail '保留备份' "$backup"
            return 1
        }
    fi
    [ "$manager" != systemd ] || systemctl daemon-reload >/dev/null 2>&1 || return 1
    if [ -n "$source" ] && [ "$source" != "$target" ]; then
        provider=$(_install_existing_service "$manager" "$target" "$CLASHCTL_KERNEL") || provider=
        [ -n "$provider" ] || {
            _ui_error "系统原服务定义已不存在；备份保留在: $backup"
            return 1
        }
    fi
}

_install_report_retained_recovery() {
    local message=$1 journal backup=${CLASHCTL_SERVICE_BACKUP:-}
    journal=${CLASHCTL_SERVICE_JOURNAL:-${CLASHCTL_HOME}/.service-transaction}
    if [ -n "$backup" ]; then
        _ui_error "$message；事务快照和备份均已保留"
    else
        _ui_error "$message；事务快照已保留"
    fi
    _ui_detail '事务快照' "$journal"
    [ -z "$backup" ] || _ui_detail '服务备份' "$backup"
    _ui_detail '重试' '解决上述冲突后重新运行安装，安装器会先重试恢复'
}

_install_restore_service() {
    local source=${CLASHCTL_SERVICE_SOURCE:-} failures=0 exact_enablement=0 definition_restored=0
    local enablement_rc=0
    local journal=${CLASHCTL_SERVICE_JOURNAL:-${CLASHCTL_HOME}/.service-transaction}
    local original_link_target=${CLASHCTL_SERVICE_ENABLE_TARGET:-}
    local original_manifest=${CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL:-}
    local installed_manifest=${CLASHCTL_SERVICE_ENABLEMENT_INSTALLED:-}
    if [ -n "$original_manifest" ]; then
        exact_enablement=1
        if ! service_enablement_validate \
            "${CLASHCTL_SERVICE_MANAGER:-}" "$CLASHCTL_KERNEL" "$original_manifest"; then
            _ui_error '安装前的服务自启快照无效，拒绝自动恢复'
            _ui_detail '原因' "${SERVICE_ENABLEMENT_ERROR:-未知错误}"
            _install_report_retained_recovery '自动恢复前置检查失败'
            return 1
        fi
        if [ -n "$installed_manifest" ] && ! service_enablement_validate \
            "${CLASHCTL_SERVICE_MANAGER:-}" "$CLASHCTL_KERNEL" "$installed_manifest"; then
            _ui_error '本次安装写入的服务自启快照无效，拒绝自动恢复'
            _ui_detail '原因' "${SERVICE_ENABLEMENT_ERROR:-未知错误}"
            _install_report_retained_recovery '自动恢复前置检查失败'
            return 1
        fi
    fi
    if ! _install_restore_preflight; then
        _install_report_retained_recovery '自动恢复前置检查失败'
        return 1
    fi
    installed_manifest=${CLASHCTL_SERVICE_ENABLEMENT_INSTALLED:-}

    if service_is_active >/dev/null 2>&1; then
        service_stop >/dev/null 2>&1 || true
        if service_is_active >/dev/null 2>&1; then
            _ui_error "停止本次安装的 $CLASHCTL_KERNEL 服务失败"
            failures=1
        fi
    fi
    if [ "$exact_enablement" -eq 0 ] && [ -n "${CLASHCTL_SERVICE_TARGET:-}" ] &&
        service_is_enabled >/dev/null 2>&1; then
        service_disable >/dev/null 2>&1 || true
        if service_is_enabled >/dev/null 2>&1; then
            _ui_error "撤销本次安装的服务自启状态失败"
            failures=1
        fi
    fi
    if _install_restore_definition; then
        definition_restored=1
    else
        _ui_error '恢复安装前的服务定义失败'
        failures=1
    fi

    if [ "$exact_enablement" -eq 1 ] && [ "$definition_restored" -eq 1 ]; then
        if [ -n "$installed_manifest" ]; then
            service_enablement_restore "${CLASHCTL_SERVICE_MANAGER:-}" "$CLASHCTL_KERNEL" \
                "$original_manifest" "$installed_manifest" || enablement_rc=$?
        else
            service_enablement_restore "${CLASHCTL_SERVICE_MANAGER:-}" "$CLASHCTL_KERNEL" \
                "$original_manifest" || enablement_rc=$?
        fi
        if [ "$enablement_rc" -ne 0 ]; then
            _ui_error '恢复安装前的精确自启状态失败'
            _ui_detail '原因' "${SERVICE_ENABLEMENT_ERROR:-未知错误}"
            _ui_detail '原始快照' "$original_manifest"
            [ -z "$installed_manifest" ] || _ui_detail '安装快照' "$installed_manifest"
            failures=1
        fi
    elif [ "$exact_enablement" -eq 0 ] && [ -n "$source" ]; then
        _service_restore_enablement "${CLASHCTL_SERVICE_WAS_ENABLED:-0}" "$original_link_target" >/dev/null 2>&1 || true
        if [ "${CLASHCTL_SERVICE_WAS_ENABLED:-0}" = 1 ]; then
            service_is_enabled >/dev/null 2>&1 || {
                _ui_error '恢复安装前的服务自启状态失败'
                failures=1
            }
        elif service_is_enabled >/dev/null 2>&1; then
            _ui_error '恢复安装前的服务禁用状态失败'
            failures=1
        fi
    elif [ "${CLASHCTL_SERVICE_MANAGER:-}" = runit ] &&
        [ "${CLASHCTL_SERVICE_ENABLE_KIND:-absent}" = symlink ]; then
        _service_restore_enablement 1 "$original_link_target" >/dev/null 2>&1 || failures=1
    fi

    if [ "$definition_restored" -eq 1 ] && [ "${CLASHCTL_SERVICE_WAS_ACTIVE:-0}" = 1 ]; then
        service_start >/dev/null 2>&1 || true
        if ! service_is_active >/dev/null 2>&1; then
            _ui_error "重新启动安装前的 $CLASHCTL_KERNEL 服务失败"
            failures=1
        fi
    elif [ "$definition_restored" -eq 1 ] && service_is_active >/dev/null 2>&1; then
        _ui_error '恢复安装前的停止状态失败'
        failures=1
    fi
    if [ "$failures" -ne 0 ]; then
        _install_report_retained_recovery '原服务状态未能完整恢复'
        return 1
    fi

    if ! /usr/bin/rm -f -- "$journal"; then
        _ui_error '原服务已恢复，但事务快照清理失败；恢复材料均已保留'
        _ui_detail '事务快照' "$journal"
        [ -z "${CLASHCTL_SERVICE_BACKUP:-}" ] || _ui_detail '服务备份' "$CLASHCTL_SERVICE_BACKUP"
        return 1
    fi
    if ! _install_cleanup_enablement_manifests; then
        _ui_error '原服务已恢复，但服务自启快照清理失败'
        for original_manifest in "${CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL:-}" \
            "${CLASHCTL_SERVICE_ENABLEMENT_INSTALLED:-}"; do
            [ -n "$original_manifest" ] &&
                { [ -e "$original_manifest" ] || [ -L "$original_manifest" ]; } &&
                _ui_detail '残留快照' "$original_manifest"
        done
        return 1
    fi
    if [ "${CLASHCTL_SERVICE_BACKUP_CREATED:-0}" = 1 ] &&
        ! /usr/bin/rm -f -- "${CLASHCTL_SERVICE_BACKUP:-}"; then
        _ui_error '原服务已恢复，但临时备份清理失败'
        _ui_detail '残留备份' "$CLASHCTL_SERVICE_BACKUP"
        return 1
    fi
    _ui_warn '安装未完成，已恢复安装前的服务定义、自启与运行状态'
    return 0
}

_install_abort_service_transaction() {
    local restore_rc=0
    _install_restore_service || restore_rc=1
    _INSTALL_SERVICE_TRANSACTION=0
    trap - INT TERM HUP
    return "$restore_rc"
}

_already_installed() {
    local home=$1
    if [ ! -f "$home/scripts/cmd/update.sh" ]; then
        _ui_error "检测到不支持在线更新的旧版安装: $home"
        _ui_detail '操作前备份' "$home/resources/{config,mixin,profiles}.yaml 和 profiles/"
        _ui_detail '卸载命令' "bash $home/uninstall.sh"
    else
        _ui_error "clashctl 已安装: $home"
        _ui_detail '更新' 'clashctl update'
        _ui_detail '重装' "先执行 bash $home/uninstall.sh"
    fi
}

_install_report_incomplete_home() {
    local home=${_INSTALL_TARGET_HOME:-${CLASHCTL_HOME:-}}
    [ "${_INSTALL_INCOMPLETE_SUMMARY_SHOWN:-0}" != 1 ] || return 0
    [ "${_INSTALL_HOME_STATE:-}" = resume ] || return 0
    [ -n "$home" ] && [ -d "$home" ] && [ ! -L "$home" ] || return 0
    [ ! -e "$home/.env" ] && [ ! -L "$home/.env" ] || return 0
    _install_marker_validate "$home" >/dev/null 2>&1 || return 0
    _install_layout_is_trusted "$home" >/dev/null 2>&1 || return 0

    _ui_blank
    _ui_error '安装未完成；安装目录和运行数据已保留'
    _ui_detail '目录' "$home"
    _ui_detail '继续原安装' '审核目录内的 install.sh 后，直接运行它；安装器会重新校验该目录'
    _ui_detail '全新安装' '先备份 data/ 和 archives/（如需），确认备份后删除整个安装目录，再重新安装'
    _INSTALL_INCOMPLETE_SUMMARY_SHOWN=1
}

_install_refuse_incomplete_source_change() {
    local home=$1 branch=$2 kernel=$3 subscription_file=${4:-}
    local argument quoted resume_command
    local -a resume_args=(--home "$home" --branch "$branch")
    [ -z "$subscription_file" ] ||
        resume_args+=(--subscription-file "$subscription_file")
    resume_args+=("$kernel")
    printf -v resume_command 'bash %q' "$home/install.sh"
    for argument in "${resume_args[@]}"; do
        printf -v quoted '%q' "$argument"
        resume_command+=" $quoted"
    done

    _ui_blank
    _ui_error '检测到未完成安装；拒绝用另一份程序文件自动覆盖'
    _ui_detail '目录' "$home"
    _ui_detail '原因' '目录中可能保留配置、日志或待恢复的服务事务，自动覆盖可能造成数据丢失'
    _ui_detail '当前状态' '未刷新、搬移或删除现有内容'
    _ui_detail '推荐处理' "先备份 $home/data 和 $home/archives（如需），确认备份后删除整个 $home，再重试"
    _ui_detail '原版本续装' "$resume_command"
    _ui_detail '注意' '原版本可能重复上次失败；仅在审核目录内脚本并确认继续使用时选择'
    _INSTALL_INCOMPLETE_SUMMARY_SHOWN=1
}

_require_empty_home() {
    local home=$1 parent first marker
    parent=$home
    marker="$home/$_INSTALL_MARKER_NAME"
    _INSTALL_HOME_STATE=new

    if [ ! -e "$home" ] && [ ! -L "$home" ]; then
        while [ ! -d "$parent" ]; do parent=$(dirname -- "$parent"); done
        [ -w "$parent" ] || {
            _ui_error "安装目录不可写: $home"
            _ui_detail '解决方法' '使用 --home 指定可写目录'
            return 1
        }
        return 0
    fi
    _install_owned_directory "$home" || {
        _ui_error '目标目录的类型、归属或权限不安全，拒绝使用'
        _ui_detail '目录' "$home"
        _ui_detail '要求' "目录归当前 uid=$(id -u) 所有，且组用户和其他用户不可写"
        return 1
    }

    first=$(find "$home" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null) || return 1
    [ -n "$first" ] || return 0

    if [ -e "$marker" ] || [ -L "$marker" ]; then
        _install_marker_validate "$home" || {
            _ui_error '安装身份标记无效或与当前目录不匹配，拒绝执行其中脚本'
            _ui_detail '标记' "$marker"
            return 1
        }
        _install_layout_is_trusted "$home" || {
            _ui_error '安装目录中的脚本归属、权限或结构异常，拒绝继续'
            _ui_detail '目录' "$home"
            return 1
        }
        if [ -e "$home/.env" ] || [ -L "$home/.env" ]; then
            _already_installed "$home"
            return 1
        fi
        _INSTALL_HOME_STATE=resume
        _ui_warn "检测到可信的未完成安装: $home"
        return 0
    fi

    if [ "${CLASHCTL_ALLOW_LEGACY_LAYOUT:-0}" = 1 ]; then
        _install_layout_is_trusted "$home" || {
            _ui_error '旧版目录未通过严格的脚本归属、权限与结构校验'
            _ui_detail '目录' "$home"
            return 1
        }
        _install_marker_write "$home" "$home" || {
            _ui_error '旧版目录校验通过，但安装身份标记写入失败'
            return 1
        }
        _ui_warn '已通过显式授权接管旧版目录，并写入新的安装身份标记'
        if [ -e "$home/.env" ] || [ -L "$home/.env" ]; then
            _already_installed "$home"
            return 1
        fi
        _INSTALL_HOME_STATE=resume
        return 0
    fi

    _ui_error '目标目录非空且缺少有效的 clashctl 安装标记，拒绝执行其中脚本'
    _ui_detail '目录' "$home"
    _ui_detail '旧版迁移' '确认目录可信后，显式添加 --allow-legacy-layout'
    _ui_detail '新安装' '改用不存在或为空的目录'
    return 1
}

_load_install_commands() {
    local cmd_file
    for cmd_file in "$CLASHCTL_CMD_DIR"/*.sh; do
        case $cmd_file in *clashctl.sh) continue ;; esac
        # shellcheck disable=SC1090
        . "$cmd_file" || {
            _ui_error "加载安装命令模块失败: $cmd_file"
            return 1
        }
    done
}

_install_wait_service() {
    local _
    for _ in {1..20}; do
        service_is_active >/dev/null 2>&1 && return 0
        sleep 0.25
    done
    _ui_error "$CLASHCTL_KERNEL 服务未能进入运行状态"
    # shellcheck disable=SC2154  # 由 detect_service_manager 设置
    _ui_detail '日志' "$service_log_path"
    return 1
}

_install_service_diagnostic() {
    local manager=$1 startup_error=${2:-}
    if [ "${CLASHCTL_VERBOSE:-}" = 1 ] && [ -s "$startup_error" ]; then
        _ui_detail '启动错误' '如下'
        sed 's/^/        | /' "$startup_error" >&2
    elif [ -s "$startup_error" ]; then
        _ui_detail '启动错误' "$startup_error（使用 --verbose 重试可直接查看）"
    fi
    case $manager in
    systemd) _ui_detail '服务日志' "journalctl -u ${CLASHCTL_KERNEL}.service --no-pager -n 80" ;;
    *) _ui_detail '服务日志' "tail -n 80 ${service_log_path}" ;;
    esac
}

_install_cleanup_controller_header() {
    local header_file=${_INSTALL_CONTROLLER_HEADER_FILE:-}
    [ -n "$header_file" ] || return 0
    if ! /usr/bin/rm -f -- "$header_file"; then
        _ui_warn '无法删除控制器认证临时文件'
        _ui_detail '文件' "$header_file"
        return 1
    fi
    _INSTALL_CONTROLLER_HEADER_FILE=
}

_install_wait_controller() {
    local addr host request_host port secret header_file _
    _install_private_locals secret
    addr=$("$BIN_YQ" '.external-controller // ""' "$CLASH_CONFIG_RUNTIME") || return 1
    host=${addr%:*}
    port=${addr##*:}
    case $host in '' | 0.0.0.0 | :: | '[::]') host=127.0.0.1 ;; esac
    request_host=$host
    case $request_host in \[*\]) ;; *:*) request_host="[$request_host]" ;; esac
    secret=$(_get_secret) || return 1
    _install_cleanup_controller_header || return 1
    _INSTALL_CONTROLLER_HEADER_FILE=$(mktemp "${CLASH_DATA_DIR}/.controller-header.XXXXXX") || return 1
    header_file=$_INSTALL_CONTROLLER_HEADER_FILE
    chmod 0600 "$header_file" || {
        _install_cleanup_controller_header || true
        return 1
    }
    printf 'Authorization: Bearer %s\n' "$secret" >"$header_file" || {
        _install_cleanup_controller_header || true
        return 1
    }
    for _ in {1..20}; do
        curl --disable --silent --show-error --fail --noproxy '*' --max-time 1 \
            --header "@$header_file" "http://${request_host}:${port}/version" >/dev/null 2>&1 && {
            _install_cleanup_controller_header || return 1
            CLASHCTL_VERIFIED_CONTROLLER=$addr
            return 0
        }
        sleep 0.25
    done
    _install_cleanup_controller_header || return 1
    return 1
}

_write_install_env() {
    local kernel=$1 branch=$2 tmp="${CLASHCTL_SRC}/.env.installing" rc=0
    local original_state='' original_links='' installed_state='' installed_links=''
    local exact_enablement=0
    if _install_retain_enablement_snapshots; then
        exact_enablement=1
        if ! service_enablement_validate "${CLASHCTL_SERVICE_MANAGER}" "$kernel" \
            "${CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL:-}"; then
            _ui_error '安装前的服务自启快照在提交前校验失败'
            _ui_detail '原因' "${SERVICE_ENABLEMENT_ERROR:-未知错误}"
            return 1
        fi
        original_state=$SERVICE_ENABLEMENT_STATE
        original_links=$SERVICE_ENABLEMENT_LINKS
        if ! service_enablement_validate "${CLASHCTL_SERVICE_MANAGER}" "$kernel" \
            "${CLASHCTL_SERVICE_ENABLEMENT_INSTALLED:-}"; then
            _ui_error '本次安装的服务自启快照在提交前校验失败'
            _ui_detail '原因' "${SERVICE_ENABLEMENT_ERROR:-未知错误}"
            return 1
        fi
        installed_state=$SERVICE_ENABLEMENT_STATE
        installed_links=$SERVICE_ENABLEMENT_LINKS
    fi
    cp "${CLASHCTL_SRC}/.env.example" "$tmp" || {
        _ui_error '无法创建安装配置文件'
        return 1
    }
    export CLASHCTL_ENV_PATH=$tmp
    _set_env CLASHCTL_KERNEL "$kernel" || rc=1
    [ -z "$branch" ] || _set_env CLASHCTL_UPDATE_BRANCH "$branch" || rc=1
    [ "${GH_PROXY+x}" != x ] || _set_env GH_PROXY "$GH_PROXY" || rc=1
    [ "${CLASHCTL_DOWNLOAD_TIMEOUT+x}" != x ] ||
        _set_env CLASHCTL_DOWNLOAD_TIMEOUT "$CLASHCTL_DOWNLOAD_TIMEOUT" || rc=1
    _set_envs || rc=1
    if [ "${CLASHCTL_SERVICE_CONFLICT:-}" = 1 ] || [ "$exact_enablement" -eq 1 ]; then
        _set_env CLASHCTL_REPLACED_SERVICE_MANAGER "$CLASHCTL_SERVICE_MANAGER" || rc=1
        _set_env CLASHCTL_REPLACED_SERVICE_SOURCE "$CLASHCTL_SERVICE_SOURCE" || rc=1
        _set_env CLASHCTL_REPLACED_SERVICE_TARGET "$CLASHCTL_SERVICE_TARGET" || rc=1
        _set_env CLASHCTL_REPLACED_SERVICE_BACKUP "$CLASHCTL_SERVICE_BACKUP" || rc=1
        _set_env CLASHCTL_REPLACED_SERVICE_WAS_ACTIVE "$CLASHCTL_SERVICE_WAS_ACTIVE" || rc=1
        _set_env CLASHCTL_REPLACED_SERVICE_WAS_ENABLED "$CLASHCTL_SERVICE_WAS_ENABLED" || rc=1
        _set_env CLASHCTL_REPLACED_SERVICE_ENABLE_LINK "${CLASHCTL_SERVICE_ENABLE_LINK:-}" || rc=1
        _set_env CLASHCTL_REPLACED_SERVICE_ENABLE_KIND "${CLASHCTL_SERVICE_ENABLE_KIND:-absent}" || rc=1
        _set_env CLASHCTL_REPLACED_SERVICE_ENABLE_TARGET "${CLASHCTL_SERVICE_ENABLE_TARGET:-}" || rc=1
        _set_env CLASHCTL_REPLACED_SERVICE_EXPECTED_ENABLE_TARGET \
            "${CLASHCTL_SERVICE_EXPECTED_ENABLE_TARGET:-}" || rc=1
        if [ "$exact_enablement" -eq 1 ]; then
            _set_env CLASHCTL_REPLACED_SERVICE_ENABLEMENT_FORMAT \
                clashctl-service-enablement-v1 || rc=1
            _set_env CLASHCTL_REPLACED_SERVICE_ENABLEMENT_STATE "$original_state" || rc=1
            _set_env CLASHCTL_REPLACED_SERVICE_ENABLEMENT_LINKS "$original_links" || rc=1
            _set_env CLASHCTL_REPLACED_SERVICE_INSTALLED_ENABLEMENT_STATE \
                "$installed_state" || rc=1
            _set_env CLASHCTL_REPLACED_SERVICE_INSTALLED_ENABLEMENT_LINKS \
                "$installed_links" || rc=1
        fi
    fi
    unset CLASHCTL_ENV_PATH
    if [ "$rc" -ne 0 ] || ! chmod 0600 "$tmp" ||
        ! /bin/mv -f -- "$tmp" "${CLASHCTL_SRC}/.env"; then
        /usr/bin/rm -f -- "$tmp"
        _ui_error '无法完成安装配置文件写入'
        return 1
    fi
    _ui_ok '安装结果已验证并写入完成标记'
}

_install_finish() {
    local manager=$1 subscription=$2 transaction_state=${3:-complete}
    local apply_rc_status=0 shell_state=ready result=0
    apply_rc || apply_rc_status=$?
    case $apply_rc_status in
    0) ;;
    2) shell_state=manual ;;
    *) shell_state=failed result=1 ;;
    esac
    [ "$transaction_state" = complete ] || result=1
    _install_complete "$manager" "$subscription" "$shell_state" "$transaction_state"
    return "$result"
}

_install_complete() {
    local manager=$1 subscription=$2 shell_state=${3:-ready} transaction_state=${4:-complete}
    local addr host port load_command journal backup
    addr=${CLASHCTL_VERIFIED_CONTROLLER:-}
    host=${addr%:*}
    port=${addr##*:}
    [ "$host" != 0.0.0.0 ] || host=$(_get_local_ip)
    case $host in '' | :: | '[::]') host=127.0.0.1 ;; esac
    case $host in \[*\]) ;; *:*) host="[$host]" ;; esac

    _ui_blank
    if [ "$transaction_state" != complete ]; then
        _ui_error 'clashctl 已安装并运行，但服务事务清理未完成'
        _ui_detail '命令状态' '本次安装以失败退出；不要将其视为完整成功'
        journal=${CLASHCTL_SERVICE_JOURNAL:-${CLASHCTL_HOME}/.service-transaction}
        backup=${CLASHCTL_SERVICE_BACKUP:-}
        if [ -e "$journal" ] || [ -L "$journal" ]; then
            _ui_detail '事务快照' "$journal"
        fi
        if [ -n "$backup" ] && { [ -e "$backup" ] || [ -L "$backup" ]; }; then
            _ui_detail '服务备份' "$backup"
        fi
        [ "$shell_state" != manual ] ||
            _ui_warn '未检测到可更新的 Shell 启动文件；当前终端需手动加载命令'
        [ "$shell_state" != failed ] ||
            _ui_error 'Shell 命令集成也未能完成'
    else
        case $shell_state in
        ready) _ui_ok 'clashctl 安装完成' ;;
        manual)
            _ui_ok 'clashctl 核心安装完成'
            _ui_warn '未检测到可更新的 Shell 启动文件；当前终端需手动加载命令'
            ;;
        *)
            _ui_error 'clashctl 服务与数据已安装，但 Shell 命令集成失败'
            ;;
        esac
    fi
    _ui_detail '目录' "$CLASHCTL_HOME"
    _ui_detail '服务' "$manager · 运行中"
    _ui_detail '订阅' "$subscription"
    _ui_detail '控制台' "http://${host}:${port}/ui"
    _ui_detail '访问密钥' '已配置（运行 clashctl secret 查看）'
    [ "${CLASHCTL_SERVICE_CONFLICT:-}" != 1 ] || _ui_detail '原服务备份' "$CLASHCTL_SERVICE_BACKUP"
    _ui_blank
    if [ "$shell_state" = ready ]; then
        _ui_info '下一步'
        _ui_detail '加载命令' "exec ${SHELL:-bash} -l"
    else
        printf -v load_command 'source %q' "$CLASHCTL_CMD_DIR/clashctl.sh"
        if [ "$shell_state" = manual ]; then
            _ui_info '手动加载'
            _ui_detail '运行' "$load_command"
        else
            _ui_info '修复 Shell 集成'
            _ui_detail '检查' "Shell 配置权限与 $CLASHCTL_CMD_DIR/clashctl.sh"
            _ui_detail '尝试加载' "$load_command"
        fi
    fi
    [ "$subscription" != '未配置' ] || _ui_detail '添加订阅' 'clashctl sub add --use <URL>'
    _ui_detail '查看状态' 'clashctl status'
}

# 下载只写入由安装器创建的暂存目录，最终目录由 _install_finalize_stage 原子提交。
_fetch_into() {
    local destination=$1 branch=$2 proxy=$3 url archive

    _ui_step '获取安装文件'
    _ui_detail '仓库' "$_REPO"
    _ui_detail '分支' "$branch"
    if command -v git >/dev/null 2>&1; then
        url=${CLASHCTL_UPDATE_GIT_URL:-}
        [ -n "$url" ] || {
            url="https://github.com/${_REPO}.git"
            [ -n "$proxy" ] && url="${proxy%/}/${url}"
        }
        local -a clone_args=(-q --depth 50 --single-branch --branch "$branch")
        [ ! -t 2 ] || [ "${CLASHCTL_VERBOSE:-}" != 1 ] || clone_args+=(--progress)
        git -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=60 clone "${clone_args[@]}" -- "$url" "$destination" && {
            git -C "$destination" config gc.auto 0
            _ui_ok '安装文件已下载'
            return 0
        }
        _ui_warn 'Git 下载失败，正在改用归档下载'
        _install_reset_stage "$destination" || {
            _ui_error '无法重置安装暂存目录'
            return 1
        }
    fi

    url="https://codeload.github.com/${_REPO}/tar.gz/refs/heads/${branch}"
    [ -n "$proxy" ] && url="${proxy%/}/${url}"
    archive=$(mktemp) || {
        _ui_error '无法创建归档下载临时文件'
        return 1
    }
    local -a curl_args=(--show-error --fail --location --max-time "${CLASHCTL_DOWNLOAD_TIMEOUT:-60}" --retry 1)
    if [ -t 2 ] && [ "${CLASHCTL_VERBOSE:-}" = 1 ]; then
        curl_args+=(--progress-bar)
    else
        curl_args+=(--silent)
    fi
    if ! curl "${curl_args[@]}" --output "$archive" --url "$url" ||
        ! tar -xzf "$archive" --strip-components=1 --no-same-owner --no-same-permissions \
            -C "$destination"; then
        /usr/bin/rm -f -- "$archive"
        _ui_error '下载安装文件失败'
        _ui_detail '排查' '检查网络，或设置 GH_PROXY=<加速前缀> 后重试'
        return 1
    fi
    /usr/bin/rm -f -- "$archive"
    _ui_ok '安装文件已下载'
}

usage() {
    cat <<'EOF'
Usage:
  bash install.sh [OPTIONS] [mihomo|clash]

Options:
  --home <路径>             安装路径（默认 ~/.clashctl）
  --branch <分支>           安装分支及后续更新分支（默认 master）
  --source-dir <路径>       从明确指定的本地源码目录安装
  --subscription-file <文件> 从权限受限的单行文件读取初始订阅 URL
  --allow-legacy-layout     显式接管并升级无安装标记的旧版目录
  --take-over-service       允许备份并接管现有同名服务
  --non-interactive         禁用所有交互；缺少订阅时直接跳过
  --verbose                 显示下载进度与失败诊断
  --color <模式>            auto、always 或 never（默认 auto）
  --no-color                等同于 --color never
  -h, --help                显示帮助信息

安装期也支持环境变量：CLASHCTL_HOME、GH_PROXY、CLASHCTL_DOWNLOAD_TIMEOUT、
CLASHCTL_CHECK_LATEST_VERSION、VERSION_MIHOMO/YQ/SUBCONVERTER/UI、SUBCONVERTER_REPO、
CLASHCTL_SUBSCRIPTION_FILE、CLASHCTL_ALLOW_UNIT_OVERWRITE=1、CLASHCTL_COLOR、NO_COLOR。

订阅 URL 不接受位置参数或 CLASHCTL_SUB_URL 环境变量，避免泄漏到 Shell 历史、
进程参数或子进程环境；请使用 --subscription-file，或在交互提示中隐藏输入。
EOF
}

_install_entrypoint() {
    _INSTALL_STREAM_COMPLETE=1
    # 流式执行时 fd0 正在承载脚本内容；脚本完整解析后，再通过 fd3 向 main 提供终端输入。
    if [ ! -t 0 ] && (exec 3</dev/tty) 2>/dev/null; then
        exec 3</dev/tty
        main "$@" <&3
        local install_rc=$?
        exec 3<&-
        return "$install_rc"
    else
        main "$@"
    fi
}

if [ "${CLASHCTL_INSTALL_SOURCE_ONLY:-}" != 1 ]; then
    _install_entrypoint "$@"
fi
# this ensures the entire script is downloaded #
