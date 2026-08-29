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

assert_not_contains() {
    local file=$1 unexpected=$2 description=$3
    grep -Fqs -- "$unexpected" "$file" &&
        fail "$description: unexpectedly found [$unexpected]"
    return 0
}

assert_no_ansi() {
    local file=$1 content
    content=$(<"$file")
    case $content in
    *$'\033['*) fail "$2: unexpected ANSI escape" ;;
    esac
}

assert_has_ansi() {
    local file=$1 content
    content=$(<"$file")
    case $content in
    *$'\033['*) return 0 ;;
    *) fail "$2: ANSI escape not found" ;;
    esac
}

export CLASHCTL_INSTALL_SOURCE_ONLY=1
# shellcheck source=../install.sh
. "$REPO_DIR/install.sh"
# shellcheck source=../scripts/lib/install-transaction.sh
. "$REPO_DIR/scripts/lib/install-transaction.sh"
# shellcheck source=../scripts/lib/service-enablement.sh
. "$REPO_DIR/scripts/lib/service-enablement.sh"
# shellcheck source=../scripts/cmd/install.sh
. "$REPO_DIR/scripts/cmd/install.sh"

impact_line=$(awk '/^    _install_impact_scan .*install_manager/{ print NR; exit }' "$REPO_DIR/scripts/cmd/install.sh")
prompt_line=$(awk '/sub_url=\$\(_ci_read_subscription\)/{ print NR; exit }' "$REPO_DIR/scripts/cmd/install.sh")
runtime_write_line=$(awk '/^    \/usr\/bin\/install -d -m 0700 "\$CLASH_DATA_DIR"/{ print NR; exit }' \
    "$REPO_DIR/scripts/cmd/install.sh")
prepare_line=$(awk '/^    prepare_zip /{ print NR; exit }' "$REPO_DIR/scripts/cmd/install.sh")
if [ -z "$impact_line" ] || [ -z "$prompt_line" ] ||
    [ -z "$runtime_write_line" ] || [ -z "$prepare_line" ]; then
    fail 'installer phase boundaries were not found'
fi
[ "$impact_line" -lt "$prompt_line" ] ||
    fail 'initial subscription prompt runs before service takeover confirmation'
[ "$prompt_line" -lt "$runtime_write_line" ] ||
    fail 'initial subscription prompt runs after runtime directory writes'
[ "$prompt_line" -lt "$prepare_line" ] ||
    fail 'initial subscription prompt runs after dependency preparation'

stdout_file="$WORK_DIR/stdout"
stderr_file="$WORK_DIR/stderr"

unset NO_COLOR CI
export TERM=xterm CLASHCTL_COLOR=never

: >"$stdout_file"
: >"$stderr_file"
export CLASHCTL_NON_INTERACTIVE=1
_install_plan "$WORK_DIR/plan-home" default mihomo master '' '' \
    >"$stdout_file" 2>"$stderr_file"
unset CLASHCTL_NON_INTERACTIVE
[ ! -s "$stdout_file" ] || fail 'installation plan wrote to stdout'
assert_contains "$stderr_file" 'clashctl 安装计划' 'installation plan has an explicit heading'
assert_contains "$stderr_file" '程序目录:' 'installation plan discloses home directory'
assert_contains "$stderr_file" '代理内核:' 'installation plan discloses kernel choice'
assert_contains "$stderr_file" 'Shell 集成:' 'installation plan discloses shell integration'
assert_contains "$stderr_file" '初始订阅: 未提供；非交互环境将跳过' \
    'non-interactive plan truthfully reports skipped subscription input'
assert_not_contains "$stderr_file" '稍后询问' \
    'non-interactive plan does not promise a later prompt'

: >"$stderr_file"
export CLASHCTL_NON_INTERACTIVE=1
_install_plan "$WORK_DIR/systemd-home" --home mihomo master '' '' \
    >"$stdout_file" 2>"$stderr_file"
unset CLASHCTL_NON_INTERACTIVE
assert_contains "$stderr_file" '程序目录: '"$WORK_DIR"'/systemd-home（--home）' \
    'plan honors explicit --home argument'
assert_contains "$stderr_file" 'clashctl install 下载并配置服务' \
    'plan routes service provisioning through clashctl install'

: >"$stdout_file"
: >"$stderr_file"
usage >"$stdout_file" 2>"$stderr_file"
assert_contains "$stdout_file" '--verbose                 显示下载进度与失败诊断' \
    'verbose help covers progress and failure diagnostics'
assert_contains "$REPO_DIR/scripts/cmd/install.sh" 'Web 访问密钥已生成（不会在输出中显示）' \
    'generated-secret message describes output privacy'
