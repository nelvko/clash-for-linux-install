#!/usr/bin/env bash

clashhelp() {
  cat <<EOF

Usage:
  clashctl COMMAND [OPTIONS]

Commands:
  on                    启用当前终端代理，自动启动内核
  off                   关闭当前终端代理，保留内核运行
  start                 仅启动内核
  stop                  仅停止内核
  status                内核状态
  ui                    面板地址
  sub                   订阅管理
  node                  节点切换
  tun                   Tun 模式
  mixin                 Mixin 配置
  secret                Web 密钥
  log                   查看日志
  upgrade               升级内核
  update                更新 clashctl

Global Options:
  -h, --help            显示帮助信息

For more help on how to use clashctl, head to https://github.com/nelvko/clash-for-linux-install
EOF
}
