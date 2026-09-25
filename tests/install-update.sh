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
printf '#!/usr/bin/env bash\n' >"$FIXTURE/scripts/lib/common.sh"
cp "$REPO_DIR/scripts/cmd/update.sh" "$FIXTURE/scripts/cmd/"
cp "$REPO_DIR/install.sh" "$FIXTURE/"
cp "$REPO_DIR/uninstall.sh" "$FIXTURE/"
cp "$REPO_DIR/.env.example" "$FIXTURE/"
cp "$REPO_DIR/resources/"{mixin.yaml.example,profiles.yaml} "$FIXTURE/resources/"
printf 'data/\nbin/\n.env\n.clashctl-install\n.clashctl-uninitialized\n.clashctl-incomplete\n.clashctl-files\n' >"$FIXTURE/.gitignore"
cat >"$FIXTURE/scripts/preflight.sh" <<'STUB'
[ ! -f "$CLASHCTL_HOME/.env" ] || . "$CLASHCTL_HOME/.env"
CLASH_DATA_DIR="$CLASHCTL_HOME/data"
CLASH_PROFILES_DIR="$CLASH_DATA_DIR/profiles"
CLASH_RESOURCES_DIR="$CLASHCTL_HOME/resources"
CLASH_CONFIG_BASE="$CLASH_DATA_DIR/config.yaml"
CLASH_CONFIG_MIXIN="$CLASH_DATA_DIR/mixin.yaml"
BIN_YQ=fixture_yq
fixture_yq() { printf existing-secret; }
bin_kernel_path() { printf '%s/bin/%s/%s' "$CLASHCTL_HOME" "$CLASHCTL_KERNEL" "$CLASHCTL_KERNEL"; }
gh_proxy_url() { [ -z "${GH_PROXY:-}" ] && printf '%s\n' "$1" || printf '%s/%s\n' "${GH_PROXY%/}" "$1"; }
operation_lock_acquire() { :; }
valid_required() { :; }
detect_service_manager() { service_manager=nohup; }
_service_check_conflict() { :; }
prepare_zip() {
    if [ "${FAIL_PREPARE:-0}" != 0 ]; then
        [ "${FAIL_PREPARE_TIMEOUT:-0}" != 1 ] || CLASHCTL_DOWNLOAD_TIMED_OUT=1
        return 1
    fi
    mkdir -p "$CLASHCTL_HOME/bin"
    printf kernel >"$CLASHCTL_HOME/bin/kernel"
    printf '%s|%s|%s\n' "$CLASHCTL_KERNEL" "$CLASHCTL_UPDATE_BRANCH" "$GH_PROXY" >"$CLASHCTL_HOME/data/download-options"
    printf '%s\n' "$CLASHCTL_DOWNLOAD_TIMEOUT" >"$CLASHCTL_HOME/data/download-timeout"
}
_set_env() { printf '%s=%q\n' "$1" "$2" >>"$CLASHCTL_HOME/.env"; }
_merge_config() { printf runtime >"$CLASH_DATA_DIR/runtime.yaml"; }
_detect_proxy_port() { :; }
_detect_ext_addr() { :; }
_get_secret() { printf existing-secret; }
install_service() { :; }
service_start() { [ "${FAIL_START:-0}" = 0 ] && touch "$CLASH_DATA_DIR/started"; }
service_is_active() { [ -f "$CLASH_DATA_DIR/started" ]; }
service_enable() { touch "$CLASH_DATA_DIR/enabled"; }
clashstart() { _merge_config && service_start && service_enable; }
clashsub() {
    printf '%s' "$3" >"$CLASH_DATA_DIR/subscription"
    printf main-config >"$CLASH_CONFIG_BASE"
    clashstart
}
apply_rc() {
    touch "$CLASH_DATA_DIR/shell-ready"
    SHELL_RC_BASH="$CLASH_DATA_DIR/.bashrc"
    touch "$SHELL_RC_BASH"
}
uninstall_service() { [ "${FAIL_STOP:-0}" = 0 ]; }
revoke_rc() { :; }
_ui_error() { printf '%s\n' "$*" >&2; }
_ui_info() { printf '%s\n' "$*"; }
_ui_step() { :; }
_ui_ok() { printf '%s\n' "$*"; }
_ui_warn() { printf '%s\n' "$*"; }
_ui_detail() {
    if [ "$#" -gt 1 ]; then
        printf '        %s: %s\n' "$1" "$2"
    else
        printf '        %s\n' "$1"
    fi
}
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
[ ! -e "$CLASHCTL_HOME/.clashctl-uninitialized" ] || fail 'initialized installation retains uninitialized marker'
[ ! -e "$CLASHCTL_HOME/.clashctl-incomplete" ] || fail 'initialized installation retains incomplete marker'
[ "$(head -n 1 "$CLASHCTL_HOME/.clashctl-install")" = "$CLASHCTL_HOME" ] || fail 'pipeline did not record installation path'
[ "$(stat -c %a "$CLASHCTL_HOME/.clashctl-install")" = 600 ] || fail 'installation marker is not private'
# GH_PROXY 无隐式默认：未显式提供时保持未设（直连），不能静默套上第三方镜像。
grep -q '^#GH_PROXY=https://gh-proxy.org$' "$CLASHCTL_HOME/.env" || fail 'GH_PROXY picked up an implicit default'
grep -q '安装完成' "$WORK_DIR/install.out" || fail 'missing install result'
grep -Fqx '        当前 Shell 加载 clashctl（bash）:' "$WORK_DIR/install.out" || fail 'missing shell activation heading'
grep -q '^          source .*\.bashrc$' "$WORK_DIR/install.out" || fail 'missing shell activation step'
grep -Fqx '        添加并使用订阅:' "$WORK_DIR/install.out" || fail 'missing subscription heading'
grep -Fqx '          clashctl sub add --use "<URL>"' "$WORK_DIR/install.out" || fail 'missing subscription step'
grep -Fqx '        启动代理:' "$WORK_DIR/install.out" || fail 'missing proxy activation heading'
grep -Fqx '          clashctl on' "$WORK_DIR/install.out" || fail 'missing proxy activation step'
if grep -q 'find: warning:' "$WORK_DIR/install.out"; then fail 'source validation emitted a find warning'; fi
# 下载运行组件失败时仍可凭安装阶段标记清理，不能依靠 .env 缺失猜测。
interrupted_home="$WORK_DIR/prepare-failed"
if FAIL_PREPARE=1 FAIL_PREPARE_TIMEOUT=1 CLASHCTL_HOME="$interrupted_home" bash "$REPO_DIR/install.sh" \
    --gh-proxy=https://slow.proxy.test >"$WORK_DIR/prepare-failed.out" 2>&1; then
    fail 'component preparation failure was ignored'
