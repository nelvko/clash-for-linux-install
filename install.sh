#!/usr/bin/env bash

. scripts/cmd/clashctl.sh
. scripts/preflight.sh

_valid
_parse_args "$@"

_prepare_zip
_detect_init

_okcat "安装内核：$KERNEL_NAME by ${INIT_TYPE}"
_okcat '📦' "安装路径：$CLASH_BASE_DIR"

/bin/cp -rf . "$CLASH_BASE_DIR"
touch "$CLASH_CONFIG_BASE"
_set_envs
_is_regular_sudo && chown -R "$SUDO_USER" "$CLASH_BASE_DIR"

_install_service
_apply_rc


_merge_config
_detect_proxy_port
clashui
clashsecret "$(_get_random_val)" >/dev/null
clashsecret

command -v go >/dev/null && {
  _okcat '🔧' '检测到 Go，正在构建 clashtui...'
  (
    cd "$CLASH_BASE_DIR/clashtui" &&
      GOPROXY="${GOPROXY:-https://goproxy.cn,direct}" go build -o "$BIN_BASE_DIR/clashtui" ./cmd/clashtui
  ) || {
    _failcat "clashtui 构建失败（可稍后手动构建）：cd $CLASH_BASE_DIR/clashtui && GOPROXY=\"https://goproxy.cn,direct\" go build -o $BIN_BASE_DIR/clashtui ./cmd/clashtui"
  }
}

_okcat "运行 TUI：clashtui（需先执行 clashon）"

_okcat '🎉' 'enjoy 🎉'
clashctl

_valid_config "$CLASH_CONFIG_BASE" && CLASH_CONFIG_URL="file://$CLASH_CONFIG_BASE"
_quit "clashsub add $CLASH_CONFIG_URL && clashsub use 1"
