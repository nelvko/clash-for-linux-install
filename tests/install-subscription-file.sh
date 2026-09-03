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
    local file=$1 value=$2 description=$3
    grep -Fqs -- "$value" "$file" || fail "$description: missing [$value]"
}

assert_not_contains() {
    local file=$1 value=$2 description=$3
    if grep -Fqs -- "$value" "$file"; then
        fail "$description: unexpectedly found [$value]"
    fi
}

assert_env_name_absent() {
    local file=$1 name=$2 description=$3
    if grep -Eqs "^${name}=" "$file"; then
        fail "$description: environment contains [$name]"
    fi
}

# 隔离默认安装目标：用例曾依赖「拒绝换源」兜底防止写真实家；自动续装
# 上线后该兜底消失，任何无 --home 的 main 调用都可能动 ~/.clashctl
ISOLATED_HOME="$WORK_DIR/isolated-home"
mkdir -p -- "$ISOLATED_HOME"
export CLASHCTL_INSTALL_SOURCE_ONLY=1 CLASHCTL_COLOR=never CLASHCTL_HOME="$ISOLATED_HOME"
# shellcheck source=../install.sh
. "$REPO_DIR/install.sh"
# shellcheck source=../scripts/lib/install-transaction.sh
. "$REPO_DIR/scripts/lib/install-transaction.sh"
# shellcheck source=../scripts/cmd/install.sh
. "$REPO_DIR/scripts/cmd/install.sh"

secret_url='https://subscription.invalid/api?token=argv-secret-123'
secure_file="$WORK_DIR/subscription.url"
stdout_file="$WORK_DIR/stdout"
stderr_file="$WORK_DIR/stderr"
printf '%s\n' "$secret_url" >"$secure_file"
chmod 0600 "$secure_file"

result=$(_ci_read_subscription_file "$secure_file" 2>"$stderr_file") ||
    fail 'secure subscription file was rejected'
assert_eq "$secret_url" "$result" 'secure subscription file value'
[ ! -s "$stderr_file" ] || fail 'secure subscription file produced diagnostics'

hostile_file_env="$WORK_DIR/hostile-file.env"
: >"$hostile_file_env"
# shellcheck disable=SC2030,SC2317  # 隔离 hostile 环境；stat/tr 由被测函数间接调用
(
    export HOSTILE_ENV_LOG=$hostile_file_env
    export raw=hostile-raw value=hostile-value
    stat() {
        /usr/bin/env >>"$HOSTILE_ENV_LOG"
        /usr/bin/stat "$@"
    }
    tr() {
        /usr/bin/env >>"$HOSTILE_ENV_LOG"
        /usr/bin/tr "$@"
    }
    hostile_result=$(_ci_read_subscription_file "$secure_file") ||
        fail 'hostile exported variables broke subscription-file reading'
    assert_eq "$secret_url" "$hostile_result" 'hostile subscription-file value'
)
assert_not_contains "$hostile_file_env" "$secret_url" \
    'subscription URL is absent from file-reader child environments'
assert_env_name_absent "$hostile_file_env" raw \
    'file reader clears inherited raw export state'
assert_env_name_absent "$hostile_file_env" value \
    'file reader clears inherited value export state'

hostile_prompt_env="$WORK_DIR/hostile-prompt.env"
: >"$hostile_prompt_env"
# shellcheck disable=SC2031,SC2317  # 第二个隔离环境；tr 由输入校验间接调用
(
    export HOSTILE_ENV_LOG=$hostile_prompt_env
    export answer=hostile-answer value=hostile-value
    tr() {
        /usr/bin/env >>"$HOSTILE_ENV_LOG"
        /usr/bin/tr "$@"
    }
    prompt_result=$(_ci_read_subscription <<<"$secret_url" 2>/dev/null) ||
        fail 'hostile exported variables broke hidden subscription input'
    assert_eq "$secret_url" "$prompt_result" 'hidden subscription input value'
)
assert_not_contains "$hostile_prompt_env" "$secret_url" \
    'subscription URL is absent from prompt-validation child environments'
assert_env_name_absent "$hostile_prompt_env" answer \
    'hidden input clears inherited answer export state'
assert_env_name_absent "$hostile_prompt_env" value \
    'hidden input validation clears inherited value export state'