fi
[ "$(tail -n 1 "$WORK_DIR/prepare-failed.out")" = \
    "重试: CLASHCTL_HOME=$interrupted_home CLASHCTL_DOWNLOAD_TIMEOUT=180 bash $interrupted_home/install.sh --gh-proxy=https://slow.proxy.test" ] ||
    fail 'retry hint lost the proxy or timeout adjustment'
[ ! -e "$interrupted_home/.env" ] || fail 'failed preparation wrote environment'
[ "$(cat "$interrupted_home/.clashctl-uninitialized")" = "$interrupted_home" ] || fail 'missing uninitialized path marker'
bash "$interrupted_home/uninstall.sh" --yes >"$WORK_DIR/prepare-uninstall.out" 2>&1 || fail 'interrupted installation cannot be cleaned'
[ ! -d "$interrupted_home" ] || fail 'interrupted installation remains'
# --gh-proxy 旗标：管道写法下参数写在右侧 bash 之后，两种形式都要生效并写入 .env。
for flag in '--gh-proxy https://flag.proxy.test' '--gh-proxy=https://flag.proxy.test'; do
    proxy_home="$WORK_DIR/flag-home"
    rm -rf "$proxy_home"
    # shellcheck disable=SC2002,SC2086  # 验证管道入口，并故意拆分旗标和值。
    cat "$REPO_DIR/install.sh" | CLASHCTL_HOME="$proxy_home" CI=1 bash -s -- $flag >"$WORK_DIR/flag.out" 2>&1 ||
        { cat "$WORK_DIR/flag.out"; fail "gh-proxy flag rejected: $flag"; }
    grep -q '^GH_PROXY=https://flag.proxy.test$' "$proxy_home/.env" ||
        fail "gh-proxy flag was not persisted: $flag"
