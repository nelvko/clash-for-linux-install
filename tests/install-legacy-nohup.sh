#!/usr/bin/env bash
# 旧 master 的 nohup 进程无 pid 文件，迁移时只应接管属于旧目录的内核。
set -euo pipefail
REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK_DIR=$(mktemp -d)
old_pid='' restored_pid='' foreign_pid='' altered_pid=''
interrupt_old_pid='' interrupt_restored_pid='' interrupt_launcher_pid='' interrupt_main_pid=''
cleanup() {
    [ -z "$old_pid" ] || kill "$old_pid" 2>/dev/null || true
    [ -z "$restored_pid" ] || kill "$restored_pid" 2>/dev/null || true
    [ -z "$foreign_pid" ] || kill "$foreign_pid" 2>/dev/null || true
    [ -z "$altered_pid" ] || kill "$altered_pid" 2>/dev/null || true
    [ -z "$interrupt_old_pid" ] || kill "$interrupt_old_pid" 2>/dev/null || true
    [ -z "$interrupt_restored_pid" ] || kill "$interrupt_restored_pid" 2>/dev/null || true
    [ -z "$interrupt_main_pid" ] || kill "$interrupt_main_pid" 2>/dev/null || true
    [ -z "$interrupt_launcher_pid" ] || kill "$interrupt_launcher_pid" 2>/dev/null || true
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

# master 从订阅锁内启动 nohup；内核继承 fd 9 后，必须先停内核再取锁。
(
    flock -x 9
    "$legacy/bin/mihomo" 30 &
    printf '%s\n' "$!" >"$WORK_DIR/inherited.pid"
) 9>>"$legacy/resources/profiles.lock"
old_pid=$(cat "$WORK_DIR/inherited.pid")
for ((i=0; i<100; i++)); do
    _service_process_snapshot "$old_pid" "$legacy/bin/mihomo" "$expected" && break
    sleep 0.01
done
_service_process_snapshot "$old_pid" "$legacy/bin/mihomo" "$expected" || fail 'lock-inheriting process did not start'
if flock -n "$legacy/resources/profiles.lock" -c true; then
    fail 'old daemon did not inherit the subscription lock'
fi
legacy_nohup_active=false
_install_legacy_prepare_for_copy "$legacy" legacy-v1 mihomo ||
    fail 'migration could not acquire lock held by old daemon'
! _service_process_identity_matches "$old_pid" "$legacy_nohup_starttime" \
    "$legacy_nohup_argv_hex" "$legacy_nohup_exe_id" || fail 'lock-inheriting old daemon remains active'
_install_legacy_profiles_lock_release || fail 'migration did not release subscription lock'
_install_legacy_service_restore mihomo || fail 'failed migration could not restore old daemon'
restored_pid=$legacy_nohup_pid
flock -n "$legacy/resources/profiles.lock" -c true ||
    fail 'restored daemon retained the subscription lock'
kill "$restored_pid"
wait "$restored_pid" 2>/dev/null || true
restored_pid=''
old_pid=''

# 若另一旧版订阅操作持锁，迁移应有界失败并恢复刚停掉的内核。
"$legacy/bin/mihomo" 30 &
old_pid=$!
for ((i=0; i<100; i++)); do
    _service_process_snapshot "$old_pid" "$legacy/bin/mihomo" "$expected" && break
    sleep 0.01
done
_service_process_snapshot "$old_pid" "$legacy/bin/mihomo" "$expected" || fail 'old process did not restart'
(
    flock -x 9
    : >"$WORK_DIR/writer-locked"
    sleep 4
) 9>>"$legacy/resources/profiles.lock" &
writer_pid=$!
for ((i=0; i<100; i++)); do
    [ ! -e "$WORK_DIR/writer-locked" ] || break
    sleep 0.01
done
[ -e "$WORK_DIR/writer-locked" ] || fail 'old writer did not acquire subscription lock'
legacy_nohup_active=false
if _install_legacy_prepare_for_copy "$legacy" legacy-v1 mihomo >"$WORK_DIR/writer-blocked.out" 2>&1; then
    fail 'migration copied data while old writer held its lock'
fi
[ -z "${legacy_profiles_fd:-}" ] || fail 'failed migration retained subscription lock fd'
restored_pid=$legacy_nohup_pid
_service_process_snapshot "$restored_pid" "$legacy/bin/mihomo" "$expected" ||
    fail 'failed migration did not restore old daemon'
wait "$writer_pid" || fail 'old writer failed'
flock -n "$legacy/resources/profiles.lock" -c true ||
    fail 'failed migration or restored daemon retained subscription lock'
kill "$restored_pid"
wait "$restored_pid" 2>/dev/null || true
restored_pid=''
old_pid=''

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

# 旧内核已经停下、订阅锁已经取得时收到 TERM，必须恢复旧内核并保留旧目录。
interrupt_legacy="$WORK_DIR/interrupt-old"
mkdir -p "$interrupt_legacy/bin" "$interrupt_legacy/resources" \
    "$interrupt_legacy/scripts/lib" "$interrupt_legacy/scripts/cmd"
cp /bin/sleep "$interrupt_legacy/bin/mihomo"
printf 'CLASHCTL_KERNEL=mihomo\n' >"$interrupt_legacy/.env"
printf 'CLASH_CONFIG_BASE="${CLASH_RESOURCES_DIR}/config.yaml"\nCLASH_PROFILES_DIR="${CLASH_RESOURCES_DIR}/profiles"\n' \
    >"$interrupt_legacy/scripts/lib/common.sh"
: >"$interrupt_legacy/resources/config.yaml"
: >"$interrupt_legacy/uninstall.sh"
: >"$interrupt_legacy/scripts/lib/service.sh"
: >"$interrupt_legacy/scripts/cmd/clashctl.sh"
chmod -R go-w "$interrupt_legacy"
cat >"$WORK_DIR/interrupt-install.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
CLASHCTL_INSTALL_RUNNING=1 . "$1"
_install_legacy_nohup_command() {
    legacy_nohup_command=("$1/bin/$2" 30)
    legacy_nohup_log="$1/resources/$2.log"
}
_install_legacy_data() {
    [ "${LOCK_PROBE:-0}" != 1 ] || return 1
    printf '%s\n' "$BASHPID" >"$INTERRUPT_MARKER"
    while :; do sleep 0.05; done
}
printf '%s\n' "$BASHPID" >"$INTERRUPT_WRAPPER_MARKER"
main --local
STUB
"$interrupt_legacy/bin/mihomo" 30 &
interrupt_old_pid=$!
interrupt_expected=$(_service_process_values_argv_hex "$interrupt_legacy/bin/mihomo" 30)
for ((i=0; i<100; i++)); do
    _service_process_snapshot "$interrupt_old_pid" "$interrupt_legacy/bin/mihomo" "$interrupt_expected" && break
    sleep 0.01
done
_service_process_snapshot "$interrupt_old_pid" "$interrupt_legacy/bin/mihomo" "$interrupt_expected" ||
    fail 'interrupt fixture old process did not start'
# 操作锁冲突必须发生在停旧内核之前，不能先停掉再靠清理重启。
(
    operation_lock_acquire || fail 'could not hold migration operation lock'
    if CLASHCTL_HOME="$interrupt_legacy" INIT_TYPE=nohup LOCK_PROBE=1 \
        INTERRUPT_WRAPPER_MARKER="$WORK_DIR/locked-launcher.pid" bash "$WORK_DIR/interrupt-install.sh" \
        "$REPO_DIR/install.sh" >"$WORK_DIR/locked-migration.out" 2>&1; then
        fail 'migration ignored held operation lock'
    fi
    grep -q '另一项 clashctl' "$WORK_DIR/locked-migration.out" || fail 'migration contention was not diagnosed'
    _service_process_snapshot "$interrupt_old_pid" "$interrupt_legacy/bin/mihomo" "$interrupt_expected" ||
        fail 'lock contention stopped or replaced old daemon'
    [ -d "$interrupt_legacy" ] || fail 'lock contention moved old installation'
    [ -z "$(find "$WORK_DIR" -maxdepth 1 \( -name 'interrupt-old.bak.*' -o -name 'interrupt-old.download.*' \) -print -quit)" ] ||
        fail 'lock contention left migration directories'
)
interrupt_marker="$WORK_DIR/interrupt-main.pid"
interrupt_wrapper_marker="$WORK_DIR/interrupt-wrapper.pid"
INTERRUPT_MARKER="$interrupt_marker" INTERRUPT_WRAPPER_MARKER="$interrupt_wrapper_marker" \
    CLASHCTL_HOME="$interrupt_legacy" INIT_TYPE=nohup \
    bash "$WORK_DIR/interrupt-install.sh" "$REPO_DIR/install.sh" >"$WORK_DIR/interrupt.out" 2>&1 &
interrupt_launcher_pid=$!
for ((i=0; i<300; i++)); do
    [ ! -s "$interrupt_marker" ] || break
    kill -0 "$interrupt_launcher_pid" 2>/dev/null || break
    sleep 0.05
done
[ -s "$interrupt_marker" ] || {
    cat "$WORK_DIR/interrupt.out" >&2
    fail 'migration did not reach data copy after stopping old daemon'
}
interrupt_main_pid=$(cat "$interrupt_marker")
[[ $interrupt_main_pid =~ ^[0-9]+$ ]] || fail 'migration marker did not contain a PID'
[ "$interrupt_main_pid" != "$(cat "$interrupt_wrapper_marker")" ] ||
    fail 'migration marker identified the launcher instead of main subshell'
! _service_process_snapshot "$interrupt_old_pid" "$interrupt_legacy/bin/mihomo" "$interrupt_expected" ||
    fail 'migration entered data copy while old daemon was still active'
wait "$interrupt_old_pid" 2>/dev/null || true
interrupt_old_pid=''
kill -TERM "$interrupt_main_pid" || fail 'could not interrupt migration'
if wait "$interrupt_launcher_pid"; then
    fail 'interrupted migration unexpectedly succeeded'
fi
interrupt_launcher_pid=''
interrupt_main_pid=''
[ -d "$interrupt_legacy" ] || fail 'interrupt removed old installation directory'
legacy_nohup_command=("$interrupt_legacy/bin/mihomo" 30)
for ((i=0; i<100; i++)); do
    _install_legacy_nohup_find "$interrupt_expected" || fail 'restored old daemon could not be identified'
    [ "$legacy_nohup_found" != true ] || break
    sleep 0.01
done
[ "$legacy_nohup_found" = true ] || fail 'TERM during migration did not restore old daemon'
interrupt_restored_pid=$legacy_nohup_pid
_service_process_snapshot "$interrupt_restored_pid" "$interrupt_legacy/bin/mihomo" "$interrupt_expected" ||
    fail 'TERM restored a process other than the old daemon'
flock -n "$interrupt_legacy/resources/profiles.lock" -c true ||
    fail 'interrupted migration retained the old subscription lock'
