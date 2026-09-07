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

# ── 用例 1：在线重跑（curl 形态：SRC 空、脚本目录不在家内）沿用现有文件续装 ──
home="$WORK_DIR/online/home"
mkdir -p -- "$home"
make_layout "$home" old
_install_marker_write "$home" "$home" || fail 'could not mark incomplete home'
mkdir -p -- "$home/data/profiles" "$home/archives" "$home/bin/mihomo"
printf 'private-data\n' >"$home/data/profiles/demo.yaml"
printf 'cached-archive\n' >"$home/archives/component.gz"
printf 'old-binary\n' >"$home/bin/mihomo/mihomo"
printf 'service-state\n' >"$home/.service-transaction"
before=$(snapshot_tree "$home")

subscription_file="$WORK_DIR/subscription input.url"
subscription_url='https://subscription.invalid/api?token=resume-secret'
printf '%s\n' "$subscription_url" >"$subscription_file"
chmod 0600 -- "$subscription_file"

fetch_called=0
handoff_called=0
handoff_home='' handoff_kernel='' handoff_branch='' handoff_subfile=''
_install_plan() { :; }
_fetch_into() {
    fetch_called=1
    return 1
}
_install_handoff_to_clashctl() {
    handoff_called=1
    handoff_home=$1 handoff_kernel=$2 handoff_branch=$3 handoff_subfile=$4
}
unset CLASHCTL_HOME CLASHCTL_LOCAL_SOURCE CLASHCTL_INSTALL_SESSION CLASHCTL_NON_INTERACTIVE
export CLASHCTL_SRC=
rc=0
main --home "$home" --branch iu --non-interactive \
    --subscription-file "$subscription_file" \
    >"$WORK_DIR/online.stdout" 2>"$WORK_DIR/online.stderr" || rc=$?
assert_eq 0 "$rc" 'online rerun continues in place without refreshing'
assert_eq 0 "$fetch_called" 'continuation must not re-download program files'
assert_eq 1 "$handoff_called" 'continuation reaches the clashctl handoff'
assert_eq "$home" "$handoff_home" 'handoff receives the incomplete home'
assert_eq mihomo "$handoff_kernel" 'handoff receives the requested kernel'
assert_eq iu "$handoff_branch" 'handoff receives the tracked branch'
assert_eq "$subscription_file" "$handoff_subfile" \
    'handoff preserves the subscription-file option'
assert_eq "$before" "$(snapshot_tree "$home")" \
    'continuation preserves everything until clashctl install runs'
assert_no_stage "$home" 'online rerun'
assert_contains "$WORK_DIR/online.stderr" '继续未完成的安装' \
    'continuation reports the resume state'
assert_contains "$WORK_DIR/online.stderr" '沿用目录中现有程序文件' \
    'continuation explains that existing files are reused'
if grep -Fqs -- "$subscription_url" "$WORK_DIR/online.stderr"; then
    fail 'continuation leaked the subscription URL'
fi

# ── 用例 2：续装时叠加 --source-dir → 拒绝，目录保持原状 ──
external="$WORK_DIR/external/source"
mkdir -p -- "$external"
make_layout "$external" new
before=$(snapshot_tree "$home")
unset CLASHCTL_HOME CLASHCTL_LOCAL_SOURCE CLASHCTL_INSTALL_SESSION CLASHCTL_NON_INTERACTIVE
rc=0
main --home "$home" --source-dir "$external" --branch iu --non-interactive \
    >"$WORK_DIR/external.stdout" 2>"$WORK_DIR/external.stderr" || rc=$?
assert_eq 1 "$rc" 'source-dir over an incomplete home is rejected'
assert_eq "$before" "$(snapshot_tree "$home")" 'rejection preserves the incomplete home'
assert_no_stage "$home" 'source-dir rejection'
assert_contains "$WORK_DIR/external.stderr" '不能指定 --source-dir' \
    'rejection names the conflicting option'
assert_contains "$WORK_DIR/external.stderr" "bash $home/install.sh" \
    'rejection recommends the in-home continuation command'

# ── 用例 3：显式 --branch 与家的 git 分支冲突 → 拒绝；省略则沿用 ──
br_home="$WORK_DIR/branch-home"
mkdir -p -- "$br_home"
make_layout "$br_home" brver
_install_marker_write "$br_home" "$br_home" || fail 'could not mark branch home'
git -C "$br_home" init -q -b iu && git -C "$br_home" add -A >/dev/null 2>&1 &&
    git -C "$br_home" -c user.email=t@t -c user.name=t commit -qm seed >/dev/null 2>&1
before=$(snapshot_tree "$br_home")
br_handoff_branch=''
_install_handoff_to_clashctl() { br_handoff_branch=$3; }
_install_plan() { :; }
unset CLASHCTL_HOME CLASHCTL_LOCAL_SOURCE CLASHCTL_INSTALL_SESSION CLASHCTL_NON_INTERACTIVE
export CLASHCTL_SRC=
rc=0
main --home "$br_home" --branch master --non-interactive \
    >"$WORK_DIR/br-conflict.stdout" 2>"$WORK_DIR/br-conflict.stderr" || rc=$?
assert_eq 1 "$rc" 'conflicting explicit branch is rejected'
assert_eq '' "$br_handoff_branch" 'conflicting branch never reaches the handoff'
assert_eq "$before" "$(snapshot_tree "$br_home")" 'branch rejection preserves the home'
assert_contains "$WORK_DIR/br-conflict.stderr" '现有分支是 iu' \
    'rejection names the home branch'
assert_contains "$WORK_DIR/br-conflict.stderr" '省略 --branch' \
    'rejection explains the implicit continuation path'

rc=0
main --home "$br_home" --non-interactive \
    >"$WORK_DIR/br-default.stdout" 2>"$WORK_DIR/br-default.stderr" || rc=$?
assert_eq 0 "$rc" 'bare continuation completes'
assert_eq iu "$br_handoff_branch" 'bare continuation keeps the home git branch'

# ── 用例 4：脚本目录就在标记家内 → 免 --home 智能默认 ──
smart_home="$WORK_DIR/smart-home"
mkdir -p -- "$smart_home"
make_layout "$smart_home" smartver
_install_marker_write "$smart_home" "$smart_home" || fail 'could not mark smart home'
smart_handoff_home='' smart_handoff_kernel='' smart_handoff_branch=''
_install_handoff_to_clashctl() {
    smart_handoff_home=$1 smart_handoff_kernel=$2 smart_handoff_branch=$3
}
_install_plan() { :; }
unset CLASHCTL_HOME CLASHCTL_LOCAL_SOURCE CLASHCTL_INSTALL_SESSION CLASHCTL_NON_INTERACTIVE
export CLASHCTL_SRC=
_INSTALL_SCRIPT_DIR=$smart_home
rc=0
main --branch iu >"$WORK_DIR/smart.stdout" 2>"$WORK_DIR/smart.stderr" || rc=$?
_INSTALL_SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
assert_eq 0 "$rc" 'script-dir marker defaults home without --home'
assert_eq "$smart_home" "$smart_handoff_home" 'script-dir home becomes the install target'
assert_eq iu "$smart_handoff_branch" 'branch still honored'

printf '%s\n' 'install-resume: ok'