done
rm -rf "$WORK_DIR/flag-home"
# 执行 README 原文中的管道命令，只把入口下载替换成本地脚本。
readme_command=$(sed -n '/^curl .*install\.sh | /p' "$REPO_DIR/README.md")
[ -n "$readme_command" ] || fail 'README installation command missing'
CLASHCTL_HOME="$WORK_DIR/readme-home" bash -c '
    installer=$1
    curl() { cat "$installer"; }
    eval "$2"
' _ "$REPO_DIR/install.sh" "$readme_command" >"$WORK_DIR/readme.out" 2>&1 || {
    cat "$WORK_DIR/readme.out"; fail 'README installation command failed'
}
grep -q '^GH_PROXY=https://gh-proxy.org$' "$WORK_DIR/readme-home/.env" || fail 'README proxy was not persisted'
# 续装保留已保存的选项；显式参数优先，空代理可切回直连。
retry_home="$WORK_DIR/retry-options"
CLASHCTL_HOME="$retry_home" CLASHCTL_UPDATE_BRANCH=iu bash "$REPO_DIR/install.sh" clash --gh-proxy=https://old.proxy.test >"$WORK_DIR/options.out" 2>&1
env -u GH_PROXY -u CLASHCTL_UPDATE_BRANCH CLASHCTL_HOME="$retry_home" bash "$retry_home/install.sh" >"$WORK_DIR/options.out" 2>&1
[ "$(cat "$retry_home/data/download-options")" = 'clash|iu|https://old.proxy.test' ] || fail 'retry lost saved options'
CLASHCTL_HOME="$retry_home" CLASHCTL_UPDATE_BRANCH=master GH_PROXY=https://env.proxy.test \
    bash "$retry_home/install.sh" mihomo --gh-proxy=https://new.proxy.test >"$WORK_DIR/options.out" 2>&1
[ "$(cat "$retry_home/data/download-options")" = 'mihomo|master|https://new.proxy.test' ] || fail 'saved options overrode retry arguments'
env -u GH_PROXY -u CLASHCTL_UPDATE_BRANCH CLASHCTL_HOME="$retry_home" \
    bash "$retry_home/install.sh" --gh-proxy= >"$WORK_DIR/options.out" 2>&1
[ "$(cat "$retry_home/data/download-options")" = 'mihomo|master|' ] || fail 'retry could not clear proxy'
env -u GH_PROXY -u CLASHCTL_UPDATE_BRANCH CLASHCTL_HOME="$retry_home" \
    bash "$retry_home/install.sh" >"$WORK_DIR/options.out" 2>&1
[ "$(cat "$retry_home/data/download-options")" = 'mihomo|master|' ] || fail 'retry options were not persisted'
CLASHCTL_HOME="$retry_home" CLASHCTL_DOWNLOAD_TIMEOUT=180 bash "$retry_home/install.sh" \
    >"$WORK_DIR/options.out" 2>&1
[ "$(cat "$retry_home/data/download-timeout")" = 180 ] || fail 'retry timeout was overridden by saved config'
# 源码不能通过重试初始化获得安装身份；克隆真实安装也不会继承 Git 私有标记。
if CLASHCTL_HOME="$FIXTURE" bash "$FIXTURE/install.sh" >"$WORK_DIR/source-retry.out" 2>&1; then
    fail 'installer adopted source checkout as installation'
