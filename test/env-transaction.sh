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

export CLASHCTL_SRC=$REPO_DIR CLASHCTL_KERNEL=mihomo INIT_TYPE=nohup
# shellcheck source=../scripts/preflight.sh
. "$REPO_DIR/scripts/preflight.sh"

CLASHCTL_SRC="$WORK_DIR/source"
mkdir -p -- "$CLASHCTL_SRC"
_update_source_rev() { printf 'test-rev\n'; }

for fail_at in 1 2 3; do
    env_calls=0
    _set_env() {
        env_calls=$((env_calls + 1))
        [ "$env_calls" -ne "$fail_at" ]
    }
    rc=0
    _set_envs || rc=$?
    [ "$rc" -eq 1 ] || fail "write failure $fail_at was swallowed"
    [ "$env_calls" -eq "$fail_at" ] ||
        fail "write failure $fail_at did not stop immediately (calls=$env_calls)"
done

printf 'env-transaction: ok\n'