assert_not_contains "$REPO_DIR/scripts/cmd/install.sh" 'Web 访问密钥已生成（不会写入安装日志）' \
    'generated-secret message no longer overstates logging behavior'

: >"$stdout_file"
: >"$stderr_file"
for level in step ok warn error question header info unknown; do
    rc=0
    _ui_emit "$level" "message-$level" >>"$stdout_file" 2>>"$stderr_file" || rc=$?
    assert_eq 0 "$rc" "_ui_emit $level always succeeds"
done
[ ! -s "$stdout_file" ] || fail '_ui_emit wrote to stdout'
for level in step ok warn error question header info unknown; do
    assert_contains "$stderr_file" "message-$level" "_ui_emit $level writes to stderr"
done

capture_color() {
    : >"$stdout_file"
    : >"$stderr_file"
    local rc=0
    _ui_emit info color-check >"$stdout_file" 2>"$stderr_file" || rc=$?
    assert_eq 0 "$rc" '_ui_emit color case succeeds'
    [ ! -s "$stdout_file" ] || fail '_ui_emit color case wrote to stdout'
}

unset NO_COLOR CI
export TERM=xterm CLASHCTL_COLOR=always
capture_color
assert_has_ansi "$stderr_file" 'CLASHCTL_COLOR=always forces color'

export NO_COLOR=
capture_color
assert_no_ansi "$stderr_file" 'NO_COLOR overrides always'

unset NO_COLOR CI
export TERM=dumb CLASHCTL_COLOR=auto
capture_color
assert_no_ansi "$stderr_file" 'TERM=dumb disables auto color'

export TERM=xterm CI=1
capture_color
assert_no_ansi "$stderr_file" 'CI disables auto color'

export CLASHCTL_COLOR=always
capture_color
assert_has_ansi "$stderr_file" 'always explicitly overrides CI auto policy'

unset CI
export CLASHCTL_COLOR=never
capture_color
assert_no_ansi "$stderr_file" 'CLASHCTL_COLOR=never disables color'

random_env_file="$WORK_DIR/random.env"
: >"$random_env_file"
_get_random_val() {
    /usr/bin/env >>"$random_env_file"
    printf 'aB3xY9'
}
export secret=hostile-secret part=hostile-part
generated_secret=$(_ci_generate_secret) || fail 'secret generation failed'
unset secret part
assert_eq 32 "${#generated_secret}" 'generated secret uses 32 characters'
case $generated_secret in
*[!a-zA-Z0-9]*) fail 'generated secret contains unsupported characters' ;;
esac
if grep -Eqs '^(secret|part)=' "$random_env_file"; then
    fail 'generated secret or partial value entered a child process environment'
fi

: >"$stdout_file"
: >"$stderr_file"
rc=0
main $'--branch=stable\033[31mCONTROL' >"$stdout_file" 2>"$stderr_file" || rc=$?
assert_eq 1 "$rc" 'control characters in command-line input are rejected'
assert_contains "$stderr_file" '命令行参数不能包含控制字符' 'control-character rejection is actionable'
assert_not_contains "$stderr_file" 'stable' 'rejected command-line input is not echoed'

: >"$stdout_file"
: >"$stderr_file"
rc=0
main $'--branch=stable\n[ERROR] forged-output' >"$stdout_file" 2>"$stderr_file" || rc=$?
assert_eq 1 "$rc" 'newlines in command-line input are rejected'
assert_contains "$stderr_file" '命令行参数不能包含控制字符' 'newline rejection is actionable'
assert_not_contains "$stderr_file" 'forged-output' 'newline input cannot forge installer output'

: >"$stdout_file"
: >"$stderr_file"
rc=0
main --definitely-unknown >"$stdout_file" 2>"$stderr_file" || rc=$?
assert_eq 1 "$rc" 'unknown installer option fails'
[ ! -s "$stdout_file" ] || fail 'unknown installer option polluted stdout with usage text'
assert_contains "$stderr_file" 'Usage:' 'unknown installer option writes usage to stderr'

: >"$stdout_file"
: >"$stderr_file"
rc=0
GH_PROXY=$'https://proxy.invalid/\033[31mCONTROL' \
    main --home "$WORK_DIR/rejected-home" >"$stdout_file" 2>"$stderr_file" || rc=$?
assert_eq 1 "$rc" 'control characters in proxy input are rejected'
assert_contains "$stderr_file" '下载代理地址不能包含控制字符' 'proxy rejection identifies the field'
assert_not_contains "$stderr_file" 'proxy.invalid' 'rejected proxy input is not echoed'

export CLASHCTL_HOME="$WORK_DIR/completion home"
export CLASHCTL_CMD_DIR="$CLASHCTL_HOME/scripts/cmd"
export _INSTALL_VERIFIED_CONTROLLER=127.0.0.1:9090
CLASHCTL_SERVICE_CONFLICT=0
apply_rc_result=0

