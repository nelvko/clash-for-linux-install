#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_DIR=$(cd -- "$TEST_DIR/.." && pwd -P)

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_probe() {
    local manager=$1 expected_state=$2 expected_rc=$3 description=$4 state='' rc=0
    state=$(_install_service_active_state "$manager" mihomo) || rc=$?
    [ "$rc" = "$expected_rc" ] ||
        fail "$description rc: expected [$expected_rc], got [$rc]"
    [ "$state" = "$expected_state" ] ||
        fail "$description state: expected [$expected_state], got [$state]"
}

export CLASHCTL_INSTALL_SOURCE_ONLY=1
# shellcheck source=../install.sh
. "$REPO_DIR/install.sh"
# shellcheck source=../scripts/lib/install-transaction.sh
. "$REPO_DIR/scripts/lib/install-transaction.sh"

SYSTEMD_STATE=active
SYSTEMD_RC=0
systemctl() {
    printf '%s\n' "$SYSTEMD_STATE"
    return "$SYSTEMD_RC"
}

for SYSTEMD_STATE in active reloading; do
    assert_probe systemd active 0 "systemd $SYSTEMD_STATE"
done
for SYSTEMD_STATE in inactive failed; do
    assert_probe systemd inactive 0 "systemd $SYSTEMD_STATE"
done
for SYSTEMD_STATE in activating deactivating maintenance unknown ''; do
    assert_probe systemd '' 1 "systemd unstable $SYSTEMD_STATE"
done
SYSTEMD_STATE=active
SYSTEMD_RC=1
assert_probe systemd '' 1 'systemd query failure'

OPENRC_RC=0
rc-service() {
    return "$OPENRC_RC"
}
assert_probe openrc active 0 'openrc rc=0'
for OPENRC_RC in 3 16; do
    assert_probe openrc inactive 0 "openrc rc=$OPENRC_RC"
done
for OPENRC_RC in 1 4 8 32; do
    assert_probe openrc '' 1 "openrc unstable rc=$OPENRC_RC"
done

SYSV_RC=0
service() {
    return "$SYSV_RC"
}
assert_probe sysvinit active 0 'sysv active'
for SYSV_RC in 1 2 3; do
    assert_probe sysvinit inactive 0 "sysv inactive rc=$SYSV_RC"
done
SYSV_RC=4
assert_probe sysvinit '' 1 'sysv unknown'

RUNIT_OUTPUT='run: mihomo: (pid 1) 10s'
RUNIT_RC=0
sv() {
    printf '%s\n' "$RUNIT_OUTPUT"
    return "$RUNIT_RC"
}
assert_probe runit active 0 'runit active'
RUNIT_OUTPUT='down: mihomo: 10s, normally up'
assert_probe runit inactive 0 'runit inactive'
RUNIT_OUTPUT='fail: mihomo: unable to change to service directory'
assert_probe runit '' 1 'runit unavailable'
RUNIT_OUTPUT='run: mihomo: (pid 1) 10s'
RUNIT_RC=1
assert_probe runit '' 1 'runit query failure'

printf 'install-service-state: ok\n'
