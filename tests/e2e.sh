#!/bin/env bash
# E2E 全流程自验证循环：安装/续装/迁移/切换/更新/卸载 × 12 场景。
# 离线确定性：本地 git 镜像源 + 假 api.github.com 应答 + file:// 订阅 + 假内核
# （自定义 HTTP 服务器充当 external-controller）。真 systemd 场景带 unit 备份恢复。
# 用法：CLASHCTL_E2E=1 bash tests/e2e.sh [场景名…]（缺省全跑；root 跑 systemd 场景）
set -u
CLASHCTL_E2E=1
export CLASHCTL_E2E

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=/var/tmp/clashctl-e2e
PASS=0
FAIL=0
FAILED_CASES=

say() { printf '\n━━ %s ━━\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); FAILED_CASES="$FAILED_CASES $1"; printf 'FAIL %s: %s\n' "$1" "$2"; }
has() { grep -Fqs -- "$2" "$1"; }

# ── 离线基件 ───────────────────────────────────────────────
setup_offline() {
    rm -rf "$WORK"
    mkdir -p "$WORK"

    # 本地 git 镜像（安装/更新取源全走它，零网络）
    git clone -q "$REPO_DIR" "$WORK/mirror"
    git -C "$WORK/mirror" checkout -q -B iu HEAD
    # 叠加工作区未提交改动并提交（E2E 验证当前工作树；不提交则下游
    # git clone 仍取旧 HEAD——本 harness 两次踩中此坑）
    (cd "$REPO_DIR" && tar -c --exclude=.git .) | (cd "$WORK/mirror" && tar -x)
    git -C "$WORK/mirror" add -A
    git -C "$WORK/mirror" -c user.email=e2e@t -c user.name=e2e         commit -qm 'e2e: working-tree snapshot' || true
    MIRROR_URL=$WORK/mirror

    # 假内核：C 编译的 200-Always 服务器（-t 配置校验直接过）。
    # 不能用脚本+exec 解释器：/proc/exe 身份校验会失败（nohup pid 记录）
    cat >"$WORK/fake-kernel.c" <<'EOF'
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
int main(int argc, char **argv) {
    int i, s, c; struct sockaddr_in a; char b[512];
    for (i = 1; i < argc; i++) if (!strcmp(argv[i], "-t")) return 0;
    int one = 1;
    s = socket(AF_INET, SOCK_STREAM, 0);
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    a.sin_family = AF_INET; a.sin_addr.s_addr = htonl(0x7f000001); a.sin_port = htons(9090);
    if (bind(s, (struct sockaddr*)&a, sizeof a) < 0) return 1;
    listen(s, 8);
    for (;;) {
        c = accept(s, 0, 0); if (c < 0) continue;
        read(c, b, sizeof b);
        dprintf(c, "HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nok");
        close(c);
    }
}
EOF
    gcc -O2 -o "$WORK/fake-kernel" "$WORK/fake-kernel.c" || return 1

    # 假归档缓存：mihomo v3 变体（按版本查询应答对齐）与 clash 固定版本
    gzip -c "$WORK/fake-kernel" >"$WORK/mihomo-linux-amd64-v3-v1.19.30.gz"
    gzip -c "$WORK/fake-kernel" >"$WORK/clash-linux-amd64-2023.08.17.gz"

    # 订阅内容（file:// 离线读取）
    cat >"$WORK/sub.yaml" <<'EOF'
port: 17890
proxies:
  - name: e2e-node
    type: socks5
    server: 127.0.0.1
    port: 11080
EOF
    printf 'file://%s/sub.yaml\n' "$WORK" >"$WORK/sub.url"
    chmod 0600 "$WORK/sub.url"

    # 假 curl（PATH 前置脚本，穿透 env -i 与 exec 交接链）：
    # - latest 查询 → 固定 v1.19.30（与归档文件名对齐）
    # - 组件归档下载 → 直接落盘假内核归档（--output 感知）
    # - 其余（file:// 订阅等）→ 透传真 curl
    mkdir -p "$WORK/bin"
    cat >"$WORK/bin/curl" <<'CURL'
#!/usr/bin/env bash
payload() { # $1=产物文件，$2…=原始 curl 参数（感知 --output）
    local src=$1
    shift
    local out=
    while [ $# -gt 0 ]; do
        [ "$1" = --output ] && { out=$2; shift 2; continue; }
        shift
    done
    if [ -n "$out" ]; then
        cat "$src" >"$out"
    else
        cat "$src"
    fi
}
case $* in
*api.github.com/repos/MetaCubeX/mihomo/releases/latest*)
    printf '{"tag_name": "v1.19.30"}\n'
    exit 0
    ;;
*MetaCubeX/mihomo/releases/download/*)
    payload /var/tmp/clashctl-e2e/mihomo-linux-amd64-v3-v1.19.30.gz "$@"
    exit $?
    ;;
*releases/download/clash/clash-linux-*)
    payload /var/tmp/clashctl-e2e/clash-linux-amd64-2023.08.17.gz "$@"
    exit $?
    ;;
*codeload.github.com/*)
    exit 22
    ;;
*)
    exec /usr/bin/curl "$@"
    ;;
esac
CURL
    chmod 0755 "$WORK/bin/curl"

    # 在线安装器形态：副本置于非 git 目录（在仓库内直跑会触发本地源检测）
    mkdir -p "$WORK/online"
    cp "$REPO_DIR/install.sh" "$WORK/online/install.sh"
}

# 每场景的干净用户环境（rc 块写入隔离 HOME）
new_env() { # $1=tag → stdout 输出 sandbox 根
    local root="$WORK/$1"
    rm -rf "$root"
    mkdir -p "$root/user"
    printf '%s' "$root"
}

run_install() { # 在 $1=sandbox 根内跑安装器，$2… 透传；stdout/stderr → $root/io.{out,err}
    local root=$1
    shift
    env -i PATH="$WORK/bin:$PATH" HOME="$root/user" \
        CLASHCTL_UPDATE_GIT_URL="$MIRROR_URL" INIT_TYPE=nohup \
        CLASHCTL_COLOR=never TERM=dumb \
        bash "$WORK/online/install.sh" "$@" \
        >"$root/io.out" 2>"$root/io.err" </dev/null
}

run_clashctl() { # $1=root, $2=INIT_TYPE, $3…=子命令
    local root=$1 manager=$2
    shift 2
    env -i PATH="$WORK/bin:$PATH" HOME="$root/user" CLASHCTL_HOME="$root/home" \
        INIT_TYPE=$manager CLASHCTL_UPDATE_GIT_URL="$MIRROR_URL" \
        CLASHCTL_COLOR=never TERM=dumb \
        bash -c '. "$1/scripts/cmd/clashctl.sh"; shift; clashctl "$@"' \
        _ "$root/home" "$@" >"$root/cli.out" 2>"$root/cli.err" </dev/null
}

seed_archives() { # $1=home：预置缓存使组件下载离线命中
    mkdir -p "$1/archives"
    cp "$WORK/mihomo-linux-amd64-v3-v1.19.30.gz" "$1/archives/"
    cp "$WORK/clash-linux-amd64-2023.08.17.gz" "$1/archives/" 2>/dev/null || true
}

make_empty_shell() { # $1=home：marker + 镜像源 + 种子 resources（v2 空壳形态）
    git clone -q "$MIRROR_URL" "$1"
    env -i PATH="$PATH" CLASHCTL_INSTALL_SOURCE_ONLY=1 CLASHCTL_HOME="$1" \
        bash -c '. "$1/install.sh"; _install_marker_write "$1" "$1"' _ "$1"
}

stop_all_sandboxes() {
    # 假内核经 exec 成为 python（cmdline 不含沙箱路径）→ 按端口与 pid 记录停。
    # 绝不 pkill -f 全局模式：外层命令行含沙箱路径会自杀（本 harness 实测事故）
    local pidfile
    for pidfile in "$WORK"/*/home/data/*.pid; do
        [ -f "$pidfile" ] || continue
        local pid
        pid=$(head -1 "$pidfile" 2>/dev/null)
        case $pid in '' | *[!0-9]*) continue ;; esac
        kill "$pid" 2>/dev/null || true
    done
    fuser -k 9090/tcp >/dev/null 2>&1 || true
    return 0
}

complete_asserts() { # $1=root $2=tag：完整安装的通用断言
    local root=$1 tag=$2
    [ -f "$root/home/.env" ] && ok "$tag: .env 物化" || no "$tag" ".env 缺失"
    [ -x "$root/home/bin/mihomo/mihomo" ] && ok "$tag: 内核落位" || no "$tag" "内核未落位"
    grep -Eqs 'clashctl (核心)?安装完成' "$root/io.err" &&
        ok "$tag: 完成摘要" || no "$tag" "无完成摘要"
    has "$root/io.err" '迁移旧版数据' && no "$tag" "v2 流程误触发迁移" || ok "$tag: 无误迁移"
    timeout 3 /usr/bin/curl -sf http://127.0.0.1:9090/version >/dev/null 2>&1 &&
        ok "$tag: 内核进程运行" || no "$tag" "内核进程未运行(控制器未应答)"
}

# ── 场景 ───────────────────────────────────────────────────
s1_fresh_install() {
    local root
    root=$(new_env s1)
    mkdir -p "$root/user"
    run_install "$root" --home "$root/home" --branch iu --non-interactive \
        --subscription-file "$WORK/sub.url" >/dev/null || true
    complete_asserts "$root" s1
}

s2_resume_inplace() {
    local root
    root=$(new_env s2)
    make_empty_shell "$root/home"
    env -i PATH="$WORK/bin:$PATH" HOME="$root/user" INIT_TYPE=nohup \
        CLASHCTL_COLOR=never TERM=dumb \
        bash "$root/home/install.sh" --branch iu --non-interactive \
        --subscription-file "$WORK/sub.url" >"$root/io.out" 2>"$root/io.err" </dev/null || true
    complete_asserts "$root" s2
    has "$root/io.err" '继续未完成的安装' && ok "s2: 续装标识" || no s2 "无续装标识"
}

s3_resume_online_refresh() {
    local root
    root=$(new_env s3)
    make_empty_shell "$root/home"
    run_install "$root" --home "$root/home" --branch iu --non-interactive \
        --subscription-file "$WORK/sub.url" >/dev/null || true
    complete_asserts "$root" s3
    has "$root/io.err" '程序文件已刷新至最新' && ok "s3: 在线刷新" || no s3 "无刷新标识"
}

s4_refresh_fail_fallback() {
    local root
    root=$(new_env s4)
    make_empty_shell "$root/home"
    env -i PATH="$WORK/bin:$PATH" HOME="$root/user" CLASHCTL_UPDATE_GIT_URL="https://codeload.github.com/e2e-block" \
        INIT_TYPE=nohup CLASHCTL_COLOR=never TERM=dumb \
        bash "$WORK/online/install.sh" --home "$root/home" --branch iu --non-interactive \
        >"$root/io.out" 2>"$root/io.err" </dev/null
    local rc=$?
    [ "$rc" -ne 0 ] && ok "s4: 刷新失败中止(rc=$rc)" || no s4 "异常成功"
    has "$root/io.err" '继续安装' && ok "s4: 续装指引" || no s4 "无指引"
    [ -f "$root/home/.env" ] && no s4 "不应物化 .env" || ok "s4: 未物化 .env"
    [ -d "$root/home/data" ] && no s4 "不应误迁移" || ok "s4: 无迁移"
}

s5_legacy_takeover() {
    local root old
    root=$(new_env s5)
    old="$root/user/clashctl"
    mkdir -p "$old/resources/profiles" "$old/bin" "$old/scripts/lib" "$old/scripts/cmd"
    printf 'port: 7890\n' >"$old/resources/config.yaml"
    printf 'mixed-port: 7890\n\nexternal-controller: "127.0.0.1:9090"\n' >"$old/resources/mixin.yaml"
    printf 'profiles:\n  - name: old\n    url: https://old.invalid/t\n' >"$old/resources/profiles.yaml"
    printf 'proxies: []\n' >"$old/resources/profiles/old.yaml"
    printf '#!/bin/sh\n' >"$old/bin/mihomo"
    for f in install.sh uninstall.sh; do : >"$old/$f"; done
    : >"$old/scripts/preflight.sh"; : >"$old/scripts/lib/common.sh"; : >"$old/scripts/cmd/off.sh"
    mkdir -p "$root/user"
    run_install "$root" --home "$old" --allow-legacy-layout --branch iu \
        --non-interactive --subscription-file "$WORK/sub.url" >/dev/null || true
    has "$root/io.err" '迁移旧版数据' && ok "s5: 迁移步骤触发" || no s5 "未触发迁移"
    [ -f "$old/data/profiles.yaml" ] && ok "s5: 用户数据迁入 data/" || no s5 "data/ 未迁移"
    grep -Fqs 'https://old.invalid/t' "$old/data/profiles.yaml" &&
        ok "s5: 旧订阅数据保留" || no s5 "旧订阅丢失"
    [ -f "$old/.env" ] && ok "s5: 接管后完成安装" || no s5 "接管未完成"
    [ -x "$old/bin/mihomo/mihomo" ] && ok "s5: 新内核落位" || no s5 "新内核未落位"
    stop_all_sandboxes
}

s6_v2_shell_no_migration() { # 今日回归 bug 的钉子
    local root
    root=$(new_env s6)
    make_empty_shell "$root/home"   # 含仓库种子 resources/profiles.yaml
    env -i PATH="$PATH" HOME="$root/user" CLASHCTL_UPDATE_GIT_URL="https://codeload.github.com/e2e-block" \
        CLASHCTL_COLOR=never TERM=dumb \
        bash "$WORK/online/install.sh" --home "$root/home" --branch iu --non-interactive \
        >"$root/io.out" 2>"$root/io.err" </dev/null
    has "$root/io.err" '迁移旧版数据' && no s6 "种子模板误判旧版" || ok "s6: 种子不触发迁移"
}

s7_idempotent() {
    local root
    root=$(new_env s7)
    mkdir -p "$root/user"
    run_install "$root" --home "$root/home" --branch iu --non-interactive >/dev/null || true
    [ -f "$root/home/.env" ] || { no s7 "前置安装失败"; return; }
    run_clashctl "$root" nohup install >"$root/cli.out" 2>"$root/cli.err" || true
    has "$root/cli.err" '已完成初始化' && ok "s7: 幂等提示" || no s7 "无幂等提示"
    stop_all_sandboxes
}

s8_switch_kernel() {
    local root
    root=$(new_env s8)
    mkdir -p "$root/user"
    run_install "$root" --home "$root/home" --branch iu --non-interactive >/dev/null || true
    [ -f "$root/home/.env" ] || { no s8 "前置安装失败"; return; }
    run_clashctl "$root" nohup install clash >"$root/cli.out" 2>"$root/cli.err" || true
    [ -x "$root/home/bin/clash/clash" ] && ok "s8: 第二内核落位" || no s8 "clash 未落位"
    grep -Fqs 'CLASHCTL_KERNEL=clash' "$root/home/.env" &&
        ok "s8: 激活指针切换" || no s8 "指针未切换"
    stop_all_sandboxes
}

s9_uninstall_full() {
    local root rc
    root=$(new_env s9)
    mkdir -p "$root/user"
    run_install "$root" --home "$root/home" --branch iu --non-interactive >/dev/null || true
    [ -f "$root/home/.env" ] || { no s9 "前置安装失败"; return; }
    rc=0
    env -i PATH="$WORK/bin:$PATH" HOME="$root/user" CLASHCTL_HOME="$root/home" \
        INIT_TYPE=nohup bash "$root/home/uninstall.sh" --yes >"$root/uni.out" 2>"$root/uni.err" </dev/null || rc=$?
    [ "$rc" -eq 0 ] && ok "s9: 卸载 rc=0" || no s9 "卸载 rc=$rc"
    [ ! -e "$root/home" ] && ok "s9: 目录删除" || no s9 "目录残留"
    pgrep -f "$root/home" >/dev/null && no s9 "进程残留" || ok "s9: 进程清理"
}

s10_uninstall_shell() {
    local root rc
    root=$(new_env s10)
    make_empty_shell "$root/home"
    rc=0
    env -i PATH="$WORK/bin:$PATH" HOME="$root/user" CLASHCTL_HOME="$root/home" \
        INIT_TYPE=nohup bash "$root/home/uninstall.sh" --yes >"$root/uni.out" 2>"$root/uni.err" </dev/null || rc=$?
    [ "$rc" -eq 0 ] && ok "s10: 空壳卸载 rc=0" || no s10 "rc=$rc"
    [ ! -e "$root/home" ] && ok "s10: 目录删除" || no s10 "目录残留"
}

s11_update() {
    local root
    root=$(new_env s11)
    mkdir -p "$root/user"
    run_install "$root" --home "$root/home" --branch iu --non-interactive >/dev/null || true
    [ -f "$root/home/.env" ] || { no s11 "前置安装失败"; return; }
    stop_all_sandboxes
    git -C "$WORK/mirror" -c user.email=e2e@t -c user.name=e2e \
        commit -q --allow-empty -m 'e2e: advance' || true
    run_clashctl "$root" nohup update >"$root/cli.out" 2>"$root/cli.err" || true
    has "$root/cli.err" '已是最新版本' && ok "s11: 幂等更新正常" || {
        git -C "$root/home" log --oneline -1 | grep -Fqs 'e2e: advance' &&
            ok "s11: 更新推进" || no s11 "更新未推进"
    }
    { has "$root/cli.err" '当前 Shell 已自动加载' || has "$root/cli.out" '当前 Shell 已自动加载'; } &&
        ok "s11: 热重载如实" || no s11 "热重载消息缺失"
    stop_all_sandboxes
}

s12_systemd_real() {
    [ "$(id -u)" -eq 0 ] && command -v systemctl >/dev/null || { ok "s12: 跳过(非root)"; return; }
    local root unit wants bak=
    unit=/etc/systemd/system/mihomo.service
    wants=/etc/systemd/system/multi-user.target.wants/mihomo.service
    [ -e "$unit" ] && { cp -a "$unit" "$WORK/unit.bak"; bak=1; }
    root=$(new_env s12)
    mkdir -p "$root/user"
    env -i PATH="$WORK/bin:$PATH" HOME="$root/user" \
        CLASHCTL_UPDATE_GIT_URL="$MIRROR_URL" CLASHCTL_COLOR=never TERM=dumb \
        bash "$WORK/online/install.sh" --home "$root/home" --branch iu --non-interactive \
        --take-over-service --subscription-file "$WORK/sub.url" \
        >"$root/io.out" 2>"$root/io.err" </dev/null || true
    [ -f "$root/home/.env" ] && ok "s12: systemd 安装完成" || no s12 ".env 缺失"
    systemctl is-active mihomo >/dev/null 2>&1 &&
        ok "s12: 单元运行" || no s12 "单元未运行"
    grep -Fqs "$root/home/bin" "$unit" &&
        ok "s12: 单元指向沙箱" || no s12 "单元指向异常"
    env -i PATH="$WORK/bin:$PATH" HOME="$root/user" CLASHCTL_HOME="$root/home" \
        INIT_TYPE=nohup bash "$root/home/uninstall.sh" --yes >"$root/uni.out" 2>"$root/uni.err" </dev/null || true
    if [ "$bak" = 1 ]; then
        [ -e "$unit" ] && ok "s12: 卸载后恢复原单元" || no s12 "原单元未恢复"
        cp -a "$WORK/unit.bak" "$unit"
        systemctl daemon-reload
    else
        [ ! -e "$unit" ] && ok "s12: 卸载清单元" || no s12 "单元残留"
    fi
    stop_all_sandboxes
}

# ── 主循环 ─────────────────────────────────────────────────
setup_offline || fail "离线基件构建失败(gcc/python 缺失?)"
ALL="s1_fresh_install s2_resume_inplace s3_resume_online_refresh s4_refresh_fail_fallback
s5_legacy_takeover s6_v2_shell_no_migration s7_idempotent s8_switch_kernel
s9_uninstall_full s10_uninstall_shell s11_update s12_systemd_real"
SELECT=${*:-$ALL}
for scen in $SELECT; do
    say "$scen"
    stop_all_sandboxes
    "$scen" 2>"$WORK/cur.err" || no "$scen" "场景函数异常: $(head -2 "$WORK/cur.err")"
done
stop_all_sandboxes
printf '\n══════ E2E: PASS=%d FAIL=%d ══════\n' "$PASS" "$FAIL"
[ -n "$FAILED_CASES" ] && printf '失败:%s\n' "$FAILED_CASES"
[ "$FAIL" -eq 0 ]
