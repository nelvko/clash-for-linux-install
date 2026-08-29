#!/usr/bin/env bash

# shellcheck disable=SC2034
# 依赖钉版数据（versions.env 为纯数据文件，随仓库分发，位于仓库根目录）
_versions_env_file="$(dirname -- "${BASH_SOURCE[0]}")/../../versions.env"
[ -f "$_versions_env_file" ] && . "$_versions_env_file"
unset -v _versions_env_file

# 下载默认值（.env 物化前或环境变量未设时兜底；GH_PROXY 显式置空 = 直连）
[ -n "${SUBCONVERTER_REPO:-}" ] || SUBCONVERTER_REPO=asdlokj1qpi233/subconverter
[ "${GH_PROXY+x}" = x ] || GH_PROXY=https://gh-proxy.org
[ "${CLASHCTL_DOWNLOAD_TIMEOUT+x}" = x ] || CLASHCTL_DOWNLOAD_TIMEOUT=60

# 用户态全部在 data/（gitignore 目录），resources/ 只保留跟踪的资源文件
CLASH_DATA_DIR="${CLASHCTL_HOME}/data"
CLASH_CONFIG_BASE="${CLASH_DATA_DIR}/config.yaml"
CLASH_CONFIG_MIXIN="${CLASH_DATA_DIR}/mixin.yaml"
CLASH_CONFIG_RUNTIME="${CLASH_DATA_DIR}/runtime.yaml"
# 订阅下载/校验失败时保留的调试产物（稳定路径，便于排障）
CLASH_CONFIG_DEBUG="${CLASH_DATA_DIR}/last-failed.yaml"
CLASH_CONFIG_DEBUG_RAW="${CLASH_DATA_DIR}/last-failed.raw"

CLASH_RESOURCES_DIR="${CLASHCTL_HOME}/resources"

BIN_BASE_DIR="${CLASHCTL_HOME}/bin"
# 每内核一目录（bin/mihomo/mihomo、bin/sing-box/sing-box…），支持多内核并存；
# CLASHCTL_KERNEL 是激活指针，已装集合以 bin/ 子目录为准
BIN_KERNEL="${BIN_BASE_DIR}/$CLASHCTL_KERNEL/$CLASHCTL_KERNEL"
BIN_YQ="${BIN_BASE_DIR}/yq"
BIN_SUBCONVERTER_DIR="${BIN_BASE_DIR}/subconverter"
BIN_SUBCONVERTER="${BIN_SUBCONVERTER_DIR}/subconverter"
BIN_SUBCONVERTER_CONFIG="$BIN_SUBCONVERTER_DIR/pref.yml"
BIN_SUBCONVERTER_LOG="${BIN_SUBCONVERTER_DIR}/latest.log"

CLASH_PROFILES_DIR="${CLASH_DATA_DIR}/profiles"
CLASH_PROFILES_META="${CLASH_DATA_DIR}/profiles.yaml"
CLASH_PROFILES_LOG="${CLASH_DATA_DIR}/profiles.log"
CLASH_PROFILES_LOCK="${CLASH_DATA_DIR}/profiles.lock"

CLASHCTL_CMD_DIR="${CLASHCTL_HOME}/scripts/cmd"

CLASHCTL_CRON_TAG="# clashctl-auto-update"

