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

wait_for_file() {
    local file=$1 description=$2 attempt
    for ((attempt = 0; attempt < 250; attempt++)); do
        [ -e "$file" ] && return 0
        sleep 0.02
    done
    fail "$description"
}

assert_no_runtime_artifacts() {
    local artifact
    artifact=$(find "$BIN_SUBCONVERTER_DIR" -maxdepth 1 \
        \( -name '.pref.runtime.*' -o -name '.subconverter-log.*' \) -print -quit)
    [ -z "$artifact" ] || fail "$1: private converter artifact remains at $artifact"
    artifact=$(find "$CLASH_RESOURCES_DIR" -maxdepth 1 -name '.curl-config.*' -print -quit)
    [ -z "$artifact" ] || fail "$1: private curl config remains at $artifact"
}

_errorcat() {
    printf 'ERROR: %s\n' "$*" >&2
    return 1
}

_ui_warn_fail() {
    printf 'WARN: %s\n' "${*: -1}" >&2
    return 1
}

_ui_info_out() {
    printf 'INFO: %s\n' "$*"
    return 0
}

_ui_ok_out() {
    printf 'OK: %s\n' "$*"
    return 0
}

# 模拟配置端口已有健康实例；隐私实现必须换端口并启动自己的实例，不能复用。
_is_port_used() {
    [ "$1" = 25500 ]
}

_get_random_port() {
    printf '25501\n'
}

CLASH_RESOURCES_DIR="$WORK_DIR/resources"
BIN_SUBCONVERTER_DIR="$WORK_DIR/subconverter"
BIN_SUBCONVERTER="$BIN_SUBCONVERTER_DIR/subconverter"
BIN_SUBCONVERTER_CONFIG="$BIN_SUBCONVERTER_DIR/pref.yml"
BIN_SUBCONVERTER_LOG="$BIN_SUBCONVERTER_DIR/latest.log"
BIN_YQ=/usr/bin/yq
export CLASHCTL_SUB_UA=clashctl-test
export CLASHCTL_SUB_TIMEOUT=5
mkdir -p -- "$CLASH_RESOURCES_DIR" "$BIN_SUBCONVERTER_DIR" "$WORK_DIR/bin" "$WORK_DIR/state"

cat >"$BIN_SUBCONVERTER_CONFIG" <<'YAML'
server:
  port: 25500
YAML

cat >"$BIN_SUBCONVERTER" <<'STUB'
#!/usr/bin/env bash
set -eu

state=${CONVERTER_TEST_STATE:?}
case_name=${CONVERTER_TEST_CASE:?}
runtime=''

while [ "$#" -gt 0 ]; do
    case $1 in
    --file)
        runtime=$2
        shift 2
        ;;
    *) shift ;;
    esac
done
[ -n "$runtime" ] || exit 2

port=$(/usr/bin/yq '.server.port' "$runtime")
printf '%s\n' "$$" >"$state/$case_name.converter.pid"
printf '%s\n' "$runtime" >"$state/$case_name.runtime-config"
tr '\0' ' ' <"/proc/$$/cmdline" >"$state/$case_name.converter.cmdline"
printf 'startup-private-token: converter raw stderr\n' >&2

if [ "${CONVERTER_STUB_MODE:-serve}" = exit ]; then
    exit 42
fi

touch "$state/$case_name.converter-ready"
on_signal() {
    if [ -s "$state/$case_name.request-url" ]; then
        printf 'shutdown request url: %s\n' "$(<"$state/$case_name.request-url")" >&2
    fi
    exit 0
}
trap on_signal HUP INT TERM

while :; do
    if [ -e "$state/$case_name.request" ] && [ ! -e "$state/$case_name.logged" ]; then
        printf "Fetching node data from url '%s'.\n" "$(<"$state/$case_name.request-url")" >&2
        touch "$state/$case_name.logged"
    fi
    sleep 0.02
done
STUB
chmod +x "$BIN_SUBCONVERTER"

cat >"$WORK_DIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -eu

state=${CONVERTER_TEST_STATE:?}
case_name=${CONVERTER_TEST_CASE:?}
config='' request_url=''

while [ "$#" -gt 0 ]; do
    case $1 in
    --config)
        config=$2
        shift 2
        ;;
    --url)
        request_url=$2
        shift 2
        ;;
    *) shift ;;
    esac
done

if [ -z "$config" ]; then
    exit 2
fi

