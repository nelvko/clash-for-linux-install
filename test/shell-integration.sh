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

CLASHCTL_HOME="$WORK_DIR/install home"
CLASHCTL_SRC=$REPO_DIR
CLASHCTL_KERNEL=mihomo
export CLASHCTL_HOME CLASHCTL_SRC CLASHCTL_KERNEL
# shellcheck source=../scripts/preflight.sh
. "$REPO_DIR/scripts/preflight.sh"

CLASHCTL_CMD_DIR="$CLASHCTL_HOME/scripts/cmd"
mkdir -p -- "$CLASHCTL_CMD_DIR"
printf '%s\n' 'CLASHCTL_TEST_LOADED=1' >"$CLASHCTL_CMD_DIR/clashctl.sh"
printf '%s\n' '# fish completion fixture' >"$CLASHCTL_CMD_DIR/clashctl.fish"
export CLASHCTL_CMD_DIR CLASHCTL_COLOR=never

RC_MODE=none
detect_rc() {
    SHELL_RC_BASH=
    SHELL_RC_ZSH=
    SHELL_RC_FISH=
    case $RC_MODE in
    bash) SHELL_RC_BASH="$WORK_DIR/user/.bashrc" ;;
    fish) SHELL_RC_FISH="$WORK_DIR/user/fish/conf.d/clashctl.fish" ;;
    esac
    export SHELL_RC_BASH SHELL_RC_ZSH SHELL_RC_FISH
}

rc=0
apply_rc >"$WORK_DIR/manual.stdout" 2>"$WORK_DIR/manual.stderr" || rc=$?
assert_eq 2 "$rc" 'missing shell startup files use the manual-load status'
assert_eq 1 "${CLASHCTL_TEST_LOADED:-0}" 'manual mode still loads commands in the installer shell'

RC_MODE=bash
mkdir -p -- "$WORK_DIR/user"
printf '%s\n' 'export USER_SETTING=keep' >"$WORK_DIR/user/.bashrc"
apply_rc >"$WORK_DIR/bash.stdout" 2>"$WORK_DIR/bash.stderr"
apply_rc >"$WORK_DIR/bash-second.stdout" 2>"$WORK_DIR/bash-second.stderr"
assert_eq 1 "$(grep -Fc '# >>> clashctl >>>' "$WORK_DIR/user/.bashrc")" \
    'bash managed block remains idempotent'
grep -Fqs 'export USER_SETTING=keep' "$WORK_DIR/user/.bashrc" ||
    fail 'bash integration removed an unrelated setting'
bash -n "$WORK_DIR/user/.bashrc"

cat >"$WORK_DIR/user/.bashrc" <<'EOF'
export USER_SETTING=keep
# >>> clashctl >>>
incomplete=user-content
EOF
cp -p -- "$WORK_DIR/user/.bashrc" "$WORK_DIR/user/.bashrc.expected"
rc=0
apply_rc >"$WORK_DIR/incomplete.stdout" 2>"$WORK_DIR/incomplete.stderr" || rc=$?
assert_eq 1 "$rc" 'incomplete bash managed markers fail without rewriting the file'
cmp -s -- "$WORK_DIR/user/.bashrc.expected" "$WORK_DIR/user/.bashrc" ||
    fail 'incomplete bash managed block was modified'

RC_MODE=fish
apply_rc >"$WORK_DIR/fish.stdout" 2>"$WORK_DIR/fish.stderr"
fish_sum=$(sha256sum "$SHELL_RC_FISH")
apply_rc >"$WORK_DIR/fish-second.stdout" 2>"$WORK_DIR/fish-second.stderr"
assert_eq "$fish_sum" "$(sha256sum "$SHELL_RC_FISH")" 'unchanged fish integration is not rewritten'
assert_eq 644 "$(stat -c %a -- "$SHELL_RC_FISH")" 'fish integration permissions'

printf '%s\n' '# user-owned fish configuration' 'set -gx USER_SETTING keep' >"$SHELL_RC_FISH"
cp -p -- "$SHELL_RC_FISH" "$WORK_DIR/fish.expected"
rc=0
apply_rc >"$WORK_DIR/fish-foreign.stdout" 2>"$WORK_DIR/fish-foreign.stderr" || rc=$?
assert_eq 1 "$rc" 'non-managed fish configuration is not overwritten'
cmp -s -- "$WORK_DIR/fish.expected" "$SHELL_RC_FISH" ||
    fail 'non-managed fish configuration was modified'

rc=0
(
    RC_MODE=bash
    # shellcheck disable=SC2317  # apply_rc 间接调用该失败桩
    _append_source_block() { return 1; }
    apply_rc
) >"$WORK_DIR/write-failure.stdout" 2>"$WORK_DIR/write-failure.stderr" || rc=$?
assert_eq 1 "$rc" 'real shell write failures are not downgraded to manual mode'

printf '%s\n' 'return 1' >"$CLASHCTL_CMD_DIR/clashctl.sh"
RC_MODE=none
rc=0
apply_rc >"$WORK_DIR/load-failure.stdout" 2>"$WORK_DIR/load-failure.stderr" || rc=$?
assert_eq 1 "$rc" 'command loader failures are reported as real failures'

printf 'shell-integration: ok\n'
