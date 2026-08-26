#!/usr/bin/env bash
# shellcheck disable=SC2317  # Test doubles are invoked indirectly by sourced command functions.
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
    local value=$1 expected=$2 description=$3
    case $value in
    *"$expected"*) ;;
    *) fail "$description: missing [$expected]" ;;
    esac
}

assert_not_contains() {
    local value=$1 unexpected=$2 description=$3
    case $value in
    *"$unexpected"*) fail "$description: unexpectedly contained [$unexpected]" ;;
    *) ;;
    esac
}

RUN_RC=0 RUN_STDOUT='' RUN_STDERR=''
run_cmd() {
    local label=$1
    shift
    set +e
    "$@" >"$WORK_DIR/$label.stdout" 2>"$WORK_DIR/$label.stderr"
    RUN_RC=$?
    set -e
    RUN_STDOUT=$(<"$WORK_DIR/$label.stdout")
    RUN_STDERR=$(<"$WORK_DIR/$label.stderr")
}

CLASHCTL_HOME="$WORK_DIR/install"
CLASHCTL_KERNEL=mihomo
CLASHCTL_COLOR=never
CI=1
export CLASHCTL_HOME CLASHCTL_KERNEL CLASHCTL_COLOR CI

# shellcheck source=../scripts/lib/common.sh
. "$REPO_DIR/scripts/lib/common.sh"
# shellcheck source=../scripts/lib/update.sh
. "$REPO_DIR/scripts/lib/update.sh"
# shellcheck source=../scripts/cmd/update.sh
. "$REPO_DIR/scripts/cmd/update.sh"

install_checks=0
dispatches=0
_update_require_install() {
    install_checks=$((install_checks + 1))
}
operation_lock_acquire() { return 0; }
operation_lock_close_fd() { return 0; }
_update_is_git_home() { return 0; }
clashupdate_git() {
    dispatches=$((dispatches + 1))
}

run_cmd control_argument clashupdate $'--force\nforged-output'
assert_eq 1 "$RUN_RC" 'control character argument exit code'
assert_eq 0 "$install_checks" 'control argument rejected before install check'
assert_eq 0 "$dispatches" 'control argument rejected before dispatch'
assert_contains "$RUN_STDERR" '更新参数不能包含' 'control argument diagnosis'
assert_not_contains "$RUN_STDERR" 'forged-output' 'control argument is not echoed'

CLASHCTL_UPDATE_BRANCH=$'main\tforged-branch'
run_cmd control_env_branch clashupdate --check
unset CLASHCTL_UPDATE_BRANCH
assert_eq 1 "$RUN_RC" 'control character environment branch exit code'
assert_eq 0 "$install_checks" 'environment branch rejected before install check'
assert_not_contains "$RUN_STDERR" 'forged-branch' 'environment branch is not echoed'

run_cmd control_cli_branch clashupdate --branch $'main\033forged-cli'
assert_eq 1 "$RUN_RC" 'control character CLI branch exit code'
assert_eq 0 "$dispatches" 'CLI branch rejected before dispatch'
assert_not_contains "$RUN_STDERR" 'forged-cli' 'CLI branch is not echoed'

_update_require_install() { return 0; }
clashupdate_git() {
    _UPDATE_TERMINAL_RESULT='更新完成'
    return 0
}
operation_lock_close_fd() { return 1; }
run_cmd lifecycle_close_failure clashupdate --check
assert_eq 1 "$RUN_RC" 'lifecycle lock close failure exit code'
assert_contains "$RUN_STDERR" '无法关闭生命周期锁' 'lifecycle lock close diagnosis'
assert_not_contains "$RUN_STDOUT" '更新完成' 'lock close failure suppresses terminal completion'

operation_lock_close_fd() { return 0; }
run_cmd lifecycle_close_success clashupdate --check
assert_eq 0 "$RUN_RC" 'lifecycle lock close success exit code'
assert_contains "$RUN_STDOUT" '[ OK ] 更新完成' 'completion follows successful lock close'

# Restore the production update functions after the dispatch stubs above.
. "$REPO_DIR/scripts/lib/update.sh"
. "$REPO_DIR/scripts/cmd/update.sh"

CLASH_RESOURCES_DIR="$WORK_DIR/resources"
CLASH_DATA_DIR="$WORK_DIR/data"
mkdir -p -- "$CLASH_RESOURCES_DIR" "$CLASH_DATA_DIR"
printf 'template\n' >"$CLASH_RESOURCES_DIR/new.yaml.example"
cp() { return 1; }
run_cmd data_copy_failure _update_data_refresh
unset -f cp
assert_eq 1 "$RUN_RC" 'template copy failure exit code'
assert_not_contains "$RUN_STDOUT" '新增配置模板' 'failed template copy has no success output'

