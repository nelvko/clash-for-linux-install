# macOS Migration Plan

本文档列出将当前项目从 Linux 支持扩展到 macOS 所需的改造内容。

## 目标

让项目在 macOS 上完成以下能力：

- 安装 `mihomo` 内核。
- 安装 `yq`、Web UI、订阅资源。
- 可通过 `clashctl` 管理启动、停止、状态、日志、订阅、面板、密钥等功能。
- 支持 bash、zsh、fish shell 集成。
- 可选支持 TUN 模式。

## 1. 增加系统识别

当前脚本主要按 Linux 环境假设运行，需要增加 OS 判断。

建议新增公共变量：

```bash
CLASHCTL_OS="$(uname -s)"
CLASHCTL_ARCH="$(uname -m)"
```

需要识别：

- `Linux`
- `Darwin`

相关文件：

- `scripts/preflight.sh`
- `scripts/lib/common.sh`
- `scripts/lib/service.sh`

## 2. 适配 macOS 二进制下载

当前 `download_zip()` 使用 Linux 下载地址。

macOS 需要按 `Darwin + arch` 选择对应包。

### mihomo

需要支持：

- Intel Mac: `mihomo-darwin-amd64`
- Apple Silicon: `mihomo-darwin-arm64`

### yq

需要支持：

- Intel Mac: `yq_darwin_amd64.tar.gz`
- Apple Silicon: `yq_darwin_arm64.tar.gz`

### subconverter

优先继续使用 `subconverter` 的 macOS 构建。

需要支持：

- Intel Mac: `subconverter_darwin64.tar.gz`
- Apple Silicon: 如果上游没有稳定 arm64 包，需要：
  - 使用 x86_64 包配合 Rosetta。
  - 或禁用本地订阅转换。
  - 或改为接入其他订阅转换方案。

相关文件：

- `scripts/preflight.sh`

## 3. 替换 Linux 专用命令

当前部分命令只适用于 Linux，macOS 需要替换。

| 当前用法 | Linux 命令 | macOS 替代 |
|---|---|---|
| 服务识别 | `/proc/1/exe`、`/proc/1/cgroup` | `uname -s`，macOS 固定走 `launchd` 或 `nohup` |
| CPU 特性 | `/proc/cpuinfo` | macOS 不需要 x86-64-v2/v3 判断，直接选 darwin 包 |
| 端口检测 | `ss` / `netstat -tunlp` | `lsof -nP -iTCP -iUDP` 或 `netstat -an` |
| 本机 IP | `ip route` / `hostname -I` | `route get 1.1.1.1` + `ipconfig getifaddr` |
| TUN 状态 | `ip link show` | `ifconfig` |
| 随机端口 | `shuf` | `jot -r 1 1024 65535` 或 bash `$RANDOM` |
| sed 原地修改 | GNU `sed -i` | BSD `sed -i ''` |

相关文件：

- `scripts/lib/common.sh`
- `scripts/lib/config.sh`
- `scripts/lib/service.sh`
- `scripts/preflight.sh`

## 4. 增加 launchd 服务支持

macOS 不使用 systemd/openrc/runit/sysvinit，需要新增 `launchd`。

### 新增模板

新增文件：

- `scripts/init/launchd.plist`

建议模板内容包含：

- `Label`
- `ProgramArguments`
- `WorkingDirectory`
- `StandardOutPath`
- `StandardErrorPath`
- `RunAtLoad`
- `KeepAlive`

### 用户级服务

普通用户安装建议写入：

```text
~/Library/LaunchAgents/com.clashctl.mihomo.plist
```

使用命令：

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.clashctl.mihomo.plist
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.clashctl.mihomo.plist
launchctl kickstart -k gui/$(id -u)/com.clashctl.mihomo
launchctl print gui/$(id -u)/com.clashctl.mihomo
```

### 系统级服务

如果要支持 TUN 或开机全局运行，可写入：

```text
/Library/LaunchDaemons/com.clashctl.mihomo.plist
```

系统级服务通常需要 root 权限。

相关文件：

- `scripts/lib/service.sh`
- `scripts/init/launchd.plist`

## 5. 改造 service.sh

需要在 `detect_service_manager()` 中加入 macOS 分支：

```bash
if [ "$(uname -s)" = "Darwin" ]; then
    service_manager="launchd"
