#!/usr/bin/env bash

# clashctl install [内核] —— 安装/切换内核并完成初始化。
# 无参 = 完整编排（内核 + 运行组件 + 服务 + 初始订阅 + 首配；幂等，失败可重跑）；
# 带参 = 安装或切换到指定内核（多内核并存：bin/<kernel>/ 与同名服务单元，
# .env 的 CLASHCTL_KERNEL 是激活指针）。
# 服务事务（接管/journal/回滚/摘要）见 scripts/lib/install-transaction.sh；
# 组件下载与版本解析见 scripts/preflight.sh（本命令按需加载）。

# ── 订阅输入侧：URL 只存在于当前进程局部变量，绝不进入环境或日志 ──

_ci_validate_url_text() {
    local label=$1 value=$2
    if _install_has_control_chars "$value"; then
        _ui_error "${label}不能包含控制字符"
        return 1
    fi
    case $value in
    http://* | https://* | file://*) ;;
    *)
        _ui_error "${label}必须以 http://、https:// 或 file:// 开头"
        return 1
        ;;
    esac
}

_ci_read_subscription_file() {
    local file=$1 fd raw value nul_found=0
    local before after owner mode size path_identity fd_identity
    _install_private_locals raw value

    [ -n "$file" ] || {
        _ui_error '缺少订阅输入文件路径'
        return 1
    }
    [ ! -L "$file" ] || {
        _ui_error '订阅输入文件不能是符号链接'
        return 1
    }
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
    _ci_validate_url_text '订阅链接' "$value" || return 1
    printf '%s' "$value"
}

_ci_read_subscription() {
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
    if _install_has_control_chars "$answer"; then
        _ui_error '订阅链接不能包含控制字符'
        return 1
    fi
    case $answer in
    '' | http://* | https://* | file://*) printf '%s' "$answer" ;;
    *)
        _ui_error '订阅链接必须以 http://、https:// 或 file:// 开头'
        return 1
        ;;
    esac
}

_ci_generate_secret() {
    local secret='' part='' _
    _install_private_locals secret part
    for _ in {1..8}; do
        part=$(_get_random_val 4) || return 1
        secret+=$part
    done
    secret=${secret:0:32}
    [[ $secret =~ ^[a-zA-Z0-9]+$ ]] || return 1
    printf '%s' "$secret"
}

# ── 收尾守卫：提交点之后的失败不再回滚（_CI_TRANSACTION_COMMITTED），之前则恢复原服务 ──

_ci_exit_guard() {
    local rc=${1:-0}
    trap - EXIT

    if declare -F _install_cleanup_controller_header >/dev/null; then
        _install_cleanup_controller_header || rc=1
    fi
    if [ "${_INSTALL_SERVICE_TRANSACTION:-0}" = 1 ]; then
        if [ "${_CI_TRANSACTION_COMMITTED:-0}" = 1 ]; then
            if declare -F _install_end_service_transaction >/dev/null; then
                _install_end_service_transaction || rc=1
            else
                printf '%s\n' '[ERROR] 安装已提交，但无法安全清理服务事务' >&2
                rc=1
            fi
        else
            printf '%s\n' '[WARN] 安装在服务配置提交前中止，正在恢复原服务状态' >&2
            _install_restore_service || true
            rc=1
        fi
    fi
    exit "$rc"
}

# 按需补装可选组件（clashctl ui / clashctl sub add 触发）：
# 持操作锁加载安装预检，再走 provision_component 单组件下载与原子提交。
# 锁置于子 shell：调用方（clashui/sub add）也是交互 shell 里的函数，
# 锁 fd 必须随子 shell 释放，不能驻留在交互进程中。
_ci_provision() {
    local component=$1
    [ -n "${CLASHCTL_HOME:-}" ] || return 1
    CLASHCTL_SRC="$CLASHCTL_HOME"
    (
        operation_lock_acquire || exit 1
        # shellcheck disable=SC1090  # 组件下载依赖安装预检模块
        . "${CLASHCTL_SRC}/scripts/preflight.sh" || exit 1
        provision_component "$component"
    )
}

_ci_help() {
    cat <<'EOF'
Usage:
  clashctl install [选项] [mihomo|clash]

无参数时执行完整初始化（缺什么补什么，可安全重跑）；
指定内核时安装或切换到该内核（多内核并存，切换会停用旧内核服务）。

Options:
  --subscription-file <文件> 从权限受限的单行文件读取初始订阅 URL
  --branch <分支>           安装分支及后续更新分支（默认沿用 .env 或 master）
  --take-over-service       允许接管现有同名服务或残留服务状态
  --verbose                 显示下载进度与失败诊断
  -h, --help                显示帮助信息
EOF
}

