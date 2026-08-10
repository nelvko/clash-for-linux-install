#!/usr/bin/env bash
set -u
REPO=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
export CLASHCTL_HOME=$REPO
export CLASH_CONFIG_RUNTIME=$REPO/resources/runtime.yaml
_errorcat() { printf '%s\n' "$*" >&2; return 1; }
_okcat() { printf '%s\n' "$*"; return 0; }
. "$REPO/scripts/cmd/traffic.sh"

fail=0
original_override=${CLASHCTL_TRAFFIC_PYTHON-}
CLASHCTL_TRAFFIC_PYTHON=$(command -v bash)
if [ "$(traffic_python)" != "$CLASHCTL_TRAFFIC_PYTHON" ]; then
  printf '%s\n' 'FAIL: traffic_python did not honor CLASHCTL_TRAFFIC_PYTHON' >&2
  fail=1
fi
CLASHCTL_TRAFFIC_PYTHON=/definitely/missing/python
if traffic_python >/dev/null 2>&1; then
  printf '%s\n' 'FAIL: traffic_python accepted a missing override' >&2
  fail=1
fi
CLASHCTL_TRAFFIC_PYTHON=$original_override
unset original_override

expect_invalid() {
  local expected=$1
  shift
  local output rc
  output=$(traffic_start "$@" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ] || ! grep -Fq "$expected" <<<"$output"; then
    printf 'FAIL: traffic_start %s\noutput: %s\n' "$*" "$output" >&2
    fail=1
  fi
}

expect_invalid '端口必须是 1024-65535' --port nope
expect_invalid '端口必须是 1024-65535' --port 70000
expect_invalid '采样间隔必须是大于等于 1 的数字' --interval 0
expect_invalid '采样间隔必须是大于等于 1 的数字' --interval nope

if [ "$fail" -ne 0 ]; then
  exit 1
fi
printf '%s\n' 'shell validation tests passed'
