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

export CLASHCTL_COLOR=never
# shellcheck source=../scripts/lib/update.sh
. "$REPO_DIR/scripts/lib/update.sh"

_ui_error() { printf '[ERROR] %s\n' "$*" >&2; }
_ui_warn() { printf '[WARN] %s\n' "$*" >&2; }
_ui_detail() { printf '        %s: %s\n' "$1" "$2" >&2; }

OUT="$WORK_DIR/out"
FAKE_SHA_HEAD=$(printf 'a%.0s' {1..40})
FAKE_SHA_OTHER=$(printf 'b%.0s' {1..40})

# 一致：直连 API 返回与 FETCH_HEAD 相同 sha → 通过并输出官方校验
API_RESPONSE=$FAKE_SHA_HEAD
curl() {
    printf '{"sha": "%s"}\n' "$API_RESPONSE"
    return 0
}
: >"$OUT"
rc=0
CLASHCTL_UPDATE_GIT_URL= _update_verify_commit master "$FAKE_SHA_HEAD" >"$OUT" 2>&1 || rc=$?
assert_eq 0 "$rc" 'matching official sha passes'
assert_contains "$OUT" '官方校验' 'matching sha reports verification'

# 不一致：镜像投递被篡改内容 → 中止
: >"$OUT"
rc=0
CLASHCTL_UPDATE_GIT_URL= _update_verify_commit master "$FAKE_SHA_OTHER" >"$OUT" 2>&1 || rc=$?
assert_eq 1 "$rc" 'sha mismatch aborts the update'
assert_contains "$OUT" '疑似镜像投递' 'mismatch explains the tamper suspicion'
assert_contains "$OUT" "$FAKE_SHA_HEAD" 'mismatch reports official sha'
assert_contains "$OUT" "$FAKE_SHA_OTHER" 'mismatch reports fetched sha'

# 直连不可达：明确降级警告后继续
curl() { return 1; }
: >"$OUT"
rc=0
CLASHCTL_UPDATE_GIT_URL= _update_verify_commit master "$FAKE_SHA_OTHER" >"$OUT" 2>&1 || rc=$?
assert_eq 0 "$rc" 'unreachable direct api degrades to warning'
assert_contains "$OUT" '跳过校验' 'unreachable api explains the skip'
assert_contains "$OUT" '镜像通道理论上可投递' 'unreachable api discloses the risk'

# 自定义更新源：跳过并说明
: >"$OUT"
rc=0
CLASHCTL_UPDATE_GIT_URL=https://example.invalid/mirror.git \
    _update_verify_commit master "$FAKE_SHA_OTHER" >"$OUT" 2>&1 || rc=$?
assert_eq 0 "$rc" 'custom update source skips verification'
assert_contains "$OUT" '自定义 CLASHCTL_UPDATE_GIT_URL' 'custom skip is explicit'

# 无法解析 HEAD：降级继续
curl() { printf 'not-json\n'; }
: >"$OUT"
rc=0
CLASHCTL_UPDATE_GIT_URL= _update_verify_commit master "$FAKE_SHA_OTHER" >"$OUT" 2>&1 || rc=$?
assert_eq 0 "$rc" 'unparseable api response degrades to warning'
assert_contains "$OUT" '跳过提交校验' 'unparseable response explains the skip'

printf '%s\n' 'update-verify: ok'
