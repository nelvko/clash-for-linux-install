#!/usr/bin/env bash

traffic_python() {
    if [ -n "${CLASHCTL_TRAFFIC_PYTHON:-}" ]; then
        [ -x "$CLASHCTL_TRAFFIC_PYTHON" ] || return 1
        printf '%s\n' "$CLASHCTL_TRAFFIC_PYTHON"
        return 0
    fi
    command -v python3 2>/dev/null || command -v python 2>/dev/null
}

traffic_script() {
    printf '%s/scripts/traffic/traffic.py\n' "$CLASHCTL_HOME"
}

traffic_state_dir() {
    local root=${XDG_STATE_HOME:-${HOME}/.local/state}
    printf '%s/clashctl\n' "$root"
}

traffic_port() {
    printf '%s\n' "${CLASHCTL_TRAFFIC_PORT:-8765}"
}

traffic_interval() {
    printf '%s\n' "${CLASHCTL_TRAFFIC_INTERVAL:-5}"
}

traffic_validate_port() {
    local port=$1
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1024 ] && [ "$port" -le 65535 ] && return 0
    _errorcat '端口必须是 1024-65535 之间的整数'
}

traffic_validate_interval() {
    local interval=$1
    awk -v value="$interval" 'BEGIN { exit !(value ~ /^[0-9]+([.][0-9]+)?$/ && value >= 1) }' && return 0
    _errorcat '采样间隔必须是大于等于 1 的数字'
}

traffic_health() {
    local port=$1
    curl --silent --show-error --fail --max-time 1 \
        "http://127.0.0.1:${port}/api/health" >/dev/null 2>&1
}

traffic_require_runtime() {
    local python
    python=$(traffic_python) || {
        _errorcat '系统未找到 python3，无法启动流量采集器'
        return 1
    }
    "$python" -c 'import sys; raise SystemExit(sys.version_info < (3, 10))' || {
        _errorcat '流量统计需要 Python 3.10 或更高版本'
        return 1
    }
    [ -f "$(traffic_script)" ] || {
        _errorcat "流量组件不存在：$(traffic_script)"
        return 1
    }
    printf '%s\n' "$python"
}

traffic_python_run() {
    local python=$1
    shift
    "$python" "$(traffic_script)" "$@"
}

traffic_start() {
    local interval=$(traffic_interval)
    local port=$(traffic_port)
    while [ $# -gt 0 ]; do
        case "$1" in
        --interval)
            [ $# -ge 2 ] || { _errorcat '--interval 需要一个秒数'; return 2; }
            interval=$2
            shift 2
            ;;
        --port)
            [ $# -ge 2 ] || { _errorcat '--port 需要一个端口'; return 2; }
            port=$2
            shift 2
            ;;
        -h|--help)
            traffic_help
            return 0
            ;;
        *)
            _errorcat "未知选项：$1"
            return 2
            ;;
        esac
    done

    traffic_validate_port "$port" || return 2
    traffic_validate_interval "$interval" || return 2

    local python
    python=$(traffic_require_runtime) || return
    local state_dir=$(traffic_state_dir)
    local log_path="$state_dir/traffic.log"
    mkdir -p "$state_dir"
    chmod 700 "$state_dir"

    if traffic_python_run "$python" status --state-dir "$state_dir" >/dev/null 2>&1; then
        traffic_health "$port" && {
            _okcat "流量采集器已运行：http://127.0.0.1:${port}"
            return 0
        }
        _errorcat "流量采集器进程已运行，但端口 ${port} 的仪表盘不可用；请先执行 clashctl traffic stop"
        return 1
    fi

    nohup "$python" "$(traffic_script)" serve \
        --config-path "$CLASH_CONFIG_RUNTIME" \
        --state-dir "$state_dir" \
        --host 127.0.0.1 \
        --port "$port" \
        --interval "$interval" \
        >>"$log_path" 2>&1 < /dev/null &

    local attempt=0
    while [ "$attempt" -lt 50 ]; do
        if traffic_python_run "$python" status --state-dir "$state_dir" >/dev/null 2>&1 \
            && traffic_health "$port"; then
            _okcat "流量采集器已启动：http://127.0.0.1:${port}"
            return 0
        fi
        sleep 0.1
        attempt=$((attempt + 1))
    done

    traffic_python_run "$python" stop --state-dir "$state_dir" >/dev/null 2>&1 || true
    _errorcat "流量采集器启动失败，请检查日志：$log_path"
    return 1
}

