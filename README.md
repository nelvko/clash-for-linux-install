# Linux 一键安装 Clash

因为有在服务器上使用代理的需求，试过许多开源脚本，总是遇到各种问题。于是自己动手，丰衣足食：对 `Clash` 的安装过程及功能进行了友好封装，使用起来优雅、简单、明确。

![img](resource/preview.png)

## 快速开始

### 环境要求

- 需要 `root` 或 `sudo` 权限。
- 具备 `bash` 和 `systemd` 的系统环境。
- 已适配：`CentOS 7.6`、`Debian 12`、`Ubuntu 24.04.1 LTS`。

### 一键安装

```bash
git clone https://gitclone.com/github.com/nelvko/clash-for-linux-install.git \
	&& cd clash-for-linux-install \
	&& sudo bash -c '. install.sh; exec bash'
```
> 如遇问题，请在查阅[常见问题](#常见问题)及 [issue](https://github.com/nelvko/clash-for-linux-install/issues?q=is%3Aissue) 未果后进行反馈。

- 上述克隆命令使用了[加速前缀](https://gitclone.com/)，如失效请更换其他[可用链接](https://ghproxy.link/)。
- ~~不懂什么是订阅链接的小白可参考~~：[issue#1](https://github.com/nelvko/clash-for-linux-install/issues/1)
- 没有订阅？[click me](https://次元.net/auth/register?code=oUbI)

### 命令一览

执行 `clash` 列出开箱即用的快捷命令。

```bash
$ clash
Usage:                                    
    clashon               	开启代理       
    clashoff              	关闭代理       
    clashui               	面板地址       
    clashtun [on|off]     	Tun模式        
    clashsecret [secret]  	查看/设置密钥  
    clashmixin [-e|-r]    	Mixin配置      
    clashupdate [auto|log]	更新订阅
```

### 基础使用

```bash
$ clashoff
😼 已关闭代理环境

$ clashon
😼 已开启代理环境

$ clashui
😼 Web 面板地址...
```

使用原理：

- 使用 `systemctl` 控制 `clash` 启停后，还需调整代理环境变量的值（http_proxy 等）。因为应用程序在发起网络请求时，会通过其指定的代理地址转发流量，不调整会造成：关闭代理后仍转发导致请求失败、开启代理后未设置代理地址导致请求不转发。
- `clashon` 等命令封装了上述流程。

### 定时更新订阅

```bash
$ clashupdate [url]
😼 配置更新成功，已重启生效

$ clashupdate auto [url]
😼 定时任务设置成功

$ clashupdate log
✅ 2024-12-13 23:38:56 配置更新成功 ...
```

- `clashupdate` 会记忆上次更新成功的订阅，后续执行无需再指定 `url`。
- 可通过 `crontab -e` 修改定时更新频率及订阅链接。
- 其他更新方式：[pr#24](https://github.com/nelvko/clash-for-linux-install/pull/24#issuecomment-2565054701)
- 依赖 [`yq`](https://github.com/mikefarah/yq/releases) 命令实现 [`Mixin`](#mixin-配置)，如自动下载失败请自行安装到 `PATH` 路径内。

### Web 控制台密钥

控制台密钥默认为空，若暴露到公网使用建议更新密钥。

```bash
$ clashsecret xxx
😼 密钥更新成功，已重启生效

$ clashsecret
😼 当前密钥：xxx
```

### `Tun` 模式

```bash
$ clashtun
😾 Tun 状态：关闭

$ clashtun on
😼 Tun 模式已开启
```

- 作用：实现本机及 `Docker` 等容器的所有流量路由到 `clash` 代理、DNS 劫持等。
- 原理：[clash-verge-rev](https://www.clashverge.dev/guide/term.html#tun)、 [clash.wiki](https://clash.wiki/premium/tun-device.html)。

### `Mixin` 配置

```bash
$ clashmixin
😼 查看 mixin 配置

$ clashmixin -e
😼 编辑 mixin 配置

$ clashmixin -r
😼 查看 运行时 配置
```

- 作用：用来存储自定义配置，防止更新订阅后覆盖丢失自定义配置内容。
- 运行时配置是订阅配置和 `Mixin` 配置的并集。
- 相同配置项优先级：`Mixin` 配置 > 订阅配置。

### 卸载

```bash
sudo bash -c '. uninstall.sh; exec bash'
```

## 常见问题

### 配置下载失败或无效

- 下载失败：脚本使用 `wget`、`curl` 命令进行了多次[重试](https://github.com/nelvko/clash-for-linux-install/blob/035c85ac92166e95b7503b2a678a6b535fbd4449/script/common.sh#L32-L46)下载，如果还是失败可能是机场限制，请自行粘贴订阅内容到配置文件：[issue#1](https://github.com/nelvko/clash-for-linux-install/issues/1#issuecomment-2066334716)
- 订阅配置无效：[issue#14](https://github.com/nelvko/clash-for-linux-install/issues/14#issuecomment-2513303276)

### bash: clashon: command not found

- 原因：使用 `bash install.sh` 执行脚本不会对当前 `shell` 生效。
- 解决：当前 `shell` 执行下 `bash` 即可。
- <details>

  <summary>几种运行方式的区别：</summary>

	- `bash` 命令运行：当前 `shell` 开启一个子 `shell` 执行脚本，对环境的修改不会作用到当前 `shell`，因此不具备 `clashon`
	  等命令。

	  ```bash
	  # 需要有可执行权限
	  $ ./install.sh
	  # 不需要可执行权限，需要读权限
	  $ bash ./install.sh
	  ```
	- `shell` 内建命令运行：脚本在当前 `shell` 环境中执行，变量和函数的定义对当前 `shell` 有效，`root` 用户推荐这种方式执行脚本。

	  ```bash
	  # 不需要可执行权限，需要读权限
	  $ . install.sh
	  $ source uninstall.sh
	  ```

  </details>

### 服务启动失败/未启动

- [端口占用](https://github.com/nelvko/clash-for-linux-install/issues/15#issuecomment-2507341281)
- [系统为 WSL 环境或不具备 systemd](https://github.com/nelvko/clash-for-linux-install/issues/11#issuecomment-2469817217)

### x86、arm架构

默认集成 `amd64` 版本的软件包，安装时会检测 `CPU` 架构，若为其他架构会从 [Clash 内核官网](https://downloads.clash.wiki/ClashPremium/)下载对应版本。若自动下载失败请自行下载至项目的 `resource` 路径下，并重新执行安装脚本。

## 引用

- [clash-linux-amd64-2023.08.17.gz](https://downloads.clash.wiki/ClashPremium/)
- [Clash Web Dashboard](https://github.com/haishanh/yacd/releases/tag/v0.3.8)
- [Clash 全家桶下载](https://www.clash.la/releases/)
- [Clash 知识库](https://clash.wiki/)

## Todo

- [X] 定时更新配置
- [X] 😼
- [X] 适配其他发行版
- [X] 配置更新日志
- [X] Tun 模式
- [x] mixin 配置
- [x] 适配x86、arm架构
- [ ] [bug / 需求](https://github.com/nelvko/clash-for-linux-install/issues)

## Thanks

[@鑫哥](https://github.com/TrackRay)

## 特别声明

1. 编写本项目主要目的为学习和研究 `Shell` 编程，不得将本项目中任何内容用于违反国家/地区/组织等的法律法规或相关规定的其他用途。
2. 本项目保留随时对免责声明进行补充或更改的权利，直接或间接使用本项目内容的个人或组织，视为接受本项目的特别声明。
