# 安装流程重构的回退准备

本次发布前的 `master` 基准为 `b2d4cbd6e4bed4ee59e1a4495f931f6e5d5498bc`。维护者应在发布前核对远端，并保存该提交或备份。回退仓库版本只改变后续下载的源码，已经迁移的用户需要恢复自己的目录、服务和 Shell 引导。

## 安装或更新失败

- 新安装失败：按安装器打印的命令重试。未初始化或未完成的状态标记用于识别续装，不要手动删除标记来绕过检查。
- 旧版本迁移失败：安装器会尝试恢复旧目录、服务和 Shell 配置。确认旧内核可以启动、代理可以请求、订阅与配置仍在。若提示恢复失败，保留旧目录、`.bak.*`、`.failed.*` 和 Shell 备份，按输出路径检查。
- Git 更新失败：恢复原提交、分支和工作树后可以重试；未跟踪的用户文件保留。恢复失败时，保留 `.update.*` 目录，查看其中的 `git-previous`，先恢复原版本再重试。
- 压缩包更新失败：恢复托管源码；无法恢复时保留 `.update.*` 中的 `previous.tar`。不要覆盖订阅、内核或运行数据。

## 成功迁移后恢复旧安装

以下步骤适用于从旧 `master` 迁移到新版后退回旧安装。使用安装时的同一用户；root/systemd 安装以 root 执行，普通用户/nohup 安装以该普通用户执行。

1. 记下新安装目录、迁移前的原目录和对应的 `.bak.*`。先备份新版整个安装目录，包括迁移后新增的订阅和自定义配置。这些新数据不会自动并回旧备份。需要时也保存 Bash、Zsh、Fish 配置和服务状态。
2. 使用新版卸载器停止新内核并移除新版服务、Shell 引导和目录：`bash /新版安装目录/uninstall.sh --yes`。只有确认备份完成且卸载成功后才继续。
3. 将选定的旧备份搬回**迁移前的原路径**。旧配置、订阅元数据和服务单元可能包含这个绝对路径；不要直接在 `.bak.*` 路径运行旧内核。
4. 恢复旧版的 Shell 引导和服务，再验证代理请求。

例如，在 Bash 中选择自己的实际路径后执行：

```bash
OLD_HOME="$HOME/clashctl"
OLD_BACKUP="$HOME/clashctl.bak.实际备份后缀"

test ! -e "$OLD_HOME" && test -d "$OLD_BACKUP" || exit 1
mv -- "$OLD_BACKUP" "$OLD_HOME"
export CLASHCTL_HOME="$OLD_HOME"
. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh"
```

普通用户的旧 `nohup` 安装可以执行 `clashctl on` 启动。若保存了迁移前的 Shell 配置，先核对其他新改动再恢复；否则在需要的 Bash/Zsh 配置中添加旧引导：

```bash
printf 'export CLASHCTL_HOME=%q\n. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh"\n' \
  "$OLD_HOME" >> "$HOME/.bashrc"
```

旧 root/systemd 安装的服务文件由迁移器保存在旧目录中的 `.clashctl-service.*`，随目录一起进入备份。选定与原内核和路径匹配的文件，核对 `ExecStart` 后恢复到原服务单元位置，执行 `systemctl daemon-reload`，再按迁移前的状态决定是否启用、启动服务。例如原内核为 mihomo：

```bash
find "$OLD_HOME" -maxdepth 1 -name '.clashctl-service.*' -type f -print
# 用上一步选定的实际文件替换下面路径；先核对内容。
cat "$OLD_HOME/.clashctl-service.实际后缀"
cp -p -- "$OLD_HOME/.clashctl-service.实际后缀" /etc/systemd/system/mihomo.service
systemctl daemon-reload
systemctl enable --now mihomo   # 仅当迁移前已启用且运行时执行
```

最后核对旧配置与订阅、访问密钥、服务启用状态、内核进程的实际二进制路径及 HTTP 代理请求。原先没有启用或运行的服务应保持原状态。定时任务若已改成新路径，也要恢复到旧路径。保留新版备份，直至确认恢复完整。