fi
[ ! -e "$FIXTURE/.clashctl-install" ] || fail 'installer marked source checkout'
[ ! -e "$FIXTURE/.env" ] || fail 'installer initialized source checkout'
# --local 取脚本所在目录的工作区，不依赖 cwd、Git 或源码下载。
local_source="$WORK_DIR/local-source"
local_home="$WORK_DIR/local-home"
cp -a "$FIXTURE" "$local_source"
printf 'fixture_version=uncommitted\n' >"$local_source/scripts/cmd/clashctl.sh"
printf 'local_helper=true\n' >"$local_source/scripts/local-helper.sh"
printf 'ignored.txt\n' >>"$local_source/.gitignore"
printf private >"$local_source/ignored.txt"
printf 'exit 99\n' >"$local_source/.env"
printf old-marker >"$local_source/.clashctl-install"
printf old-manifest >"$local_source/.clashctl-files"
mkdir -p "$local_source/data" "$local_source/bin" "$local_source/archives" "$local_source/resources/dist"
for file in data/private bin/private archives/private resources/dist/index.html resources/cache.db; do
    printf private >"$local_source/$file"
done
(
    cd "$WORK_DIR"
    FAIL_FETCH=1 FAIL_DOWNLOAD=1 CLASHCTL_HOME="$local_home" CLASHCTL_UPDATE_BRANCH=iu \
        bash "$local_source/install.sh" --local --gh-proxy=https://local.proxy.test
) >"$WORK_DIR/local.out" 2>&1 || { cat "$WORK_DIR/local.out"; fail 'local installation failed'; }
grep -qx 'fixture_version=uncommitted' "$local_home/scripts/cmd/clashctl.sh" || fail 'local edits were not installed'
[ -f "$local_home/scripts/local-helper.sh" ] || fail 'untracked source file was omitted'
for file in .git ignored.txt data/private bin/private archives/private resources/dist resources/cache.db; do
    [ ! -e "$local_home/$file" ] || fail "local installation copied $file"
done
grep -q '^CLASHCTL_UPDATE_BRANCH=iu$' "$local_home/.env" || fail 'local installation lost update branch'
[ "$(tail -n 1 "$local_home/.clashctl-install")" = archive ] || fail 'local installation did not reuse archive updates'
(cd "$local_home" && sha256sum --status -c .clashctl-files) || fail 'local manifest is invalid'
[ "$(cat "$local_source/.env")" = 'exit 99' ] || fail 'source environment changed'
[ "$(cat "$local_source/.clashctl-install")" = old-marker ] || fail 'source identity changed'
local_interrupted="$WORK_DIR/local-interrupted"
if FAIL_PREPARE=1 CLASHCTL_HOME="$local_interrupted" bash "$local_source/install.sh" --local \
    >"$WORK_DIR/local-interrupted.out" 2>&1; then
    fail 'interrupted local installation was accepted'
fi
printf 'fixture_version=after-interruption\n' >"$local_source/scripts/cmd/clashctl.sh"
CLASHCTL_HOME="$local_interrupted" bash "$local_source/install.sh" --local \
    >"$WORK_DIR/local-resume.out" 2>&1 ||
    { cat "$WORK_DIR/local-resume.out"; fail 'interrupted local installation did not resume'; }
grep -qx 'fixture_version=after-interruption' "$local_interrupted/scripts/cmd/clashctl.sh" ||
    fail 'local retry did not refresh copied program files'
printf 'fixture_version=local-refresh\n' >"$local_source/scripts/cmd/clashctl.sh"
printf 'saved local data\n' >"$local_home/data/config.yaml"
CLASHCTL_HOME="$local_home" bash "$local_source/install.sh" --local >"$WORK_DIR/local-refresh.out" 2>&1 ||
    { cat "$WORK_DIR/local-refresh.out"; fail 'local archive update failed'; }
grep -qx 'fixture_version=local-refresh' "$local_home/scripts/cmd/clashctl.sh" ||
    fail 'local archive source did not refresh'
[ "$(<"$local_home/data/config.yaml")" = 'saved local data' ] || fail 'local archive update changed data'
bash "$local_home/uninstall.sh" --yes >"$WORK_DIR/local-uninstall.out" 2>&1 || fail 'local installation could not be uninstalled'
[ -f "$local_source/install.sh" ] || fail 'uninstall removed local source'

