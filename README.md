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

<p align="center">
  <a href="#-快速开始">快速开始</a> ·
  <a href="#-常用命令">常用命令</a> ·
  <a href="#-从旧版迁移">旧版迁移</a>
</p>

## ✨ 功能

- 一条命令安装 mihomo 或 Clash 及运行依赖，普通用户与 root 均可使用。
- 管理内核、当前终端代理、Web 面板和 TUN 模式。
- 添加、切换和更新多个订阅；更新程序时保留订阅与自定义配置。

## 🚀 快速开始

### 1. 安装

```bash
curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/nelvko/clash-for-linux-install/master/install.sh | \
  bash -s -- --gh-proxy https://gh-proxy.org
```

默认安装到 `~/.clashctl`。安装完成后重新打开终端，再使用 `clashctl`。可选参数写在管道右侧的 `bash -s --` 后：

| 参数 | 作用 | 示例 |
| --- | --- | --- |
| `--install-dir` | 指定绝对安装目录，优先于 `CLASHCTL_HOME` | `--install-dir "$HOME/apps/clashctl"` |
| `--gh-proxy` | 加速安装器后续的源码和组件下载 | `--gh-proxy https://gh-proxy.org` |

上面的命令还通过代理下载入口脚本。直连时，去掉 URL 开头的 `https://gh-proxy.org/`，并将右侧参数改为 `--gh-proxy=`，以清除已有代理配置。

URL 中的分支只选择安装器；源码和后续更新跟踪 `CLASHCTL_UPDATE_BRANCH` 指定的分支，新安装默认为 `master`。

### 2. 添加订阅并启动

```bash
clashctl sub add --use "<订阅链接>"
clashctl on
clashctl ui
```

添加订阅后，`clashctl on` 会启动内核并启用当前终端代理；`clashctl ui` 显示 Web 面板地址。

## 🎯 常用命令

| 操作 | 命令 |
| --- | --- |
| 切换订阅 / 选择节点 | `clashctl sub` / `clashctl node` |
| 更新当前 / 全部订阅 | `clashctl sub update` / `clashctl sub update --all` |
| 关闭当前终端代理 | `clashctl off` |
| 只启动 / 停止内核 | `clashctl start` / `clashctl stop` |
| 查看内核状态 / 日志 | `clashctl status` / `clashctl log` |

`off` 只关闭当前终端代理，需要停止内核时运行 `clashctl stop`。更多命令见 `clashctl --help`。

## 🔄 从旧版迁移

安装器会识别旧版目录并迁移订阅和配置。按希望保留的路径选择：

**搬到新默认目录**：旧版在 `~/clashctl`，且 `~/.clashctl` 尚不存在。

```bash
curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/nelvko/clash-for-linux-install/master/install.sh | \
  bash -s -- --install-dir "$HOME/.clashctl" --gh-proxy https://gh-proxy.org
```

**沿原路径升级**：将 `--install-dir` 改为实际旧目录，自定义路径也适用。

```bash
curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/nelvko/clash-for-linux-install/master/install.sh | \
  bash -s -- --install-dir /absolute/path/to/clashctl --gh-proxy https://gh-proxy.org
```

迁移可能短暂重启内核。旧目录会留在同级的 `.bak.*` 备份中，其中可能含订阅凭据和访问密钥；确认不再需要后再清理。搬迁目录后，记得修改写死旧路径的定时任务。

## ⬆️ 更新

```bash
clashctl update   # 更新程序，保留订阅和配置
clashctl upgrade  # 更新内核
```

从其他分支安装的用户仍跟踪原分支。要切换到 `master`，先将安装目录 `.env` 中的 `CLASHCTL_UPDATE_BRANCH` 改为 `master`，再运行 `clashctl update`。

## 🧹 卸载

```bash
bash "${CLASHCTL_HOME:-$HOME/.clashctl}/uninstall.sh"
```

若当前终端仍指向旧目录，请重新打开终端，或直接运行 `bash /实际安装路径/uninstall.sh`。卸载会停止内核并删除安装目录，包括订阅和配置；需要保留的数据请先备份。

## 📖 文档

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