invalid_tree="$WORK_DIR/invalid-tree"
mkdir -p -- "$invalid_tree/scripts/cmd" "$invalid_tree/scripts/lib"
printf 'clashctl() { :; }\n' >"$invalid_tree/scripts/cmd/clashctl.sh"
printf 'broken() {\n' >"$invalid_tree/scripts/lib/broken.sh"
run_cmd invalid_tree _update_validate_tree "$invalid_tree"
assert_eq 1 "$RUN_RC" 'invalid update tree exit code'
assert_contains "$RUN_STDERR" '更新脚本语法校验失败' 'invalid update tree diagnosis'

unloadable_tree="$WORK_DIR/unloadable-tree"
mkdir -p -- "$unloadable_tree/scripts/cmd"
printf 'return 1\n' >"$unloadable_tree/scripts/cmd/clashctl.sh"
saved_home=$CLASHCTL_HOME
CLASHCTL_HOME=$unloadable_tree
run_cmd unloadable_tree _update_validate_tree "$unloadable_tree"
CLASHCTL_HOME=$saved_home
assert_eq 1 "$RUN_RC" 'unloadable update tree exit code'
assert_contains "$RUN_STDERR" '命令模块无法完整加载' 'unloadable update tree diagnosis'

failure_stage=''
side_effect_calls=''
_UPDATE_WAS_ACTIVE=false
_update_validate_tree() { [ "$failure_stage" != tree ]; }
_update_env_refresh() { [ "$failure_stage" != env ]; }
_update_data_refresh() {
    side_effect_calls="${side_effect_calls}data "
    [ "$failure_stage" != data ]
}
_update_unit_refresh() {
    side_effect_calls="${side_effect_calls}unit "
    [ "$failure_stage" != unit ]
}
_update_runtime_refresh() {
    side_effect_calls="${side_effect_calls}runtime "
    [ "$failure_stage" != runtime ]
}
_update_rc_refresh() {
    side_effect_calls="${side_effect_calls}rc "
    [ "$failure_stage" != rc ]
}
for failure_stage in tree env data unit runtime rc; do
    side_effect_calls=''
    run_cmd "side_effect_$failure_stage" _update_side_effects
    assert_eq 1 "$RUN_RC" "$failure_stage side effect failure exit code"
    if [ "$failure_stage" = env ]; then
        assert_eq '' "$side_effect_calls" 'side effect chain stops after environment failure'
        assert_contains "$RUN_STDERR" '无法补充新版本所需的环境配置项' \
            'environment side effect diagnosis'
    fi
done

make_git_repo() {
    local repo=$1 reload_result=$2

    mkdir -p -- "$repo/scripts/cmd"
    git -C "$repo" init -q
    git -C "$repo" config user.email test@example.invalid
    git -C "$repo" config user.name test
    printf 'old\n' >"$repo/version"
    printf 'return 0\n' >"$repo/scripts/cmd/clashctl.sh"
    git -C "$repo" add .
    git -C "$repo" commit -qm old
    OLD_SHA=$(git -C "$repo" rev-parse HEAD)
    printf 'new\n' >"$repo/version"
    printf 'return %s\n' "$reload_result" >"$repo/scripts/cmd/clashctl.sh"
    git -C "$repo" add .
    git -C "$repo" commit -qm new
    NEW_SHA=$(git -C "$repo" rev-parse HEAD)
    git -C "$repo" checkout -q "$OLD_SHA"
}

prepare_git_update_stubs() {
    _update_local_rev() { printf '%s\n' "${OLD_SHA:0:7}"; }
    _update_fetch() { printf '%s\n' "$NEW_SHA"; }
    _update_status() { printf 'behind 1\n'; }
    _update_dirty() { return 1; }
    _update_check_env() { return 0; }
    _update_acquire_lock() { return 0; }
    _update_release_lock() { return 0; }
    _update_capture_state() { _UPDATE_WAS_ACTIVE=false; }
}

git_repo="$WORK_DIR/git-recovery"
make_git_repo "$git_repo" 0
CLASHCTL_HOME=$git_repo
CLASH_CONFIG_MIXIN="$git_repo/missing-mixin.yaml"
CLASH_RESOURCES_DIR="$git_repo/resources"
prepare_git_update_stubs
_update_status() { return 1; }
run_cmd git_status_probe_failure clashupdate_git false false master
assert_eq 1 "$RUN_RC" 'git status probe failure exit code'
assert_contains "$RUN_STDERR" '无法比较本地与远端版本' 'git status probe diagnosis'
assert_eq "$OLD_SHA" "$(git -C "$git_repo" rev-parse HEAD)" 'status probe failure does not deploy'

