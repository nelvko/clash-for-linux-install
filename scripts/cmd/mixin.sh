#!/usr/bin/env bash

clashmixin() {
    case "$1" in
    -h | --help)
        mixin_help
        return 0
        ;;
    -e)
        "${EDITOR:-vim}" "$CLASH_CONFIG_MIXIN" && {
            _merge_config_restart && _okcat "配置更新成功，已重启生效"
        }
        ;;
    -r)
        less "$CLASH_CONFIG_RUNTIME"
        ;;
    -c)
        less "$CLASH_CONFIG_BASE"
        ;;
    *)
        less "$CLASH_CONFIG_MIXIN"
        ;;
    esac
}

mixin_help() {
    cat <<EOF

- 查看 Mixin 配置：$CLASH_CONFIG_MIXIN
  clashctl mixin

- 编辑 Mixin 配置
  clashctl mixin -e

- 查看原始订阅配置：$CLASH_CONFIG_BASE
  clashctl mixin -c

- 查看运行时配置：$CLASH_CONFIG_RUNTIME
  clashctl mixin -r

EOF
}