no_lf_file="$WORK_DIR/no-lf.url"
printf '%s' "$secret_url" >"$no_lf_file"
chmod 0400 "$no_lf_file"
result=$(_ci_read_subscription_file "$no_lf_file" 2>"$stderr_file") ||
    fail '0400 subscription file without trailing LF was rejected'
assert_eq "$secret_url" "$result" 'subscription file without trailing LF'

chmod 0644 "$secure_file"
rc=0
_ci_read_subscription_file "$secure_file" >"$stdout_file" 2>"$stderr_file" || rc=$?
assert_eq 1 "$rc" 'world-readable subscription file is rejected'
[ ! -s "$stdout_file" ] || fail 'unsafe subscription file leaked data to stdout'
assert_not_contains "$stderr_file" "$secret_url" 'unsafe mode diagnostic redacts the URL'
assert_contains "$stderr_file" '权限不安全' 'unsafe mode diagnostic is actionable'
chmod 0600 "$secure_file"

chmod 0700 "$secure_file"
rc=0
_ci_read_subscription_file "$secure_file" >"$stdout_file" 2>"$stderr_file" || rc=$?
assert_eq 1 "$rc" 'executable subscription file is rejected'
assert_not_contains "$stderr_file" "$secret_url" 'executable-file diagnostic redacts the URL'
chmod 0600 "$secure_file"

ln -s -- "$secure_file" "$WORK_DIR/subscription.link"
rc=0
_ci_read_subscription_file "$WORK_DIR/subscription.link" \
    >"$stdout_file" 2>"$stderr_file" || rc=$?
assert_eq 1 "$rc" 'subscription symlink is rejected'
assert_not_contains "$stderr_file" "$secret_url" 'symlink diagnostic redacts the URL'

multiline="$WORK_DIR/multiline.url"
printf '%s\n%s\n' "$secret_url" 'https://second.invalid/' >"$multiline"
chmod 0600 "$multiline"
rc=0
_ci_read_subscription_file "$multiline" >"$stdout_file" 2>"$stderr_file" || rc=$?
assert_eq 1 "$rc" 'multiline subscription file is rejected'
assert_not_contains "$stderr_file" "$secret_url" 'multiline diagnostic redacts the URL'
assert_contains "$stderr_file" '只能包含一行' 'multiline diagnostic is actionable'

double_lf="$WORK_DIR/double-lf.url"
printf '%s\n\n' "$secret_url" >"$double_lf"
chmod 0600 "$double_lf"
rc=0
_ci_read_subscription_file "$double_lf" >"$stdout_file" 2>"$stderr_file" || rc=$?
assert_eq 1 "$rc" 'subscription file with an extra empty line is rejected'
assert_not_contains "$stderr_file" "$secret_url" 'extra-line diagnostic redacts the URL'

nul_file="$WORK_DIR/nul.url"
printf 'https://subscription.invalid/\000suffix\n' >"$nul_file"
chmod 0600 "$nul_file"
rc=0
_ci_read_subscription_file "$nul_file" >"$stdout_file" 2>"$stderr_file" || rc=$?
assert_eq 1 "$rc" 'NUL-containing subscription file is rejected'
assert_contains "$stderr_file" 'NUL' 'NUL diagnostic is actionable'
for nul_position in first last; do
    nul_file="$WORK_DIR/nul-$nul_position.url"
    case $nul_position in
    first) printf '\000https://subscription.invalid/\n' >"$nul_file" ;;
    last) printf 'https://subscription.invalid/\000' >"$nul_file" ;;
    esac
    chmod 0600 "$nul_file"
    rc=0
    _ci_read_subscription_file "$nul_file" >"$stdout_file" 2>"$stderr_file" || rc=$?
    assert_eq 1 "$rc" "NUL at $nul_position is rejected"
    assert_contains "$stderr_file" 'NUL' "NUL-at-$nul_position diagnostic is actionable"
done

empty_line="$WORK_DIR/empty-line.url"
printf '\n' >"$empty_line"
chmod 0600 "$empty_line"
rc=0
_ci_read_subscription_file "$empty_line" >"$stdout_file" 2>"$stderr_file" || rc=$?
assert_eq 1 "$rc" 'empty subscription line is rejected'
assert_contains "$stderr_file" '不能为空' 'empty-line diagnostic is actionable'

rc=0
main "$secret_url" >"$stdout_file" 2>"$stderr_file" || rc=$?
assert_eq 1 "$rc" 'subscription URL argv is rejected'
assert_not_contains "$stderr_file" "$secret_url" 'argv rejection redacts the URL'
assert_contains "$stderr_file" '不再支持把订阅链接直接放入命令行' \
    'argv rejection explains the privacy boundary'

