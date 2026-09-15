#!/usr/bin/env bash
set -euo pipefail
REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
export CLASHCTL_HOME="$WORK_DIR/home" CLASHCTL_SRC="$REPO_DIR" CLASHCTL_KERNEL=mihomo INIT_TYPE=systemd
. "$REPO_DIR/scripts/lib/common.sh"
. "$REPO_DIR/scripts/lib/service.sh"
# 所有服务操作都限制在临时目录，不调用宿主 init。
_service_target() { printf '%s/unit.service\n' "$WORK_DIR"; }
systemctl() { :; }
service_enable() { touch "$WORK_DIR/enabled"; }
service_disable() { rm -f "$WORK_DIR/enabled"; }
service_is_active() { [ -f "$WORK_DIR/active" ]; }
service_stop() { rm -f "$WORK_DIR/active"; }
_service_unregister() { :; }

printf 'foreign unit\n' >"$WORK_DIR/unit.service"
if install_service >/dev/null 2>&1; then fail 'installer took over a foreign service'; fi
[ "$(cat "$WORK_DIR/unit.service")" = 'foreign unit' ] || fail 'foreign service changed'
if uninstall_service >/dev/null 2>&1; then fail 'uninstaller removed a foreign service'; fi
rm "$WORK_DIR/unit.service"
install_service || fail 'service installation failed'
grep -Fq "ExecStart=$BIN_KERNEL" "$WORK_DIR/unit.service" || fail 'service executable path is wrong'
[ -f "$WORK_DIR/enabled" ] || fail 'service was not enabled'
touch "$WORK_DIR/active"
uninstall_service || fail 'service uninstall failed'
[ ! -e "$WORK_DIR/active" ] || fail 'service was not stopped'
[ ! -e "$WORK_DIR/enabled" ] || fail 'service was not disabled'
[ ! -e "$WORK_DIR/unit.service" ] || fail 'service definition was not removed'
printf 'service-basic: ok\n'
