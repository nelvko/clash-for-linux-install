#!/usr/bin/env bash
# 使用真实 yq 和配置/订阅流程，服务及内核校验由桩隔离宿主机。
# shellcheck disable=SC2119  # 验证无参数的 clashon 入口
set -euo pipefail
REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
export CLASHCTL_HOME="$WORK_DIR" CLASHCTL_KERNEL=mihomo INIT_TYPE=nohup
. "$REPO_DIR/scripts/lib/common.sh"
. "$REPO_DIR/scripts/lib/config.sh"
. "$REPO_DIR/scripts/lib/convert.sh"
. "$REPO_DIR/scripts/lib/service.sh"
. "$REPO_DIR/scripts/cmd/on.sh"
. "$REPO_DIR/scripts/cmd/sub.sh"
BIN_YQ=$(command -v yq)
BIN_KERNEL=/bin/true
mkdir -p "$CLASH_PROFILES_DIR" "$CLASH_RESOURCES_DIR"
cp "$REPO_DIR/resources/mixin.yaml.example" "$CLASH_CONFIG_MIXIN"
# 即使 Mixin 中有节点，也不能代替主配置。
"$BIN_YQ" -i '.proxies.append = [{"name": "mixin-node", "type": "socks5", "server": "localhost", "port": 1080}]' "$CLASH_CONFIG_MIXIN"

assert_rejected() {
    if _merge_config >"$WORK_DIR/merge.out" 2>&1; then fail "$1: merge accepted invalid base"; fi
    [ ! -e "$CLASH_CONFIG_RUNTIME" ] || fail "$1: merge created runtime"
    if clashon >"$WORK_DIR/on.out" 2>&1; then fail "$1: clashon accepted invalid base"; fi
    grep -q 'clashctl sub add --use' "$WORK_DIR/on.out" || fail "$1: missing subscription guidance"
    if service_start >"$WORK_DIR/start.out" 2>&1; then fail "$1: service_start bypassed base guard"; fi
    if service_sudo_start >"$WORK_DIR/sudo.out" 2>&1; then fail "$1: privileged start bypassed base guard"; fi
}
assert_rejected missing
for text in '' 'null' '{}' 'mixed-port: 7890' 'proxies: []' 'proxies: {append: [bad]}' 'proxies: ['; do
    printf '%s\n' "$text" >"$CLASH_CONFIG_BASE"
    assert_rejected "$text"
done
cat >"$WORK_DIR/valid.yaml" <<'YAML'
proxies:
  - name: local-node
    type: socks5
    server: 127.0.0.1
    port: 1080
proxy-groups: []
rules: []
YAML
cp "$WORK_DIR/valid.yaml" "$CLASH_CONFIG_BASE"
BIN_KERNEL=/bin/false
assert_rejected kernel-validation
BIN_KERNEL=/bin/true
# 有本地主配置就允许合并，无需订阅元数据。
_merge_config || fail 'valid local base was rejected'
[ "$("$BIN_YQ" '.proxies | length' "$CLASH_CONFIG_RUNTIME")" = 2 ] || fail 'mixin was not merged with base'
cp "$CLASH_CONFIG_RUNTIME" "$WORK_DIR/runtime.before"
printf '{}\n' >"$CLASH_CONFIG_BASE"
if _merge_config >/dev/null 2>&1; then fail 'empty base replaced existing runtime'; fi
cmp "$WORK_DIR/runtime.before" "$CLASH_CONFIG_RUNTIME" || fail 'rejected merge destroyed previous runtime'
if clashon >/dev/null 2>&1; then fail 'stale runtime bypassed main config guard'; fi
# 无末尾换行的单行 YAML 也应有效。
printf '%s' 'proxies: [{name: inline, type: socks5, server: localhost, port: 1080}]' >"$CLASH_CONFIG_BASE"
_require_base_config || fail 'single-line main config was rejected'
# provider 型主配置也可通过结构检查。
printf 'proxy-providers: {remote: {type: http, url: "https://example.invalid/sub.yaml", path: ./remote.yaml}}\n' >"$CLASH_CONFIG_BASE"
_require_base_config || fail 'provider base was rejected'

