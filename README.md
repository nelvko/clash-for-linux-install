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

```bash
curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/nelvko/clash-for-linux-install/master/install.sh | bash
```

默认安装到 `~/.clashctl`，安装后重开终端加载命令。
有 Git 时克隆仓库；没有 Git 时，使用 curl（或 wget）下载分支源码压缩包。
Git 克隆失败会直接报错，不自动切换方式。组件和订阅下载仍需要 curl，另需 tar、gzip、unzip 等运行依赖。
订阅链接在安装时输入，也可跳过。跳过时只安装组件和命令，不启动代理、不启用自启。
运行 `clashctl sub add --use <url>` 首次启用订阅后，会生成运行配置、启动代理并设置自启。
组件独立安装；某个组件失败时保留已安装成功的组件，修复问题后可重新运行安装脚本。

`data/config.yaml` 是来自订阅或本地导入的主配置，必须含有节点或代理提供者并通过内核校验；
`data/mixin.yaml` 仅用于覆盖和补充主配置，两者合并生成内核运行所需的 `data/runtime.yaml`。
没有有效主配置时，`clashctl on` 会提示先添加并启用订阅。

可通过 `CLASHCTL_HOME`、`CLASHCTL_UPDATE_BRANCH`、`GH_PROXY` 环境变量设置目录、分支和下载代理，
管道安装时变量必须设置在右侧 `bash` 前，例如安装 `iu` 分支：

```bash
curl -fsSL https://raw.githubusercontent.com/nelvko/clash-for-linux-install/iu/install.sh | CLASHCTL_UPDATE_BRANCH=iu bash
```

写在 `curl` 前的变量不会传给右侧 `bash`。设置 `GH_PROXY=''` 使用直连。

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

```bash
clashupdate             # 更新脚本与资源，并加载到当前 Shell
# 等价命令：clashctl update
```

更新沿用安装时的方式：Git 安装使用 Git；压缩包安装重新下载源码压缩包，即使后来安装了 Git 也不会自动转换。
两种方式都保留 `data/` 中的订阅、Mixin 和密钥，以及已下载的内核、面板和运行缓存，不重启代理。
Git 安装有本地代码修改时会停止，请先提交或暂存；压缩包安装按 `.clashctl-files` 中的校验值检查程序文件，
发现修改或缺失时会停止，请先恢复。压缩包更新会清理新版已删除的程序文件，写入失败时尝试恢复原程序。
更新来源由 `~/.clashctl/.env` 中的 `CLASHCTL_UPDATE_BRANCH` 和 `GH_PROXY` 配置。
升级代理内核仍使用 `clashctl upgrade`。

旧版数字 ID 订阅数据不再自动迁移。遇到格式提示时，先备份
`$CLASHCTL_HOME/data/profiles.yaml`，用安装目录中的 `resources/profiles.yaml` 模板替换它，再用 `clashctl sub add --use <url>` 重新添加订阅。
现有主配置和运行配置会保留。

## 🧹 Uninstall

```bash
bash ~/.clashctl/uninstall.sh
```

仅允许卸载安装器创建、且 `.clashctl-install` 标记与当前路径匹配的目录；该文件记录安装路径和 Git/压缩包类型。
此前的 `.git/clashctl-home` 路径标记仍可验证，Git 更新成功后会补写独立标记。
源码克隆、移动或复制后的安装副本、完全没有标记的旧目录会被拒绝，不会删除；请勿手动补写标记。
确认后停止并移除当前安装的服务，清理指向本目录的 Shell 引导及安装目录。
有安装标记但尚未生成 `.env` 的中断安装仅清理目录自身。若内核信息无效、服务停止或 Shell 清理失败，会保留安装目录。
非交互卸载使用 `--yes`。

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
