<h1 align="center">clashctl</h1>

<p align="center">在 Linux 上安装和管理 Mihomo / Clash</p>

<p align="center">
  <a href="https://www.star-history.com/nelvko/clash-for-linux-install">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/badge?repo=nelvko/clash-for-linux-install&type=rank&theme=dark" />
      <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/badge?repo=nelvko/clash-for-linux-install&type=rank" />
      <img alt="Star History Global Rank" src="https://api.star-history.com/badge?repo=nelvko/clash-for-linux-install&type=rank" />
    </picture>
  </a>
</p>

<p align="center">
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/github/license/nelvko/clash-for-linux-install" /></a>
  <a href="https://github.com/nelvko/clash-for-linux-install/stargazers"><img alt="GitHub Stars" src="https://img.shields.io/github/stars/nelvko/clash-for-linux-install" /></a>
  <a href="https://deepwiki.com/nelvko/clash-for-linux-install"><img alt="Ask DeepWiki" src="https://deepwiki.com/badge.svg" /></a>
</p>

<p align="center">
  <a href="#安装">安装</a> ·
  <a href="#使用">使用</a> ·
  <a href="docs/guide.md">使用指南</a> ·
  <a href="https://github.com/nelvko/clash-for-linux-install/wiki/FAQ">常见问题</a>
</p>


<p align="center">
  <img src="preview.png" alt="clashctl 终端界面预览（旧版占位）" width="760" />
</p>
<p align="center"><sub>终端界面预览 · 暂用旧版截图，后续更新</sub></p>

## 特性

- **安装简单**：默认使用 Mihomo，也可选择 Clash；支持普通用户与 root。
- **终端管理**：开关当前终端代理、切换节点、管理 TUN 和 Web 面板。
- **订阅与配置**：保存、切换和更新多个订阅，通过 Mixin 保留自定义配置。

## 安装

在 Linux 终端中运行：

```bash
curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/nelvko/clash-for-linux-install/master/install.sh | \
  bash -s -- --gh-proxy https://gh-proxy.org
```

默认安装到 `~/.clashctl`。安装完成后按提示加载 `clashctl`，或重新打开终端。

源码安装、自定义目录和直连方式见 [安装选项](docs/guide.md#安装选项)。 

## 使用

添加订阅并开启代理；安装时已配置订阅可跳过第一步：

```bash
clashctl sub add --name mysub --use "<订阅链接>"
clashctl on

clashctl ui              # 查看 Web 面板地址
clashctl secret          # 查看面板登录密钥
```

日常操作：

```bash
clashctl off             # 关闭当前终端代理，内核继续运行
clashctl status          # 查看内核状态
clashctl node            # 选择节点
clashctl sub update      # 更新当前订阅
clashctl update          # 更新 clashctl，保留订阅和配置
```

`on` / `off` 作用于**当前终端**；需要停止内核时运行 `clashctl stop`。完整命令见 `clashctl --help`。

## 文档

- [使用指南](docs/guide.md)：安装选项、订阅与配置、更新、旧版迁移和卸载。
- [常见问题](https://github.com/nelvko/clash-for-linux-install/wiki/FAQ) · [Wiki](https://github.com/nelvko/clash-for-linux-install/wiki)
- [问题反馈](https://github.com/nelvko/clash-for-linux-install/issues) · [社区讨论](https://github.com/nelvko/clash-for-linux-install/discussions)

## 支持

通过 [爱发电](https://afdian.com/a/nelvko) 支持项目。

没有订阅？[获取订阅](https://次元.net/auth/register?code=oUbI)。也可使用项目推荐的 [Maru Code API 中转服务](https://api.muteki.site/register?aff=NELVKO&promo=nelvko)。

<details>
<summary>Star History</summary>

<a href="https://www.star-history.com/?repos=nelvko%2Fclash-for-linux-install&type=timeline&legend=bottom-right">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=nelvko/clash-for-linux-install&type=date&theme=dark&legend=bottom-right" />
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=nelvko/clash-for-linux-install&type=date&legend=bottom-right" />
    <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=nelvko/clash-for-linux-install&type=date&legend=bottom-right" />
  </picture>
</a>

</details>

## 许可证

[MIT License](LICENSE)。本项目仅供学习和研究 Shell 编程，请遵守适用的法律法规。
