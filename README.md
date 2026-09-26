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

- 一条命令安装内核与运行依赖，支持普通用户和 root。
- 管理内核、当前终端代理、Web 面板和 TUN 模式。
- 添加、切换和更新多个订阅；更新程序时保留订阅与自定义配置。

## 🚀 安装

```bash
curl -fsSL https://raw.githubusercontent.com/nelvko/clash-for-linux-install/master/install.sh | bash -s -- --gh-proxy https://gh-proxy.org
```

默认安装到 `~/.clashctl`；自定义目录在管道右侧加 `--install-dir /absolute/path`，优先于已导出的 `CLASHCTL_HOME`。安装后重新打开终端，即可使用 `clashctl`。不需要下载加速时，去掉 `--gh-proxy https://gh-proxy.org`；该参数不影响管道左侧的 `curl`。

脚本 URL 中的分支只决定安装器版本；安装源码和后续更新使用 `CLASHCTL_UPDATE_BRANCH` 指定的分支，新安装默认跟踪 `master`。

## 🎯 常用命令

```bash
clashctl sub add --use "<订阅链接>"  # 添加并使用订阅
clashctl sub                      # 选择订阅
clashctl node                     # 选择节点

clashctl on      # 启动内核，并为当前终端启用代理
clashctl off     # 关闭当前终端代理
clashctl start   # 只启动内核
clashctl stop    # 只停止内核
clashctl status  # 查看内核状态
clashctl ui      # 查看 Web 面板地址
clashctl log     # 查看日志
```

与旧版不同，`off` 不再停止内核；需要停止时运行 `clashctl stop`。更多命令见 `clashctl --help`。

## 🔄 从旧版迁移

新版安装器会识别旧版目录，迁移订阅和配置。根据希望保留的安装路径选择命令：

**搬到新默认目录**：旧版位于 `~/clashctl`，且 `~/.clashctl` 尚不存在时，显式指定新目录。

```bash
curl -fsSL https://raw.githubusercontent.com/nelvko/clash-for-linux-install/master/install.sh | bash -s -- --install-dir "$HOME/.clashctl" --gh-proxy https://gh-proxy.org
```

**沿原路径升级**：把实际旧目录传给 `--install-dir`。自定义旧路径也适用。

```bash
curl -fsSL https://raw.githubusercontent.com/nelvko/clash-for-linux-install/master/install.sh | bash -s -- --install-dir /absolute/path/to/clashctl --gh-proxy https://gh-proxy.org
```

迁移可能短暂重启内核。成功后，旧目录留在同级的 `.bak.*` 备份中，其中可能包含订阅凭据和访问密钥；确认不再需要后再清理。搬迁目录后，记得修改写死旧路径的定时任务。

## ⬆️ 更新

```bash
clashctl update   # 更新程序，保留订阅和配置
clashctl upgrade  # 更新内核
```

已从其他分支安装的用户仍会跟踪原分支；要切换到正式版，先将安装目录 `.env` 中的 `CLASHCTL_UPDATE_BRANCH` 改为 `master`，再运行 `clashctl update`。

## 🧹 卸载

```bash
bash "${CLASHCTL_HOME:-$HOME/.clashctl}/uninstall.sh"
```

刚用 `--install-dir` 更换路径时，请在新终端卸载，或直接运行 `bash /实际安装路径/uninstall.sh`，避免当前终端仍指向旧目录。卸载会停止内核并删除安装目录，包括订阅和配置；需要保留的数据请先备份。

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
