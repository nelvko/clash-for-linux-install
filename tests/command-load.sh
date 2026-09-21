#!/usr/bin/env bash
# 命令加载与分发冒烟测试：在隔离的假安装目录里 source 加载器，
# 确认 README/help 承诺的每个子命令都能被解析、且其依赖的底层符号都存在。
# 不依赖内核、网络与服务，可在 CI 长期保留。
set -euo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_DIR=$(cd -- "$TEST_DIR/.." && pwd -P)
WORK_DIR=$(mktemp -d)
trap '/usr/bin/rm -rf -- "$WORK_DIR"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

# 造一个最小安装目录：只需要 scripts/ 与 .env，供加载器 source。
HOME_DIR="$WORK_DIR/home"
mkdir -p "$HOME_DIR/scripts"
cp -r "$REPO_DIR/scripts/lib" "$HOME_DIR/scripts/lib"
cp -r "$REPO_DIR/scripts/cmd" "$HOME_DIR/scripts/cmd"
: >"$HOME_DIR/.env"
printf 'CLASHCTL_KERNEL=mihomo\n' >>"$HOME_DIR/.env"

export CLASHCTL_HOME="$HOME_DIR"
export CLASHCTL_SRC="$HOME_DIR"
export CLASHCTL_KERNEL=mihomo
export INIT_TYPE=nohup
# 加载库时 common.sh 会请求系统 yq；无副作用，保持安静。
# shellcheck source=/dev/null
. "$HOME_DIR/scripts/cmd/clashctl.sh"

# 1) 每个公开子命令都必须有 clashXXX 函数
for sub in on off status ui sub node tun mixin secret log upgrade update help; do
    declare -F "clash${sub}" >/dev/null 2>&1 ||
        fail "subcommand not loaded: clashctl ${sub} (clash${sub} undefined)"
done

# 2) 未定义子命令必须被拒绝，且返回非零
if clashctl definitely-not-a-command >"$WORK_DIR/unknown.out" 2>&1; then
    fail 'unknown subcommand was accepted'
fi
grep -q 'Unknown subcommand' "$WORK_DIR/unknown.out" ||
    fail 'unknown subcommand had no diagnosis'

# 3) help 必须能执行且列出核心命令
clashctl help >"$WORK_DIR/help.out" 2>&1 || fail 'clashctl help failed'
for word in on off status ui sub node update; do
    grep -q "  $word " "$WORK_DIR/help.out" ||
        fail "help does not list: $word"
done

# 4) 声明支持 -h/--help 的子命令，其 --help 不应因缺依赖而崩溃。
#    其余命令（如 status/log）本就没有 help 分支，不在此断言。
#    -h 是最轻的路径，能在无内核/无配置下验证函数体前半段接线正确。
for sub in on off sub node tun mixin secret upgrade update; do
    rc=0
    clashctl "$sub" --help >"$WORK_DIR/$sub-help.out" 2>&1 || rc=$?
    [ "$rc" -eq 0 ] ||
        fail "clashctl $sub --help returned $rc: $(head -1 "$WORK_DIR/$sub-help.out")"
    [ -s "$WORK_DIR/$sub-help.out" ] ||
        fail "clashctl $sub --help produced no output"
done

# 无 help 分支的命令也必须能被调用（不报 Unknown subcommand）。
# status 在服务未运行时返回非零属正常，只要求它执行到服务查询。
rc=0
clashctl status >"$WORK_DIR/status.out" 2>&1 || rc=$?
case "$(cat "$WORK_DIR/status.out")" in
*"Unknown subcommand"*) fail 'clashctl status was not dispatched' ;;
esac

# 5) 底层接口对接：master 原版命令依赖的符号必须在本分支的库层存在
#    这些是"换底层"最容易断裂的点，逐一断言定义存在。
required_symbols=(
    service_start service_stop service_is_active service_status service_log
    service_follow_log service_sudo_start service_sudo_stop service_enable
    install_service uninstall_service detect_service_manager
    _merge_config _merge_config_restart _detect_proxy_port _detect_ext_addr
    _require_base_config _valid_config _get_secret _get_bind_addr _is_tun_enabled
    tunstatus _has_proxy_nodes
    _ui_ok _ui_fail _ui_error _ui_info _ui_warn _ui_detail _ui_ok_out
    _okcat _failcat _errorcat
)
for fn in "${required_symbols[@]}"; do
    declare -F "$fn" >/dev/null 2>&1 ||
        fail "required symbol missing on ported lib layer: $fn"
done

# 6) 关键路径变量必须指向 data/（运行时布局），而不是旧的 resources/
case "$CLASH_CONFIG_BASE" in
"$CLASHCTL_HOME/data/"*) ;;
*) fail "CLASH_CONFIG_BASE not under data/: $CLASH_CONFIG_BASE" ;;
esac
case "$CLASH_CONFIG_MIXIN" in
"$CLASHCTL_HOME/data/"*) ;;
*) fail "CLASH_CONFIG_MIXIN not under data/: $CLASH_CONFIG_MIXIN" ;;
esac
[ "$BIN_KERNEL" = "$CLASHCTL_HOME/bin/mihomo/mihomo" ] ||
    fail "BIN_KERNEL layout unexpected: $BIN_KERNEL"

printf 'command-load: ok\n'
