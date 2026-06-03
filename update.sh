#!/usr/bin/env bash

# 源码侧更新入口：在 git 克隆目录中 `git pull` 后执行 `bash update.sh`，
# 把最新脚本/资源非破坏式部署到已安装的 $CLASHCTL_HOME，订阅与配置保留。
# 对应的就地命令为 `clashctl update`（自动从 GitHub 拉取，无需手动 git pull）。

CLASHCTL_SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
. "$CLASHCTL_SRC/scripts/preflight.sh"

valid_required
deploy_clashctl "$@"