# 带旧身份标记的安装：先准备新源码，失败时恢复原目录，成功时备份旧目录。
legacy_v2="$WORK_DIR/legacy-v2-home"
mkdir -p "$legacy_v2/scripts/lib" "$legacy_v2/data/profiles"
cp "$FIXTURE/install.sh" "$legacy_v2/install.sh"
cp "$FIXTURE/scripts/preflight.sh" "$legacy_v2/scripts/preflight.sh"
cp "$FIXTURE/scripts/lib/common.sh" "$legacy_v2/scripts/lib/common.sh"
printf 'legacy config\n' >"$legacy_v2/data/config.yaml"
printf 'legacy profile\n' >"$legacy_v2/data/profiles/first.yaml"
printf 'CLASHCTL_KERNEL=mihomo\nCLASHCTL_UPDATE_BRANCH=iu\nGH_PROXY=https://legacy.proxy.test\nCLASHCTL_HOME=/old/path\nCLASHCTL_SRC=/old/path\n' >"$legacy_v2/.env"
printf 'CLASHCTL_INSTALLATION=clashctl\nCLASHCTL_INSTALLATION_FORMAT=1\nCLASHCTL_INSTALLATION_HOME=%s\nCLASHCTL_INSTALLATION_UID=%s\n' \
    "$legacy_v2" "$(id -u)" >"$legacy_v2/.clashctl-installation"
chmod 0600 "$legacy_v2/.clashctl-installation"
# 旧服务接管必须精确匹配旧二进制与配置路径；恢复时保留启用和运行状态。
(
    . "$REPO_DIR/install.sh"
    existing_kind='legacy-v2'
    unit_target="$WORK_DIR/legacy.service"
    unit_calls="$WORK_DIR/legacy-service.calls"
    printf 'ExecStart=%s/bin/mihomo -d %s/resources -f %s/data/runtime.yaml\n' \
        "$legacy_v2" "$legacy_v2" "$legacy_v2" >"$unit_target"
    cp "$unit_target" "$WORK_DIR/legacy.service.expected"
    detect_service_manager() { service_manager=systemd; }
    _service_target() { printf '%s\n' "$unit_target"; }
    systemctl() { printf '%s\n' "$*" >>"$unit_calls"; }
    _install_legacy_service_prepare "$legacy_v2" mihomo || fail 'owned legacy service was rejected'
    [ ! -e "$unit_target" ] || fail 'legacy service was not detached'
    _install_legacy_service_restore mihomo || fail 'legacy service restore failed'
    cmp -s "$unit_target" "$WORK_DIR/legacy.service.expected" || fail 'legacy service file changed after restore'
    grep -qx 'stop mihomo' "$unit_calls" || fail 'legacy service was not stopped'
    grep -qx 'start mihomo' "$unit_calls" || fail 'legacy service was not restarted'
    printf 'ExecStart=/usr/bin/unrelated\n' >"$unit_target"
    if _install_legacy_service_prepare "$legacy_v2" mihomo; then
        fail 'foreign service was adopted as legacy service'
    fi
    grep -qx 'ExecStart=/usr/bin/unrelated' "$unit_target" || fail 'foreign service was modified'
)
if FAIL_PREPARE=1 CLASHCTL_HOME="$legacy_v2" bash "$local_source/install.sh" --local >"$WORK_DIR/legacy-failed.out" 2>&1; then
    fail 'failed legacy migration was accepted'
fi
[ "$(<"$legacy_v2/data/config.yaml")" = 'legacy config' ] || fail 'failed migration lost old config'
[ -f "$legacy_v2/.clashctl-installation" ] || fail 'failed migration did not restore old marker'
CLASHCTL_HOME="$legacy_v2" bash "$local_source/install.sh" clash --local >"$WORK_DIR/legacy-success.out" 2>&1 ||
    { cat "$WORK_DIR/legacy-success.out"; fail 'legacy v2 migration failed'; }
[ "$(<"$legacy_v2/data/config.yaml")" = 'legacy config' ] || fail 'legacy v2 config was not migrated'
[ "$(<"$legacy_v2/data/profiles/first.yaml")" = 'legacy profile' ] || fail 'legacy v2 profile was not migrated'
[ -f "$legacy_v2/.clashctl-install" ] || fail 'legacy v2 did not gain current marker'
! grep -Eq '^CLASHCTL_(HOME|SRC)=' "$legacy_v2/.env" || fail 'legacy path overrides were retained'
[ "$(<"$legacy_v2/data/download-options")" = 'clash|iu|https://legacy.proxy.test' ] ||
    fail 'legacy v2 update options were not retained'
