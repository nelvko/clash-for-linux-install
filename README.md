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

一条命令安装（有 `Git` 时克隆仓库，没有则下载源码压缩包）：

```bash
curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/nelvko/clash-for-linux-install/master/install.sh | bash
```

默认安装到 `~/.clashctl`，装完**重开终端**加载命令。订阅链接可在安装时输入，也可跳过——跳过时只装组件和命令，不启动代理、不设自启。

### 安装选项

| 环境变量 | 作用 | 默认 |
|---|---|---|
| `CLASHCTL_HOME` | 安装目录 | `~/.clashctl` |
| `CLASHCTL_UPDATE_BRANCH` | 安装/更新所跟踪的分支 | `master` |
| `GH_PROXY` | GitHub 加速前缀；不设或设为空串则直连 | 不设（直连） |

管道安装时，变量必须写在右侧 `bash` 之前，例如安装 `iu` 分支：

```bash
curl -fsSL https://raw.githubusercontent.com/nelvko/clash-for-linux-install/iu/install.sh | CLASHCTL_UPDATE_BRANCH=iu bash
```

写在 `curl` 前面的变量不会传给右侧 `bash`。若加速前缀失效，可换其他[可用镜像](https://ghproxy.link/)。

没有订阅？[click me](https://次元.net/auth/register?code=oUbI)

## 🎯 Quick Start

安装完成后，即可使用 `clashctl` 管理代理：

```bash
clashctl on              # 开启代理
clashctl off             # 关闭代理
clashctl status          # 查看内核状态
clashctl ui              # 查看 Web 面板地址

clashctl sub add <url>   # 添加并启用订阅
clashctl sub update      # 更新订阅
clashctl node            # 切换节点

clashctl update          # 更新脚本（保留订阅与自定义配置）

clashctl -h              # 查看全部命令
```

## 🧹 Uninstall

在安装目录下执行以下命令即可干净卸载（清除内核、配置及服务）：

```bash
bash ~/.clashctl/uninstall.sh
```

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
