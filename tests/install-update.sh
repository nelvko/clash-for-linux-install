#!/usr/bin/env bash
# 本地 Git 源模拟网络，执行实际管道入口、初始化和更新流程。
# shellcheck disable=SC2119  # 测试无参数的更新入口
set -euo pipefail
REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
export REAL_GIT
REAL_GIT=$(command -v git)
export FIXTURE="$WORK_DIR/source" CI=1 CLASHCTL_HOME="$WORK_DIR/installed"
mkdir -p "$FIXTURE/scripts/lib" "$FIXTURE/scripts/cmd" "$FIXTURE/resources" "$WORK_DIR/bin"
cp "$REPO_DIR/scripts/lib/operation-lock.sh" "$FIXTURE/scripts/lib/"
cp "$REPO_DIR/scripts/cmd/update.sh" "$FIXTURE/scripts/cmd/"
cp "$REPO_DIR/install.sh" "$FIXTURE/"
cp "$REPO_DIR/uninstall.sh" "$FIXTURE/"
cp "$REPO_DIR/.env.example" "$FIXTURE/"
cp "$REPO_DIR/resources/"{mixin.yaml.example,profiles.yaml} "$FIXTURE/resources/"
printf 'data/\nbin/\n.env\n' >"$FIXTURE/.gitignore"
cat >"$FIXTURE/scripts/preflight.sh" <<'STUB'
[ ! -f "$CLASHCTL_HOME/.env" ] || . "$CLASHCTL_HOME/.env"
CLASH_DATA_DIR="$CLASHCTL_HOME/data"
CLASH_PROFILES_DIR="$CLASH_DATA_DIR/profiles"
CLASH_RESOURCES_DIR="$CLASHCTL_HOME/resources"
CLASH_CONFIG_BASE="$CLASH_DATA_DIR/config.yaml"
CLASH_CONFIG_MIXIN="$CLASH_DATA_DIR/mixin.yaml"
BIN_YQ=fixture_yq
fixture_yq() { printf existing-secret; }
bin_kernel_path() { printf '%s/bin/mihomo/mihomo' "$CLASHCTL_HOME"; }
operation_lock_acquire() { :; }
valid_required() { :; }
detect_service_manager() { service_manager=nohup; }
_service_check_conflict() { :; }
prepare_zip() { mkdir -p "$CLASHCTL_HOME/bin"; printf kernel >"$CLASHCTL_HOME/bin/kernel"; }
_set_env() { printf '%s=%q\n' "$1" "$2" >>"$CLASHCTL_HOME/.env"; }
_merge_config() { printf runtime >"$CLASH_DATA_DIR/runtime.yaml"; }
_detect_proxy_port() { :; }
_detect_ext_addr() { :; }
_get_secret() { printf existing-secret; }
install_service() { :; }
service_start() { [ "${FAIL_START:-0}" = 0 ] && touch "$CLASH_DATA_DIR/started"; }
service_is_active() { [ -f "$CLASH_DATA_DIR/started" ]; }
service_enable() { touch "$CLASH_DATA_DIR/enabled"; }
on_service_only() { _merge_config && service_start && service_enable; }
clashsub() {
    printf '%s' "$3" >"$CLASH_DATA_DIR/subscription"
    printf main-config >"$CLASH_CONFIG_BASE"
    on_service_only
}
apply_rc() { touch "$CLASH_DATA_DIR/shell-ready"; }
uninstall_service() { [ "${FAIL_STOP:-0}" = 0 ]; }
revoke_rc() { :; }
_ui_error() { printf '%s\n' "$*" >&2; }
_ui_info() { printf '%s\n' "$*"; }
_ui_step() { :; }
_ui_ok() { printf '%s\n' "$*"; }
_ui_detail() { :; }
STUB
printf 'fixture_version=old\n' >"$FIXTURE/scripts/cmd/clashctl.sh"
"$REAL_GIT" -C "$FIXTURE" init -q -b master
"$REAL_GIT" -C "$FIXTURE" config user.email test@example.invalid
"$REAL_GIT" -C "$FIXTURE" config user.name test
"$REAL_GIT" -C "$FIXTURE" add .
"$REAL_GIT" -C "$FIXTURE" commit -qm initial
"$REAL_GIT" -C "$FIXTURE" branch iu
"$REAL_GIT" -C "$FIXTURE" checkout -qb legacy
"$REAL_GIT" -C "$FIXTURE" rm -q .env.example
"$REAL_GIT" -C "$FIXTURE" commit -qm legacy-layout
"$REAL_GIT" -C "$FIXTURE" checkout -q master
cat >"$WORK_DIR/bin/git" <<'STUB'
#!/usr/bin/env bash
[ "${FAIL_FETCH:-0}" = 0 ] || exit 1
args=()
for arg in "$@"; do
    case $arg in
    *github.com/nelvko/clash-for-linux-install.git) arg=$FIXTURE ;;
    esac
    args+=("$arg")
