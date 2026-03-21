#!/usr/bin/env bash

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"

. .env
. scripts/cmd/common.sh

_okcat '🔄' '正在检查更新...'

# 检查安装目录是否存在
[ ! -d "$CLASH_BASE_DIR" ] && {
    _failcat "安装目录不存在：$CLASH_BASE_DIR，请先执行 install.sh"
    exit 1
}

# 停止 failover（如果在运行），记录状态以便更新后恢复
FAILOVER_WAS_RUNNING=false
if [ -f "$CLASH_FAILOVER_PID" ]; then
    pid=$(cat "$CLASH_FAILOVER_PID" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        FAILOVER_WAS_RUNNING=true
        _okcat '🛑' '停止故障转移...'
        kill "$pid" 2>/dev/null
        sleep 1
    fi
    rm -f "$CLASH_FAILOVER_PID"
fi

# 更新脚本文件（保留用户数据：resources/profiles、resources/*.yaml 等）
_okcat '📦' '更新脚本文件...'
/bin/cp -rf scripts "$CLASH_BASE_DIR/"
/bin/cp -f .env "$CLASH_BASE_DIR/.env.new"

# 合并 .env：保留用户已有配置，仅补充新增的配置项
while IFS= read -r line; do
    [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
    key="${line%%=*}"
    grep -qE "^${key}=" "$CLASH_BASE_DIR/.env" || echo "$line" >>"$CLASH_BASE_DIR/.env"
done <"$CLASH_BASE_DIR/.env.new"
rm -f "$CLASH_BASE_DIR/.env.new"

# 重新加载环境变量（使用安装目录的 .env）
. "$CLASH_BASE_DIR/.env"
. "$CLASH_BASE_DIR/scripts/cmd/common.sh"
. scripts/preflight.sh

# 重新应用 init 系统服务配置和 placeholder 替换
_detect_init
_install_service
_okcat '⚙️' '服务配置已更新'

# 重新应用 shell RC
_revoke_rc
_apply_rc
_okcat '🐚' 'Shell 配置已更新'

# 更新 fish 补全（如果存在）
[ -n "$SHELL_RC_FISH" ] && [ -f "$SCRIPT_CMD_FISH" ] && {
    /usr/bin/install "$SCRIPT_CMD_FISH" "$SHELL_RC_FISH"
}

# 重启内核（如果正在运行）
if "${service_is_active[@]}" >&/dev/null; then
    _okcat '🔄' '重启内核以应用更新...'
    "${service_restart[@]}"
    _okcat '✅' '内核已重启'
fi

# 恢复 failover（如果更新前在运行）
if [ "$FAILOVER_WAS_RUNNING" = true ]; then
    . "$CLASH_BASE_DIR/scripts/cmd/clashctl.sh"
    if [ -f "$CLASH_FAILOVER_ARGS" ]; then
        _okcat '🔄' '恢复故障转移...'
        eval "clashsub failover on $(cat "$CLASH_FAILOVER_ARGS")"
    else
        _okcat '🔄' '恢复故障转移（默认参数）...'
        clashsub failover on
    fi
fi

_okcat '🎉' '更新完成！'
