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

assert_contains() {
    local file=$1 expected=$2 description=$3
    grep -Fqs -- "$expected" "$file" || fail "$description: missing [$expected]"
}

fake_home="$WORK_DIR/fake-install"
mkdir -p -- "$fake_home"
cp -a -- "$REPO_DIR/install.sh" "$REPO_DIR/uninstall.sh" "$REPO_DIR/scripts" "$fake_home/"
: >"$fake_home/.env"
sentinel="$WORK_DIR/preflight-was-sourced"
# shellcheck disable=SC2016  # The copied script must expand SENTINEL, not this test.
printf '\nprintf "loaded\\n" >"$SENTINEL"\n' >>"$fake_home/scripts/preflight.sh"

stderr="$WORK_DIR/missing-marker.stderr"
rc=0
SENTINEL=$sentinel bash "$fake_home/uninstall.sh" --yes \
    >"$WORK_DIR/missing-marker.stdout" 2>"$stderr" || rc=$?
[ "$rc" -eq 1 ] || fail "missing marker: expected rc 1, got $rc"
[ ! -e "$sentinel" ] || fail 'untrusted preflight was sourced before marker validation'
assert_contains "$stderr" '缺少有效安装标记' 'missing marker is explained'

{
    printf 'CLASHCTL_INSTALLATION=clashctl\n'
    printf 'CLASHCTL_INSTALLATION_FORMAT=1\n'
    printf 'CLASHCTL_INSTALLATION_HOME=%s\n' "$WORK_DIR/other"
    printf 'CLASHCTL_INSTALLATION_UID=%s\n' "$(id -u)"
} >"$fake_home/.clashctl-installation"
chmod 0600 "$fake_home/.clashctl-installation"

stderr="$WORK_DIR/mismatched-marker.stderr"
rc=0
SENTINEL=$sentinel bash "$fake_home/uninstall.sh" --yes \
    >"$WORK_DIR/mismatched-marker.stdout" 2>"$stderr" || rc=$?
[ "$rc" -eq 1 ] || fail "mismatched marker: expected rc 1, got $rc"
[ ! -e "$sentinel" ] || fail 'preflight was sourced after a mismatched marker'
assert_contains "$stderr" '安装身份标记无效' 'mismatched marker is explained'

printf 'uninstall-gate: ok\n'
