#!/usr/bin/env bash

CLASHCTL_SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CLASHCTL_HOME=$CLASHCTL_SRC
export CLASHCTL_HOME CLASHCTL_SRC
_UNINSTALL_MARKER_NAME=.clashctl-installation
_UNINSTALL_ALLOW_LEGACY=0
_UNINSTALL_CRON_STATE=unknown
_UNINSTALL_STAGE=preflight
_UNINSTALL_SIGNAL_HOME=
_UNINSTALL_SIGNAL_BACKUP=

_uninstall_usage() {
    cat <<'EOF'
Usage:
  bash uninstall.sh [OPTIONS]

Options:
  -y, --yes                确认卸载；非交互环境必须显式指定
  --allow-legacy-layout    显式允许卸载无安装标记的旧版目录
  --no-color               禁用彩色输出
  -h, --help               显示帮助信息
EOF
}

_uninstall_has_control_chars() {
    local value=$1 cleaned
    cleaned=$(printf '%s' "$value" | LC_ALL=C tr -d '\001-\037\177')
    [ "$cleaned" != "$value" ]
}

_uninstall_owned_directory() {
    local path=$1 owner mode
    [ -d "$path" ] && [ ! -L "$path" ] || return 1
    owner=$(stat -c %u -- "$path" 2>/dev/null) || return 1
    mode=$(stat -c %a -- "$path" 2>/dev/null) || return 1
    [ "$owner" -eq "$(id -u)" ] && [ $((8#$mode & 0022)) -eq 0 ]
}

_uninstall_owned_file() {
    local path=$1 owner mode
    [ -f "$path" ] && [ ! -L "$path" ] || return 1
    owner=$(stat -c %u -- "$path" 2>/dev/null) || return 1
    mode=$(stat -c %a -- "$path" 2>/dev/null) || return 1
    [ "$owner" -eq "$(id -u)" ] && [ $((8#$mode & 0022)) -eq 0 ]
}

_uninstall_layout_is_trusted() {
    local home=$1 path unsafe uid
    local -a required=(
        "$home/.env"
        "$home/install.sh"
        "$home/uninstall.sh"
        "$home/scripts/preflight.sh"
        "$home/scripts/lib/common.sh"
        "$home/scripts/cmd/off.sh"
    )
    _uninstall_owned_directory "$home" || return 1
    for path in "${required[@]}"; do
        _uninstall_owned_file "$path" || return 1
    done
    uid=$(id -u)
    unsafe=$(find "$home/scripts" \
        \( -type l -o ! -user "$uid" -o -perm /022 \) -print -quit 2>/dev/null) || return 1
    [ -z "$unsafe" ]
}

_uninstall_marker_is_valid() {
    local home=$1 marker="$1/$_UNINSTALL_MARKER_NAME" owner mode line key value
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
            _uninstall_has_control_chars "$value" && return 1
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
        [ "${marker_values[CLASHCTL_INSTALLATION_HOME]}" = "$home" ] &&
        [ "${marker_values[CLASHCTL_INSTALLATION_UID]}" = "$(id -u)" ]
}

_uninstall_path_is_safe() {
    local home=$1 canonical_user_home=
    case $home in
    / | /bin | /boot | /dev | /etc | /home | /lib | /lib32 | /lib64 | /media | /mnt | /opt | \
        /proc | /root | /run | /sbin | /srv | /sys | /tmp | /usr | /var)
        return 1
        ;;
    esac
    if [ -n "${HOME:-}" ] && [ -d "$HOME" ]; then
        canonical_user_home=$(cd -P -- "$HOME" 2>/dev/null && pwd -P) || canonical_user_home=
        [ -z "$canonical_user_home" ] || [ "$home" != "$canonical_user_home" ] || return 1
    fi
}

_uninstall_target_is_trusted() {
    local home=$1 allow_legacy=${2:-0} marker="$1/$_UNINSTALL_MARKER_NAME"
    _uninstall_path_is_safe "$home" || return 1
    _uninstall_layout_is_trusted "$home" || return 1
    if [ -e "$marker" ] || [ -L "$marker" ]; then
        _uninstall_marker_is_valid "$home"
    else
        [ "$allow_legacy" = 1 ]
    fi
}

_uninstall_preflight_gate() {
    local arg allow_legacy=${CLASHCTL_ALLOW_LEGACY_LAYOUT:-0}
    for arg in "$@"; do
        if _uninstall_has_control_chars "$arg"; then
            printf '%s\n' '[ERROR] 命令行参数不能包含控制字符，未加载或修改安装目录' >&2
            return 1
        fi
        [ "$arg" != --allow-legacy-layout ] || allow_legacy=1
    done
    if ! _uninstall_path_is_safe "$CLASHCTL_HOME"; then
        printf '[ERROR] 安装目录属于高危删除目标，拒绝卸载: %s\n' "$CLASHCTL_HOME" >&2
        return 1
    fi
    if ! _uninstall_layout_is_trusted "$CLASHCTL_HOME"; then
        printf '[ERROR] 安装目录的结构、归属或权限异常，未加载其中脚本: %s\n' "$CLASHCTL_HOME" >&2
        return 1
    fi
    if [ -e "$CLASHCTL_HOME/$_UNINSTALL_MARKER_NAME" ] ||
        [ -L "$CLASHCTL_HOME/$_UNINSTALL_MARKER_NAME" ]; then
        if ! _uninstall_marker_is_valid "$CLASHCTL_HOME"; then
            printf '[ERROR] 安装身份标记无效或与当前目录不匹配，拒绝卸载: %s\n' "$CLASHCTL_HOME" >&2
            return 1
        fi
    elif [ "$allow_legacy" = 1 ]; then
        [ "${_UNINSTALL_PREFLIGHT_RECHECK:-0}" = 1 ] ||
            printf '%s\n' '[WARN] 正在按显式授权卸载无身份标记的旧版目录' >&2
    else
        printf '%s\n' '[ERROR] 当前目录缺少有效安装标记，拒绝卸载' >&2
        printf '%s\n' '        旧版目录: 确认来源可信后添加 --allow-legacy-layout' >&2
        return 1
    fi
    _UNINSTALL_ALLOW_LEGACY=$allow_legacy
}

if [ "${CLASHCTL_UNINSTALL_SOURCE_ONLY:-}" != 1 ]; then
    for _uninstall_arg in "$@"; do
        case $_uninstall_arg in
        -h | --help)
            _uninstall_usage
            exit 0
            ;;
        esac
    done
    _uninstall_preflight_gate "$@" || exit 1
    . "$CLASHCTL_SRC/scripts/lib/operation-lock.sh" || {
        printf '%s\n' '[ERROR] 无法加载操作锁模块，未修改系统' >&2
        exit 1
    }
    operation_lock_acquire || exit 1
    _UNINSTALL_PREFLIGHT_RECHECK=1 _uninstall_preflight_gate "$@" || exit 1
fi

. "$CLASHCTL_SRC/scripts/preflight.sh" || {
    printf '%s\n' '[ERROR] 无法加载卸载模块，未修改系统' >&2
    exit 1
}
. "$CLASHCTL_SRC/scripts/cmd/off.sh" || {
    _ui_error '无法加载代理状态模块，未修改系统'
    exit 1
}

_uninstall_legacy_cron_worker() {
    _UNINSTALL_CRON_CURRENT=
    _UNINSTALL_CRON_FILTERED=
    _UNINSTALL_CRON_ERROR=
    # shellcheck disable=SC2317  # 由 EXIT trap 调用
    cleanup() {
        [ -z "${_UNINSTALL_CRON_CURRENT:-}" ] ||
            /usr/bin/rm -f -- "$_UNINSTALL_CRON_CURRENT"
        [ -z "${_UNINSTALL_CRON_FILTERED:-}" ] ||
            /usr/bin/rm -f -- "$_UNINSTALL_CRON_FILTERED"
        [ -z "${_UNINSTALL_CRON_ERROR:-}" ] ||
            /usr/bin/rm -f -- "$_UNINSTALL_CRON_ERROR"
    }
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    if ! command -v crontab >/dev/null 2>&1; then
        printf '%s\n' unavailable
        exit 0
    fi
    _UNINSTALL_CRON_CURRENT=$(mktemp) || {
        printf '%s\n' failed
        exit 1
    }
    _UNINSTALL_CRON_FILTERED=$(mktemp) || {
        printf '%s\n' failed
        exit 1
    }
    _UNINSTALL_CRON_ERROR=$(mktemp) || {
        printf '%s\n' failed
        exit 1
    }
    if ! LC_ALL=C crontab -l >"$_UNINSTALL_CRON_CURRENT" 2>"$_UNINSTALL_CRON_ERROR"; then
        if LC_ALL=C grep -Eiq '(^|: )no crontab for [^[:space:]]+[[:space:]]*$' \
            "$_UNINSTALL_CRON_ERROR"; then
            printf '%s\n' absent
        else
            printf '%s\n' unreadable
        fi
        exit 0
    fi
    if ! grep -Fq "$CLASHCTL_CRON_TAG" "$_UNINSTALL_CRON_CURRENT"; then
        printf '%s\n' absent
        exit 0
    fi
    if awk -v tag="$CLASHCTL_CRON_TAG" 'index($0, tag) == 0' \
        "$_UNINSTALL_CRON_CURRENT" >"$_UNINSTALL_CRON_FILTERED" &&
        crontab "$_UNINSTALL_CRON_FILTERED" >/dev/null 2>&1; then
        printf '%s\n' removed
    else
        printf '%s\n' failed
        exit 1
    fi
}

_uninstall_legacy_cron() {
    local state rc=0
    state=$(_uninstall_legacy_cron_worker) || rc=$?
    case $state in unavailable | unreadable | absent | removed | failed) ;;
    *) state=failed rc=1 ;;
    esac
    _UNINSTALL_CRON_STATE=$state
    return "$rc"
}

_uninstall_report_cron_state() {
    case ${_UNINSTALL_CRON_STATE:-unknown} in
    removed)
        _ui_ok '旧版 clashctl 定时任务已移除'
        return 0
        ;;
    absent)
        _ui_info '未发现 clashctl 旧版定时任务'
        return 0
        ;;
    unavailable)
        _ui_warn '未安装 crontab 命令；已跳过旧版定时任务检查'
        return 1
        ;;
    unreadable)
        _ui_error '无法读取当前用户的 crontab；未修改定时任务'
        return 2
        ;;
    *)
        _ui_warn '旧版定时任务状态未能确认'
        return 1
        ;;
    esac
}