fi
```

需要新增这些分支：

- `service_start()`
- `service_stop()`
- `service_restart()`
- `service_status()`
- `service_is_active()`
- `service_log()`
- `service_follow_log()`
- `service_read_log()`
- `install_service()`
- `uninstall_service()`

日志路径建议：

```text
$CLASH_RESOURCES_DIR/mihomo.log
```

或：

```text
~/Library/Logs/clashctl/mihomo.log
```

## 6. 适配 shell rc 写入

当前 bash、zsh、fish 都已有基础支持。

macOS 需要注意：

- 默认 shell 通常是 zsh。
- `~/.bashrc` 不一定存在。
- zsh 交互环境通常读 `~/.zshrc`。
- fish 继续写入 `~/.config/fish/conf.d/clashctl.fish`。

建议保持现有逻辑，只修复 macOS 上 `sed -i` 的兼容问题。

相关文件：

- `scripts/preflight.sh`

## 7. 适配端口检测

当前 `_is_port_used()` 依赖：

```bash
ss -tunlp
netstat -tunlp
```

macOS 建议改为：

```bash
lsof -nP -iTCP:"$1" -iUDP:"$1" 2>/dev/null | grep -q .
```

或：

```bash
netstat -an | grep -q "[.:]$1 "
```

相关文件：

- `scripts/lib/common.sh`

## 8. 适配本机 IP 获取

当前 `_get_local_ip()` 使用 Linux 命令。

macOS 可改为：

```bash
iface=$(route get 1.1.1.1 2>/dev/null | awk '/interface:/{print $2}')
ipconfig getifaddr "$iface"
```

相关文件：

- `scripts/lib/common.sh`

## 9. 适配随机端口生成

当前 `_get_random_port()` 使用 `shuf`。

macOS 默认没有 `shuf`。

可替换为：

```bash
jot -r 1 1024 65535
```

或者用 bash：

```bash
echo $((RANDOM % 64512 + 1024))
```

相关文件：

- `scripts/lib/common.sh`

## 10. 适配 TUN 模式

当前 `tunstatus()` 使用：

```bash
ip link show
```

macOS 应改为：

```bash
ifconfig | grep -q "$device"
```

注意：

- macOS TUN 通常需要更高权限。
- `launchd` 用户级服务可能无法正常启用 TUN。
- TUN 模式建议走系统级 LaunchDaemon 或提示用户使用 sudo。

相关文件：

- `scripts/lib/config.sh`
- `scripts/cmd/tun.sh`
- `scripts/lib/service.sh`

## 11. 适配 sed

当前多处使用：

```bash
sed -i
```

macOS BSD sed 需要：

```bash
sed -i ''
```

建议封装公共函数：

```bash
_sed_inplace() {
    if [ "$(uname -s)" = "Darwin" ]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}
```

然后替换项目中的原地修改调用。

相关文件：

- `scripts/lib/common.sh`
- `scripts/lib/service.sh`
- `scripts/preflight.sh`

## 12. 调整依赖检查

当前 `valid_required()` 要求：

- `xz`
- `pgrep`
- `pkill`
- `curl`
- `tar`
- `unzip`
- `gzip`
- `shuf`
- `ss/netstat`
- `ip/hostname`

macOS 应调整为：

- `pgrep`
- `pkill`
- `curl`
- `tar`
- `unzip`
- `gzip`
- `lsof` 或 `netstat`
- `route`
- `ipconfig`
- `ifconfig`
- `jot` 或移除对 `jot` 的依赖

相关文件：

- `scripts/preflight.sh`

## 13. 卸载逻辑

`uninstall_service()` 需要支持：

- 停止 launchd 服务。
- 卸载 launchd plist。
- 删除日志。
- 删除 shell rc 注入。

用户级服务路径：

```text
~/Library/LaunchAgents/com.clashctl.mihomo.plist
```

系统级服务路径：

```text
/Library/LaunchDaemons/com.clashctl.mihomo.plist
```

相关文件：

- `scripts/lib/service.sh`
- `uninstall.sh`

## 14. 安装路径

当前默认：

```bash
CLASHCTL_HOME=~/clashctl
```

macOS 可以继续使用该路径。

可选更符合 macOS 习惯的路径：

```text
~/.local/share/clashctl
```

建议先保持原路径，减少改动范围。

相关文件：

- `.env.install`

## 15. 命令兼容性测试

macOS 迁移后至少验证：

- `bash install.sh`
- `clashctl help`
- `clashctl status`
- `clashon`
- `clashoff`
- `clashlog`
- `clashui`
- `clashsecret`
- `clashsub add`
- `clashsub update`
- `bash uninstall.sh`

shell 验证：

- zsh
- bash
- fish

架构验证：

- Intel Mac
- Apple Silicon Mac

## 16. 推荐实施顺序

1. 增加 OS/arch 判断。
2. 改造依赖下载地址。
3. 封装 macOS/Linux 通用命令函数。
4. 增加 `launchd` 服务模板。
5. 在 `service.sh` 中加入 `launchd` 分支。
6. 修复 `sed -i`、端口检测、本机 IP、随机端口。
7. 适配 TUN 状态检测。
8. 调整卸载逻辑。
9. 在 macOS Intel 和 Apple Silicon 上测试。
10. 更新 README 安装说明。

## 17. 最小可行版本

如果先做最小 macOS 支持，可以暂时只实现：

- `mihomo` macOS 二进制下载。
- `yq` macOS 二进制下载。
- `nohup` 模式启动。
- bash/zsh/fish 命令可用。
- 禁用或延后 TUN。
- 禁用或延后 subconverter 的 macOS arm64 适配。

这样可以先让普通代理功能跑起来，再逐步补齐 launchd 和 TUN。
