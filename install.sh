#!/usr/bin/env bash

# 同时供安装入口与 clashupdate 使用；source 本文件只加载函数。
_install_method() {
    local home=$1 marker
    if [ -f "$home/.clashctl-install" ] && [ ! -L "$home/.clashctl-install" ]; then
        marker=$(cat -- "$home/.clashctl-install") || return 1
        case "$marker" in
        "$home"$'\ngit') printf 'git\n'; return 0 ;;
        "$home"$'\narchive') printf 'archive\n'; return 0 ;;
        '') printf '安装标记为空，无法识别安装类型，也不能卸载：%s；请备份后重新安装\n' "$home/.clashctl-install" >&2; return 1 ;;
        esac
        printf '安装标记与当前路径不匹配，无法更新或卸载：%s\n' "$home/.clashctl-install" >&2
    fi
    return 1
}

_source_path_allowed() {
    local path=${1#./}
    [[ -n "$path" && "$path" != /* && "$path" != *[^a-zA-Z0-9_./-]* ]] || return 1
    case "/$path/" in */../* | */./*) return 1 ;; esac
    case "$path" in
    .git | .git/* | .env | .env/* | .clashctl-* | data | data/* | bin | bin/* | archives | archives/* | resources/dist | resources/dist/* | resources/cache.db)
        return 1 ;;
    esac
}

_source_archive() (
    local destination=$1 branch=$2 proxy=$3 archive entries url
    [[ "$branch" =~ ^[a-zA-Z0-9][a-zA-Z0-9_./-]*$ ]] || { printf '分支名称无效\n' >&2; return 1; }
    archive=$(mktemp) || return 1
    entries="${archive}.list"
    trap 'rm -f -- "$archive" "$entries"' EXIT
    url="https://github.com/nelvko/clash-for-linux-install/archive/refs/heads/${branch}.tar.gz"
    [ -z "$proxy" ] || url="${proxy%/}/$url"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --max-time 180 --retry 2 -o "$archive" "$url" || return 1
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout=30 --tries=3 -O "$archive" "$url" || return 1
    else
        printf '下载源码需要 curl 或 wget\n' >&2
        return 1
    fi
    # 仅允许单个顶层目录内的普通文件/目录；拒绝越界路径和链接后再解压。
    tar -tzf "$archive" >"$entries" || return 1
    awk '
        /[^a-zA-Z0-9_.\/-]/ || /^\// || /(^|\/)\.\.?($|\/)/ { exit 1 }
        { split($0, parts, "/"); if (!root) root=parts[1]; if (parts[1]!=root || !index($0,"/")) exit 1 }
        END { if (!root) exit 1 }
    ' "$entries" || { printf '源码归档路径无效\n' >&2; return 1; }
    tar -tvzf "$archive" >"$entries" || return 1
    if LC_ALL=C grep -qv '^[-d]' "$entries"; then
        printf '源码归档包含非普通文件\n' >&2
        return 1
    fi
    tar -xzf "$archive" --strip-components=1 --no-same-owner --no-same-permissions -C "$destination"
)

_source_validate() {
    local directory=$1 file relative
    for file in .env.example install.sh uninstall.sh scripts/preflight.sh scripts/cmd/clashctl.sh scripts/cmd/update.sh; do
        if [ ! -f "$directory/$file" ] || [ -L "$directory/$file" ]; then
            printf '源码不兼容：缺少必需文件 %s\n' "$file" >&2
            return 1
        fi
    done
    while IFS= read -r -d '' file; do
        relative=${file#"$directory/"}
        if ! _source_path_allowed "$relative" || [ -L "$file" ] || { [ ! -d "$file" ] && [ ! -f "$file" ]; }; then
            printf '源码包含不支持的路径：%s\n' "$relative" >&2
            return 1
        fi
        case "$file" in *.sh) bash -n "$file" || return 1 ;; esac
    done < <(find "$directory" -mindepth 1 -path "$directory/.git" -prune -o -print0)
}

_source_manifest() (
    set -o pipefail
    cd -- "$1" || return 1
    find . -path './.git' -prune -o -type f ! -name '.clashctl-*' -print0 |
        sort -z | xargs -0 -r sha256sum
)

_install_next_step() {
    local shell=$1 rc_var rc_path load_command
    case "$shell" in bash | zsh | fish) ;; *) shell=bash ;; esac
    rc_var=SHELL_RC_${shell^^}
    rc_path=${!rc_var:-}
    if [ -f "$rc_path" ]; then
        printf -v load_command 'source %q' "$rc_path"
        if [[ $rc_path == "$HOME/"* ]]; then
            printf -v load_command 'source ~/%q' "${rc_path#"$HOME/"}"
        fi
    elif [ "$shell" = fish ]; then
        printf -v load_command 'set -gx CLASHCTL_HOME %q; source %q' \
            "$CLASHCTL_HOME" "$CLASHCTL_HOME/scripts/cmd/clashctl.fish"
    else
        printf -v load_command 'export CLASHCTL_HOME=%q; source %q' \
            "$CLASHCTL_HOME" "$CLASHCTL_HOME/scripts/cmd/clashctl.sh"
    fi
    if [ -s "$CLASH_CONFIG_BASE" ]; then
        _ui_detail "启用代理（$shell）" "$load_command && clashctl on"
    else
        _ui_detail "添加订阅（$shell）" "$load_command && clashctl sub add --use \"<URL>\" && clashctl on"
    fi
}

_install_initialize() {
    export CLASHCTL_SRC="$CLASHCTL_HOME"
    . "$CLASHCTL_SRC/scripts/preflight.sh" || return 1
    # 参数在 main 中保存，不受 preflight 加载已有 .env 的影响。
    local kernel=${1:-${CLASHCTL_KERNEL:-mihomo}} branch=${2:-${CLASHCTL_UPDATE_BRANCH:-master}}
    local proxy=${GH_PROXY:-} subscription='' rc secret
    [ "$4" != x ] || proxy=$3
    export -n subscription secret
    export CLASHCTL_KERNEL="$kernel" CLASHCTL_UPDATE_BRANCH="$branch" GH_PROXY="$proxy"
    # shellcheck disable=SC2034  # preflight 中的组件安装与服务定义共用此路径。
    BIN_KERNEL=$(bin_kernel_path) || return 1
    operation_lock_acquire || return 1
    valid_required || return 1
    detect_service_manager
    _service_check_conflict || return 1

    _ui_step '准备运行组件'
    install -d -m 0700 "$CLASH_DATA_DIR" "$CLASH_PROFILES_DIR" || return 1
    local source target
    for source in mixin.yaml.example profiles.yaml; do
        target="$CLASH_DATA_DIR/${source%.example}"
        [ -f "$target" ] || install -m 0600 "$CLASH_RESOURCES_DIR/$source" "$target" || return 1
    done
    [ -f "$CLASH_CONFIG_BASE" ] || install -m 0600 /dev/null "$CLASH_CONFIG_BASE" || return 1
    prepare_zip kernel yq || return 1
    # 在写入配置、注册服务之前撤销未初始化凭据；后续丢失 .env 不能按空安装删除。
    command rm -f -- "$CLASHCTL_HOME/.clashctl-uninitialized" || return 1
    [ -f "$CLASHCTL_HOME/.env" ] || install -m 0600 "$CLASHCTL_HOME/.env.example" "$CLASHCTL_HOME/.env" || return 1
    _set_env CLASHCTL_KERNEL "$kernel" || return 1
    _set_env CLASHCTL_UPDATE_BRANCH "$branch" || return 1
    _set_env GH_PROXY "$proxy" || return 1
    # shellcheck disable=SC2154  # detect_service_manager 设置
    _set_env INIT_TYPE "$service_manager" || return 1
    . "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" || return 1

    _ui_step '配置服务与终端命令'
    # 密钥直接写入 Mixin，无主配置时不生成 runtime。
    secret=$("$BIN_YQ" '.secret // ""' "$CLASH_CONFIG_MIXIN") || return 1
    if [ -z "$secret" ]; then
        secret=$(_get_random_val) || return 1
        SECRET=$secret "$BIN_YQ" -i '.secret = env(SECRET)' "$CLASH_CONFIG_MIXIN" || return 1
    fi
    install_service || return 1
    apply_rc || { rc=$?; [ "$rc" -eq 2 ] || return "$rc"; }

    if [ "${CI+x}" != x ] && ( : </dev/tty ) 2>/dev/null; then
        IFS= read -r -p '订阅链接（回车跳过）: ' subscription </dev/tty || subscription=''
    fi
    if [ -n "$subscription" ]; then
        # 订阅失败不算安装失败：组件、命令和服务都已就绪，此时报"安装未完成"会误导用户重装。
        if ! clashsub add --use "$subscription"; then
            _ui_warn '订阅添加失败，已跳过；组件与命令安装完成'
            _ui_detail '稍后重试' 'clashctl sub add --use <URL>'
        fi
    elif [ -s "$CLASH_CONFIG_BASE" ]; then
        clashstart || return 1
    else
        _ui_info '尚未配置订阅，内核未启动'
    fi
    _ui_ok '安装完成'
    # 安装器运行在子进程中；优先识别调用它的 Shell，登录 Shell 只作兜底。
    local shell
    shell=$(readlink "/proc/$PPID/exe" 2>/dev/null) || shell=${SHELL:-bash}
    case ${shell##*/} in bash | zsh | fish) ;; *) shell=${SHELL:-bash} ;; esac
    _install_next_step "${shell##*/}"
}

