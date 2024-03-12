
# Linux一键部署clash
> 
- 下载
```bash
git clone https://github.com/coolapker/clash-for-linux-install.git
```
- 可执行权限
```bash
cd clash-for-linux-install && chmod +x install.sh uninstall.sh
```
- 部署
```bash
. install.sh
```

## Command
```bash
# 关闭clash（systemctl stop clash）
# 删除代理变量（http_proxy等）
clashoff

# 打印ui地址
clashui

# 启动clash（同理）
clashon

# 卸载clash（项目根目录下）
# 当前shell恢复如初
. uninstall.sh
```
- 当前登录的 shell 环境可用。
- 不要直接使用`systemctl`控制启停！！！（没有修改环境变量，导致某些命令该走代理的不走，不该走的走）

## Tips
```bash
. install.sh
```
- 脚本在当前 shell 环境中执行，变量和函数的定义对当前 shell 有效。


```bash
./install.sh
```
- 当前 shell 开启一个子 shell 来执行脚本，对环境的修改仅影响该子 shell 和其子进程，当前 shell 不会生效
- wget等命令不走代理，需要退出终端重新登录生效
## Todo
- [ ] 定时更新配置
  

