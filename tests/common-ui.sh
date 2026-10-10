#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_DIR=$(cd -- "$TEST_DIR/.." && pwd -P)
WORK_DIR=$(mktemp -d)
trap '/usr/bin/rm -rf -- "$WORK_DIR"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_eq() {
    local expected=$1 actual=$2 description=$3
    [ "$expected" = "$actual" ] ||
        fail "$description: expected [$expected], got [$actual]"
}

assert_empty() {
    [ ! -s "$1" ] || fail "$2"
}

assert_contains() {
    grep -Fqs -- "$2" "$1" || fail "$3: missing [$2]"
}

assert_not_contains() {
    if grep -Fqs -- "$2" "$1"; then
        fail "$3: unexpectedly found [$2]"
    fi
}

export CLASHCTL_HOME="$WORK_DIR/home"
export CLASHCTL_KERNEL=mihomo
export CLASHCTL_COLOR=never
export TERM=dumb
unset NO_COLOR
mkdir -p -- "$CLASHCTL_HOME"

# shellcheck source=../scripts/lib/common.sh
. "$REPO_DIR/scripts/lib/common.sh"
# shellcheck source=../scripts/lib/config.sh
. "$REPO_DIR/scripts/lib/config.sh"

stdout_file="$WORK_DIR/stdout"
stderr_file="$WORK_DIR/stderr"

# 启动前配置门禁：缺失时给出可复制命令，无效时保留路径及校验错误。
(
    CLASH_CONFIG_BASE="$WORK_DIR/base.yaml"
    _has_proxy_nodes() { [ "$BASE_HAS_NODES" = true ]; }
    _valid_config() {
        if [ "$BASE_VALID" = true ]; then return 0; fi
        printf 'kernel: invalid proxy type\n' >&2
        return 1
    }
    for state in missing empty no-nodes invalid valid; do
        BASE_HAS_NODES=true BASE_VALID=true
        case $state in
        missing) ;;
        empty) : >"$CLASH_CONFIG_BASE" ;;
        no-nodes) printf '{}\n' >"$CLASH_CONFIG_BASE"; BASE_HAS_NODES=false ;;
        invalid) BASE_VALID=false ;;
        valid) ;;
        esac
        rc=0
        _require_base_config >"$stdout_file" 2>"$stderr_file" || rc=$?
        assert_empty "$stdout_file" "base config $state wrote to stdout"
        if [ "$state" = valid ]; then
            assert_eq 0 "$rc" 'valid base config rejected'
            assert_empty "$stderr_file" 'valid base config emitted an error'
        else
            assert_eq 1 "$rc" "base config $state was accepted"
            case $state in
            missing | empty)
                assert_contains "$stderr_file" 'clashctl sub add --use "<URL>"' 'missing config recovery command'
                ;;
            no-nodes | invalid)
                assert_contains "$stderr_file" "$CLASH_CONFIG_BASE" 'invalid config path'
                assert_not_contains "$stderr_file" '尚未配置订阅' 'invalid config reported as missing subscription'
                ;;
            esac
            if [ "$state" = invalid ]; then
                assert_contains "$stderr_file" 'kernel: invalid proxy type' 'kernel validation diagnostic'
            fi
        fi
    done
)

: >"$stdout_file"
: >"$stderr_file"
_ui_ok_out '处理完成' >"$stdout_file" 2>"$stderr_file"
assert_contains "$stdout_file" '处理完成' '_ui_ok_out stdout content'
assert_empty "$stderr_file" '_ui_ok_out wrote to stderr'

: >"$stdout_file"
: >"$stderr_file"
rc=0
_ui_fail '处理失败' >"$stdout_file" 2>"$stderr_file" || rc=$?
assert_eq 1 "$rc" '_ui_fail return code'
assert_empty "$stdout_file" '_ui_fail wrote to stdout'
assert_contains "$stderr_file" '处理失败' '_ui_fail stderr content'

