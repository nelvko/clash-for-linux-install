#!/usr/bin/env bash
# 真实命令与 Shell 环境；服务用磁盘状态模拟，覆盖 Bash/Zsh/Fish 的子进程边界。
set -euo pipefail
REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
for shell in bash zsh fish; do command -v "$shell" >/dev/null || fail "$shell is required"; done

cat >"$WORK_DIR/services.sh" <<'STUB'
service_is_active() { [ -f "$CLASHCTL_HOME/running" ]; }
_require_base_config() { [ -f "$CLASHCTL_HOME/base-ready" ]; }
_merge_config() { printf 'merge\n' >>"$CLASHCTL_HOME/calls"; }
_detect_proxy_port() { :; }
_detect_ext_addr() { :; }
_get_bind_addr() { printf 127.0.0.1; }
service_start() {
    [ ! -f "$CLASHCTL_HOME/fail-start" ] || return 1
    printf 'start\n' >>"$CLASHCTL_HOME/calls"
    touch "$CLASHCTL_HOME/running"
}
service_stop() {
    [ ! -f "$CLASHCTL_HOME/fail-stop" ] && [ ! -f "$CLASHCTL_HOME/privileged" ] || return 1
    printf 'stop\n' >>"$CLASHCTL_HOME/calls"
    rm -f "$CLASHCTL_HOME/running"
}
service_enable() { :; }
_service_privileged_marker_exists() { [ -f "$CLASHCTL_HOME/privileged" ]; }
service_sudo_stop() { rm -f "$CLASHCTL_HOME/running" "$CLASHCTL_HOME/privileged"; }
STUB
cat >"$WORK_DIR/probe.sh" <<'PROBE'
set -e
. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh"
clashctl off
clashctl start
[ -z "${http_proxy:-}" ]
clashctl on
clashctl on
[ "$http_proxy" = http://127.0.0.1:7890 ]
[ "$(grep -c '^start$' "$CLASHCTL_HOME/calls")" = 1 ]
[ "$(grep -c '^merge$' "$CLASHCTL_HOME/calls")" = 1 ]
clashctl off
[ -z "${http_proxy:-}" ] && [ -f "$CLASHCTL_HOME/running" ]
clashctl on
clashctl stop
clashctl stop
[ ! -f "$CLASHCTL_HOME/running" ] && [ -n "$http_proxy" ]
[ "$(grep -c '^stop$' "$CLASHCTL_HOME/calls")" = 1 ]
clashctl on
[ "$(grep -c '^start$' "$CLASHCTL_HOME/calls")" = 2 ]
clashctl on -s
[ "$http_proxy" = http://127.0.0.1:7890 ] && [ -f "$CLASHCTL_HOME/running" ]
clashctl off -e
[ -z "${http_proxy:-}" ] && [ -f "$CLASHCTL_HOME/running" ]
clashctl on --env-only
[ "$http_proxy" = http://127.0.0.1:7890 ] && [ -f "$CLASHCTL_HOME/running" ]
clashctl off --service-only
[ "$http_proxy" = http://127.0.0.1:7890 ] && [ ! -f "$CLASHCTL_HOME/running" ]
if clashctl on -e; then exit 1; fi
[ "$http_proxy" = http://127.0.0.1:7890 ]
clashctl on --service-only
[ "$http_proxy" = http://127.0.0.1:7890 ] && [ -f "$CLASHCTL_HOME/running" ]
clashctl off -s
[ "$http_proxy" = http://127.0.0.1:7890 ] && [ ! -f "$CLASHCTL_HOME/running" ]
clashctl on -s
[ "$http_proxy" = http://127.0.0.1:7890 ] && [ -f "$CLASHCTL_HOME/running" ]
clashctl off --env-only
[ -z "${http_proxy:-}" ] && [ -f "$CLASHCTL_HOME/running" ]
clashctl on
touch "$CLASHCTL_HOME/fail-stop"
if clashctl stop; then exit 1; fi
[ -f "$CLASHCTL_HOME/running" ] && [ -n "$http_proxy" ]
rm "$CLASHCTL_HOME/fail-stop"
touch "$CLASHCTL_HOME/privileged"
clashctl stop
[ ! -f "$CLASHCTL_HOME/running" ] && [ ! -f "$CLASHCTL_HOME/privileged" ]
export http_proxy=http://before
touch "$CLASHCTL_HOME/fail-start"
if clashctl on; then exit 1; fi
[ "$http_proxy" = http://before ]
rm "$CLASHCTL_HOME/fail-start" "$CLASHCTL_HOME/base-ready"
if clashctl on; then exit 1; fi
[ "$http_proxy" = http://before ]
if clashctl off --invalid; then exit 1; fi
[ "$http_proxy" = http://before ]
clashctl off --help
[ "$http_proxy" = http://before ]
rm "$BIN_KERNEL"
clashctl off
[ -z "${http_proxy:-}${HTTP_PROXY:-}${https_proxy:-}${HTTPS_PROXY:-}${all_proxy:-}${ALL_PROXY:-}${no_proxy:-}${NO_PROXY:-}" ]
PROBE
cat >"$WORK_DIR/probe.fish" <<'PROBE'
source "$CLASHCTL_HOME/scripts/cmd/clashctl.fish"
clashctl off; or exit 1
clashctl start; or exit 1
set -q http_proxy; and exit 1
clashctl on; or exit 1
clashctl on; or exit 1
test "$http_proxy" = http://127.0.0.1:7890; or exit 1
test (grep -c '^start$' "$CLASHCTL_HOME/calls") = 1; or exit 1
clashctl off; or exit 1
set -q http_proxy; and exit 1
test -f "$CLASHCTL_HOME/running"; or exit 1
clashctl on; or exit 1
clashctl stop; or exit 1
test -n "$http_proxy"; or exit 1
test ! -f "$CLASHCTL_HOME/running"; or exit 1
clashctl on; or exit 1
test (grep -c '^start$' "$CLASHCTL_HOME/calls") = 2; or exit 1
clashctl on -s; or exit 1
test "$http_proxy" = http://127.0.0.1:7890; or exit 1
test -f "$CLASHCTL_HOME/running"; or exit 1
clashctl off -e; or exit 1
set -q http_proxy; and exit 1
test -f "$CLASHCTL_HOME/running"; or exit 1
clashctl on --env-only; or exit 1
test "$http_proxy" = http://127.0.0.1:7890; or exit 1
clashctl off --service-only; or exit 1
test "$http_proxy" = http://127.0.0.1:7890; or exit 1
test ! -f "$CLASHCTL_HOME/running"; or exit 1
clashctl on -e; and exit 1
test "$http_proxy" = http://127.0.0.1:7890; or exit 1
clashctl on --service-only; or exit 1
test "$http_proxy" = http://127.0.0.1:7890; or exit 1
test -f "$CLASHCTL_HOME/running"; or exit 1
clashctl off -s; or exit 1
test "$http_proxy" = http://127.0.0.1:7890; or exit 1
test ! -f "$CLASHCTL_HOME/running"; or exit 1
clashctl on -s; or exit 1
test "$http_proxy" = http://127.0.0.1:7890; or exit 1
test -f "$CLASHCTL_HOME/running"; or exit 1
clashctl off --env-only; or exit 1
set -q http_proxy; and exit 1
test -f "$CLASHCTL_HOME/running"; or exit 1
clashctl on; or exit 1
clashctl off; or exit 1
clashctl stop; or exit 1
set -gx http_proxy http://before
touch "$CLASHCTL_HOME/fail-start"
clashctl on; and exit 1
test "$http_proxy" = http://before; or exit 1
clashctl off --invalid; and exit 1
test "$http_proxy" = http://before; or exit 1
clashctl off --help; or exit 1
test "$http_proxy" = http://before; or exit 1
rm "$CLASHCTL_HOME/bin/mihomo/mihomo" "$CLASHCTL_HOME/base-ready"
clashctl off; or exit 1
for name in http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
    set -q $name; and exit 1
end
exit 0
PROBE
for shell in bash zsh fish; do
    home_dir="$WORK_DIR/$shell"
    mkdir -p "$home_dir/bin/mihomo"
    cp -a "$REPO_DIR/scripts" "$home_dir/"
    cp "$WORK_DIR/services.sh" "$home_dir/scripts/lib/zz-test.sh"
    printf 'CLASHCTL_KERNEL=mihomo\n' >"$home_dir/.env"
    printf '#!/bin/sh\nprintf "7890|||"\n' >"$home_dir/bin/yq"
    printf '#!/bin/sh\nexit 0\n' >"$home_dir/bin/mihomo/mihomo"
    chmod +x "$home_dir/bin/yq" "$home_dir/bin/mihomo/mihomo"
    touch "$home_dir/base-ready"
    probe="$WORK_DIR/probe.sh"
    shell_args=()
    case "$shell" in
    zsh) shell_args=(-f) ;;
    fish) shell_args=(--no-config); probe="$WORK_DIR/probe.fish" ;;
    esac
    CLASHCTL_HOME="$home_dir" XDG_CACHE_HOME="$home_dir/cache" "$shell" "${shell_args[@]}" "$probe" \
        >"$WORK_DIR/output" 2>&1 || { cat "$WORK_DIR/output"; fail "$shell proxy lifecycle failed"; }
done
printf 'proxy-lifecycle: ok\n'
