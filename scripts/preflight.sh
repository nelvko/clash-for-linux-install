#!/usr/bin/env bash

. "$CLASHCTL_SRC/.env"

for lib_file in "$CLASHCTL_SRC"/scripts/lib/*.sh; do
    [ -f "$lib_file" ] || continue
    . "$lib_file"
done

ARCHIVE_BASE_DIR="${CLASHCTL_SRC}/archives"
ZIP_BASE_DIR="${ARCHIVE_BASE_DIR}"

_resolve_repo_path() {
    case "$1" in
    /*)
        printf '%s\n' "$1"
        ;;
    *)
        printf '%s\n' "${CLASHCTL_SRC}/$1"
        ;;
    esac
}

_valid_required() {
    local required_cmds=("xz" "pgrep" "curl" "tar" 'unzip')
    local missing=()
    for cmd in "${required_cmds[@]}"; do
        command -v "$cmd" >&/dev/null || missing+=("$cmd")
    done
    [ "${#missing[@]}" -gt 0 ] && _error_quit "请先安装以下命令：${missing[*]}"
}

_valid() {
    _valid_required

    if [ -d "$CLASHCTL_HOME" ]; then
        _error_quit "请先执行卸载脚本,以清除安装路径：$CLASHCTL_HOME"
        return 1
    fi

    local msg="${CLASHCTL_HOME}：当前路径不可用，请在 .env 中更换安装路径。"
    if ! mkdir -p "$CLASHCTL_HOME"; then
        _error_quit "$msg"
    fi

    if [ -z "$ZSH_VERSION" ] && [ -z "$BASH_VERSION" ]; then
        _error_quit "仅支持：bash、zsh 执行"
        return 1
    fi
}

_parse_args() {
    for arg in "$@"; do
        case $arg in
        mihomo)
            CLASHCTL_KERNEL=mihomo
            ;;
        clash)
            CLASHCTL_KERNEL=clash
            ;;
        http*)
            CLASHCTL_SUB_URL=$arg
            ;;
        esac
    done
}

_prepare_zip() {
    ZIP_UI=$(_resolve_repo_path "$ZIP_UI")
    _load_zip >&/dev/null
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

    _download_zip "${required_zips[@]}"

    case "${CLASHCTL_KERNEL}" in
    clash)
        ZIP_KERNEL="$ZIP_CLASH"
        ;;
    mihomo | *)
        ZIP_KERNEL="$ZIP_MIHOMO"
        ;;
    esac
    BIN_KERNEL="${BIN_BASE_DIR}/$CLASHCTL_KERNEL"
    _unzip_zip
}
_load_zip() {
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
    shopt -u nullglob
}
_download_zip() {
    (($#)) || return 0
    local url_clash url_mihomo url_yq url_subconverter
    local arch=$(uname -m)
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
        url_subconverter=https://github.com/tindy2013/subconverter/releases/download/${VERSION_SUBCONVERTER}/subconverter_linux64.tar.gz
        ;;
    *86*)
        url_clash=https://github.com/nelvko/clash-for-linux-install/releases/download/clash/clash-linux-386-2023.08.17.gz
        url_mihomo=https://github.com/MetaCubeX/mihomo/releases/download/${VERSION_MIHOMO##*-}/mihomo-linux-386-${VERSION_MIHOMO}.gz
        url_yq=https://github.com/mikefarah/yq/releases/download/${VERSION_YQ}/yq_linux_386.tar.gz
        url_subconverter=https://github.com/tindy2013/subconverter/releases/download/${VERSION_SUBCONVERTER}/subconverter_linux32.tar.gz
        ;;
    armv*)
        url_clash=https://github.com/nelvko/clash-for-linux-install/releases/download/clash/clash-linux-armv5-2023.08.17.gz
        url_mihomo=https://github.com/MetaCubeX/mihomo/releases/download/${VERSION_MIHOMO##*-}/mihomo-linux-armv7-${VERSION_MIHOMO}.gz
        url_yq=https://github.com/mikefarah/yq/releases/download/${VERSION_YQ}/yq_linux_arm.tar.gz
        url_subconverter=https://github.com/tindy2013/subconverter/releases/download/${VERSION_SUBCONVERTER}/subconverter_armv7.tar.gz
        ;;
    aarch64)
        url_clash=https://github.com/nelvko/clash-for-linux-install/releases/download/clash/clash-linux-arm64-2023.08.17.gz
        url_mihomo=https://github.com/MetaCubeX/mihomo/releases/download/${VERSION_MIHOMO##*-}/mihomo-linux-arm64-${VERSION_MIHOMO}.gz
        url_yq=https://github.com/mikefarah/yq/releases/download/${VERSION_YQ}/yq_linux_arm64.tar.gz
        url_subconverter=https://github.com/tindy2013/subconverter/releases/download/${VERSION_SUBCONVERTER}/subconverter_aarch64.tar.gz
        ;;
    *)
        _error_quit "未知的架构版本：$arch，请自行下载对应版本至 ${ZIP_BASE_DIR} 目录"
        ;;
    esac

    local -A urls=(
        [clash]="$url_clash"
        [mihomo]="$url_mihomo"
        [yq]="$url_yq"
        [subconverter]="$url_subconverter"
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
            --retry 1 \
            --output "$target" \
            "$url"
        target_zips+=("$target")
    done
    _valid_zip "${target_zips[@]}"
    _load_zip >&/dev/null
}
_valid_zip() {
    (($#)) || return 1
    local zip fail_zips=()
    for zip in "$@"; do
        gzip -tq "$zip" || unzip -tqq "$zip" || fail_zips+=("$zip")
    done

    ((${#fail_zips[@]})) && _error_quit "文件验证失败：${fail_zips[*]} 请删除后重试，或自行下载对应版本至 ${ZIP_BASE_DIR} 目录"
}
_unzip_zip() {
    _valid_zip "$ZIP_KERNEL" "$ZIP_YQ" "$ZIP_SUBCONVERTER" "$ZIP_UI"
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
}

CLASHCTL_BIN_FALLBACK="${HOME}/.local/bin/clashctl"

_install_cli() {
    local target_dir=$CLASHCTL_HOME
    local resource

    /usr/bin/install -d \
        "$target_dir/bin" \
        "$target_dir/scripts" \
        "$target_dir/resources"

    touch "$CLASH_CONFIG_BASE"

    /usr/bin/install -m 644 "$CLASHCTL_SRC/.env" "$target_dir/.env" && _set_envs
    /usr/bin/install -m 755 "$CLASHCTL_SRC/bin/clashctl" "$target_dir/bin/clashctl"
    /usr/bin/install -m 755 "$CLASHCTL_SRC/uninstall.sh" "$target_dir/uninstall.sh"

    /bin/cp -a "$CLASHCTL_SRC/scripts/cmd" "$target_dir/scripts/"
    /bin/cp -a "$CLASHCTL_SRC/scripts/lib" "$target_dir/scripts/"
    /bin/cp -a "$CLASHCTL_SRC/scripts/init" "$target_dir/scripts/"

    for resource in "$CLASHCTL_SRC"/resources/*; do
        /bin/cp -r "$resource" "$target_dir/resources/"
    done

    local bin_path="$CLASHCTL_BIN"
    [ ! -w "$(dirname "$bin_path")" ] && {
        _failcat '📍' "${CLASHCTL_BIN} 不可写，改为安装到 ${CLASHCTL_BIN_FALLBACK}"
        CLASHCTL_BIN="$CLASHCTL_BIN_FALLBACK"
    }
    local dir
    dir=$(dirname "$CLASHCTL_BIN")
    echo "$PATH" | grep -qE "$dir" || {
        PATH=$PATH:$dir
        echo "PATH=\$PATH:$dir" >>"$HOME/.bashrc"
    }
}
