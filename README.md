<h1 align="center">
  clashctl
</h1>

<p align="center">Linux 上的 Mihomo / Clash 安装与管理工具</p>

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
  <a href="https://github.com/nelvko/clash-for-linux-install/actions/workflows/shell-tests.yml"><img alt="Shell tests" src="https://github.com/nelvko/clash-for-linux-install/actions/workflows/shell-tests.yml/badge.svg" /></a>
  <img alt="Platform: Linux" src="https://img.shields.io/badge/platform-Linux-blue?logo=linux&amp;logoColor=white" />
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/github/license/nelvko/clash-for-linux-install" /></a>
  <img alt="Language: Shell" src="https://img.shields.io/github/languages/top/nelvko/clash-for-linux-install" />
  <a href="https://github.com/nelvko/clash-for-linux-install/stargazers"><img alt="GitHub stars" src="https://img.shields.io/github/stars/nelvko/clash-for-linux-install" /></a>
  <a href="https://deepwiki.com/nelvko/clash-for-linux-install"><img src="https://deepwiki.com/badge.svg" alt="Ask DeepWiki" /></a>
</p>

## ✨ 特性

- **开箱即用**：一键部署 `mihomo` 内核、Web 面板及运行依赖。
- **广泛兼容**：支持 `root` 与普通用户，适配主流 Linux 发行版及容器环境。兼容 systemd、OpenRC 等服务方式，提供 Bash、Zsh 和 Fish 命令集成。
- **功能丰富**：涵盖代理开关、内核启停、状态查看、日志追踪等常用操作，支持 Web 面板、TUN 模式、内核升级及 `Mixin` 配置。
- **订阅管理**：支持多订阅添加、切换与更新，集成 [subconverter](https://github.com/asdlokj1qpi233/subconverter) 实现订阅格式转换。

## 📦 安装

首次安装或从旧版升级，执行以下命令（已加速）：

```bash
GH_PROXY=https://gh-proxy.org/
curl -fsSL "${GH_PROXY}https://raw.githubusercontent.com/nelvko/clash-for-linux-install/HEAD/install.sh" | \
  bash -s -- --gh-proxy "$GH_PROXY"
```

- `GH_PROXY`：[GitHub 下载加速代理](https://gh-proxy.org/)，失效时可更换[其他可用地址](https://ghproxy.link/)。
- 没有订阅？[click me](https://次元.net/auth/register?code=oUbI)

## 🚀 快速上手

添加并启用订阅（安装时已配置可跳过）：

```bash
clashctl sub add --use "<订阅链接>"
```

开启当前终端代理：

```bash
# 自动启动内核，并开启当前终端代理
clashctl on

# 测试连通性
curl -I https://www.google.com
```

## ⌨️ 命令一览

```text
Usage:
  clashctl COMMAND [OPTIONS]

Commands:
  on                    启用当前终端代理，自动启动内核
  off                   关闭当前终端代理，保留内核运行
  start                 仅启动内核
  stop                  仅停止内核
  status                内核状态
  ui                    面板地址
  sub                   订阅管理
  node                  节点切换
  tun                   Tun 模式
  mixin                 Mixin 配置
  secret                Web 密钥
  log                   查看日志
  upgrade               升级内核
  update                更新 clashctl

Global Options:
  -h, --help            显示帮助信息
```

使用示例与进阶配置，详见 [Wiki](https://github.com/nelvko/clash-for-linux-install/wiki)。

## 🔄 更新

```bash
# 更新 clashctl 上游版本
clashctl update

# 升级代理内核
clashctl upgrade
```

## 🗑️ 卸载

```bash
# 清理当前 Shell 的代理环境变量（卸载脚本无法清理）
clashctl off

# 执行卸载脚本
bash "$CLASHCTL_HOME/uninstall.sh"
```

卸载会删除安装目录及其数据，需要保留的内容请提前备份。`.clashctl-backups/` 中的恢复资料会保留，确认无需回退后可手动清理。

## 📖 文档

- [Wiki](https://github.com/nelvko/clash-for-linux-install/wiki)
- [常见问题](https://github.com/nelvko/clash-for-linux-install/wiki/FAQ)

## 💖 赞助

<table>
  <tr>
    <td width="180" align="center" valign="middle">
      <a href="https://api.muteki.site/register?aff=nelvko&promo=nelvko">
        <img src="https://cdn.nodeimage.com/i/hc6anADTcLP0P2CTOoqUMkKcHER4KeYY.webp" alt="MaruCode" width="60">
      </a>
    </td>
    <td valign="middle">
      <b><a href="https://api.muteki.site/register?aff=nelvko&promo=nelvko">MaruCode</a></b> 是一家偶尔做做慈善的小破站 API，自营号池，主要提供 Codex、Claude Code、GPT Image 等主流模型，支持 Websocket 协议，明码标价(Codex 0.25x, CC 1.5x)，透明汇率(1:1) <a href="https://api.muteki.site/register?aff=nelvko&promo=nelvko"></a><a href="https://images-2.muteki.site">生图工作台🖼️</a>
    </td>
  </tr>
</table>

## ⭐ Star History

<a href="https://www.star-history.com/?repos=nelvko%2Fclash-for-linux-install&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=nelvko/clash-for-linux-install&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=nelvko/clash-for-linux-install&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=nelvko/clash-for-linux-install&type=date&legend=top-left" />
 </picture>
</a>

## ⚠️ 特别声明

- 编写本项目主要是为了学习和研究 `Shell` 编程，不得将项目内容用于违反适用法律法规及相关规定的活动。
- 本项目保留对本声明进行补充或修改的权利。使用本项目前，请阅读并遵守本声明。