done
exec "$REAL_GIT" "${args[@]}"
STUB
chmod +x "$WORK_DIR/bin/git"
export PATH="$WORK_DIR/bin:$PATH"
# stdin 是脚本，CI 跳过 /dev/tty 输入；初始化不能只安装命令空壳。
# shellcheck disable=SC2002  # 必须验证管道输入，不能改成文件执行
cat "$REPO_DIR/install.sh" | bash >"$WORK_DIR/install.out" 2>&1
[ ! -f "$CLASHCTL_HOME/data/started" ] || fail 'empty install started service'
[ ! -f "$CLASHCTL_HOME/data/enabled" ] || fail 'empty install enabled service'
[ ! -e "$CLASHCTL_HOME/data/runtime.yaml" ] || fail 'empty install generated runtime'
grep -q '尚未配置订阅' "$WORK_DIR/install.out" || fail 'empty install did not explain missing configuration'
[ -f "$CLASHCTL_HOME/data/shell-ready" ] || fail 'pipeline did not install shell integration'
[ -f "$CLASHCTL_HOME/.env" ] || fail 'pipeline did not write environment'
[ "$(cat "$CLASHCTL_HOME/.git/clashctl-home")" = "$CLASHCTL_HOME" ] || fail 'pipeline did not record installation path'
[ "$(stat -c %a "$CLASHCTL_HOME/.git/clashctl-home")" = 600 ] || fail 'installation marker is not private'
grep -q '安装完成' "$WORK_DIR/install.out" || fail 'missing install result'
# 源码不能通过重试初始化获得安装身份；克隆真实安装也不会继承 Git 私有标记。
if CLASHCTL_HOME="$FIXTURE" bash "$FIXTURE/install.sh" >"$WORK_DIR/source-retry.out" 2>&1; then
    fail 'installer adopted source checkout as installation'
fi
[ ! -e "$FIXTURE/.git/clashctl-home" ] || fail 'installer marked source checkout'
[ ! -e "$FIXTURE/.env" ] || fail 'installer initialized source checkout'
"$REAL_GIT" clone -q "$CLASHCTL_HOME" "$WORK_DIR/cloned-install"
[ ! -e "$WORK_DIR/cloned-install/.git/clashctl-home" ] || fail 'Git clone inherited installation identity'
if bash "$WORK_DIR/cloned-install/uninstall.sh" --yes >"$WORK_DIR/cloned-uninstall.out" 2>&1; then
    fail 'cloned installation was accepted for uninstall'
fi
[ -f "$WORK_DIR/cloned-install/install.sh" ] || fail 'cloned installation was removed'
if bash "$REPO_DIR/install.sh" >"$WORK_DIR/existing.out" 2>&1; then fail 'existing installation was overwritten'; fi
if FAIL_FETCH=1 CLASHCTL_HOME="$WORK_DIR/failed" bash "$REPO_DIR/install.sh" >"$WORK_DIR/failed.out" 2>&1; then
    fail 'download failure succeeded'
fi
[ ! -e "$WORK_DIR/failed" ] || fail 'download failure installed a partial tree'
# 路径先规范化再登记；含 . 或 .. 的路径不能绕过根目录和 HOME 限制。
for unsafe_home in /tmp/.. "$HOME/./"; do
    if CLASHCTL_HOME="$unsafe_home" bash "$REPO_DIR/install.sh" >"$WORK_DIR/unsafe-home.out" 2>&1; then
        fail 'installer accepted root or HOME through path aliases'
    fi
    grep -q '不能使用根目录或用户主目录' "$WORK_DIR/unsafe-home.out" || fail 'unsafe path was not rejected before cloning'
