#!/usr/bin/env bash
set -euo pipefail

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEST_TMP=$(mktemp -d)
trap '/usr/bin/rm -rf -- "$TEST_TMP"' EXIT

# shellcheck source=scripts/lib/service-enablement.sh
. "$REPO_DIR/scripts/lib/service-enablement.sh"

TEST_CASE=
TEST_SYSTEMD_STATE=disabled
TEST_SYSTEMD_RELOADS=0
TEST_SYSTEMD_RELOAD_FAIL=0

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_eq() {
    local expected=$1 actual=$2 message=$3
    [ "$expected" = "$actual" ] ||
        fail "$message (expected '$expected', got '$actual')"
}

assert_link() {
    local path=$1 target=$2
    [ -L "$path" ] || fail "expected symlink: $path"
    assert_eq "$target" "$(readlink -- "$path")" "wrong symlink target: $path"
}

assert_link_exact() {
    local path=$1 target=$2 expected_hex actual_hex
    [ -L "$path" ] || fail "expected symlink: $path"
    expected_hex=$(_service_enablement_hex_encode "$target")
    actual_hex=$(_service_enablement_readlink_hex "$path")
    assert_eq "$expected_hex" "$actual_hex" "wrong byte-exact symlink target: $path"
}

assert_absent() {
    local path=$1
    if [ -e "$path" ] || [ -L "$path" ]; then
        fail "expected absent path: $path"
    fi
}

assert_fails() {
    "$@" && fail "command unexpectedly succeeded: $*"
    return 0
}

service_enablement_systemd_persistent_root() {
    printf '%s\n' "$TEST_CASE/systemd/etc"
}

service_enablement_systemd_runtime_root() {
    printf '%s\n' "$TEST_CASE/systemd/run"
}

service_enablement_sysv_root() {
    printf '%s\n' "$TEST_CASE/sysv"
}

service_enablement_openrc_root() {
    printf '%s\n' "$TEST_CASE/openrc/runlevels"
}

service_enablement_runit_link() {
    printf '%s/runit/enabled/%s\n' "$TEST_CASE" "$1"
}

service_enablement_systemd_state() {
    printf '%s\n' "$TEST_SYSTEMD_STATE"
}

service_enablement_systemd_reload() {
    TEST_SYSTEMD_RELOADS=$((TEST_SYSTEMD_RELOADS + 1))
    [ "$TEST_SYSTEMD_RELOAD_FAIL" -eq 0 ]
}

service_enablement_systemd_unit_path() {
    printf '%s/systemd/current/%s.service\n' "$TEST_CASE" "$1"
}

service_enablement_sysv_service_path() {
    printf '%s/sysv/init.d/%s\n' "$TEST_CASE" "$1"
}

service_enablement_openrc_service_path() {
    printf '%s/openrc/init.d/%s\n' "$TEST_CASE" "$1"
}

service_enablement_runit_service_path() {
    printf '%s/runit/services/%s\n' "$TEST_CASE" "$1"
}

setup_case() {
    TEST_CASE="$TEST_TMP/$1"
    TEST_SYSTEMD_STATE=disabled
    TEST_SYSTEMD_RELOADS=0
    TEST_SYSTEMD_RELOAD_FAIL=0
    mkdir -p \
        "$TEST_CASE/systemd/etc" \
        "$TEST_CASE/systemd/run" \
        "$TEST_CASE/systemd/current" \
        "$TEST_CASE/sysv/init.d" \
        "$TEST_CASE/openrc/runlevels" \
        "$TEST_CASE/openrc/init.d" \
        "$TEST_CASE/runit/enabled" \
        "$TEST_CASE/runit/services"
    : >"$TEST_CASE/systemd/current/mihomo.service"
    : >"$TEST_CASE/sysv/init.d/mihomo"
    : >"$TEST_CASE/openrc/init.d/mihomo"
    mkdir -p "$TEST_CASE/runit/services/mihomo"
    _service_enablement_before_restore_commit() { return 0; }
}

manifest_state() {
    sed -n 's/^state=//p' "$1"
}

manifest_links() {
    sed -n 's/^links=//p' "$1"
}