apply_rc() {
    return "$apply_rc_result"
}

: >"$stderr_file"
rc=0
_install_finish nohup '未配置' 2>"$stderr_file" || rc=$?
assert_eq 0 "$rc" 'successful shell integration keeps installation successful'
assert_contains "$stderr_file" '[ OK ] clashctl 安装完成' 'full completion reports success'

apply_rc_result=2
: >"$stderr_file"
rc=0
_install_finish nohup '未配置' 2>"$stderr_file" || rc=$?
assert_eq 0 "$rc" 'manual shell loading remains a successful installation'
assert_contains "$stderr_file" '[ OK ] clashctl 核心安装完成' 'manual shell state reports core success'
assert_contains "$stderr_file" '[WARN] 未检测到可更新的 Shell 启动文件' 'manual shell state reports its limitation'
assert_contains "$stderr_file" 'source ' 'manual shell state provides a load command'

apply_rc_result=1
: >"$stderr_file"
rc=0
_install_finish nohup '未配置' 2>"$stderr_file" || rc=$?
assert_eq 1 "$rc" 'shell integration failure makes the installer fail'
assert_contains "$stderr_file" '[ERROR] clashctl 服务与数据已安装，但 Shell 命令集成失败' \
    'shell integration failure reports the committed installation state'
assert_not_contains "$stderr_file" '[ OK ] clashctl 安装完成' \
    'shell integration failure is not reported as full success'

apply_rc_result=0
: >"$stderr_file"
rc=0
_install_finish nohup '未配置' incomplete 2>"$stderr_file" || rc=$?
assert_eq 1 "$rc" 'transaction cleanup failure makes the installer fail'
assert_contains "$stderr_file" '[ERROR] clashctl 已安装并运行，但服务事务清理未完成' \
    'transaction cleanup failure reports the committed partial state'
assert_not_contains "$stderr_file" '[ OK ] clashctl 安装完成' \
    'transaction cleanup failure is not reported as full success'

fake_bin="$WORK_DIR/bin"
mkdir -p -- "$fake_bin"
cat >"$fake_bin/date" <<'EOF'
#!/usr/bin/env sh
printf '%s\n' 20260826-120000
EOF
chmod +x -- "$fake_bin/date"
PATH="$fake_bin:$PATH"

unit="$WORK_DIR/mihomo.service"
systemd_etc="$WORK_DIR/systemd/etc"
systemd_run="$WORK_DIR/systemd/run"
mkdir -p -- "$systemd_etc" "$systemd_run"
export HOME="$WORK_DIR/home"
install_home="${HOME}/clashctl"
mkdir -p -- "$install_home"
export CLASHCTL_HOME="$install_home" CLASHCTL_KERNEL=mihomo
cat >"$unit" <<'EOF'
[Service]
ExecStart=/foreign/bin/mihomo -d /foreign/data
EOF

_install_service_target() {
    printf '%s\n' "$unit"
}

SERVICE_SOURCE=$unit
_install_existing_service() {
    [ -n "$SERVICE_SOURCE" ] || return 1
    printf '%s\n' "$SERVICE_SOURCE"
}

SERVICE_ACTIVE_STATE=active
_install_service_active_state() {
    [ "$SERVICE_ACTIVE_STATE" != unknown ] || return 1
    printf '%s\n' "$SERVICE_ACTIVE_STATE"
}

_install_service_is_enabled() {
    return 1
}

service_enablement_systemd_persistent_root() {
    printf '%s\n' "$systemd_etc"
}

service_enablement_systemd_runtime_root() {
    printf '%s\n' "$systemd_run"
}

SYSTEMD_ENABLEMENT_STATE=disabled
service_enablement_systemd_state() {
    printf '%s\n' "$SYSTEMD_ENABLEMENT_STATE"
}

service_enablement_systemd_unit_path() {
    printf '%s\n' "$unit"
}

service_enablement_systemd_reload() {
    return 0
}

