# 安装/更新候选版验收记录：2026-10-09

本节真实内核验收使用 `install-update` 候选代码 `836e9c35c3fe73e69921c022ef150bbf857788b4`，包含 Git 失败恢复、安装/迁移提前加锁、已有安装禁止切换内核，以及 `off` 不停内核、移除 `on/off` 旧选项的修改。旧版本由实际 `master` 提交 `b2d4cbd6e4bed4ee59e1a4495f931f6e5d5498bc` 的安装器建立。后续工作区修改的本地验证单独记录于下文。

## 环境

- 隔离的 Ubuntu 24.04 Docker 容器，systemd 255 为 PID 1；使用真实 `systemctl` 注册、启动、停止和卸载服务。
- 同一容器中另建普通用户，使用真实 `nohup` 运行内核。每个用例使用独立 HOME 和安装目录，按序清理服务。
- 实际下载 mihomo v1.19.32（amd64 v3）与 yq v4.54.1。直连 GitHub 下载超时后，安装器保留未完成状态；使用 `--gh-proxy https://gh-proxy.org` 重试成功。后续用例固定版本并复用已下载的真实制品。
- 旧安装实际下载并使用 subconverter v0.9.9 和 zashboard v3.20.0。新版无订阅安装只要求内核与 yq。
- 本地 HTTP 服务器提供有效原生订阅和响应正文；通过内核 HTTP 代理请求核对响应。订阅中使用 DIRECT 策略验证代理链路，没有测试外部机场节点或 Tun。
- Git 集成验收使用本地 Git 源替代网络源码地址，执行真实 clone/fetch/checkout/reset；仅失败用例注入一次 checkout 部分写入。

## 结果

| 用例 | root/systemd | 普通用户/nohup |
| --- | --- | --- |
| 新安装无订阅：准备组件，不启动、不设自启 | 通过 | 通过 |
| 添加有效订阅，真实代理请求 | 通过 | 通过 |
| on/off/start/stop，off 保持内核运行 | 通过 | 通过 |
| 重跑安装器，配置与密钥不变 | 通过 | 通过 |
| 下载失败保留未初始化状态，随后重试 | 通过 | 通过 |
| Shell 初始化失败保留未完成状态，随后重试 | 通过 | 通过 |
| 安装器启用订阅后启动内核并设置自启 | 通过 | 通过（nohup 无系统自启） |
| 自启设置失败后，续装恢复已运行内核的自启 | 通过 | 通过（隔离回归注入） |
| 实际旧 master 原路径升级 | 通过 | 通过 |
| 实际旧 master 默认目录搬迁 | 通过 | 通过 |
| 实际旧 master 自定义路径迁移 | 通过 | 通过 |
| 迁移初始化失败恢复旧目录、Shell 与服务 | 通过 | 通过 |
| 成功迁移后从备份手动恢复，真实代理请求 | 通过 | 通过 |
| 卸载停止内核并移除安装和对应服务 | 通过 | 通过 |

迁移核对主配置和 Mixin 的 SHA-256（包括访问密钥）、订阅元数据和文件、provider 数据、旧备份以及 Shell 中的目标路径。systemd 核对服务单元中的内核与运行配置路径、运行状态和启用状态。用例结束后无遗留运行的 mihomo 进程。

Git 安装与更新在真实 systemd 内核运行时通过：成功更新、部分 checkout 失败后恢复、再次更新成功。`.env`、主配置、Mixin、订阅元数据、mihomo 和 yq 的 SHA-256 不变，更新期间内核 MainPID 不变，代理请求成功。

## 验收发现与修复

带订阅安装使用订阅生效流程启动服务，未经过 `clashstart` 的自启步骤，导致内核运行但 systemd 自启未设置。安装器现于已有主配置且内核运行时确认自启设置；无配置安装保持不启动、不设自启。回归 fixture 改为模拟真实订阅启动路径，分别检查内核启动和自启设置；自启失败后即使内核已运行，续装也会恢复自启。

修改后 root 全量回归 15/15，普通用户迁移回归 2/2，45 个 Bash 文件与 Fish 包装语法检查通过。

候选代码已作为 `836e9c35c3fe73e69921c022ef150bbf857788b4` 推送至 `install-update`，[GitHub Actions](https://github.com/nelvko/clash-for-linux-install/actions/runs/37882411799) 的语法、全量回归和普通用户迁移检查通过。[Wiki 候选说明](https://github.com/nelvko/clash-for-linux-install/wiki/Install-Update-Preview)已发布，旧 `master` 的默认说明保留。

## 2026-10-10 本地补充验证

以下本地验证针对 `2f2e14c` 之后的收尾修改。修改已作为最终代码候选 `13169dd72dba5ef51ad71f8390a3e8d2030aa2d7` 提交并推送；[GitHub Actions](https://github.com/nelvko/clash-for-linux-install/actions/runs/38017703053) 的 Bash 语法、全量回归和普通用户迁移检查均通过。

- 本地收尾审查：root 全量回归 15/15，普通用户 `install-update`、`install-legacy-nohup` 与 `uninstall-scope` 回归 3/3 通过；Bash/Fish 语法检查及改动涉及的生产脚本 ShellCheck 错误级检查通过。
- 审查后复现 `--local` 更新部分写入失败、回滚也失败时，外层退出清理删除 `previous.tar` 的问题。新增安装入口回归在修复前失败；修复后 root 与普通用户 `install-update` 回归各 1/1 通过。测试确认恢复目录、原程序与清单备份均保留，备份可实际恢复，用户配置和 `.env` 不变；更新成功或回滚成功时仍清理临时目录。
- 备份修复涉及的安装脚本和测试脚本 Bash 语法、ShellCheck 错误级检查及 `git diff --check` 通过。上述验证使用隔离 fixture 与故障注入，没有重新执行真实 systemd 或外部代理节点验收。
- 命令示例与文档收尾：`command-load` 回归 1/1，通过实际 `sub add --help` 确认订阅链接占位符带引号；安装器与订阅脚本 Bash 语法及 ShellCheck 错误级检查通过。

## 尚待发布阶段完成

最终代码候选已推送并通过 CI，Wiki 候选说明中的安装参数仍需同步。旧候选的真实内核结果来自隔离 Linux/systemd 环境，不能替代所有发行版和物理机的兼容性验证。外部用户试用反馈仍待收集；正式合并时需要切换 Wiki 默认说明。此次只准备和验证候选版，没有合并 `master`。
