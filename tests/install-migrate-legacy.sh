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
    grep -Fqs -- "$expected" "$file" ||
        fail "$description: missing [$expected]"
}

assert_not_contains() {
    local file=$1 unexpected=$2 description=$3
    if grep -Fqs -- "$unexpected" "$file"; then
        fail "$description: unexpectedly found [$unexpected]"
    fi
}

make_layout() {
    local root=$1
    mkdir -p -- "$root/scripts/lib" "$root/scripts/cmd"
    printf '%s\n' layout-install >"$root/install.sh"
    printf '%s\n' layout-uninstall >"$root/uninstall.sh"
    printf '%s\n' layout-preflight >"$root/scripts/preflight.sh"
    printf '%s\n' layout-common >"$root/scripts/lib/common.sh"
    printf '%s\n' layout-off >"$root/scripts/cmd/off.sh"
}

# 旧版（master 时代）布局：数据在 resources/ 下，无安装标记
make_legacy_home() {
    local root=$1
    mkdir -p -- "$root/resources/profiles" "$root/bin"
    printf 'port: 7890\n' >"$root/resources/config.yaml"
    printf 'mixin: true\n' >"$root/resources/mixin.yaml"
    printf 'profiles:\n  - name: demo\n    url: https://sub.invalid/token\n' \
        >"$root/resources/profiles.yaml"
    printf 'proxies: []\n' >"$root/resources/profiles/demo.yaml"
    printf 'old-kernel\n' >"$root/bin/mihomo"
}

export CLASHCTL_INSTALL_SOURCE_ONLY=1 CLASHCTL_COLOR=never
# shellcheck source=../install.sh
. "$REPO_DIR/install.sh"

user_home="$WORK_DIR/user"
mkdir -p -- "$user_home"
export HOME=$user_home
unset CLASHCTL_HOME CLASHCTL_LOCAL_SOURCE CLASHCTL_INSTALL_SESSION CLASHCTL_NON_INTERACTIVE

legacy="$user_home/clashctl"
new_home="$user_home/.clashctl"

# ── 用例 1：非交互环境跳过自动迁移并给出手动指引 ──
make_legacy_home "$legacy"
make_layout "$new_home"
_install_marker_write "$new_home" "$new_home" || fail 'could not mark new home'
handoff=0
_install_handoff_to_clashctl() { handoff=1; }
_INSTALL_SCRIPT_DIR=$new_home
export CLASHCTL_SRC=
rc=0
main --home "$new_home" --branch iu --non-interactive \
    >"$WORK_DIR/skip.stdout" 2>"$WORK_DIR/skip.stderr" || rc=$?
assert_eq 0 "$rc" 'non-interactive legacy detection completes'
assert_eq 1 "$handoff" 'non-interactive legacy detection still hands off'
assert_contains "$WORK_DIR/skip.stderr" '检测到旧版安装' 'legacy install is detected'
assert_contains "$WORK_DIR/skip.stderr" '非交互环境：跳过自动迁移' 'skip reason is explicit'
assert_contains "$WORK_DIR/skip.stderr" 'cp '"$legacy"'/resources/' 'manual migration path is given'
[ -d "$legacy" ] || fail 'non-interactive skip must not remove the legacy home'
[ ! -d "$new_home/data/profiles" ] ||
    fail 'non-interactive skip must not migrate data'

# ── 用例 2：确认后自动迁移数据并保留旧目录为 .bak ──
rm -rf -- "$new_home"
make_layout "$new_home"
_install_marker_write "$new_home" "$new_home" || fail 'could not re-mark new home'
make_legacy_home "$legacy"
handoff=0
_ui_confirm() { return 0; }
_install_can_prompt() { return 0; }
_INSTALL_SCRIPT_DIR=$new_home
export CLASHCTL_SRC=
rc=0
main --home "$new_home" --branch iu \
    >"$WORK_DIR/migrate.stdout" 2>"$WORK_DIR/migrate.stderr" || rc=$?
assert_eq 0 "$rc" 'interactive legacy migration completes'
assert_eq 1 "$handoff" 'migration hands off to clashctl install'
assert_contains "$WORK_DIR/migrate.stderr" '旧版数据已迁入' 'migration reports success'
assert_contains "$WORK_DIR/migrate.stderr" '旧版目录已保留为' 'backup retention is reported'
[ -f "$new_home/data/config.yaml" ] || fail 'config.yaml was not migrated'
[ -f "$new_home/data/mixin.yaml" ] || fail 'mixin.yaml was not migrated'
[ -f "$new_home/data/profiles.yaml" ] || fail 'profiles.yaml was not migrated'
[ -f "$new_home/data/profiles/demo.yaml" ] || fail 'subscription profiles were not migrated'
[ "$(stat -c %a -- "$new_home/data/config.yaml")" = 600 ] ||
    fail 'migrated config must be 0600'
legacy_backup=$(find "$user_home" -maxdepth 1 -name 'clashctl.bak.*' -print -quit)
[ -n "$legacy_backup" ] || fail 'legacy home was not retained as .bak'
[ -f "$legacy_backup/resources/profiles.yaml" ] ||
    fail 'legacy backup retains original data'
[ ! -d "$legacy" ] || fail 'legacy home should have been renamed after migration'
unset -f _ui_confirm

# ── 用例 3：拒绝迁移时保留原状并继续安装 ──
legacy="$user_home/clashctl"
make_legacy_home "$legacy"
rm -rf -- "$new_home"
make_layout "$new_home"
_install_marker_write "$new_home" "$new_home" || fail 'could not re-mark new home again'
handoff=0
_ui_confirm() { return 1; }
_install_can_prompt() { return 0; }
_INSTALL_SCRIPT_DIR=$new_home
export CLASHCTL_SRC=
rc=0
main --home "$new_home" --branch iu \
    >"$WORK_DIR/decline.stdout" 2>"$WORK_DIR/decline.stderr" || rc=$?
assert_eq 0 "$rc" 'declined migration still completes'
assert_eq 1 "$handoff" 'declined migration hands off'
assert_contains "$WORK_DIR/decline.stderr" '已跳过迁移' 'decline is reported'
[ -d "$legacy" ] || fail 'declined migration must keep legacy home untouched'
[ ! -f "$new_home/data/profiles.yaml" ] ||
    fail 'declined migration must not copy data'
unset -f _ui_confirm

# ── 用例 4：显式 --home 指到旧目录 = 原地接管，不进入迁移流程 ──
rc=0
main --home "$legacy" --branch iu --non-interactive \
    >"$WORK_DIR/inplace.stdout" 2>"$WORK_DIR/inplace.stderr" || rc=$?
[ "$rc" -ne 0 ] || fail 'in-place takeover without legacy flag must fail'
assert_not_contains "$WORK_DIR/inplace.stderr" '旧版数据已迁入' \
    'in-place takeover must not run data migration'

printf '%s\n' 'install-migrate-legacy: ok'