reset_service_state() {
    unset CLASHCTL_SERVICE_MANAGER CLASHCTL_SERVICE_TARGET
    unset CLASHCTL_SERVICE_TARGET_EXISTED CLASHCTL_SERVICE_SOURCE
    unset CLASHCTL_SERVICE_BACKUP CLASHCTL_SERVICE_BACKUP_CREATED
    unset CLASHCTL_SERVICE_WAS_ACTIVE CLASHCTL_SERVICE_CONFLICT
    unset CLASHCTL_SERVICE_WAS_ENABLED CLASHCTL_SERVICE_JOURNAL
    unset CLASHCTL_SERVICE_ENABLE_LINK CLASHCTL_SERVICE_ENABLE_KIND
    unset CLASHCTL_SERVICE_ENABLE_TARGET CLASHCTL_SERVICE_EXPECTED_ENABLE_TARGET
    unset CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL CLASHCTL_SERVICE_ENABLEMENT_INSTALLED
    unset CLASHCTL_SERVICE_ENABLEMENT_STATE CLASHCTL_SERVICE_ENABLEMENT_LINKS
    unset CLASHCTL_ALLOW_UNIT_OVERWRITE CLASHCTL_NON_INTERACTIVE CI
    SERVICE_SOURCE=$unit
    SERVICE_ACTIVE_STATE=active
    SYSTEMD_ENABLEMENT_STATE=disabled
}

backup_base="${unit}.clashctl-bak.20260826-120000"
backup_one="${backup_base}.1"
backup_two="${backup_base}.2"
printf 'keep-base\n' >"$backup_base"
printf 'keep-one\n' >"$backup_one"

stale_dir="$systemd_etc/multi-user.target.wants"
stale_link="$stale_dir/mihomo.service"
mkdir -p -- "$stale_dir"
/usr/bin/rm -f -- "$unit"

reset_service_state
SERVICE_SOURCE=
SERVICE_ACTIVE_STATE=inactive
SYSTEMD_ENABLEMENT_STATE=not-found
export CLASHCTL_NON_INTERACTIVE=1
: >"$stderr_file"
_install_impact_scan "$install_home" mihomo systemd >"$stdout_file" 2>"$stderr_file" ||
    fail 'clean inactive systemd state was not accepted'
assert_eq 0 "$CLASHCTL_SERVICE_CONFLICT" 'clean inactive systemd state is not a conflict'
assert_not_contains "$stderr_file" '发现残留的 systemd 服务状态' \
    'clean inactive systemd state does not emit a stale-state warning'

reset_service_state
SERVICE_SOURCE=
SERVICE_ACTIVE_STATE=active
SYSTEMD_ENABLEMENT_STATE=not-found
export CLASHCTL_NON_INTERACTIVE=1 CLASHCTL_ALLOW_UNIT_OVERWRITE=1
: >"$stderr_file"
rc=0
_install_impact_scan "$install_home" mihomo systemd >"$stdout_file" 2>"$stderr_file" || rc=$?
assert_eq 1 "$rc" 'active missing definition without enablement links is rejected'
assert_contains "$stderr_file" '定义已缺失，但服务仍在运行，无法确认进程归属' \
    'active missing definition without links explains the ownership boundary'
assert_not_contains "$stderr_file" '授权在记录残留状态后继续安装' \
    'takeover authorization cannot bypass an active missing definition without links'

ln -s -- "$unit" "$stale_link"

reset_service_state
SERVICE_SOURCE=
SERVICE_ACTIVE_STATE=inactive
SYSTEMD_ENABLEMENT_STATE=not-found
export CLASHCTL_NON_INTERACTIVE=1
: >"$stdout_file"
: >"$stderr_file"
rc=0
_install_impact_scan "$install_home" mihomo systemd >"$stdout_file" 2>"$stderr_file" || rc=$?
assert_eq 1 "$rc" 'non-interactive stale state is rejected without authorization'
assert_contains "$stderr_file" '发现残留的 systemd 服务状态: mihomo.service' \
    'stale state has a dedicated warning'
assert_contains "$stderr_file" "残留链接: $stale_link -> $unit" \
    'stale state reports the exact link and target'
assert_contains "$stderr_file" '写入服务定义后，现有链接可能重新生效并影响服务自启' \
    'stale state explains the installation impact'
assert_contains "$stderr_file" '恢复安装前的自启状态；当前残留状态不会被自动清理' \
    'stale state explains uninstall behavior'
assert_contains "$stderr_file" '非交互安装不会在归属不明的残留服务状态上继续' \
    'stale state preserves the non-interactive authorization gate'
assert_not_contains "$stderr_file" '备份现有定义' \
    'stale state does not promise to back up a missing definition'
if [ -e "$unit" ] || [ -L "$unit" ]; then
    fail 'stale-state scan created a service definition'
fi
assert_eq "$unit" "$(readlink -- "$stale_link")" 'stale-state scan preserves the existing link'

reset_service_state
SERVICE_SOURCE=
SERVICE_ACTIVE_STATE=inactive
SYSTEMD_ENABLEMENT_STATE=not-found
export CLASHCTL_NON_INTERACTIVE=1 CLASHCTL_ALLOW_UNIT_OVERWRITE=1
: >"$stderr_file"
_install_impact_scan "$install_home" mihomo systemd >"$stdout_file" 2>"$stderr_file" ||
    fail 'explicit authorization did not accept an inactive stale state'
