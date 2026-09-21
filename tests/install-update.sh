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
printf 'data/\nbin/\n.env\n.clashctl-install\n.clashctl-files\n' >"$FIXTURE/.gitignore"
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
_ui_warn() { printf '%s\n' "$*"; }
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
# 两个 env -u：未设时才走管道安装，保证下面断言的是"未提供即直连"。
env -u GH_PROXY -u CLASHCTL_UPDATE_BRANCH bash -c 'cat "$1" | bash' _ "$REPO_DIR/install.sh" >"$WORK_DIR/install.out" 2>&1
[ ! -f "$CLASHCTL_HOME/data/started" ] || fail 'empty install started service'
[ ! -f "$CLASHCTL_HOME/data/enabled" ] || fail 'empty install enabled service'
[ ! -e "$CLASHCTL_HOME/data/runtime.yaml" ] || fail 'empty install generated runtime'
grep -q '尚未配置订阅' "$WORK_DIR/install.out" || fail 'empty install did not explain missing configuration'
[ -f "$CLASHCTL_HOME/data/shell-ready" ] || fail 'pipeline did not install shell integration'
[ -f "$CLASHCTL_HOME/.env" ] || fail 'pipeline did not write environment'
[ "$(head -n 1 "$CLASHCTL_HOME/.clashctl-install")" = "$CLASHCTL_HOME" ] || fail 'pipeline did not record installation path'
[ "$(stat -c %a "$CLASHCTL_HOME/.clashctl-install")" = 600 ] || fail 'installation marker is not private'
# GH_PROXY 无隐式默认：未显式提供时保持未设（直连），不能静默套上第三方镜像。
grep -q '^#GH_PROXY=https://gh-proxy.org$' "$CLASHCTL_HOME/.env" || fail 'GH_PROXY picked up an implicit default'
grep -q '安装完成' "$WORK_DIR/install.out" || fail 'missing install result'
# --gh-proxy 旗标：管道写法下参数写在右侧 bash 之后，两种形式都要生效并写入 .env。
for flag in '--gh-proxy https://flag.proxy.test' '--gh-proxy=https://flag.proxy.test'; do
    proxy_home="$WORK_DIR/flag-home"
    rm -rf "$proxy_home"
    # shellcheck disable=SC2086  # 故意按空格拆分为两个参数
    CLASHCTL_HOME="$proxy_home" CI=1 bash "$REPO_DIR/install.sh" $flag >"$WORK_DIR/flag.out" 2>&1 ||
        { cat "$WORK_DIR/flag.out"; fail "gh-proxy flag rejected: $flag"; }
    grep -q '^GH_PROXY=https://flag.proxy.test$' "$proxy_home/.env" ||
        fail "gh-proxy flag was not persisted: $flag"
done
rm -rf "$WORK_DIR/flag-home"
# 源码不能通过重试初始化获得安装身份；克隆真实安装也不会继承 Git 私有标记。
if CLASHCTL_HOME="$FIXTURE" bash "$FIXTURE/install.sh" >"$WORK_DIR/source-retry.out" 2>&1; then
    fail 'installer adopted source checkout as installation'
