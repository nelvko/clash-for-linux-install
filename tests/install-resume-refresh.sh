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

make_layout() {
    local root=$1 version=$2
    mkdir -p -- "$root/scripts/lib" "$root/scripts/cmd"
    printf '%s\n' "$version-install" >"$root/install.sh"
    printf '%s\n' "$version-uninstall" >"$root/uninstall.sh"
    printf '%s\n' "$version-preflight" >"$root/scripts/preflight.sh"
    printf '%s\n' "$version-common" >"$root/scripts/lib/common.sh"
    printf '%s\n' "$version-off" >"$root/scripts/cmd/off.sh"
}

snapshot_tree() {
    {
        find "$1" -xdev -printf 'meta|%P|%y|%m|%s\n'
        find "$1" -xdev -type f -exec sha256sum -- {} +
    } | LC_ALL=C sort
}

assert_no_stage() {
    local home=$1
    if find "$(dirname -- "$home")" -maxdepth 1 -name "$(basename -- "$home").installing.*" \
        -print -quit | grep -q .; then
        fail "$2: installation stage was created"
    fi
}

export CLASHCTL_INSTALL_SOURCE_ONLY=1 CLASHCTL_COLOR=never
# shellcheck source=../install.sh
. "$REPO_DIR/install.sh"

home="$WORK_DIR/network/home"
mkdir -p -- "$home"
make_layout "$home" old
_install_marker_write "$home" "$home" || fail 'could not mark incomplete home'
mkdir -p -- "$home/data/profiles" "$home/archives" "$home/bin/mihomo"
printf 'private-data\n' >"$home/data/profiles/demo.yaml"
printf 'cached-archive\n' >"$home/archives/component.gz"
printf 'old-binary\n' >"$home/bin/mihomo/mihomo"
printf 'service-state\n' >"$home/.service-transaction"
before=$(snapshot_tree "$home")

fetch_called=0
_install_plan() { :; }
_install_detect_service_manager() { printf 'nohup\n'; }
_fetch_into() {
    fetch_called=1
    return 1
}

export CLASHCTL_SRC=
unset CLASHCTL_LOCAL_SOURCE CLASHCTL_INSTALL_SESSION CLASHCTL_NON_INTERACTIVE
rc=0
main --home "$home" --branch iu --non-interactive \
    >"$WORK_DIR/network.stdout" 2>"$WORK_DIR/network.stderr" || rc=$?
assert_eq 1 "$rc" 'network bootstrap rejects source replacement'
assert_eq 0 "$fetch_called" 'network bootstrap rejects before downloading'
assert_eq "$before" "$(snapshot_tree "$home")" 'network rejection preserves incomplete home'
assert_no_stage "$home" 'network rejection'
assert_contains "$WORK_DIR/network.stderr" \
    '上次安装没有完成，本次已停止' 'network rejection explains the boundary'
assert_contains "$WORK_DIR/network.stderr" '未做任何修改' \
    'network rejection reports that the home was preserved'
assert_contains "$WORK_DIR/network.stderr" '继续安装（推荐）:' \
    'network rejection provides an in-place continuation command'
assert_contains "$WORK_DIR/network.stderr" '重新开始' \
    'network rejection provides backup and reinstall guidance'
assert_contains "$WORK_DIR/network.stderr" '重新开始' \
    'network rejection offers a clean restart option'

external="$WORK_DIR/external/source"
mkdir -p -- "$external"
make_layout "$external" new
before=$(snapshot_tree "$home")
unset CLASHCTL_INSTALL_SESSION CLASHCTL_NON_INTERACTIVE
rc=0
main --home "$home" --source-dir "$external" --branch iu --non-interactive \
    >"$WORK_DIR/external.stdout" 2>"$WORK_DIR/external.stderr" || rc=$?
assert_eq 1 "$rc" 'external source rejects source replacement'
assert_eq "$before" "$(snapshot_tree "$home")" 'external rejection preserves incomplete home'
assert_no_stage "$home" 'external source rejection'
assert_contains "$WORK_DIR/external.stderr" \
    '上次安装没有完成，本次已停止' 'external rejection explains the boundary'

subscription_file="$WORK_DIR/subscription input.url"
subscription_url='https://subscription.invalid/api?token=resume-secret'
printf '%s\n' "$subscription_url" >"$subscription_file"
chmod 0600 -- "$subscription_file"
unset CLASHCTL_LOCAL_SOURCE CLASHCTL_INSTALL_SESSION CLASHCTL_NON_INTERACTIVE
export CLASHCTL_SRC=
rc=0
main --home "$home" --branch iu --non-interactive \
    --subscription-file "$subscription_file" \
    >"$WORK_DIR/subscription.stdout" 2>"$WORK_DIR/subscription.stderr" || rc=$?
assert_eq 1 "$rc" 'subscription-file bootstrap rejects source replacement'
assert_contains "$WORK_DIR/subscription.stderr" '--subscription-file' \
    'continuation command preserves the subscription-file option'
printf -v quoted_subscription '%q' "$subscription_file"
assert_contains "$WORK_DIR/subscription.stderr" "$quoted_subscription" \
    'continuation command safely quotes the subscription-file path'