assert_contains "$stderr_file" '授权在记录残留状态后继续安装' \
    'stale-state authorization is reported accurately'
assert_eq '' "$CLASHCTL_SERVICE_SOURCE" 'stale-state authorization records no service source'
assert_eq '' "$CLASHCTL_SERVICE_BACKUP" 'stale-state authorization does not select a definition backup'
assert_eq 1 "$CLASHCTL_SERVICE_CONFLICT" 'stale-state authorization records the conflict gate'
service_enablement_validate systemd mihomo "$CLASHCTL_SERVICE_ENABLEMENT_ORIGINAL" ||
    fail "authorized stale-state snapshot is invalid: $SERVICE_ENABLEMENT_ERROR"
[ -n "$SERVICE_ENABLEMENT_LINKS" ] || fail 'authorized stale-state snapshot omitted the link'
if [ -e "$unit" ] || [ -L "$unit" ]; then
    fail 'authorized stale-state scan created a service definition'
fi
assert_eq "$unit" "$(readlink -- "$stale_link")" 'authorized stale-state scan preserves the link'

/usr/bin/rm -f -- "$stale_link"
hostile_target=$'/missing target\n[ERROR] forged\033[31m'
printf -v hostile_target_display '%q' "$hostile_target"
ln -s -- "$hostile_target" "$stale_link"
reset_service_state
SERVICE_SOURCE=
SERVICE_ACTIVE_STATE=inactive
SYSTEMD_ENABLEMENT_STATE=not-found
export CLASHCTL_NON_INTERACTIVE=1 CLASHCTL_ALLOW_UNIT_OVERWRITE=1
: >"$stderr_file"
_install_impact_scan "$install_home" mihomo systemd >"$stdout_file" 2>"$stderr_file" ||
    fail 'escaped stale-link target was rejected'
assert_contains "$stderr_file" "残留链接: $stale_link -> $hostile_target_display" \
    'stale-link target is rendered with shell escaping'
assert_no_ansi "$stderr_file" 'stale-link target cannot inject terminal escapes'
if grep -Fqx -- '[ERROR] forged' "$stderr_file"; then
    fail 'stale-link target forged a log line'
fi
/usr/bin/rm -f -- "$stale_link"
ln -s -- "$unit" "$stale_link"

reset_service_state
SERVICE_SOURCE=
SERVICE_ACTIVE_STATE=inactive
SYSTEMD_ENABLEMENT_STATE=not-found
prompt_file="$WORK_DIR/stale-confirm-prompt"
: >"$stderr_file"
(
    # shellcheck disable=SC2317  # invoked dynamically by _install_impact_scan
    _ui_confirm() {
        printf '%s\n' "$1" >"$prompt_file"
        return 0
    }
    _install_impact_scan "$install_home" mihomo systemd >"$stdout_file" 2>"$stderr_file"
) || fail 'interactive confirmation did not accept an inactive stale state'
assert_eq '保留上述残留状态并继续安装 mihomo.service？' "$(<"$prompt_file")" \
    'stale state uses the dedicated confirmation prompt'
assert_contains "$stderr_file" '已确认继续安装；残留服务状态尚未修改' \
    'stale-state confirmation reports its read-only boundary'

reset_service_state
SERVICE_SOURCE=
SERVICE_ACTIVE_STATE=active
SYSTEMD_ENABLEMENT_STATE=not-found
export CLASHCTL_NON_INTERACTIVE=1 CLASHCTL_ALLOW_UNIT_OVERWRITE=1
: >"$stderr_file"
rc=0
_install_impact_scan "$install_home" mihomo systemd >"$stdout_file" 2>"$stderr_file" || rc=$?
assert_eq 1 "$rc" 'active service with a missing definition is always rejected'
assert_contains "$stderr_file" '定义已缺失，但服务仍在运行，无法确认进程归属' \
    'active stale service rejection explains the ownership boundary'
assert_not_contains "$stderr_file" '授权在记录残留状态后继续安装' \
    'takeover authorization cannot bypass an unknown active service'
if [ -e "$unit" ] || [ -L "$unit" ]; then
    fail 'active stale-state scan created a service definition'
fi
assert_eq "$unit" "$(readlink -- "$stale_link")" 'active stale-state scan preserves the link'

/usr/bin/rm -f -- "$stale_link"
cat >"$unit" <<'EOF'
[Service]
ExecStart=/foreign/bin/mihomo -d /foreign/data
EOF

