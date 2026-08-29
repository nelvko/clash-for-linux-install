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

assert_absent() {
    if [ -e "$1" ] || [ -L "$1" ]; then
        fail "$2: still exists [$1]"
    fi
}

assert_mode() {
    local expected=$1 path=$2 description=$3 actual
    actual=$(stat -c %a -- "$path") || fail "$description: cannot stat [$path]"
    assert_eq "$expected" "$actual" "$description"
}

assert_owned_tree() {
    local root=$1 description=$2 foreign
    foreign=$(find "$root" ! -user "$(id -u)" -print -quit)
    [ -z "$foreign" ] || fail "$description: foreign-owned path [$foreign]"
}

assert_public_tree_modes() {
    local root=$1 description=$2 invalid
    invalid=$(find "$root" \
        \( \( -type d ! -perm 0755 \) -o \( -type f ! -perm 0644 \) \) \
        -print -quit)
    [ -z "$invalid" ] || fail "$description: unexpected mode on [$invalid]"
}

assert_no_stages() {
    local staged
    staged=$(find "$BIN_BASE_DIR" -maxdepth 1 -name '.components.*' -print -quit)
    [ -z "$staged" ] || fail "binary staging directory was retained: [$staged]"
    staged=$(find "$CLASH_RESOURCES_DIR" -maxdepth 1 -name '.web-ui.*' -print -quit)
    [ -z "$staged" ] || fail "Web UI staging directory was retained: [$staged]"
}

assert_external_untouched() {
    local root=$1 description=$2 unexpected

    assert_eq outside-unchanged "$(<"$root/sentinel")" "$description sentinel"
    assert_mode 700 "$root" "$description external directory mode"
    unexpected=$(find "$root" -mindepth 1 -maxdepth 1 ! -name sentinel -print -quit)
    [ -z "$unexpected" ] || fail "$description: unexpected external path [$unexpected]"
}

export CLASHCTL_SRC=$REPO_DIR
export CLASHCTL_HOME="$WORK_DIR/bootstrap"
export CLASHCTL_KERNEL=mihomo
export CLASHCTL_COLOR=never
mkdir -p -- "$CLASHCTL_HOME"

# shellcheck source=../scripts/preflight.sh
. "$REPO_DIR/scripts/preflight.sh"

ARCHIVE_DIR="$WORK_DIR/archives"
SOURCE_DIR="$WORK_DIR/archive-sources"
mkdir -p -- "$ARCHIVE_DIR" "$SOURCE_DIR"

printf 'new-kernel\n' >"$SOURCE_DIR/kernel"
gzip -c -- "$SOURCE_DIR/kernel" >"$ARCHIVE_DIR/kernel.gz"

mkdir -p -- "$SOURCE_DIR/yq"
printf 'new-yq\n' >"$SOURCE_DIR/yq/yq_linux_amd64"
printf 'manual page\n' >"$SOURCE_DIR/yq/yq.1"
printf '#!/bin/sh\n' >"$SOURCE_DIR/yq/install-man-page.sh"
chmod 0777 "$SOURCE_DIR/yq/yq_linux_amd64" "$SOURCE_DIR/yq/install-man-page.sh"
chmod 0666 "$SOURCE_DIR/yq/yq.1"
tar --create --gzip --file "$ARCHIVE_DIR/yq.tar.gz" --numeric-owner \
    --owner=1001 --group=1001 --directory "$SOURCE_DIR/yq" .

mkdir -p -- "$SOURCE_DIR/converter/subconverter/config"
printf 'new-converter\n' >"$SOURCE_DIR/converter/subconverter/subconverter"
printf 'server:\n  port: 25500\n' >"$SOURCE_DIR/converter/subconverter/pref.example.yml"
printf 'fresh-rule\n' >"$SOURCE_DIR/converter/subconverter/config/fresh.ini"
chmod -R 0777 "$SOURCE_DIR/converter/subconverter"
tar --create --gzip --file "$ARCHIVE_DIR/subconverter.tar.gz" --numeric-owner \
    --owner=1001 --group=1001 --directory "$SOURCE_DIR/converter" .

mkdir -p -- "$SOURCE_DIR/ui/dist/assets"
printf '<html>new-ui</html>\n' >"$SOURCE_DIR/ui/dist/index.html"
printf 'new-assets\n' >"$SOURCE_DIR/ui/dist/assets/app.js"
chmod -R 0777 "$SOURCE_DIR/ui/dist"
tar --create --gzip --file "$ARCHIVE_DIR/ui.zip" --numeric-owner \
    --owner=1001 --group=1001 --directory "$SOURCE_DIR/ui" .