if grep -Fqs -- "$subscription_url" "$WORK_DIR/subscription.stderr"; then
    fail 'source replacement rejection leaked the subscription URL'
fi

handoff_called=0
handoff_home='' handoff_kernel='' handoff_branch='' handoff_subfile=''
_install_handoff_to_clashctl() {
    handoff_called=1
    handoff_home=$1 handoff_kernel=$2 handoff_branch=$3 handoff_subfile=$4
}
before=$(snapshot_tree "$home")
_INSTALL_SCRIPT_DIR=$home
export CLASHCTL_SRC=
unset CLASHCTL_LOCAL_SOURCE CLASHCTL_INSTALL_SESSION CLASHCTL_NON_INTERACTIVE
rc=0
main --home "$home" --branch iu --non-interactive \
    --subscription-file "$subscription_file" \
    >"$WORK_DIR/self-source.stdout" 2>"$WORK_DIR/self-source.stderr" || rc=$?
assert_eq 0 "$rc" 'in-place continuation reaches the clashctl handoff'
assert_eq 1 "$handoff_called" 'in-place continuation hands off to clashctl install'
assert_eq "$home" "$handoff_home" 'handoff receives the incomplete home'
assert_eq mihomo "$handoff_kernel" 'handoff receives the requested kernel'
assert_eq iu "$handoff_branch" 'handoff receives the tracked branch'
assert_eq "$subscription_file" "$handoff_subfile" \
    'handoff preserves the subscription-file option'
assert_eq "$before" "$(snapshot_tree "$home")" \
    'in-place continuation preserves private data until clashctl install runs'
assert_contains "$WORK_DIR/self-source.stderr" \
    '使用未完成目录内已验证的程序文件继续安装' \
    'in-place continuation reports the selected source'
if grep -Fqs -- '上次安装没有完成，本次已停止' \
    "$WORK_DIR/self-source.stderr"; then
    fail 'in-place continuation was rejected as a source replacement'
fi
if grep -Fqs -- "$subscription_url" "$WORK_DIR/self-source.stderr"; then
    fail 'in-place continuation leaked the subscription URL'
fi

# ── rc 已集成时：推荐直接 clashctl install ──
rc_fake_user="$WORK_DIR/rc-user"
mkdir -p -- "$rc_fake_user" "$rc_fake_user/.config/fish/conf.d"
printf '# >>> clashctl >>>\n# <<< clashctl <<<\n' >"$rc_fake_user/.config/fish/conf.d/clashctl.fish"
rc_home="$WORK_DIR/rc-home"
mkdir -p -- "$rc_home"
make_layout "$rc_home" rcver
_install_marker_write "$rc_home" "$rc_home" || fail 'could not mark rc-test home'
handoff2=0
_install_handoff_to_clashctl() { handoff2=1; }
_INSTALL_SCRIPT_DIR=$rc_home
export CLASHCTL_SRC=
rc=0
HOME="$rc_fake_user" main --home "$rc_home" --branch iu --non-interactive \
    >"$WORK_DIR/rc.stdout" 2>"$WORK_DIR/rc.stderr" || rc=$?
assert_eq 1 "$rc" 'rc-integrated rejection still refuses'
assert_contains "$WORK_DIR/rc.stderr" '继续安装（推荐）: clashctl install' \
    'rc-integrated rejection recommends the short command'
assert_contains "$WORK_DIR/rc.stderr" '或: bash' \
    'rc-integrated rejection keeps the script path as secondary fallback'
grep -Fqs '# >>> clashctl >>>' "$WORK_DIR/rc.stderr" && fail 'marker leaked into output'

# ── 智能默认：目录内 install.sh 免 --home 续装 ──
smart_home="$WORK_DIR/smart-home"
mkdir -p -- "$smart_home"
make_layout "$smart_home" smartver
_install_marker_write "$smart_home" "$smart_home" || fail 'could not mark smart home'
smart_handoff_home='' smart_handoff_kernel='' smart_handoff_branch=''
_install_handoff_to_clashctl() {
    smart_handoff_home=$1 smart_handoff_kernel=$2 smart_handoff_branch=$3
}
unset CLASHCTL_HOME CLASHCTL_LOCAL_SOURCE CLASHCTL_INSTALL_SESSION CLASHCTL_NON_INTERACTIVE
export CLASHCTL_SRC=
_INSTALL_SCRIPT_DIR=$smart_home
_install_plan() { :; }
_require_empty_home() { _INSTALL_HOME_STATE=resume; }
rc=0
main --branch iu >"$WORK_DIR/smart.stdout" 2>"$WORK_DIR/smart.stderr" || rc=$?
_INSTALL_SCRIPT_DIR=$REPO_DIR
assert_eq 0 "$rc" 'script-dir marker defaults home without --home'
assert_eq "$smart_home" "$smart_handoff_home" 'script-dir home becomes the install target'
assert_eq iu "$smart_handoff_branch" 'branch still honored'
_INSTALL_SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

printf '%s\n' 'install-resume-refresh: ok'