fi
[ ! -e "$FIXTURE/.clashctl-install" ] || fail 'installer marked source checkout'
[ ! -e "$FIXTURE/.env" ] || fail 'installer initialized source checkout'
"$REAL_GIT" clone -q "$CLASHCTL_HOME" "$WORK_DIR/cloned-install"
[ ! -e "$WORK_DIR/cloned-install/.clashctl-install" ] || fail 'Git clone inherited installation identity'
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
[ "$(head -n 1 "$WORK_DIR/normalized/.clashctl-install")" = "$WORK_DIR/normalized" ] || fail 'marker did not use physical installation path'
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
# 分支选择以右侧 bash 的环境为准；右侧是交互 shell，安装器会从控制终端读订阅链接。
TEST_REPO="$REPO_DIR" TEST_WORK="$WORK_DIR" TEST_FIXTURE="$FIXTURE" python3 - <<'PTY'
import errno, os, pty, select, signal, time, subprocess
work = os.environ["TEST_WORK"]
# 把安装器的克隆源固定到本地 fixture 仓库（含 .env.example 与初始化桩），
# 这样 PTY 用例不依赖网络，且 _source_validate 能通过。
origin = work + "/origin"
subprocess.run(["rm", "-rf", origin], check=True)
subprocess.run(["git", "clone", "-q", os.environ["TEST_FIXTURE"], origin], check=True)
pid, fd = pty.fork()
if pid == 0:
    os.environ.pop("CI", None)
    os.environ["CLASHCTL_HOME"] = work + "/tty-install"
    os.environ["CLASHCTL_UPDATE_BRANCH"] = "master"
    # 把安装器的克隆源固定到本地仓库，测试不依赖网络。
    script = 'cat "$TEST_REPO/install.sh" | '
    script += 'sed "s#https://github.com/nelvko/clash-for-linux-install.git#$TEST_WORK/origin#" | bash'
    os.execlp("bash", "bash", "-c", script)
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
    assert os.path.isfile(work + "/tty-install/data/started")
    assert os.path.isfile(work + "/tty-install/data/enabled")
    assert b"file:///private-subscription" not in output, "subscription echoed"
    with open(work + "/tty-install/data/subscription") as saved:
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
_ui_info() { printf '%s\n' "$*"; }
_ui_ok() { :; }
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
[ "$(head -n 1 "$CLASHCTL_HOME/.clashctl-install")" = "$CLASHCTL_HOME" ] || fail 'update lost installation marker'
# 标记完整时不得重写：截断后被掉电/满盘打断会留下空标记，更新与卸载双双死锁。
printf '%s\ngit\n' "$CLASHCTL_HOME" >"$CLASHCTL_HOME/.clashctl-install"
touch -d '2 seconds ago' "$CLASHCTL_HOME/.clashctl-install"
marker_mtime=$(stat -c %Y "$CLASHCTL_HOME/.clashctl-install")
clashupdate >"$WORK_DIR/marker-intact.out" 2>&1 || fail 'update failed with a healthy marker'
[ "$(stat -c %Y "$CLASHCTL_HOME/.clashctl-install")" = "$marker_mtime" ] ||
    fail 'update rewrote an intact installation marker'
# 已存在的 Git 安装可以凭旧的精确路径标记更新，并补写独立标记。
printf '%s\n' "$CLASHCTL_HOME" >"$CLASHCTL_HOME/.git/clashctl-home"
rm "$CLASHCTL_HOME/.clashctl-install"
clashupdate >"$WORK_DIR/marker-update.out" 2>&1 || fail 'existing Git installation could not update'
[ "$(head -n 1 "$CLASHCTL_HOME/.clashctl-install")" = "$CLASHCTL_HOME" ] || fail 'old installation marker was not migrated'
# 空标记（半截写入的残留）必须自解释：只报"缺少匹配的安装标记"无法让用户知道该删哪个文件。
printf '' >"$CLASHCTL_HOME/.clashctl-install"
if clashupdate >"$WORK_DIR/marker-empty.out" 2>&1; then fail 'empty installation marker was accepted'; fi
grep -q '安装标记为空' "$WORK_DIR/marker-empty.out" || fail 'empty marker had no diagnosis'
grep -qF "$CLASHCTL_HOME/.clashctl-install" "$WORK_DIR/marker-empty.out" || fail 'empty marker diagnosis did not name the file'
printf '%s\ngit\n' "$CLASHCTL_HOME" >"$CLASHCTL_HOME/.clashctl-install"
# 无 Git 的真实 PATH：下载器只复制本地 tar 包，其余使用系统工具。
no_git_bin="$WORK_DIR/no-git-bin"
mkdir "$no_git_bin"
for tool in install bash cat dirname readlink mkdir mktemp rm mv tar gzip unzip sha256sum find sort xargs chmod cp head stat sleep touch grep sed awk id flock; do
    ln -s "$(command -v "$tool")" "$no_git_bin/$tool"
done
export SOURCE_ARCHIVE="$WORK_DIR/source.tar.gz" DOWNLOAD_LOG="$WORK_DIR/download.log"
cat >"$no_git_bin/curl" <<'DOWNLOAD'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >>"$DOWNLOAD_LOG"
[ "${FAIL_DOWNLOAD:-0}" = 0 ] || exit 22
while [ "$#" -gt 0 ]; do
    case "$1" in -o | -O) destination=$2; shift ;; esac
    shift
done
cp "$SOURCE_ARCHIVE" "$destination"
DOWNLOAD
chmod +x "$no_git_bin/curl"
cp "$no_git_bin/curl" "$no_git_bin/wget"
archive_source="$WORK_DIR/archive-source"
mkdir "$archive_source"
"$REAL_GIT" -C "$FIXTURE" archive HEAD | tar -x -C "$archive_source"
printf 'obsolete=true\n' >"$archive_source/scripts/obsolete.sh"
tar -czf "$SOURCE_ARCHIVE" -C "$WORK_DIR" archive-source
archive_home="$WORK_DIR/archive-home"
PATH="$no_git_bin" CLASHCTL_HOME="$archive_home" GH_PROXY=https://proxy.example \
    bash "$REPO_DIR/install.sh" >"$WORK_DIR/archive-install.out" 2>&1 || { cat "$WORK_DIR/archive-install.out"; fail 'curl fallback install failed'; }