write_manifest() {
    local path=$1 manager=$2 service=$3 state=$4 links=$5 service_hex
    service_hex=$(_service_enablement_hex_encode "$service")
    printf '%s\n' \
        'format=clashctl-service-enablement-v1' \
        "manager=$manager" \
        "service=$service_hex" \
        "state=$state" \
        "links=$links" >"$path"
    chmod 0600 "$path"
}

test_systemd_capture_restore_and_idempotence() {
    local original expected inode_before inode_after links first second first_path second_path
    local etc run vendor_direct
    setup_case systemd-roundtrip
    etc=$TEST_CASE/systemd/etc
    run=$TEST_CASE/systemd/run
    original=$TEST_CASE/original.manifest
    expected=$TEST_CASE/expected.manifest
    mkdir -p "$etc/zeta.target.requires" "$run/alpha.target.wants"
    ln -s /vendor/zeta.service "$etc/zeta.target.requires/mihomo.service"
    ln -s ../../vendor/alpha.service "$run/alpha.target.wants/mihomo.service"
    vendor_direct=$etc/mihomo.service
    ln -s /vendor/mihomo.service "$vendor_direct"
    TEST_SYSTEMD_STATE='enabled-runtime'

    service_enablement_capture systemd mihomo "$original" || fail "$SERVICE_ENABLEMENT_ERROR"
    assert_eq enabled-runtime "$(manifest_state "$original")" 'systemd state was not captured'
    links=$(manifest_links "$original")
    service_enablement_validate systemd mihomo "$original" || fail "$SERVICE_ENABLEMENT_ERROR"
    assert_eq enabled-runtime "$SERVICE_ENABLEMENT_STATE" 'validated systemd state was not exported'
    assert_eq "$links" "$SERVICE_ENABLEMENT_LINKS" 'validated systemd links were not exported'
    IFS=, read -r first second <<<"$links"
    first_path=${first%%:*}
    second_path=${second%%:*}
    [[ $first_path < $second_path ]] || fail 'systemd manifest paths are not byte-sorted'
    [[ $links != *"$(_service_enablement_hex_encode "$vendor_direct")"* ]] ||
        fail 'systemd definition link was included in enablement manifest'
    inode_before=$(stat -c %i -- "$original")
    service_enablement_capture systemd mihomo "$original" || fail "$SERVICE_ENABLEMENT_ERROR"
    inode_after=$(stat -c %i -- "$original")
    assert_eq "$inode_before" "$inode_after" 'identical capture rewrote the manifest'

    /usr/bin/rm -f -- \
        "$etc/zeta.target.requires/mihomo.service" \
        "$run/alpha.target.wants/mihomo.service"
    mkdir -p "$etc/multi-user.target.wants" "$run/rescue.target.requires"
    ln -s "$TEST_CASE/systemd/current/mihomo.service" \
        "$etc/multi-user.target.wants/mihomo.service"
    ln -s "$TEST_CASE/systemd/current/mihomo.service" \
        "$run/rescue.target.requires/mihomo.service"
    TEST_SYSTEMD_STATE=enabled
    service_enablement_capture systemd mihomo "$expected" || fail "$SERVICE_ENABLEMENT_ERROR"

    # The original definition has already been restored, so state can be the
    # desired state while links still match the takeover snapshot.
    TEST_SYSTEMD_STATE='enabled-runtime'
    service_enablement_restore systemd mihomo "$original" "$expected" ||
        fail "$SERVICE_ENABLEMENT_ERROR"
    assert_link "$etc/zeta.target.requires/mihomo.service" /vendor/zeta.service
    assert_link "$run/alpha.target.wants/mihomo.service" ../../vendor/alpha.service
    assert_absent "$etc/multi-user.target.wants/mihomo.service"
    assert_absent "$run/rescue.target.requires/mihomo.service"
    assert_link "$vendor_direct" /vendor/mihomo.service
    assert_eq 1 "$TEST_SYSTEMD_RELOADS" 'systemd restore did not reload exactly once'
    service_enablement_reconcile systemd mihomo "$original" || fail "$SERVICE_ENABLEMENT_ERROR"
    service_enablement_restore systemd mihomo "$original" "$expected" ||
        fail "$SERVICE_ENABLEMENT_ERROR"
    assert_eq 1 "$TEST_SYSTEMD_RELOADS" 'idempotent restore reloaded systemd again'
}

