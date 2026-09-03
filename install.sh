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

    # 本脚本只负责 CLI 落位（源码获取/标记/迁移/交接）；服务事务的守卫在
    # clashctl install（scripts/cmd/install.sh 的 _ci_exit_guard）里。
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


# 取源 + 交互救援：直连失败时现场询问加速前缀并重试（仅交互环境；CI/
# 非交互保持快速失败与 --gh-proxy 文案指引）。输入的前缀经校验后 export，
# stage-2 组件下载全链路继承并随收尾物化 .env（与旗标语义一致）。
_install_fetch_home() {
    local home=$1 branch=$2 proxy=$3 stage answer
    while :; do
        _install_create_stage "$home" stage || return 1
        if _fetch_into "$stage" "$branch" "$proxy" &&
            _install_finalize_stage "$stage" "$home"; then
            return 0
        fi
        _install_discard_stage "$stage" || true
        _install_can_prompt || return 1
        _ui_blank
        _ui_warn '获取安装文件失败：GitHub 直连受限或网络不可用'
        if _ui_color_enabled 2; then
            printf '\033[35m[ ? ]\033[0m 加速前缀重试（如 https://gh-proxy.org/，回车重试直连，Ctrl-C 退出）: ' >&2
        else
            printf '[ ? ] 加速前缀重试（如 https://gh-proxy.org/，回车重试直连，Ctrl-C 退出）: ' >&2
        fi
        IFS= read -r answer || {
            printf '\n' >&2
            return 1
        }
        case $answer in
        '') ;;
        https://* | http://*)
            if _install_has_control_chars "$answer"; then
                _ui_error '加速前缀不能包含控制字符'
                continue
            fi
            proxy=${answer%/}
            export GH_PROXY=$proxy
            ;;
        *)
            _ui_error '加速前缀需以 http:// 或 https:// 开头'
            ;;
        esac
    done
}

_install_reexec() {
    # 全新落位后的交接：stage-2 识别为自身续装，无需再提示「未完成安装」
    export _INSTALL_FRESH_HANDOFF=1
    local script=$1 home=$2 branch=$3 kernel=$4 subscription_file=${5:-}
    local -a args=(--home "$home" --branch "$branch")
    [ -z "$subscription_file" ] || args+=(--subscription-file "$subscription_file")
    args+=("$kernel")
    exec bash "$script" "${args[@]}"
}

