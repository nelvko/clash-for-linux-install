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

CLASH_DATA_DIR="$WORK_DIR/data"
CLASHCTL_API_TIMEOUT=3
mkdir -m 0700 -- "$CLASH_DATA_DIR"
export CLASH_DATA_DIR CLASHCTL_API_TIMEOUT

# shellcheck source=../scripts/cmd/node.sh
. "$REPO_DIR/scripts/cmd/node.sh"

controller_secret='controller-secret-must-not-enter-argv'
args_file="$WORK_DIR/curl.args"
header_copy="$WORK_DIR/header.copy"
header_path_file="$WORK_DIR/header.path"
header_mode_file="$WORK_DIR/header.mode"

_detect_ext_addr() {
    export EXT_PORT=9090
}

_get_secret() {
    printf '%s' "$controller_secret"
}

curl() {
    local arg expect_header=0 header_path=
    : >"$args_file"
    for arg in "$@"; do
        printf '%s\n' "$arg" >>"$args_file"
        if [ "$expect_header" -eq 1 ]; then
            header_path=${arg#@}
            expect_header=0
        elif [ "$arg" = --header ]; then
            expect_header=1
        fi
    done
    [ -f "$header_path" ] || return 1
    stat -c %a -- "$header_path" >"$header_mode_file"
    cp -- "$header_path" "$header_copy"
    printf '%s\n' "$header_path" >"$header_path_file"
    printf '%s\n' '{"status":"ok"}'
}

response=$(_node_curl GET /version) || fail 'private controller request failed'
assert_eq '{"status":"ok"}' "$response" 'controller response is preserved'
assert_eq --disable "$(head -n 1 -- "$args_file")" '.curlrc is disabled first'
assert_eq 600 "$(<"$header_mode_file")" 'controller header permissions'
grep -Fqs -- "$controller_secret" "$args_file" && fail 'controller secret entered curl argv'
grep -Fqs -- "Authorization: Bearer $controller_secret" "$header_copy" ||
    fail 'controller header file did not contain the expected Bearer value'
header_path=$(<"$header_path_file")
[ ! -e "$header_path" ] || fail 'controller header file was not removed'

printf 'api-argv-security: ok\n'