test_systemd_states_are_preserved() {
    local state manifest
    setup_case systemd-states
    ln -s /dev/null "$TEST_CASE/systemd/etc/mihomo.service"
    for state in enabled enabled-runtime linked linked-runtime alias masked masked-runtime \
        static indirect generated transient disabled not-found; do
        TEST_SYSTEMD_STATE=$state
        manifest="$TEST_CASE/$state.manifest"
        service_enablement_capture systemd mihomo "$manifest" || fail "$SERVICE_ENABLEMENT_ERROR"
        assert_eq "$state" "$(manifest_state "$manifest")" "lost systemd state $state"
        assert_eq '' "$(manifest_links "$manifest")" \
            'systemd definition path leaked into state links'
    done
    TEST_SYSTEMD_STATE=unexpected
    assert_fails service_enablement_capture systemd mihomo "$TEST_CASE/bad-state.manifest"
}

test_systemd_upholds_roundtrip() {
    local desired expected link current
    setup_case systemd-upholds
    desired=$TEST_CASE/desired.manifest
    expected=$TEST_CASE/expected.manifest
    link=$TEST_CASE/systemd/etc/rescue.target.upholds/mihomo.service
    current=$TEST_CASE/systemd/current/mihomo.service
    TEST_SYSTEMD_STATE=disabled
    service_enablement_capture systemd mihomo "$desired" || fail "$SERVICE_ENABLEMENT_ERROR"
    mkdir -p -- "${link%/*}"
    ln -s -- "$current" "$link"
    TEST_SYSTEMD_STATE=enabled
    service_enablement_capture systemd mihomo "$expected" || fail "$SERVICE_ENABLEMENT_ERROR"
    [[ $(manifest_links "$expected") == *"$(_service_enablement_hex_encode "$link")"* ]] ||
        fail 'systemd .upholds link was not captured'

    TEST_SYSTEMD_STATE=disabled
    service_enablement_restore systemd mihomo "$desired" "$expected" ||
        fail "$SERVICE_ENABLEMENT_ERROR"
    assert_absent "$link"
}

test_systemd_conflicts_and_race() {
    local desired wants admin owned regular
    setup_case systemd-conflicts
    desired=$TEST_CASE/desired.manifest
    wants=$TEST_CASE/systemd/etc/multi-user.target.wants
    mkdir -p "$wants"
    TEST_SYSTEMD_STATE=disabled
    service_enablement_capture systemd mihomo "$desired" || fail "$SERVICE_ENABLEMENT_ERROR"

    admin=$wants/mihomo.service
    ln -s /admin/mihomo.service "$admin"
    assert_fails service_enablement_restore systemd mihomo "$desired"
    assert_link "$admin" /admin/mihomo.service

    /usr/bin/rm -f -- "$admin"
    owned=$TEST_CASE/systemd/current/mihomo.service
    ln -s "$owned" "$admin"
    service_enablement_restore systemd mihomo "$desired" || fail "$SERVICE_ENABLEMENT_ERROR"
    assert_absent "$admin"

    regular=$admin
    printf '%s\n' 'administrator data' >"$regular"
    assert_fails service_enablement_restore systemd mihomo "$desired"
    assert_eq 'administrator data' "$(cat "$regular")" 'ordinary file was modified'
    /usr/bin/rm -f -- "$regular"

    ln -s "$owned" "$admin"
    _service_enablement_before_restore_commit() {
        # shellcheck disable=SC2317
        /usr/bin/rm -f -- "$admin"
        # shellcheck disable=SC2317
        ln -s /admin/raced.service "$admin"
    }
    assert_fails service_enablement_restore systemd mihomo "$desired"
    assert_link "$admin" /admin/raced.service
}