prepare_git_update_stubs
_update_dirty() { return 2; }
run_cmd git_dirty_probe_failure clashupdate_git false false master
assert_eq 1 "$RUN_RC" 'git dirty probe failure exit code'
assert_contains "$RUN_STDERR" '无法检查本地文件修改' 'git dirty probe diagnosis'
assert_eq "$OLD_SHA" "$(git -C "$git_repo" rev-parse HEAD)" 'dirty probe failure does not deploy'

prepare_git_update_stubs
side_effect_run=0
_update_side_effects() {
    side_effect_run=$((side_effect_run + 1))
    [ "$side_effect_run" -gt 1 ]
}
run_cmd git_recovery clashupdate_git false false master
assert_eq 1 "$RUN_RC" 'git side effect failure exit code'
assert_eq "$OLD_SHA" "$(git -C "$git_repo" rev-parse HEAD)" 'git failure restores original revision'
assert_contains "$RUN_STDERR" '代码已恢复到' 'git recovery result'
assert_contains "$RUN_STDERR" '[STEP] 检查远端版本：master' 'git fetch step feedback'
assert_contains "$RUN_STDERR" '[STEP] 部署更新：' 'git deployment step feedback'
assert_not_contains "$RUN_STDOUT" '更新完成' 'recovered git failure has no completion output'

side_effect_run=0
_update_side_effects() { return 1; }
run_cmd git_incomplete_recovery clashupdate_git false false master
assert_eq 1 "$RUN_RC" 'incomplete git recovery exit code'
assert_eq "$OLD_SHA" "$(git -C "$git_repo" rev-parse HEAD)" 'incomplete recovery still restores git revision'
assert_contains "$RUN_STDERR" '自动恢复不完整' 'incomplete git recovery diagnosis'
assert_not_contains "$RUN_STDOUT" '更新完成' 'incomplete git recovery has no completion output'

git_reload_repo="$WORK_DIR/git-reload"
make_git_repo "$git_reload_repo" 1
CLASHCTL_HOME=$git_reload_repo
CLASH_CONFIG_MIXIN="$git_reload_repo/missing-mixin.yaml"
CLASH_RESOURCES_DIR="$git_reload_repo/resources"
prepare_git_update_stubs
_update_side_effects() { return 0; }
run_cmd git_reload_failure clashupdate_git false false master
assert_eq 1 "$RUN_RC" 'current shell reload failure exit code'
assert_eq "$NEW_SHA" "$(git -C "$git_reload_repo" rev-parse HEAD)" 'reload failure leaves deployed revision'
assert_contains "$RUN_STDERR" '已写入磁盘，但当前 Shell 重新加载失败' 'reload failure diagnosis'
assert_not_contains "$RUN_STDOUT" '更新完成' 'reload failure has no completion output'

archive_home="$WORK_DIR/archive-home"
mkdir -p -- "$archive_home"
old_rev=1111111111111111111111111111111111111111
new_rev=2222222222222222222222222222222222222222
printf 'CLASHCTL_REV=%s\n' "$old_rev" >"$archive_home/.env"
CLASHCTL_HOME=$archive_home
_UPDATE_ARCHIVE_PATHS=()
_update_remote_sha() { printf '%s\n' "$new_rev"; }
_update_check_env() { return 0; }
_update_acquire_lock() { return 0; }
_update_release_lock() { return 0; }
_update_capture_state() { _UPDATE_WAS_ACTIVE=false; }
_update_archive_backup() { printf '%s\n' "$WORK_DIR/archive-backup.tar.gz"; }
_update_fetch_archive() { return 0; }
_update_archive_restore() { return 0; }
_update_prune_backups() { return 0; }
side_effect_run=0
_update_side_effects() {
    side_effect_run=$((side_effect_run + 1))
    [ "$side_effect_run" -gt 1 ]
}
run_cmd archive_recovery clashupdate_archive false true master
assert_eq 1 "$RUN_RC" 'archive side effect failure exit code'
assert_contains "$(<"$archive_home/.env")" "CLASHCTL_REV=$old_rev" 'archive recovery restores revision record'
assert_contains "$RUN_STDERR" '代码已恢复到更新前版本' 'archive recovery result'
assert_not_contains "$RUN_STDOUT" '更新完成' 'recovered archive failure has no completion output'

printf 'update-ux: ok\n'
