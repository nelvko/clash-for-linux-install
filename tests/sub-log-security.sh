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
    *"$unexpected"*) fail "$description: found [$unexpected]" ;;
    *) ;;
    esac
}

CLASH_PROFILES_LOG="$WORK_DIR/profiles.log"
CLASH_RESOURCES_DIR="$WORK_DIR/resources"
# shellcheck disable=SC2034  # consumed by functions in the sourced command module
CLASH_CONFIG_DEBUG="$WORK_DIR/last-failed.yaml"
# shellcheck disable=SC2034  # consumed by functions in the sourced command module
CLASH_CONFIG_DEBUG_RAW="$WORK_DIR/last-failed.raw"
# shellcheck disable=SC2034  # consumed by functions in the sourced command module
BIN_SUBCONVERTER_LOG="$WORK_DIR/subconverter.log"
mkdir -p -- "$CLASH_RESOURCES_DIR"
# shellcheck source=../scripts/cmd/sub.sh
. "$REPO_DIR/scripts/cmd/sub.sh"

secret_url='https://example.test/sub?token=a[b]*c&user=demo'
raw_error="wget: server returned error for $secret_url; retry $secret_url"
redacted=$(printf '%s\n' "$raw_error" | _sub_redact_url "$secret_url")
assert_not_contains "$redacted" "$secret_url" 'redactor hides the exact subscription URL'
assert_contains "$redacted" '<订阅链接>' 'redactor leaves a useful placeholder'

_download_config() {
    printf 'download failed for %s; retry %s\n' "$2" "$2" >&2
    return 1
}

set +e
_sub_download "$secret_url" raw 2>"$WORK_DIR/download.stderr"
download_rc=$?
set -e
[ "$download_rc" -ne 0 ] || fail 'failed download unexpectedly returned success'
download_error=$(<"$WORK_DIR/download.stderr")
assert_not_contains "$download_error" "$secret_url" 'download failure stderr hides subscription URL'
assert_contains "$download_error" '<订阅链接>' 'download failure stderr keeps a placeholder'
assert_not_contains "$_SUB_DL_REASON" "$secret_url" 'download failure reason hides subscription URL'
assert_contains "$_SUB_DL_REASON" '<订阅链接>' 'download failure reason keeps a placeholder'

good_log=$CLASH_PROFILES_LOG
mkdir -p -- "$WORK_DIR/log-target-directory"
chmod 0755 "$WORK_DIR/log-target-directory"
CLASH_PROFILES_LOG="$WORK_DIR/log-target-directory"
set +e
_sub_log_event INFO 'must fail' 2>"$WORK_DIR/log-failure.stderr"
log_failure_rc=$?
set -e
[ "$log_failure_rc" -ne 0 ] || fail 'log append failure was reported as success'
[ "$(stat -c '%a' "$CLASH_PROFILES_LOG")" = 755 ] ||
    fail 'failed log append changed directory permissions'
CLASH_PROFILES_LOG=$good_log

_sub_log_event INFO '订阅已添加：[demo]'
log_output=$(_sub_log -n 1)
assert_contains "$log_output" '[INFO] 订阅已添加：[demo]' 'event log uses a level and message'
assert_not_contains "$log_output" "$secret_url" 'event log does not contain a subscription URL'

line_count=$(wc -l <"$CLASH_PROFILES_LOG")
[ "$line_count" -eq 1 ] || fail 'viewing the log unexpectedly wrote another event'
[ "$(stat -c '%a' "$CLASH_PROFILES_LOG")" = 600 ] || fail 'subscription log mode is not 0600'

printf 'sub-log-security: ok\n'
