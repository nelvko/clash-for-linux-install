# Linux 一键部署 Clash

因为有在服务器上使用代理的需求，试过大部分的开源脚本，总是遇到各种问题。于是自己动手，丰衣足食。对安装过程及后续使用进行了友好封装，部署使用起来优雅、简单、明确。

基于 `Clash` 项目作者删库前最新的 `Premium` 版本，如有需求可自行更换版本。

文末[引用](#ref)中收集了各种内核和 `GUI` 客户端版本的下载地址。

## 环境要求

- 需要 `root` 权限（普通用户使用 `sudo`）
- 具备 `bash` 和 `systemd` 的系统环境

## 快速开始

### 一键安装脚本

```bash
git clone https://ghp.ci/https://github.com/nelvko/clash-for-linux-install.git && cd clash-for-linux-install && . install.sh
```

- 以上脚本已使用[代理加速下载](https://ghp.ci/)，如失效请自行更换

- ~~不懂什么是订阅链接的小白可参考~~：[issue#1](https://github.com/nelvko/clash-for-linux-install/issues/1)

- 没有订阅？[click me](https://次元.net/auth/register?code=oUbI)

### Command

以下命令已集成到 `bashrc` 中，可直接在终端执行。

```bash
# 关闭代理环境
clashoff

# 启动代理环境
clashon

# 打印 ui 地址
clashui

# 手动更新配置
clashupdate <url>
```

- 使用 `systemctl` 控制 `clash` 启停后，还需调整代理环境变量的值（http_proxy 等），因为`wget`、`curl` 等命令会读取代理变量发送请求。以上命令集成了上述流程
- 普通用户每次执行都需要验证密码，推荐使用 `sudo`

### 自动更新配置

```bash
clashupdate --auto url
```

- 将命令末尾的 `url` 替换为你的订阅链接，执行一次即可。会新建定时任务，每两天自动下载配置文件（会覆盖）
- 可通过 `crontab -e`  来修改更新频率及订阅链接

### Web 控制台设置密钥（推荐）

步骤参考：[issue#7](https://github.com/nelvko/clash-for-linux-install/issues/7)

### 卸载

恢复如初。

```bash
. uninstall.sh
```

## Tips

### 几种运行方式的区别

**bash 命令运行**

```bash
# 需要有可执行权限
./install.sh

# 不需要可执行权限，需要读权限
bash ./install.sh
```

- 当前 `shell` 开启一个子 `shell` 来执行脚本，对环境的修改仅影响该子 `shell` ，当前 `shell` 不会生效
- 使当前终端生效需要配置代理环境变量，或执行一次 `bash`

**shell 内建命令运行**

```bash
# 不需要可执行权限，需要读权限
. install.sh
source install.sh
```

- 脚本在当前 `shell` 环境中执行，变量和函数的定义对当前 `shell` 有效

## 引用

- [clash-linux-amd64-v3-2023.08.17.gz](https://downloads.clash.wiki/ClashPremium/)
- [Clash Web Dashboard](https://github.com/haishanh/yacd/releases/tag/v0.3.8)
- <a id="ref">[Clash 全家桶下载](https://www.clash.la/releases/)</a>
- [Clash 知识库](https://clash.wiki/)

## Todo

- [x] 定时更新配置
- [ ] [bug / 需求](https://github.com/nelvko/clash-for-linux-install/issues)

## Thanks

[@鑫哥](https://github.com/TrackRay)

## 特别声明

1. 编写本项目主要目的为学习和研究`Shell`编程，不得将本项目中任何内容用于违反国家/地区/组织等的法律法规或相关规定的其他用途。

2. 本项目保留随时对免责声明进行补充或更改的权利，直接或间接使用本项目内容的个人或组织，视为接受本项目的特别声明。