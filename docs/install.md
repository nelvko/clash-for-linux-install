# 安装与迁移

README 中的安装命令默认使用 `master`，安装到 `~/.clashctl`。安装完成后重新打开终端。

## 安装选项

- 自定义目录：在管道右侧的 `bash` 前设置 `CLASHCTL_HOME=/absolute/path`。路径必须是绝对路径，只能包含字母、数字、`_`、`.`、`/`、`-`。
- 不需要 GitHub 下载加速：去掉 `--gh-proxy https://gh-proxy.org`。这个参数只影响安装器后续的源码和组件下载；管道左侧的 `curl` 仍需能访问 `raw.githubusercontent.com`。
- 本地源码验证：在源码目录运行 `bash install.sh --local`。内核和依赖仍会按需下载，后续更新使用 `.env` 中保存的远端分支。

脚本 URL 中的分支只决定下载哪个 `install.sh`。安装源码和后续更新由 `CLASHCTL_UPDATE_BRANCH` 决定；新安装默认跟踪 `master`。

## 从旧版迁移

安装器会识别旧版目录，迁移订阅、配置和兼容的运行数据。当前终端若导出了 `CLASHCTL_HOME`，会在该路径升级；未设置时使用新默认目录 `~/.clashctl`。

若旧版位于 `~/clashctl`，希望搬到新默认目录：

```bash
curl -fsSL https://raw.githubusercontent.com/nelvko/clash-for-linux-install/master/install.sh | env -u CLASHCTL_HOME bash -s -- --gh-proxy https://gh-proxy.org
```

希望沿用旧路径，或旧版装在自定义目录：

```bash
curl -fsSL https://raw.githubusercontent.com/nelvko/clash-for-linux-install/master/install.sh | CLASHCTL_HOME=/absolute/path/to/clashctl bash -s -- --gh-proxy https://gh-proxy.org
```

`CLASHCTL_HOME` 要传给管道右侧的 `bash`。迁移成功后，旧目录保留为同级的 `.bak.*` 备份，里面可能有订阅凭据和访问密钥。有有效主配置时，迁移可能重启内核，代理会短暂中断。若定时任务写死了旧目录路径，搬迁后需要手动更新。

迁移会短暂等待旧版订阅写入结束；超时则中止并提示重试。迁移期间不要再次启动旧版订阅更新。若提示“无法安全确认”旧目录，请核对属主和脚本内容；确认是自己的旧安装后，移除该目录及 `scripts/` 的组和其他用户写权限，再重试。安装器不会代为修改权限。迁移失败会尽力恢复旧目录与服务；若提示恢复失败，请保留现场，检查备份和服务。

## 更新与卸载

`clashctl update` 更新程序，`clashctl upgrade` 更新内核。程序更新使用安装目录 `.env` 中的 `CLASHCTL_UPDATE_BRANCH` 和 `GH_PROXY`。从其他分支安装的用户会继续跟踪已保存的分支；转到正式版时，将 `CLASHCTL_UPDATE_BRANCH` 显式改为 `master` 后再更新。

旧版 `on/off -s`、`on/off -e` 暂时兼容。新版 `off` 只关闭当前终端代理；停止内核请运行 `clashctl stop`。

卸载脚本会显示删除路径并请求确认，且会删除订阅、配置、内核和日志。需要保留数据时，先备份安装目录的 `.env` 和 `data/`；运行缓存位于 `resources/cache.db`。迁移留下的 `.bak.*` 不属于当前安装，确认不再需要后可自行清理。
