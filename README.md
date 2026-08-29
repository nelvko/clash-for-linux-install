<h1 align="center">
  clashctl
</h1>

<p align="center">mihomo / clash 一键部署与管理工具</p>

<p align="center">
  <img alt="GitHub License" src="https://img.shields.io/github/license/nelvko/clash-for-linux-install" />
  <img alt="GitHub top language" src="https://img.shields.io/github/languages/top/nelvko/clash-for-linux-install" />
  <img alt="GitHub Repo stars" src="https://img.shields.io/github/stars/nelvko/clash-for-linux-install" />
  <a href="https://deepwiki.com/nelvko/clash-for-linux-install"><img src="https://deepwiki.com/badge.svg" alt="Ask DeepWiki"></a>
</p>

## 📸 Preview

![preview](preview.png)

## ✨ Features

- **开箱即用**：一键部署 `mihomo` / `clash` 内核、Web 面板及运行依赖。
- **广泛兼容**：支持 `root` / 普通用户，适配主流 `Linux` 发行版、容器环境及 `systemd` / `OpenRC` 等 `init` 系统。
- **统一管理**：通过 `clashctl` 管理代理启停、状态查看、日志追踪、Web 面板、TUN 模式、访问密钥与内核升级等。
- **订阅管理**：支持多订阅源配置、一键新增、切换、更新等，并集成 [subconverter](https://github.com/tindy2013/subconverter) 实现订阅格式转换。

## 🚀 Installation

安装脚本会先完整下载到安全的临时文件，确认非空后再交给 Bash 执行：

```bash
(
  installer=$(mktemp) || exit 1
  trap 'rm -f "$installer"' EXIT

  curl -fsSL -o "$installer" \
    https://gh-proxy.org/https://raw.githubusercontent.com/nelvko/clash-for-linux-install/master/install.sh || exit 1
  [ -s "$installer" ] || {
    printf '%s\n' '安装脚本为空，已中止' >&2
    exit 1
  }

  bash "$installer"
)
```

默认安装会交互询问可选的初始订阅，并在发现同名服务时要求确认。用于自动化时，将上面最后一行替换为所需命令：

```bash
bash "$installer" --home /opt/clashctl --branch dev mihomo
bash "$installer" --non-interactive
bash "$installer" --non-interactive --subscription-file /run/secrets/clash-subscription
bash "$installer" --non-interactive --take-over-service
```

安装分两步：`install.sh` 只落位 clashctl 本体（脚本与 Shell 集成），随后自动执行 `clashctl install` 完成内核、组件、服务与初始订阅——失败后直接重跑 `clashctl install` 即可补全。检测到旧版安装（`~/clashctl` 布局）时会询问是否自动迁移订阅与配置，旧目录整体保留为 `.bak`。

- `--non-interactive` 禁用交互并在未提供订阅时跳过订阅；它不会授权覆盖已有服务。
- `--subscription-file` 从当前用户所有、权限为 `0400` 或 `0600` 的单行普通文件读取初始订阅 URL；文件路径可进入命令行，URL 本身不会进入安装器参数、输出或子进程环境。
- `--take-over-service` 明确授权备份并接管同名服务；若仅检测到定义缺失的残留自启状态，则授权记录并保留该状态后继续。systemd 服务定义缺失但服务仍在运行时始终拒绝安装。
- 安装目录会写入权限为 `0600` 的 `.clashctl-installation` 身份标记；非空目录缺少有效标记时，安装器不会执行其中脚本。
- 迁移可信的旧版目录需显式添加 `--allow-legacy-layout`；目录归属、权限或脚本结构校验失败时仍会拒绝接管。
- 接管同名服务时会保存定义、运行状态及各服务管理器的精确自启链接；恢复时若发现管理员在安装后修改过相关链接，会停止并保留快照与备份。
- 可追加 `mihomo|clash` 选择内核（`clashctl install <内核>` 可安装或切换，多内核并存于 `bin/<内核>/` 与同名服务单元）；交互安装会隐藏读取初始订阅，自动化安装应使用 `--subscription-file`，避免 URL 留在 Shell 历史中。完整选项可将最后一行改为 `bash "$installer" --help` 查看。
- 面板与订阅转换组件（zashboard/subconverter）在首次使用 `clashctl ui` / `clashctl sub add` 时按需下载，无需预装。
- 上述下载地址使用了[加速前缀](https://gh-proxy.org/)，如失效请更换其他[可用链接](https://ghproxy.link/)；依赖下载源可通过 `--gh-proxy <地址>` 旗标或 `GH_PROXY` 环境变量配置（旗标优先，置空为直连，安装后会持久化到 `.env`）。

- 没有订阅？[click me](https://次元.net/auth/register?code=oUbI)

## 🎯 Quick Start

安装完成后，即可使用 `clashctl` 管理代理：

```bash
clashctl on              # 开启代理
clashctl off             # 关闭代理
clashctl status          # 查看内核状态
clashctl ui              # 查看 Web 面板地址

clashctl sub add <url>   # 添加订阅
clashctl sub update      # 更新订阅
clashctl node            # 切换节点

clashctl -h              # 查看全部命令
```

## 🔄 Update

更新无需卸载重装，订阅、mixin、密钥与内核二进制全部保留：

```bash
clashctl update                # 增量更新（git fetch，通常只拉几 KB）
clashctl update --check        # 检查版本（本地 git 比对，不调 GitHub API）
clashctl update --branch dev   # 切换跟进分支（默认 master）
clashctl update --rollback     # 回退到上一版本
```

- 安装目录 `~/.clashctl` 即 git 仓库：用户配置全部在 `data/`，更新永不触碰；本地修改过跟踪文件时更新会被拒绝并列出清单。
- 进阶：可直接 `cd ~/.clashctl && git log` 查看版本历史；不建议裸 `git pull`（会跳过服务配置刷新）。
- 长期跟进某分支、更换镜像或 SSH 源，编辑 `~/.clashctl/.env` 的 `CLASHCTL_UPDATE_BRANCH` / `CLASHCTL_UPDATE_GIT_URL`。
- 升级代理内核请使用 `clashctl upgrade`，与脚本更新相互独立。

## 🧹 Uninstall

执行以下命令会先展示删除范围并要求确认；如安装时接管过同名服务，卸载会恢复其定义、自启和运行状态：

```bash
bash ~/.clashctl/uninstall.sh
```

- 自定义过安装路径的用户请相应调整。
- 自动化卸载需显式确认：`bash ~/.clashctl/uninstall.sh --yes`。
- 无身份标记的可信旧版目录需追加 `--allow-legacy-layout`，新安装不需要该选项。
- 服务恢复失败时卸载会停止，安装目录与恢复备份会保留，不会报告成功。

## 📖 Documentation

- [Usage](https://github.com/nelvko/clash-for-linux-install/wiki) — 命令用法与示例。
- [FAQ](https://github.com/nelvko/clash-for-linux-install/wiki/FAQ) — 常见问题。

## 💖 Support

### <img alt="Maru Code" src="https://cdn.nodeimage.com/i/hc6anADTcLP0P2CTOoqUMkKcHER4KeYY.webp" width="20" height="20"> [Maru Code —— 稳定可靠的 API 中转服务](https://api.muteki.site/register?aff=NELVKO&promo=nelvko)

- ⚡ 模型能力完整，`Claude` 系列满血可用。
- 📊 计费倍率透明公开，成本更容易预估。
- 🔑 自营号池保障可用性，日常调用更稳定。
- 🎁 新用户注册赠送 `$2` 额度：👉[立即注册](https://api.muteki.site/register?aff=NELVKO&promo=nelvko)

## ⭐ Star History

<a href="https://star-history.dera.page/#nelvko/clash-for-linux-install&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://star-history.dera.page/svg?repos=nelvko/clash-for-linux-install&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://star-history.dera.page/svg?repos=nelvko/clash-for-linux-install&type=Date" />
   <img alt="Star History Chart" src="https://star-history.dera.page/svg?repos=nelvko/clash-for-linux-install&type=Date" />
 </picture>
</a>

## ⚠️ Disclaimer

- 编写本项目主要目的为学习和研究 `Shell` 编程，不得将本项目中任何内容用于违反国家/地区/组织等的法律法规或相关规定的其他用途。
- 本项目保留随时对免责声明进行补充或更改的权利，直接或间接使用本项目内容的个人或组织，视为接受本项目的特别声明。
