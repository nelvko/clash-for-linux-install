# Linux 一键部署 Clash

## 特别声明

1. 编写本项目主要目的为学习和研究`Shell`编程，不得将本项目中任何内容用于违反国家/地区/组织等的法律法规或相关规定的其他用途。

2. 本项目保留随时对免责声明进行补充或更改的权利，直接或间接使用本项目内容的个人或组织，视为接受本项目的特别声明。

## 前言

基于`Clash`项目作者删库前最新的`Premium`版本。

> 注：文末[引用](#ref)中收集了各种架构的内核和GUI版本。

## 环境要求

- 需要 `root` 权限。
- 基于`bash`的`shell`环境。

## 快速开始

### 一键安装脚本

```bash
git clone https://github.com/nelvko/clash-for-linux-install.git && cd clash-for-linux-install && . install.sh
```
普通用户请使用`sudo ./install.sh`

不懂什么是订阅链接的小白可参考：[issue#1](https://github.com/nelvko/clash-for-linux-install/issues/1)

没有订阅？[click me](https://次元.net/auth/register?code=oUbI)

### Command
以下命令已集成到`bashrc`中，可直接在终端执行。
```bash
# 关闭代理环境
clashoff

# 启动代理环境
clashon

# 打印 ui 地址
clashui

# 手动更新配置文件
clashupdate <url>
```

- 使用 `systemctl` 控制启停后，还需要再修改下代理变量（http_proxy 等），否则会影响正常使用：例`curl`命令无代理环境时走代理发送请求，有代理环境时不走代理。
- 以上命令（函数）集成了上述流程。
- 普通用户每次执行后都需要验证用户密码，推荐使用`sudo`

### 自动更新配置

将命令末尾的`url`替换为你的订阅链接后执行即可，会新建定时任务间隔48h更新一次配置文件。

```bash
xargs -I {} sed -i '/clashupdate/s/url/{}/' /var/spool/cron/root <<< url
```

也可通过`crontab -e` 或`vi /var/spool/cron/root`来修改更新频率及订阅链接。

### 卸载

```bash
. uninstall.sh
```

恢复如初。

普通用户请使用`sudo ./uninstall.sh`

## Tips

### 几种运行方式的区别

**bash 命令运行**

```bash
# 需要有可执行权限
./install.sh

# 不需要可执行权限，需要读权限
bash ./install.sh
```

- 当前 `shell` 开启一个子 `shell` 来执行脚本，对环境的修改仅影响该子 shell 和其子进程，当前 `shell` 不会生效。
- 使当前终端生效需要再配置代理环境变量，或者退出终端重新登录。

**shell 内建命令运行**

```bash
# 不需要可执行权限，需要读权限
. install.sh
source install.sh
```

- 脚本在当前 `shell` 环境中执行，变量和函数的定义对当前 `shell` 有效，无需再设置代理变量或重新登陆。

## 引用

- [clash-linux-amd64-v3-2023.08.17.gz](https://downloads.clash.wiki/ClashPremium/)
- [Clash Dashboard](https://github.com/haishanh/yacd/releases/tag/v0.3.8)
- <a id="ref">[Clash GUI & Core Releases](https://www.clash.la/releases/)</a>
- [Clash 知识库](https://clash.wiki/)

## Todo

- [x] 定时更新配置
- [ ] [bug / 需求](https://github.com/nelvko/clash-for-linux-install/issues)

## Thanks

[@鑫哥](https://github.com/TrackRay)