mkdir -p -- "$SOURCE_DIR/invalid/subconverter"
printf 'invalid-converter\n' >"$SOURCE_DIR/invalid/subconverter/subconverter"
chmod 0777 "$SOURCE_DIR/invalid/subconverter/subconverter"
tar --create --gzip --file "$ARCHIVE_DIR/subconverter-invalid.tar.gz" --numeric-owner \
    --owner=1001 --group=1001 --directory "$SOURCE_DIR/invalid" .

printf 'unsafe-member\n' >"$SOURCE_DIR/extraction-failure"
tar --create --gzip --file "$ARCHIVE_DIR/subconverter-extraction-failure.tar.gz" \
    --transform='s|^extraction-failure$|../extraction-failure|' \
    --directory "$SOURCE_DIR" extraction-failure

tar --numeric-owner --list --verbose --file "$ARCHIVE_DIR/yq.tar.gz" |
    grep -E '1001/1001' >/dev/null ||
    fail 'synthetic yq archive does not contain numeric owner 1001:1001'
tar --numeric-owner --list --verbose --file "$ARCHIVE_DIR/subconverter.tar.gz" |
    grep -E '1001/1001' >/dev/null ||
    fail 'synthetic subconverter archive does not contain numeric owner 1001:1001'
tar --numeric-owner --list --verbose --file "$ARCHIVE_DIR/ui.zip" |
    grep -E '1001/1001' >/dev/null ||
    fail 'synthetic Web UI archive does not contain numeric owner 1001:1001'

# `unzip_zip`（已 source）通过这些全局变量读取测试归档。
# shellcheck disable=SC2034
ZIP_KERNEL="$ARCHIVE_DIR/kernel.gz"
# shellcheck disable=SC2034
ZIP_YQ="$ARCHIVE_DIR/yq.tar.gz"
# shellcheck disable=SC2034
ZIP_SUBCONVERTER="$ARCHIVE_DIR/subconverter.tar.gz"
# shellcheck disable=SC2034
ZIP_UI="$ARCHIVE_DIR/ui.zip"

archive_link="$WORK_DIR/archive-link.tar.gz"
ln -s "$ARCHIVE_DIR/yq.tar.gz" "$archive_link"
if _archive_is_valid "$archive_link"; then
    fail 'archive cache accepted a symlink file'
fi

guard_root="$WORK_DIR/directory-guards"
mkdir -p -- "$guard_root"

archives_home="$guard_root/archives-home"
archives_external="$guard_root/archives-external"
mkdir -p -- "$archives_home" "$archives_external"
chmod 0700 "$archives_external"
printf 'outside-unchanged\n' >"$archives_external/sentinel"
ln -s "$archives_external" "$archives_home/archives"
# shellcheck disable=SC2034
ZIP_BASE_DIR="$archives_home/archives"
rc=0
download_zip yq >"$guard_root/archives.stdout" 2>"$guard_root/archives.stderr" || rc=$?
assert_eq 1 "$rc" 'symlink archive directory rejection status'
assert_contains "$guard_root/archives.stderr" '依赖缓存目录无法安全使用' \
    'symlink archive directory diagnostic'
assert_external_untouched "$archives_external" 'symlink archive directory rejection'

bin_home="$guard_root/bin-home"
bin_external="$guard_root/bin-external"
mkdir -p -- "$bin_home/resources" "$bin_external"
chmod 0700 "$bin_external"
printf 'outside-unchanged\n' >"$bin_external/sentinel"
ln -s "$bin_external" "$bin_home/bin"
CLASHCTL_HOME=$bin_home
BIN_BASE_DIR="$bin_home/bin"
BIN_KERNEL="$BIN_BASE_DIR/mihomo/mihomo"
BIN_YQ="$BIN_BASE_DIR/yq"
BIN_SUBCONVERTER_DIR="$BIN_BASE_DIR/subconverter"
BIN_SUBCONVERTER="$BIN_SUBCONVERTER_DIR/subconverter"
BIN_SUBCONVERTER_CONFIG="$BIN_SUBCONVERTER_DIR/pref.yml"
CLASH_RESOURCES_DIR="$bin_home/resources"
rc=0
unzip_zip >"$guard_root/bin.stdout" 2>"$guard_root/bin.stderr" || rc=$?
assert_eq 1 "$rc" 'symlink component directory rejection status'
assert_contains "$guard_root/bin.stderr" '运行组件目录无法安全使用' \
    'symlink component directory diagnostic'
