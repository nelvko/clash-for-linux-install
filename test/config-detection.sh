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

assert_file_eq() {
    local expected=$1 file=$2 description=$3
    assert_eq "$expected" "$(<"$file")" "$description"
}

BIN_YQ="$WORK_DIR/yq"
CLASH_CONFIG_RUNTIME="$WORK_DIR/runtime.yaml"
CLASH_CONFIG_MIXIN="$WORK_DIR/mixin.yaml"
export BIN_YQ CLASH_CONFIG_RUNTIME CLASH_CONFIG_MIXIN

cat >"$BIN_YQ" <<'EOF'
#!/usr/bin/env bash
case ${1:-} in
'[.bind-address'*|'[.mixed-port'*|'.external-controller'*)
    [ "${YQ_READ_RC:-0}" -eq 0 ] || exit "$YQ_READ_RC"
    case $1 in
    '[.bind-address'*) printf '%s\n' "${YQ_BIND_VALUES:-*|false}" ;;
    '[.mixed-port'*) printf '%s\n' "${YQ_PORTS:-7890||}" ;;
    *) printf '%s\n' "${YQ_EXT_ADDR-127.0.0.1:9090}" ;;
    esac
    ;;
-i)
    [ "${YQ_WRITE_RC:-0}" -eq 0 ] || exit "$YQ_WRITE_RC"
    [ -z "${YQ_WRITE_CAPTURE:-}" ] || printf '%s\n' "${EXT_ADDR:-}" >"$YQ_WRITE_CAPTURE"
    ;;
*) exit 64 ;;
esac
EOF
chmod 0700 "$BIN_YQ"

# shellcheck source=../scripts/lib/config.sh
. "$REPO_DIR/scripts/lib/config.sh"

USED_PORTS=
SERVICE_ACTIVE=0
NEXT_PORT=23456
MERGE_RC=0
LOCAL_IP=192.0.2.10

_is_port_used() {
    case " $USED_PORTS " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
    esac
}

service_is_active() {
    [ "$SERVICE_ACTIVE" -eq 1 ]
}

_get_random_port() {
    printf '%s\n' "$NEXT_PORT"
}

_get_local_ip() {
    printf '%s\n' "$LOCAL_IP"
}

_merge_config() {
    return "$MERGE_RC"
}

_ui_warn() {
    printf '[WARN] %s\n' "$*" >&2
}

_ui_error() {
    printf '[ERROR] %s\n' "$*" >&2
}

run_probe() {
    local label=$1
    shift
    RUN_RC=0
    "$@" >"$WORK_DIR/$label.stdout" 2>"$WORK_DIR/$label.stderr" || RUN_RC=$?
    RUN_STDERR="$WORK_DIR/$label.stderr"
}

export YQ_READ_RC=0 YQ_WRITE_RC=0 YQ_BIND_VALUES='*|false'
export YQ_PORTS='7890||' YQ_EXT_ADDR='127.0.0.1:9090'
export YQ_WRITE_CAPTURE=

run_probe bind-address _get_bind_addr
assert_eq 0 "$RUN_RC" 'bind address read succeeds'
assert_eq '127.0.0.1' "$(<"$WORK_DIR/bind-address.stdout")" \
    'disabled LAN access uses loopback'

export YQ_BIND_VALUES='*|true'
LOCAL_IP=
run_probe bind-address-missing _get_bind_addr
assert_eq 1 "$RUN_RC" 'missing LAN address is reported'
assert_contains "$RUN_STDERR" '无法确定局域网监听地址' \
    'missing LAN address diagnosis'
LOCAL_IP=192.0.2.10
export YQ_BIND_VALUES='*|false'

run_probe proxy-no-conflict _detect_proxy_port
assert_eq 0 "$RUN_RC" 'no proxy port conflict is a successful no-op'

run_probe controller-no-conflict _detect_ext_addr
assert_eq 0 "$RUN_RC" 'no controller port conflict is a successful no-op'
assert_eq 127.0.0.1 "$EXT_IP" 'IPv4 controller host is preserved for display'
assert_eq 9090 "$EXT_PORT" 'controller port is parsed'

