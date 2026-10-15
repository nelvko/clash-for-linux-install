#!/usr/bin/env bash
# Only verified old-install jobs are paused; running old commands drain naturally.
set -euo pipefail
REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK_DIR=$(mktemp -d)
child_pid=''
cleanup() {
    [ -z "$child_pid" ] || kill "$child_pid" 2>/dev/null || true
    wait 2>/dev/null || true
    _install_maintenance_restore || true
    _install_maintenance_cleanup || true
    rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
# shellcheck source=../scripts/lib/install-maintenance.sh
. "$REPO_DIR/scripts/lib/install-maintenance.sh"

legacy="$WORK_DIR/old"
destination="$WORK_DIR/new installation"
cron_file="$WORK_DIR/crontab"
mkdir -p "$legacy/scripts/cmd" "$destination/scripts/cmd"
crontab() {
    [ "${CRON_WRITE_FAIL:-0}" = 0 ] || [ "${1:-}" = -l ] || return 1
    if [ "${1:-}" = -l ]; then
        [ ! -f "$cron_file" ] || cat "$cron_file"
    else
        cp -- "$1" "$cron_file"
    fi
}
assert_line() { grep -Fqx -- "$1" "$cron_file" || fail "missing cron line: $1"; }
assert_no_line() { ! grep -Fqx -- "$1" "$cron_file" || fail "unexpected cron line: $1"; }

# Safe before begin, and repeated sourcing cannot discard active recovery state.
_install_maintenance_restore
_install_maintenance_cleanup
cat >"$cron_file" <<EOF
MAILTO=keep@example.invalid
* * * * * /usr/bin/printf unrelated
0 0 */2 * * /bin/bash -i -c 'clashsub update'
0 0 */2 * * $legacy/scripts/cmd/clashctl.sh sub update # clashctl-auto-update
0 0 */2 * * $legacy-other/scripts/cmd/clashctl.sh sub update # clashctl-auto-update
0 0 */2 * * /bin/bash -c 'clashsub update'
* * * * * /bin/bash -c 'echo $legacy; echo clashctl sub update'
EOF
cp -- "$cron_file" "$WORK_DIR/original"
_install_maintenance_begin "$legacy" 0 || fail 'maintenance begin failed'
assert_no_line "0 0 */2 * * /bin/bash -i -c 'clashsub update'"
assert_no_line "0 0 */2 * * $legacy/scripts/cmd/clashctl.sh sub update # clashctl-auto-update"
assert_line "0 0 */2 * * $legacy-other/scripts/cmd/clashctl.sh sub update # clashctl-auto-update"
assert_line "0 0 */2 * * /bin/bash -c 'clashsub update'"
assert_line "* * * * * /bin/bash -c 'echo $legacy; echo clashctl sub update'"
# shellcheck source=../scripts/lib/install-maintenance.sh
. "$REPO_DIR/scripts/lib/install-maintenance.sh"
[ "$_INSTALL_MAINTENANCE_ACTIVE" = true ] || fail 'sourcing helper lost maintenance state'
_install_maintenance_restore || fail 'maintenance restore failed'
cmp -s -- "$cron_file" "$WORK_DIR/original" || fail 'unchanged crontab was not restored exactly'
_install_maintenance_cleanup

# Unrelated edits made during migration survive; moved jobs use the new home.
_install_maintenance_begin "$legacy" 0
printf '* * * * * /usr/bin/printf added-during-migration\n' >>"$cron_file"
_install_maintenance_finish "$destination"
assert_line '* * * * * /usr/bin/printf added-during-migration'
assert_line "0 0 */2 * * /bin/bash -i -c 'clashsub update'"
assert_no_line "0 0 */2 * * $legacy/scripts/cmd/clashctl.sh sub update # clashctl-auto-update"
cat >"$destination/scripts/cmd/clashctl.sh" <<'EOF'
clashsub() { [ "$1" = update ] && printf '%s\n' "$CLASHCTL_HOME" >"$MAINTENANCE_TEST_MARKER"; }
EOF
line=$(grep '# clashctl-auto-update$' "$cron_file" | grep 'CLASHCTL_HOME=')
read -r _ _ _ _ _ command <<<"$line"
MAINTENANCE_TEST_MARKER="$WORK_DIR/new-updater-ran" sh -c "$command" || fail 'canonical moved cron command failed'
[ "$(cat "$WORK_DIR/new-updater-ran")" = "$destination" ] || fail 'moved cron did not dispatch subscription update'
_install_maintenance_restore
_install_maintenance_cleanup

# Pausing can fail before crontab changes; rollback still keeps the exact original.
cp -- "$WORK_DIR/original" "$cron_file"
CRON_WRITE_FAIL=1
if _install_maintenance_begin "$legacy" 0; then fail 'failed cron pause was accepted'; fi
cmp -s -- "$cron_file" "$WORK_DIR/original" || fail 'failed pause modified original cron'
CRON_WRITE_FAIL=0
_install_maintenance_restore
cmp -s -- "$cron_file" "$WORK_DIR/original" || fail 'failed pause recovery changed original cron'
_install_maintenance_cleanup

# A failed crontab write keeps recovery state and its exact saved entries.
cp -- "$WORK_DIR/original" "$cron_file"
_install_maintenance_begin "$legacy" 0
CRON_WRITE_FAIL=1
if _install_maintenance_restore 2>"$WORK_DIR/restore-error"; then
    fail 'failed crontab write was accepted'
fi
if _install_maintenance_cleanup; then fail 'cleanup discarded active cron recovery'; fi
[ -f "$_INSTALL_MAINTENANCE_WORK/original" ] || fail 'cron recovery snapshot was deleted'
CRON_WRITE_FAIL=0
_install_maintenance_restore
cmp -s -- "$cron_file" "$WORK_DIR/original" || fail 'retry did not restore exact cron records'
_install_maintenance_cleanup

# Recognize executable symlinks, never another installation with a common prefix.
: >"$legacy/scripts/cmd/clashctl.sh"
ln -s "$legacy/scripts/cmd/clashctl.sh" "$WORK_DIR/clashctl"
printf '0 0 */2 * * %s sub update # clashctl-auto-update\n' "$WORK_DIR/clashctl" >"$cron_file"
_install_maintenance_begin "$legacy" 0
[ ! -s "$cron_file" ] || fail 'old executable symlink cron was not paused'
_install_maintenance_restore
_install_maintenance_cleanup
# Same-home upgrades must also stop depending on a removed old executable wrapper.
cp -- "$destination/scripts/cmd/clashctl.sh" "$legacy/scripts/cmd/clashctl.sh"
_install_maintenance_begin "$legacy" 0
_install_maintenance_finish "$legacy"
line=$(cat "$cron_file")
read -r _ _ _ _ _ command <<<"$line"
MAINTENANCE_TEST_MARKER="$WORK_DIR/same-home-updater-ran" sh -c "$command" || fail 'same-home canonical cron failed'
[ "$(cat "$WORK_DIR/same-home-updater-ran")" = "$legacy" ] || fail 'same-home cron kept old executable wrapper'
_install_maintenance_cleanup
# Reset the historical external symlink entry before testing a moved installation.
printf '0 0 */2 * * %s sub update # clashctl-auto-update\n' "$WORK_DIR/clashctl" >"$cron_file"
_install_maintenance_begin "$legacy" 0
_install_maintenance_finish "$destination"
line=$(cat "$cron_file")
read -r _ _ _ _ _ command <<<"$line"
rm -f -- "$WORK_DIR/new-updater-ran"
MAINTENANCE_TEST_MARKER="$WORK_DIR/new-updater-ran" sh -c "$command" || fail 'moved symlink cron command failed'
[ -f "$WORK_DIR/new-updater-ran" ] || fail 'moved symlink cron did not dispatch update'
_install_maintenance_cleanup

# Cron variable assignments retain their scope when successful finish rewrites a job.
printf 'MAINTENANCE_SCOPE=before\n0 0 */2 * * %s sub update # clashctl-auto-update\nMAINTENANCE_SCOPE=after\n' \
    "$WORK_DIR/clashctl" >"$cron_file"
_install_maintenance_begin "$legacy" 0
_install_maintenance_finish "$legacy"
IFS= read -r first_line <"$cron_file"
[ "$first_line" = MAINTENANCE_SCOPE=before ] || fail 'finish moved cron assignment before job'
[ "$(tail -1 "$cron_file")" = MAINTENANCE_SCOPE=after ] || fail 'finish changed cron assignment scope'
[ "$(wc -l <"$cron_file")" -eq 3 ] || fail 'finish duplicated scoped cron job'
_install_maintenance_cleanup

# No cron entries and no crontab command are ordinary no-op cases.
: >"$cron_file"
_install_maintenance_begin "$legacy" 0
_install_maintenance_finish "$legacy"
_install_maintenance_cleanup
(
    unset -f crontab
    # shellcheck disable=SC2317  # 间接替换 command -v 的依赖探测。
    command() { [ "${1:-}:${2:-}" != '-v:crontab' ] && builtin command "$@"; }
    _install_maintenance_begin "$legacy" 0
    _install_maintenance_restore
    _install_maintenance_cleanup
)

# Real old script invocations are waited on; relative scripts use their cwd.
: >"$cron_file"
cat >"$legacy/install.sh" <<'EOF'
#!/usr/bin/env bash
: >"$1"
sleep 1
EOF
bash "$legacy/install.sh" "$WORK_DIR/old-operation.ready" &
child_pid=$!
for ((attempt=0; attempt<100; attempt++)); do
    [ ! -e "$WORK_DIR/old-operation.ready" ] || break
    sleep 0.01
done
if _install_maintenance_begin "$legacy" 0 2>"$WORK_DIR/busy"; then
    fail 'running old install command was ignored'
fi
kill -0 "$child_pid" || fail 'maintenance killed an old command'
_install_maintenance_begin "$legacy" 5 || fail 'maintenance did not wait for old command completion'
wait "$child_pid"
child_pid=''
_install_maintenance_cleanup
(
    cd "$legacy"
    exec bash ./install.sh "$WORK_DIR/relative.ready"
) &
child_pid=$!
for ((attempt=0; attempt<100; attempt++)); do
    [ ! -e "$WORK_DIR/relative.ready" ] || break
    sleep 0.01
done
if _install_maintenance_begin "$legacy" 0 2>"$WORK_DIR/busy"; then
    fail 'relative old install command was ignored'
fi
wait "$child_pid"
child_pid=''
_install_maintenance_cleanup

# Arbitrary bash source containing path/command references is not an updater.
bash -c ': "$1" "clashctl sub update"; : >"$2"; sleep 1' _ "$legacy" "$WORK_DIR/unrelated.ready" &
child_pid=$!
for ((attempt=0; attempt<100; attempt++)); do
    [ ! -e "$WORK_DIR/unrelated.ready" ] || break
    sleep 0.01
done
_install_maintenance_begin "$legacy" 0 || fail 'unrelated shell was treated as an old operation'
kill -0 "$child_pid" || fail 'maintenance modified an unrelated shell'
wait "$child_pid"
child_pid=''
_install_maintenance_cleanup

printf 'install-maintenance: ok\n'
