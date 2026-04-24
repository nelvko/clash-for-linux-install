#!/usr/bin/env bash

clashupgrade() {
    local arg channel="" log_flag=false
    for arg in "$@"; do
        case $arg in
        -h | --help)
            help
            return 0
            ;;
        -v | --verbose)
            log_flag=true
            ;;
        -r | --release)
            channel="release"
            ;;
        -a | --alpha)
            channel="alpha"
            ;;
        *)
            channel=""
            ;;
        esac
    done

    _detect_ext_addr
    service_is_active >&/dev/null || service_start >/dev/null
    _okcat '⏳' "请求内核升级..."

    local follow_pid=
    if [ "$log_flag" = true ]; then
        service_follow_log &
        follow_pid=$!
    fi

    local res
    res=$(
        curl -X POST \
            --silent \
            --noproxy "*" \
            --location \
            -H "Authorization: Bearer $(_get_secret)" \
            "http://${EXT_IP}:${EXT_PORT}/upgrade?channel=$channel"
    )

    [ -n "$follow_pid" ] && kill "$follow_pid" >/dev/null 2>&1

    grep '"status":"ok"' <<<"$res" && {
        _okcat "内核升级成功"
        return 0
    }
    grep 'already using latest version' <<<"$res" && {
        _okcat "已是最新版本"
        return 0
    }
    _failcat "内核升级失败，请检查网络或稍后重试"
}

help() {
    cat <<EOF
Usage:
  clashctl upgrade [OPTIONS]

Options:
  -v, --verbose       输出内核升级日志
  -r, --release       升级至稳定版
  -a, --alpha         升级至测试版
  -h, --help          显示帮助信息

EOF
}
