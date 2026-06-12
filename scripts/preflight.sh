#!/usr/bin/env bash

. "$CLASHCTL_SRC/.env"
. "$CLASHCTL_SRC/.env.install"

for lib_file in "$CLASHCTL_SRC"/scripts/lib/*.sh; do
    [ -f "$lib_file" ] || continue
    . "$lib_file"
done

ARCHIVE_BASE_DIR="${CLASHCTL_SRC}/archives"
ZIP_BASE_DIR="${ARCHIVE_BASE_DIR}"

CLASHCTL_CMD_DIR="${CLASHCTL_HOME}/scripts/cmd"

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

valid_env() {
    valid_required

    [ -d "$CLASHCTL_HOME" ] && {
        _errorcat "请先执行卸载脚本,以清除安装路径：$CLASHCTL_HOME"
        exit
    }

    local _d="$CLASHCTL_HOME"
    while [[ ! -d "$_d" ]]; do _d="$(dirname "$_d")"; done
    [[ -w "$_d" ]] || _errorcat "${CLASHCTL_HOME}：当前路径不可用，请在 .env.install 中更换安装路径。" || exit
}

parse_args() {
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
    shopt -u nullglob
}
_fetch_latest_tag() {
    local repo=$1
    # 网络受限时此处会失败，由调用方提示用户在 .env.install 手动指定版本
    local body
    body=$(curl -sL --max-time 10 --retry 1 -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null) || return 1
    local tag
    tag=$(printf '%s' "$body" | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 |
        sed -E 's/.*"([^"]+)"[[:space:]]*$/\1/')
    [ -n "$tag" ] && printf '%s\n' "$tag"
}

_resolve_version() {
    local varname=$1 repo=$2
    [ -n "${!varname}" ] && return 0
    local tag
    tag=$(_fetch_latest_tag "$repo") || {
        _errorcat "${repo} 版本获取失败，请在 .env.install 手动指定 $varname"
        return 1
    }
    printf -v "$varname" '%s' "$tag"
    _okcat '🏷️ ' "${repo} → $tag"
}

download_zip() {
    (($#)) || return 0
    local url_clash url_mihomo url_yq url_subconverter
    local arch=$(uname -m)

    _okcat '🔎' "查询依赖最新版本..."
    local item
    for item in "$@"; do
        case $item in
        mihomo) _resolve_version VERSION_MIHOMO MetaCubeX/mihomo || exit ;;
        yq) _resolve_version VERSION_YQ mikefarah/yq || exit ;;
        subconverter) _resolve_version VERSION_SUBCONVERTER "$SUBCONVERTER_REPO" || exit ;;
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
}

install_clashctl() {
    local target_dir=$CLASHCTL_HOME
    local resource

    /usr/bin/install -d \
        "$target_dir/bin" \
        "$target_dir/scripts" \
        "$target_dir/resources"

    touch "$CLASH_CONFIG_BASE"

    /usr/bin/install -m 644 "$CLASHCTL_SRC/.env" "$target_dir/.env" && _set_envs
    /usr/bin/install -m 755 "$CLASHCTL_SRC/uninstall.sh" "$target_dir/uninstall.sh"

    /bin/cp -a "$CLASHCTL_SRC/scripts/cmd" "$target_dir/scripts/"
    /bin/cp -a "$CLASHCTL_SRC/scripts/lib" "$target_dir/scripts/"
    /bin/cp -a "$CLASHCTL_SRC/scripts/init" "$target_dir/scripts/"

    for resource in "$CLASHCTL_SRC"/resources/*; do
        /bin/cp -r "$resource" "$target_dir/resources/"
    done
    apply_rc
}

detect_rc() {
    local USER_HOME="${HOME}"

    if [ -n "${SUDO_USER}" ]; then
        USER_HOME=$(eval echo "~{SUDO_USER}")
    fi

    command -v bash >&/dev/null && {
        SHELL_RC_BASH="${HOME}/.bashrc"
    }
    command -v zsh >&/dev/null && {
        SHELL_RC_ZSH="${USER_HOME}/.zshrc"
    }
    command -v fish >&/dev/null && {
        SHELL_RC_FISH="${USER_HOME}/.config/fish/conf.d/clashctl.fish"
    }
}
apply_rc() {
    detect_rc

    local source_clashctl=$(
        cat <<EOF
export CLASHCTL_HOME=$CLASHCTL_HOME
. \$CLASHCTL_HOME/scripts/cmd/clashctl.sh
EOF
    )

    local rc written=()
    for rc in "$SHELL_RC_BASH" "$SHELL_RC_ZSH"; do
        [ ! -e "$rc" ] && continue

        [ "$(tail -c 1 -- "$rc" | wc -l)" -eq 0 ] && {
            printf '\n' >>"$rc"
        }

        printf '%s\n' "$source_clashctl" >>"$rc"

        written+=("$rc")
    done

    [ -n "$SHELL_RC_FISH" ] && {
        mkdir -p -- "$(dirname -- "$SHELL_RC_FISH")"
        local fish_quoted=${CLASHCTL_HOME//\\/\\\\}
        fish_quoted=${fish_quoted//\'/\\\'}
        {
            printf "# clashctl shell-rc (managed by install.sh, do not edit)\n"
            printf "set -gx CLASHCTL_HOME '%s'\n\n" "$fish_quoted"
            cat -- "$CLASHCTL_CMD_DIR/clashctl.fish"
        } >"$SHELL_RC_FISH"
        chmod 0644 -- "$SHELL_RC_FISH"
        written+=("$SHELL_RC_FISH")
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