assert_external_untouched "$bin_external" 'symlink component directory rejection'

resources_home="$guard_root/resources-home"
resources_external="$guard_root/resources-external"
mkdir -p -- "$resources_home/bin" "$resources_external"
chmod 0700 "$resources_external"
printf 'outside-unchanged\n' >"$resources_external/sentinel"
ln -s "$resources_external" "$resources_home/resources"
CLASHCTL_HOME=$resources_home
BIN_BASE_DIR="$resources_home/bin"
BIN_KERNEL="$BIN_BASE_DIR/mihomo/mihomo"
BIN_YQ="$BIN_BASE_DIR/yq"
BIN_SUBCONVERTER_DIR="$BIN_BASE_DIR/subconverter"
BIN_SUBCONVERTER="$BIN_SUBCONVERTER_DIR/subconverter"
BIN_SUBCONVERTER_CONFIG="$BIN_SUBCONVERTER_DIR/pref.yml"
CLASH_RESOURCES_DIR="$resources_home/resources"
rc=0
unzip_zip >"$guard_root/resources.stdout" 2>"$guard_root/resources.stderr" || rc=$?
assert_eq 1 "$rc" 'symlink resource directory rejection status'
assert_contains "$guard_root/resources.stderr" '资源目录无法安全使用' \
    'symlink resource directory diagnostic'
assert_external_untouched "$resources_external" 'symlink resource directory rejection'

# 后续缓存废弃测试中的归档均由安装器管理。
# shellcheck disable=SC2034
ZIP_BASE_DIR=$ARCHIVE_DIR

outside_cache="$WORK_DIR/outside-cache.tar.gz"
printf 'outside-cache\n' >"$outside_cache"
rc=0
_managed_cache_file_discard "$outside_cache" || rc=$?
assert_eq 2 "$rc" 'outside cache discard rejection status'
assert_eq outside-cache "$(<"$outside_cache")" 'outside cache discard rejection'

linked_cache="$ARCHIVE_DIR/linked-cache.tar.gz"
ln -s "$outside_cache" "$linked_cache"
rc=0
_managed_cache_file_discard "$linked_cache" || rc=$?
assert_eq 2 "$rc" 'symlink cache discard rejection status'
[ -L "$linked_cache" ] || fail 'symlink cache discard removed the managed link'
assert_eq outside-cache "$(<"$outside_cache")" 'symlink cache discard target preservation'

if [ "$(id -u)" -eq 0 ]; then
    foreign_cache="$ARCHIVE_DIR/foreign-cache.tar.gz"
    printf 'foreign-cache\n' >"$foreign_cache"
    chown 1001:1001 -- "$foreign_cache"
    rc=0
    _managed_cache_file_discard "$foreign_cache" || rc=$?
    assert_eq 2 "$rc" 'foreign-owned cache discard rejection status'
    assert_eq foreign-cache "$(<"$foreign_cache")" 'foreign-owned cache preservation'
fi

configure_home() {
    CLASHCTL_HOME="$WORK_DIR/$1/home"
    BIN_BASE_DIR="$CLASHCTL_HOME/bin"
    BIN_KERNEL="$BIN_BASE_DIR/mihomo/mihomo"
    BIN_YQ="$BIN_BASE_DIR/yq"
    BIN_SUBCONVERTER_DIR="$BIN_BASE_DIR/subconverter"
    BIN_SUBCONVERTER="$BIN_SUBCONVERTER_DIR/subconverter"
    BIN_SUBCONVERTER_CONFIG="$BIN_SUBCONVERTER_DIR/pref.yml"
    CLASH_RESOURCES_DIR="$CLASHCTL_HOME/resources"
    mkdir -p -- "$BIN_BASE_DIR/mihomo" "$BIN_SUBCONVERTER_DIR" "$CLASH_RESOURCES_DIR/dist"
}

