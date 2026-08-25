#!/usr/bin/env bash

# 仅支持 bash：sh/dash（curl | sh）执行时给明确提示而非语法乱码
[ -n "${BASH_VERSION:-}" ] || {
    echo "📢 请使用 bash 执行本脚本：bash install.sh 或 curl ... | bash" >&2
    exit 1
}

# 管道执行（curl | bash / bash -c "$(curl)"）时 stdin 被脚本字节占用，重绑终端保证交互 read 可用
# 先在子 shell 里试开 /dev/tty（exec 失败只退出子 shell；内建重定向失败会退出整个脚本）
if [ ! -t 0 ] && (exec 0</dev/tty) 2>/dev/null; then
    {
        exec 0</dev/tty
    } 2>/dev/null || true
fi

CLASHCTL_SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
_REPO=nelvko/clash-for-linux-install
_BRANCH_DEFAULT=master

# 主体包进 main 函数：管道/下载截断只拿到半截时，bash 解析未闭合函数直接报语法错误、零执行
main() {
    local home=${CLASHCTL_HOME:-} branch=${CLASHCTL_UPDATE_BRANCH:-$_BRANCH_DEFAULT}
    local kernel=${CLASHCTL_KERNEL:-mihomo} sub_url=${CLASHCTL_SUB_URL:-}
    local proxy=${GH_PROXY-https://gh-proxy.org}

    # ── 参数解析：位置参数（内核/订阅URL）+ 旗子；优先级 参数 > 环境变量 > 默认 ──
    while [ $# -gt 0 ]; do
        case $1 in
        mihomo | clash) kernel=$1 ;;
        http*) sub_url=$1 ;;
        --home)
            shift
            [ $# -gt 0 ] || {
                echo "📢 --home 缺少参数" >&2
                return 1
            }
            home=$1
            ;;
        --branch)
            shift
            [ $# -gt 0 ] || {
                echo "📢 --branch 缺少参数" >&2
                return 1
            }
            branch=$1
            ;;
        -h | --help)
            usage
            return 0
            ;;
        *)
            echo "📢 未知参数：$1" >&2
            usage
            return 1
            ;;
        esac
        shift
    done
    [ -n "$home" ] || home="${HOME}/.clashctl"

    # ── 自举：本地没有源码树时，克隆/解压目标即安装目录（无中间暂存）──
    if [ ! -f "${CLASHCTL_SRC}/scripts/preflight.sh" ]; then
        _require_empty_home "$home"
        _fetch_into "$home" "$branch" "$proxy" || return 1
        # 转入安装目录继续首跑物化；参数原样透传
        exec bash "${home}/install.sh" \
            --home "$home" --branch "$branch" \
            ${kernel:+$kernel} ${sub_url:+"$sub_url"}
    fi

    # ── dev 克隆安装：源码树存在但不是目标目录 → 以本地路径为 remote 克隆（携带未推送提交）──
    if [ "${CLASHCTL_SRC}" != "$home" ]; then
        _require_empty_home "$home"
        if command -v git >/dev/null 2>&1 && [ -d "${CLASHCTL_SRC}/.git" ]; then
            echo "⏳ 正在克隆：${CLASHCTL_SRC}（${branch:-默认分支}）"
            git clone -q "$CLASHCTL_SRC" "$home" || return 1
        else
            echo "⏳ 正在复制：${CLASHCTL_SRC} → ${home}"
            cp -a "$CLASHCTL_SRC" "$home" || return 1
        fi
        exec bash "${home}/install.sh" \
            --home "$home" --branch "$branch" \
            ${kernel:+$kernel} ${sub_url:+"$sub_url"}
    fi

    # ── 首跑物化：install.sh 已位于安装目录内 ──
    if [ -f "${CLASHCTL_SRC}/.env" ]; then
        echo "📢 检测到已安装：${CLASHCTL_SRC}。更新请使用 clashctl update；确需重装请先执行卸载脚本。" >&2
        return 1
    fi

    # 1) 用户态骨架与依赖下载、服务注册（.env 尚未物化：失败即止不留安装态，
    #    可直接重跑安装；依赖版本键此刻取自环境变量或内置钉版）
    export CLASHCTL_HOME="$home"
    . "${CLASHCTL_SRC}/scripts/lib/common.sh"
    export CLASHCTL_KERNEL="$kernel" CLASHCTL_SUB_URL="$sub_url" CLASHCTL_UPDATE_BRANCH="$branch"
    . "${CLASHCTL_SRC}/scripts/preflight.sh"
    valid_required

    /usr/bin/install -d "${CLASH_DATA_DIR}/profiles"
    [ -f "${CLASH_CONFIG_MIXIN}" ] || cp "${CLASH_RESOURCES_DIR}/mixin.yaml.example" "${CLASH_CONFIG_MIXIN}"
    touch "$CLASH_CONFIG_BASE"

    echo "😼 安装内核：$kernel"
    echo "📦 安装路径：$CLASHCTL_HOME"

    prepare_zip
    install_service

    # 2) 安装成功，物化 .env：模板 + 参数/环境变量覆盖烤入文件（此后以 .env 为准）
    cp "${CLASHCTL_SRC}/.env.example" "${CLASHCTL_SRC}/.env" || return 1
    _set_env CLASHCTL_KERNEL "$kernel"
    [ -n "$sub_url" ] && _set_env CLASHCTL_SUB_URL "$sub_url"
    [ -n "$branch" ] && _set_env CLASHCTL_UPDATE_BRANCH "$branch"
    [ "${GH_PROXY+x}" = x ] && _set_env GH_PROXY "$GH_PROXY"
    [ "${CLASHCTL_DOWNLOAD_TIMEOUT+x}" = x ] && _set_env CLASHCTL_DOWNLOAD_TIMEOUT "$CLASHCTL_DOWNLOAD_TIMEOUT"
    _set_envs
    apply_rc

    # 3) 初始配置与订阅
    _merge_config
    _detect_proxy_port
    clashui
    [ -z "$(_get_secret)" ] && clashsecret "$(_get_random_val)" >/dev/null
    clashsecret

    _valid_config "$CLASH_CONFIG_BASE" && {
        CLASHCTL_SUB_URL="file://$CLASH_CONFIG_BASE"
    }
    clashsub add --use "$CLASHCTL_SUB_URL"
    _okcat '🎉' "请执行 source ~/.bashrc 为当前 SHELL 加载 clashctl 命令"
}