# 自动模式下颜色和加粗不进入管道，NO_COLOR 始终优先。
CLASHCTL_COLOR=always _ui_ok_out '处理完成' >"$stdout_file"
assert_contains "$stdout_file" $'\033[' 'forced color emits ANSI'
NO_COLOR=1 CLASHCTL_COLOR=always _ui_ok_out '处理完成' >"$stdout_file"
assert_not_contains "$stdout_file" $'\033[' 'NO_COLOR overrides always'
CLASHCTL_COLOR=auto TERM=xterm _ui_ok_out '处理完成' >"$stdout_file"
assert_not_contains "$stdout_file" $'\033[' 'redirected auto output has no ANSI'

# 自举阶段与源码加载后的阶段使用同一颜色策略。
(
    . "$REPO_DIR/install.sh"
    for policy in always never auto no-color; do
        unset NO_COLOR
        CLASHCTL_COLOR=$policy
        if [ "$policy" = no-color ]; then
            NO_COLOR=1
            CLASHCTL_COLOR=always
        fi
        bootstrap=$(_install_bootstrap_step '准备组件' 2>&1)
        loaded=$(_install_ui_emit_fd 2 step '准备组件' 2>&1)
        assert_eq "$bootstrap" "${loaded#$'\n'}" "bootstrap and loaded color policy: $policy"
    done
)

{
    _ui_step '准备组件'
    _ui_info '使用系统版本'
    _ui_warn '已跳过'
} >"$stdout_file" 2>"$stderr_file"
assert_empty "$stdout_file" 'progress and hints wrote to stdout'
for hint in 准备组件 使用系统版本 已跳过; do
    assert_contains "$stderr_file" "$hint" 'progress and hints go to stderr'
done

_okcat '🎉' '处理完成' >"$stdout_file" 2>"$stderr_file"
assert_contains "$stdout_file" '处理完成' 'legacy success content'
assert_empty "$stderr_file" 'legacy success wrote to stderr'
rc=0
_failcat '🍂' '处理失败' >"$stdout_file" 2>"$stderr_file" || rc=$?
assert_eq 1 "$rc" 'legacy failure return code'
assert_empty "$stdout_file" 'legacy failure wrote to stdout'
assert_contains "$stderr_file" '处理失败' 'legacy failure content'

export BIN_YQ=fake_yq
export CLASH_CONFIG_RUNTIME="$WORK_DIR/runtime.yaml"
fake_yq() {
    printf '%s\n' Meta
}
TUN_PRESENT=1
ip() {
    [ "$TUN_PRESENT" -eq 1 ] && printf '%s\n' '7: Meta: <POINTOPOINT,UP>'
}

: >"$stdout_file"
: >"$stderr_file"
tunstatus >"$stdout_file" 2>"$stderr_file"
assert_contains "$stdout_file" '启用' 'active Tun status is plain text'
assert_empty "$stderr_file" 'active Tun status wrote to stderr'

TUN_PRESENT=0
: >"$stdout_file"
: >"$stderr_file"
rc=0
tunstatus >"$stdout_file" 2>"$stderr_file" || rc=$?
assert_eq 1 "$rc" 'inactive Tun status return code'
assert_contains "$stderr_file" '关闭' 'inactive Tun status describes the state'

command -v script >/dev/null 2>&1 || fail 'util-linux script is required'
preflight_probe="$WORK_DIR/preflight-probe.sh"
cat >"$preflight_probe" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

REPO_DIR=$1
CASE_DIR=$2
VERBOSE=$3
export GH_PROXY=${4:-}
INSTALL_MODE=${5:-}
DOWNLOAD_RC=${6:-0}
mkdir -p -- "$CASE_DIR/home" "$CASE_DIR/download"
export CLASHCTL_SRC=$REPO_DIR
export CLASHCTL_HOME="$CASE_DIR/home"
export CLASHCTL_KERNEL=mihomo
export CLASHCTL_COLOR=never
export CLASHCTL_DOWNLOAD_TIMEOUT=60
export _INSTALL_VERBOSE=$VERBOSE

# shellcheck source=../scripts/preflight.sh
. "$REPO_DIR/scripts/preflight.sh"
if [ "$INSTALL_MODE" = install ]; then
    _install_ui_output() { _install_ui_emit_fd "$@"; }
fi

_archive_is_valid() {
    [ -s "$1" ]
}