seed_existing_components() {
    printf 'old-kernel\n' >"$BIN_KERNEL"
    printf 'old-yq\n' >"$BIN_YQ"
    printf 'legacy-manpage\n' >"$BIN_BASE_DIR/yq.1"
    printf 'legacy-installer\n' >"$BIN_BASE_DIR/install-man-page.sh"
    printf 'old-converter\n' >"$BIN_SUBCONVERTER"
    printf 'old-config\n' >"$BIN_SUBCONVERTER_CONFIG"
    printf 'stale-rule\n' >"$BIN_SUBCONVERTER_DIR/stale.ini"
    printf '<html>old-ui</html>\n' >"$CLASH_RESOURCES_DIR/dist/index.html"
    printf 'stale-ui\n' >"$CLASH_RESOURCES_DIR/dist/stale.js"
    chmod 0755 "$BIN_KERNEL" "$BIN_YQ" "$BIN_SUBCONVERTER"
    chmod 0600 "$BIN_SUBCONVERTER_CONFIG"

    if [ "$(id -u)" -eq 0 ]; then
        chown -R 1001:1001 -- "$BIN_SUBCONVERTER_DIR" "$CLASH_RESOURCES_DIR/dist"
        chown 1001:1001 -- "$BIN_YQ" "$BIN_BASE_DIR/yq.1" \
            "$BIN_BASE_DIR/install-man-page.sh"
        assert_eq 1001 "$(stat -c %u -- "$BIN_SUBCONVERTER_DIR")" \
            'foreign-owned existing converter test precondition'
    fi
}

configure_home replace
seed_existing_components
stdout_file="$WORK_DIR/replace.stdout"
stderr_file="$WORK_DIR/replace.stderr"
unzip_zip >"$stdout_file" 2>"$stderr_file" ||
    fail "component installation failed: $(<"$stderr_file")"

assert_eq new-kernel "$(<"$BIN_KERNEL")" 'kernel replacement'
assert_eq new-yq "$(<"$BIN_YQ")" 'yq replacement'
assert_eq new-converter "$(<"$BIN_SUBCONVERTER")" 'subconverter replacement'
assert_eq fresh-rule "$(<"$BIN_SUBCONVERTER_DIR/config/fresh.ini")" \
    'subconverter archive content'
assert_eq '<html>new-ui</html>' "$(<"$CLASH_RESOURCES_DIR/dist/index.html")" \
    'Web UI tar fallback content'
assert_absent "$BIN_BASE_DIR/yq.1" 'legacy yq manual cleanup'
assert_absent "$BIN_BASE_DIR/install-man-page.sh" 'legacy yq installer cleanup'
assert_absent "$BIN_SUBCONVERTER_DIR/stale.ini" 'stale subconverter cleanup'
assert_absent "$CLASH_RESOURCES_DIR/dist/stale.js" 'stale Web UI cleanup'

assert_owned_tree "$BIN_KERNEL" 'kernel ownership'
assert_owned_tree "$BIN_YQ" 'yq ownership'
assert_owned_tree "$BIN_SUBCONVERTER_DIR" 'subconverter ownership'
assert_owned_tree "$CLASH_RESOURCES_DIR/dist" 'Web UI ownership'
assert_mode 755 "$BIN_KERNEL" 'kernel mode'
assert_mode 755 "$BIN_YQ" 'yq mode'
assert_mode 755 "$BIN_SUBCONVERTER_DIR" 'subconverter directory mode'
assert_mode 755 "$BIN_SUBCONVERTER" 'subconverter executable mode'
assert_mode 600 "$BIN_SUBCONVERTER_CONFIG" 'subconverter runtime config mode'
assert_mode 644 "$BIN_SUBCONVERTER_DIR/config/fresh.ini" 'subconverter data mode'
assert_public_tree_modes "$CLASH_RESOURCES_DIR/dist" 'Web UI modes'
assert_no_stages
assert_contains "$stderr_file" '运行组件已安装' 'successful component installation output'

rollback_root="$WORK_DIR/replace-rollback"
rollback_target="$rollback_root/subconverter"
rollback_stage="$rollback_root/.stage"
mkdir -p -- "$rollback_target" "$rollback_stage/candidate"
printf 'old-after-rollback\n' >"$rollback_target/version"
printf 'rejected-candidate\n' >"$rollback_stage/candidate/version"
if [ "$(id -u)" -eq 0 ]; then
    chown -R 1001:1001 -- "$rollback_target"
fi
reject_component() { return 1; }
_component_transaction_init
rc=0
_component_replace_path "$rollback_stage/candidate" "$rollback_target" \
    "$rollback_stage/previous" reject_component || rc=$?
