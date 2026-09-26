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
- 管理内核启停、当前终端代理、Web 面板、TUN 模式、日志与访问密钥。
- 添加、切换和更新多个订阅；按需安装 [subconverter](https://github.com/tindy2013/subconverter) 进行格式转换。
- 在更新程序时保留订阅、自定义配置和内核。支持 systemd、OpenRC、runit、SysVinit 和 nohup 运行方式。

## 🚀 安装

正式版安装命令：

```bash
curl -fsSL https://raw.githubusercontent.com/nelvko/clash-for-linux-install/master/install.sh | bash -s -- --gh-proxy https://gh-proxy.org
```

默认安装到 `~/.clashctl`。如需自定义目录，在管道右侧的 `bash` 前设置 `CLASHCTL_HOME=/absolute/path`；路径须为只包含英文字母、数字、`_`、`.`、`/`、`-` 的绝对路径。安装完成后重新打开终端，再运行 `clashctl`。如果无需 GitHub 下载加速，删除命令末尾的 `--gh-proxy https://gh-proxy.org` 即可。

脚本 URL 中的分支只决定获取哪个版本的 `install.sh`；安装源码和后续更新由 `CLASHCTL_UPDATE_BRANCH` 决定，默认是 `master`。**在新版合并到 `master` 前**，验证 `install-update` 分支请同时指定两处：

```bash
curl -fsSL https://raw.githubusercontent.com/nelvko/clash-for-linux-install/install-update/install.sh | CLASHCTL_UPDATE_BRANCH=install-update bash -s -- --gh-proxy https://gh-proxy.org
```

`--gh-proxy` 用于安装脚本后续的源码和组件下载；**管道最前面的 `curl` 仍直接访问 `raw.githubusercontent.com`**。如果该地址无法访问，请先用可访问的网络或镜像获取安装脚本。代理地址失效时可在 [ghproxy.link](https://ghproxy.link/) 查找其他地址。

在 Linux 上验证本地源码（包括未提交的修改），可在源码目录执行 `bash install.sh --local`。该参数使用本地源码，但仍会按需下载内核和依赖；更新命令仍跟踪 `.env` 中指定的远端分支。

## 🎯 常用命令

```bash
clashctl on       # 启动内核，并为当前终端启用代理
clashctl off      # 关闭当前终端代理，内核继续运行
clashctl start    # 只启动内核
clashctl stop     # 只停止内核
clashctl status   # 查看内核状态

clashctl sub      # 选择或查看订阅
clashctl node     # 选择节点
clashctl ui       # 查看 Web 面板地址
clashctl log      # 查看日志
```

`on` 和 `off` 作用于**当前终端**；其他终端中的代理环境变量不会随之改变。运行 `clashctl --help` 可查看全部命令，子命令也支持 `--help`。

## 🔄 从旧版迁移

新版首次安装时，会识别旧版 `master` 的安装目录并迁移订阅、配置和可兼容的运行数据。安装目录优先使用当前终端已导出的 `CLASHCTL_HOME`；未设置时才使用新默认目录 `~/.clashctl`。迁移会重启内核，代理可能短暂中断。下方命令以新版合并到 `master` 后为准；合并前验证请按安装章节同时改用 `install-update` 脚本和源码分支。

### 搬到新默认目录

旧版在 `~/clashctl` 且 `~/.clashctl` 尚不存在时，让安装进程不继承旧版 Shell 配置中的 `CLASHCTL_HOME`。安装器会自动找到旧目录并迁移到 `~/.clashctl`：

```bash
curl -fsSL https://raw.githubusercontent.com/nelvko/clash-for-linux-install/master/install.sh | env -u CLASHCTL_HOME bash -s -- --gh-proxy https://gh-proxy.org
```

### 在原路径升级

让安装进程读取旧版 Shell 配置中已导出的 `CLASHCTL_HOME`，或将实际旧路径传给管道右侧的 `bash`。自定义旧目录也使用此方式：

```bash
curl -fsSL https://raw.githubusercontent.com/nelvko/clash-for-linux-install/master/install.sh | CLASHCTL_HOME=/absolute/path/to/clashctl bash -s -- --gh-proxy https://gh-proxy.org
```

不要把 `CLASHCTL_HOME=...` 只写在管道左侧的 `curl` 前面；那样右侧的安装进程读不到。

安装器会等待正在写入的旧版订阅操作结束；迁移期间请勿再启动旧版订阅更新。它只接管能确认属于 clashctl 的旧目录和服务；目标目录已存在但无法确认归属，或旧进程无法安全识别时会中止。成功后，旧目录保留在同级的 `.bak.*` 备份中；迁移失败时会尝试恢复旧目录和服务。备份包含订阅链接、配置及密钥，请妥善保管。迁移前也可先运行 `clashctl stop`，避免旧内核继续写入缓存。若自定义定时任务写死了旧目录路径，搬到新目录后需手动更新这些路径。

## ⬆️ 更新

```bash
clashctl update    # 更新 clashctl 程序，保留订阅、配置和内核
clashctl upgrade   # 升级内核
```

`clashctl update` 使用安装目录 `.env` 中的 `CLASHCTL_UPDATE_BRANCH` 和 `GH_PROXY`，默认跟踪 `master`。此前使用 `install-update` 等测试分支安装的用户，合并后如需跟踪正式版，请将 `.env` 中的 `CLASHCTL_UPDATE_BRANCH` 改为 `master`，重新打开终端后再执行更新。重新运行新版安装脚本也可更新已识别的安装，并继续未完成的安装。

## 🧹 卸载

```bash
clashctl off
bash "${CLASHCTL_HOME:-$HOME/.clashctl}/uninstall.sh"
```

卸载会停止本次安装的内核，移除服务和 Shell 引导，并删除安装目录，**包括订阅、自定义配置、内核和日志**。如需保留数据，请先备份安装目录中的 `.env`、`data/`；要保留内核选择等运行状态，还可备份 `resources/cache.db`。备份可能含订阅凭据和访问密钥。迁移时留下的 `.bak.*` 旧目录不属于当前安装，确认不再需要后可自行清理。

卸载脚本会显示实际删除路径并请求确认；无人值守可追加 `--yes`。卸载后重新打开终端，以清除旧命令和当前 Shell 无法由子进程撤销的环境变量。

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