done
CLASHCTL_HOME="$WORK_DIR/unused/../normalized" bash "$REPO_DIR/install.sh" >"$WORK_DIR/normalized.out" 2>&1
[ "$(cat "$WORK_DIR/normalized/.git/clashctl-home")" = "$WORK_DIR/normalized" ] || fail 'marker did not use physical installation path'
bash "$WORK_DIR/normalized/uninstall.sh" --yes >"$WORK_DIR/normalized-uninstall.out" 2>&1
[ ! -e "$WORK_DIR/normalized" ] || fail 'normalized installation could not be uninstalled'
# 已有主配置时重试初始化：启动失败仍返回失败，恢复后可以继续。
printf main-config >"$CLASHCTL_HOME/data/config.yaml"
if FAIL_START=1 bash "$CLASHCTL_HOME/install.sh" >"$WORK_DIR/start-failed.out" 2>&1; then
    fail 'service failure succeeded'
fi
! grep -q '安装完成' "$WORK_DIR/start-failed.out" || fail 'service failure reported success'
bash "$CLASHCTL_HOME/install.sh" >"$WORK_DIR/retry.out" 2>&1
[ -f "$CLASHCTL_HOME/data/started" ] || fail 'root installer could not retry initialization'

# 不兼容分支必须在落位和初始化前拒绝，不能留下半成品目录。
if CLASHCTL_UPDATE_BRANCH=legacy CLASHCTL_HOME="$WORK_DIR/legacy" bash "$REPO_DIR/install.sh" >"$WORK_DIR/legacy.out" 2>&1; then
    fail 'incompatible source was installed'
fi
[ ! -e "$WORK_DIR/legacy" ] || fail 'incompatible source created an installation'
grep -q '源码不兼容' "$WORK_DIR/legacy.out" || fail 'missing incompatible branch diagnosis'
! grep -q 'command not found' "$WORK_DIR/legacy.out" || fail 'incompatible source reached initialization'
# 左侧命令的环境变量不影响安装器，取源分支以右侧 bash 的环境为准。
# shellcheck disable=SC2002  # 验证真实管道两侧的环境变量作用域
CLASHCTL_UPDATE_BRANCH=legacy cat "$REPO_DIR/install.sh" | CLASHCTL_UPDATE_BRANCH=iu CLASHCTL_HOME="$WORK_DIR/iu" bash >"$WORK_DIR/iu.out" 2>&1
[ "$("$REAL_GIT" -C "$WORK_DIR/iu" branch --show-current)" = iu ] || fail 'pipeline cloned the wrong branch'
grep -q '^CLASHCTL_UPDATE_BRANCH=iu$' "$WORK_DIR/iu/.env" || fail 'pipeline did not persist selected branch'

# 控制终端与脚本 stdin 分离：真实 PTY 下读取订阅，并验证输入不回显。
TEST_REPO="$REPO_DIR" TEST_WORK="$WORK_DIR" python3 - <<'PTY'
import errno, os, pty, select, signal, time
pid, fd = pty.fork()
if pid == 0:
    os.environ.pop("CI", None)
    os.environ["CLASHCTL_HOME"] = os.environ["TEST_WORK"] + "/tty-install"
    os.execlp("bash", "bash", "-c", 'cat "$TEST_REPO/install.sh" | bash')
output = b""
sent = False
status = None
try:
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.1)
        if ready:
            try:
                chunk = os.read(fd, 65536)
            except OSError as exc:
                if exc.errno != errno.EIO:
                    raise
                break
            if not chunk:
                break
            output += chunk
            if not sent and "订阅链接（回车跳过）".encode() in output:
                os.write(fd, b"file:///private-subscription\n")
                sent = True
        child, child_status = os.waitpid(pid, os.WNOHANG)
        if child:
            status = child_status
            break
    if status is None:
        child, status = os.waitpid(pid, os.WNOHANG)
        if not child:
            raise AssertionError("TTY installation timed out")
    assert os.waitstatus_to_exitcode(status) == 0, output.decode(errors="replace")
    assert sent, "subscription prompt missing"
    assert os.path.isfile(os.environ["TEST_WORK"] + "/tty-install/data/started")
    assert os.path.isfile(os.environ["TEST_WORK"] + "/tty-install/data/enabled")
    assert b"file:///private-subscription" not in output, "subscription echoed"
    with open(os.environ["TEST_WORK"] + "/tty-install/data/subscription") as saved:
        assert saved.read() == "file:///private-subscription"
finally:
    try:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
    except ProcessLookupError:
        pass
    os.close(fd)
