#!/usr/bin/env bash
# 临时安装目录和用户目录，systemctl 桩记录调用，绝不操作宿主服务。
# shellcheck disable=SC2016  # 引导文件中的变量必须原样写入
set -euo pipefail
REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/user/.config/fish/conf.d"
export UNINSTALL_CALLS="$WORK_DIR/service.calls" UNINSTALL_ACTIVE="$WORK_DIR/active"
cat >"$WORK_DIR/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$UNINSTALL_CALLS"
case $1 in
is-active) [ -f "$UNINSTALL_ACTIVE" ] ;;
stop) [ "${FAIL_STOP:-0}" = 0 ] && rm -f "$UNINSTALL_ACTIVE" ;;
*) exit 0 ;;
esac
STUB
printf '#!/bin/sh\n' >"$WORK_DIR/bin/fish"
printf '#!/bin/sh\n' >"$WORK_DIR/bin/zsh"
chmod +x "$WORK_DIR/bin/"*
export PATH="$WORK_DIR/bin:$PATH"

setup_source() {
    local dest=$1
    mkdir -p "$dest/.git"
    cp "$REPO_DIR/"{install,uninstall}.sh "$dest/"
    cp -a "$REPO_DIR/scripts" "$dest/"
    # 仅替换 init 探测和服务文件路径，保留真实卸载与归属检查。
    cat >>"$dest/scripts/lib/service.sh" <<'STUB'
detect_service_manager() { service_manager=systemd; }
_service_target() { printf '%s/service.unit\n' "$CLASHCTL_HOME"; }
STUB
}
setup_install() {
    setup_source "$1"
    printf '%s\ngit\n' "$1" >"$1/.clashctl-install"
}
write_rc() {
    local target=$1 rc
    for rc in .bashrc .zshrc; do
        {
            printf '# user setting\n# >>> clashctl >>>\nexport CLASHCTL_HOME=%q\n' "$target"
            printf '%s\n' '[ -s "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" ] && . "$CLASHCTL_HOME/scripts/cmd/clashctl.sh"' '# <<< clashctl <<<'
        } >"$WORK_DIR/user/$rc"
    done
    printf '# clashctl shell-rc (managed by install.sh, do not edit)\nset -gx CLASHCTL_HOME '\''%s'\''\n' "$target" >"$WORK_DIR/user/.config/fish/conf.d/clashctl.fish"
}
run_uninstall() {
    HOME="$WORK_DIR/user" CLASHCTL_KERNEL=mihomo INIT_TYPE=systemd \
        bash "$1/uninstall.sh" --yes >"$WORK_DIR/output" 2>&1
}

# 源码目录即使有 .git 或 .env 也不能卸载，更不能受继承的安装路径影响。
setup_source "$WORK_DIR/clone"
write_rc "$WORK_DIR/other-install"
cp -a "$WORK_DIR/user" "$WORK_DIR/user.expected"
printf 'exit 77\n' >"$WORK_DIR/clone/scripts/preflight.sh"
if run_uninstall "$WORK_DIR/clone"; then fail 'fresh source clone was accepted for uninstall'; fi
[ -f "$WORK_DIR/clone/uninstall.sh" ] || fail 'source clone was removed'
grep -q '缺少匹配的安装标记' "$WORK_DIR/output" || fail 'missing source directory rejection'
printf 'CLASHCTL_KERNEL=clash\nINIT_TYPE=systemd\n' >"$WORK_DIR/clone/.env"
setup_install "$WORK_DIR/other-install"
if (cd "$WORK_DIR/clone" && HOME="$WORK_DIR/user" CLASHCTL_HOME="$WORK_DIR/other-install" \
    bash uninstall.sh --yes) >"$WORK_DIR/output" 2>&1; then
    fail 'source clone with environment was accepted for uninstall'
fi
[ -f "$WORK_DIR/clone/.env" ] || fail 'source clone with environment was removed'
[ -f "$WORK_DIR/other-install/uninstall.sh" ] || fail 'source uninstall removed another installation'
ln -s "$WORK_DIR/clone" "$WORK_DIR/user/.clashctl"
if run_uninstall "$WORK_DIR/user/.clashctl"; then fail 'symlink to source bypassed installation check'; fi
[ -f "$WORK_DIR/clone/uninstall.sh" ] || fail 'symlink uninstall removed source'
[ ! -e "$UNINSTALL_CALLS" ] || fail 'source rejection invoked system services'
rm "$WORK_DIR/user/.clashctl"
diff -r "$WORK_DIR/user.expected" "$WORK_DIR/user" || fail 'source rejection changed shell integration'

