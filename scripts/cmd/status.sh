#!/usr/bin/env bash

# shellcheck disable=SC1091  # 独立 source（测试）时补载依赖；经 clashctl.sh 加载时已存在。
declare -F _clashctl_run_in_bash >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../lib/shell.sh"

function clashstatus() {
    if ! _clashctl_in_bash; then
        _clashctl_run_in_bash clashstatus "$@"
        return
    fi
    service_status "$@"
    service_is_active >&/dev/null
}
