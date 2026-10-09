# 使用指南

[返回 README](../README.md)

## 安装选项

在线安装时，选项写在 `bash -s --` 后；从源码安装时，写在 `bash install.sh` 后。

| 参数 | 说明 |
| --- | --- |
| `--kernel <mihomo\|clash>` | 选择内核，新安装默认使用 Mihomo；已有安装不支持切换内核 |
| `--subscription <URL>` | 添加并启用订阅，跳过订阅的交互输入 |
| `--install-dir <绝对路径>` | 指定安装目录，优先于 `CLASHCTL_HOME`，默认 `~/.clashctl` |
| `--gh-proxy <URL>` | 为后续源码和组件下载设置 GitHub 加速前缀；`--gh-proxy=` 表示直连 |
| `--local` | 使用安装脚本所在目录的源码，依赖仍按需下载；不支持管道输入 |

例如，指定安装目录和订阅：

```bash
curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/nelvko/clash-for-linux-install/master/install.sh | \
  bash -s -- --install-dir "$HOME/apps/clashctl" --subscription "<订阅链接>" --gh-proxy https://gh-proxy.org
```

安装目录必须是绝对路径，只能包含字母、数字、`_`、`.`、`/` 和 `-`。

### 直连安装

如果可以直接访问 GitHub：

```bash
curl -fsSL https://raw.githubusercontent.com/nelvko/clash-for-linux-install/master/install.sh | \
  bash -s -- --gh-proxy=
```

入口脚本的下载地址与 `--gh-proxy` 分别控制脚本下载和后续下载。指定空值可清除已有的代理配置。

### 从源码安装

```bash
git clone --depth 1 --branch master https://gh-proxy.org/https://github.com/nelvko/clash-for-linux-install.git
cd clash-for-linux-install
bash install.sh --local --gh-proxy https://gh-proxy.org
```

也可在本地安装时指定内核和订阅：

```bash
bash install.sh --local --kernel clash --subscription "<订阅链接>" --gh-proxy https://gh-proxy.org
```

本地安装仍会将程序安装到目标目录；目标目录不能位于源码目录内。安装结束后按提示加载命令，或重新打开终端。

## 代理与内核

| 命令 | 作用 |
| --- | --- |
| `clashctl on` | 启用当前终端代理，内核未运行时自动启动 |
| `clashctl off` | 清除当前终端代理变量，内核继续运行 |
| `clashctl start` / `clashctl stop` | 只启动 / 停止内核 |
| `clashctl status` / `clashctl log` | 查看内核状态 / 日志 |
| `clashctl node` | 选择节点 |
| `clashctl tun` | 管理 TUN 模式 |
| `clashctl ui` | 查看 Web 面板地址 |
| `clashctl secret` | 查看面板登录密钥 |

`on` / `off` 设置或清除当前 Shell 的代理环境变量。Web 面板地址以 `clashctl ui` 输出为准；新安装会生成随机登录密钥，用 `clashctl secret` 查看。

`on` / `off` 只接受 `-h` / `--help`；旧版 `-e` / `--env-only` 和 `-s` / `--service-only` 选项已移除。仅启停内核请使用 `start` / `stop`；需要同时停止内核并清除当前终端代理时，先执行 `clashctl stop`，再执行 `clashctl off`。

## 订阅与配置

### 管理多个订阅

```bash
clashctl sub add --name mysub --use "<订阅链接>"  # 添加并启用
clashctl sub ls                                # 查看已保存的订阅
clashctl sub use mysub                         # 切换订阅
clashctl sub update                            # 更新当前订阅
clashctl sub update --all                      # 更新全部订阅
```

`clashctl sub` 可交互选择订阅。添加订阅时省略 `--use` 只保存，不启用；省略 URL 则交互输入。更多选项见 `clashctl sub --help` 和 `clashctl sub add --help`。

### 使用本地 YAML

除 HTTP(S) 链接外，也支持本地 Clash / Mihomo YAML：

```bash
clashctl sub add --name local --raw --use "file://$PWD/a.yaml"
```

`file://` 后必须是绝对路径，`file://./a.yaml` 不受支持。安装器的 `--subscription` 也接受本地文件 URL。`--raw` 跳过订阅转换，仅对本次操作生效。

### 保留自定义配置

订阅更新后会重新生成运行配置。需要持久保留的修改，请写入 Mixin：

```bash
clashctl mixin -e        # 编辑自定义配置，保存后合并并重启生效
clashctl mixin -c        # 查看原始订阅配置
clashctl mixin -r        # 查看运行配置
```

编辑器由 `EDITOR` 环境变量指定，默认使用 `vim`。

## 更新与迁移

### 日常更新

```bash
clashctl update         # 更新脚本与资源，保留用户配置和内核
clashctl upgrade        # 通过内核 API 请求升级
```

内核升级是否可用取决于所选内核，更多选项见 `clashctl upgrade --help`。

源码下载与脚本更新跟踪安装目录 `.env` 中的 `CLASHCTL_UPDATE_BRANCH`，新安装默认为 `master`。入口脚本 URL 中的分支只选择安装器；试用其他分支时，需要同时指定 `CLASHCTL_UPDATE_BRANCH`。

从其他分支切换到正式版时，先将 `.env` 中的 `CLASHCTL_UPDATE_BRANCH` 改为 `master`，再运行 `clashctl update`。

### 从旧版迁移

安装器会识别旧版目录并迁移订阅和配置。

旧版安装在 `~/clashctl`、且 `~/.clashctl` 尚不存在时，可迁移到新默认目录：

```bash
curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/nelvko/clash-for-linux-install/master/install.sh | \
  bash -s -- --install-dir "$HOME/.clashctl" --gh-proxy https://gh-proxy.org
```

沿原路径升级时，将 `--install-dir` 改为实际旧目录，自定义路径也适用：

```bash
curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/nelvko/clash-for-linux-install/master/install.sh | \
  bash -s -- --install-dir /absolute/path/to/clashctl --gh-proxy https://gh-proxy.org
```

迁移可能短暂重启内核。旧目录会保留为同级的 `.bak.*` 备份，其中可能含订阅凭据和访问密钥；确认不再需要后再清理。搬迁目录后，记得修改写死旧路径的定时任务。

安装失败按安装器输出的命令重试；迁移失败时核对旧目录与服务是否已恢复。成功迁移后需要退回旧版，先保存新版新增数据，再按[回退步骤](rollback-install-update.md)恢复旧目录、服务和 Shell 引导。

## 卸载

需要保留订阅和配置时，请先备份安装目录，再运行：

```bash
clashctl off
bash "$CLASHCTL_HOME/uninstall.sh"
```

默认安装且尚未加载命令时，也可运行 `bash ~/.clashctl/uninstall.sh`；自定义安装则使用实际路径。

卸载会停止内核、移除本项目的服务与 Shell 引导，并删除整个安装目录，包括订阅、自定义配置、内核和日志。