assert_eq 1 "$rc" 'failed final verification status'
assert_eq old-after-rollback "$(<"$rollback_target/version")" \
    'failed final verification restored previous component'
assert_absent "$rollback_stage/previous" 'component rollback backup cleanup'

transaction_root="$WORK_DIR/batch-rollback"
transaction_stage="$transaction_root/.stage"
mkdir -p -- "$transaction_stage"
for component in kernel yq subconverter ui; do
    printf 'old-%s\n' "$component" >"$transaction_root/$component"
    printf 'new-%s\n' "$component" >"$transaction_stage/$component.candidate"
    chmod 0600 "$transaction_root/$component" "$transaction_stage/$component.candidate"
done
printf 'legacy-yq-file\n' >"$transaction_root/yq.1"
_component_transaction_init
for component in kernel yq subconverter; do
    _component_replace_path "$transaction_stage/$component.candidate" \
        "$transaction_root/$component" "$transaction_stage/$component.previous" \
        _component_file_is_safe 600 || fail "batch setup failed for $component"
done
_component_remove_path "$transaction_root/yq.1" "$transaction_stage/yq.1.previous" ||
    fail 'batch setup failed for legacy yq removal'
rc=0
_component_replace_path "$transaction_stage/ui.candidate" "$transaction_root/ui" \
    "$transaction_stage/ui.previous" reject_component || rc=$?
assert_eq 1 "$rc" 'late component commit failure status'
assert_eq new-kernel "$(<"$transaction_root/kernel")" \
    'late failure reached the partially committed state'
_component_cleanup_stages "$transaction_stage" '' || fail 'batch component rollback failed'
for component in kernel yq subconverter ui; do
    assert_eq "old-$component" "$(<"$transaction_root/$component")" \
        "late failure restored $component"
done
assert_eq legacy-yq-file "$(<"$transaction_root/yq.1")" \
    'late failure restored legacy yq file'

retry_root="$WORK_DIR/retry-rollback"
retry_stage="$retry_root/.stage"
mkdir -p -- "$retry_stage"
for component in kernel yq ui; do
    printf 'old-%s\n' "$component" >"$retry_root/$component"
    printf 'new-%s\n' "$component" >"$retry_stage/$component.candidate"
    chmod 0600 "$retry_root/$component" "$retry_stage/$component.candidate"
done
_component_transaction_init
for component in kernel yq ui; do
    _component_replace_path "$retry_stage/$component.candidate" \
        "$retry_root/$component" "$retry_stage/$component.previous" \
        _component_file_is_safe 600 || fail "retry setup failed for $component"
done
/usr/bin/rm -f -- "$retry_stage/yq.previous"
rc=0
_component_rollback_committed || rc=$?
assert_eq 1 "$rc" 'partial rollback failure status'
assert_eq old-kernel "$(<"$retry_root/kernel")" \
    'partial rollback continued past failed middle item'
assert_eq new-yq "$(<"$retry_root/yq")" \
    'partial rollback retained failed middle item'
assert_eq old-ui "$(<"$retry_root/ui")" \
    'partial rollback restored item before failed middle item'
assert_eq 1 "${#_COMPONENT_TRANSACTION_TARGETS[@]}" \
    'partial rollback retained only failed target'
assert_eq "$retry_root/yq" "${_COMPONENT_TRANSACTION_TARGETS[0]}" \
    'partial rollback retained the retryable target'
assert_absent "$retry_stage/kernel.previous" \
    'partial rollback removed successful kernel record'
assert_absent "$retry_stage/ui.previous" \
    'partial rollback removed successful UI record'

printf 'old-yq\n' >"$retry_stage/yq.previous"
chmod 0600 "$retry_stage/yq.previous"
_component_rollback_committed || fail 'partial rollback retry failed'
assert_eq old-yq "$(<"$retry_root/yq")" 'partial rollback retry restored failed item'
assert_eq 0 "${#_COMPONENT_TRANSACTION_TARGETS[@]}" \
    'partial rollback retry cleared transaction state'

