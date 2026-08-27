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

BIN_YQ="$WORK_DIR/yq"
CLASH_CONFIG_BASE="$WORK_DIR/config.yaml"
CLASH_CONFIG_MIXIN="$WORK_DIR/mixin.yaml"
CLASH_CONFIG_RUNTIME="$WORK_DIR/runtime.yaml"
export BIN_YQ CLASH_CONFIG_BASE CLASH_CONFIG_MIXIN CLASH_CONFIG_RUNTIME

cat >"$BIN_YQ" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${YQ_OUTPUT:-new-runtime}"
exit "${YQ_RC:-0}"
EOF
chmod 0700 "$BIN_YQ"

# shellcheck source=../scripts/lib/config.sh
. "$REPO_DIR/scripts/lib/config.sh"

VALID_RC=0
_valid_config() {
    return "$VALID_RC"
}

_ui_error() {
    printf '[ERROR] %s\n' "$*" >&2
}

_errorcat() {
    printf '[ERROR] %s\n' "$*" >&2
    return 1
}

run_merge() {
    local label=$1
    RUN_RC=0
    _merge_config >"$WORK_DIR/$label.stdout" 2>"$WORK_DIR/$label.stderr" || RUN_RC=$?
    RUN_STDERR="$WORK_DIR/$label.stderr"
}

printf 'base\n' >"$CLASH_CONFIG_BASE"
printf 'mixin\n' >"$CLASH_CONFIG_MIXIN"

printf 'old-runtime\n' >"$CLASH_CONFIG_RUNTIME"
export YQ_OUTPUT=partial-runtime YQ_RC=73
VALID_RC=0
run_merge merge-failure
assert_eq 1 "$RUN_RC" 'merge command failure exit code'
assert_eq old-runtime "$(<"$CLASH_CONFIG_RUNTIME")" \
    'merge command failure preserves the previous runtime'
assert_contains "$RUN_STDERR" '无法合并运行配置' 'merge command failure diagnosis'

printf 'old-runtime\n' >"$CLASH_CONFIG_RUNTIME"
export YQ_OUTPUT=invalid-runtime YQ_RC=0
VALID_RC=1
run_merge validation-failure
assert_eq 1 "$RUN_RC" 'candidate validation failure exit code'
assert_eq old-runtime "$(<"$CLASH_CONFIG_RUNTIME")" \
    'candidate validation failure preserves the previous runtime'
assert_contains "$RUN_STDERR" '已保留原运行配置' 'validation failure preservation diagnosis'

printf 'old-runtime\n' >"$CLASH_CONFIG_RUNTIME"
export YQ_OUTPUT=new-runtime YQ_RC=0
VALID_RC=0
run_merge success
assert_eq 0 "$RUN_RC" 'valid candidate commit exit code'
assert_eq new-runtime "$(<"$CLASH_CONFIG_RUNTIME")" 'valid candidate is committed'
assert_eq 600 "$(stat -c %a -- "$CLASH_CONFIG_RUNTIME")" 'committed runtime mode'

if find "$WORK_DIR" -maxdepth 1 -name 'runtime.yaml.next.*' -print -quit | grep -q .; then
    fail 'merge candidate remained after transaction completion'
fi

printf 'config-merge-transaction: ok\n'
