# `install-update` 发布验收

这份清单用于决定何时将安装流程合入 `master`。仓库更名、命令更名和安装目录再次更名不属于本次发布。

## 合并前试用

远端 `master` 仍是旧安装器；此分支的试用命令必须同时选择脚本和源码分支：

```bash
curl -fsSL https://raw.githubusercontent.com/nelvko/clash-for-linux-install/install-update/install.sh | CLASHCTL_UPDATE_BRANCH=install-update bash -s -- --gh-proxy https://gh-proxy.org
```

旧目录搬到新默认目录时，在管道右侧的 `bash` 前设置 `CLASHCTL_UPDATE_BRANCH=install-update`，并在 `bash -s --` 后加 `--install-dir "$HOME/.clashctl"`；原路径升级时改为 `--install-dir /absolute/path/to/clashctl`。目录参数优先于已导出的 `CLASHCTL_HOME`。正式合并后，README 中的 `master` 命令才可使用。合并前的试用命令以本文件为准；功能与命令说明参考 README 和命令帮助。当前 Wiki 仍描述旧版行为。

## 用户可见变化

| 项目 | 旧版 `master` | `install-update` |
| --- | --- | --- |
| 默认安装目录 | `~/clashctl` | `~/.clashctl`；`--install-dir` 优先于 `CLASHCTL_HOME` |
| 配置与订阅 | `resources/` | `data/`；首次安装识别并迁移旧目录 |
| 安装参数 | `.env.install` | `--install-dir`、`CLASHCTL_HOME`、`CLASHCTL_UPDATE_BRANCH`、`--gh-proxy` |
| 内核选择 | 安装时选择 | 新安装可用 `--kernel` 选择；已有安装须沿用原内核，直接切换会在修改前拒绝 |
| 终端与内核启停 | `off` 同时停止内核和终端代理 | `off` 仅清除当前终端代理；`stop` 停止内核 |

`on/off` 只保留 `-h/--help`，移除旧版 `-s/--service-only` 和 `-e/--env-only` 选项。仅启停内核改用 `start/stop`；开启或关闭当前终端代理直接使用 `on/off`，其中 `on` 会在内核未运行时自动启动。旧版无参数 `off` 同时停止内核和清除代理的用法，改为先 `stop` 再 `off`。新版 `off` 的默认行为已在 README 中说明。
已有 `iu` 安装的 `.env` 若写着 `CLASHCTL_UPDATE_BRANCH=iu`，再次运行安装器仍跟踪 `iu`；想转向正式版需显式把该值改为 `master`。发布说明必须写明这一步。

## 与 `iu` 分支的取舍

`iu` 与 `install-update` 都从旧 `master` 分出，后者没有包含前者的提交。`iu` 的订阅 URL/密钥保护、订阅操作失败回滚和运行配置原子写入都值得单独移植；这些问题在当前 `master` 中已存在，故不将整个 `iu` 并入本次安装流程发布。两条分支的 `data/` 布局和订阅名称模型基本相同；命令行为的兼容断点集中在 `on/off`。

## 合并门槛