# 订阅已添加但未启用时，仍不能启动；首次 use 走真实的合并和重启链路。
rm -f "$CLASH_CONFIG_RUNTIME"
: >"$CLASH_CONFIG_BASE"
cp "$WORK_DIR/valid.yaml" "$CLASH_PROFILES_DIR/demo.yaml"
cat >"$CLASH_PROFILES_META" <<YAML
use: ''
profiles:
  - name: demo
    path: "$CLASH_PROFILES_DIR/demo.yaml"
    url: https://example.invalid/sub
YAML
assert_rejected unused-subscription
active=0 enabled=0 starts=0 detects=0
service_is_active() { [ "$active" = 1 ]; }
service_stop() { active=0; }
service_start() { _require_base_config || return 1; active=1; starts=$((starts + 1)); }
service_enable() { [ "$active" = 1 ] || fail 'enabled before successful start'; enabled=1; }
_detect_proxy_port() { detects=$((detects + 1)); }
_detect_ext_addr() { detects=$((detects + 1)); }
tunstatus() { return 1; }
_sub_use_locked demo >"$WORK_DIR/use.out" 2>&1 || { cat "$WORK_DIR/use.out"; fail 'first subscription activation failed'; }
[ "$active:$enabled:$starts:$detects" = 1:1:1:2 ] || fail 'first activation did not start and enable service'
[ "$("$BIN_YQ" '.use' "$CLASH_PROFILES_META")" = demo ] || fail 'first activation lost current subscription'
[ -s "$CLASH_CONFIG_RUNTIME" ] || fail 'first activation did not generate runtime'
# 后续下载失败不影响已有主配置或运行配置。
cp "$CLASH_CONFIG_BASE" "$WORK_DIR/base.before"
cp "$CLASH_CONFIG_RUNTIME" "$WORK_DIR/runtime.before"
fetch_sub() { return 1; }
if _sub_update_one demo auto >/dev/null 2>&1; then fail 'failed subscription download succeeded'; fi
cmp "$WORK_DIR/base.before" "$CLASH_CONFIG_BASE" || fail 'failed download replaced base'
cmp "$WORK_DIR/runtime.before" "$CLASH_CONFIG_RUNTIME" || fail 'failed download replaced runtime'
_require_base_config || fail 'download failure invalidated previous main config'
# clashon 也支持直接导入的有效主配置并重新生成 runtime。
active=0 enabled=0
on_service_only >/dev/null || fail 'valid main config could not start via clashon'
[ "$active:$enabled" = 1:1 ] || fail 'clashon did not enable successful start'
# 默认入口已完成服务启动，不再重复执行 env-only 的配置校验。
cat >"$WORK_DIR/kernel" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CLASHCTL_HOME/kernel-checks"
SH
chmod +x "$WORK_DIR/kernel"
BIN_KERNEL="$WORK_DIR/kernel"
_get_local_ip() { printf '127.0.0.1\n'; }
active=0
clashon >"$WORK_DIR/full-on.out" || fail 'default clashon failed'
[ "$(grep -Fc -- "-f $CLASH_CONFIG_BASE -t" "$WORK_DIR/kernel-checks")" = 2 ] ||
    fail 'default startup repeated main config checks outside merge and service boundaries'
[ -n "${http_proxy:-}" ] || fail 'default clashon did not set proxy environment'
clashon --env-only >/dev/null || fail 'env-only rejected valid active service'
printf '{}\n' >"$CLASH_CONFIG_BASE"
if clashon >/dev/null 2>&1; then fail 'active service bypassed main config guard'; fi
if clashon --env-only >/dev/null 2>&1; then fail 'env-only bypassed main config guard'; fi
printf 'base-config: ok\n'