[ ! -e "$archive_home/.git" ] || fail 'fallback created a Git repository'
[ "$(tail -n 1 "$archive_home/.clashctl-install")" = archive ] || fail 'archive type was not recorded'
[ -s "$archive_home/.clashctl-files" ] || fail 'archive file manifest missing'
grep -Fq 'https://proxy.example/https://github.com/nelvko/clash-for-linux-install/archive/refs/heads/master.tar.gz' "$DOWNLOAD_LOG" || fail 'source archive ignored proxy or branch'
# wget 只负责拉取源码，此处初始化桩不依赖 curl。
mv "$no_git_bin/curl" "$WORK_DIR/saved-curl"
PATH="$no_git_bin" CLASHCTL_HOME="$WORK_DIR/wget-home" GH_PROXY='' \
    bash "$REPO_DIR/install.sh" >"$WORK_DIR/wget-install.out" 2>&1 || { cat "$WORK_DIR/wget-install.out"; fail 'wget fallback install failed'; }
grep -q '^wget ' "$DOWNLOAD_LOG" || fail 'wget fallback was not used'
mv "$WORK_DIR/saved-curl" "$no_git_bin/curl"
# Git 存在但失败时不能偷偷回退下载。
before_downloads=$(wc -l <"$DOWNLOAD_LOG")
ln -s "$WORK_DIR/bin/git" "$no_git_bin/git"
if PATH="$no_git_bin" FAIL_FETCH=1 CLASHCTL_HOME="$WORK_DIR/git-failed" bash "$REPO_DIR/install.sh" >"$WORK_DIR/git-failed.out" 2>&1; then fail 'Git failure succeeded'; fi
[ "$(wc -l <"$DOWNLOAD_LOG")" = "$before_downloads" ] || fail 'Git failure fell back to archive'
rm "$no_git_bin/git"
if PATH="$no_git_bin" FAIL_DOWNLOAD=1 CLASHCTL_HOME="$WORK_DIR/archive-failed" bash "$REPO_DIR/install.sh" >/dev/null 2>&1; then fail 'archive download failure succeeded'; fi
[ ! -e "$WORK_DIR/archive-failed" ] || fail 'failed download created installation'