reset_service_state
SERVICE_ACTIVE_STATE=unknown
export CLASHCTL_NON_INTERACTIVE=1
export CLASHCTL_ALLOW_UNIT_OVERWRITE=1
: >"$stdout_file"
: >"$stderr_file"
rc=0
_install_impact_scan "$install_home" mihomo systemd >"$stdout_file" 2>"$stderr_file" || rc=$?
assert_eq 1 "$rc" 'unknown active-service state aborts takeover'
assert_contains "$stderr_file" '无法确定现有 mihomo 服务是否正在运行' \
    'unknown service state is diagnosed'
[ ! -e "$backup_two" ] || fail 'unknown service state created a backup'

reset_service_state
SERVICE_ACTIVE_STATE=active
export CLASHCTL_NON_INTERACTIVE=1
: >"$stdout_file"
: >"$stderr_file"
rc=0
_install_impact_scan "$install_home" mihomo systemd >"$stdout_file" 2>"$stderr_file" || rc=$?
assert_eq 1 "$rc" 'non-interactive conflict is rejected by default'
[ ! -s "$stdout_file" ] || fail '_install_impact_scan wrote human output to stdout'
assert_contains "$stderr_file" '非交互安装不会接管现有服务' 'rejection explains non-interactive policy'
assert_eq "$backup_two" "$CLASHCTL_SERVICE_BACKUP" 'collision-free backup is selected'
[ ! -e "$backup_two" ] || fail 'impact scan created a backup before authorization'
assert_eq 1 "$CLASHCTL_SERVICE_WAS_ACTIVE" 'active-service probe result is recorded'

reset_service_state
export CLASHCTL_NON_INTERACTIVE=1
export CLASHCTL_ALLOW_UNIT_OVERWRITE=1
: >"$stdout_file"
: >"$stderr_file"
rc=0
_install_impact_scan "$install_home" mihomo systemd >"$stdout_file" 2>"$stderr_file" || rc=$?
assert_eq 0 "$rc" 'explicit authorization accepts service takeover'
assert_eq 1 "$CLASHCTL_SERVICE_CONFLICT" 'service conflict is recorded'
assert_eq "$unit" "$CLASHCTL_SERVICE_SOURCE" 'service source uses the temporary unit'
assert_eq "$unit" "$CLASHCTL_SERVICE_TARGET" 'service target uses the temporary unit'
assert_eq "$backup_two" "$CLASHCTL_SERVICE_BACKUP" 'authorized scan preserves collision-free name'
[ ! -e "$backup_two" ] || fail 'authorization backed up the service too early'
[ "${CLASHCTL_SERVICE_BACKUP_CREATED:-0}" = 0 ] || fail 'authorization marked a backup as created'
assert_contains "$stderr_file" '授权接管' 'authorization is reported'
assert_contains "$stderr_file" '自动尝试恢复原状态；若恢复不完整，将保留事务快照与备份' \
    'takeover plan describes recovery as an attempt and discloses retained evidence'

journal="$install_home/.service-transaction"
SERVICE_ACTIVE_STATE=unknown
: >"$stderr_file"
rc=0
_install_snapshot_service >"$stdout_file" 2>"$stderr_file" || rc=$?
assert_eq 1 "$rc" 'unknown state during transaction recheck aborts takeover'
assert_contains "$stderr_file" '无法确定现有 mihomo 服务是否正在运行' \
    'unknown transaction recheck is diagnosed'
[ ! -e "$backup_two" ] || fail 'unknown transaction recheck created a backup'
[ ! -e "$journal" ] || fail 'unknown transaction recheck created a journal'

reset_service_state
SERVICE_ACTIVE_STATE=active
export CLASHCTL_NON_INTERACTIVE=1 CLASHCTL_ALLOW_UNIT_OVERWRITE=1
_install_impact_scan "$install_home" mihomo systemd >"$stdout_file" 2>"$stderr_file" ||
    fail 'could not prepare runtime-state change test'
SERVICE_ACTIVE_STATE=inactive
: >"$stderr_file"
rc=0
_install_snapshot_service >"$stdout_file" 2>"$stderr_file" || rc=$?
assert_eq 1 "$rc" 'runtime-state change after confirmation aborts takeover'
assert_contains "$stderr_file" '服务运行状态在确认后发生变化' \
    'runtime-state change is diagnosed'
[ ! -e "$backup_two" ] || fail 'runtime-state change created a backup'
[ ! -e "$journal" ] || fail 'runtime-state change created a journal'

reset_service_state
SERVICE_ACTIVE_STATE=active
export CLASHCTL_NON_INTERACTIVE=1 CLASHCTL_ALLOW_UNIT_OVERWRITE=1
_install_impact_scan "$install_home" mihomo systemd >"$stdout_file" 2>"$stderr_file" ||
    fail 'could not prepare successful transaction test'

