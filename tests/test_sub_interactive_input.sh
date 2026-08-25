#!/usr/bin/env bash

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
SUB_SCRIPT="${REPO_ROOT}/scripts/cmd/sub.sh"
errors=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; errors=$((errors + 1)); }

if ! command -v script >/dev/null 2>&1; then
    echo 'SKIP: script is unavailable'
    exit 0
fi

test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

cat >"$test_root/probe.sh" <<'EOF'
source "$1"

_okcat() { printf '%s' "$*"; }
_errorcat() { printf 'ERROR: %s\n' "$*" >&2; }
_sub_url_exists() { return 1; }
_sub_download() {
    _SUB_DL_FILE=/dev/null
    FETCH_USERINFO=''
    FETCH_FILENAME=''
    return 0
}
_with_profiles_lock() {
    [ "$1" = _sub_add_locked ] || return 90
    printf 'RESULT=%s\n' "$3"
}

sub_add
EOF

run_case() {
    local shell=$1 name=$2 input=$3 expected=$4 output actual shell_command
    output="$test_root/${shell}-${name}.out"

    case "$shell" in
    bash) shell_command="'$shell' --noprofile --norc -i" ;;
    zsh) shell_command="'$shell' -f -i" ;;
    esac

    printf '%b' "$input" | TERM=xterm-256color script -qfec \
        "stty cols 120 rows 30; TERM=xterm-256color $shell_command '$test_root/probe.sh' '$SUB_SCRIPT'" \
        /dev/null >"$output" 2>&1

    actual="$(tr -d '\r' <"$output" | sed -n 's/.*RESULT=//p' | tail -1)"
    if [ "$actual" = "$expected" ]; then
        pass "$shell $name"
    else
        fail "$shell $name (expected '$expected', got '$actual')"
        tr -d '\r' <"$output" | tail -5
    fi
}

run_fallback_case() {
    local shell=$1 output actual
    output="$test_root/${shell}-fallback.out"

    printf '%b' '\033[200~https://example.invalid/fallback\033[201~\n' |
        "$shell" "$test_root/probe.sh" "$SUB_SCRIPT" >"$output" 2>&1
    actual="$(tr -d '\r' <"$output" | sed -n 's/.*RESULT=//p' | tail -1)"
    if [ "$actual" = 'https://example.invalid/fallback' ]; then
        pass "$shell non-TTY fallback"
    else
        fail "$shell non-TTY fallback (got '$actual')"
    fi
}

for shell in bash zsh; do
    command -v "$shell" >/dev/null 2>&1 || continue
    run_case "$shell" bracketed-paste \
        '\033[200~https://example.invalid/sub?id=1\033[201~\n' \
        'https://example.invalid/sub?id=1'
    run_case "$shell" left-arrow 'ab\033[DZ\n' 'aZb'
    run_fallback_case "$shell"
done

if [ "$errors" -eq 0 ]; then
    echo 'PASS: interactive subscription input'
    exit 0
fi

echo "FAIL: interactive subscription input ($errors error(s))"
exit 1