[ -n "$(find "$WORK_DIR" -maxdepth 1 -name 'legacy-v2-home.bak.*' -print -quit)" ] ||
    fail 'legacy v2 backup missing'

# 无标记的早期布局只在旧版代码特征和真实配置同时存在时迁移。
legacy_v1="$WORK_DIR/legacy-v1-home"
mkdir -p "$legacy_v1/scripts/lib" "$legacy_v1/resources/profiles"
printf '#!/usr/bin/env bash\n' >"$legacy_v1/install.sh"
printf '#!/usr/bin/env bash\n' >"$legacy_v1/scripts/preflight.sh"
printf 'CLASH_PROFILES_DIR="${CLASH_RESOURCES_DIR}/profiles"\n' >"$legacy_v1/scripts/lib/common.sh"
printf 'CLASHCTL_SUB_TIMEOUT=31\n' >"$legacy_v1/.env"
printf 'legacy v1 config\n' >"$legacy_v1/resources/config.yaml"
printf 'legacy v1 profile\n' >"$legacy_v1/resources/profiles/first.yaml"
CLASHCTL_HOME="$legacy_v1" bash "$local_source/install.sh" --local >"$WORK_DIR/v1-success.out" 2>&1 ||
    { cat "$WORK_DIR/v1-success.out"; fail 'legacy v1 migration failed'; }
[ "$(<"$legacy_v1/data/config.yaml")" = 'legacy v1 config' ] || fail 'legacy v1 config was not migrated'
[ "$(<"$legacy_v1/data/profiles/first.yaml")" = 'legacy v1 profile' ] || fail 'legacy v1 profile was not migrated'
grep -q '^CLASHCTL_SUB_TIMEOUT=31$' "$legacy_v1/.env" || fail 'legacy user option was not migrated'
legacy_default_user="$WORK_DIR/legacy-default-user"
mkdir -p "$legacy_default_user"
legacy_v1_backup=$(find "$WORK_DIR" -maxdepth 1 -name 'legacy-v1-home.bak.*' -print -quit)
cp -a -- "$legacy_v1_backup" "$legacy_default_user/clashctl"
env -u CLASHCTL_HOME HOME="$legacy_default_user" bash "$local_source/install.sh" --local \
    >"$WORK_DIR/v1-default.out" 2>&1 ||
    { cat "$WORK_DIR/v1-default.out"; fail 'historical default directory was not migrated'; }
[ "$(<"$legacy_default_user/.clashctl/data/config.yaml")" = 'legacy v1 config' ] ||
    fail 'historical default config was not migrated'
[ -n "$(find "$legacy_default_user" -maxdepth 1 -name 'clashctl.bak.*' -print -quit)" ] ||
    fail 'historical default directory was not backed up'

if CLASHCTL_HOME="$local_source/nested" bash "$local_source/install.sh" --local >"$WORK_DIR/local-nested.out" 2>&1; then
    fail 'local installation accepted a destination inside its source'
fi
[ ! -e "$local_source/nested" ] || fail 'nested local installation changed source'
# shellcheck disable=SC2002  # 验证管道输入缺少本地源码路径时的错误。
if cat "$REPO_DIR/install.sh" | CLASHCTL_HOME="$WORK_DIR/local-pipe" bash -s -- --local >"$WORK_DIR/local-pipe.out" 2>&1; then
    fail 'local installation accepted pipeline input'
fi
grep -q '不支持管道输入' "$WORK_DIR/local-pipe.out" || fail 'missing local pipeline diagnosis'
printf 'broken() {\n' >"$local_source/scripts/local-helper.sh"
if CLASHCTL_HOME="$local_home" bash "$local_source/install.sh" --local >"$WORK_DIR/local-broken.out" 2>&1; then
    fail 'local installation accepted broken source'