if ! grep -q '^data-urlencode = ' "$config"; then
    request_url=$(sed -n 's/^url = "\(.*\)"$/\1/p' "$config")
    printf '%s\n' "$request_url" >>"$state/$case_name.health-urls"
    tr '\0' ' ' <"/proc/$$/cmdline" >"$state/$case_name.health-cmdline"
    case $request_url in
    http://localhost:25501/version)
        [ -e "$state/$case_name.converter-ready" ]
        exit
        ;;
    *) exit 7 ;;
    esac
fi

printf '%s\n' "$$" >"$state/$case_name.curl.pid"
subscription_url=$(sed -n 's/^data-urlencode = "url=\(.*\)"$/\1/p' "$config")
output=$(sed -n 's/^output = "\(.*\)"$/\1/p' "$config")
printf '%s\n' "$subscription_url" >"$state/$case_name.request-url"
touch "$state/$case_name.request"

for attempt in $(seq 1 250); do
    [ -e "$state/$case_name.logged" ] && break
    sleep 0.02
done
[ -e "$state/$case_name.logged" ] || exit 70
touch "$state/$case_name.curl-ready"

while [ -e "$state/$case_name.hold" ]; do
    sleep 0.02
done

result=${CONVERTER_CURL_RESULT:-0}
[ "$result" -eq 0 ] || exit "$result"
printf 'proxies: [converted-node]\n' >"$output"
STUB
chmod +x "$WORK_DIR/bin/curl"

PATH="$WORK_DIR/bin:$PATH"
export PATH CONVERTER_TEST_STATE="$WORK_DIR/state"

# shellcheck source=../scripts/lib/convert.sh
. "$REPO_DIR/scripts/lib/convert.sh"

secret_url='https://example.test/sub?token=top-secret&user=demo'

# 成功路径：已有实例不被复用，原始 URL 仅短暂存在于 0600 私有日志。
export CONVERTER_TEST_CASE=success CONVERTER_STUB_MODE=serve CONVERTER_CURL_RESULT=0
touch "$WORK_DIR/state/success.hold"
_download_convert_config "$WORK_DIR/success.yaml" "$secret_url" 2>"$WORK_DIR/success.stderr" &
success_job=$!
wait_for_file "$WORK_DIR/state/success.curl-ready" 'successful conversion request did not start'

runtime_config=$(<"$WORK_DIR/state/success.runtime-config")
[ -f "$runtime_config" ] || fail 'private runtime config is unavailable during conversion'
[ "$(stat -c '%a' "$runtime_config")" = 600 ] || fail 'private runtime config mode is not 0600'
[ "$("$BIN_YQ" '.server.port' "$runtime_config")" = 25501 ] || fail 'private runtime config did not use isolated port'
[ "$("$BIN_YQ" '.server.port' "$BIN_SUBCONVERTER_CONFIG")" = 25500 ] || fail 'shared converter config was modified'

converter_cmdline=$(<"$WORK_DIR/state/success.converter.cmdline")
assert_contains "$converter_cmdline" '--file' 'converter uses a private runtime config'
assert_not_contains "$converter_cmdline" "$secret_url" 'converter argv hides subscription URL'
health_urls=$(<"$WORK_DIR/state/success.health-urls")
assert_contains "$health_urls" '25501/version' 'isolated converter is health checked'
assert_not_contains "$health_urls" '25500/version' 'existing converter is not reused or contacted'
health_cmdline=$(<"$WORK_DIR/state/success.health-cmdline")
assert_not_contains "$health_cmdline" 'http://' 'health check argv contains no URL'

private_log=$(find "$BIN_SUBCONVERTER_DIR" -maxdepth 1 -name '.subconverter-log.*' -print -quit)
[ -n "$private_log" ] || fail 'private converter log is missing during request'
[ "$(stat -c '%a' "$private_log")" = 600 ] || fail 'private converter log mode is not 0600'
private_log_content=$(<"$private_log")
assert_contains "$private_log_content" "$secret_url" 'third-party URL output is confined to private log'
persistent_log=$(<"$BIN_SUBCONVERTER_LOG")
assert_not_contains "$persistent_log" "$secret_url" 'persistent converter log hides URL during request'
assert_not_contains "$persistent_log" 'startup-private-token' 'third-party startup output is not persisted'

/usr/bin/rm -f "$WORK_DIR/state/success.hold"
set +e
wait "$success_job"
success_rc=$?
set -e
[ "$success_rc" -eq 0 ] || fail "successful conversion returned $success_rc: $(<"$WORK_DIR/success.stderr")"
[ -s "$WORK_DIR/success.yaml" ] || fail 'successful conversion did not create output'
assert_no_runtime_artifacts 'successful conversion cleanup'
persistent_log=$(<"$BIN_SUBCONVERTER_LOG")
assert_contains "$persistent_log" '转换请求完成' 'persistent log records safe success state'
assert_not_contains "$persistent_log" "$secret_url" 'success log hides subscription URL'
[ "$(stat -c '%a' "$BIN_SUBCONVERTER_LOG")" = 600 ] || fail 'persistent converter log mode is not 0600'

