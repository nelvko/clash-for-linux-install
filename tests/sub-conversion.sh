#!/usr/bin/env bash
# 真实 yq 参与校验；网络、转换器和内核只操作临时目录。
set -euo pipefail
REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
export CLASHCTL_HOME="$WORK_DIR" CLASHCTL_KERNEL=mihomo
. "$REPO_DIR/scripts/lib/common.sh"
. "$REPO_DIR/scripts/lib/config.sh"
. "$REPO_DIR/scripts/lib/convert.sh"
BIN_YQ=$(command -v yq)
BIN_KERNEL="$WORK_DIR/kernel"
cat >"$BIN_KERNEL" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
    if [ "$1" = -f ]; then
        ! grep -q 'kernel-invalid' "$2"
        exit
    fi
    shift
done
exit 1
SH
chmod +x "$BIN_KERNEL"
printf 'proxies: [{name: node, type: socks5, server: localhost, port: 1080}]\n' >"$WORK_DIR/valid.yaml"
printf 'proxy-providers: {remote: {type: http, url: "https://example.invalid/sub"}}\n' >"$WORK_DIR/provider.yaml"
DEST="$WORK_DIR/download.yaml"
CONVERTED="$WORK_DIR/valid.yaml"
CONVERT_RC=0
_download_raw_config() { cp "$SOURCE" "$1"; }
_download_convert_config() {
    printf 'convert\n' >>"$WORK_DIR/conversions"
    [ "$CONVERT_RC" = 0 ] || return "$CONVERT_RC"
    cp "$CONVERTED" "$1"
}
run_download() {
    rm -f "$DEST" "$DEST.raw" "$WORK_DIR/conversions"
    _download_config "$DEST" 'https://example.invalid/sub' "${1:-true}" >"$WORK_DIR/output" 2>&1
}

for SOURCE in "$WORK_DIR/valid.yaml" "$WORK_DIR/provider.yaml"; do
    run_download || fail 'valid subscription rejected'
    cmp "$SOURCE" "$DEST" || fail 'valid subscription changed'
    [ ! -e "$WORK_DIR/conversions" ] || fail 'valid subscription was converted'
    run_download false || fail 'raw mode rejected valid subscription'
done

# 原生配置内核校验失败和非原生订阅走相同的转换流程。
printf 'encoded-subscription\n' >"$WORK_DIR/encoded"
{ cat "$WORK_DIR/valid.yaml"; printf '# kernel-invalid\n'; } >"$WORK_DIR/invalid.yaml"
for SOURCE in "$WORK_DIR/encoded" "$WORK_DIR/invalid.yaml"; do
    run_download || fail 'conversion fallback failed'
    [ "$(wc -l <"$WORK_DIR/conversions")" = 1 ] || fail 'fallback converted more than once'
    cmp "$SOURCE" "$DEST.raw" || fail 'fallback lost original subscription'
    cmp "$CONVERTED" "$DEST" || fail 'fallback did not produce converted subscription'
    if run_download false; then fail 'raw mode accepted invalid subscription'; fi
    [ ! -e "$WORK_DIR/conversions" ] || fail 'raw mode invoked converter'
done

CONVERT_RC=1
if run_download; then fail 'converter failure reported success'; fi
CONVERT_RC=0
for value in '{}' 'proxies: []' 'proxies: {append: [bad]}' 'proxy-providers: [bad]' 'proxies: ['; do
    printf '%s\n' "$value" >"$WORK_DIR/bad-converted.yaml"
    CONVERTED="$WORK_DIR/bad-converted.yaml"
    if run_download; then fail 'invalid converted subscription accepted'; fi
    if _valid_sub_nodes "$CONVERTED" >/dev/null 2>&1; then fail 'invalid node structure accepted'; fi
done
# 即使结构看似有效，查询器异常也不能当成校验成功。
if BIN_YQ=/bin/false _valid_sub_nodes "$WORK_DIR/valid.yaml" >/dev/null 2>&1; then
    fail 'yq failure accepted'
fi
SOURCE="$WORK_DIR/html"
printf '<html><body>error</body></html>\n' >"$SOURCE"
if run_download; then fail 'HTML subscription accepted'; fi
[ ! -e "$WORK_DIR/conversions" ] || fail 'HTML response reached converter'
printf 'sub-conversion: ok\n'
