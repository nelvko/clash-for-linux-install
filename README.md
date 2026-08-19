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

在终端中执行以下命令即可完成安装（无需 git）：

```bash
curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/nelvko/clash-for-linux-install/master/install.sh | bash
```

- 上述命令使用了[加速前缀](https://gh-proxy.org/)，如失效请更换其他[可用链接](https://ghproxy.link/)。
- 弱网下若执行后无任何输出（下载失败静默退出），可改用落盘方式重试：
  `curl -fsSL -o /tmp/install.sh <上述链接> && bash /tmp/install.sh`
- 定制安装直接带参数/环境变量（无需配置文件）：

```bash
curl -fsSL <上述链接> | bash -s -- mihomo https://订阅URL   # 指定内核与初始订阅
curl -fsSL <上述链接> | CLASHCTL_HOME=/opt/clashctl GH_PROXY=https://ghproxy.link bash -s -- --branch dev
# 可选参数：--home 路径、--branch 分支；环境变量：GH_PROXY、CLASHCTL_DOWNLOAD_TIMEOUT、VERSION_* 依赖钉版等
```

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

执行以下命令即可干净卸载（清除内核、配置及服务）：

```bash
bash ~/.clashctl/uninstall.sh
```

- 自定义过安装路径的用户请相应调整。

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