_is_port_used() {
    local port=${1:-} sockets
    [[ $port =~ ^[0-9]+$ ]] && [ "${#port}" -le 5 ] &&
        ((10#$port >= 1 && 10#$port <= 65535)) || return 1
    port=$((10#$port))

    if command -v ss >/dev/null 2>&1 &&
        sockets=$(ss -H -lntu "sport = :$port" 2>/dev/null); then
        awk -v expected="$port" '
            {
                local_addr = $5
                sub(/^.*:/, "", local_addr)
                if (local_addr == expected) found = 1
            }
            END { exit(found ? 0 : 1) }
        ' <<<"$sockets"
        return
    fi

    command -v netstat >/dev/null 2>&1 || return 1
    sockets=$(netstat -lntu 2>/dev/null) || return 1
    awk -v expected="$port" '
        {
            local_addr = $4
            sub(/^.*:/, "", local_addr)
            if (local_addr == expected) found = 1
        }
        END { exit(found ? 0 : 1) }
    ' <<<"$sockets"
}

_is_root() {
    [ "$(id -u)" -eq 0 ]
}

_get_random_port() {
    local fail_count=0
    while [ "$fail_count" -lt 100 ]; do
        local random_port
        random_port=$(shuf -i 1024-65535 -n 1)
        ! _is_port_used "$random_port" && {
            printf '%s\n' "$random_port"
            return 0
        }
        fail_count=$((fail_count + 1))
    done
    _errorcat "未找到可用的代理端口"
}

_get_local_ip() {
    local local_ip iface
    # 取主路由表默认出口网卡的地址：不探测公网 IP（Tun 下 ip route get
    # 会命中策略路由返回 fake-ip 段地址），主表 default 不受 Tun 影响。
    iface=$(ip -4 route show default 2>/dev/null | awk 'NR==1{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
    [ -n "$iface" ] && local_ip=$(ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1)
    [ -z "$local_ip" ] && local_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    printf '%s\n' "$local_ip"
}

_get_random_val() {
    local value
    value=$(od -An -N24 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n') || return 1
    [ ${#value} -eq 48 ] || return 1
    printf '%s\n' "$value"
}

# UI 颜色策略：NO_COLOR 优先；always/never 显式覆盖自动检测。
# auto 仅在非 CI、终端能力正常且目标 fd 为 TTY 时启用颜色。
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

# 结构化 UI 默认写 stderr；兼容旧命令时可显式选择 stdout。
_ui_emit_fd() {
    local fd=${1:-2} level
    [ $# -gt 0 ] && shift
    level=${1:-info}
    [ $# -gt 0 ] && shift
    local msg="$*" prefix color

    case $level in
    step)
        prefix='[STEP]'
        color=36
        ;;
    ok)
        prefix='[ OK ]'
        color=32
        ;;
    warn)
        prefix='[WARN]'
        color=33
        ;;
    error)
        prefix='[ERROR]'
        color=31
        ;;
    question)
        prefix='[ ? ]'
        color=35
        ;;
    header)
        prefix='[INFO]'
        color='1;36'
        ;;
    info | *)
        prefix='[INFO]'
        color=36
        ;;
    esac

    if _ui_color_enabled "$fd"; then
        printf '\033[%sm%s\033[0m %s\n' "$color" "$prefix" "$msg" >&"$fd"
    else
        printf '%s %s\n' "$prefix" "$msg" >&"$fd"
    fi
    return 0
}

_ui_emit() {
    _ui_emit_fd 2 "$@"
}

_ui_step() {
    _ui_emit step "$*"
}

_ui_info() {
    _ui_emit info "$*"
}

_ui_ok() {
    _ui_emit ok "$*"
}

_ui_warn() {
    _ui_emit warn "$*"
}

_ui_error() {
    _ui_emit error "$*"
}

_ui_header() {
    _ui_emit header "$*"
}

_ui_info_out() {
    _ui_emit_fd 1 info "$*"
}

_ui_ok_out() {
    _ui_emit_fd 1 ok "$*"
}

_ui_fail() {
    _ui_emit_fd 2 error "$*"
    return 1
}

_ui_warn_fail() {
    _ui_emit_fd 2 warn "$*"
    return 1
}

_ui_prompt() {
    local prompt=${1:-}

    if _ui_color_enabled 2; then
        printf '\033[35m[ ? ]\033[0m %s ' "$prompt" >&2
    else
        printf '[ ? ] %s ' "$prompt" >&2
    fi
    return 0
}

_ui_detail() {
    local label=${1:-}
    [ $# -gt 0 ] && shift

    if [ $# -gt 0 ]; then
        printf '        %s: %s\n' "$label" "$*" >&2
    else
        printf '        %s\n' "$label" >&2
    fi
    return 0
}

_ui_blank() {
    printf '\n' >&2
    return 0
}

# 返回 0=yes、1=no/读取失败、2=非交互环境；调用方决定后续业务状态。
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

_color_log() {
    local color="$1"
    local msg="$2"

    # fd1 会随调用方重定向，因此仍按实际输出目标判定颜色。
    _ui_color_enabled 1 || {
        printf '%s\n' "$msg"
        return
    }

    local hex="${color#\#}"
    local r=$((16#${hex:0:2}))
    local g=$((16#${hex:2:2}))
    local b=$((16#${hex:4:2}))

    local color_code="\033[38;2;${r};${g};${b}m"
    local reset_code="\033[0m"

    printf "%b%s%b\n" "$color_code" "$msg" "$reset_code"
}

_errorcat() {
    [ $# -gt 0 ] && {
        [ $# -gt 1 ] && shift
        _ui_fail "$*"
    }
    return 1
}

# 估算字符串终端显示宽度：CJK/emoji 计 2 列，旗帜按对各计 1（合 2），
# VS16(FE0F) 把前一字符提升为宽。依赖 UTF-8 locale 下的逐字符索引。
_dispwidth() {
    local s=$1 w=0 i c cp
    for ((i = 0; i < ${#s}; i++)); do
        c=${s:i:1}
        printf -v cp '%d' "'$c"
        if ((cp == 0xFE0F)); then
            ((w += 1)) # 变体选择符：补足前一字符到宽
        elif ((cp >= 0x1100 && cp <= 0x115F)) ||
            ((cp >= 0x2E80 && cp <= 0xA4CF)) ||
            ((cp >= 0xAC00 && cp <= 0xD7A3)) ||
            ((cp >= 0xF900 && cp <= 0xFAFF)) ||
            ((cp >= 0xFE30 && cp <= 0xFE4F)) ||
            ((cp >= 0xFF00 && cp <= 0xFF60)) ||
            ((cp >= 0xFFE0 && cp <= 0xFFE6)) ||
            ((cp >= 0x1F300 && cp <= 0x1FAFF)) ||
            ((cp >= 0x20000 && cp <= 0x3FFFD)); then
            ((w += 2))
        else
            ((w += 1))
        fi
    done
    printf '%d' "$w"
}

# 按显示宽度右侧补空格，使字符串占满 target 列
_pad() {
    local s=$1 target=$2 w pad
    w=$(_dispwidth "$s")
    pad=$((target - w))
    ((pad < 0)) && pad=0
    printf '%s%*s' "$s" "$pad" ''
}

_set_env() {
    local key=$1
    local value=$2
    local env_path="${CLASHCTL_ENV_PATH:-${CLASHCTL_HOME}/.env}"
    local quoted tmp line found=0

    [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    printf -v quoted '%q' "$value"
    tmp=$(mktemp "${env_path}.tmp.XXXXXX") || return 1
    chmod 0600 "$tmp" || {
        /usr/bin/rm -f -- "$tmp"
        return 1
    }
    if [ -f "$env_path" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case $line in
            "$key="*)
                printf '%s=%s\n' "$key" "$quoted" >>"$tmp" || {
                    /usr/bin/rm -f -- "$tmp"
                    return 1
                }
                found=1
                ;;
            *)
                printf '%s\n' "$line" >>"$tmp" || {
                    /usr/bin/rm -f -- "$tmp"
                    return 1
                }
                ;;
            esac
        done <"$env_path"
    fi
    if [ "$found" -eq 0 ]; then
        printf '%s=%s\n' "$key" "$quoted" >>"$tmp" || {
            /usr/bin/rm -f -- "$tmp"
            return 1
        }
    fi
    /bin/mv -f -- "$tmp" "$env_path"
}

detect_rc() {
    SHELL_RC_BASH=
    SHELL_RC_ZSH=
    SHELL_RC_FISH=
    command -v bash >&/dev/null && {
        SHELL_RC_BASH="${HOME}/.bashrc"
    }
    command -v zsh >&/dev/null && {
        SHELL_RC_ZSH="${HOME}/.zshrc"
    }
    command -v fish >&/dev/null && [ -d "${HOME}/.config/fish" ] && {
        SHELL_RC_FISH="${HOME}/.config/fish/conf.d/clashctl.fish"
    }
}

# 幂等写入 bash/zsh 的 clashctl 引导块。返回 2 表示现有托管标记不完整，
# 调用方必须保留原文件并提示人工处理。
_append_source_block() {
    local rc=$1
    local tmp quoted mode

    [ -f "$rc" ] || return 0
    rc=$(readlink -f -- "$rc" 2>/dev/null) || return 1
    awk '
        $0 == "# >>> clashctl >>>" {
            if (managed) exit 1
            managed = 1
            next
        }
        $0 == "# <<< clashctl <<<" {
            if (!managed) exit 1
            managed = 0
        }
        END { if (managed) exit 1 }
    ' "$rc" >/dev/null || return 2
    tmp=$(mktemp "${rc}.clashctl.XXXXXX") || return 1
    mode=$(stat -c %a -- "$rc" 2>/dev/null) || mode=0600
    awk '
        /^# >>> clashctl >>>$/ { managed=1; next }
        /^# <<< clashctl <<<$/{ managed=0; next }
        managed { next }
        # 同时清除旧版（master 时代）遗留的裸引导行与历史导出
        /^export CLASHCTL_HOME=/ { next }
        /^\. \$CLASHCTL_HOME\/scripts\/cmd\/clashctl\.sh$/ { next }
        /^\[ -s "\$CLASHCTL_HOME\/scripts\/cmd\/clashctl\.sh" \]/ { next }
        { print }
    ' "$rc" >"$tmp" || {
        /usr/bin/rm -f -- "$tmp"
        return 1
    }
    if [ -s "$tmp" ] && [ "$(tail -c 1 -- "$tmp" | wc -l)" -eq 0 ]; then
        printf '\n' >>"$tmp" || {
            /usr/bin/rm -f -- "$tmp"
            return 1
        }
    fi
    printf -v quoted '%q' "$CLASHCTL_HOME"
    {
        printf '%s\n' '# >>> clashctl >>>'
        printf 'export CLASHCTL_HOME=%s\n' "$quoted"
        # shellcheck disable=SC2016 # 变量应在新 shell 加载 rc 时展开
        printf '%s\n' '[ -s "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" ] && . "$CLASHCTL_HOME/scripts/cmd/clashctl.sh"'
        printf '%s\n' '# <<< clashctl <<<'
    } >>"$tmp" || {
        /usr/bin/rm -f -- "$tmp"
        return 1
    }
    chmod "$mode" "$tmp" && /bin/mv -f -- "$tmp" "$rc"
}

# 只移除 clashctl 写入的完整托管块；同时兼容旧版安装器写入的两行引导。
_remove_source_block() {
    local rc=$1 tmp mode legacy_export

    [ -f "$rc" ] || return 0
    rc=$(readlink -f -- "$rc" 2>/dev/null) || return 1
    tmp=$(mktemp "${rc}.clashctl.XXXXXX") || return 1
    mode=$(stat -c %a -- "$rc" 2>/dev/null) || mode=0600
    legacy_export="export CLASHCTL_HOME=${CLASHCTL_HOME}"

    awk -v legacy_export="$legacy_export" '
        BEGIN {
            managed = 0
            buffered = ""
            legacy_guard = "[ -s \"$CLASHCTL_HOME/scripts/cmd/clashctl.sh\" ] && . \"$CLASHCTL_HOME/scripts/cmd/clashctl.sh\""
        }
        !managed && $0 == "# >>> clashctl >>>" {
            managed = 1
            buffered = $0 ORS
            next
        }
        managed {
            buffered = buffered $0 ORS
            if ($0 == "# <<< clashctl <<<") {
                managed = 0
                buffered = ""
            }
            next
        }
        $0 == legacy_export || $0 == legacy_guard { next }
        { print }
        END {
            # 不完整的标记块可能是用户内容，原样保留。
            if (managed) printf "%s", buffered
        }
    ' "$rc" >"$tmp" || {
        /usr/bin/rm -f -- "$tmp"
        return 1
    }
    if ! chmod "$mode" "$tmp" || ! /bin/mv -f -- "$tmp" "$rc"; then
        /usr/bin/rm -f -- "$tmp"
        return 1
    fi
}

# 将 clashctl.fish 以内容快照方式写入 fish 配置；内容无变化时也视为成功。
_write_fish_rc() {
    [ -n "$SHELL_RC_FISH" ] || return 2

    if [ -e "$SHELL_RC_FISH" ] || [ -L "$SHELL_RC_FISH" ]; then
        [ ! -L "$SHELL_RC_FISH" ] &&
            head -n 1 -- "$SHELL_RC_FISH" 2>/dev/null |
            grep -Fqx '# clashctl shell-rc (managed by install.sh, do not edit)' || return 3
    fi

    local fish_dir
    fish_dir=$(dirname -- "$SHELL_RC_FISH")
    mkdir -p -- "$fish_dir" || return 1
    local fish_quoted=${CLASHCTL_HOME//\\/\\\\}
    fish_quoted=${fish_quoted//\'/\\\'}
    local tmp
    tmp=$(mktemp "${fish_dir}/.clashctl.fish.XXXXXX") || return 1
    {
        printf "# clashctl shell-rc (managed by install.sh, do not edit)\n"
        printf "set -gx CLASHCTL_HOME '%s'\n\n" "$fish_quoted"
        cat -- "$CLASHCTL_CMD_DIR/clashctl.fish"
    } >"$tmp" || {
        /usr/bin/rm -f -- "$tmp"
        return 1
    }
    if cmp -s -- "$tmp" "$SHELL_RC_FISH"; then
        /usr/bin/rm -f -- "$tmp"
        return 0
    fi
    if ! chmod 0644 -- "$tmp" || ! /bin/mv -f -- "$tmp" "$SHELL_RC_FISH"; then
        /usr/bin/rm -f -- "$tmp"
        return 1
    fi
}