_install_snapshot_service >"$stdout_file" 2>"$stderr_file" ||
    fail 'service transaction snapshot failed'
assert_eq 'keep-base' "$(<"$backup_base")" 'existing base backup is not overwritten'
assert_eq 'keep-one' "$(<"$backup_one")" 'existing numbered backup is not overwritten'
cmp -s -- "$unit" "$backup_two" || fail 'new backup does not match the service unit'
assert_eq 1 "${CLASHCTL_SERVICE_BACKUP_CREATED:-0}" 'deferred backup is marked as created'
[ -f "$journal" ] || fail 'service transaction journal was not created'
assert_eq 600 "$(stat -c %a -- "$journal")" 'service transaction journal permissions'

controller_dir="$WORK_DIR/controller"
mkdir -p -- "$controller_dir"
export CLASH_DATA_DIR="$controller_dir"
export CLASH_CONFIG_RUNTIME="$controller_dir/runtime.yaml" BIN_YQ=fake_yq
controller_secret='controller-secret-must-not-enter-argv'
curl_args_file="$controller_dir/curl-args"
header_copy="$controller_dir/header-copy"
header_path_file="$controller_dir/header-path"
controller_env_file="$controller_dir/curl-env"
: >"$controller_env_file"
curl_result=0

fake_yq() {
    printf '%s\n' '0.0.0.0:9090'
}

_get_secret() {
    printf '%s' "$controller_secret"
}