- [x] 提交已验证的迁移修复与测试。
- [x] 冻结功能范围；后续只处理兼容问题和验收中发现的阻断缺陷。
- [x] 候选代码 `836e9c3` 推送后，[Shell tests](https://github.com/nelvko/clash-for-linux-install/actions/runs/37882411799) 通过 Bash 语法、完整回归和普通用户迁移测试。
- [x] 核对 `iu` 分支独有的行为和测试；安全与事务修复另行排期，`on/off` 在本次发布前决定。
- [x] 最终代码候选在隔离 Ubuntu 24.04 / systemd 255 环境中，使用实际旧 `master` 安装器验证原路径升级、默认目录搬迁和自定义路径迁移；核对订阅、当前配置、密钥、服务状态、真实代理请求与备份。
- [x] 使用真实 mihomo/yq 验证普通用户 `nohup` 与 root `systemd` 安装；覆盖无订阅、有效订阅、下载失败、初始化失败后的重试及迁移回退。环境与限制见[验收记录](acceptance-install-update-20261009.md)。
- [x] 明确 `off` 只清除终端代理、`start/stop` 启停内核，并移除 `on/off` 的旧选项，更新文档与命令帮助。
- [x] 候选版已推送至 `install-update`，提供同时指定脚本分支与 `CLASHCTL_UPDATE_BRANCH` 的试用命令，并发布 [Wiki 候选说明](https://github.com/nelvko/clash-for-linux-install/wiki/Install-Update-Preview)。
- [ ] 收集外部用户试用反馈，处理发现的阻断问题；尚未收到试用结果时不将此项记为完成。
- [ ] 正式合并时切换 Wiki 默认说明中的 `off` 行为、安装路径和 FAQ；候选期保留旧 `master` 文档并链接候选说明。README 已按合并后的 `master` 写法准备。
- [x] 保存旧 `master` 基准 `b2d4cbd6e4bed4ee59e1a4495f931f6e5d5498bc` 的完整 Git bundle，并验证备份可读；[回退步骤](rollback-install-update.md)已通过真实 systemd/nohup 内核与 HTTP 请求验证。

验收项完成后再合入 `master`。合并本身不会更改已有安装；新安装和主动运行新版安装器的用户会进入新流程。

## 已完成的手动验证

- 2026-09-26：Orb Linux 普通用户在隔离 `HOME` 下从本地候选源码安装，真实下载 mihomo 与 yq；无订阅时内核未启动，随后卸载成功，临时安装目录已清理。
- 2026-09-26：Orb Linux 将按旧版 `master` 布局构造的三份独立目录迁移：自动搬迁 `~/clashctl`、导出默认路径原地升级、自定义路径原地升级。实际下载并校验 mihomo 与 yq；核对旧目录备份、订阅文件及路径、缓存、日志和 `clashctl sub list`。旧配置为空，未覆盖服务启动或代理流量。
- 2026-09-26：Orb Linux 根用户全量回归 15/15；普通用户迁移回归 2/2。
- 2026-09-26：Orb Linux 以独立 UID 运行实际旧 `master` 安装器，添加有效本地订阅并启动 `nohup` 内核；迁移到 `~/.clashctl` 后，核对备份、当前订阅与路径、Shell 引导、单个新内核进程，以及迁移前后的本地 HTTP 代理请求。用户原有的旧内核 PID 保持不变。旧版内核继承订阅锁的情形已修复并加入回归；若旧脚本带组写权限，安装器现在明确中止而不另建新目录，核实后可手动收紧权限再重试。
- 2026-09-26：增加迁移期间收到 TERM 的回归：分别在旧 nohup 内核停止后的数据复制阶段，以及 Bash/Fish 引导写入后中断；核对旧服务、目录、订阅锁和 Shell 配置恢复。Orb Linux 根用户全量回归 15/15，普通用户迁移回归 2/2。
- 2026-10-09：修复 Git 更新落盘失败后的恢复、安装/迁移操作锁取得过晚，以及已有安装直接切换内核的问题。Git 回归覆盖部分写入、HEAD 切换后失败、TERM 中断、未跟踪文件冲突和恢复失败保留现场；操作锁回归覆盖首装、重试和旧版迁移，确认争用时旧 nohup 内核 PID 不变。根用户全量回归 15/15，普通用户迁移回归 2/2；Bash/Fish 语法检查通过。此阶段使用隔离 fixture 和本地下载源，真实内核验收见下一条记录。
- 2026-10-09：完成[最终代码候选验收](acceptance-install-update-20261009.md)。真实 systemd 验收发现带订阅安装未设置自启，已在订阅启用成功后补上自启，并加入回归；无订阅安装仍不启动、不设自启。本轮全量回归 15/15、普通用户迁移回归 2/2 和 Bash/Fish 语法检查通过。
