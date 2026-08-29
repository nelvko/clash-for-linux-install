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

assert_contains() {
    local file=$1 expected=$2 description=$3
    grep -Fqs -- "$expected" "$file" || fail "$description: missing [$expected]"
}

assert_not_contains() {
    local file=$1 unexpected=$2 description=$3
    if grep -Fqs -- "$unexpected" "$file"; then
        fail "$description: unexpectedly found [$unexpected]"
    fi
}

export CLASHCTL_UNINSTALL_SOURCE_ONLY=1 CLASHCTL_COLOR=never CLASHCTL_KERNEL=mihomo
# shellcheck source=../uninstall.sh
. "$REPO_DIR/uninstall.sh"

CRON_MODE=absent
CRON_WRITTEN="$WORK_DIR/written"
CRON_SIGNAL_READY="$WORK_DIR/cron-signal-ready"

command() {
    if [ "${1:-}" = -v ] && [ "${2:-}" = crontab ] && [ "$CRON_MODE" = unavailable ]; then
        return 1
    fi
    builtin command "$@"
}

crontab() {
    if [ "${1:-}" = -l ]; then
        case $CRON_MODE in
        unreadable) printf '%s\n' 'permission denied' >&2; return 1 ;;
        no-table) printf '%s\n' 'no crontab for testuser' >&2; return 1 ;;
        signal)
            printf '%s\n' "$BASHPID" >"$CRON_SIGNAL_READY"
            while :; do sleep 0.1; done
            ;;
        absent) printf '%s\n' '15 4 * * * echo keep' ;;
        removed | failed)
            printf '%s\n' \
                '15 4 * * * echo keep' \
                "0 3 * * * clashctl sub update $CLASHCTL_CRON_TAG"
            ;;
        esac
        return 0
    fi
    [ "$CRON_MODE" != failed ] || return 1
    /bin/cp -- "$1" "$CRON_WRITTEN"
}

run_case() {
    local mode=$1 expected_state=$2 expected_rc=$3 rc=0
    CRON_MODE=$mode
    _UNINSTALL_CRON_STATE=unknown
    _uninstall_legacy_cron || rc=$?
    assert_eq "$expected_rc" "$rc" "$mode cleanup result"
    assert_eq "$expected_state" "$_UNINSTALL_CRON_STATE" "$mode cleanup state"
}

run_case unavailable unavailable 0
run_case unreadable unreadable 0
run_case no-table absent 0
run_case absent absent 0
run_case removed removed 0
assert_contains "$CRON_WRITTEN" 'echo keep' 'cron cleanup preserves unrelated entries'
assert_not_contains "$CRON_WRITTEN" "$CLASHCTL_CRON_TAG" 'cron cleanup removes managed entries'
run_case failed failed 1

cron_tmp="$WORK_DIR/cron-tmp"
mkdir -p -- "$cron_tmp"
export TMPDIR=$cron_tmp
CRON_MODE=signal
signal_rc=0
_uninstall_legacy_cron_worker >"$WORK_DIR/signal.state" 2>"$WORK_DIR/signal.stderr" &
worker_pid=$!
for _ in {1..50}; do
    [ -s "$CRON_SIGNAL_READY" ] && break
    sleep 0.02
done
[ -s "$CRON_SIGNAL_READY" ] || fail 'cron worker did not reach the interrupt point'
kill -TERM "$worker_pid"
wait "$worker_pid" || signal_rc=$?
assert_eq 143 "$signal_rc" 'cron worker preserves TERM status'
[ -z "$(find "$cron_tmp" -mindepth 1 -print -quit)" ] ||
    fail 'cron worker retained sensitive temporary files after TERM'
unset TMPDIR

printf 'uninstall-cron: ok\n'