_uninstall_interrupted() {
    local signal=$1 rc=$2 home=${_UNINSTALL_SIGNAL_HOME:-${CLASHCTL_HOME:-}}
    local backup=${_UNINSTALL_SIGNAL_BACKUP:-} retry
    printf -v retry 'bash %q --yes' "$home/uninstall.sh"
    trap - HUP INT TERM
    _ui_blank
    _ui_error "卸载被 ${signal} 信号中断"
    case ${_UNINSTALL_STAGE:-unknown} in
    service)
        _ui_detail '状态' '服务注销或原服务恢复可能未完成；Shell 集成和安装数据尚未处理'
        ;;
    integration)
        _ui_detail '状态' '服务处理已完成；Shell 或定时任务清理可能未完成；安装数据仍保留'
        ;;
    predelete)
        _ui_detail '状态' '服务与系统集成已处理；安装数据尚未删除'
        ;;
    data)
        _ui_detail '状态' '服务与系统集成已处理；安装目录可能只删除了一部分'
        ;;
    backup)
        _ui_detail '状态' 'clashctl 安装目录已删除；原服务备份清理可能未完成'
        ;;
    *)
        _ui_detail '状态' '中断点无法确定，请先检查服务与安装目录'
        ;;
    esac
    if [ -n "$home" ] && { [ -e "$home" ] || [ -L "$home" ]; }; then
        _ui_detail '安装目录' "$home"
    fi
    if [ -n "$backup" ] && { [ -e "$backup" ] || [ -L "$backup" ]; }; then
        _ui_detail '原服务备份' "$backup"
    fi
    case ${_UNINSTALL_STAGE:-unknown} in
    service | integration | predelete)
        _ui_detail '继续' "重新运行 ${retry}"
        ;;
    data)
        _ui_detail '处理' '检查残留目录内容和服务状态后，再决定手动清理或恢复'
        ;;
    backup)
        _ui_detail '处理' '确认原服务正常后，手动检查并清理残留备份'
        ;;
    esac
    exit "$rc"
}