# 可直接 curl .../install.sh | bash；交互输入从 /dev/tty 读取。
main() (
    set -e
    local install_home=${CLASHCTL_HOME:-$HOME/.clashctl}
    local branch=${CLASHCTL_UPDATE_BRANCH:-} kernel=''
    local proxy=${GH_PROXY:-} proxy_set=${GH_PROXY+x} stage='' arg method
    local local_source=false script_dir=''
    while [ "$#" -gt 0 ]; do
        arg=$1
        shift
        case $arg in
        mihomo | clash) kernel=$arg ;;
        --local) local_source=true ;;
        --gh-proxy=*) proxy=${arg#--gh-proxy=}; proxy_set=x ;;
        --gh-proxy)
            [ "$#" -gt 0 ] || { printf '%s\n' '--gh-proxy 需要一个值' >&2; return 1; }
            proxy=$1
            proxy_set=x
            shift
            ;;
        -h | --help)
            printf '用法: bash install.sh [mihomo|clash] [--local] [--gh-proxy <URL>]\n--local: 使用本脚本所在目录的源码，依赖仍按需下载\n环境变量: CLASHCTL_HOME、CLASHCTL_UPDATE_BRANCH、GH_PROXY\n'
            return 0 ;;
        *) printf '未知安装参数\n' >&2; return 1 ;;
        esac
    done
    if [ -f "${BASH_SOURCE[0]:-}" ]; then
        script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
    fi
    if [ "$local_source" = true ] && [ -z "$script_dir" ]; then
        printf '%s\n' '--local 需要从本地源码目录中的 install.sh 执行，不支持管道输入' >&2
        return 1
    fi
    # 服务单元名与内核二进制路径都派生自它，必须在 sourcing 前导出。
    export CLASHCTL_KERNEL="$kernel"
    for arg in tar gzip unzip sha256sum; do
        command -v "$arg" >/dev/null || { printf '缺少依赖: %s\n' "$arg" >&2; return 1; }
    done
    # 服务模板使用绝对路径；拒绝会影响模板或 Shell 解析的字符。
    [[ $install_home == /* && $install_home != *[^a-zA-Z0-9_./-]* ]] || {
        printf '安装目录必须是绝对路径，且只包含字母、数字、_、.、/、-\n' >&2
        return 1
    }
    install_home=$(readlink -m -- "$install_home") || return 1
    if [ "$install_home" = / ] || [ "$install_home" = "$(cd -- "$HOME" && pwd -P)" ]; then
        printf '不能使用根目录或用户主目录作为安装目录\n' >&2
        return 1
    fi
    if [ "$local_source" = true ]; then
        case "$install_home/" in
        "$script_dir/"*) printf '本地安装目录不能位于源码目录内，请通过 CLASHCTL_HOME 指定其他目录\n' >&2; return 1 ;;
        esac
    fi
    if [ -e "$install_home" ] || [ -L "$install_home" ]; then
        # 允许直接执行安装目录中的脚本重试初始化，不覆盖或重新下载目录。
        if ! method=$(_install_method "$install_home") || [ "$script_dir" != "$install_home" ]; then
            printf '目录已存在且不是可重试的安装目录: %s；请使用新的安装目录\n' "$install_home" >&2
            return 1
        fi
    else
        branch=${branch:-master}
        mkdir -p -- "$(dirname -- "$install_home")"
        stage=$(mktemp -d "${install_home}.download.XXXXXX")
        trap '[ -z "$stage" ] || rm -rf -- "$stage"' EXIT
        if [ "$local_source" = true ]; then
            method=archive
            # 保留工作区修改；排除运行数据与被 .gitignore 忽略的本地文件。
            (
                set -o pipefail
                tar -C "$script_dir" --exclude-vcs-ignores \
                    --exclude='./.git' --exclude='./.env' --exclude='./.clashctl-*' \
                    --exclude='./data' --exclude='./bin' --exclude='./archives' \
                    --exclude='./resources/dist' --exclude='./resources/cache.db' -cf - . |
                    tar --no-same-owner --no-same-permissions -xf - -C "$stage"
            )
        elif command -v git >/dev/null 2>&1; then
            method=git
            local url=https://github.com/nelvko/clash-for-linux-install.git
            [ -z "$proxy" ] || url="${proxy%/}/$url"
            git -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=60 \
                clone --depth 1 --branch "$branch" -- "$url" "$stage"
        else
            method=archive
            _source_archive "$stage" "$branch" "$proxy"
            [ ! -e "$stage/.git" ] && [ ! -L "$stage/.git" ] || return 1
        fi
        _source_validate "$stage"
        if [ "$method" = archive ]; then
            _source_manifest "$stage" >"$stage/.clashctl-files"
        fi
        (umask 077; printf '%s\n%s\n' "$install_home" "$method" >"$stage/.clashctl-install")
        (umask 077; printf '%s\n' "$install_home" >"$stage/.clashctl-uninitialized")
        mv -T -- "$stage" "$install_home"
        stage=''
    fi
    export CLASHCTL_HOME="$install_home" CLASHCTL_SRC="$install_home" CLASHCTL_KERNEL="$kernel"
    export CLASHCTL_UPDATE_BRANCH="$branch" GH_PROXY="$proxy"
    _install_initialize "$kernel" "$branch" "$proxy" "$proxy_set" || {
        printf '安装未完成；排查错误后运行 CLASHCTL_HOME=%s bash %s/install.sh 重试\n' "$install_home" "$install_home" >&2
        return 1
    }
)

# 完整读取脚本后才执行，下载中断时不会提前开始安装。
if [ -z "${BASH_SOURCE[0]:-}" ] || [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