test_expected_snapshot_rejects_unknown_link() {
    local desired expected wants link
    setup_case expected-conflict
    desired=$TEST_CASE/desired.manifest
    expected=$TEST_CASE/expected.manifest
    wants=$TEST_CASE/systemd/etc/multi-user.target.wants
    mkdir -p "$wants"
    TEST_SYSTEMD_STATE=disabled
    service_enablement_capture systemd mihomo "$desired" || fail "$SERVICE_ENABLEMENT_ERROR"
    link=$wants/mihomo.service
    ln -s "$TEST_CASE/systemd/current/mihomo.service" "$link"
    TEST_SYSTEMD_STATE=enabled
    service_enablement_capture systemd mihomo "$expected" || fail "$SERVICE_ENABLEMENT_ERROR"
    /usr/bin/rm -f -- "$link"
    ln -s /admin/replacement.service "$link"
    TEST_SYSTEMD_STATE=disabled
    assert_fails service_enablement_restore systemd mihomo "$desired" "$expected"
    assert_link "$link" /admin/replacement.service
}

test_preflight_is_read_only_and_rejects_partial_snapshots() {
    local desired expected marker etc run desired_a desired_b expected_a expected_b
    setup_case preflight-cas
    desired=$TEST_CASE/desired.manifest
    expected=$TEST_CASE/expected.manifest
    marker=$TEST_CASE/commit-hook-ran
    etc=$TEST_CASE/systemd/etc
    run=$TEST_CASE/systemd/run
    desired_a=$etc/alpha.target.wants/mihomo.service
    desired_b=$run/beta.target.requires/mihomo.service
    expected_a=$etc/multi-user.target.wants/mihomo.service
    expected_b=$run/rescue.target.requires/mihomo.service
    mkdir -p -- "${desired_a%/*}" "${desired_b%/*}" \
        "${expected_a%/*}" "${expected_b%/*}"
    ln -s -- /vendor/alpha.service "$desired_a"
    ln -s -- /vendor/beta.service "$desired_b"
    TEST_SYSTEMD_STATE='enabled-runtime'
    service_enablement_capture systemd mihomo "$desired" || fail "$SERVICE_ENABLEMENT_ERROR"

    /usr/bin/rm -f -- "$desired_a" "$desired_b"
    ln -s -- "$TEST_CASE/systemd/current/mihomo.service" "$expected_a"
    ln -s -- "$TEST_CASE/systemd/current/mihomo.service" "$expected_b"
    TEST_SYSTEMD_STATE=enabled
    service_enablement_capture systemd mihomo "$expected" || fail "$SERVICE_ENABLEMENT_ERROR"
    _service_enablement_before_restore_commit() {
        # shellcheck disable=SC2317
        : >"$marker"
    }

    service_enablement_preflight_restore systemd mihomo "$desired" "$expected" ||
        fail "$SERVICE_ENABLEMENT_ERROR"
    assert_link "$expected_a" "$TEST_CASE/systemd/current/mihomo.service"
    assert_link "$expected_b" "$TEST_CASE/systemd/current/mihomo.service"
    assert_absent "$marker"
    assert_eq 0 "$TEST_SYSTEMD_RELOADS" 'read-only preflight reloaded systemd'

    /usr/bin/rm -f -- "$expected_b"
    ln -s -- /vendor/alpha.service "$desired_a"
    assert_fails service_enablement_preflight_restore systemd mihomo "$desired" "$expected"
    assert_link "$expected_a" "$TEST_CASE/systemd/current/mihomo.service"
    assert_link "$desired_a" /vendor/alpha.service
    assert_absent "$marker"

    /usr/bin/rm -f -- "$desired_a"
    assert_fails service_enablement_preflight_restore systemd mihomo "$desired" "$expected"
    assert_link "$expected_a" "$TEST_CASE/systemd/current/mihomo.service"
    assert_absent "$marker"

    /usr/bin/rm -f -- "$expected_a"
    ln -s -- /vendor/alpha.service "$desired_a"
    ln -s -- /vendor/beta.service "$desired_b"
    TEST_SYSTEMD_STATE=enabled
    assert_fails service_enablement_preflight_restore systemd mihomo "$desired" "$expected"
    assert_link "$desired_a" /vendor/alpha.service
    assert_link "$desired_b" /vendor/beta.service
    assert_absent "$marker"
}