configure_home invalid-layout
seed_existing_components
# shellcheck disable=SC2034
ZIP_SUBCONVERTER="$ARCHIVE_DIR/subconverter-invalid.tar.gz"
stderr_file="$WORK_DIR/invalid-layout.stderr"
rc=0
unzip_zip >"$WORK_DIR/invalid-layout.stdout" 2>"$stderr_file" || rc=$?
assert_eq 1 "$rc" 'invalid subconverter layout failure status'
assert_contains "$stderr_file" 'subconverter 归档结构无效' \
    'invalid subconverter layout diagnostic'
assert_contains "$stderr_file" '已废弃布局无效的依赖缓存：subconverter' \
    'invalid subconverter cache discard diagnostic'
assert_contains "$stderr_file" '安装器将重新下载该组件' \
    'invalid subconverter cache retry diagnostic'
assert_absent "$ZIP_SUBCONVERTER" 'invalid subconverter layout cache discard'
assert_eq old-kernel "$(<"$BIN_KERNEL")" 'invalid layout preserved kernel'
assert_eq old-yq "$(<"$BIN_YQ")" 'invalid layout preserved yq'
assert_eq old-converter "$(<"$BIN_SUBCONVERTER")" \
    'invalid layout preserved subconverter'
assert_eq '<html>old-ui</html>' "$(<"$CLASH_RESOURCES_DIR/dist/index.html")" \
    'invalid layout preserved Web UI'
assert_no_stages

configure_home extraction-failure
seed_existing_components
# shellcheck disable=SC2034
ZIP_SUBCONVERTER="$ARCHIVE_DIR/subconverter-extraction-failure.tar.gz"
stderr_file="$WORK_DIR/extraction-failure.stderr"
rc=0
unzip_zip >"$WORK_DIR/extraction-failure.stdout" 2>"$stderr_file" || rc=$?
assert_eq 1 "$rc" 'subconverter extraction failure status'
assert_contains "$stderr_file" '准备 subconverter 失败' \
    'subconverter extraction failure diagnostic'
[ -f "$ZIP_SUBCONVERTER" ] || fail 'non-layout failure removed managed cache'
assert_eq old-kernel "$(<"$BIN_KERNEL")" 'extraction failure preserved kernel'
assert_eq old-yq "$(<"$BIN_YQ")" 'extraction failure preserved yq'
assert_eq old-converter "$(<"$BIN_SUBCONVERTER")" \
    'extraction failure preserved subconverter'
assert_eq '<html>old-ui</html>' "$(<"$CLASH_RESOURCES_DIR/dist/index.html")" \
    'extraction failure preserved Web UI'
assert_no_stages

# ── 部分组件集（provision_component 场景）：仅 UI 时其他组件不动 ──
configure_home ui-only
seed_existing_components
stdout_file="$WORK_DIR/ui-only.stdout"
stderr_file="$WORK_DIR/ui-only.stderr"
ZIP_KERNEL= ZIP_YQ= ZIP_SUBCONVERTER= unzip_zip >"$stdout_file" 2>"$stderr_file" ||
    fail "ui-only provisioning failed: $(<"$stderr_file")"
assert_eq old-kernel "$(<"$BIN_KERNEL")" 'ui-only provisioning keeps the kernel'
assert_eq old-yq "$(<"$BIN_YQ")" 'ui-only provisioning keeps yq'
assert_eq old-converter "$(<"$BIN_SUBCONVERTER")" 'ui-only provisioning keeps subconverter'
assert_eq '<html>new-ui</html>' "$(<"$CLASH_RESOURCES_DIR/dist/index.html")" \
    'ui-only provisioning replaces the Web UI'
assert_absent "$CLASH_RESOURCES_DIR/dist/stale.js" 'ui-only provisioning cleans stale UI'
assert_no_stages
assert_contains "$stderr_file" '运行组件已安装' 'ui-only provisioning success output'

# 空组件集拒绝
configure_home empty-set
stdout_file="$WORK_DIR/empty-set.stdout"
stderr_file="$WORK_DIR/empty-set.stderr"
rc=0
ZIP_KERNEL= ZIP_YQ= ZIP_SUBCONVERTER= ZIP_UI= unzip_zip \
    >"$stdout_file" 2>"$stderr_file" || rc=$?
assert_eq 1 "$rc" 'empty component set is rejected'
assert_contains "$stderr_file" '没有待安装的组件归档' 'empty set diagnostic is actionable'

if [ "$(id -u)" -eq 0 ]; then
    printf 'preflight-components: ok (root numeric-owner coverage)\n'
else
    printf 'preflight-components: ok (numeric-owner root behavior requires root)\n'
fi