clashinstall() (
    # 整体置于子 shell：operation lock 的 fd 与 EXIT trap 随子 shell 释放——
    # clashctl 以函数运行在交互 shell 中，进程不会退出，锁必须由子 shell 承载
    local kernel='' branch='' subscription_file='' sub_url='' install_arg
    local install_manager
    _install_private_locals sub_url

    for install_arg in "$@"; do
        if _install_has_control_chars "$install_arg"; then
            _ui_error '命令行参数不能包含控制字符'
            return 1
        fi
    done

    while [ $# -gt 0 ]; do
        case $1 in
        mihomo | clash) kernel=$1 ;;
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
        --take-over-service) export CLASHCTL_ALLOW_UNIT_OVERWRITE=1 ;;
        --verbose) export _INSTALL_VERBOSE=1 ;;
        -h | --help)
            _ci_help
            return 0
            ;;
        *)
            _ui_error '存在未知参数；参数内容未回显'
            _ci_help >&2
            return 1
            ;;
        esac
        shift
    done

    [ -n "${CLASHCTL_HOME:-}" ] || {
        _ui_error '缺少 CLASHCTL_HOME；请先运行 bash install.sh 安装 clashctl'
        return 1
    }
    [ -d "$CLASHCTL_HOME" ] || {
        _ui_error "安装目录不存在: $CLASHCTL_HOME"
        return 1
    }
    # 安装身份标记的执法在 install.sh（落位/resume 判定）与 uninstall.sh；
    # 此处经加载器运行，信任边界是加载链本身，不再重复校验。

    if [ -z "$kernel" ] && [ -f "$CLASHCTL_HOME/.env" ]; then
        _ui_info "clashctl 已完成初始化（当前内核: ${CLASHCTL_KERNEL:-未知}）"
        _ui_info '切换或新增内核: clashctl install <mihomo|clash>'
        return 0
    fi

    kernel=${kernel:-${CLASHCTL_KERNEL:-mihomo}}
    branch=${branch:-${CLASHCTL_UPDATE_BRANCH:-master}}
    [ "${CLASHCTL_NON_INTERACTIVE:-}" != 1 ] || [ "${CI+x}" != x ] ||
        _ui_info '非交互环境：缺少订阅时将跳过初始订阅'
    trap '_ci_exit_guard $?' EXIT

    export CLASHCTL_HOME CLASHCTL_KERNEL="$kernel" CLASHCTL_UPDATE_BRANCH="$branch"
    CLASHCTL_SRC="$CLASHCTL_HOME"
    BIN_KERNEL="${BIN_BASE_DIR}/$kernel/$kernel"

    operation_lock_acquire || return 1
    # shellcheck disable=SC1090  # 组件下载与 .env 物化依赖安装预检模块
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

    _install_impact_scan "$CLASHCTL_HOME" "$kernel" "$install_manager" || return 1

    if [ -n "$subscription_file" ]; then
        sub_url=$(_ci_read_subscription_file "$subscription_file") || return 1
    elif [ -z "$sub_url" ] && [ "${CLASHCTL_NON_INTERACTIVE:-}" != 1 ] &&
        [ "${CI+x}" != x ] && [ -t 0 ] && [ -t 2 ]; then
        sub_url=$(_ci_read_subscription) || return 1
        [ -z "$sub_url" ] || _ui_info '已接收初始订阅（链接不会写入安装输出）'
    fi

    _ui_step '准备运行组件'
    /usr/bin/install -d -m 0700 "$CLASH_DATA_DIR" "${CLASH_DATA_DIR}/profiles" || {
        _ui_error "无法创建数据目录: $CLASH_DATA_DIR"
        return 1
    }
    if [ ! -f "${CLASH_CONFIG_MIXIN}" ] &&
        ! /usr/bin/install -m 0600 "${CLASH_RESOURCES_DIR}/mixin.yaml.example" "${CLASH_CONFIG_MIXIN}"; then
        _ui_error '无法初始化 Mixin 配置: '"$CLASH_CONFIG_MIXIN"
        return 1
    fi
    if [ ! -f "${CLASH_PROFILES_META}" ] &&
        ! /usr/bin/install -m 0600 "${CLASH_RESOURCES_DIR}/profiles.yaml" "${CLASH_PROFILES_META}"; then
        _ui_error '无法初始化订阅元数据: '"$CLASH_PROFILES_META"
        return 1
    fi
    touch "$CLASH_CONFIG_BASE" || {
        _ui_error '无法创建基础配置: '"$CLASH_CONFIG_BASE"
        return 1
    }
    chmod 0600 "$CLASH_CONFIG_BASE" "$CLASH_CONFIG_MIXIN" "$CLASH_PROFILES_META" || {
        _ui_error '无法收紧配置文件权限'
        return 1
    }
    # 无参编排只装内核+yq；subconverter/UI 由 clashctl ui / clashctl sub add 按需补装
    prepare_zip kernel yq || return 1

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
        generated_secret=$(_ci_generate_secret) || {
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
    _CI_TRANSACTION_COMMITTED=1
    local transaction_state=complete
    _install_end_service_transaction || transaction_state=incomplete

    _install_finish "$install_manager" "$subscription_status" "$transaction_state"
)
