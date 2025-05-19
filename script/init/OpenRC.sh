#!/sbin/openrc-run
# shellcheck disable=SC2034

# 服务元数据
name="placeholder_kernel_name"
description="placeholder_kernel_desc"

command="placeholder_cmd_path"
command_args="placeholder_cmd_args"
pidfile="placeholder_pid_file"

command_background=true

# 依赖关系
depend() {
    after network localmount
    need net
}

# 自定义启动前检查

# 启动操作

# 停止操作（可选自定义）
stop_post() {
    rm -f "placeholder_pid_file"
}

# 日志管理（可选）
#logger="logger -t clash"
