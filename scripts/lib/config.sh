#!/usr/bin/env bash

_get_bind_addr() {
  local allow_lan bind_addr
  IFS='|' read -r bind_addr allow_lan < <(
    "$BIN_YQ" '[.bind-address // "*", .allow-lan // false] | join("|")' "$CLASH_CONFIG_RUNTIME"
  )

  case $allow_lan in
  true)
    [ "$bind_addr" = "*" ] && bind_addr=$(_get_local_ip)
    ;;
  false)
    bind_addr=127.0.0.1
    ;;
  esac
  printf '%s\n' "$bind_addr"
}

_detect_proxy_port() {
  local mixed_port http_port socks_port
  IFS='|' read -r mixed_port http_port socks_port < <(
    "$BIN_YQ" '[.mixed-port // "", .port // "", .socks-port // ""] | join("|")' "$CLASH_CONFIG_RUNTIME"
  )

  [ -z "$mixed_port" ] && [ -z "$http_port" ] && [ -z "$socks_port" ] && mixed_port=7890

  local count=0
  local service_active=false
  service_is_active >&/dev/null && service_active=true

  local entries=(
    "mixed-port:$mixed_port"
    "port:$http_port"
    "socks-port:$socks_port"
  )

  local entry yaml_key port new_port
  for entry in "${entries[@]}"; do
    yaml_key=${entry%%:*}
    port=${entry#*:}

    [ -n "$port" ] && _is_port_used "$port" && [ "$service_active" != "true" ] && {
      new_port=$(_get_random_port) || return
      count=$((count + 1))
      _failcat '🎯' "端口冲突：[$yaml_key] $port 🎲 随机分配 $new_port"
      "$BIN_YQ" -i ".${yaml_key} = $new_port" "$CLASH_CONFIG_MIXIN"
    }
  done

  [ "$count" -gt 0 ] && _merge_config
}

_detect_ext_addr() {
  local ext_addr
  ext_addr=$("$BIN_YQ" '.external-controller // ""' "$CLASH_CONFIG_RUNTIME")

  local ext_ip=${ext_addr%%:*}
  local ext_port=${ext_addr##*:}

  EXT_IP=$ext_ip
  EXT_PORT=$ext_port
  [ "$ext_ip" = '0.0.0.0' ] && EXT_IP=$(_get_local_ip)

  local service_active=false
  service_is_active >&/dev/null && service_active=true

  _is_port_used "$EXT_PORT" && [ "$service_active" != "true" ] && {
    local new_port
    new_port=$(_get_random_port) || return
    _failcat '🎯' "端口冲突：[external-controller] ${EXT_PORT} 🎲 随机分配 $new_port"
    EXT_PORT=$new_port
    EXT_ADDR="$ext_ip:$new_port" "$BIN_YQ" -i '.external-controller = env(EXT_ADDR)' "$CLASH_CONFIG_MIXIN"
    _merge_config
  }
}

_get_secret() {
  "$BIN_YQ" '.secret // ""' "$CLASH_CONFIG_RUNTIME"
}

_valid_config() {
  local config="$1"
  [[ ! -e "$config" || "$(wc -l <"$config")" -lt 1 ]] && return 1

  local test_log
  test_log=$("$BIN_KERNEL" -d "$(dirname "$config")" -f "$config" -t 2>&1) || {
    printf '%s\n' "$test_log" >&2
    grep -qs "unsupport proxy type" <<<"$test_log" && {
      local prefix="检测到订阅中包含不受支持的代理协议"
      if [ "$CLASHCTL_KERNEL" = "clash" ]; then
        _errorcat "${prefix}, 推荐安装使用 mihomo 内核"
      else
        _errorcat "${prefix}, 请检查并升级内核版本"
      fi
    }
    return 1
  }
}

_merge_config() {
  cat "$CLASH_CONFIG_RUNTIME" >"$CLASH_CONFIG_TEMP" 2>/dev/null
  # shellcheck disable=SC2016
  "$BIN_YQ" eval-all '
      ########################################
      #              Load Files              #
      ########################################
      select(fileIndex==0) as $config |
      select(fileIndex==1) as $mixin |

      ########################################
      #              Deep Merge              #
      ########################################
      $mixin |= del(._custom) |
      (($config // {}) * $mixin) as $runtime |
      $runtime |

      ########################################
      #               Rules                  #
      ########################################
      .rules = (
        ($mixin.rules.prepend // []) +
        ($config.rules // []) +
        ($mixin.rules.append // [])
      ) |

      ########################################
      #                Proxies               #
      ########################################
      .proxies = (
        ($mixin.proxies.prepend // []) +
        (
          ($config.proxies // []) as $configList |
          ($mixin.proxies.override // []) as $overrideList |
          $configList | map(
            . as $configItem |
            (
              $overrideList[] | select(.name == $configItem.name)
            ) // $configItem
          )
        ) +
        ($mixin.proxies.append // [])
      ) |

      ########################################
      #             ProxyGroups              #
      ########################################
      .proxy-groups = (
        ($mixin.proxy-groups.prepend // []) +
        (
          ($config.proxy-groups // []) as $configList |
          ($mixin.proxy-groups.override // []) as $overrideList |
          $configList | map(
            . as $configItem |
            (
              $overrideList[] | select(.name == $configItem.name)
            ) // $configItem
          )
        ) +
        ($mixin.proxy-groups.append // [])
      ) |

      ########################################
      #         ProxyGroups Inject           #
      ########################################
      ($mixin.proxy-groups.inject // {}) as $inj |
      .proxy-groups[] |= (
        . as $g |
        ($inj | .[$g.name] // []) as $extra |
        .proxies = (.proxies + $extra | unique)
      )
    ' "$CLASH_CONFIG_BASE" "$CLASH_CONFIG_MIXIN" >"$CLASH_CONFIG_RUNTIME"

  _valid_config "$CLASH_CONFIG_RUNTIME" || {
    cat "$CLASH_CONFIG_TEMP" >"$CLASH_CONFIG_RUNTIME"
    _errorcat "验证失败：请检查 Mixin 配置"
  }
}
tunstatus() {
  local device
  device=$("$BIN_YQ" '.tun.device // ""' "$CLASH_CONFIG_RUNTIME")
  [ -z "$device" ] && device="Meta"
  { if _is_macos; then ifconfig; else ip link show; fi; } 2>/dev/null | grep -qs "$device" && {
    _okcat 'Tun 状态：启用'
    return 0
  }
  _failcat 'Tun 状态：关闭'
  return 1
}
_is_tun_enabled() {
  "$BIN_YQ" -e '.tun.enable == true' "$CLASH_CONFIG_RUNTIME" >&/dev/null
}
_merge_config_restart() {
  local was_tun_active tun_enabled

  tunstatus >&/dev/null && was_tun_active=true
  _merge_config || return
  _is_tun_enabled && tun_enabled=true

  if [ "${was_tun_active}" = true ]; then
    service_sudo_stop >/dev/null
    service_is_active >&/dev/null && {
      _errorcat "请先关闭 Tun 模式"
      return
    }
  else
    service_stop >&/dev/null
  fi

  sleep 0.1

  if [ "${tun_enabled}" = true ]; then
    service_sudo_start >/dev/null
    sleep 1
    tunstatus >&/dev/null || _errorcat "Tun 模式重启失败，请检查代理内核日志" || return
  else
    service_start >/dev/null

  fi
}
