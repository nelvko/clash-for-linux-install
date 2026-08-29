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

assert_no_private_config() {
    local files
    files=$(find "$CLASH_RESOURCES_DIR" -maxdepth 1 \
        \( -name '.curl-config.*' -o -name '.header.*' \) -print -quit)
    [ -z "$files" ] || fail "$1: private curl artifact remains at $files"
}

wait_for_file() {
    local file=$1 description=$2 attempt
    for ((attempt = 0; attempt < 250; attempt++)); do
        [ -e "$file" ] && return 0
        sleep 0.02
    done
    fail "$description"
}

_errorcat() {
    printf 'ERROR: %s\n' "$*" >&2
    return 1
}

CLASH_RESOURCES_DIR="$WORK_DIR/resources"
export CLASHCTL_SUB_CONNECT_TIMEOUT=7
export CLASHCTL_SUB_TIMEOUT=23
export CLASHCTL_SUB_RETRY=4
export CLASHCTL_SUB_UA='clashctl-test/1.0 "private"'
export BIN_SUBCONVERTER_PORT=25500
FETCH_USERINFO=''
FETCH_FILENAME=''
mkdir -p -- "$CLASH_RESOURCES_DIR" "$WORK_DIR/bin" "$WORK_DIR/state" "$WORK_DIR/empty-path"

# shellcheck source=../scripts/lib/convert.sh
. "$REPO_DIR/scripts/lib/convert.sh"

# _download_convert_config 只需测试 HTTP 请求；不启动真实 subconverter。
_start_convert() {
    return 0
}

_stop_convert() {
    return 0
}

cat >"$WORK_DIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -eu

state=${CURL_STUB_STATE_DIR:?}
call=${CURL_STUB_CALL:?}
config=''

printf '%s\n' "$$" >"$state/$call.pid"
tr '\0' ' ' <"/proc/$$/cmdline" >"$state/$call.cmdline"

while [ "$#" -gt 0 ]; do
    case $1 in
    --config)
        [ "$#" -ge 2 ] || exit 2
        config=$2
        shift 2
        ;;
    *) shift ;;
    esac
done

[ -n "$config" ] || exit 2
printf '%s\n' "$config" >"$state/$call.config-path"
stat -c '%a' "$config" >"$state/$call.config-mode"
cp -- "$config" "$state/$call.config-copy"
header=$(sed -n 's/^dump-header = "\(.*\)"$/\1/p' "$config")
touch "$state/$call.ready"

while [ -e "$state/$call.hold" ]; do
    sleep 0.02
done

if [ "${CURL_STUB_ECHO_CONFIG:-0}" = 1 ]; then
    cat "$config" >&2
fi

result=${CURL_STUB_RESULT:-0}
[ "$result" -eq 0 ] || exit "$result"

[ -z "${CURL_STUB_DEST:-}" ] || printf 'proxies: [test-node]\n' >"$CURL_STUB_DEST"
if [ -n "$header" ]; then
    printf '%s\n' \
        'HTTP/1.1 200 OK' \
        'Subscription-Userinfo: upload=1; download=2; total=10' \
        'Content-Disposition: attachment; filename="airport.yaml"' \
        >"$header"
fi
STUB
chmod +x "$WORK_DIR/bin/curl"

PATH="$WORK_DIR/bin:$PATH"
export PATH CURL_STUB_STATE_DIR="$WORK_DIR/state"

secret_url='https://example.test/sub?token=a\b"c&user=demo'

# 原始下载：在 curl 挂起期间检查真实进程参数、配置权限和功能选项。
export CURL_STUB_CALL=raw CURL_STUB_DEST="$WORK_DIR/raw.yaml"
unset CURL_STUB_RESULT CURL_STUB_ECHO_CONFIG
touch "$WORK_DIR/state/raw.hold"
_download_raw_config "$WORK_DIR/raw.yaml" "$secret_url" 2>"$WORK_DIR/raw.stderr" &
raw_job=$!
wait_for_file "$WORK_DIR/state/raw.ready" 'raw curl stub did not start'

