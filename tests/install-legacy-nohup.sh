#!/usr/bin/env bash
# 旧 master 的 nohup 进程无 pid 文件，迁移时只应接管属于旧目录的内核。
set -euo pipefail
REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK_DIR=$(mktemp -d)
old_pid='' restored_pid='' foreign_pid='' altered_pid=''
cleanup() {
    [ -z "$old_pid" ] || kill "$old_pid" 2>/dev/null || true
    [ -z "$restored_pid" ] || kill "$restored_pid" 2>/dev/null || true
    [ -z "$foreign_pid" ] || kill "$foreign_pid" 2>/dev/null || true
    [ -z "$altered_pid" ] || kill "$altered_pid" 2>/dev/null || true
    wait 2>/dev/null || true
    rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

CLASHCTL_INSTALL_RUNNING=1 . "$REPO_DIR/install.sh"
. "$REPO_DIR/scripts/lib/service-process.sh"
. "$REPO_DIR/scripts/lib/operation-lock.sh"
detect_service_manager() { service_manager=nohup; }
legacy="$WORK_DIR/old"
mkdir -p "$legacy/bin" "$legacy/resources"
cp /bin/sleep "$legacy/bin/mihomo"
existing_kind=legacy-v1
_install_legacy_nohup_command "$legacy" mihomo
[ "${legacy_nohup_command[*]}" = "$legacy/bin/mihomo -d $legacy/resources -f $legacy/resources/runtime.yaml" ] ||
    fail 'master nohup command does not match its runtime layout'
existing_kind=legacy-v2
_install_legacy_nohup_command "$legacy" mihomo
[ "${legacy_nohup_command[*]}" = "$legacy/bin/mihomo -d $legacy/resources -f $legacy/data/runtime.yaml" ] ||
    fail 'legacy v2 nohup command does not match its runtime layout'
existing_kind=legacy-v1
_install_legacy_nohup_command() {
    legacy_nohup_command=("$1/bin/$2" 30)
    legacy_nohup_log="$1/resources/$2.log"
}
legacy_nohup_active=false
legacy_nohup_found=false
legacy_nohup_pid=''
legacy_nohup_starttime=''
legacy_nohup_argv_hex=''
legacy_nohup_exe_id=''
legacy_nohup_log=''
declare -a legacy_nohup_command=()
expected=$(_service_process_values_argv_hex "$legacy/bin/mihomo" 30)

"$legacy/bin/mihomo" 30 &
old_pid=$!
for ((i=0; i<100; i++)); do
    _service_process_snapshot "$old_pid" "$legacy/bin/mihomo" "$expected" && break
    sleep 0.01
done
_service_process_snapshot "$old_pid" "$legacy/bin/mihomo" "$expected" || fail 'old process did not start'
stopped_pid=$old_pid
_install_legacy_service_prepare "$legacy" mihomo || fail 'old nohup process was not stopped'
[ "$legacy_nohup_active" = true ] || fail 'old nohup process was not recorded'
! _service_process_identity_matches "$old_pid" "$legacy_nohup_starttime" \
    "$legacy_nohup_argv_hex" "$legacy_nohup_exe_id" || fail 'old nohup process is still active'
wait "$old_pid" 2>/dev/null || true
old_pid=''

_install_legacy_profiles_lock_acquire "$legacy" legacy-v1 || fail 'legacy profile lock was not acquired'
operation_lock_acquire || fail 'operation lock was not acquired'
_install_legacy_service_restore mihomo || fail 'old nohup process was not restored'
restored_pid=$legacy_nohup_pid
[ "$restored_pid" != "$stopped_pid" ] || fail 'restored process reused old pid'
_service_process_snapshot "$restored_pid" "$legacy/bin/mihomo" "$expected" ||
    fail 'restored process is not the old binary'
_install_legacy_service_restore mihomo || fail 'second restore failed'
[ "$legacy_nohup_pid" = "$restored_pid" ] || fail 'second restore started a duplicate'
_install_legacy_profiles_lock_release || fail 'legacy profile lock was not released'
flock -n "$legacy/resources/profiles.lock" -c true ||
    fail 'restored old process retained the legacy profile lock'
operation_lock_close_fd || fail 'operation lock was not released'
bash -c '. "$1"; operation_lock_acquire' _ "$REPO_DIR/scripts/lib/operation-lock.sh" ||
    fail 'restored old process retained the operation lock'
kill "$restored_pid"
wait "$restored_pid" 2>/dev/null || true
restored_pid=''

# 命令行相同但可执行文件不同：不能仅凭 argv 终止无关进程。
bash -c 'exec -a "$1" /bin/sleep 30' _ "$legacy/bin/mihomo" &
foreign_pid=$!
for ((i=0; i<100; i++)); do
    [ "$(_service_process_argv_hex "$foreign_pid" 2>/dev/null || true)" = "$expected" ] && break
    sleep 0.01
done
[ "$(_service_process_argv_hex "$foreign_pid")" = "$expected" ] || fail 'foreign process did not start'
legacy_nohup_active=false
if _install_legacy_service_prepare "$legacy" mihomo >"$WORK_DIR/foreign.out" 2>&1; then
    fail 'foreign process was accepted as old nohup process'
fi
kill -0 "$foreign_pid" 2>/dev/null || fail 'foreign process was stopped'
kill "$foreign_pid"
wait "$foreign_pid" 2>/dev/null || true
foreign_pid=''

# 可执行文件来自旧目录，但参数已被用户改变：不能忽略它继续迁移。
"$legacy/bin/mihomo" 29 &
altered_pid=$!
altered=$(_service_process_values_argv_hex "$legacy/bin/mihomo" 29)
for ((i=0; i<100; i++)); do
    [ "$(_service_process_argv_hex "$altered_pid" 2>/dev/null || true)" = "$altered" ] && break
    sleep 0.01
done
[ "$(_service_process_argv_hex "$altered_pid")" = "$altered" ] || fail 'altered process did not start'
if _install_legacy_service_prepare "$legacy" mihomo >"$WORK_DIR/altered.out" 2>&1; then
    fail 'altered old process was ignored'
fi
kill -0 "$altered_pid" 2>/dev/null || fail 'altered old process was stopped'