# 主体包进 main 函数：管道/下载截断只拿到半截时，bash 解析未闭合函数直接报语法错误、零执行
main() {
    umask 077
    local home=${CLASHCTL_HOME:-} branch=$_BRANCH_DEFAULT
    local kernel=mihomo sub_url= branch_explicit=0 home_branch=
    local proxy=${GH_PROXY-} home_source=default
    local source_dir=${CLASHCTL_LOCAL_SOURCE:-$CLASHCTL_SRC}
    local subscription_file=${CLASHCTL_SUBSCRIPTION_FILE:-} install_arg legacy_candidate
    case $subscription_file in
    http://* | https://* | file://*)
        _ui_error 'CLASHCTL_SUBSCRIPTION_FILE 需要文件路径而非 URL（URL 不进环境）'
        _ui_detail '自动化' '将 URL 写入权限为 0600 的单行文件后改用 --subscription-file'
        return 1
        ;;
    esac
    _install_private_locals sub_url
    [ -z "${CLASHCTL_HOME:-}" ] || home_source=CLASHCTL_HOME
    # 未指定安装路径时：脚本自身就在一个已标记的安装目录里（典型：按提示
    # 重跑目录内 install.sh 续装）→ 以脚本目录为安装目录，续装命令免 --home
    if [ -z "$home" ] && _install_marker_validate "$_INSTALL_SCRIPT_DIR"; then
        home=$_INSTALL_SCRIPT_DIR
        home_source=script-dir
    fi

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
            branch=$1 branch_explicit=1
            ;;
        --branch=*)
            branch=${1#*=}
            [ -n "$branch" ] || {
                _ui_error '--branch 缺少分支参数'
                return 1
            }
            branch_explicit=1
            ;;
        --gh-proxy)
            shift
            [ $# -gt 0 ] || {
                _ui_error '--gh-proxy 缺少地址参数（置空字符串为直连）'
                return 1
            }
            proxy=$1
            export GH_PROXY=$proxy
            ;;
        --gh-proxy=*)
            proxy=${1#*=}
            export GH_PROXY=$proxy
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
            case $1 in
            http://* | https://* | file://*)
                _ui_error '--subscription-file 需要文件路径而非 URL（URL 不进命令行）'
                _ui_detail '自动化' '将 URL 写入权限为 0600 的单行文件后再传入'
                return 1
                ;;
            esac
            subscription_file=$1
            ;;
        --subscription-file=*)
            subscription_file=${1#*=}
            [ -n "$subscription_file" ] || {
                _ui_error '--subscription-file 缺少文件路径'
                return 1
            }
            case $subscription_file in
            http://* | https://* | file://*)
                _ui_error '--subscription-file 需要文件路径而非 URL（URL 不进命令行）'
                _ui_detail '自动化' '将 URL 写入权限为 0600 的单行文件后再传入'
                return 1
                ;;
            esac
            ;;
        --allow-legacy-layout) _INSTALL_ALLOW_LEGACY_LAYOUT=1 ;;
        --take-over-service) CLASHCTL_ALLOW_UNIT_OVERWRITE=1 ;;
        --non-interactive) CLASHCTL_NON_INTERACTIVE=1 ;;
        --verbose) _INSTALL_VERBOSE=1 ;;
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
    # 旧版（master 时代 ~/clashctl 布局）检测：旧布局目录是迁移源而非安装目标。
    # 显式 --home 指到旧目录 = 原地接管，仍走 --allow-legacy-layout 语义。
    _INSTALL_LEGACY_HOME=
    for legacy_candidate in "${CLASHCTL_HOME:-}" "${HOME}/clashctl"; do
        [ -n "$legacy_candidate" ] || continue
        [ "$legacy_candidate" != "${_INSTALL_LEGACY_CHECKED:-}" ] || continue
        _INSTALL_LEGACY_CHECKED=$legacy_candidate
        _install_legacy_candidate "$legacy_candidate" || continue
        if [ "$home" = "$legacy_candidate" ] && [ "$home_source" = --home ]; then
            break
        fi
        _INSTALL_LEGACY_HOME=$legacy_candidate
        if [ "$home_source" != --home ]; then
            home=
            home_source=default
        fi
        break
    done
    [ -n "$home" ] || home="${HOME}/.clashctl"
    # 未显式指定分支时：沿用未完成安装 git 仓库的现有分支——续装不漂移
    # 更新通道（显式 --branch > 家的分支 > master 默认）
    if [ "${branch_explicit:-0}" != 1 ] && command -v git >/dev/null 2>&1 &&
        [ -d "$home/.git" ]; then
        home_branch=$(git -C "$home" rev-parse --abbrev-ref HEAD 2>/dev/null) &&
            [ -n "$home_branch" ] && [ "$home_branch" != HEAD ] &&
            branch=$home_branch
        [ "$branch" = "${home_branch:-}" ] ||
            _ui_warn "未能读取安装目录的现有分支，按默认分支 $branch 继续"
    fi
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
    fi
    _install_validate_home_path "$home" "$source_dir" || return 1
    case ${CLASHCTL_COLOR:-auto} in
    auto | always | never) ;;
    *)
        _ui_error "无效颜色模式: ${CLASHCTL_COLOR}（可选 auto、always、never）"
        return 1
        ;;
    esac
    export CLASHCTL_COLOR
    [ -z "${_INSTALL_VERBOSE:-}" ] || export _INSTALL_VERBOSE
    [ -z "${CLASHCTL_NON_INTERACTIVE:-}" ] || export CLASHCTL_NON_INTERACTIVE
    [ -z "${CLASHCTL_ALLOW_UNIT_OVERWRITE:-}" ] || export CLASHCTL_ALLOW_UNIT_OVERWRITE
    [ -z "${_INSTALL_ALLOW_LEGACY_LAYOUT:-}" ] || export _INSTALL_ALLOW_LEGACY_LAYOUT
    case $kernel in
    mihomo | clash) ;;
    *)
        _ui_error "不支持的内核: $kernel（可选 mihomo 或 clash）"
        return 1
        ;;
    esac

    if [ "${CLASHCTL_INSTALL_SESSION:-}" != 1 ]; then
        _install_plan "$home" "$home_source" "$kernel" "$branch" \
            "$subscription_file" "$source_dir"
        export CLASHCTL_INSTALL_SESSION=1
    fi

    # 先验证目标目录，再询问或执行任何接管操作。
    _require_empty_home "$home" || return 1

    if [ "$_INSTALL_HOME_STATE" = resume ]; then
        # 旧版原地接管（--allow-legacy-layout，旗标见 _require_empty_home）：
        # resources/ 里是用户数据，刷新会整目录替换——先把数据就地迁入 data/
        if [ "${_INSTALL_LEGACY_TAKEOVER:-0}" = 1 ]; then
            _ui_step '迁移旧版数据到 data/'
            # 旧 bin/ 是平铺文件（bin/mihomo 为文件），与新布局 bin/<内核>/
            # 目录冲突；内核本就要重下，旧 bin 挪为 .bak 不参与安装
            if [ -e "$home/bin" ] && [ ! -d "$home/bin/$kernel" ]; then
                mv -f -- "$home/bin" \
                    "$home/bin.clashctl-legacy.$(date +%s)" || {
                    _ui_error '旧版 bin 目录无法挪开'
                    return 1
                }
            fi
            /usr/bin/install -d -m 0700 "$home/data" "$home/data/profiles" || return 1
            local legacy_item
            for legacy_item in config.yaml mixin.yaml profiles.yaml; do
                [ -f "$home/resources/$legacy_item" ] || continue
                /usr/bin/install -m 0600 "$home/resources/$legacy_item" \
                    "$home/data/$legacy_item" || return 1
            done
            if [ -d "$home/resources/profiles" ]; then
                cp -a -- "$home/resources/profiles/." "$home/data/profiles/" || return 1
                chmod 0600 -- "$home/data/profiles"/*.yaml 2>/dev/null || true
            fi
            _ui_ok "旧版数据已迁入 $home/data"
        fi
        if [ "${CLASHCTL_SRC:-}" != "$home" ]; then
            # 空壳自动续装：先把程序文件刷到本次安装器的最新版，失败才降级
            # 为原地续装指引（离线时可跑旧代码完成）
            if ! _install_refresh_source "$home" "$branch" "$proxy"; then
                _ui_warn '未能刷新程序文件（目录可能已部分更新），可按下方指引用现有文件续装'
                _install_refuse_incomplete_source_change \
                    "$home" "$branch" "$kernel" "$subscription_file"
                return 1
            fi
            CLASHCTL_SRC=$home
        fi
        [ "${_INSTALL_FRESH_HANDOFF:-0}" = 1 ] ||
            _ui_info "继续未完成的安装: $home"
    fi

    unset CLASHCTL_SUBSCRIPTION_FILE CLASHCTL_SUB_URL

    if [ -z "$CLASHCTL_SRC" ]; then
        _install_fetch_home "$home" "$branch" "$proxy" || return 1
        export CLASHCTL_LOCAL_SOURCE=$home
        _install_reexec "${home}/install.sh" "$home" "$branch" "$kernel" "$subscription_file"
        return 0
    fi

    if [ "${CLASHCTL_SRC}" != "$home" ]; then
        local source_stage
        _install_create_stage "$home" source_stage || return 1
        _ui_step '准备安装文件'
        if command -v git >/dev/null 2>&1 && [ -d "${CLASHCTL_SRC}/.git" ]; then
            local -a clone_args=()
            if [ -t 2 ]; then clone_args+=(--progress); else clone_args+=(-q); fi
            git clone "${clone_args[@]}" "$CLASHCTL_SRC" "$source_stage" || {
                _ui_error '复制本地 Git 仓库失败'
                _install_discard_stage "$source_stage" || true
                return 1
            }
        else
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
        return 0
    fi

    export CLASHCTL_HOME="$home"

    # 旧版（master 时代 ~/clashctl 布局）数据自动迁移：把订阅/配置种子到新家，
    # clashctl install 的数据骨架「存在即跳过」会原样保留迁移内容。
    _install_migrate_legacy_data "$home" || return 1

    _install_handoff_to_clashctl "$home" "$kernel" "$branch" "$subscription_file"
}

# 交接给 clashctl install（内核/组件/服务/订阅在此完成）；测试以本函数为桩点。
_install_handoff_to_clashctl() {
    local home=$1 kernel=$2 branch=$3 subscription_file=$4
    _ui_step '安装内核与服务（clashctl install）'
    local -a install_args=(install "$kernel" --branch "$branch")
    [ -z "$subscription_file" ] ||
        install_args+=(--subscription-file "$subscription_file")
    # 环境变量（NON_INTERACTIVE/ALLOW_UNIT_OVERWRITE/颜色/verbose 等）经 exec 继承
    exec bash -c '. "$1/scripts/cmd/clashctl.sh"; clashctl "${@:2}"' \
        _ "$home" "${install_args[@]}"
}

_install_plan() {
    local home=$1 home_source=$2 kernel=$3 branch=$4 subscription_file=$5 source_dir=${6:-}
    local privilege="普通用户 (uid=$(id -u))"
    local source="${_REPO} · ${branch}" shell_plan shell_target
    local -a shell_targets=()
    case $home_source in
    default) home_source=默认 ;;
    CLASHCTL_HOME) home_source=CLASHCTL_HOME ;;
    script-dir) home_source=脚本目录 ;;
    --home) home_source='--home' ;;
    esac
    [ "$(id -u)" -ne 0 ] || privilege=root
    [ -z "$source_dir" ] || source="本地源码 · ${source_dir}"
    command -v bash >/dev/null 2>&1 && [ -f "${HOME}/.bashrc" ] &&
        shell_targets+=(bash)
    command -v zsh >/dev/null 2>&1 && [ -f "${HOME}/.zshrc" ] &&
        shell_targets+=(zsh)
    command -v fish >/dev/null 2>&1 && [ -d "${HOME}/.config/fish" ] &&
        shell_targets+=(fish)
    if [ ${#shell_targets[@]} -gt 0 ]; then
        shell_plan=${shell_targets[*]}
        shell_plan=${shell_plan// / · }
    else
        shell_plan='未检测到可更新的启动文件；安装后提供手动加载命令'
    fi

    _ui_blank
    _ui_header 'clashctl 安装计划'
    _ui_detail '来源' "$source"
    _ui_detail '系统' "Linux/$(uname -m) · ${privilege}"
    _ui_detail '程序目录' "${home}（${home_source}）"
    _ui_detail '代理内核' "$kernel（由 clashctl install 下载并配置服务）"
    _ui_detail 'Shell 集成' "$shell_plan"
    if [ -n "$subscription_file" ]; then
        _ui_detail '初始订阅' '已通过受限文件提供（链接不回显）'
    elif [ "${CLASHCTL_NON_INTERACTIVE:-}" = 1 ] || [ "${CI+x}" = x ] ||
        [ ! -t 0 ] || [ ! -t 2 ]; then
        _ui_detail '初始订阅' '未提供；非交互环境将跳过'
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


# 旧版（master 时代）布局特征：数据在 resources/ 下且没有安装身份标记
_install_legacy_candidate() {
    local dir=$1
    [ -n "$dir" ] && [ -d "$dir" ] || return 1
    [ ! -e "$dir/$_INSTALL_MARKER_NAME" ] || return 1
    [ -f "$dir/resources/profiles.yaml" ] ||
        [ -f "$dir/resources/config.yaml" ] ||
        [ -d "$dir/resources/profiles" ]
}

# 是否可以向用户询问（与 sub.sh 的 _sub_can_prompt 同语义；测试桩点）
_install_can_prompt() {
    [ "${CLASHCTL_NON_INTERACTIVE:-}" != 1 ] &&
        [ "${CI+x}" != x ] && [ -t 0 ] && [ -t 2 ]
}

# 把旧版数据（订阅/配置）种子到新家 data/；确认后旧目录整体改名保留，
# 防止误用旧脚本（旧版 uninstall 会按服务名删除新装的 mihomo.service）。
_install_migrate_legacy_data() {
    local home=$1 legacy=${_INSTALL_LEGACY_HOME:-} item ts backup migrate_rc=0
    [ -n "$legacy" ] || return 0
    [ "$legacy" != "$home" ] || return 0

    _ui_blank
    _ui_warn "检测到旧版安装: $legacy"
    local -a legacy_found=()
    for item in resources/profiles.yaml resources/config.yaml resources/mixin.yaml resources/profiles; do
        [ -e "$legacy/$item" ] && legacy_found+=("$item")
    done
    [ ${#legacy_found[@]} -gt 0 ] || return 0
    for item in "${legacy_found[@]}"; do
        _ui_detail '旧版数据' "$item"
    done

    if ! _install_can_prompt; then
        _ui_info '非交互环境：跳过自动迁移，安装完成后可手动迁移'
        _ui_detail '迁移配置' "cp $legacy/resources/{config,mixin,profiles}.yaml $home/data/"
        _ui_detail '迁移订阅' "cp -a $legacy/resources/profiles/. $home/data/profiles/"
        return 0
    fi
    if ! _ui_confirm '迁移上述数据并升级到新版？（旧目录将整体保留为 .bak）'; then
        _ui_info '已跳过迁移；新装完成后可按同样路径手动迁移'
        return 0
    fi

    /usr/bin/install -d -m 0700 "$home/data" "$home/data/profiles" || return 1
    for item in config.yaml mixin.yaml profiles.yaml; do
        [ -f "$legacy/resources/$item" ] || continue
        [ -e "$home/data/$item" ] ||
            /usr/bin/install -m 0600 "$legacy/resources/$item" "$home/data/$item" ||
            migrate_rc=1
    done
    if [ -d "$legacy/resources/profiles" ]; then
        cp -a -- "$legacy/resources/profiles/." "$home/data/profiles/" || migrate_rc=1
        chmod 0600 -- "$home/data/profiles"/*.yaml 2>/dev/null || true
    fi
    [ "$migrate_rc" -eq 0 ] || {
        _ui_error '旧版数据迁移失败；请检查权限后重试，或按上方指引手动迁移'
        return 1
    }
    _ui_ok "旧版数据已迁入 $home/data"

    ts=$(date +%Y%m%d%H%M%S)
    backup="${legacy}.bak.${ts}"
    if /bin/mv -f -- "$legacy" "$backup"; then
        _ui_ok "旧版目录已保留为 $backup"
        _ui_detail '后续' '确认新版可用后可删除该备份；旧 shell 引导行将在安装收尾自动清理'
    else
        _ui_warn "旧版目录改名失败，原样保留: $legacy"
    fi
    _ui_blank
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
    local home=${_INSTALL_TARGET_HOME:-${CLASHCTL_HOME:-}} quoted
    [ "${_INSTALL_INCOMPLETE_SUMMARY_SHOWN:-0}" = 0 ] || return 0
    [ -n "$home" ] || return 0
    _install_marker_validate "$home" || return 0
    _install_layout_is_trusted "$home" || return 0
    [ -f "$home/.env" ] && return 0
    _INSTALL_INCOMPLETE_SUMMARY_SHOWN=1
    printf -v quoted 'bash %q --branch %q' "$home/install.sh" \
        "${CLASHCTL_UPDATE_BRANCH:-$_BRANCH_DEFAULT}"
    _ui_blank
    _ui_warn "本次未能完成安装，目录和已有数据已保留: $home"
    _ui_detail '继续安装' "$quoted"
    _ui_detail '全新安装' "备份需要的文件后删除 $home，再重新运行安装命令"
    return 0
}

# 空壳自动续装的源刷新：把未完成安装的程序文件换成本次安装器拉到的
# 最新版本，用户数据（data/）、下载缓存（archives/）、标记、事务 journal、
# bin/ 一律保留。git 家走 fetch+checkout（同 clashctl update 机制，天然
# 不降级）；无 git 或 git 失败时回落 stage 取源+按清单替换；两者皆败返回
# 非零（调用方降级为原地续装指引）。
_INSTALL_REFRESH_PATHS=(
    install.sh
    uninstall.sh
    scripts
    resources
    versions.env
    .env.example
)

_install_refresh_source() {
    local home=$1 branch=$2 proxy=$3 url item stage refresh_rc=0

    _ui_step '刷新未完成安装的程序文件'
    # --source-dir 指定了本地源：直接从本地拷入 stage（不经网络）
    if [ -n "${CLASHCTL_SRC:-}" ] && [ "$CLASHCTL_SRC" != "$home" ]; then
        _install_create_stage "$home" stage || return 1
        if command -v git >/dev/null 2>&1 && [ -d "${CLASHCTL_SRC}/.git" ]; then
            git clone -q -- "${CLASHCTL_SRC}" "$stage" ||
                {
                    _install_discard_stage "$stage" || true
                    return 1
                }
        else
            cp -a -- "${CLASHCTL_SRC}/." "$stage"/ ||
                {
                    _install_discard_stage "$stage" || true
                    return 1
                }
        fi
        _install_refresh_apply "$home" "$stage" || return 1
        return 0
    fi
    if [ -d "$home/.git" ] && command -v git >/dev/null 2>&1 &&
        [ -n "$(git -C "$home" remote 2>/dev/null)" ]; then
        url=${CLASHCTL_UPDATE_GIT_URL:-}
        [ -n "$url" ] || {
            url="https://github.com/${_REPO}.git"
            [ -n "$proxy" ] && url="${proxy%/}/${url}"
        }
        refresh_origin_before=$(git -C "$home" remote get-url origin 2>/dev/null || printf '')
        if git -C "$home" remote set-url origin "$url" &&
            git -C "$home" -c gc.auto=0 -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=60 \
                fetch -q --depth 50 origin -- "$branch" &&
            git -C "$home" checkout -q -B "$branch" FETCH_HEAD; then
            _install_layout_is_trusted "$home" || return 1
            _ui_ok '程序文件已刷新至最新'
            return 0
        fi
        [ -z "$refresh_origin_before" ] ||
            git -C "$home" remote set-url origin "$refresh_origin_before" 2>/dev/null || :
        _ui_warn 'Git 刷新未完成安装失败，尝试重新下载'
    fi

    _install_create_stage "$home" stage || return 1
    if ! _fetch_into "$stage" "$branch" "$proxy"; then
        _install_discard_stage "$stage" || true
        return 1
    fi
    _install_refresh_apply "$home" "$stage" || return 1
    return 0
}

# 按清单把 stage 的程序文件替换进 home（用户数据/缓存/标记/journal不动）
_install_refresh_apply() {
    local home=$1 stage=$2 item incoming refresh_rc=0
    for item in "${_INSTALL_REFRESH_PATHS[@]}"; do
        [ -e "$stage/$item" ] || continue
        # 先拷入同目录暂存名再交换，避免拷贝中途失败留下空洞
        incoming="${home}/${item}.clashctl-incoming.$$"
        cp -a -- "$stage/$item" "$incoming" || {
            rm -rf -- "$incoming"
            refresh_rc=1
            continue
        }
        rm -rf -- "$home/$item"
        /bin/mv -f -- "$incoming" "$home/$item" || {
            refresh_rc=1
            continue
        }
    done
    _install_discard_stage "$stage" || true
    [ "$refresh_rc" -eq 0 ] || return 1
    _install_layout_is_trusted "$home" || return 1
    _ui_ok '程序文件已刷新至最新'
    return 0
}

_install_refuse_incomplete_source_change() {
    local home=$1 branch=$2 kernel=$3 subscription_file=${4:-}
    local argument quoted resume_command
    # 默认分支省略（裸续装经智能分支自动解析）；非默认分支必须显式携带
    local -a resume_args=()
    [ "$branch" = "$_BRANCH_DEFAULT" ] || resume_args+=(--branch "$branch")
    [ -z "$subscription_file" ] ||
        resume_args+=(--subscription-file "$subscription_file")
    [ "$kernel" = mihomo ] || resume_args+=("$kernel")
    printf -v resume_command 'bash %q' "$home/install.sh"
    for argument in "${resume_args[@]}"; do
        printf -v quoted '%q' "$argument"
        resume_command+=" $quoted"
    done

    _ui_blank
    _ui_error "上次安装没有完成，本次已停止（未做任何修改）"
    _ui_detail '安装目录' "$home"
    _ui_detail '现状' '程序文件已就位，内核与服务尚未安装'
    _ui_detail '继续安装（推荐）' "$resume_command"
    _ui_detail '重新开始' "备份需要的文件后删除 $home，再重新运行安装命令"
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
        [ "${_INSTALL_FRESH_HANDOFF:-0}" = 1 ] ||
            _ui_warn "检测到未完成的安装"
        return 0
    fi

    if [ "${_INSTALL_ALLOW_LEGACY_LAYOUT:-0}" = 1 ]; then
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
        # 旧版原地接管专属旗标：resources/ 里是用户数据。v2 空壳的 resources/
        # 只是仓库种子模板，文件特征与旧版完全重叠，只能靠本旗标区分
        _INSTALL_LEGACY_TAKEOVER=1
        _INSTALL_HOME_STATE=resume
        return 0
    fi

    _ui_error '目标目录非空且缺少有效的 clashctl 安装标记，拒绝执行其中脚本'
    _ui_detail '目录' "$home"
    _ui_detail '旧版迁移' '确认目录可信后，显式添加 --allow-legacy-layout'
    _ui_detail '新安装' '改用不存在或为空的目录'
    return 1
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
        [ ! -t 2 ] || [ "${_INSTALL_VERBOSE:-}" != 1 ] || clone_args+=(--progress)
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
    if [ -t 2 ]; then
        curl_args+=(--progress-bar)
    else
        curl_args+=(--silent)
    fi
    if ! curl "${curl_args[@]}" --output "$archive" --url "$url" ||
        ! tar -xzf "$archive" --strip-components=1 --no-same-owner --no-same-permissions \
            -C "$destination"; then
        /usr/bin/rm -f -- "$archive"
        _ui_error '下载安装文件失败'
        _ui_detail '排查' '检查网络，或加 --gh-proxy <加速前缀> 重试（也可用 GH_PROXY 环境变量）'
        return 1
    fi
    /usr/bin/rm -f -- "$archive"
    _ui_ok '安装文件已下载'
}

usage() {
    cat <<'EOF'
Usage:
  bash install.sh [OPTIONS] [mihomo|clash]

安装 clashctl 本体（脚本与 Shell 集成），随后自动执行
`clashctl install` 完成内核、组件、服务与初始订阅的配置。

Options:
  --home <路径>             安装路径（默认 ~/.clashctl）
  --branch <分支>           安装分支及后续更新分支（默认 master）
  --gh-proxy <地址>         依赖下载加速前缀（默认直连；置空同样为直连，
                            优先于 GH_PROXY 环境变量，选择将持久化到 .env）
  --source-dir <路径>       从明确指定的本地源码目录安装
  --subscription-file <文件> 从权限受限的单行文件读取初始订阅 URL
  --allow-legacy-layout     显式接管并升级无安装标记的旧版目录
  --take-over-service       允许接管现有同名服务或残留服务状态
  --non-interactive         禁用所有交互；缺少订阅时直接跳过
  --verbose                 显示下载进度与失败诊断
  -h, --help                显示帮助信息

检测到旧版安装（~/clashctl 布局）时会询问是否自动迁移订阅与配置。

环境变量：CLASHCTL_HOME、GH_PROXY（或用 --gh-proxy 旗标指定，旗标优先）、
CLASHCTL_UPDATE_GIT_URL、CLASHCTL_DOWNLOAD_TIMEOUT、
SUBCONVERTER_REPO、
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