traffic_stop() {
    local python
    python=$(traffic_require_runtime) || return
    traffic_python_run "$python" stop --state-dir "$(traffic_state_dir)"
    local attempt=0
    while [ "$attempt" -lt 30 ]; do
        traffic_python_run "$python" status --state-dir "$(traffic_state_dir)" >/dev/null 2>&1 || {
            _okcat '流量采集器已停止'
            return 0
        }
        sleep 0.1
        attempt=$((attempt + 1))
    done
    _errorcat '流量采集器停止请求已发送，但进程仍在运行'
    return 1
}

traffic_status() {
    local python
    python=$(traffic_require_runtime) || return
    traffic_python_run "$python" status --state-dir "$(traffic_state_dir)"
}

traffic_ui() {
    local port=$(traffic_port)
    local previous=
    for previous in "$@"; do
        if [ "${expect_port:-false}" = true ]; then
            port=$previous
            expect_port=false
            continue
        fi
        [ "$previous" = --port ] && expect_port=true
    done
    traffic_start "$@" || return
    cat <<EOF

流量仪表盘已启动：
  本机访问：http://127.0.0.1:${port}

远程访问（在本地终端建立 SSH 隧道）：
  ssh -F ~/.ssh/config.server-mesh -N -L ${port}:127.0.0.1:${port} <mesh-host>
  然后打开：http://127.0.0.1:${port}

EOF
}

traffic_report() {
    local python
    python=$(traffic_require_runtime) || return
    local since=${1:-today}
    traffic_python_run "$python" report --state-dir "$(traffic_state_dir)" --since "$since"
}

traffic_live() {
    local python
    python=$(traffic_require_runtime) || return
    traffic_python_run "$python" live --state-dir "$(traffic_state_dir)"
}

traffic_export() {
    local python
    python=$(traffic_require_runtime) || return
    local since=today
    local until=
    while [ $# -gt 0 ]; do
        case "$1" in
        --since)
            [ $# -ge 2 ] || { _errorcat '--since 需要一个时间范围'; return 2; }
            since=$2
            shift 2
            ;;
        --until)
            [ $# -ge 2 ] || { _errorcat '--until 需要一个时间范围'; return 2; }
            until=$2
            shift 2
            ;;
        -h|--help)
            traffic_help
            return 0
            ;;
        *)
            _errorcat "未知选项：$1"
            return 2
            ;;
        esac
    done
    if [ -n "$until" ]; then
        traffic_python_run "$python" export --state-dir "$(traffic_state_dir)" --since "$since" --until "$until"
    else
        traffic_python_run "$python" export --state-dir "$(traffic_state_dir)" --since "$since"
    fi
}

clashtraffic() {
    case "${1:-status}" in
    start)
        shift
        traffic_start "$@"
        ;;
    stop)
        shift
        traffic_stop "$@"
        ;;
    status)
        shift
        traffic_status "$@"
        ;;
    ui|open)
        shift
        traffic_ui "$@"
        ;;
    today)
        shift
        traffic_report today "$@"
        ;;
    top|report)
        shift
        traffic_report "${1:-today}"
        ;;
    live)
        shift
        traffic_live "$@"
        ;;
    export)
        shift
        traffic_export "$@"
        ;;
    -h|--help|help)
        traffic_help
        ;;
    *)
        traffic_help
        return 2
        ;;
    esac
}

traffic_help() {
    cat <<EOF

clashctl traffic - 代理流量采集与仪表盘

Usage:
  clashctl traffic COMMAND [OPTIONS]

Commands:
  start [--interval SEC] [--port PORT] 启动本地采集器与仪表盘
  stop                              停止采集器
  status                            查看采集器状态
  ui                                启动并显示仪表盘访问方式
  today                             查看今天的身份流量汇总
  top [RANGE]                       查看指定范围的身份流量排行
  live                              查看最近一次采样的活跃连接
  export [OPTIONS]                  导出 CSV

Export options:
  --since RANGE                     today、24h、7d 或 ISO-8601 时间
  --until RANGE                     结束时间（默认 now）

安全边界：仪表盘只监听 127.0.0.1；统计只保存身份与字节增量，不保存目标地址或流量内容。
EOF
}