fi
[ ! -e "$local_home" ] || fail 'invalid local source left an installation'
"$REAL_GIT" clone -q "$CLASHCTL_HOME" "$WORK_DIR/cloned-install"
[ ! -e "$WORK_DIR/cloned-install/.clashctl-install" ] || fail 'Git clone inherited installation identity'
if CLASHCTL_HOME="$WORK_DIR/cloned-install" bash "$WORK_DIR/cloned-install/uninstall.sh" --yes >"$WORK_DIR/cloned-uninstall.out" 2>&1; then
    fail 'cloned installation was accepted for uninstall'
fi
[ -f "$WORK_DIR/cloned-install/install.sh" ] || fail 'cloned installation was removed'
printf 'fixture_version=auto-updated\n' >"$FIXTURE/scripts/cmd/clashctl.sh"
"$REAL_GIT" -C "$FIXTURE" commit -qam auto-updated
printf 'user data preserved\n' >"$CLASHCTL_HOME/data/config.yaml"
bash "$REPO_DIR/install.sh" >"$WORK_DIR/existing.out" 2>&1 || {
    cat "$WORK_DIR/existing.out"; fail 'existing installation was not updated'
}
grep -qx 'fixture_version=auto-updated' "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" ||
    fail 'installer did not refresh existing program files'
[ "$(<"$CLASHCTL_HOME/data/config.yaml")" = 'user data preserved' ] ||
    fail 'installer changed existing user data'
chmod 0644 "$CLASHCTL_HOME/.clashctl-install"
if bash "$REPO_DIR/install.sh" >"$WORK_DIR/unsafe-marker.out" 2>&1; then
    fail 'installer accepted a writable installation marker'
fi
chmod 0600 "$CLASHCTL_HOME/.clashctl-install"
mv "$CLASHCTL_HOME/.env" "$CLASHCTL_HOME/.env.saved"
ln -s .env.saved "$CLASHCTL_HOME/.env"
if bash "$REPO_DIR/install.sh" >"$WORK_DIR/unsafe-env.out" 2>&1; then
    fail 'installer accepted a symlinked environment file'
fi
rm "$CLASHCTL_HOME/.env"
mv "$CLASHCTL_HOME/.env.saved" "$CLASHCTL_HOME/.env"
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
[ -f "$CLASHCTL_HOME/.clashctl-incomplete" ] || fail 'failed initialization lost incomplete marker'
bash "$CLASHCTL_HOME/install.sh" >"$WORK_DIR/retry.out" 2>&1
[ -f "$CLASHCTL_HOME/data/started" ] || fail 'root installer could not retry initialization'
[ ! -e "$CLASHCTL_HOME/.clashctl-incomplete" ] || fail 'retry retained incomplete marker'

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

# 控制终端与脚本 stdin 分离：真实 PTY 下读取订阅，确认用户能看到粘贴内容。
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
            if not sent and "订阅链接（回车跳过）: ".encode() in output:
                os.write(fd, b"file:///private-subscription\n")
                sent = True
        child, child_status = os.waitpid(pid, os.WNOHANG)
        if child:
            status = child_status
            break
    if status is None:
        # PTY 关闭可能早于子进程可回收；仍受同一个截止时间约束。
        while time.monotonic() < deadline:
            child, child_status = os.waitpid(pid, os.WNOHANG)
            if child:
                status = child_status
                break
            time.sleep(0.01)
        if status is None:
            raise AssertionError("TTY installation timed out: " + output.decode(errors="replace"))
    assert os.waitstatus_to_exitcode(status) == 0, output.decode(errors="replace")
    assert sent, "subscription prompt missing"
    assert os.path.isfile(work + "/tty-install/data/started")
    assert os.path.isfile(work + "/tty-install/data/enabled")
    assert output.count(b"file:///private-subscription") == 1, "subscription input was not shown exactly once"
    assert "当前 Shell 加载 clashctl（bash）:".encode() in output, "missing shell activation heading"
    assert "添加并使用订阅:".encode() not in output, "configured installation suggested adding a subscription"
    assert "启动代理:".encode() in output, "missing proxy activation heading"
    assert b"          clashctl on" in output, "missing proxy activation step"
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
# 空标记（半截写入的残留）必须指出具体文件，便于用户排查。
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