test_restore_failures_roll_back_link_changes() {
    local desired expected link current
    setup_case restore-rollback
    desired=$TEST_CASE/desired.manifest
    expected=$TEST_CASE/expected.manifest
    link=$TEST_CASE/systemd/etc/multi-user.target.wants/mihomo.service
    current=$TEST_CASE/systemd/current/mihomo.service
    mkdir -p -- "${link%/*}"
    TEST_SYSTEMD_STATE=disabled
    service_enablement_capture systemd mihomo "$desired" || fail "$SERVICE_ENABLEMENT_ERROR"
    ln -s -- "$current" "$link"
    TEST_SYSTEMD_STATE=enabled
    service_enablement_capture systemd mihomo "$expected" || fail "$SERVICE_ENABLEMENT_ERROR"

    TEST_SYSTEMD_RELOAD_FAIL=1
    assert_fails service_enablement_restore systemd mihomo "$desired" "$expected"
    assert_link "$link" "$current"
    assert_eq 2 "$TEST_SYSTEMD_RELOADS" \
        'reload failure did not attempt a reload after rolling links back'

    TEST_SYSTEMD_RELOAD_FAIL=0
    TEST_SYSTEMD_RELOADS=0
    assert_fails service_enablement_restore systemd mihomo "$desired" "$expected"
    assert_link "$link" "$current"
    assert_eq 2 "$TEST_SYSTEMD_RELOADS" \
        'verification failure did not reload after rolling links back'
}

test_sysv_all_runlevels_roundtrip() {
    local original expected root entry
    setup_case sysv-roundtrip
    root=$TEST_CASE/sysv
    original=$TEST_CASE/sysv-original.manifest
    expected=$TEST_CASE/sysv-expected.manifest
    mkdir -p "$root/rc0.d" "$root/rc2.d" "$root/rcCustom.d" "$root/rc.d/rc6.d"
    ln -s ../init.d/mihomo "$root/rc0.d/K20mihomo"
    ln -s ../init.d/mihomo "$root/rc2.d/S10mihomo"
    ln -s ../init.d/mihomo "$root/rcCustom.d/S99mihomo"
    ln -s ../../init.d/mihomo "$root/rc.d/rc6.d/K01mihomo"
    service_enablement_capture sysvinit mihomo "$original" || fail "$SERVICE_ENABLEMENT_ERROR"
    assert_eq enabled "$(manifest_state "$original")" 'SysV enabled state was not derived'

    for entry in "$root/rc0.d/K20mihomo" "$root/rc2.d/S10mihomo" \
        "$root/rcCustom.d/S99mihomo" "$root/rc.d/rc6.d/K01mihomo"; do
        /usr/bin/rm -f -- "$entry"
    done
    ln -s ../init.d/mihomo "$root/rc2.d/S01mihomo"
    service_enablement_capture sysvinit mihomo "$expected" || fail "$SERVICE_ENABLEMENT_ERROR"
    service_enablement_restore sysvinit mihomo "$original" "$expected" ||
        fail "$SERVICE_ENABLEMENT_ERROR"
    assert_link "$root/rc0.d/K20mihomo" ../init.d/mihomo
    assert_link "$root/rc2.d/S10mihomo" ../init.d/mihomo
    assert_link "$root/rcCustom.d/S99mihomo" ../init.d/mihomo
    assert_link "$root/rc.d/rc6.d/K01mihomo" ../../init.d/mihomo
    assert_absent "$root/rc2.d/S01mihomo"
    service_enablement_reconcile sysvinit mihomo "$original" || fail "$SERVICE_ENABLEMENT_ERROR"

    ln -s /admin/mihomo "$root/rc2.d/K88mihomo"
    assert_fails service_enablement_restore sysvinit mihomo "$original"
    assert_link "$root/rc2.d/K88mihomo" /admin/mihomo
}