_require_empty_home() {
    local home=$1
    if [ -f "$home/.env" ]; then
        echo "📢 检测到已安装：$home。更新请使用 clashctl update；确需重装请先执行卸载脚本。" >&2
        return 1
    fi
    if [ -e "$home" ]; then
        # 半安装态（上次安装中途失败，.env 未物化）：允许续装
        [ -f "$home/install.sh" ] && [ -d "$home/scripts" ] && return 0
        echo "📢 目标目录已存在且非 clashctl 安装：$home" >&2
        return 1
    fi
    local _d=$home
    while [ ! -d "$_d" ]; do _d="$(dirname "$_d")"; done
    [ -w "$_d" ] || {
        echo "📢 ${home}：当前路径不可用，请用 --home 指定其他路径。" >&2
        return 1
    }
}

# 克隆/解压源码直接落到安装目录（无 .git 时为纯目录安装）
_fetch_into() {
    local home=$1 branch=$2 proxy=$3 url

    # 半安装态续装：源码树已在位则跳过取源
    [ -f "$home/install.sh" ] && [ -d "$home/scripts" ] && return 0

    /usr/bin/install -d "$home" || return 1
    if command -v git >/dev/null 2>&1; then
        url=${CLASHCTL_UPDATE_GIT_URL:-}
        [ -n "$url" ] || {
            url="https://github.com/${_REPO}.git"
            [ -n "$proxy" ] && url="${proxy%/}/${url}"
        }
        echo "⏳ 正在克隆：$url（${branch}）"
        git clone -q --depth 50 --single-branch --branch "$branch" "$url" "$home" && {
            git -C "$home" config gc.auto 0
            return 0
        }
        /usr/bin/rm -rf -- "$home"
        echo '🍂 git 通道失败，回落归档下载'
    fi

    url="https://codeload.github.com/${_REPO}/tar.gz/refs/heads/${branch}"
    [ -n "$proxy" ] && url="${proxy%/}/${url}"
    echo "⏳ 正在下载：$url"
    curl -sSL --fail --max-time "${CLASHCTL_DOWNLOAD_TIMEOUT:-60}" --retry 1 "$url" |
        tar -xzf - --strip-components=1 -C "$home" || {
        echo "📢 下载失败：请检查网络，或设置 GH_PROXY=<加速前缀> 后重试" >&2
        /usr/bin/rm -rf -- "$home"
        return 1
    }
}

usage() {
    cat <<'EOF'
Usage:
  bash install.sh [OPTIONS] [mihomo|clash] [订阅URL]

Options:
  --home <路径>      安装路径（默认 ~/.clashctl；亦可用环境变量 CLASHCTL_HOME）
  --branch <分支>    安装分支，并作为后续 clashctl update 的默认跟进分支（默认 master）
  -h, --help         显示帮助信息

安装期定制也可用环境变量：GH_PROXY、CLASHCTL_DOWNLOAD_TIMEOUT、
CLASHCTL_CHECK_LATEST_VERSION、VERSION_MIHOMO/YQ/SUBCONVERTER/UI、SUBCONVERTER_REPO。
EOF
}

main "$@"
# this ensures the entire script is downloaded #
