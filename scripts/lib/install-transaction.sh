#!/usr/bin/env bash

# 安装事务编排（impact 扫描、服务事务 journal/快照/回滚、接管、控制器探测、
# .env 物化与收尾摘要）。由 install.sh 时代整体迁移而来；函数名保持不变，
# 服务脚本（service.sh/service-enablement.sh）的正交机制原样复用。
# 消费方：scripts/cmd/install.sh（clashctl install）与 test/ 事务测试。

# 参数化服务查询：与 service.sh 的全局版（detect_service_manager 探测后使用
# service_manager）不同，这里按传入的 manager/kernel 查询——服务事务恢复必须
# 以 journal 记录的 manager 为准，不能重新探测。
_install_service_target() {
    local manager=$1 kernel=$2
    case $manager in
    systemd) printf '/etc/systemd/system/%s.service\n' "$kernel" ;;
    sysvinit | openrc) printf '/etc/init.d/%s\n' "$kernel" ;;
    runit) printf '/etc/sv/%s/run\n' "$kernel" ;;
    *) return 1 ;;
    esac
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

# 事务进程内的通用防护（与安装器 stage-1 的自包含副本同源；运行期经加载器加载本文件）
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

_install_report_enablement_links() {
    local record path_hex target_hex path target path_display target_display
    local -a records=()
    [ -n "${CLASHCTL_SERVICE_ENABLEMENT_LINKS:-}" ] || return 0
    IFS=, read -r -a records <<<"$CLASHCTL_SERVICE_ENABLEMENT_LINKS"
    for record in "${records[@]}"; do
        path_hex=${record%%:*}
        target_hex=${record#*:}
        _service_enablement_hex_decode "$path_hex" path
        _service_enablement_hex_decode "$target_hex" target
        printf -v path_display '%q' "$path"
        printf -v target_display '%q' "$target"
        _ui_detail '残留链接' "$path_display -> $target_display"
    done
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
    local enablement_only=0 runtime_captured=0

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
    if [ "$manager" = systemd ] && [ -z "$source" ]; then
        _install_capture_service_runtime_state "$manager" "$kernel" || return 1
        runtime_captured=1
        if [ "$CLASHCTL_SERVICE_WAS_ACTIVE" = 1 ]; then
            _ui_error "${kernel}.service 的定义已缺失，但服务仍在运行，无法确认进程归属"
            _install_report_enablement_links
            _ui_detail '当前进度' '仅完成只读检查；服务定义、自启状态和运行状态均未修改'
            _ui_detail '处理' '确认并停止该服务，或恢复其 unit 定义后重新运行安装'
            return 1
        fi
    fi
    if [ -n "$source" ]; then
        CLASHCTL_SERVICE_BACKUP=$(_install_next_backup "$target")
        export CLASHCTL_SERVICE_BACKUP
    elif ! _install_enablement_has_artifacts; then
        return 0
    fi
    if [ "$runtime_captured" -eq 0 ]; then
        _install_capture_service_runtime_state "$manager" "$kernel" || return 1
    fi
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
    if [ "$manager" = systemd ] && [ -z "$source" ]; then
        enablement_only=1
    fi
    _ui_blank
    if [ "$enablement_only" -eq 1 ]; then
        _ui_warn "发现残留的 systemd 服务状态: $service_name"
        _ui_detail '服务定义' '未找到'
        _ui_detail '当前状态' "$runtime_state · $enable_state"
        _install_report_enablement_links
        if [ -n "${CLASHCTL_SERVICE_ENABLEMENT_LINKS:-}" ]; then
            _ui_detail '安装影响' '写入服务定义后，现有链接可能重新生效并影响服务自启'
        else
            _ui_detail '安装影响' '现有注册或屏蔽状态可能影响服务启用'
        fi
        _ui_detail '当前进度' '仅完成只读检查；服务定义、自启状态和运行状态均未修改'
        _ui_detail '将执行' '保存安装前的自启状态，在缺失位置写入、启用并启动 clashctl 服务'
        _ui_detail '写入位置' "$target"
        _ui_detail '定义备份' '不需要（当前没有可备份的服务定义）'
        _ui_detail '卸载行为' '恢复安装前的自启状态；当前残留状态不会被自动清理'
        _ui_detail '清理建议' '若确认残留状态已无其他用途，请先取消安装并清理后重试'
        _ui_detail '失败处理' '自动尝试移除本次写入并恢复安装前状态；恢复不完整时保留事务快照'
    else
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
    fi
    _ui_blank

    if [ "${CLASHCTL_ALLOW_UNIT_OVERWRITE:-}" = 1 ]; then
        if [ "$enablement_only" -eq 1 ]; then
            _ui_info '已通过 --take-over-service / CLASHCTL_ALLOW_UNIT_OVERWRITE=1 授权在记录残留状态后继续安装'
        else
            _ui_info '已通过 --take-over-service / CLASHCTL_ALLOW_UNIT_OVERWRITE=1 授权接管'
        fi
        return 0
    fi
    if [ "${CLASHCTL_NON_INTERACTIVE:-}" = 1 ] || [ "${CI+x}" = x ]; then
        if [ "$enablement_only" -eq 1 ]; then
            _ui_error '非交互安装不会在归属不明的残留服务状态上继续'
        else
            _ui_error '非交互安装不会接管现有服务'
        fi
        _ui_detail '重新执行' '添加 --take-over-service'
        return 1
    fi
    local confirm_rc=0
    if [ "$enablement_only" -eq 1 ]; then
        _ui_confirm "保留上述残留状态并继续安装 ${service_name}？" || confirm_rc=$?
    else
        _ui_confirm "停止并接管 ${service_name}？" || confirm_rc=$?
    fi
    if [ "$confirm_rc" -eq 0 ]; then
        if [ "$enablement_only" -eq 1 ]; then
            _ui_ok '已确认继续安装；残留服务状态尚未修改'
        else
            _ui_ok '已确认接管；现有服务尚未被修改'
        fi
        return 0
    fi
    if [ "$confirm_rc" -eq 2 ]; then
        if [ "$enablement_only" -eq 1 ]; then
            _ui_error '当前环境无法交互确认残留服务状态'
        else
            _ui_error '当前环境无法交互确认服务接管'
        fi
        _ui_detail '非交互授权' '添加 --take-over-service'
        _ui_detail '保留目录' "$home"
        _ui_detail '继续安装' '使用相同参数重试；安装器会复用可信的未完成目录'
        _INSTALL_INCOMPLETE_SUMMARY_SHOWN=1
    else
        if [ "$enablement_only" -eq 1 ]; then
            _ui_info '安装已取消；残留服务状态未被修改'
        else
            _ui_info '安装已取消；现有服务未被修改'
        fi
        _ui_detail '保留目录' "$home"
        if [ "$enablement_only" -eq 1 ]; then
            _ui_detail '继续安装' '重新运行安装命令，并确认保留残留状态后继续'
        else
            _ui_detail '继续安装' '重新运行安装命令，并在确认后接管服务'
        fi
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
            _service_same_object "$target" "$backup"; then
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
    if [ "${_INSTALL_VERBOSE:-}" = 1 ] && [ -s "$startup_error" ]; then
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
            _INSTALL_VERIFIED_CONTROLLER=$addr
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
    _ui_ok '安装结果已验证'
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
    addr=${_INSTALL_VERIFIED_CONTROLLER:-}
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

