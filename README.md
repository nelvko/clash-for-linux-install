<h1 align="center">
  clashctl
</h1>

<p align="center">mihomo / clash 一键部署与管理工具</p>
<p align="center">
 <a href="https://www.star-history.com/nelvko/clash-for-linux-install">
  <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/badge?repo=nelvko/clash-for-linux-install&type=rank&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/badge?repo=nelvko/clash-for-linux-install&type=rank" />
   <img alt="Star History Rank" src="https://api.star-history.com/badge?repo=nelvko/clash-for-linux-install&type=rank" />
  </picture>
 </a>
</p>

<p align="center">
  <img alt="GitHub License" src="https://img.shields.io/github/license/nelvko/clash-for-linux-install" />
  <img alt="GitHub top language" src="https://img.shields.io/github/languages/top/nelvko/clash-for-linux-install" />
  <img alt="GitHub Repo stars" src="https://img.shields.io/github/stars/nelvko/clash-for-linux-install" />
  <a href="https://deepwiki.com/nelvko/clash-for-linux-install"><img src="https://deepwiki.com/badge.svg" alt="Ask DeepWiki"></a>
</p>

## 📸 Preview

![preview](preview.png)

## ✨ Features

- **开箱即用**：一条命令部署 `mihomo` / `clash` 内核、Web 面板及运行依赖。有 `Git` 时克隆仓库，没有则下载源码压缩包。
- **广泛兼容**：支持 `root` / 普通用户，适配主流 `Linux` 发行版、容器环境，以及 `systemd` / `OpenRC` / `runit` / `SysVinit` / `nohup`。
- **统一管理**：通过 `clashctl` 管理代理启停、状态查看、日志追踪、Web 面板、TUN 模式、访问密钥与内核升级等。
- **订阅管理**：支持多订阅源配置、一键新增、切换、更新等，并集成 [subconverter](https://github.com/tindy2013/subconverter) 实现订阅格式转换。
- **配置可控**：主配置与 Mixin 分层合并；`clashctl update` 更新 clashctl 时不影响你的订阅与自定义配置。

## 🚀 Installation

```bash
curl -fsSL https://raw.githubusercontent.com/nelvko/clash-for-linux-install/master/install.sh | bash -s -- --gh-proxy https://gh-proxy.org
```

- 上述命令使用了[加速下载代理](https://gh-proxy.org/),若失效请更换其他[可用地址](https://ghproxy.link/)。
- 没有订阅？[click me](https://次元.net/auth/register?code=oUbI)

在 Linux 中测试本地源码（包括未提交的修改），只需增加 `--local`：

```bash
bash install.sh --local
```

源码取自 `install.sh` 所在目录，复制后安装到 `~/.clashctl`；可通过 `CLASHCTL_HOME` 指定其他安装目录。此参数只跳过源码下载，运行依赖仍按需下载；`clashctl update` 仍更新到配置的远端分支（默认 `master`）。

再次运行新版安装脚本时，已验证的安装目录会自动更新并继续初始化；上次安装中断则直接续装。`--local` 可刷新已有的压缩包安装，Git 安装仍从已配置的远端分支更新。检测到可验证的旧版安装时，会迁移配置和订阅，并将旧目录保留为带 `.bak` 后缀的备份；迁移失败会恢复旧目录。无法确认归属的目录不会被覆盖。

## 🎯 Quick Start

安装完成后，即可使用 `clashctl` 管理代理：

```bash
clashctl on              # 启用当前终端代理，内核未运行时自动启动
clashctl off             # 关闭当前终端代理，内核继续运行

clashctl start           # 仅启动内核
clashctl stop            # 仅停止内核
clashctl status          # 查看代理状态

clashctl ui              # 查看 Web 面板地址
clashctl sub             # 订阅管理
clashctl node            # 节点管理

clashctl update          # 更新 clashctl
```

更多命令用法与示例请参阅：[Usage](https://github.com/nelvko/clash-for-linux-install/wiki)

## 🧹 Uninstall

卸载会停止本次安装的内核，并删除服务、Shell 引导及整个安装目录，**包括订阅、自定义配置、内核和日志**。如需保留配置，请提前将安装目录中的 `.env` 和 `data/` 备份到其他位置；备份可能包含订阅凭据和访问密钥，请妥善保管。

```bash
clashctl off
bash ~/.clashctl/uninstall.sh
```

也可在源码目录执行 `bash uninstall.sh`：脚本优先识别自身所在的安装目录，否则使用 `CLASHCTL_HOME` 指定的目录，未设置时查找 `~/.clashctl`。自定义安装可执行 `CLASHCTL_HOME=/path/to/clashctl bash uninstall.sh`，或直接运行该安装目录下的脚本。确认提示会显示实际卸载路径；路径或安装标记无效时会停止。

无人值守可加 `--yes` 跳过确认，仍会检查安装归属和内核停止结果。普通用户安装应由原用户卸载，需要停止 TUN 特权进程时会单独请求 `sudo`。

卸载后请关闭使用过 clashctl 的终端并重新打开。卸载脚本无法清除父 Shell 的代理变量，因此建议先执行 `clashctl off`；脚本报告的残留文件可检查后手动清理。若 `.env` 意外丢失，脚本会保留目录，请恢复备份后重试。

## 📖 Documentation


- [FAQ](https://github.com/nelvko/clash-for-linux-install/wiki/FAQ) — 常见问题。

## 💖 Support

### <img alt="Maru Code" src="https://cdn.nodeimage.com/i/hc6anADTcLP0P2CTOoqUMkKcHER4KeYY.webp" width="20" height="20"> [Maru Code —— 稳定可靠的 API 中转服务](https://api.muteki.site/register?aff=NELVKO&promo=nelvko)

- ⚡ 模型能力完整，`Claude` 系列满血可用。
- 📊 计费倍率透明公开，成本更容易预估。
- 🔑 自营号池保障可用性，日常调用更稳定。
- 🎁 新用户注册赠送 `$2` 额度：👉[立即注册](https://api.muteki.site/register?aff=NELVKO&promo=nelvko)

## ⭐ Star History

## Star History

<a href="https://www.star-history.com/?repos=nelvko%2Fclash-for-linux-install&type=timeline&legend=bottom-right">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=nelvko/clash-for-linux-install&type=date&theme=dark&legend=bottom-right" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=nelvko/clash-for-linux-install&type=date&legend=bottom-right" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=nelvko/clash-for-linux-install&type=date&legend=bottom-right" />
 </picture>
</a>

## ⚠️ Disclaimer

- 编写本项目主要目的为学习和研究 `Shell` 编程，不得将本项目中任何内容用于违反国家/地区/组织等的法律法规或相关规定的其他用途。
- 本项目保留随时对免责声明进行补充或更改的权利，直接或间接使用本项目内容的个人或组织，视为接受本项目的特别声明。
