#!/usr/bin/env bash

clashsecret() {
    case "$1" in
    -h | --help)
        secret_help
        return 0
        ;;
    esac

    case $# in
    0)
        _okcat "Web 访问密钥：$(_get_secret)"
        ;;
    1)
        "$BIN_YQ" -i ".secret = \"$1\"" "$CLASH_CONFIG_MIXIN" || {
            _failcat "密钥更新失败，请重新输入"
            return 1
        }
        _merge_config_restart
        _okcat "密钥更新成功，已重启生效"
        ;;
    *)
        _failcat "参数错误，请使用 -h 查看帮助"
        ;;
    esac
}

secret_help() {
    cat <<EOF

- 查看 Web 密钥
  clashctl secret

- 修改 Web 密钥
  clashctl secret <new_secret>

EOF
}
