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

make_archive_tree() {
    local root=$1 path

    for path in "${_UPDATE_ARCHIVE_REQUIRED_FILES[@]}"; do
        mkdir -p -- "$(dirname -- "$root/$path")"
        printf '# archive fixture: %s\n' "$path" >"$root/$path"
    done
    printf 'clashctl() { :; }\n' >"$root/scripts/cmd/clashctl.sh"
}

valid_archive_tree="$WORK_DIR/archive-valid"
make_archive_tree "$valid_archive_tree"
run_cmd archive_valid _update_validate_archive_tree "$valid_archive_tree"
assert_eq 0 "$RUN_RC" 'complete archive tree exit code'

missing_loader_tree="$WORK_DIR/archive-missing-loader"
make_archive_tree "$missing_loader_tree"
/usr/bin/rm -f -- "$missing_loader_tree/scripts/cmd/clashctl.sh"
run_cmd archive_missing_loader_tree _update_validate_archive_tree "$missing_loader_tree"
assert_eq 1 "$RUN_RC" 'archive without loader exit code'
assert_contains "$RUN_STDERR" 'scripts/cmd/clashctl.sh' \
    'archive without loader diagnosis'

empty_loader_tree="$WORK_DIR/archive-empty-loader"
make_archive_tree "$empty_loader_tree"
: >"$empty_loader_tree/scripts/cmd/clashctl.sh"
run_cmd archive_empty_loader_tree _update_validate_archive_tree "$empty_loader_tree"
assert_eq 1 "$RUN_RC" 'archive with empty loader exit code'
assert_contains "$RUN_STDERR" '为空' 'archive with empty loader diagnosis'

directory_resource_tree="$WORK_DIR/archive-directory-resource"
make_archive_tree "$directory_resource_tree"
/usr/bin/rm -f -- "$directory_resource_tree/resources/Country.mmdb"
mkdir -- "$directory_resource_tree/resources/Country.mmdb"
run_cmd archive_directory_resource_tree \
    _update_validate_archive_tree "$directory_resource_tree"
assert_eq 1 "$RUN_RC" 'archive with a directory in place of a resource exit code'
assert_contains "$RUN_STDERR" '类型无效' 'archive directory resource diagnosis'

missing_update_lib_tree="$WORK_DIR/archive-missing-update-lib"
make_archive_tree "$missing_update_lib_tree"
/usr/bin/rm -f -- "$missing_update_lib_tree/scripts/lib/update.sh"
run_cmd archive_missing_update_lib_tree _update_validate_archive_tree "$missing_update_lib_tree"
assert_eq 1 "$RUN_RC" 'archive without update library exit code'
assert_contains "$RUN_STDERR" 'scripts/lib/update.sh' \
    'archive without update library diagnosis'

missing_operation_lock_tree="$WORK_DIR/archive-missing-operation-lock"
make_archive_tree "$missing_operation_lock_tree"
/usr/bin/rm -f -- "$missing_operation_lock_tree/scripts/lib/operation-lock.sh"
run_cmd archive_missing_operation_lock_tree \
    _update_validate_archive_tree "$missing_operation_lock_tree"
assert_eq 1 "$RUN_RC" 'archive without operation lock exit code'
assert_contains "$RUN_STDERR" 'scripts/lib/operation-lock.sh' \
    'archive without operation lock diagnosis'

invalid_archive_tree="$WORK_DIR/archive-invalid-syntax"
make_archive_tree "$invalid_archive_tree"
printf 'broken() {\n' >"$invalid_archive_tree/scripts/lib/common.sh"
run_cmd archive_invalid_syntax _update_validate_archive_tree "$invalid_archive_tree"
assert_eq 1 "$RUN_RC" 'archive with invalid shell syntax exit code'
assert_contains "$RUN_STDERR" '更新脚本语法校验失败' \
    'archive with invalid shell syntax diagnosis'

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
    _update_verify_commit() { return 0; }
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

archive_incomplete_home="$WORK_DIR/archive-incomplete-home"
mkdir -p -- "$archive_incomplete_home/scripts/cmd"
old_archive_rev=1111111111111111111111111111111111111111
new_archive_rev=2222222222222222222222222222222222222222
printf 'CLASHCTL_REV=%s\n' "$old_archive_rev" >"$archive_incomplete_home/.env"
printf 'old-loader\n' >"$archive_incomplete_home/scripts/cmd/clashctl.sh"
printf 'old-install\n' >"$archive_incomplete_home/install.sh"
printf 'old-uninstall\n' >"$archive_incomplete_home/uninstall.sh"
printf 'old-script\n' >"$archive_incomplete_home/scripts/sentinel.sh"
CLASHCTL_HOME=$archive_incomplete_home
_update_remote_sha() { printf '%s\n' "$new_archive_rev"; }
_update_check_env() { return 0; }
_update_acquire_lock() { return 0; }
_update_release_lock() { return 0; }
_update_capture_state() { _UPDATE_WAS_ACTIVE=false; }
_update_fetch_archive() {
    local _branch=$1 destination=$2
    mkdir -p -- "$destination/scripts"
    printf 'new-install\n' >"$destination/install.sh"
    printf 'new-uninstall\n' >"$destination/uninstall.sh"
    printf 'new-script\n' >"$destination/scripts/sentinel.sh"
}
archive_backup_marker="$WORK_DIR/archive-incomplete-backup-called"
archive_side_effect_marker="$WORK_DIR/archive-incomplete-side-effect-called"
_update_archive_backup() {
    : >"$archive_backup_marker"
    printf '%s\n' "$WORK_DIR/archive-incomplete-backup.tar.gz"
}
_update_side_effects() {
    : >"$archive_side_effect_marker"
    return 0
}
run_cmd archive_incomplete clashupdate_archive false true master
assert_eq 1 "$RUN_RC" 'incomplete archive exit code'
assert_eq old-loader "$(<"$archive_incomplete_home/scripts/cmd/clashctl.sh")" \
    'incomplete archive preserves installed loader'
assert_eq old-install "$(<"$archive_incomplete_home/install.sh")" \
    'incomplete archive preserves installed install script'
assert_eq old-script "$(<"$archive_incomplete_home/scripts/sentinel.sh")" \
    'incomplete archive preserves installed scripts'
assert_eq "CLASHCTL_REV=$old_archive_rev" "$(<"$archive_incomplete_home/.env")" \
    'incomplete archive preserves installed revision'
[ ! -e "$archive_backup_marker" ] || fail 'incomplete archive created a backup before validation'
[ ! -e "$archive_side_effect_marker" ] || fail 'incomplete archive ran update side effects'
assert_contains "$RUN_STDERR" '更新归档不完整' 'incomplete archive diagnosis'

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
_update_validate_archive_tree() { return 0; }
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
