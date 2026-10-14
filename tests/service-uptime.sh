#!/usr/bin/env bash
# 查询替身由 service_uptime 间接调用。
# shellcheck disable=SC2317
set -euo pipefail

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK_DIR=$(mktemp -d)
CHILD_PID=''
KEEPER_PID=''
KEEPER_RELEASE="$WORK_DIR/keeper-release"
cleanup() {
    if [ -n "$CHILD_PID" ]; then
        kill "$CHILD_PID" 2>/dev/null || true
        wait "$CHILD_PID" 2>/dev/null || true
    fi
    if [ -n "$KEEPER_PID" ]; then
        : >"$KEEPER_RELEASE"
        wait "$KEEPER_PID" 2>/dev/null || true
    fi
    command rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
# shellcheck source=../scripts/lib/service.sh
. "$REPO_DIR/scripts/lib/service.sh"

assert_elapsed() {
    local expected=$1 label=$2 pid=${3:-42} result rc=0
    rm -f "$WORK_DIR/read-once"
    result=$(service_uptime "$pid" 2>/dev/null) || rc=$?
    if [ "$expected" = error ]; then
        [ "$rc" -ne 0 ] || fail "$label: expected failure, got $rc/$result"
        [ -z "$result" ] || fail "$label: failure printed $result"
    else
        [ "$rc" -eq 0 ] || fail "$label: query failed with $rc"
        [ "$result" = "$expected" ] || fail "$label: expected $expected seconds, got $result"
    fi
}

(
    START_TICKS=9930 END_TICKS=9930 FIRST_RC=0 SECOND_RC=0 CLOCK_RC=0
    CLOCK_UPTIME=100.30 CLOCK_TICKS=100
    _service_uptime_process_ticks() {
        if [ -e "$WORK_DIR/read-once" ]; then
            [ "$SECOND_RC" -eq 0 ] || return 1
            printf '%s\n' "$END_TICKS"
        else
            : >"$WORK_DIR/read-once"
            [ "$FIRST_RC" -eq 0 ] || return 1
            printf '%s\n' "$START_TICKS"
        fi
    }
    _service_uptime_clock() {
        [ "$CLOCK_RC" -eq 0 ] || return 1
        printf '%s %s\n' "$CLOCK_UPTIME" "$CLOCK_TICKS"
    }
    assert_elapsed 1 'exact second'
    CLOCK_UPTIME=100.29 assert_elapsed 0 'just before a full second'
    CLOCK_UPTIME=100.31 assert_elapsed 1 'just after a full second'
    START_TICKS=102301 END_TICKS=102301 CLOCK_UPTIME=1024.01 assert_elapsed 1 'floating point boundary'
    START_TICKS=9009 END_TICKS=9009 CLOCK_UPTIME=10.009 CLOCK_TICKS=1000 assert_elapsed 1 'millisecond tick rate'
    START_TICKS=9009 END_TICKS=9009 CLOCK_UPTIME=10.008999999 CLOCK_TICKS=1000 assert_elapsed 0 'fraction precision boundary'
    START_TICKS=00100 END_TICKS=00100 CLOCK_UPTIME=00010.00 CLOCK_TICKS=00100 assert_elapsed 9 'decimal leading zeroes'
    START_TICKS=0 END_TICKS=0 CLOCK_UPTIME=86401 assert_elapsed 86401 'whole uptime and long duration'
    CLOCK_UPTIME=99.29 assert_elapsed error 'clock precedes process start'
    CLOCK_UPTIME=bad assert_elapsed error 'malformed uptime'
    CLOCK_UPTIME=100. assert_elapsed error 'empty fractional uptime'
    CLOCK_UPTIME=.3 assert_elapsed error 'empty whole uptime'
    CLOCK_UPTIME=1.2.3 assert_elapsed error 'multiple decimal points'
    CLOCK_UPTIME=100.3000000000 assert_elapsed error 'excessive decimal precision'
    CLOCK_UPTIME=-100.30 assert_elapsed error 'negative clock'
    CLOCK_TICKS=0 assert_elapsed error 'zero tick rate'
    CLOCK_TICKS=oops assert_elapsed error 'malformed tick rate'
    CLOCK_TICKS=1000000000 assert_elapsed error 'overflowing tick rate'
    CLOCK_RC=1 assert_elapsed error 'unreadable clock or missing getconf'
    START_TICKS='' assert_elapsed error 'missing process start'
    START_TICKS=bad assert_elapsed error 'malformed process start'
    START_TICKS=9999999999999999999 assert_elapsed error 'overflowing process start'
    FIRST_RC=1 assert_elapsed error 'unreadable process'
    SECOND_RC=1 assert_elapsed error 'process disappeared before result'
    END_TICKS=9931 assert_elapsed error 'PID reused during query'
    assert_elapsed error 'invalid PID' abc
    assert_elapsed error 'reserved PID' 1
)

# 真进程从启动到查询只有数毫秒；查询既不发信号，也不要求安装 ps/procps。
sleep 30 &
CHILD_PID=$!
elapsed=$(service_uptime "$CHILD_PID") || fail 'live process uptime query failed'
case "$elapsed" in '' | *[!0-9]*) fail 'live uptime is not a nonnegative integer' ;; esac
[ "$elapsed" -le 5 ] || fail 'new process has an unexpectedly long uptime'
kill -0 "$CHILD_PID" || fail 'uptime query changed the process'
(
    getconf() { return 127; }
    assert_elapsed error 'missing native getconf' "$CHILD_PID"
)
(
    getconf() { printf 'invalid\n'; }
    assert_elapsed error 'malformed native getconf' "$CHILD_PID"
)
kill "$CHILD_PID"
wait "$CHILD_PID" 2>/dev/null || true
assert_elapsed error 'exited process' "$CHILD_PID"
CHILD_PID=''

# 保留真正的僵尸，验证 starttime 尚可读取时也不会返回运行时长。
cat >"$WORK_DIR/keeper.py" <<'PY'
import os
from pathlib import Path
import subprocess
import sys
import time

child = subprocess.Popen(["true"])
Path(sys.argv[1]).write_text(str(child.pid))
while not os.path.exists(sys.argv[2]):
    time.sleep(0.01)
child.wait()
PY
python3 "$WORK_DIR/keeper.py" "$WORK_DIR/zombie-pid" "$KEEPER_RELEASE" &
KEEPER_PID=$!
for ((attempt = 0; attempt < 100; attempt++)); do
    [ ! -s "$WORK_DIR/zombie-pid" ] || break
    sleep 0.01
done
[ -s "$WORK_DIR/zombie-pid" ] || fail 'zombie fixture did not start'
zombie_pid=$(cat "$WORK_DIR/zombie-pid")
for ((attempt = 0; attempt < 100; attempt++)); do
    IFS= read -r zombie_stat <"/proc/$zombie_pid/stat" || fail 'zombie fixture disappeared'
    zombie_stat=${zombie_stat##*) }
    [ "${zombie_stat%% *}" != Z ] || break
    sleep 0.01
done
[ "${zombie_stat%% *}" = Z ] || fail 'fixture did not retain a zombie'
assert_elapsed error 'zombie process' "$zombie_pid"
: >"$KEEPER_RELEASE"
wait "$KEEPER_PID"
KEEPER_PID=''

printf 'service-uptime: ok\n'