curl() {
    local arg expect_header=0 header_path=
    /usr/bin/env >>"$controller_env_file"
    : >"$curl_args_file"
    for arg in "$@"; do
        printf '%s\n' "$arg" >>"$curl_args_file"
        if [ "$expect_header" = 1 ]; then
            header_path=${arg#@}
            expect_header=0
        elif [ "$arg" = --header ]; then
            expect_header=1
        fi
    done
    [ -f "$header_path" ] || return 1
    cp -- "$header_path" "$header_copy"
    printf '%s\n' "$header_path" >"$header_path_file"
    return "$curl_result"
}

export secret=hostile-controller-secret
_install_wait_controller || fail 'controller readiness probe failed'
unset secret
assert_eq --disable "$(head -n 1 -- "$curl_args_file")" \
    'controller curl disables .curlrc before all other options'
assert_not_contains "$curl_args_file" "$controller_secret" 'controller secret is absent from curl argv'
assert_not_contains "$controller_env_file" "$controller_secret" \
    'controller secret is absent from curl environment'
if grep -Eqs '^secret=' "$controller_env_file"; then
    fail 'controller secret local retained hostile export state'
fi
assert_contains "$header_copy" "Authorization: Bearer $controller_secret" 'controller auth header is populated'
header_path=$(<"$header_path_file")
[ ! -e "$header_path" ] || fail 'controller auth header file was not removed'
[ -z "${_INSTALL_CONTROLLER_HEADER_FILE:-}" ] || fail 'controller header registry was not cleared'

sleep() {
    :
}

curl_result=1
rc=0
_install_wait_controller || rc=$?
assert_eq 1 "$rc" 'controller readiness timeout is reported'
header_path=$(<"$header_path_file")
[ ! -e "$header_path" ] || fail 'failed controller probe retained its auth header file'
[ -z "${_INSTALL_CONTROLLER_HEADER_FILE:-}" ] || fail 'failed probe retained its header registry'

signal_dir="$WORK_DIR/controller-signal"
signal_header_path_file="$signal_dir/header-path"
mkdir -p -- "$signal_dir"
rc=0
# shellcheck disable=SC2016  # 子 Bash 必须在运行时展开其局部变量和 $?
env CLASHCTL_INSTALL_SOURCE_ONLY=1 bash -c '
    . "$1"
    . "${1%/*}/scripts/lib/install-transaction.sh"
    . "${1%/*}/scripts/cmd/install.sh"
    _INSTALL_STREAM_COMPLETE=1
    trap '\''_ci_exit_guard $?'\'' EXIT
    trap '\''exit 143'\'' TERM
    CLASH_DATA_DIR=$2
    CLASH_CONFIG_RUNTIME=$2/runtime.yaml
    SIGNAL_HEADER_PATH_FILE=$3
    BIN_YQ=fake_yq
    fake_yq() { printf "%s\n" "127.0.0.1:9090"; }
    _get_secret() { printf "%s" secret; }
    curl() {
        local arg expect_header=0 header_path=
        for arg in "$@"; do
            if [ "$expect_header" = 1 ]; then
                header_path=${arg#@}
                expect_header=0
            elif [ "$arg" = --header ]; then
                expect_header=1
            fi
        done
        printf "%s\n" "$header_path" >"$SIGNAL_HEADER_PATH_FILE"
        kill -TERM "$BASHPID"
    }
    _install_wait_controller
' _ "$REPO_DIR/install.sh" "$signal_dir" "$signal_header_path_file" \
    >"$signal_dir/stdout" 2>"$signal_dir/stderr" || rc=$?
assert_eq 143 "$rc" 'TERM during controller probe preserves the signal exit status'
header_path=$(<"$signal_header_path_file")
[ ! -e "$header_path" ] || fail 'TERM during controller probe retained its auth header file'

fresh_home="$WORK_DIR/fresh-home"
fresh_target="$WORK_DIR/fresh.service"
mkdir -p -- "$fresh_home"
reset_service_state
export CLASHCTL_HOME="$fresh_home" CLASHCTL_KERNEL=mihomo
export CLASHCTL_SERVICE_MANAGER=sysvinit CLASHCTL_SERVICE_TARGET="$fresh_target"
export CLASHCTL_SERVICE_TARGET_EXISTED=0 CLASHCTL_SERVICE_SOURCE=''
export CLASHCTL_SERVICE_BACKUP='' CLASHCTL_SERVICE_BACKUP_CREATED=0
export CLASHCTL_SERVICE_WAS_ACTIVE=0 CLASHCTL_SERVICE_WAS_ENABLED=0
export CLASHCTL_SERVICE_CONFLICT=0 CLASHCTL_SERVICE_ENABLE_KIND=absent
export CLASHCTL_SERVICE_JOURNAL="$fresh_home/.service-transaction"
printf 'snapshot\n' >"$CLASHCTL_SERVICE_JOURNAL"
service_disable_calls=0

service_is_active() {
    return 1
}

service_is_enabled() {
    return 1
}

service_disable() {
    service_disable_calls=$((service_disable_calls + 1))
    return 1
}

: >"$stdout_file"
: >"$stderr_file"
_install_restore_service >"$stdout_file" 2>"$stderr_file" ||
    fail 'fresh-install rollback treated an absent service as a failure'
assert_eq 0 "$service_disable_calls" 'fresh-install rollback skips disabling an absent service'
[ ! -e "$CLASHCTL_SERVICE_JOURNAL" ] || fail 'successful rollback retained its journal'

cleanup_home="$WORK_DIR/cleanup-failure-home"
mkdir -p -- "$cleanup_home"
export CLASHCTL_HOME="$cleanup_home" CLASHCTL_SERVICE_TARGET="$WORK_DIR/cleanup.service"
export CLASHCTL_SERVICE_SOURCE='' CLASHCTL_SERVICE_BACKUP_CREATED=1
export CLASHCTL_SERVICE_BACKUP="$cleanup_home/original.backup"
printf 'backup\n' >"$CLASHCTL_SERVICE_BACKUP"
export CLASHCTL_SERVICE_JOURNAL="$cleanup_home/.service-transaction"
mkdir -- "$CLASHCTL_SERVICE_JOURNAL"
: >"$stderr_file"
rc=0
_install_restore_service >"$stdout_file" 2>"$stderr_file" || rc=$?
assert_eq 1 "$rc" 'journal cleanup failure is reported'
[ -d "$CLASHCTL_SERVICE_JOURNAL" ] || fail 'failed journal cleanup removed the journal'
[ -f "$CLASHCTL_SERVICE_BACKUP" ] || fail 'backup was removed while its journal remained'
assert_contains "$stderr_file" '恢复材料均已保留' 'journal cleanup failure explains recovery state'
assert_not_contains "$stderr_file" '已恢复安装前的服务定义、自启与运行状态' \
    'journal cleanup failure is not reported as complete rollback'

/usr/bin/rm -rf -- "$CLASHCTL_SERVICE_JOURNAL"
printf 'snapshot\n' >"$CLASHCTL_SERVICE_JOURNAL"
/usr/bin/rm -f -- "$CLASHCTL_SERVICE_BACKUP"
mkdir -- "$CLASHCTL_SERVICE_BACKUP"
: >"$stderr_file"
rc=0
_install_restore_service >"$stdout_file" 2>"$stderr_file" || rc=$?
assert_eq 1 "$rc" 'backup cleanup failure is reported'
[ ! -e "$CLASHCTL_SERVICE_JOURNAL" ] || fail 'journal was retained after its successful cleanup'
[ -d "$CLASHCTL_SERVICE_BACKUP" ] || fail 'failed backup cleanup removed recovery material'
assert_contains "$stderr_file" '临时备份清理失败' 'backup cleanup failure is actionable'
assert_not_contains "$stderr_file" '已恢复安装前的服务定义、自启与运行状态' \
    'backup cleanup failure is not reported as complete rollback'

printf 'install-ui: ok\n'
