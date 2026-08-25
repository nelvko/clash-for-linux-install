#!/usr/bin/env bash

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."

command -v zsh >/dev/null 2>&1 || {
    echo 'SKIP: zsh is unavailable'
    exit 0
}

test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

mkdir -p "$test_root/bin" "$test_root/resources" "$test_root/scripts/cmd" "$test_root/scripts/lib"
ln -s "$REPO_ROOT/scripts/cmd/clashctl.sh" "$test_root/scripts/cmd/clashctl.sh"
[ ! -f "$REPO_ROOT/scripts/cmd/clashctl.zsh" ] ||
    ln -s "$REPO_ROOT/scripts/cmd/clashctl.zsh" "$test_root/scripts/cmd/clashctl.zsh"
ln -s "$REPO_ROOT/scripts/cmd/on.sh" "$test_root/scripts/cmd/on.sh"
ln -s "$REPO_ROOT/scripts/cmd/off.sh" "$test_root/scripts/cmd/off.sh"

cat >"$test_root/.env" <<'EOF'
CLASHCTL_KERNEL=mihomo
EOF

cat >"$test_root/bin/yq" <<'EOF'
#!/bin/sh
printf '7897|||\n'
EOF
chmod +x "$test_root/bin/yq"

cat >"$test_root/scripts/lib/common.sh" <<'EOF'
BIN_YQ="$CLASHCTL_HOME/bin/yq"
CLASH_CONFIG_RUNTIME="$CLASHCTL_HOME/resources/runtime.yaml"

CLASHCTL_TEST_ACTIVE=1
service_is_active() { [ "${CLASHCTL_TEST_ACTIVE:-1}" = 1 ]; }
service_start() { return 0; }
service_stop() { CLASHCTL_TEST_ACTIVE=0; }
_get_bind_addr() { printf '127.0.0.1'; }
_okcat() { printf '%s\n' "$*"; }
_failcat() { printf '%s\n' "$*" >&2; return 1; }
EOF

cat >"$test_root/scripts/cmd/probe.sh" <<'EOF'
clashprobe() {
    local runtime=zsh
    [ -n "${BASH_VERSION:-}" ] && runtime=bash
    printf 'runtime=%s argument=%s\n' "$runtime" "$1"
}
EOF

cat >"$test_root/probe.zsh" <<'EOF'
CLASHCTL_HOME=$1
export CLASHCTL_HOME
. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh"

if (( $+functions[set_system_proxy] )); then
    print -u2 'Bash implementation leaked into Zsh'
    exit 91
fi

result=$(clashctl probe 'value with spaces') || exit
[[ $result == 'runtime=bash argument=value with spaces' ]] || {
    print -u2 -- "unexpected clashctl result: $result"
    exit 92
}

result=$(clashprobe 'direct wrapper') || exit
[[ $result == 'runtime=bash argument=direct wrapper' ]] || {
    print -u2 -- "unexpected direct-wrapper result: $result"
    exit 93
}

clashctl on --env-only >/dev/null 2>&1 || exit
[[ $http_proxy == 'http://127.0.0.1:7897' ]] || {
    print -u2 -- "proxy environment was not imported: ${http_proxy:-missing}"
    exit 94
}

clashctl off --env-only >/dev/null 2>&1 || exit
(( ! ${+http_proxy} && ! ${+https_proxy} && ! ${+all_proxy} )) || {
    print -u2 'proxy environment was not removed'
    exit 95
}

export CLASHCTL_MANAGE_SHELL_PROXY=0
unset http_proxy https_proxy all_proxy
clashctl on >/dev/null 2>&1 || exit
(( ! ${+http_proxy} && ! ${+https_proxy} && ! ${+all_proxy} )) || {
    print -u2 'externally managed proxy environment was overwritten by clashctl on'
    exit 96
}

export http_proxy='owned-by-env-setup'
clashctl off >/dev/null 2>&1 || exit
[[ $http_proxy == 'owned-by-env-setup' ]] || {
    print -u2 'externally managed proxy environment was cleared by clashctl off'
    exit 97
}

print 'adapter-ok'
EOF

output=$(zsh -f "$test_root/probe.zsh" "$test_root" 2>&1)
status=$?
printf '%s\n' "$output"

if [ "$status" -ne 0 ] || [ "$output" != adapter-ok ]; then
    echo "FAIL: Zsh Bash adapter (status $status)"
    exit 1
fi

cat >"$test_root/probe.bash" <<'EOF'
CLASHCTL_HOME=$1
export CLASHCTL_HOME CLASHCTL_MANAGE_SHELL_PROXY=0
. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh"

unset http_proxy https_proxy all_proxy
clashctl on >/dev/null 2>&1 || exit
[ -z "${http_proxy+x}${https_proxy+x}${all_proxy+x}" ] || {
    printf '%s\n' 'Bash clashctl on overwrote externally managed proxy variables' >&2
    exit 98
}

export http_proxy=owned-by-env-setup
clashctl off >/dev/null 2>&1 || exit
[ "$http_proxy" = owned-by-env-setup ] || {
    printf '%s\n' 'Bash clashctl off cleared externally managed proxy variables' >&2
    exit 99
}
EOF

if bash "$test_root/probe.bash" "$test_root"; then
    echo 'PASS: Zsh delegates clashctl implementation to Bash'
    echo 'PASS: Bash honors external proxy ownership'
    exit 0
fi

echo 'FAIL: Bash external proxy ownership'
exit 1
