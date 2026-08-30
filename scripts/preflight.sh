#!/usr/bin/env bash

# 已安装时存在；install.sh 首跑物化前（依赖下载阶段）暂缺
[ -f "$CLASHCTL_SRC/.env" ] && . "$CLASHCTL_SRC/.env"

for lib_file in "$CLASHCTL_SRC"/scripts/lib/*.sh; do
    [ -f "$lib_file" ] || continue
    # shellcheck disable=SC1090
    . "$lib_file"
done

ZIP_BASE_DIR="${CLASHCTL_SRC}/archives"

valid_required() {
    local required_cmds=(curl tar unzip gzip shuf od)
    local missing=()

    for cmd in "${required_cmds[@]}"; do
        command -v "$cmd" >&/dev/null || missing+=("$cmd")
    done

    command -v ss >&/dev/null || command -v netstat >&/dev/null || missing+=("ss/netstat")
    command -v ip >&/dev/null || command -v hostname >&/dev/null || missing+=("ip/hostname")

    if [ ${#missing[@]} -gt 0 ]; then
        _ui_error "缺少安装所需的系统命令"
        _ui_detail "缺少" "${missing[*]}"
        _ui_detail "处理" "安装上述命令后重新运行安装脚本"
        return 1
    fi
    return 0
}

prepare_zip() {
    # 组件集合可由参数指定（kernel 关键字映射为当前内核）；缺省全套。
    # clashctl install 的无参编排只装 kernel+yq，subconverter/UI 由
    # clashctl ui / clashctl sub add 按需补装（provision_component）。
    local -a requested=("$@") normalized=() item
    local kernel_zip system_yq
    case "${CLASHCTL_KERNEL}" in
    clash) kernel_zip=clash ;;
    *) kernel_zip=mihomo ;;
    esac
    if [ ${#requested[@]} -eq 0 ]; then
        requested=(kernel yq subconverter ui)
    fi
    for item in "${requested[@]}"; do
        [ "$item" != kernel ] || item=$kernel_zip
        # 系统 yq 兼容且本地未下载时复用系统副本，跳过下载（bin/yq 存在则照常刷新）
        if [ "$item" = yq ] && [ ! -x "${BIN_BASE_DIR}/yq" ] &&
            system_yq=$(_get_system_yq); then
            _ui_info "复用系统 yq: $system_yq"
            continue
        fi
        normalized+=("$item")
    done
    if [ ${#normalized[@]} -eq 0 ]; then
        _ui_ok '依赖组件已就绪'
        return 0
    fi

    unset ZIP_KERNEL ZIP_YQ ZIP_SUBCONVERTER ZIP_UI
    download_zip "${normalized[@]}" || return 1

    case "$kernel_zip" in
    clash) ZIP_KERNEL="$ZIP_CLASH" ;;
    *) ZIP_KERNEL="$ZIP_MIHOMO" ;;
    esac
    BIN_KERNEL="${BIN_BASE_DIR}/$CLASHCTL_KERNEL/$CLASHCTL_KERNEL"
    unzip_zip || return 1
}

# 按需补装单个组件（subconverter/ui）；ZIP_* 其余保持为空，unzip_zip 跳过。
provision_component() {
    local component=$1
    case "$component" in
    subconverter | ui) ;;
    *)
        _ui_error "组件 $component 不支持按需补装"
        return 1
        ;;
    esac
    unset ZIP_KERNEL ZIP_YQ ZIP_SUBCONVERTER ZIP_UI
    download_zip "$component" || return 1
    unzip_zip || return 1
}

_fetch_latest_tag() {
    local repo=$1
    local body
    body=$(curl -sSL --fail --max-time 10 --retry 1 -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null) || return 1
    local tag
    tag=$(printf '%s' "$body" | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 |
        sed -E 's/.*"([^"]+)"[[:space:]]*$/\1/')
    [ -n "$tag" ] && printf '%s\n' "$tag"
}

_resolve_version() {
    local varname=$1 repo=$2
    local local_version="${!varname}"

    # 版本来源优先级：用户显式钉版（.env/环境变量）> 最新版本查询 > 内置钉版
    if [ -n "$local_version" ]; then
        _ui_detail "$repo" "$local_version（配置版本）"
        return 0
    fi

    local tag
    if tag=$(_fetch_latest_tag "$repo"); then
        printf -v "$varname" '%s' "$tag"
        _ui_detail "$repo" "$tag（最新版本）"
        return 0
    fi

    case "$varname" in
    VERSION_MIHOMO) local_version=$DEFAULT_VERSION_MIHOMO ;;
    VERSION_YQ) local_version=$DEFAULT_VERSION_YQ ;;
    VERSION_SUBCONVERTER) local_version=$DEFAULT_VERSION_SUBCONVERTER ;;
    VERSION_UI) local_version=$DEFAULT_VERSION_UI ;;
    esac
    if [ -n "$local_version" ]; then
        if [ "${CLASHCTL_LATEST_VERSION_FALLBACK_WARNED:-0}" -eq 0 ]; then
            _ui_warn "无法查询部分依赖的最新版本，回退内置钉版"
            CLASHCTL_LATEST_VERSION_FALLBACK_WARNED=1
        fi
        printf -v "$varname" '%s' "$local_version"
        _ui_detail "$repo" "$local_version（内置钉版）"
        return 0
    fi

    _ui_error "无法解析依赖版本：$repo"
    _ui_detail "原因" "未配置版本、无内置钉版，且最新版本查询不可用"
    return 1
}

_archive_is_valid() {
    local archive=$1
    local expected=${archive%.part}

    [ -f "$archive" ] && [ ! -L "$archive" ] && [ -s "$archive" ] || return 1
    case $expected in
    *.zip)
        unzip -tqq "$archive" >/dev/null 2>&1 ||
            tar -tf "$archive" >/dev/null 2>&1
        ;;
    *.tar.gz | *.tgz) tar -tzf "$archive" >/dev/null 2>&1 ;;
    *.gz) gzip -tq "$archive" >/dev/null 2>&1 ;;
    *) gzip -tq "$archive" >/dev/null 2>&1 || unzip -tqq "$archive" >/dev/null 2>&1 ;;
    esac
}

_managed_directory_is_safe() {
    local path=$1 owner mode

    [ -d "$path" ] && [ ! -L "$path" ] || return 1
    owner=$(stat -c %u -- "$path" 2>/dev/null) || return 1
    mode=$(stat -c %a -- "$path" 2>/dev/null) || return 1
    [ "$owner" -eq "$(id -u)" ] &&
        [ $((8#$mode & 0700)) -eq $((8#700)) ] &&
        [ $((8#$mode & 0022)) -eq 0 ]
}

_managed_directory_prepare() {
    local path=$1 mode=${2:-0755}

    if [ -e "$path" ] || [ -L "$path" ]; then
        _managed_directory_is_safe "$path"
        return
    fi
    /usr/bin/install -d -m "$mode" -- "$path" || return 1
    _managed_directory_is_safe "$path"
}

_managed_cache_file_discard() {
    local archive=$1 owner cache_dir archive_dir archive_parent

    _managed_directory_is_safe "$ZIP_BASE_DIR" || return 2
    [ -f "$archive" ] && [ ! -L "$archive" ] || return 2
    owner=$(stat -c %u -- "$archive" 2>/dev/null) || return 2
    [ "$owner" -eq "$(id -u)" ] || return 2

    cache_dir=$(cd -P -- "$ZIP_BASE_DIR" 2>/dev/null && pwd -P) || return 2
    archive_parent=$(dirname -- "$archive") || return 2
    archive_dir=$(cd -P -- "$archive_parent" 2>/dev/null && pwd -P) || return 2
    [ "$archive_dir" = "$cache_dir" ] || return 2

    /usr/bin/rm -f -- "$archive" || return 1
    [ ! -e "$archive" ] && [ ! -L "$archive" ]
}

_component_discard_invalid_cache() {
    local label=$1 archive=$2 discard_rc=0

    _managed_cache_file_discard "$archive" || discard_rc=$?
    if [ "$discard_rc" -eq 0 ]; then
        _ui_warn "已废弃布局无效的依赖缓存：$label"
        _ui_detail "缓存" "$archive"
        _ui_detail "重试" "重新运行安装；安装器将重新下载该组件"
    else
        _ui_warn "布局无效的依赖缓存未被删除：$label"
        _ui_detail "缓存" "$archive"
        if [ "$discard_rc" -eq 2 ]; then
            _ui_detail "原因" "路径、归属或文件类型未通过托管缓存安全校验"
        else
            _ui_detail "原因" "删除缓存文件失败"
        fi
        _ui_detail "处理" "检查该文件后手动移除，再重新运行安装"
    fi
    return 0
}

_cache_token() {
    local value=$1
    value=${value//\//_}
    value=${value// /_}
    printf '%s' "$value"
}

_download_archive() {
    local label=$1 url=$2 target=$3
    local download_url="${GH_PROXY:+${GH_PROXY%/}/}${url}"
    local part="${target}.part"
    local -a curl_args=(
        --show-error
        --fail
        --location
        --max-time "$CLASHCTL_DOWNLOAD_TIMEOUT"
        --retry 1
    )

    if _archive_is_valid "$target"; then
        _ui_ok "$label（缓存命中）"
        _ui_detail "缓存" "$target"
        return 0
    fi

    if [ -e "$target" ] || [ -L "$target" ]; then
        _ui_warn "忽略损坏的依赖缓存：$label"
        _ui_detail "文件" "$target"
        /usr/bin/rm -f -- "$target" || {
            _ui_error "无法移除损坏的依赖缓存：$label"
            return 1
        }
    fi
    /usr/bin/rm -f -- "$part" || {
        _ui_error "无法清理上次下载的残片：$label"
        _ui_detail "残片" "$part"
        return 1
    }

    if [ -t 2 ] && [ "${_INSTALL_VERBOSE:-}" = 1 ]; then
        curl_args+=(--progress-bar)
    else
        curl_args+=(--silent)
    fi

    _ui_info "下载 $label"
    _ui_detail "上游" "$url"
    if ! curl "${curl_args[@]}" --output "$part" --url "$download_url"; then
        /usr/bin/rm -f -- "$part"
        _ui_error "下载失败：$label"
        _ui_detail "目标" "$target"
        _ui_detail "重试" "检查网络或用 --gh-proxy 指定镜像；续装：bash ${CLASHCTL_HOME:-$HOME/.clashctl}/install.sh（慢链路可调大 CLASHCTL_DOWNLOAD_TIMEOUT）"
        return 1
    fi
    if ! _archive_is_valid "$part"; then
        /usr/bin/rm -f -- "$part"
        _ui_error "下载文件校验失败：$label"
        _ui_detail "上游" "$url"
        return 1
    fi
    if ! /bin/mv -f -- "$part" "$target"; then
        /usr/bin/rm -f -- "$part"
        _ui_error "无法写入依赖缓存：$label"
        _ui_detail "目标" "$target"
        return 1
    fi

    _ui_ok "$label 已下载并通过校验"
    return 0
}

download_zip() {
    (($#)) || return 0
    # 上游行只标识制品身份；实际下载通道在此一次性披露（镜像排障线索）
    if [ -n "${GH_PROXY:-}" ]; then
        _ui_detail '下载经由' "$GH_PROXY"
    else
        _ui_detail '下载经由' '直连'
    fi
    _managed_directory_prepare "$ZIP_BASE_DIR" 0755 || {
        _ui_error "依赖缓存目录无法安全使用"
        _ui_detail "目录" "$ZIP_BASE_DIR"
        _ui_detail "要求" "必须是当前用户所有的真实目录，且组用户和其他用户不可写"
        return 1
    }
    local url_clash url_mihomo url_yq url_subconverter
    local arch flags level
    arch=$(uname -m) || {
        _ui_error "无法检测系统架构"
        return 1
    }

    CLASHCTL_LATEST_VERSION_FALLBACK_WARNED=0
    local item
    for item in "$@"; do
        case $item in
        clash) ;;
        mihomo) _resolve_version VERSION_MIHOMO MetaCubeX/mihomo || return 1 ;;
        yq) _resolve_version VERSION_YQ mikefarah/yq || return 1 ;;
        subconverter) _resolve_version VERSION_SUBCONVERTER "$SUBCONVERTER_REPO" || return 1 ;;
        ui) _resolve_version VERSION_UI Zephyruso/zashboard || return 1 ;;
        *)
            _ui_error "未知依赖组件：$item"
            return 1
            ;;
        esac
    done

    case "$arch" in
    x86_64)
        flags=$(grep -m1 '^flags' /proc/cpuinfo)
        level=v1
        grep -qw sse4_2 <<<"$flags" && grep -qw popcnt <<<"$flags" && level=v2
        grep -qw avx2 <<<"$flags" && grep -qw fma <<<"$flags" && level=v3

        url_clash=https://github.com/nelvko/clash-for-linux-install/releases/download/clash/clash-linux-amd64-2023.08.17.gz
        url_mihomo=https://github.com/MetaCubeX/mihomo/releases/download/${VERSION_MIHOMO##*-}/mihomo-linux-amd64-${level}-${VERSION_MIHOMO##*-}.gz
        url_yq=https://github.com/mikefarah/yq/releases/download/${VERSION_YQ}/yq_linux_amd64.tar.gz
        url_subconverter=https://github.com/${SUBCONVERTER_REPO}/releases/download/${VERSION_SUBCONVERTER}/subconverter_linux64.tar.gz
        ;;
    *86*)
        url_clash=https://github.com/nelvko/clash-for-linux-install/releases/download/clash/clash-linux-386-2023.08.17.gz
        url_mihomo=https://github.com/MetaCubeX/mihomo/releases/download/${VERSION_MIHOMO##*-}/mihomo-linux-386-${VERSION_MIHOMO}.gz
        url_yq=https://github.com/mikefarah/yq/releases/download/${VERSION_YQ}/yq_linux_386.tar.gz
        url_subconverter=https://github.com/${SUBCONVERTER_REPO}/releases/download/${VERSION_SUBCONVERTER}/subconverter_linux32.tar.gz
        ;;
    armv*)
        url_clash=https://github.com/nelvko/clash-for-linux-install/releases/download/clash/clash-linux-armv5-2023.08.17.gz
        url_mihomo=https://github.com/MetaCubeX/mihomo/releases/download/${VERSION_MIHOMO##*-}/mihomo-linux-armv7-${VERSION_MIHOMO}.gz
        url_yq=https://github.com/mikefarah/yq/releases/download/${VERSION_YQ}/yq_linux_arm.tar.gz
        url_subconverter=https://github.com/${SUBCONVERTER_REPO}/releases/download/${VERSION_SUBCONVERTER}/subconverter_armv7.tar.gz
        ;;
    aarch64)
        url_clash=https://github.com/nelvko/clash-for-linux-install/releases/download/clash/clash-linux-arm64-2023.08.17.gz
        url_mihomo=https://github.com/MetaCubeX/mihomo/releases/download/${VERSION_MIHOMO##*-}/mihomo-linux-arm64-${VERSION_MIHOMO}.gz
        url_yq=https://github.com/mikefarah/yq/releases/download/${VERSION_YQ}/yq_linux_arm64.tar.gz
        url_subconverter=https://github.com/${SUBCONVERTER_REPO}/releases/download/${VERSION_SUBCONVERTER}/subconverter_aarch64.tar.gz
        ;;
    *)
        _ui_error "不支持的系统架构：$arch"
        _ui_detail "缓存目录" "$ZIP_BASE_DIR"
        return 1
        ;;
    esac

    # UI 为纯静态资源，与架构无关
    local url_ui="https://github.com/Zephyruso/zashboard/releases/download/${VERSION_UI}/dist.zip"
    local url target label version_token

    for item in "$@"; do
        case $item in
        clash)
            url=$url_clash
            target="${ZIP_BASE_DIR}/$(basename -- "$url")"
            label='clash 2023.08.17'
            ;;
        mihomo)
            url=$url_mihomo
            target="${ZIP_BASE_DIR}/$(basename -- "$url")"
            label="mihomo ${VERSION_MIHOMO}"
            ;;
        yq)
            url=$url_yq
            version_token=$(_cache_token "$VERSION_YQ")
            target="${ZIP_BASE_DIR}/yq-${version_token}-${arch}.tar.gz"
            label="yq ${VERSION_YQ}"
            ;;
        subconverter)
            url=$url_subconverter
            version_token=$(_cache_token "$VERSION_SUBCONVERTER")
            target="${ZIP_BASE_DIR}/subconverter-${version_token}-${arch}.tar.gz"
            label="subconverter ${VERSION_SUBCONVERTER}"
            ;;
        ui)
            url=$url_ui
            version_token=$(_cache_token "$VERSION_UI")
            target="${ZIP_BASE_DIR}/dist-${version_token}.zip"
            label="zashboard ${VERSION_UI}"
            ;;
        esac

        _download_archive "$label" "$url" "$target" || return 1
        case $item in
        clash) ZIP_CLASH=$target ;;
        mihomo) ZIP_MIHOMO=$target ;;
        yq) ZIP_YQ=$target ;;
        subconverter) ZIP_SUBCONVERTER=$target ;;
        ui) ZIP_UI=$target ;;
        esac
    done
    return 0
}

valid_zip() {
    if (($# == 0)); then
        _ui_error "没有可验证的依赖归档"
        return 1
    fi

    local archive
    local invalid=()
    for archive in "$@"; do
        _archive_is_valid "$archive" || invalid+=("$archive")
    done

    if [ ${#invalid[@]} -gt 0 ]; then
        _ui_error "依赖归档校验失败"
        for archive in "${invalid[@]}"; do
            _ui_detail "文件" "$archive"
        done
        return 1
    fi
    return 0
}

_component_file_is_safe() {
    local path=$1 expected_mode=$2 owner mode

    [ -f "$path" ] && [ ! -L "$path" ] || return 1
    owner=$(stat -c %u -- "$path" 2>/dev/null) || return 1
    mode=$(stat -c %a -- "$path" 2>/dev/null) || return 1
    [ "$owner" -eq "$(id -u)" ] && [ "$mode" = "$expected_mode" ]
}

_component_tree_is_safe() {
    local root=$1 unexpected

    [ -d "$root" ] && [ ! -L "$root" ] || return 1
    unexpected=$(find "$root" ! -user "$(id -u)" -print -quit 2>/dev/null) || return 1
    [ -z "$unexpected" ] || return 1
    unexpected=$(find "$root" ! -type d ! -type f -print -quit 2>/dev/null) || return 1
    [ -z "$unexpected" ] || return 1
    unexpected=$(find "$root" -perm /022 -print -quit 2>/dev/null) || return 1
    [ -z "$unexpected" ]
}

_component_public_tree_is_safe() {
    local root=$1 unexpected

    _component_tree_is_safe "$root" || return 1
    unexpected=$(find "$root" \
        \( \( -type d ! -perm 0755 \) -o \( -type f ! -perm 0644 \) \) \
        -print -quit 2>/dev/null) || return 1
    [ -z "$unexpected" ]
}

_component_subconverter_is_safe() {
    local root=$1

    _component_tree_is_safe "$root" || return 1
    _component_file_is_safe "$root/subconverter" 755 || return 1
    _component_file_is_safe "$root/pref.yml" 600
}

_component_normalize_public_tree() {
    local root=$1

    find "$root" -type d -exec chmod 0755 -- {} + &&
        find "$root" -type f -exec chmod 0644 -- {} +
}

_component_extract_tar() {
    local archive=$1 destination=$2

    tar --extract --no-same-owner --no-same-permissions \
        --file "$archive" --directory "$destination"
}

_component_prepare_yq() {
    local archive=$1 stage=$2
    local extract_dir="$stage/yq.extract"
    local candidate='' count=0 path

    /usr/bin/install -d -m 0700 -- "$extract_dir" || return 1
    _component_extract_tar "$archive" "$extract_dir" || return 1
    while IFS= read -r -d '' path; do
        candidate=$path
        count=$((count + 1))
    done < <(find "$extract_dir" -mindepth 1 -maxdepth 1 -type f \
        -name 'yq_linux_*' -print0)
    [ "$count" -eq 1 ] && [ -n "$candidate" ] && [ ! -L "$candidate" ] &&
        [ -x "$candidate" ] || return 2
    /usr/bin/install -m 0755 -- "$candidate" "$stage/yq.ready" || return 1
    _component_file_is_safe "$stage/yq.ready" 755 || return 3
}

_component_prepare_subconverter() {
    local archive=$1 stage=$2
    local extract_dir="$stage/subconverter.extract"
    local candidate="$extract_dir/subconverter" unexpected

    /usr/bin/install -d -m 0700 -- "$extract_dir" || return 1
    _component_extract_tar "$archive" "$extract_dir" || return 1
    unexpected=$(find "$extract_dir" -mindepth 1 -maxdepth 1 \
        ! -name subconverter -print -quit 2>/dev/null) || return 1
    [ -z "$unexpected" ] && [ -d "$candidate" ] && [ ! -L "$candidate" ] || return 2
    [ -f "$candidate/subconverter" ] && [ ! -L "$candidate/subconverter" ] || return 2
    [ -f "$candidate/pref.example.yml" ] && [ ! -L "$candidate/pref.example.yml" ] || return 2
    _component_normalize_public_tree "$candidate" || return 1
    chmod 0755 -- "$candidate/subconverter" || return 1
    /usr/bin/install -m 0600 -- "$candidate/pref.example.yml" \
        "$candidate/pref.yml" || return 1
    _component_subconverter_is_safe "$candidate" || return 3
}

_component_prepare_ui() {
    local archive=$1 stage=$2
    local extract_dir="$stage/ui.extract"
    local candidate="$extract_dir/dist" unexpected

    /usr/bin/install -d -m 0700 -- "$extract_dir" || return 1
    if ! unzip -oqq "$archive" -d "$extract_dir" 2>/dev/null; then
        /usr/bin/rm -rf -- "$extract_dir" || return 1
        /usr/bin/install -d -m 0700 -- "$extract_dir" || return 1
        _component_extract_tar "$archive" "$extract_dir" || return 1
    fi
    unexpected=$(find "$extract_dir" -mindepth 1 -maxdepth 1 \
        ! -name dist -print -quit 2>/dev/null) || return 1
    [ -z "$unexpected" ] && [ -d "$candidate" ] && [ ! -L "$candidate" ] || return 2
    [ -f "$candidate/index.html" ] && [ ! -L "$candidate/index.html" ] || return 2
    _component_normalize_public_tree "$candidate" || return 1
    _component_public_tree_is_safe "$candidate" || return 3
}

_component_rollback_pending() {
    [ "${_COMPONENT_REPLACE_PENDING:-0}" -eq 1 ] || return 0

    if [ "${_COMPONENT_REPLACE_HAD_PREVIOUS:-0}" -eq 1 ]; then
        if [ -e "$_COMPONENT_REPLACE_BACKUP" ] || [ -L "$_COMPONENT_REPLACE_BACKUP" ]; then
            /usr/bin/rm -rf -- "$_COMPONENT_REPLACE_TARGET" || return 1
            /bin/mv -T -- "$_COMPONENT_REPLACE_BACKUP" \
                "$_COMPONENT_REPLACE_TARGET" || return 1
        fi
    else
        /usr/bin/rm -rf -- "$_COMPONENT_REPLACE_TARGET" || return 1
    fi
    _COMPONENT_REPLACE_PENDING=0
}

_component_transaction_init() {
    _COMPONENT_TRANSACTION_TARGETS=()
    _COMPONENT_TRANSACTION_BACKUPS=()
    _COMPONENT_TRANSACTION_HAD_PREVIOUS=()
    _COMPONENT_TRANSACTION_COMMITTED=0
    _COMPONENT_REPLACE_PENDING=0
}

_component_transaction_record() {
    _COMPONENT_TRANSACTION_TARGETS+=("$1")
    _COMPONENT_TRANSACTION_BACKUPS+=("$2")
    _COMPONENT_TRANSACTION_HAD_PREVIOUS+=("$3")
}

_component_rollback_committed() {
    local index target backup had_previous record_failed rollback_failed=0
    local -a remaining_targets=() remaining_backups=() remaining_had_previous=()

    for ((index = ${#_COMPONENT_TRANSACTION_TARGETS[@]} - 1; index >= 0; index--)); do
        target=${_COMPONENT_TRANSACTION_TARGETS[index]}
        backup=${_COMPONENT_TRANSACTION_BACKUPS[index]}
        had_previous=${_COMPONENT_TRANSACTION_HAD_PREVIOUS[index]}
        record_failed=0
        if [ "$had_previous" -eq 1 ]; then
            if { [ ! -e "$backup" ] && [ ! -L "$backup" ]; } ||
                ! /usr/bin/rm -rf -- "$target" ||
                ! /bin/mv -T -- "$backup" "$target"; then
                record_failed=1
            fi
        else
            /usr/bin/rm -rf -- "$target" || record_failed=1
        fi
        if [ "$record_failed" -ne 0 ]; then
            rollback_failed=1
            remaining_targets=("$target" "${remaining_targets[@]}")
            remaining_backups=("$backup" "${remaining_backups[@]}")
            remaining_had_previous=("$had_previous" "${remaining_had_previous[@]}")
        fi
    done
    _COMPONENT_TRANSACTION_TARGETS=("${remaining_targets[@]}")
    _COMPONENT_TRANSACTION_BACKUPS=("${remaining_backups[@]}")
    _COMPONENT_TRANSACTION_HAD_PREVIOUS=("${remaining_had_previous[@]}")
    [ "$rollback_failed" -eq 0 ]
}

_component_replace_path() {
    local candidate=$1 target=$2 backup=$3 verifier=$4
    shift 4

    _COMPONENT_REPLACE_TARGET=$target
    _COMPONENT_REPLACE_BACKUP=$backup
    _COMPONENT_REPLACE_HAD_PREVIOUS=0
    if [ -e "$target" ] || [ -L "$target" ]; then
        _COMPONENT_REPLACE_HAD_PREVIOUS=1
        _COMPONENT_REPLACE_PENDING=1
        if ! /bin/mv -T -- "$target" "$backup"; then
            _COMPONENT_REPLACE_PENDING=0
            return 1
        fi
    else
        _COMPONENT_REPLACE_PENDING=1
    fi

    if ! /bin/mv -T -- "$candidate" "$target" || ! "$verifier" "$target" "$@"; then
        _component_rollback_pending || return 1
        return 1
    fi
    _component_transaction_record "$target" "$backup" "$_COMPONENT_REPLACE_HAD_PREVIOUS"
    _COMPONENT_REPLACE_PENDING=0
}

_component_remove_path() {
    local target=$1 backup=$2

    [ -e "$target" ] || [ -L "$target" ] || return 0
    _COMPONENT_REPLACE_TARGET=$target
    _COMPONENT_REPLACE_BACKUP=$backup
    _COMPONENT_REPLACE_HAD_PREVIOUS=1
    _COMPONENT_REPLACE_PENDING=1
    if ! /bin/mv -T -- "$target" "$backup"; then
        _COMPONENT_REPLACE_PENDING=0
        return 1
    fi
    _component_transaction_record "$target" "$backup" 1
    _COMPONENT_REPLACE_PENDING=0
}

_component_cleanup_stages() {
    local bin_stage=${1:-} ui_stage=${2:-} rollback_failed=0

    if [ "${_COMPONENT_TRANSACTION_COMMITTED:-0}" -ne 1 ]; then
        _component_rollback_committed || rollback_failed=1
    fi
    _component_rollback_pending || rollback_failed=1
    if [ "$rollback_failed" -ne 0 ]; then
        _ui_error "组件安装事务回滚失败，已保留暂存目录"
        _ui_detail "暂存" "${bin_stage:-$ui_stage}"
        return 1
    fi
    [ -z "$bin_stage" ] || /usr/bin/rm -rf -- "$bin_stage" || return 1
    [ -z "$ui_stage" ] || /usr/bin/rm -rf -- "$ui_stage" || return 1
}

unzip_zip() (
    local bin_stage='' ui_stage='' kernel_unpacked kernel_candidate
    local yq_rc converter_rc ui_rc component_dir component_label
    local kernel_dir="$BIN_BASE_DIR/$CLASHCTL_KERNEL"
    local ui_target="$CLASH_RESOURCES_DIR/dist"
    local -a valid_archives=()

    _component_transaction_init
    trap '_component_cleanup_stages "$bin_stage" "$ui_stage" || :' EXIT
    umask 077
    # 组件按需：ZIP_* 为空即跳过（clashctl install 只装 kernel+yq，
    # subconverter/UI 由 provision_component 单独补装）
    for component_dir in "$ZIP_KERNEL" "$ZIP_YQ" "$ZIP_SUBCONVERTER" "$ZIP_UI"; do
        [ -z "$component_dir" ] || valid_archives+=("$component_dir")
    done
    [ ${#valid_archives[@]} -gt 0 ] || {
        _ui_error '没有待安装的组件归档'
        return 1
    }
    valid_zip "${valid_archives[@]}" || return 1
    for component_dir in "$BIN_BASE_DIR" "$kernel_dir" "$CLASH_RESOURCES_DIR"; do
        if [ "$component_dir" = "$BIN_BASE_DIR" ]; then
            component_label=运行组件目录
        elif [ "$component_dir" = "$kernel_dir" ]; then
            component_label=内核目录
        else
            component_label=资源目录
        fi
        _managed_directory_prepare "$component_dir" 0755 || {
            _ui_error "${component_label}无法安全使用"
            _ui_detail "目录" "$component_dir"
            _ui_detail "要求" "必须是当前用户所有的真实目录，且组用户和其他用户不可写"
            return 1
        }
    done

    bin_stage=$(mktemp -d "$BIN_BASE_DIR/.components.XXXXXX") || {
        _ui_error "无法创建组件暂存目录"
        _ui_detail "目录" "$BIN_BASE_DIR"
        return 1
    }
    ui_stage=$(mktemp -d "$CLASH_RESOURCES_DIR/.web-ui.XXXXXX") || {
        _ui_error "无法创建 Web UI 暂存目录"
        _ui_detail "目录" "$CLASH_RESOURCES_DIR"
        return 1
    }
    chmod 0700 -- "$bin_stage" "$ui_stage" || {
        _ui_error "无法保护组件暂存目录"
        return 1
    }

    kernel_unpacked="$bin_stage/kernel.unpacked"
    kernel_candidate="$bin_stage/kernel.ready"
    if [ -n "$ZIP_KERNEL" ] && {
        ! gzip -dc "$ZIP_KERNEL" >"$kernel_unpacked" ||
            ! /usr/bin/install -m 0755 -- "$kernel_unpacked" "$kernel_candidate"
    }; then
        _ui_error "安装内核失败：$CLASHCTL_KERNEL"
        return 1
    fi
    if [ -n "$ZIP_KERNEL" ] && ! _component_file_is_safe "$kernel_candidate" 755; then
        _ui_error "内核文件的归属或权限校验失败"
        return 1
    fi

    yq_rc=0
    [ -z "$ZIP_YQ" ] || _component_prepare_yq "$ZIP_YQ" "$bin_stage" || yq_rc=$?
    if [ "$yq_rc" -ne 0 ]; then
        if [ "$yq_rc" -eq 2 ]; then
            _ui_error "yq 归档结构无效"
        else
            _ui_error "准备 yq 失败"
        fi
        _ui_detail "预期" "归档根目录中唯一的 yq_linux_* 可执行文件"
        if [ "$yq_rc" -eq 2 ]; then
            _component_discard_invalid_cache yq "$ZIP_YQ"
        fi
        return 1
    fi

    converter_rc=0
    [ -z "$ZIP_SUBCONVERTER" ] ||
        _component_prepare_subconverter "$ZIP_SUBCONVERTER" "$bin_stage" || converter_rc=$?
    if [ "$converter_rc" -ne 0 ]; then
        if [ "$converter_rc" -eq 2 ]; then
            _ui_error "subconverter 归档结构无效"
        else
            _ui_error "准备 subconverter 失败"
        fi
        _ui_detail "预期" "subconverter/ 及其可执行文件和 pref.example.yml"
        if [ "$converter_rc" -eq 2 ]; then
            _component_discard_invalid_cache subconverter "$ZIP_SUBCONVERTER"
        fi
        return 1
    fi

    ui_rc=0
    [ -z "$ZIP_UI" ] || _component_prepare_ui "$ZIP_UI" "$ui_stage" || ui_rc=$?
    if [ "$ui_rc" -ne 0 ]; then
        if [ "$ui_rc" -eq 2 ]; then
            _ui_error "Web UI 归档结构无效"
        else
            _ui_error "准备 Web UI 失败"
        fi
        _ui_detail "预期" "dist/ 目录及 dist/index.html"
        if [ "$ui_rc" -eq 2 ]; then
            _component_discard_invalid_cache 'Web UI' "$ZIP_UI"
        fi
        return 1
    fi

    if [ -n "$ZIP_KERNEL" ]; then
        _component_replace_path "$kernel_candidate" "$BIN_KERNEL" \
            "$bin_stage/kernel.previous" _component_file_is_safe 755 || {
            _ui_error "提交内核失败：$CLASHCTL_KERNEL"
            return 1
        }
    fi
    if [ -n "$ZIP_YQ" ]; then
        _component_replace_path "$bin_stage/yq.ready" "$BIN_YQ" \
            "$bin_stage/yq.previous" _component_file_is_safe 755 || {
            _ui_error '提交 yq 失败'
            return 1
        }
    fi
    if [ -n "$ZIP_SUBCONVERTER" ]; then
        _component_replace_path "$bin_stage/subconverter.extract/subconverter" \
            "$BIN_SUBCONVERTER_DIR" "$bin_stage/subconverter.previous" \
            _component_subconverter_is_safe || {
            _ui_error '提交 subconverter 失败'
            return 1
        }
    fi
    if [ -n "$ZIP_UI" ]; then
        _component_replace_path "$ui_stage/ui.extract/dist" "$ui_target" \
            "$ui_stage/dist.previous" _component_public_tree_is_safe || {
            _ui_error '提交 Web UI 失败'
            return 1
        }
    fi

    if ! _component_remove_path "$BIN_BASE_DIR/yq.1" "$bin_stage/yq.1.previous" ||
        ! _component_remove_path "$BIN_BASE_DIR/install-man-page.sh" \
            "$bin_stage/install-man-page.previous"; then
        _ui_error '无法清理旧版 yq 附带文件'
        return 1
    fi
    if { [ -z "$ZIP_KERNEL" ] || _component_file_is_safe "$BIN_KERNEL" 755; } &&
        { [ -z "$ZIP_YQ" ] || _component_file_is_safe "$BIN_YQ" 755; } &&
        { [ -z "$ZIP_SUBCONVERTER" ] || _component_subconverter_is_safe "$BIN_SUBCONVERTER_DIR"; } &&
        { [ -z "$ZIP_UI" ] || _component_public_tree_is_safe "$ui_target"; }; then
        :
    else
        _ui_error '运行组件的归属或权限校验失败'
        return 1
    fi
    _COMPONENT_TRANSACTION_COMMITTED=1
    if ! _component_cleanup_stages "$bin_stage" "$ui_stage"; then
        _ui_error "无法清理组件暂存目录"
        return 1
    fi
    bin_stage=
    ui_stage=
    trap - EXIT
    _ui_ok "运行组件已安装"
)

_set_envs() {
    local rev
    _set_env INIT_TYPE "$INIT_TYPE" || return 1
    _set_env CLASHCTL_KERNEL "$CLASHCTL_KERNEL" || return 1
    # 无 .git 的安装记录 rev；git 安装以 rev-parse 为准（clashctl update 直接读 git）
    if [ ! -d "${CLASHCTL_SRC}/.git" ]; then
        rev=$(_update_source_rev "$CLASHCTL_SRC") || return 1
        _set_env CLASHCTL_REV "$rev" || return 1
    fi
}

apply_rc() {
    detect_rc

    local rc rc_status configured=()
    for rc in "$SHELL_RC_BASH" "$SHELL_RC_ZSH"; do
        [ -f "$rc" ] || continue

        rc_status=0
        _append_source_block "$rc" || rc_status=$?
        if [ "$rc_status" -eq 2 ]; then
            _ui_error "Shell 配置中的 clashctl 托管标记不完整，已保留原文件"
            _ui_detail "文件" "$rc"
            return 1
        elif [ "$rc_status" -ne 0 ]; then
            _ui_error "无法更新 Shell 配置"
            _ui_detail "文件" "$rc"
            return 1
        fi
        configured+=("$rc")
    done

    if [ -n "$SHELL_RC_FISH" ]; then
        rc_status=0
        _write_fish_rc || rc_status=$?
        if [ "$rc_status" -eq 3 ]; then
            _ui_error "Fish 配置不是 clashctl 托管文件，已保留原文件"
            _ui_detail "文件" "$SHELL_RC_FISH"
            return 1
        elif [ "$rc_status" -ne 0 ]; then
            _ui_error "无法更新 Shell 配置"
            _ui_detail "文件" "$SHELL_RC_FISH"
            return 1
        fi
        configured+=("$SHELL_RC_FISH")
    fi

    if [ ${#configured[@]} -gt 0 ]; then
        _ui_ok "Shell 集成已就绪"
        for rc in "${configured[@]}"; do
            _ui_detail "配置" "$rc"
        done
    fi

    . "$CLASHCTL_CMD_DIR/clashctl.sh" || {
        _ui_error "加载 clashctl 命令失败"
        return 1
    }
    [ ${#configured[@]} -gt 0 ] && return 0
    return 2
}
revoke_rc() {
    detect_rc

    local rc failures=0
    for rc in "$SHELL_RC_BASH" "$SHELL_RC_ZSH"; do
        [ -n "$rc" ] || continue
        _remove_source_block "$rc" || {
            _ui_error "无法清理 Shell 配置"
            _ui_detail "文件" "$rc"
            failures=1
        }
    done

    if [ -n "$SHELL_RC_FISH" ] && [ -e "$SHELL_RC_FISH" ]; then
        if head -n 1 -- "$SHELL_RC_FISH" 2>/dev/null |
            grep -Fqx '# clashctl shell-rc (managed by install.sh, do not edit)'; then
            /usr/bin/rm -f -- "$SHELL_RC_FISH" || {
                _ui_error "无法清理 Fish 配置"
                _ui_detail "文件" "$SHELL_RC_FISH"
                failures=1
            }
        else
            _ui_warn "Fish 配置不再由 clashctl 管理，已保留"
            _ui_detail "文件" "$SHELL_RC_FISH"
        fi
    fi
    return "$failures"
}