archive_update() (
    export CLASHCTL_HOME="$archive_home" PATH="$no_git_bin"
    . "$archive_home/scripts/cmd/update.sh"
    clashupdate >"$WORK_DIR/archive-update.out" 2>&1 || return
    printf '%s\n' "$fixture_version" >"$WORK_DIR/archive-version"
)
printf keep-config >"$archive_home/data/config.yaml"
mkdir -p "$archive_home/resources/dist" "$archive_home/archives"
printf keep-ui >"$archive_home/resources/dist/index.html"
printf keep-cache >"$archive_home/resources/cache.db"
printf keep-archive >"$archive_home/archives/kernel.gz"
cp "$archive_home/.env" "$WORK_DIR/archive.env.before"
cp "$archive_home/.clashctl-install" "$WORK_DIR/archive.marker.before"
cp "$archive_home/.clashctl-files" "$WORK_DIR/archive.manifest.before"
rm "$archive_source/scripts/obsolete.sh"
printf 'new_helper=true\n' >"$archive_source/scripts/new-helper.sh"
printf 'fixture_version=archive-new\n' >"$archive_source/scripts/cmd/clashctl.sh"
tar -czf "$SOURCE_ARCHIVE" -C "$WORK_DIR" archive-source
# 本地修改与非托管文件冲突都应在替换前拒绝。
printf 'local-change=true\n' >>"$archive_home/scripts/obsolete.sh"
if archive_update; then fail 'archive update overwrote modified code'; fi
printf 'obsolete=true\n' >"$archive_home/scripts/obsolete.sh"
printf 'user-file=true\n' >"$archive_home/scripts/new-helper.sh"
if archive_update; then fail 'archive update overwrote unmanaged file'; fi
rm "$archive_home/scripts/new-helper.sh"
# 模拟写入阶段中途失败，必须恢复旧程序文件与旧清单。
(
    tar() {
        if [ "${1:-}" = -xf ] && [ "${2:-}" = - ]; then
            cat >/dev/null
            printf 'partial=true\n' >"$archive_home/scripts/cmd/clashctl.sh"
            printf 'partial=true\n' >"$archive_home/scripts/new-helper.sh"
            return 1
        fi
        command tar "$@"
    }
    if archive_update; then fail 'partial archive write reported success'; fi
)
grep -qx 'fixture_version=new' "$archive_home/scripts/cmd/clashctl.sh" || fail 'failed update did not restore code'
[ ! -e "$archive_home/scripts/new-helper.sh" ] || fail 'failed update retained new file'
cmp "$WORK_DIR/archive.manifest.before" "$archive_home/.clashctl-files" || fail 'failed update lost old manifest'
# 后续系统装上 Git，压缩包安装仍使用原方式更新。
cat >"$no_git_bin/git" <<'GIT'
#!/usr/bin/env bash
exit 97
GIT
chmod +x "$no_git_bin/git"
archive_update || { cat "$WORK_DIR/archive-update.out"; fail 'archive update failed'; }
[ "$(cat "$WORK_DIR/archive-version")" = archive-new ] || fail 'archive update did not reload shell'
[ ! -e "$archive_home/scripts/obsolete.sh" ] || fail 'obsolete script survived archive update'
[ ! -e "$archive_home/.git" ] || fail 'archive install changed type after Git appeared'
[ "$(cat "$archive_home/data/config.yaml")" = keep-config ] || fail 'archive update changed subscription'
[ "$(cat "$archive_home/resources/dist/index.html")" = keep-ui ] || fail 'archive update changed UI'
[ "$(cat "$archive_home/resources/cache.db")" = keep-cache ] || fail 'archive update changed runtime cache'
[ "$(cat "$archive_home/archives/kernel.gz")" = keep-archive ] || fail 'archive update changed archives'
[ "$(cat "$archive_home/bin/kernel")" = kernel ] || fail 'archive update changed kernel'
cmp "$WORK_DIR/archive.env.before" "$archive_home/.env" || fail 'archive update changed environment'
cmp "$WORK_DIR/archive.marker.before" "$archive_home/.clashctl-install" || fail 'archive update changed identity'
# 下载失败、语法错误、保留目录和越界/链接归档不得影响已安装文件。
cp "$archive_home/.clashctl-files" "$WORK_DIR/archive.manifest.after"
if FAIL_DOWNLOAD=1 archive_update; then fail 'failed archive update download succeeded'; fi
printf 'broken() {\n' >"$archive_source/scripts/new-helper.sh"
tar -czf "$SOURCE_ARCHIVE" -C "$WORK_DIR" archive-source
if archive_update; then fail 'archive update accepted syntax error'; fi
printf 'new_helper=true\n' >"$archive_source/scripts/new-helper.sh"
mkdir "$archive_source/data"
printf forbidden >"$archive_source/data/config.yaml"
tar -czf "$SOURCE_ARCHIVE" -C "$WORK_DIR" archive-source
if archive_update; then fail 'archive update accepted user data paths'; fi
rm -rf "$archive_source/data"
python3 - "$WORK_DIR" <<'BAD_ARCHIVES'
import io, sys, tarfile
from pathlib import Path
root=Path(sys.argv[1])
for kind in ['traversal','symlink','hardlink']:
    with tarfile.open(root/(kind+'.tar.gz'),'w:gz') as archive:
        item=tarfile.TarInfo('source/../../escaped' if kind=='traversal' else 'source/link')
        if kind=='traversal':
            item.size=3
            archive.addfile(item,io.BytesIO(b'bad'))
        else:
            item.type=tarfile.SYMTYPE if kind=='symlink' else tarfile.LNKTYPE
            item.linkname=str(root/'escaped')
            archive.addfile(item)
BAD_ARCHIVES
for kind in traversal symlink hardlink; do
    if SOURCE_ARCHIVE="$WORK_DIR/$kind.tar.gz" archive_update; then fail "accepted $kind archive"; fi
done
[ ! -e "$WORK_DIR/escaped" ] || fail 'archive escaped staging directory'
cmp "$WORK_DIR/archive.manifest.after" "$archive_home/.clashctl-files" || fail 'rejected archive changed manifest'
# 无 Git 的安装也能正常卸载，更新后标记仍有效。
PATH="$no_git_bin" bash "$archive_home/uninstall.sh" --yes >"$WORK_DIR/archive-uninstall.out" 2>&1 || { cat "$WORK_DIR/archive-uninstall.out"; fail 'archive uninstall failed'; }
[ ! -e "$archive_home" ] || fail 'archive installation remains after uninstall'

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