# 复制安装目录不授予新目录卸载权限；软链接标记也拒绝。
cp -a "$WORK_DIR/other-install" "$WORK_DIR/copied"
if run_uninstall "$WORK_DIR/copied"; then fail 'copied installation marker was accepted'; fi
[ -d "$WORK_DIR/copied" ] || fail 'copied directory was removed'
rm "$WORK_DIR/copied/.clashctl-install"
printf '%s\n' "$WORK_DIR/copied" >"$WORK_DIR/external-marker"
ln -s "$WORK_DIR/external-marker" "$WORK_DIR/copied/.clashctl-install"
if run_uninstall "$WORK_DIR/copied"; then fail 'symlink marker was accepted'; fi
# 安装器留下的未初始化目录有真实标记，仍可清理，且不加载 preflight。
setup_install "$WORK_DIR/interrupted"
printf 'exit 77\n' >"$WORK_DIR/interrupted/scripts/preflight.sh"
run_uninstall "$WORK_DIR/interrupted" || fail 'interrupted installation cleanup failed'
[ ! -e "$WORK_DIR/interrupted" ] || fail 'interrupted installation remains'
[ ! -e "$UNINSTALL_CALLS" ] || fail 'interrupted install cleanup invoked system services'
diff -r "$WORK_DIR/user.expected" "$WORK_DIR/user" || fail 'interrupted cleanup changed shell integration'

# 无效 .env 不能沿用父进程内核，也不能删目录或 Shell 引导。
setup_install "$WORK_DIR/invalid"
printf 'INIT_TYPE=systemd\n' >"$WORK_DIR/invalid/.env"
if run_uninstall "$WORK_DIR/invalid"; then fail 'missing kernel was accepted'; fi
[ -d "$WORK_DIR/invalid" ] || fail 'invalid installation was removed'
[ ! -e "$UNINSTALL_CALLS" ] || fail 'invalid environment invoked system services'
diff -r "$WORK_DIR/user.expected" "$WORK_DIR/user" || fail 'invalid environment changed shell integration'

printf 'CLASHCTL_KERNEL=clash\nreturn 1\n' >"$WORK_DIR/invalid/.env"
if run_uninstall "$WORK_DIR/invalid"; then fail 'failed environment load was ignored'; fi
[ -d "$WORK_DIR/invalid" ] || fail 'failed environment load removed installation'
printf 'CLASHCTL_KERNEL=clash\nCLASHCTL_HOME=%q\n' "$WORK_DIR/other-install" >"$WORK_DIR/invalid/.env"
if run_uninstall "$WORK_DIR/invalid"; then fail 'environment redirected uninstall to another directory'; fi
[ ! -e "$UNINSTALL_CALLS" ] || fail 'invalid environment touched a service'

# 正常安装：使用 .env 的 clash 而非父进程 mihomo；停服务失败时全部保留。
setup_install "$WORK_DIR/installed"
printf 'CLASHCTL_KERNEL=clash\nINIT_TYPE=systemd\n' >"$WORK_DIR/installed/.env"
printf 'ExecStart=%s/bin/clash/clash -d %s/resources -f %s/data/runtime.yaml\n' "$WORK_DIR/installed" "$WORK_DIR/installed" "$WORK_DIR/installed" >"$WORK_DIR/installed/service.unit"
write_rc "$WORK_DIR/installed"
touch "$UNINSTALL_ACTIVE"
if FAIL_STOP=1 run_uninstall "$WORK_DIR/installed"; then fail 'failed service stop was ignored'; fi
[ -f "$WORK_DIR/installed/service.unit" ] || fail 'failed stop removed service definition'
grep -q '# >>> clashctl >>>' "$WORK_DIR/user/.bashrc" || fail 'failed stop removed shell integration'
run_uninstall "$WORK_DIR/installed" || { cat "$WORK_DIR/output"; fail 'installed cleanup failed'; }
[ ! -d "$WORK_DIR/installed" ] || fail 'installation directory remains'
[ ! -e "$UNINSTALL_ACTIVE" ] || fail 'service was not stopped'
grep -q '^stop clash$' "$UNINSTALL_CALLS" || fail 'uninstall did not use stored kernel'
! grep -q mihomo "$UNINSTALL_CALLS" || fail 'uninstall used inherited kernel'
for rc in .bashrc .zshrc; do
    [ "$(cat "$WORK_DIR/user/$rc")" = '# user setting' ] || fail 'owned shell integration was not removed cleanly'
done
[ ! -e "$WORK_DIR/user/.config/fish/conf.d/clashctl.fish" ] || fail 'owned fish integration remains'

# 已初始化的旧安装也不能清理指向其他安装的引导。
setup_install "$WORK_DIR/old"
printf 'CLASHCTL_KERNEL=clash\nINIT_TYPE=systemd\n' >"$WORK_DIR/old/.env"
write_rc "$WORK_DIR/other-install"
run_uninstall "$WORK_DIR/old" || fail 'old installation cleanup failed'
diff -r "$WORK_DIR/user.expected" "$WORK_DIR/user" || fail 'old installation removed other installation integration'
# Shell 清理失败也必须保留目录，不能报告成功。
setup_install "$WORK_DIR/rc-failed"
printf 'CLASHCTL_KERNEL=clash\nINIT_TYPE=systemd\n' >"$WORK_DIR/rc-failed/.env"
printf '\nrevoke_rc() { return 1; }\n' >>"$WORK_DIR/rc-failed/scripts/preflight.sh"
if run_uninstall "$WORK_DIR/rc-failed"; then fail 'failed shell cleanup was ignored'; fi
[ -d "$WORK_DIR/rc-failed" ] || fail 'failed shell cleanup removed installation'
! grep -q '卸载完成' "$WORK_DIR/output" || fail 'failed shell cleanup reported success'
printf 'uninstall-scope: ok\n'