raw_pid=$(<"$WORK_DIR/state/raw.pid")
raw_cmdline=$(tr '\0' ' ' <"/proc/$raw_pid/cmdline")
assert_contains "$raw_cmdline" '--disable --config' 'raw curl disables user config and uses private config'
assert_not_contains "$raw_cmdline" "$secret_url" 'raw curl argv hides subscription URL'
assert_not_contains "$raw_cmdline" 'https://' 'raw curl argv contains no request URL'

raw_config_path=$(<"$WORK_DIR/state/raw.config-path")
[ -f "$raw_config_path" ] || fail 'raw private config is unavailable during request'
[ "$(<"$WORK_DIR/state/raw.config-mode")" = 600 ] || fail 'raw private config mode is not 0600'
raw_config=$(<"$WORK_DIR/state/raw.config-copy")
escaped_url=${secret_url//\\/\\\\}
escaped_url=${escaped_url//\"/\\\"}
assert_contains "$raw_config" "url = \"$escaped_url\"" 'raw private config safely escapes URL'
assert_contains "$raw_config" 'connect-timeout = "7"' 'raw connect timeout is preserved'
assert_contains "$raw_config" 'max-time = "23"' 'raw total timeout is preserved'
assert_contains "$raw_config" 'retry = "4"' 'raw retry count is preserved'
assert_contains "$raw_config" 'retry-connrefused' 'raw connection retry is preserved'
assert_contains "$raw_config" 'user-agent = "clashctl-test/1.0 \"private\""' 'raw user agent is preserved and escaped'
assert_contains "$raw_config" 'dump-header = ' 'raw response headers remain enabled'

/usr/bin/rm -f "$WORK_DIR/state/raw.hold"
wait "$raw_job"
assert_no_private_config 'raw success cleanup'

# 响应头仍在前台调用中回传给订阅事务。
export CURL_STUB_CALL=headers CURL_STUB_DEST="$WORK_DIR/headers.yaml"
_download_raw_config "$WORK_DIR/headers.yaml" "$secret_url"
[ "$FETCH_USERINFO" = 'upload=1; download=2; total=10' ] || fail 'subscription-userinfo parsing regressed'
[ "$FETCH_FILENAME" = 'airport.yaml' ] || fail 'content-disposition parsing regressed'
assert_no_private_config 'header parsing cleanup'

# 转换请求：data-urlencode 和本地请求地址都只进入配置文件。
export CURL_STUB_CALL=convert CURL_STUB_DEST="$WORK_DIR/convert.yaml"
touch "$WORK_DIR/state/convert.hold"
_download_convert_config "$WORK_DIR/convert.yaml" "$secret_url" 2>"$WORK_DIR/convert.stderr" &
convert_job=$!
wait_for_file "$WORK_DIR/state/convert.ready" 'convert curl stub did not start'

convert_pid=$(<"$WORK_DIR/state/convert.pid")
convert_cmdline=$(tr '\0' ' ' <"/proc/$convert_pid/cmdline")
assert_not_contains "$convert_cmdline" "$secret_url" 'convert curl argv hides subscription URL'
assert_not_contains "$convert_cmdline" 'http://' 'convert curl argv contains no request URL'
[ "$(<"$WORK_DIR/state/convert.config-mode")" = 600 ] || fail 'convert private config mode is not 0600'
convert_config=$(<"$WORK_DIR/state/convert.config-copy")
assert_contains "$convert_config" "data-urlencode = \"url=$escaped_url\"" 'convert URL is encoded from private config'
assert_contains "$convert_config" 'data-urlencode = "target=clash"' 'convert target is preserved'
assert_contains "$convert_config" 'url = "http://127.0.0.1:25500/sub"' 'convert endpoint is preserved'

/usr/bin/rm -f "$WORK_DIR/state/convert.hold"
wait "$convert_job"
assert_no_private_config 'convert success cleanup'

# curl 原生错误即使回显整个配置，也不能进入 stderr；失败必须清理配置。
export CURL_STUB_CALL=failure CURL_STUB_DEST="$WORK_DIR/failure.yaml"
export CURL_STUB_RESULT=28 CURL_STUB_ECHO_CONFIG=1
set +e
_download_raw_config "$WORK_DIR/failure.yaml" "$secret_url" 2>"$WORK_DIR/failure.stderr"
failure_rc=$?
set -e
[ "$failure_rc" -eq 28 ] || fail "raw curl failure code changed: $failure_rc"
failure_stderr=$(<"$WORK_DIR/failure.stderr")
assert_contains "$failure_stderr" '订阅下载请求失败' 'raw failure keeps a useful diagnosis'
assert_not_contains "$failure_stderr" "$secret_url" 'raw failure stderr hides subscription URL'
assert_not_contains "$failure_stderr" 'token=' 'raw failure stderr hides curl config content'
assert_no_private_config 'raw failure cleanup'

# TERM 同时结束 curl 和持有清理 trap 的请求进程，私有配置不得残留。
export CURL_STUB_CALL=term CURL_STUB_DEST="$WORK_DIR/term.yaml"
unset CURL_STUB_RESULT CURL_STUB_ECHO_CONFIG
touch "$WORK_DIR/state/term.hold"
set +e
_curl_private_request raw "$WORK_DIR/term.yaml" "$secret_url" '' 2>"$WORK_DIR/term.stderr" &
term_job=$!
set -e
wait_for_file "$WORK_DIR/state/term.ready" 'term curl stub did not start'
term_pid=$(<"$WORK_DIR/state/term.pid")
term_owner=$(awk '/^PPid:/{print $2}' "/proc/$term_pid/status")
kill -TERM "$term_pid" "$term_owner" 2>/dev/null || true
set +e
wait "$term_job"
term_rc=$?
set -e
[ "$term_rc" -ne 0 ] || fail 'TERM request unexpectedly succeeded'
wait_for_file "$WORK_DIR/state/term.config-path" 'term config path was not recorded'
term_config_path=$(<"$WORK_DIR/state/term.config-path")
[ ! -e "$term_config_path" ] || fail 'TERM left private curl config behind'
assert_no_private_config 'TERM cleanup'

# 换行等控制字符在写入 curl 配置前失败，且诊断不回显输入。
export CURL_STUB_CALL=injection
set +e
_curl_private_request raw "$WORK_DIR/injection.yaml" $'https://example.test/sub\noutput = "/tmp/leak"' '' \
    2>"$WORK_DIR/injection.stderr"
injection_rc=$?
set -e
[ "$injection_rc" -ne 0 ] || fail 'curl config injection URL unexpectedly succeeded'
injection_stderr=$(<"$WORK_DIR/injection.stderr")
assert_contains "$injection_stderr" '控制字符' 'curl config injection has a useful diagnosis'
assert_not_contains "$injection_stderr" '/tmp/leak' 'curl config injection diagnosis hides input'
assert_no_private_config 'injection rejection cleanup'

# 没有 curl 时明确失败，不再静默回退到 wget。
saved_path=$PATH
# shellcheck disable=SC2123  # 本用例需要模拟系统中不存在 curl。
PATH="$WORK_DIR/empty-path"
set +e
_curl_private_request raw "$WORK_DIR/missing.yaml" "$secret_url" '' 2>"$WORK_DIR/missing.stderr"
missing_rc=$?
set -e
PATH=$saved_path
[ "$missing_rc" -eq 127 ] || fail "missing curl exit code changed: $missing_rc"
missing_stderr=$(<"$WORK_DIR/missing.stderr")
assert_contains "$missing_stderr" '缺少订阅下载依赖：curl' 'missing curl diagnosis'
assert_not_contains "$missing_stderr" "$secret_url" 'missing curl diagnosis hides subscription URL'
assert_no_private_config 'missing curl cleanup'

printf 'sub-argv-security: ok\n'
