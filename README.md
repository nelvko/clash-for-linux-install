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
  <a href="https://deepwiki.com/nelvko/clash-for-linux-install"><img src="https://deepwiki.com/badge.svg" alt="Ask DeepWiki" /></a>
</p>

## 📸 Preview

![preview](preview.png)

## ✨ Features

- 支持 `mihomo` / `clash` 内核，默认使用 `mihomo`，Web 面板和订阅转换器按需下载。
- 支持 `root` / 普通用户、容器环境，适配 `systemd` / `OpenRC` 等服务管理方式。
- 通过 `clashctl` 开关终端代理、启停内核、切换节点、查看日志，管理 Web 面板、TUN 模式和访问密钥。
- 支持添加、切换和更新多个订阅，非原生订阅可通过 [subconverter](https://github.com/tindy2013/subconverter) 转换；自定义配置写入 Mixin，订阅更新后仍保留。
- 支持脚本更新和旧版迁移，保留已有订阅与配置。

## 🚀 Installation

在 Linux 终端中执行：

```bash
curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/nelvko/clash-for-linux-install/master/install.sh | \
  bash -s -- --gh-proxy https://gh-proxy.org
```

- 默认安装到 `~/.clashctl`，安装时按提示输入订阅链接，也可以回车跳过。
- 安装完成后，按提示加载命令，或重新打开终端。
- 上述命令使用了 [GitHub 加速前缀](https://gh-proxy.org/)，失效时可更换其他 [可用链接](https://ghproxy.link/)。脚本地址和 `--gh-proxy` 中的前缀需一并替换。
- 没有订阅？[获取订阅](https://次元.net/auth/register?code=oUbI)

<details>
<summary>从源码安装</summary>

```bash
git clone --branch master --depth 1 https://gh-proxy.org/https://github.com/nelvko/clash-for-linux-install.git
cd clash-for-linux-install
bash install.sh --local --gh-proxy https://gh-proxy.org
```

</details>

安装参数可通过 `bash install.sh --help` 查看。自定义目录、选择内核和直连安装见 [安装选项](docs/guide.md#安装选项)。日常配置在安装目录的 `.env` 中修改，模板见 [.env.example](.env.example)。

## 🎯 Quick Start

安装时已配置订阅，可直接开启当前终端代理：

```bash
clashctl on
clashctl ui              # 查看 Web 面板地址
clashctl secret          # 查看面板登录密钥
```

如果跳过了订阅配置，先添加并启用订阅：

```bash
clashctl sub add --use "<订阅链接>"
clashctl on
```

常用命令：

```bash
clashctl off             # 关闭当前终端代理，内核继续运行
clashctl start           # 启动内核
clashctl stop            # 停止内核
clashctl status          # 查看内核状态
clashctl log             # 查看内核日志
clashctl node            # 切换节点
clashctl tun on          # 开启 TUN 模式
clashctl tun off         # 关闭 TUN 模式

clashctl sub             # 选择订阅
clashctl sub ls          # 查看订阅列表
clashctl sub update      # 更新当前订阅
clashctl mixin -e        # 编辑自定义配置

clashctl -h              # 查看全部命令
```

`on` / `off` 设置或清除当前终端的代理环境变量；`on` 会在内核未运行时自动启动。需要停止内核并关闭当前终端代理时，依次执行 `clashctl stop` 和 `clashctl off`。

## 🔄 Update

```bash
clashctl update          # 更新 clashctl，保留订阅、配置和内核
clashctl upgrade         # 升级内核，是否支持取决于所选内核
```

旧版用户请重新执行安装命令，安装器会识别并迁移已有订阅和配置。需要沿原路径升级时，通过 `--home` 指定旧安装目录；迁移备份路径会在安装完成后显示。详见 [从旧版迁移](docs/guide.md#从旧版迁移)。

从测试分支切回 `master` 时，先将安装目录 `.env` 中的 `CLASHCTL_UPDATE_BRANCH` 改为 `master`，再运行 `clashctl update`。

## 🧹 Uninstall

```bash
clashctl off
bash "$CLASHCTL_HOME/uninstall.sh"
```

卸载会停止内核、移除服务与终端命令，并删除安装目录中的订阅、配置和日志。需要保留的数据请提前备份。安装目录外的 `.clashctl-backups/` 会保留，确认无需回退后可自行清理。

尚未加载命令时，默认安装可运行 `bash ~/.clashctl/uninstall.sh`；自定义安装请使用实际路径。

## 📖 Documentation

- [使用指南](docs/guide.md) — 安装选项、命令用法、订阅与配置、更新和迁移。
- [Wiki](https://github.com/nelvko/clash-for-linux-install/wiki) — 更多使用说明。
- [FAQ](https://github.com/nelvko/clash-for-linux-install/wiki/FAQ) — 常见问题。

## 💖 Support

### <img alt="Maru Code" src="https://cdn.nodeimage.com/i/hc6anADTcLP0P2CTOoqUMkKcHER4KeYY.webp" width="20" height="20"> [Maru Code —— 稳定可靠的 API 中转服务](https://api.muteki.site/register?aff=NELVKO&promo=nelvko)

- ⚡ 模型能力完整，`Claude` 系列满血可用。
- 📊 计费倍率透明公开，成本更容易预估。
- 🔑 自营号池保障可用性，日常调用更稳定。
- 🎁 新用户注册赠送 `$2` 额度：👉[立即注册](https://api.muteki.site/register?aff=NELVKO&promo=nelvko)

## ⭐ Star History

<a href="https://www.star-history.com/?repos=nelvko%2Fclash-for-linux-install&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=nelvko/clash-for-linux-install&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=nelvko/clash-for-linux-install&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=nelvko/clash-for-linux-install&type=date&legend=top-left" />
 </picture>
</a>

## ⚠️ Disclaimer

- 编写本项目主要目的为学习和研究 `Shell` 编程，不得将本项目中任何内容用于违反国家/地区/组织等的法律法规或相关规定的其他用途。
- 本项目保留随时对免责声明进行补充或更改的权利，直接或间接使用本项目内容的个人或组织，视为接受本项目的特别声明。
