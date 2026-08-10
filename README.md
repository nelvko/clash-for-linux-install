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
- **订阅管理**：支持多订阅源配置、一键切换、定时更新，并集成 [subconverter](https://github.com/tindy2013/subconverter) 实现订阅格式转换。
- **流量统计**：按认证账号、Linux UID 或来源 IP 汇总代理流量，并提供本地 Web 仪表盘和 CSV 导出。

## 🚀 Installation

在终端中执行以下命令即可完成安装：

```bash
git clone --branch master --depth 1 https://gh-proxy.org/https://github.com/nelvko/clash-for-linux-install.git \
  && cd clash-for-linux-install \
  && bash install.sh
```

- 上述命令使用了[加速前缀](https://gh-proxy.org/)，如失效请更换其他[可用链接](https://ghproxy.link/)。
- 可通过 `.env.install` 文件自定义安装选项。
- 没有订阅？[click me](https://次元.net/auth/register?code=oUbI)

## 📊 Traffic accounting

`clashctl traffic` 从 Mihomo `/connections` 接口定期读取连接字节计数，按可识别身份聚合并保存到本地 SQLite。该功能需要 **Python 3.10 或更高版本**。

```bash
# 启动采集器和仅监听本机的仪表盘
clashctl traffic start

# 查看状态、今日排行和当前活跃连接
clashctl traffic status
clashctl traffic today
clashctl traffic live

# 查看最近 24 小时并导出最近 7 天 CSV
clashctl traffic top 24h
clashctl traffic export --since 7d > traffic.csv

# 显示仪表盘地址和远程 SSH 隧道示例
clashctl traffic ui

# 停止采集器
clashctl traffic stop
```

默认仪表盘地址为 `http://127.0.0.1:8765`，不会监听公网地址。远程服务器建议通过 SSH 隧道访问：

```bash
ssh -N -L 8765:127.0.0.1:8765 <server>
```

统计数据库位于 `${XDG_STATE_HOME:-~/.local/state}/clashctl/traffic.sqlite3`，目录和数据库权限分别限制为 `700` 和 `600`。采集器只持久化身份、归属类型、置信度和字节增量，不保存目标域名、目标地址、进程路径、流量内容或 Mihomo 控制密钥。

统计保留两个不同字段：

- `user_id`：仅表示 Linux UID，JSON 中为整数；无法映射到本机 Linux 用户时为 `null`，CSV 中为空。
- `identity_key`：通用归属键，可为 `uid:<UID>`、`account:<inboundUser>`、`source-ip:<IP>` 或 `unknown`。

归属顺序为：代理认证账号优先；本机 loopback 连接按 `sourcePort` 从 `/proc/net/{tcp,tcp6,udp,udp6}` 唯一反查 Linux UID；然后才使用 Mihomo 返回的正数 UID、来源 IP 和 `unknown`。`/proc` 反查只在每轮采样时读取一次，不持久化端口、inode 或进程路径。

> [!IMPORTANT]
> 这是基于连接接口的采样统计，不是计费级计量。连接第一次出现时只建立基线；短连接可能在两次采样之间完成，连接消失前最后一段流量也无法追溯；采集器停止期间的流量不会补记。要可靠区分远程用户，请为每个用户配置独立的代理认证账号。

## 📖 Documentation

- [Usage](https://github.com/nelvko/clash-for-linux-install/wiki) — 命令用法与示例。
- [FAQ](https://github.com/nelvko/clash-for-linux-install/wiki/FAQ) — 常见问题。

## 💖 Support

### <img alt="Maru Code" src="https://cdn.nodeimage.com/i/hc6anADTcLP0P2CTOoqUMkKcHER4KeYY.webp" width="20" height="20"> [Maru Code —— 稳定可靠的 API 中转服务](https://api.muteki.site/register?aff=NELVKO)

- ⚡ 模型能力完整，`Claude` 系列满血可用。
- 📊 计费倍率透明公开，成本更容易预估。
- 🔑 自营号池保障可用性，日常调用更稳定。
- 🎁 新用户注册赠送 `$2` 额度：👉[立即注册](https://api.muteki.site/register?aff=NELVKO&promo=nelvko)

## ⭐ Star History

<a href="https://www.star-history.com/#nelvko/clash-for-linux-install&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=nelvko/clash-for-linux-install&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=nelvko/clash-for-linux-install&type=Date" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=nelvko/clash-for-linux-install&type=Date" />
 </picture>
</a>

## ⚠️ Disclaimer

- 编写本项目主要目的为学习和研究 `Shell` 编程，不得将本项目中任何内容用于违反国家/地区/组织等的法律法规或相关规定的其他用途。
- 本项目保留随时对免责声明进行补充或更改的权利，直接或间接使用本项目内容的个人或组织，视为接受本项目的特别声明。
