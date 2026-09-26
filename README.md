<h1 align="center">clashctl</h1>

<p align="center">在 Linux 上安装和管理 mihomo / clash</p>
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

![clashctl 预览](preview.png)

## ✨ 功能

- 一条命令安装 mihomo / clash，支持普通用户和 root。
- 管理订阅、节点、终端代理与内核服务。
- 提供 Web 面板、TUN 模式和程序更新。

## 🚀 安装

```bash
curl -fsSL https://raw.githubusercontent.com/nelvko/clash-for-linux-install/master/install.sh | bash -s -- --gh-proxy https://gh-proxy.org
```

默认安装到 `~/.clashctl`。安装后重新打开终端，即可使用 `clashctl`。不需要下载加速时，可去掉 `--gh-proxy` 参数。

## 🎯 使用

```bash
clashctl sub add --use "<订阅链接>"  # 添加并使用订阅
clashctl on                       # 启动内核，启用当前终端代理
clashctl off                      # 关闭当前终端代理
clashctl start                    # 只启动内核
clashctl stop                     # 只停止内核
clashctl update                   # 更新程序
```

`off` 只关闭当前终端代理；要停止内核，请运行 `stop`。订阅、节点、面板等命令见 `clashctl --help`。

## 🔄 旧版升级

在旧版环境运行上方安装命令，即可迁移订阅和配置。若当前终端导出了 `CLASHCTL_HOME`，会沿原路径升级；想把旧版 `~/clashctl` 搬到新默认目录，请在命令的 `bash` 前加 `env -u CLASHCTL_HOME`。详见[安装与迁移](docs/install.md)。

## 🧹 卸载

```bash
bash "${CLASHCTL_HOME:-$HOME/.clashctl}/uninstall.sh"
```

卸载会删除安装目录，包括订阅和配置；请先备份需要保留的数据。

## 📖 文档

- [安装与迁移](docs/install.md)
- [常见问题](https://github.com/nelvko/clash-for-linux-install/wiki/FAQ)
- [更多使用说明](https://github.com/nelvko/clash-for-linux-install/wiki)

## 💖 支持

没有订阅？[获取订阅](https://次元.net/auth/register?code=oUbI)。

### <img alt="Maru Code" src="https://cdn.nodeimage.com/i/hc6anADTcLP0P2CTOoqUMkKcHER4KeYY.webp" width="20" height="20"> [Maru Code —— 稳定可靠的 API 中转服务](https://api.muteki.site/register?aff=NELVKO&promo=nelvko)

- ⚡ 模型能力完整，`Claude` 系列满血可用。
- 📊 计费倍率透明公开，成本更容易预估。
- 🔑 自营号池保障可用性，日常调用更稳定。
- 🎁 新用户注册赠送 `$2` 额度：[立即注册](https://api.muteki.site/register?aff=NELVKO&promo=nelvko)

## ⭐ Star History

<a href="https://www.star-history.com/?repos=nelvko%2Fclash-for-linux-install&type=timeline&legend=bottom-right">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=nelvko/clash-for-linux-install&type=date&theme=dark&legend=bottom-right" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=nelvko/clash-for-linux-install&type=date&legend=bottom-right" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=nelvko/clash-for-linux-install&type=date&legend=bottom-right" />
 </picture>
</a>

## ⚠️ 免责声明

- 编写本项目主要目的为学习和研究 Shell 编程，不得将本项目中的任何内容用于违反国家、地区或组织法律法规及相关规定的用途。
- 本项目保留随时补充或更改免责声明的权利。直接或间接使用本项目内容的个人或组织，视为接受本项目的特别声明。
