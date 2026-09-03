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

assert_rejected() {
    local description=$1
    shift
    if "$@" >"$WORK_DIR/rejected.stdout" 2>"$WORK_DIR/rejected.stderr"; then
        fail "$description: unexpectedly accepted"
    fi
}

make_layout() {
    local home=$1
    mkdir -p -- "$home/scripts/lib" "$home/scripts/cmd"
    : >"$home/install.sh"
    : >"$home/uninstall.sh"
    : >"$home/scripts/preflight.sh"
    : >"$home/scripts/lib/common.sh"
    : >"$home/scripts/cmd/off.sh"
}

export CLASHCTL_INSTALL_SOURCE_ONLY=1 CLASHCTL_COLOR=never
# shellcheck source=../install.sh
. "$REPO_DIR/install.sh"

export HOME="$WORK_DIR/user home"
mkdir -p -- "$HOME"

assert_rejected 'root directory' _install_validate_home_path / ''
assert_rejected 'top-level tmp directory' _install_validate_home_path /tmp ''
assert_rejected 'entire user home' _install_validate_home_path "$HOME" ''

source_dir="$WORK_DIR/source"
mkdir -p -- "$source_dir"
unset CLASHCTL_INSTALL_SESSION
assert_rejected 'source directory itself' _install_validate_home_path "$source_dir" "$source_dir"
assert_rejected 'source descendant' _install_validate_home_path "$source_dir/install" "$source_dir"
assert_rejected 'source ancestor' _install_validate_home_path "$WORK_DIR" "$source_dir"

fake_resume="$WORK_DIR/fake-resume"
make_layout "$fake_resume"
assert_rejected 'unmarked continuation directory' _require_empty_home "$fake_resume"
[ ! -e "$fake_resume/.clashctl-installation" ] || fail 'unmarked directory was modified without authorization'

mismatched="$WORK_DIR/mismatched"
make_layout "$mismatched"
_install_marker_write "$mismatched" "$WORK_DIR/other-home"
assert_rejected 'mismatched marker path' _require_empty_home "$mismatched"

writable="$WORK_DIR/group-writable"
make_layout "$writable"
chmod 0770 "$writable"
assert_rejected 'group-writable install directory' _require_empty_home "$writable"

legacy="$WORK_DIR/legacy layout"
make_layout "$legacy"
export _INSTALL_ALLOW_LEGACY_LAYOUT=1
_require_empty_home "$legacy" >"$WORK_DIR/legacy.stdout" 2>"$WORK_DIR/legacy.stderr" ||
    fail 'explicitly authorized legacy layout was rejected'
unset _INSTALL_ALLOW_LEGACY_LAYOUT
[ "$_INSTALL_HOME_STATE" = resume ] || fail 'legacy layout did not enter resume state'
_install_marker_validate "$legacy" || fail 'legacy layout did not receive a valid marker'
[ "$(stat -c %a -- "$legacy/.clashctl-installation")" = 600 ] || fail 'marker mode is not 0600'

complete="$WORK_DIR/complete"
make_layout "$complete"
: >"$complete/.env"
_install_marker_write "$complete" "$complete"
assert_rejected 'completed installation' _require_empty_home "$complete"
[ -d "$complete" ] || fail 'completed installation was modified during detection'

target="$WORK_DIR/atomic target"
mkdir -- "$target"
stage=
_install_create_stage "$target" stage || fail 'could not create installation stage'
make_layout "$stage"
_install_finalize_stage "$stage" "$target" || fail 'could not atomically commit installation stage'
[ ! -e "$stage" ] || fail 'stage still exists after atomic commit'
_install_marker_validate "$target" || fail 'committed installation marker is invalid'
_install_layout_is_trusted "$target" || fail 'committed installation layout is untrusted'
_INSTALL_TARGET_HOME=$target
_INSTALL_HOME_STATE=resume
_INSTALL_INCOMPLETE_SUMMARY_SHOWN=0
_install_report_incomplete_home >"$WORK_DIR/incomplete.stdout" 2>"$WORK_DIR/incomplete.stderr"
[ ! -s "$WORK_DIR/incomplete.stdout" ] || fail 'incomplete-install summary wrote to stdout'
grep -Fqs '本次未能完成安装，目录和已有数据已保留' "$WORK_DIR/incomplete.stderr" ||
    fail 'trusted incomplete directory did not receive a failure summary'
grep -Fqs "保留: $target" "$WORK_DIR/incomplete.stderr" ||
    fail 'incomplete-install summary omitted the retained directory'
grep -Fqs '继续安装' "$WORK_DIR/incomplete.stderr" ||
    fail 'incomplete-install summary omitted retry guidance'

: >"$target/.env"
_INSTALL_INCOMPLETE_SUMMARY_SHOWN=0
_install_report_incomplete_home >"$WORK_DIR/complete-summary.stdout" \
    2>"$WORK_DIR/complete-summary.stderr"
[ ! -s "$WORK_DIR/complete-summary.stderr" ] ||
    fail 'completed installation was described as resumable'
/usr/bin/rm -f -- "$target/.env"

chmod g+w -- "$target"
_INSTALL_INCOMPLETE_SUMMARY_SHOWN=0
_install_report_incomplete_home >"$WORK_DIR/untrusted-summary.stdout" \
    2>"$WORK_DIR/untrusted-summary.stderr"
[ ! -s "$WORK_DIR/untrusted-summary.stderr" ] ||
    fail 'untrusted incomplete directory received retry guidance'
chmod g-w -- "$target"
export CLASHCTL_INSTALL_SESSION=1
_install_validate_home_path "$target" "$target" || fail 'marked second-stage installation was rejected'
unset CLASHCTL_INSTALL_SESSION

git_target="$WORK_DIR/git target"
git_stage=
_install_create_stage "$git_target" git_stage || fail 'could not create Git installation stage'
git clone -q "$REPO_DIR" "$git_stage" || fail 'Git could not clone into the empty staging directory'
_install_finalize_stage "$git_stage" "$git_target" || fail 'could not commit staged Git installation'
_install_marker_validate "$git_target" || fail 'staged Git installation marker is invalid'

printf 'install-home-safety: ok\n'
