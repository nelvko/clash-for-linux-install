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
    local required_zips=(yq subconverter ui)

    case "${CLASHCTL_KERNEL}" in
    clash)
        required_zips=(clash "${required_zips[@]}")
        ;;
    mihomo | *)
        required_zips=(mihomo "${required_zips[@]}")
        ;;
    esac

    download_zip "${required_zips[@]}" || return 1

    case "${CLASHCTL_KERNEL}" in
    clash)
        ZIP_KERNEL="$ZIP_CLASH"
        ;;
    mihomo | *)
        ZIP_KERNEL="$ZIP_MIHOMO"
        ;;
    esac
    BIN_KERNEL="${BIN_BASE_DIR}/$CLASHCTL_KERNEL"
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
    local check_latest="${CLASHCTL_CHECK_LATEST_VERSION:-1}"
    local latest_failed=0 version_source=配置版本

    case "$check_latest" in
    1)
        local tag
        tag=$(_fetch_latest_tag "$repo") && {
            printf -v "$varname" '%s' "$tag"
            _ui_detail "$repo" "$tag（最新版本）"
            return 0
        }
        latest_failed=1
        ;;
    esac

    # 版本来源优先级：最新版本查询 > 用户指定（.env/环境变量）> 文件顶部的内置钉版
    if [ -z "$local_version" ]; then
        version_source=内置钉版
        case "$varname" in
        VERSION_MIHOMO) local_version=$DEFAULT_VERSION_MIHOMO ;;
        VERSION_YQ) local_version=$DEFAULT_VERSION_YQ ;;
        VERSION_SUBCONVERTER) local_version=$DEFAULT_VERSION_SUBCONVERTER ;;
        VERSION_UI) local_version=$DEFAULT_VERSION_UI ;;
        esac
    fi
    if [ -n "$local_version" ]; then
        if [ "$latest_failed" -ne 0 ] && [ "${CLASHCTL_LATEST_VERSION_FALLBACK_WARNED:-0}" -eq 0 ]; then
            _ui_warn "无法查询部分依赖的最新版本，使用配置版本或内置钉版"
            CLASHCTL_LATEST_VERSION_FALLBACK_WARNED=1
        fi
        printf -v "$varname" '%s' "$local_version"
        _ui_detail "$repo" "$local_version（$version_source）"
        return 0
    fi

    _ui_error "无法解析依赖版本：$repo"
    _ui_detail "原因" "未配置版本、无内置钉版，且最新版本查询不可用"
    return 1
}

_archive_is_valid() {
    local archive=$1
    local expected=${archive%.part}

    [ -f "$archive" ] && [ -s "$archive" ] || return 1
    case $expected in
    *.zip) unzip -tqq "$archive" >/dev/null 2>&1 ;;
    *.tar.gz | *.tgz) tar -tzf "$archive" >/dev/null 2>&1 ;;
    *.gz) gzip -tq "$archive" >/dev/null 2>&1 ;;
    *) gzip -tq "$archive" >/dev/null 2>&1 || unzip -tqq "$archive" >/dev/null 2>&1 ;;
    esac
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

    if [ -e "$target" ]; then
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

    if [ -t 2 ] && [ "${CLASHCTL_VERBOSE:-}" = 1 ]; then
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
        _ui_detail "重试" "检查网络或 GH_PROXY 后重新运行安装脚本"
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
    /usr/bin/install -d "$ZIP_BASE_DIR" || {
        _ui_error "无法创建依赖缓存目录"
        _ui_detail "目录" "$ZIP_BASE_DIR"
        return 1
    }
    local url_clash url_mihomo url_yq url_subconverter
    local arch flags level
    arch=$(uname -m) || {
        _ui_error "无法检测系统架构"
        return 1
    }

    CLASHCTL_LATEST_VERSION_FALLBACK_WARNED=0
    case "${CLASHCTL_CHECK_LATEST_VERSION:-1}" in
    1) _ui_info "查询依赖版本" ;;
    esac
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

    _ui_info "系统架构：$arch"
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

unzip_zip() {
    valid_zip "$ZIP_KERNEL" "$ZIP_YQ" "$ZIP_SUBCONVERTER" "$ZIP_UI" || return 1
    /usr/bin/install -d "$BIN_BASE_DIR" "$CLASH_RESOURCES_DIR" || {
        _ui_error "无法创建组件安装目录"
        return 1
    }

    _ui_info "安装运行组件"
    /usr/bin/install -D <(gzip -dc "$ZIP_KERNEL") "$BIN_KERNEL" || {
        _ui_error "安装内核失败：$CLASHCTL_KERNEL"
        return 1
    }
    tar -xf "$ZIP_YQ" -C "${BIN_BASE_DIR}" || {
        _ui_error "解压 yq 失败"
        return 1
    }
    /bin/mv -f "${BIN_BASE_DIR}"/yq_* "${BIN_BASE_DIR}/yq" || {
        _ui_error "安装 yq 失败"
        return 1
    }
    tar -xf "$ZIP_SUBCONVERTER" -C "$BIN_BASE_DIR" || {
        _ui_error "解压 subconverter 失败"
        return 1
    }
    /bin/cp "$BIN_SUBCONVERTER_DIR/pref.example.yml" "$BIN_SUBCONVERTER_CONFIG" || {
        _ui_error "初始化 subconverter 配置失败"
        return 1
    }
    unzip -oqq "$ZIP_UI" -d "$CLASH_RESOURCES_DIR" 2>/dev/null ||
        tar -xf "$ZIP_UI" -C "$CLASH_RESOURCES_DIR" || {
        _ui_error "解压 Web UI 失败"
        return 1
    }
    _ui_ok "运行组件已安装"
}

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