test_sysv_compat_runlevel_aliases() {
    local original disabled root canonical alias link external
    setup_case sysv-aliases
    original=$TEST_CASE/original.manifest
    disabled=$TEST_CASE/disabled.manifest
    root=$TEST_CASE/sysv
    canonical=$root/rc.d/rc2.d
    alias=$root/rc2.d
    link=$canonical/S20mihomo
    mkdir -p -- "$canonical"
    ln -s -- rc.d/rc2.d "$alias"
    ln -s -- ../../init.d/mihomo "$link"
    service_enablement_capture sysvinit mihomo "$original" || fail "$SERVICE_ENABLEMENT_ERROR"
    assert_eq enabled "$(manifest_state "$original")" \
        'SysV compatibility runlevel link was not captured'
    [[ $(manifest_links "$original") == *"$(_service_enablement_hex_encode "$link")"* ]] ||
        fail 'SysV manifest did not use the canonical runlevel path'

    /usr/bin/rm -f -- "$link"
    service_enablement_capture sysvinit mihomo "$disabled" || fail "$SERVICE_ENABLEMENT_ERROR"
    service_enablement_restore sysvinit mihomo "$original" "$disabled" ||
        fail "$SERVICE_ENABLEMENT_ERROR"
    assert_link "$link" ../../init.d/mihomo
    assert_link "$alias" rc.d/rc2.d

    external=$TEST_CASE/external-runlevel
    mkdir -p -- "$external"
    ln -s -- "$external" "$root/rc3.d"
    assert_fails service_enablement_capture sysvinit mihomo "$TEST_CASE/unsafe.manifest"
    assert_link "$root/rc3.d" "$external"
}

test_openrc_arbitrary_runlevels_roundtrip() {
    local original expected root target
    setup_case openrc-roundtrip
    root=$TEST_CASE/openrc/runlevels
    target=$TEST_CASE/openrc/init.d/mihomo
    original=$TEST_CASE/openrc-original.manifest
    expected=$TEST_CASE/openrc-expected.manifest
    mkdir -p "$root/boot.custom" "$root/net-online" "$root/default"
    ln -s "$target" "$root/boot.custom/mihomo"
    ln -s ../../init.d/mihomo "$root/net-online/mihomo"
    service_enablement_capture openrc mihomo "$original" || fail "$SERVICE_ENABLEMENT_ERROR"
    /usr/bin/rm -f -- "$root/boot.custom/mihomo" "$root/net-online/mihomo"
    ln -s "$target" "$root/default/mihomo"
    service_enablement_capture openrc mihomo "$expected" || fail "$SERVICE_ENABLEMENT_ERROR"
    service_enablement_restore openrc mihomo "$original" "$expected" ||
        fail "$SERVICE_ENABLEMENT_ERROR"
    assert_link "$root/boot.custom/mihomo" "$target"
    assert_link "$root/net-online/mihomo" ../../init.d/mihomo
    assert_absent "$root/default/mihomo"
    service_enablement_reconcile openrc mihomo "$original" || fail "$SERVICE_ENABLEMENT_ERROR"
}

test_runit_single_link_roundtrip_and_conflicts() {
    local original expected disabled link original_target current_target
    setup_case runit-roundtrip
    link=$TEST_CASE/runit/enabled/mihomo
    original_target=$TEST_CASE/runit/services/original-mihomo
    current_target=$TEST_CASE/runit/services/mihomo
    mkdir -p "$original_target"
    original=$TEST_CASE/runit-original.manifest
    expected=$TEST_CASE/runit-expected.manifest
    disabled=$TEST_CASE/runit-disabled.manifest
    ln -s "$original_target" "$link"
    service_enablement_capture runit mihomo "$original" || fail "$SERVICE_ENABLEMENT_ERROR"
    /usr/bin/rm -f -- "$link"
    ln -s "$current_target" "$link"
    service_enablement_capture runit mihomo "$expected" || fail "$SERVICE_ENABLEMENT_ERROR"
    service_enablement_restore runit mihomo "$original" "$expected" || fail "$SERVICE_ENABLEMENT_ERROR"
    assert_link "$link" "$original_target"

    /usr/bin/rm -f -- "$link"
    service_enablement_capture runit mihomo "$disabled" || fail "$SERVICE_ENABLEMENT_ERROR"
    ln -s /admin/runit-service "$link"
    assert_fails service_enablement_restore runit mihomo "$disabled"
    assert_link "$link" /admin/runit-service
    /usr/bin/rm -f -- "$link"
    printf '%s\n' 'not a link' >"$link"
    assert_fails service_enablement_restore runit mihomo "$disabled"
    [ -f "$link" ] || fail 'runit ordinary file was removed'
}

