#!/usr/bin/env bash

# 已安装时存在；install.sh 首跑物化前（依赖下载阶段）暂缺
if [ -f "$CLASHCTL_SRC/.env" ]; then
    . "$CLASHCTL_SRC/.env" || return 1
fi

for lib_file in "$CLASHCTL_SRC"/scripts/lib/*.sh; do
    [ -f "$lib_file" ] || continue
    # shellcheck disable=SC1090
    . "$lib_file"
done

# 查询最新版本失败时使用已知可用版本。
DEFAULT_VERSION_MIHOMO=v1.19.27
DEFAULT_VERSION_YQ=v4.53.3
DEFAULT_VERSION_SUBCONVERTER=v0.9.9
DEFAULT_VERSION_UI=v3.20.0

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
    # 首次安装与按需补装共用；下载结果仅在本次调用内有效。
    local -a normalized=()
    local item system_yq ZIP_KERNEL='' ZIP_YQ='' ZIP_SUBCONVERTER='' ZIP_UI=''
    (($#)) || {
        _ui_error 'prepare_zip 需要显式组件列表'
        return 1
    }
    for item in "$@"; do
        [ "$item" != kernel ] || item=$CLASHCTL_KERNEL
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

    download_zip "${normalized[@]}" || return 1
    unzip_zip
}

# 最新版查询与下载同走 GH_PROXY 通道（有代理时代理优先，直连兜底）：
# 加速前缀对 api.github.com 的支持不一（如 ghfast.top 403、gh-proxy.org 200），
# 代理通道失败必须再试直连；直连本身 connect 超时快速失败，避免受限网络长磨。
_fetch_latest_tag() {
    local repo=$1 url body tag
    local direct_url="https://api.github.com/repos/${repo}/releases/latest"
    local -a urls=("$direct_url")
    [ -z "${GH_PROXY:-}" ] || urls=("$(gh_proxy_url "$direct_url")" "$direct_url")
    for url in "${urls[@]}"; do
        body=$(curl -sSL --fail --connect-timeout 4 --max-time 12 --retry 1 \
            -H 'Accept: application/vnd.github+json' "$url" 2>/dev/null) || continue
        tag=$(printf '%s' "$body" | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 |
            sed -E 's/.*"([^"]+)"[[:space:]]*$/\1/')
        [ -n "$tag" ] && {
            printf '%s\n' "$tag"
            return 0
        }
    done
    return 1
}

_resolve_version() {
    local varname=$1 repo=$2 tag local_version

    # 版本来源优先级：最新版本查询 > 内置备用版本
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
    _ui_detail "原因" "内置钉版缺失，且最新版本查询不可用"
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
    local download_url
    download_url=$(gh_proxy_url "$url")
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
        _ui_error "下载失败：$label"
        _ui_detail "目标" "$target"
        _ui_detail "重试" "检查网络或用 --gh-proxy 指定镜像；续装：bash ${CLASHCTL_HOME:-$HOME/.clashctl}/install.sh（慢链路可调大 CLASHCTL_DOWNLOAD_TIMEOUT）"
        return 1
    fi
    # 校验/搬移失败都不必清理 .part：下次进入时会先删残片，且这里随即 return。
    if ! _archive_is_valid "$part"; then
        _ui_error "下载文件校验失败：$label"
        _ui_detail "上游" "$url"
        return 1
    fi
    if ! /bin/mv -f -- "$part" "$target"; then
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
        clash | mihomo) ZIP_KERNEL=$target ;;
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
}

# 使用 _install_component 子 shell 的局部状态，只恢复正在替换的组件。
_component_cleanup() {
    [ -n "$stage" ] || return 0
    if [ "$pending" = true ]; then
        if [ -e "$stage/previous" ] || [ -L "$stage/previous" ]; then
            if ! /usr/bin/rm -rf -- "$target" ||
                ! /bin/mv -T -- "$stage/previous" "$target"; then
                _ui_error "组件恢复失败，已保留暂存目录"
                _ui_detail "暂存" "$stage"
                return 1
            fi
        elif [ "$had_previous" = false ]; then
            /usr/bin/rm -rf -- "$target" || return 1
        fi
    fi
    /usr/bin/rm -rf -- "$stage"
}

_install_component() (
    local component=$1 archive=$2 target root label parent stage='' candidate
    local pending=false had_previous=false prepare_rc=0
    local -a verifier
    umask 077
    case "$component" in
    kernel)
        target=$BIN_KERNEL root=$BIN_BASE_DIR label=运行组件目录
        verifier=(_component_file_is_safe 755)
        ;;
    yq)
        target=$BIN_YQ root=$BIN_BASE_DIR label=运行组件目录
        verifier=(_component_file_is_safe 755)
        ;;
    subconverter)
        target=$BIN_SUBCONVERTER_DIR root=$BIN_BASE_DIR label=运行组件目录
        verifier=(_component_subconverter_is_safe)
        ;;
    ui)
        target="$CLASH_RESOURCES_DIR/dist" root=$CLASH_RESOURCES_DIR label=资源目录
        verifier=(_component_public_tree_is_safe)
        ;;
    *) return 1 ;;
    esac
    valid_zip "$archive" || return 1
    _managed_directory_prepare "$root" 0755 || {
        _ui_error "${label}无法安全使用"
        _ui_detail "目录" "$root"
        return 1
    }
    parent=$(dirname -- "$target")
    [ "$parent" = "$root" ] || _managed_directory_prepare "$parent" 0755 || {
        _ui_error "组件安装目录无法安全使用"
        _ui_detail "目录" "$parent"
        return 1
    }
    trap '_component_cleanup || exit 1' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    stage=$(mktemp -d "$parent/.components.XXXXXX") || return 1
    case "$component" in
    kernel)
        candidate="$stage/kernel.ready"
        gzip -dc "$archive" >"$candidate" && chmod 0755 -- "$candidate" || prepare_rc=1
        ;;
    yq)
        candidate="$stage/yq.ready"
        _component_prepare_yq "$archive" "$stage" || prepare_rc=$?
        ;;
    subconverter)
        candidate="$stage/subconverter.extract/subconverter"
        _component_prepare_subconverter "$archive" "$stage" || prepare_rc=$?
        ;;
    ui)
        candidate="$stage/ui.extract/dist"
        _component_prepare_ui "$archive" "$stage" || prepare_rc=$?
        ;;
    esac
    if [ "$prepare_rc" -ne 0 ]; then
        if [ "$prepare_rc" -eq 2 ]; then
            _ui_error "$component 归档结构无效"
            _component_discard_invalid_cache "$component" "$archive"
        else
            _ui_error "准备 $component 失败"
        fi
        return 1
    fi
    "${verifier[0]}" "$candidate" "${verifier[@]:1}" || {
        _ui_error "$component 文件的归属或权限校验失败"
        return 1
    }

    [ ! -e "$target" ] && [ ! -L "$target" ] || had_previous=true
    pending=true
    if [ "$had_previous" = true ]; then
        /bin/mv -T -- "$target" "$stage/previous" || return 1
    fi
    if ! /bin/mv -T -- "$candidate" "$target" ||
        ! "${verifier[0]}" "$target" "${verifier[@]:1}"; then
        _ui_error "安装 $component 失败，正在恢复原组件"
        return 1
    fi
    pending=false
)

unzip_zip() {
    local component archive count=0
    for component in kernel yq subconverter ui; do
        case "$component" in
        kernel) archive=${ZIP_KERNEL:-} ;;
        yq) archive=${ZIP_YQ:-} ;;
        subconverter) archive=${ZIP_SUBCONVERTER:-} ;;
        ui) archive=${ZIP_UI:-} ;;
        esac
        [ -n "$archive" ] || continue
        _install_component "$component" "$archive" || return 1
        count=$((count + 1))
    done
    [ "$count" -gt 0 ] || {
        _ui_error '没有待安装的组件归档'
        return 1
    }
    _ui_ok "运行组件已安装"
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
        if [ ! -L "$SHELL_RC_FISH" ] &&
            [ "$(head -n 1 -- "$SHELL_RC_FISH")" = "$CLASHCTL_FISH_MANAGED_MARKER" ] &&
            [ "$(sed -n '2p' "$SHELL_RC_FISH")" = "$(_fish_home_export)" ]; then
            /usr/bin/rm -f -- "$SHELL_RC_FISH" || {
                _ui_error "无法清理 Fish 配置"
                _ui_detail "文件" "$SHELL_RC_FISH"
                failures=1
            }
        else
            _ui_warn "Fish 配置不属于当前安装或已被修改，已保留"
            _ui_detail "文件" "$SHELL_RC_FISH"
        fi
    fi
    return "$failures"
}