mixed_case_url='HTTPS://subscription.invalid/api?token=mixed-case-secret'
rc=0
main "$mixed_case_url" >"$stdout_file" 2>"$stderr_file" || rc=$?
assert_eq 1 "$rc" 'mixed-case subscription URL argv is rejected'
assert_not_contains "$stderr_file" "$mixed_case_url" 'mixed-case argv rejection redacts the URL'
assert_contains "$stderr_file" '不再支持把订阅链接直接放入命令行' \
    'mixed-case argv rejection explains the privacy boundary'

rc=0
CLASHCTL_SUB_URL=$secret_url main >"$stdout_file" 2>"$stderr_file" || rc=$?
assert_eq 1 "$rc" 'subscription URL environment input is rejected'
assert_not_contains "$stderr_file" "$secret_url" 'environment rejection redacts the URL'
assert_contains "$stderr_file" '泄漏到子进程环境' \
    'environment rejection explains the privacy boundary'

url_shaped_file_arg='https://subscription.invalid/api?token=file-option-secret'
rc=0
main --subscription-file="$url_shaped_file_arg" >"$stdout_file" 2>"$stderr_file" || rc=$?
assert_eq 1 "$rc" 'URL-shaped subscription file argument is rejected'
assert_not_contains "$stderr_file" "$url_shaped_file_arg" \
    'URL-shaped file diagnostic does not echo the argument'

fake_bin="$WORK_DIR/bin"
reexec_output="$WORK_DIR/reexec.args"
mkdir -p -- "$fake_bin"
cat >"$fake_bin/bash" <<'EOF'
#!/bin/sh
{
    printf 'env-url=%s\n' "${CLASHCTL_SUB_URL-}"
    printf 'env-file=%s\n' "${CLASHCTL_SUBSCRIPTION_FILE-}"
    printf 'env-local-url=%s\n' "${sub_url-}"
    printf 'arg=%s\n' "$@"
} >"$REEXEC_OUTPUT"
EOF
chmod 0700 "$fake_bin/bash"
# shellcheck disable=SC2030  # re-exec 必须在子 Shell 内替换进程
(
    export PATH="$fake_bin:$PATH" REEXEC_OUTPUT="$reexec_output"
    unset CLASHCTL_SUBSCRIPTION_FILE CLASHCTL_SUB_URL
    _install_reexec /installed/install.sh /installed iu mihomo "$secure_file"
)
assert_not_contains "$reexec_output" "$secret_url" 'installer re-exec argv and environment redact URL'
assert_contains "$reexec_output" 'env-url=' 'installer re-exec clears URL environment state'
assert_contains "$reexec_output" 'env-file=' 'installer re-exec clears file environment state'
assert_contains "$reexec_output" 'arg=--subscription-file' 'installer re-exec uses file option'
assert_contains "$reexec_output" "arg=$secure_file" 'installer re-exec passes only the file path'

main_reexec_output="$WORK_DIR/main-reexec.args"
# shellcheck disable=SC2031,SC2317  # 独立 main 会 exec；两个函数是定向测试桩
(
    export PATH="$fake_bin:$PATH" REEXEC_OUTPUT=$main_reexec_output
    export sub_url=hostile-exported-sub-url
    export CLASHCTL_INSTALL_SESSION=1
    unset CLASHCTL_LOCAL_SOURCE CLASHCTL_SUBSCRIPTION_FILE CLASHCTL_SUB_URL
    _install_validate_home_path() { :; }
    _require_empty_home() { _INSTALL_HOME_STATE=new; }
    main --home "$WORK_DIR/reexec-home" --source-dir "$REPO_DIR" \
        --subscription-file "$secure_file" mihomo
) >"$WORK_DIR/main-reexec.stdout" 2>"$WORK_DIR/main-reexec.stderr"
assert_not_contains "$main_reexec_output" "$secret_url" \
    'main keeps subscription URL out of re-exec environment'
assert_not_contains "$main_reexec_output" 'hostile-exported-sub-url' \
    'main clears hostile outer sub_url export state'
assert_contains "$main_reexec_output" 'env-local-url=' \
    'main re-exec has no lowercase subscription URL environment value'

printf '%s\n' 'install-subscription-file: ok'