curl() {
    local arg output= expect_output=0
    : >"$CASE_DIR/curl-args"
    for arg in "$@"; do
        printf '%s\n' "$arg" >>"$CASE_DIR/curl-args"
        if [ "$expect_output" -eq 1 ]; then
            output=$arg
            expect_output=0
        elif [ "$arg" = --output ]; then
            expect_output=1
        fi
    done
    [ -n "$output" ] || return 1
    [ "$DOWNLOAD_RC" -eq 0 ] || return "$DOWNLOAD_RC"
    printf 'archive\n' >"$output"
}

_download_archive component https://example.invalid/component.tar.gz \
    "$CASE_DIR/download/component.tar.gz"
EOF
chmod 0700 "$preflight_probe"

run_preflight_probe() {
    local label=$1 verbose=$2 proxy=${3:-} case_dir="$WORK_DIR/$1" command output rc=0
    local mode=${4:-} download_rc=${5:-0} expected_rc=0
    [ "$download_rc" -eq 0 ] || expected_rc=1
    mkdir -p -- "$case_dir"
    printf -v command '%q ' bash "$preflight_probe" "$REPO_DIR" "$case_dir" "$verbose" "$proxy" "$mode" "$download_rc"
    output="$case_dir/terminal"
    script -q -e -E never -c "$command" /dev/null </dev/null >"$output" 2>&1 || rc=$?
    assert_eq "$expected_rc" "$rc" "preflight progress probe $label"
}

run_preflight_probe quiet ''
assert_contains "$WORK_DIR/quiet/curl-args" --silent 'quiet dependency download'
assert_not_contains "$WORK_DIR/quiet/curl-args" --progress-bar 'quiet dependency download'

run_preflight_probe verbose 1
assert_contains "$WORK_DIR/verbose/curl-args" --progress-bar 'verbose dependency download'
assert_not_contains "$WORK_DIR/verbose/curl-args" --silent 'verbose dependency download'

run_preflight_probe proxied '' https://gh-proxy.example/
requested_url=$(awk 'previous == "--url" { print; exit } { previous = $0 }' "$WORK_DIR/proxied/curl-args")
assert_eq 'https://gh-proxy.example/https://example.invalid/component.tar.gz' \
    "$requested_url" 'dependency download uses proxy URL'
assert_contains "$WORK_DIR/proxied/terminal" "下载地址: $requested_url" \
    'displayed download address matches curl request'

# 安装成功时只显示组件状态，失败必须保留实际请求地址以便排查代理。
run_preflight_probe install-quiet '' https://gh-proxy.example/ install
assert_not_contains "$WORK_DIR/install-quiet/terminal" '下载地址:' 'concise installation output'
assert_contains "$WORK_DIR/install-quiet/terminal" '文件: component.tar.gz' 'installation shows artifact name'
run_preflight_probe install-verbose 1 https://gh-proxy.example/ install
assert_contains "$WORK_DIR/install-verbose/terminal" "下载地址: $requested_url" 'verbose installation shows full URL'
assert_contains "$WORK_DIR/install-verbose/curl-args" --progress-bar 'verbose installation shows download progress'
run_preflight_probe install-failed '' https://gh-proxy.example/ install 22
assert_contains "$WORK_DIR/install-failed/terminal" '下载失败' 'failed installation explains the error'
assert_contains "$WORK_DIR/install-failed/terminal" "下载地址: $requested_url" \
    'failed installation retains the actual download address'

# GH_PROXY 无隐式默认：未显式提供时保持未设（直连），不再默认走第三方镜像
no_proxy_probe="$WORK_DIR/no-proxy.probe"
env -u GH_PROXY CLASHCTL_HOME="$WORK_DIR/no-proxy-home" CLASHCTL_SRC="$REPO_DIR" \
    bash -c '. "$1/scripts/lib/common.sh" >/dev/null 2>&1; printf "%s" "${GH_PROXY-unset}"' \
    _ "$REPO_DIR" >"$no_proxy_probe" 2>/dev/null
assert_eq 'unset' "$(<"$no_proxy_probe")" 'GH_PROXY has no implicit default'

printf 'common-ui: ok\n'