_uninstall_enable_signal_summary() {
    _UNINSTALL_SIGNAL_HOME=$CLASHCTL_HOME
    _UNINSTALL_SIGNAL_BACKUP=${1:-}
    trap '_uninstall_interrupted HUP 129' HUP
    trap '_uninstall_interrupted INT 130' INT
    trap '_uninstall_interrupted TERM 143' TERM
}

_uninstall_disable_signal_summary() {
    trap - HUP INT TERM
    _UNINSTALL_STAGE=preflight
}

main() {
    umask 077
    local replaced_backup=${CLASHCTL_REPLACED_SERVICE_BACKUP:-} assume_yes=0 confirm_rc=0
    local allow_legacy=${_UNINSTALL_ALLOW_LEGACY:-0} restore_original=0 integration_warnings=0
    local cron_report_rc=0 retry_command
    printf -v retry_command 'bash %q --yes' "$CLASHCTL_HOME/uninstall.sh"
    if [ -n "$replaced_backup" ] || [ -n "${CLASHCTL_REPLACED_SERVICE_SOURCE:-}" ] ||
        [ -n "${CLASHCTL_REPLACED_SERVICE_ENABLEMENT_FORMAT:-}" ]; then
        restore_original=1
    fi

    while [ $# -gt 0 ]; do
        case $1 in
        -y | --yes) assume_yes=1 ;;
        --allow-legacy-layout) allow_legacy=1 ;;
        --no-color)
            CLASHCTL_COLOR=never
            export CLASHCTL_COLOR
            ;;
        -h | --help)
            _uninstall_usage
            return 0
            ;;
        *)
            _ui_error '存在未知参数；参数内容未回显'
            _uninstall_usage >&2
            return 1
            ;;
        esac
        shift
    done

    if ! _uninstall_target_is_trusted "$CLASHCTL_HOME" "$allow_legacy"; then
        _ui_error '安装目录的身份、结构、归属或权限校验失败，拒绝卸载'
        _ui_detail '目录' "$CLASHCTL_HOME"
        return 1
    fi
    if ! _is_root && tunstatus >/dev/null 2>&1; then
        _ui_error 'Tun 模式仍在运行；请先关闭 Tun 模式再卸载'
        return 1
    fi
    if [ "$restore_original" -eq 1 ]; then
        _ui_step '检查原服务恢复条件'
        if ! uninstall_replaced_service_preflight; then
            _ui_error '安装前的同名服务当前无法安全恢复，卸载尚未开始'
            _ui_detail '目录' "$CLASHCTL_HOME"
            [ -z "$replaced_backup" ] || _ui_detail '保留备份' "$replaced_backup"
            return 1
        fi
        _ui_ok '原服务定义、自启快照和恢复目标已通过检查'
    fi

    _ui_blank
    _ui_header 'clashctl 卸载计划'
    _ui_detail '目录' "$CLASHCTL_HOME"
    _ui_detail '服务' "停止并注销 ${CLASHCTL_KERNEL}"
    _ui_detail '系统集成' '移除 Shell 命令入口和 clashctl 定时任务'
    _ui_detail '安装数据' '永久删除程序、订阅、运行配置和日志'
    [ "$restore_original" -eq 0 ] ||
        _ui_detail '原服务' '恢复安装前的定义、自启与运行状态'

    if [ "$assume_yes" -ne 1 ]; then
        _ui_blank
        _ui_confirm '执行上述卸载与恢复操作？' || confirm_rc=$?
        case $confirm_rc in
        0) ;;
        2)
            _ui_error '非交互卸载需要显式确认'
            _ui_detail '重新执行' "$retry_command"
            return 1
            ;;
        *)
            _ui_info '卸载已取消，系统未被修改'
            return 1
            ;;
        esac
    fi

    _uninstall_enable_signal_summary "$replaced_backup"
    _UNINSTALL_STAGE=service
    _ui_step '停止并注销服务'
    uninstall_service || {
        _uninstall_disable_signal_summary
        _ui_error '服务卸载或原服务恢复失败，安装数据已保留'
        _ui_detail '目录' "$CLASHCTL_HOME"
        [ -z "$replaced_backup" ] || _ui_detail '恢复备份' "$replaced_backup"
        return 1
    }

    _UNINSTALL_STAGE=integration
    _ui_step '清理 Shell 与定时任务集成'
    revoke_rc || {
        _uninstall_disable_signal_summary
        _ui_error '服务处理已完成，但 Shell 配置清理失败；安装数据已保留'
        _ui_detail '重试' "$retry_command"
        return 1
    }
    _uninstall_legacy_cron || {
        _uninstall_disable_signal_summary
        _ui_error '服务处理已完成，但旧版定时任务清理失败；安装数据已保留'
        _ui_detail '重试' "$retry_command"
        return 1
    }
    _ui_ok 'Shell 命令入口已清理'
    _uninstall_report_cron_state || cron_report_rc=$?
    case $cron_report_rc in
    0) ;;
    1) integration_warnings=$((integration_warnings + 1)) ;;
    *)
        _uninstall_disable_signal_summary
        _ui_error '服务与 Shell 处理已完成，但定时任务状态未知；安装数据已保留'
        _ui_detail '重试' "$retry_command"
        return 1
        ;;
    esac

    _UNINSTALL_STAGE=predelete
    _ui_step '删除安装数据'
    if ! _uninstall_target_is_trusted "$CLASHCTL_HOME" "$allow_legacy"; then
        _uninstall_disable_signal_summary
        _ui_error '卸载期间安装目录发生变化，拒绝递归删除；服务与 Shell 清理已完成'
        _ui_detail '保留目录' "$CLASHCTL_HOME"
        return 1
    fi
    _UNINSTALL_STAGE=data
    /usr/bin/rm -rf --one-file-system -- "$CLASHCTL_HOME" || {
        _uninstall_disable_signal_summary
        _ui_error '删除安装数据失败'
        _ui_detail '保留目录' "$CLASHCTL_HOME"
        [ -z "$replaced_backup" ] || _ui_detail '恢复备份' "$replaced_backup"
        return 1
    }
    _UNINSTALL_STAGE=backup
    if [ -n "$replaced_backup" ] && { [ -e "$replaced_backup" ] || [ -L "$replaced_backup" ]; }; then
        /usr/bin/rm -f -- "$replaced_backup" || {
            _uninstall_disable_signal_summary
            _ui_warn '卸载已完成，但原服务备份未能删除'
            _ui_detail '残留备份' "$replaced_backup"
            return 1
        }
    fi

    _uninstall_disable_signal_summary
    if [ "$integration_warnings" -eq 0 ]; then
        _ui_ok 'clashctl 已卸载，安装数据已删除'
    else
        _ui_warn 'clashctl 核心已卸载，但旧版定时任务状态未能确认'
        _ui_detail '检查' 'crontab -l'
    fi
    if [ -n "${http_proxy:-}" ] || [ -n "${https_proxy:-}" ] ||
        [ -n "${all_proxy:-}" ]; then
        _ui_warn '当前终端仍保留代理环境变量；重新打开终端即可清除'
    fi
    return 0
}

if [ "${CLASHCTL_UNINSTALL_SOURCE_ONLY:-}" != 1 ]; then
    main "$@"
fi