# 请求失败：保留 curl 错误码，但删除包含 URL 的第三方日志。
export CONVERTER_TEST_CASE=failure CONVERTER_STUB_MODE=serve CONVERTER_CURL_RESULT=28
set +e
_download_convert_config "$WORK_DIR/failure.yaml" "$secret_url" 2>"$WORK_DIR/failure.stderr"
failure_rc=$?
set -e
[ "$failure_rc" -eq 28 ] || fail "conversion failure code changed: $failure_rc"
failure_stderr=$(<"$WORK_DIR/failure.stderr")
assert_contains "$failure_stderr" 'curl 错误码 28' 'conversion failure diagnosis keeps curl code'
assert_not_contains "$failure_stderr" "$secret_url" 'conversion failure stderr hides URL'
assert_no_runtime_artifacts 'failed conversion cleanup'
persistent_log=$(<"$BIN_SUBCONVERTER_LOG")
assert_contains "$persistent_log" '转换请求失败（curl 错误码 28' 'persistent log records safe failure state'
assert_not_contains "$persistent_log" "$secret_url" 'failure log hides subscription URL'
assert_not_contains "$persistent_log" 'startup-private-token' 'failure log excludes third-party output'

# 实例启动失败：快速报告进程状态和配置位置，不持久化原始 stderr。
export CONVERTER_TEST_CASE=start-failure CONVERTER_STUB_MODE=exit CONVERTER_CURL_RESULT=0
set +e
_download_convert_config "$WORK_DIR/start-failure.yaml" "$secret_url" 2>"$WORK_DIR/start-failure.stderr"
start_failure_rc=$?
set -e
[ "$start_failure_rc" -ne 0 ] || fail 'converter start failure unexpectedly succeeded'
start_failure_stderr=$(<"$WORK_DIR/start-failure.stderr")
assert_contains "$start_failure_stderr" '状态 42' 'start failure includes converter exit status'
assert_contains "$start_failure_stderr" "$BIN_SUBCONVERTER_CONFIG" 'start failure points to configuration'
assert_not_contains "$start_failure_stderr" 'startup-private-token' 'start failure stderr excludes third-party output'
assert_not_contains "$start_failure_stderr" "$secret_url" 'start failure stderr hides URL'
assert_no_runtime_artifacts 'converter start failure cleanup'
persistent_log=$(<"$BIN_SUBCONVERTER_LOG")
assert_contains "$persistent_log" '状态 42' 'persistent log records safe start failure state'
assert_not_contains "$persistent_log" 'startup-private-token' 'start failure log excludes raw stderr'

# 信号路径：终止请求所有者后，外层 EXIT trap 回收实例及两个敏感临时文件。
export CONVERTER_TEST_CASE=signal CONVERTER_STUB_MODE=serve CONVERTER_CURL_RESULT=0
touch "$WORK_DIR/state/signal.hold"
set +e
_download_convert_config "$WORK_DIR/signal.yaml" "$secret_url" 2>"$WORK_DIR/signal.stderr" &
signal_job=$!
set -e
wait_for_file "$WORK_DIR/state/signal.curl-ready" 'signal conversion request did not start'
signal_converter_pid=$(<"$WORK_DIR/state/signal.converter.pid")
signal_curl_pid=$(<"$WORK_DIR/state/signal.curl.pid")
signal_owner=$(awk '/^PPid:/{print $2}' "/proc/$signal_converter_pid/status")
signal_curl_owner=$(awk '/^PPid:/{print $2}' "/proc/$signal_curl_pid/status")
kill -TERM "$signal_curl_pid" "$signal_curl_owner" "$signal_owner" 2>/dev/null || true
set +e
wait "$signal_job"
signal_rc=$?
set -e
[ "$signal_rc" -ne 0 ] || fail 'signalled conversion unexpectedly succeeded'
assert_no_runtime_artifacts 'signalled conversion cleanup'
persistent_log=$(<"$BIN_SUBCONVERTER_LOG")
assert_not_contains "$persistent_log" "$secret_url" 'signal path persistent log hides URL'
assert_not_contains "$persistent_log" 'startup-private-token' 'signal path excludes third-party output'

printf 'sub-converter-log-security: ok\n'
