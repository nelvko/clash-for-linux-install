# Linux 一键部署 Clash

## 环境要求

- 需要 `root` 用户。
- 自用 CentOS 7.x 生效。

## 安装脚本

```bash
git clone https://github.com/coolapker/clash-for-linux-install.git && cd clash-for-linux-install && . install.sh
```

> 代理加速：<https://mirror.ghproxy.com>

## 卸载

```bash
# 删除 clash 及其配置
# 清除 shell 代理环境
. uninstall.sh
```

## Command

```bash
# 关闭 clash (systemctl stop clash)
# 删除代理变量（http_proxy等）
clashoff

# 打印 ui 地址
clashui

# 启动 clash（同理）
clashon
```

- 直接使用 `systemctl` 控制启停时，当前登陆的 shell 环境需要再修改下代理变量，否则执行某些下载命令时会导致：无代理环境时走代理下载，有代理环境时不走代理。
- 以上命令（函数）集成了上述流程。

## Tips

### 几种运行方式的区别

**bash 命令运行**

```bash
# 需要有可执行权限
./install.sh

# 不需要可执行权限
bash ./install.sh
```

- 当前 shell 开启一个子 shell 来执行脚本，对环境的修改仅影响该子 shell 和其子进程，当前 shell 不会生效。
- 使当前终端生效需要再 `export` 代理环境变量，或者退出终端重新登录。

**shell 内建命令运行**

```bash
# 不需要可执行权限
. install.sh
source install.sh
```

- 脚本在当前 shell 环境中执行，变量和函数的定义对当前 shell 有效，无需再设置代理变量或重新登陆。

## 引用

- [clash-linux-amd64-v3-2023.08.17.gz](https://downloads.clash.wiki/ClashPremium/)
- [Clash Dashboard](https://github.com/haishanh/yacd/releases/tag/v0.3.8)
- [Clash GUI & Core Releases](https://www.clash.la/releases/)
- [Clash 知识库](https://clash.wiki/)

## Todo

- [ ] 定时更新配置
