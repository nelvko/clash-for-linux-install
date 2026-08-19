#!/usr/bin/env bash

# 安装期物化后存在；uninstall.sh 自安装目录运行时亦存在
. "$CLASHCTL_SRC/.env"

for lib_file in "$CLASHCTL_SRC"/scripts/lib/*.sh; do
    [ -f "$lib_file" ] || continue
    . "$lib_file"
done

ARCHIVE_BASE_DIR="${CLASHCTL_SRC}/archives"
ZIP_BASE_DIR="${ARCHIVE_BASE_DIR}"

valid_required() {
    local required_cmds=("xz" "pgrep" "pkill" "curl" "tar" 'unzip' 'gzip' 'shuf')
    local missing=()
    for cmd in "${required_cmds[@]}"; do
        command -v "$cmd" >&/dev/null || missing+=("$cmd")
    done

    command -v ss >&/dev/null || command -v netstat >&/dev/null || missing+=("ss/netstat")
    command -v ip >&/dev/null || command -v hostname >&/dev/null || missing+=("ip/hostname")

    [ ${#missing[@]} -eq 0 ] || _errorcat "请先安装以下命令：${missing[*]}" || exit
}

prepare_zip() {
    load_zip >&/dev/null
    local required_zips=()
    case "${CLASHCTL_KERNEL}" in
    clash)
        [ ! -f "$ZIP_CLASH" ] && required_zips+=("clash")
        ;;
    mihomo | *)
        [ ! -f "$ZIP_MIHOMO" ] && required_zips+=("mihomo")
        ;;
    esac
    [ ! -f "$ZIP_YQ" ] && required_zips+=("yq")
    [ ! -f "$ZIP_SUBCONVERTER" ] && required_zips+=("subconverter")
    [ ! -f "$ZIP_UI" ] && required_zips+=("ui")

    download_zip "${required_zips[@]}"

    case "${CLASHCTL_KERNEL}" in
    clash)
        ZIP_KERNEL="$ZIP_CLASH"
        ;;
    mihomo | *)
        ZIP_KERNEL="$ZIP_MIHOMO"
        ;;
    esac
    BIN_KERNEL="${BIN_BASE_DIR}/$CLASHCTL_KERNEL"
    unzip_zip
}
load_zip() {
    local matches=()
    shopt -s nullglob
    matches=("${ZIP_BASE_DIR}"/clash*)
    ZIP_CLASH="${matches[0]:-}"
    matches=("${ZIP_BASE_DIR}"/mihomo*)
    ZIP_MIHOMO="${matches[0]:-}"
    matches=("${ZIP_BASE_DIR}"/yq*)
    ZIP_YQ="${matches[0]:-}"
    matches=("${ZIP_BASE_DIR}"/subconverter*)
    ZIP_SUBCONVERTER="${matches[0]:-}"
    matches=("${ZIP_BASE_DIR}"/dist*)
    ZIP_UI="${matches[0]:-}"
    shopt -u nullglob
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
    local latest_failed=0

    case "$check_latest" in
    1)
        local tag
        tag=$(_fetch_latest_tag "$repo") && {
            printf -v "$varname" '%s' "$tag"
            _okcat '🏷️ ' "${repo} → $tag（最新版本）"
            return 0
        }
        latest_failed=1
        ;;
    esac

    [ -n "$local_version" ] && {
        if [ "$latest_failed" -ne 0 ] && [ "${CLASHCTL_LATEST_VERSION_FALLBACK_WARNED:-0}" -eq 0 ]; then
            _errorcat '⚠️ ' "依赖最新版本查询失败，已回退到指定版本" || true
            CLASHCTL_LATEST_VERSION_FALLBACK_WARNED=1
        fi
        printf -v "$varname" '%s' "$local_version"
        _okcat '🏷️ ' "${repo} → $local_version（指定版本）"
        return 0
    }

    if [ "$latest_failed" -ne 0 ]; then
        _errorcat "${repo} 最新版本查询失败，且未在 .env.install 指定 $varname"
    else
        _errorcat "${repo} 未指定版本，请在 .env.install 手动指定 $varname"
    fi
    return 1
}

download_zip() {
    (($#)) || return 0
    local url_clash url_mihomo url_yq url_subconverter
    local arch=$(uname -m)

    CLASHCTL_LATEST_VERSION_FALLBACK_WARNED=0
    case "${CLASHCTL_CHECK_LATEST_VERSION:-1}" in
    1) _okcat '🔎' "查询依赖最新版本..." ;;
    esac
    local item
    for item in "$@"; do
        case $item in
        mihomo) _resolve_version VERSION_MIHOMO MetaCubeX/mihomo || exit ;;
        yq) _resolve_version VERSION_YQ mikefarah/yq || exit ;;
        subconverter) _resolve_version VERSION_SUBCONVERTER "$SUBCONVERTER_REPO" || exit ;;
        ui) _resolve_version VERSION_UI Zephyruso/zashboard || exit ;;
        esac
    done

    case "$arch" in
    x86_64)
        local flags=$(grep -m1 '^flags' /proc/cpuinfo)
        local level=v1
        grep -qw sse4_2 <<<"$flags" && grep -qw popcnt <<<"$flags" && level=v2
        grep -qw avx2 <<<"$flags" && grep -qw fma <<<"$flags" && level=v3
        VERSION_MIHOMO=${level}-$VERSION_MIHOMO

        url_clash=https://github.com/nelvko/clash-for-linux-install/releases/download/clash/clash-linux-amd64-2023.08.17.gz
        url_mihomo=https://github.com/MetaCubeX/mihomo/releases/download/${VERSION_MIHOMO##*-}/mihomo-linux-amd64-${VERSION_MIHOMO}.gz
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
        _errorcat "未知的架构版本：$arch，请自行下载对应版本至 ${ZIP_BASE_DIR} 目录" || exit
        ;;
    esac

    # UI 为纯静态资源，与架构无关
    local url_ui="https://github.com/Zephyruso/zashboard/releases/download/${VERSION_UI}/dist.zip"

    local -A urls=(
        [clash]="$url_clash"
        [mihomo]="$url_mihomo"
        [yq]="$url_yq"
        [subconverter]="$url_subconverter"
        [ui]="$url_ui"
    )

    local item target_zips=() level=
    _okcat '🖥️ ' "系统架构：$arch $level"
    for item in "$@"; do
        local url="${urls[$item]}"
        local proxy_url="${GH_PROXY:+${GH_PROXY%/}/}${url}"
        url="$proxy_url"
        _okcat '⏳' "正在下载：${item}：$url"
        local target="${ZIP_BASE_DIR}/$(basename "$url")"
        curl \
            --progress-bar \
            --show-error \
            --fail \
            --insecure \
            --location \
            --max-time "$CLASHCTL_DOWNLOAD_TIMEOUT" \
            --retry 1 \
            --output "$target" \
            "$url"
        target_zips+=("$target")
    done
    valid_zip "${target_zips[@]}"
    load_zip >&/dev/null
}
valid_zip() {
    (($#)) || return 1
    local zip fail_zips=()
    for zip in "$@"; do
        gzip -tq "$zip" || unzip -tqq "$zip" || fail_zips+=("$zip")
    done

    [ ${#fail_zips[@]} -eq 0 ] || _errorcat "文件验证失败：${fail_zips[*]} 请删除后重试，或自行下载对应版本至 ${ZIP_BASE_DIR} 目录" || exit
}
unzip_zip() {
    valid_zip "$ZIP_KERNEL" "$ZIP_YQ" "$ZIP_SUBCONVERTER" "$ZIP_UI"
    /usr/bin/install -D <(gzip -dc "$ZIP_KERNEL") "$BIN_KERNEL"
    tar -xf "$ZIP_YQ" -C "${BIN_BASE_DIR}"
    /bin/mv -f "${BIN_BASE_DIR}"/yq_* "${BIN_BASE_DIR}/yq"
    tar -xf "$ZIP_SUBCONVERTER" -C "$BIN_BASE_DIR"
    /bin/cp "$BIN_SUBCONVERTER_DIR/pref.example.yml" "$BIN_SUBCONVERTER_CONFIG"
    unzip -oqq "$ZIP_UI" -d "$CLASH_RESOURCES_DIR" 2>/dev/null || tar -xf "$ZIP_UI" -C "$CLASH_RESOURCES_DIR"
}

_set_envs() {
    _set_env INIT_TYPE "$INIT_TYPE"
    _set_env CLASHCTL_KERNEL "$CLASHCTL_KERNEL"
    # 无 .git 的安装记录 rev；git 安装以 rev-parse 为准（clashctl update 直接读 git）
    [ -d "${CLASHCTL_SRC}/.git" ] ||
        _set_env CLASHCTL_REV "$(_update_source_rev "$CLASHCTL_SRC")"
}

apply_rc() {
    detect_rc

    local rc written=()
    for rc in "$SHELL_RC_BASH" "$SHELL_RC_ZSH"; do
        [ -f "$rc" ] || continue

        # 已有引导块则跳过（幂等，重复安装不再重复追加）
        _append_source_block "$rc"
        written+=("$rc")
    done

    [ -n "$SHELL_RC_FISH" ] && {
        _write_fish_rc && written+=("$SHELL_RC_FISH")
    }

    [ ${#written[@]} -gt 0 ] && _okcat '📄' "已写入 shell 配置：${written[*]}"
    . "$CLASHCTL_CMD_DIR"/clashctl.sh
}
revoke_rc() {
    detect_rc

    local rc
    for rc in "$SHELL_RC_BASH" "$SHELL_RC_ZSH"; do
        [ ! -f "$rc" ] && continue
        sed -i.bak --follow-symlinks '/CLASHCTL_HOME/d' "$rc" 2>/dev/null
    done

    [ -n "$SHELL_RC_FISH" ] && rm -f -- "$SHELL_RC_FISH" 2>/dev/null
}