export YQ_EXT_ADDR='controller.example:19090'
run_probe controller-hostname _detect_ext_addr
assert_eq 0 "$RUN_RC" 'hostname controller address is accepted'
assert_eq controller.example "$EXT_IP" 'hostname controller address is parsed'
assert_eq 19090 "$EXT_PORT" 'hostname controller port is parsed'

export YQ_EXT_ADDR='[2001:db8::1]:29090'
run_probe controller-ipv6 _detect_ext_addr
assert_eq 0 "$RUN_RC" 'bracketed IPv6 controller address is accepted'
assert_eq '2001:db8::1' "$EXT_IP" 'IPv6 controller host is unwrapped for display'
assert_eq 29090 "$EXT_PORT" 'IPv6 controller port is parsed'

for invalid_addr in '' 'controller.example' 'controller.example:0' \
    'controller.example:65536' 'controller.example:not-a-port' '2001:db8::1:9090'; do
    export YQ_EXT_ADDR=$invalid_addr
    run_probe controller-invalid _detect_ext_addr
    assert_eq 1 "$RUN_RC" "invalid controller address is rejected: [$invalid_addr]"
    assert_contains "$RUN_STDERR" '控制器地址无效' \
        "invalid controller address diagnosis: [$invalid_addr]"
done

LOCAL_IP=
for wildcard_addr in '0.0.0.0:9090' '[::]:9090'; do
    export YQ_EXT_ADDR=$wildcard_addr
    run_probe controller-display-address-missing _detect_ext_addr
    assert_eq 1 "$RUN_RC" "missing controller display address is reported: [$wildcard_addr]"
    assert_contains "$RUN_STDERR" '无法确定控制器的本机访问地址' \
        "missing controller display address diagnosis: [$wildcard_addr]"
done

LOCAL_IP=192.0.2.10
export YQ_EXT_ADDR='[::]:9090' USED_PORTS=9090 YQ_WRITE_CAPTURE="$WORK_DIR/ext-write"
run_probe controller-ipv6-conflict _detect_ext_addr
assert_eq 0 "$RUN_RC" 'IPv6 wildcard controller conflict is adjusted'
assert_file_eq '[::]:23456' "$YQ_WRITE_CAPTURE" \
    'controller conflict write preserves the bracketed IPv6 listener host'
assert_eq 192.0.2.10 "$EXT_IP" 'IPv6 wildcard uses the local display address'
assert_eq 23456 "$EXT_PORT" 'controller conflict publishes the adjusted port'

export YQ_READ_RC=71
run_probe bind-read-failure _get_bind_addr
assert_eq 1 "$RUN_RC" 'bind address read failure is reported'
assert_contains "$RUN_STDERR" '无法读取运行配置中的监听地址' \
    'bind address read failure diagnosis'

run_probe proxy-read-failure _detect_proxy_port
assert_eq 1 "$RUN_RC" 'proxy port read failure is reported'
assert_contains "$RUN_STDERR" '无法读取运行配置中的代理端口' \
    'proxy port read failure diagnosis'

run_probe controller-read-failure _detect_ext_addr
assert_eq 1 "$RUN_RC" 'controller address read failure is reported'
assert_contains "$RUN_STDERR" '无法读取运行配置中的控制器地址' \
    'controller address read failure diagnosis'

export YQ_READ_RC=0 YQ_WRITE_RC=72 USED_PORTS='7890'
run_probe proxy-write-failure _detect_proxy_port
assert_eq 1 "$RUN_RC" 'proxy port write failure is reported'
assert_contains "$RUN_STDERR" '无法写入随机代理端口' \
    'proxy port write failure diagnosis'

export YQ_EXT_ADDR='127.0.0.1:9090' YQ_WRITE_CAPTURE=
export YQ_WRITE_RC=0 USED_PORTS='9090' MERGE_RC=1
run_probe controller-merge-failure _detect_ext_addr
assert_eq 1 "$RUN_RC" 'controller merge failure is reported'
assert_contains "$RUN_STDERR" '控制器端口已调整，但运行配置更新失败' \
    'controller merge failure diagnosis'

printf 'config-detection: ok\n'