PTY

. "$REPO_DIR/scripts/cmd/update.sh"
operation_lock_acquire() { :; }
gh_proxy_url() { printf '%s\n' "$1"; }
_ui_step() { :; }
_ui_error() { printf '%s\n' "$*" >&2; }
_ui_ok_out() { printf '%s\n' "$*"; }
CLASHCTL_UPDATE_BRANCH=master
printf 'user config' >"$CLASHCTL_HOME/data/config.yaml"
cp "$CLASHCTL_HOME/.env" "$WORK_DIR/env.before"
printf 'fixture_version=new\n' >"$FIXTURE/scripts/cmd/clashctl.sh"
"$REAL_GIT" -C "$FIXTURE" commit -qam update
clashupdate >"$WORK_DIR/update.out" 2>&1
# shellcheck disable=SC2154  # 更新后的加载器赋值
[ "$fixture_version" = new ] || fail 'current shell did not load update'
[ "$(cat "$CLASHCTL_HOME/data/config.yaml")" = 'user config' ] || fail 'update changed config'
[ "$(cat "$CLASHCTL_HOME/bin/kernel")" = kernel ] || fail 'update changed kernel'
cmp "$WORK_DIR/env.before" "$CLASHCTL_HOME/.env" || fail 'update changed environment'
[ "$(cat "$CLASHCTL_HOME/.git/clashctl-home")" = "$CLASHCTL_HOME" ] || fail 'update lost installation marker'
old=$("$REAL_GIT" -C "$CLASHCTL_HOME" rev-parse HEAD)
printf 'local edit\n' >>"$CLASHCTL_HOME/scripts/cmd/clashctl.sh"
if clashupdate >"$WORK_DIR/dirty.out" 2>&1; then fail 'update overwrote local edits'; fi
"$REAL_GIT" -C "$CLASHCTL_HOME" checkout -- scripts/cmd/clashctl.sh
printf '\nbroken() {\n' >>"$FIXTURE/install.sh"
"$REAL_GIT" -C "$FIXTURE" commit -qam broken-installer
if clashupdate >"$WORK_DIR/broken-installer.out" 2>&1; then fail 'invalid installer was deployed'; fi
[ "$("$REAL_GIT" -C "$CLASHCTL_HOME" rev-parse HEAD)" = "$old" ] || fail 'invalid installer changed version'
cp "$REPO_DIR/install.sh" "$FIXTURE/install.sh"
printf 'broken() {\n' >"$FIXTURE/scripts/cmd/clashctl.sh"
"$REAL_GIT" -C "$FIXTURE" commit -qam broken
if clashupdate >"$WORK_DIR/broken.out" 2>&1; then fail 'syntax error was deployed'; fi
[ "$("$REAL_GIT" -C "$CLASHCTL_HOME" rev-parse HEAD)" = "$old" ] || fail 'syntax failure changed version'
if FAIL_FETCH=1 clashupdate >"$WORK_DIR/network.out" 2>&1; then fail 'fetch failure succeeded'; fi
[ "$("$REAL_GIT" -C "$CLASHCTL_HOME" rev-parse HEAD)" = "$old" ] || fail 'fetch failure changed version'
printf 'fixture_version=new\n' >"$FIXTURE/scripts/cmd/clashctl.sh"
printf 'foreign environment\n' >"$FIXTURE/.env"
"$REAL_GIT" -C "$FIXTURE" add -f .env
"$REAL_GIT" -C "$FIXTURE" commit -qam incompatible-layout
if clashupdate >"$WORK_DIR/layout.out" 2>&1; then fail 'update accepted tracked user data'; fi
cmp "$WORK_DIR/env.before" "$CLASHCTL_HOME/.env" || fail 'incompatible update overwrote environment'
if FAIL_STOP=1 bash "$CLASHCTL_HOME/uninstall.sh" --yes >"$WORK_DIR/uninstall-failed.out" 2>&1; then
    fail 'uninstall ignored service stop failure'
fi
[ -f "$CLASHCTL_HOME/data/config.yaml" ] || fail 'failed uninstall removed user data'
bash "$CLASHCTL_HOME/uninstall.sh" --yes >"$WORK_DIR/uninstall.out" 2>&1
[ ! -e "$CLASHCTL_HOME" ] || fail 'uninstall retained installation'
printf 'install-update: ok\n'