test_hex_target_roundtrip() {
    local original expected link original_target current_target
    setup_case hex-target
    link=$TEST_CASE/runit/enabled/mihomo
    original=$TEST_CASE/original.manifest
    expected=$TEST_CASE/expected.manifest
    original_target=$'relative,colon:target\nsecond line\n'
    current_target=$TEST_CASE/runit/services/mihomo
    ln -s "$original_target" "$link"
    service_enablement_capture runit mihomo "$original" || fail "$SERVICE_ENABLEMENT_ERROR"
    /usr/bin/rm -f -- "$link"
    ln -s "$current_target" "$link"
    service_enablement_capture runit mihomo "$expected" || fail "$SERVICE_ENABLEMENT_ERROR"
    service_enablement_restore runit mihomo "$original" "$expected" || fail "$SERVICE_ENABLEMENT_ERROR"
    assert_link_exact "$link" "$original_target"
}

test_manifest_validation() {
    local valid bad links first second outside_hex target_hex old_limit
    setup_case manifest-validation
    mkdir -p "$TEST_CASE/openrc/runlevels/a" "$TEST_CASE/openrc/runlevels/b"
    ln -s ../../init.d/mihomo "$TEST_CASE/openrc/runlevels/a/mihomo"
    ln -s ../../init.d/mihomo "$TEST_CASE/openrc/runlevels/b/mihomo"
    valid=$TEST_CASE/valid.manifest
    service_enablement_capture openrc mihomo "$valid" || fail "$SERVICE_ENABLEMENT_ERROR"
    links=$(manifest_links "$valid")
    IFS=, read -r first second <<<"$links"

    bad=$TEST_CASE/duplicate.manifest
    write_manifest "$bad" openrc mihomo enabled "$first,$first"
    assert_fails service_enablement_reconcile openrc mihomo "$bad"
    write_manifest "$bad" openrc mihomo enabled "$second,$first"
    assert_fails service_enablement_reconcile openrc mihomo "$bad"
    write_manifest "$bad" openrc mihomo enabled 'zz:11'
    assert_fails service_enablement_reconcile openrc mihomo "$bad"

    outside_hex=$(_service_enablement_hex_encode "$TEST_CASE/outside/mihomo")
    target_hex=$(_service_enablement_hex_encode /tmp/target)
    write_manifest "$bad" openrc mihomo enabled "$outside_hex:$target_hex"
    assert_fails service_enablement_reconcile openrc mihomo "$bad"
    write_manifest "$bad" openrc other disabled ''
    assert_fails service_enablement_reconcile openrc mihomo "$bad"
    write_manifest "$bad" openrc mihomo disabled "$first"
    assert_fails service_enablement_reconcile openrc mihomo "$bad"

    cp -- "$valid" "$bad"
    chmod 0666 "$bad"
    assert_fails service_enablement_reconcile openrc mihomo "$bad"
    chmod 0600 "$bad"
    ln -s "$valid" "$TEST_CASE/symlink.manifest"
    assert_fails service_enablement_reconcile openrc mihomo "$TEST_CASE/symlink.manifest"

    old_limit=$SERVICE_ENABLEMENT_MANIFEST_MAX_BYTES
    SERVICE_ENABLEMENT_MANIFEST_MAX_BYTES=32
    assert_fails service_enablement_reconcile openrc mihomo "$valid"
    SERVICE_ENABLEMENT_MANIFEST_MAX_BYTES=$old_limit
}

test_systemd_capture_restore_and_idempotence
test_systemd_states_are_preserved
test_systemd_upholds_roundtrip
test_systemd_conflicts_and_race
test_expected_snapshot_rejects_unknown_link
test_preflight_is_read_only_and_rejects_partial_snapshots
test_restore_failures_roll_back_link_changes
test_sysv_all_runlevels_roundtrip
test_sysv_compat_runlevel_aliases
test_openrc_arbitrary_runlevels_roundtrip
test_runit_single_link_roundtrip_and_conflicts
test_hex_target_roundtrip
test_manifest_validation

printf '%s\n' 'service enablement tests passed'
