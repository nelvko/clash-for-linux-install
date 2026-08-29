#!/usr/bin/env bash

_get_bind_addr() {
  local allow_lan bind_addr bind_values
  bind_values=$(
    "$BIN_YQ" '[.bind-address // "*", .allow-lan // false] | join("|")' \
      "$CLASH_CONFIG_RUNTIME"
  ) || {
    _ui_error '无法读取运行配置中的监听地址'
    return 1
  }
  IFS='|' read -r bind_addr allow_lan <<<"$bind_values"

  case $allow_lan in
  true)
    if [ "$bind_addr" = "*" ]; then
      bind_addr=$(_get_local_ip)
      [ -n "$bind_addr" ] || {
        _ui_error '无法确定局域网监听地址'
        return 1
      }
    fi
    ;;
  false)
    bind_addr=127.0.0.1
    ;;
  esac
  printf '%s\n' "$bind_addr"
}

_detect_proxy_port() {
  local mixed_port http_port socks_port port_values
  port_values=$(
    "$BIN_YQ" '[.mixed-port // "", .port // "", .socks-port // ""] | join("|")' \
      "$CLASH_CONFIG_RUNTIME"
  ) || {
    _ui_error '无法读取运行配置中的代理端口'
    return 1
  }
  IFS='|' read -r mixed_port http_port socks_port <<<"$port_values"

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

    if [ -n "$port" ] && _is_port_used "$port" && [ "$service_active" != "true" ]; then
      new_port=$(_get_random_port) || return 1
      count=$((count + 1))
      _ui_warn "端口冲突：[$yaml_key] $port；已随机分配 $new_port"
      "$BIN_YQ" -i ".${yaml_key} = $new_port" "$CLASH_CONFIG_MIXIN" || {
        _ui_error "无法写入随机代理端口：$yaml_key"
        return 1
      }
    fi
  done

  if [ "$count" -gt 0 ] && ! _merge_config; then
    _ui_error '代理端口已调整，但运行配置更新失败'
    return 1
  fi
  return 0
}

_detect_ext_addr() {
  local ext_addr listen_host='' ext_ip='' ext_port='' display_ip
  ext_addr=$("$BIN_YQ" '.external-controller // ""' "$CLASH_CONFIG_RUNTIME") || {
    _ui_error '无法读取运行配置中的控制器地址'
    return 1
  }

  if [[ $ext_addr =~ ^(\[[0-9A-Fa-f:.]+\]):([0-9]+)$ ]]; then
    listen_host=${BASH_REMATCH[1]}
    ext_port=${BASH_REMATCH[2]}
    ext_ip=${listen_host#\[}
    ext_ip=${ext_ip%\]}
    [[ $ext_ip == *:* ]] || ext_ip=
  elif [[ $ext_addr =~ ^([A-Za-z0-9._-]+):([0-9]+)$ ]]; then
    listen_host=${BASH_REMATCH[1]}
    ext_ip=$listen_host
    ext_port=${BASH_REMATCH[2]}
  fi
  if [ -z "$ext_ip" ] || [ -z "$ext_port" ] || [ "${#ext_port}" -gt 5 ] ||
    ((10#$ext_port < 1 || 10#$ext_port > 65535)); then
    _ui_error '运行配置中的控制器地址无效（应为 hostname/IPv4:port 或 [IPv6]:port）'
    return 1
  fi
  ext_port=$((10#$ext_port))

  display_ip=$ext_ip
  case $ext_ip in
  0.0.0.0 | ::)
    display_ip=$(_get_local_ip) || display_ip=
    [ -n "$display_ip" ] || {
      _ui_error '无法确定控制器的本机访问地址'
      return 1
    }
    ;;
  esac

  local service_active=false
  service_is_active >&/dev/null && service_active=true

  if _is_port_used "$ext_port" && [ "$service_active" != "true" ]; then
    local new_port
    new_port=$(_get_random_port) || return 1
    _ui_warn "端口冲突：[external-controller] ${ext_port}；已随机分配 $new_port"
    EXT_ADDR="${listen_host}:$new_port" "$BIN_YQ" -i \
      '.external-controller = env(EXT_ADDR)' "$CLASH_CONFIG_MIXIN" || {
      _ui_error '无法写入随机控制器端口'
      return 1
    }
    _merge_config || {
      _ui_error '控制器端口已调整，但运行配置更新失败'
      return 1
    }
    ext_port=$new_port
  fi

  # shellcheck disable=SC2034  # 由 scripts/cmd/ui.sh 读取
  EXT_IP=$display_ip
  # shellcheck disable=SC2034  # 由 scripts/cmd/ui.sh 与 scripts/cmd/node.sh 读取
  EXT_PORT=$ext_port
  return 0
}

_get_secret() {
  "$BIN_YQ" '.secret // ""' "$CLASH_CONFIG_RUNTIME"
}

# 配置适配层：渲染/校验当前仅支持 clash-yaml 系内核；sing-box 等 JSON 内核
# 在 _valid_config/_merge_config 顶部的分派处扩展（换渲染器与校验命令）。
_config_kernel_supported() {
    case "$CLASHCTL_KERNEL" in
    mihomo | clash) return 0 ;;
    *) return 1 ;;
    esac
}

_valid_config() {
  _config_kernel_supported || {
    _ui_error "内核 $CLASHCTL_KERNEL 暂不支持配置校验"
    return 1
  }
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

_merge_config() (
  _config_kernel_supported || {
    _ui_error "内核 $CLASHCTL_KERNEL 暂不支持配置渲染"
    return 1
  }
  umask 077
  local candidate
  candidate=$(mktemp "${CLASH_CONFIG_RUNTIME}.next.XXXXXX") || {
    _ui_error '无法创建运行配置候选文件'
    return 1
  }
  trap '[ -z "${candidate:-}" ] || /usr/bin/rm -f -- "$candidate"' EXIT

  # shellcheck disable=SC2016
  if ! "$BIN_YQ" eval-all '
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
      #        Tun DNS fallback              #
      ########################################
      # DNS 默认不接管，仅在 Tun 开启且无任何 dns 配置时补
      # 最小骨架，避免 dns-hijack 劫持的查询收到 SERVFAIL。
      (((.tun.enable // false) == true)) as $tunOn |
      (select($tunOn and ((.dns // {}) | keys | length) == 0) | .dns = {
        "enable": true,
        "listen": "0.0.0.0:1053",
        "enhanced-mode": "fake-ip",
        "nameserver": ["114.114.114.114", "8.8.8.8"]
      }) // . |

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
    ' "$CLASH_CONFIG_BASE" "$CLASH_CONFIG_MIXIN" >"$candidate"; then
    _ui_error '无法合并运行配置；已保留原运行配置'
    return 1
  fi

  _valid_config "$candidate" || {
    _ui_error '运行配置验证失败；已保留原运行配置'
    return 1
  }
  chmod 0600 -- "$candidate" || {
    _ui_error '无法保护运行配置候选文件；已保留原运行配置'
    return 1
  }
  /bin/mv -fT -- "$candidate" "$CLASH_CONFIG_RUNTIME" || {
    _ui_error '无法提交运行配置；已保留原运行配置'
    return 1
  }
  candidate=
  return 0
)
tunstatus() {
  local device
  device=$("$BIN_YQ" '.tun.device // ""' "$CLASH_CONFIG_RUNTIME")
  [ -z "$device" ] && device="Meta"
  ip link show | grep -qs "$device" && {
    _ui_ok_out 'Tun 状态：启用'
    return 0
  }
  _ui_info_out 'Tun 状态：关闭'
  return 1
}
_is_tun_enabled() {
  local enabled
  enabled=$("$BIN_YQ" '.tun.enable // false' "$CLASH_CONFIG_RUNTIME") || {
    _ui_error '无法读取运行配置中的 Tun 状态'
    return 2
  }
  case $enabled in
  true) return 0 ;;
  false) return 1 ;;
  *)
    _ui_error '运行配置中的 Tun 状态不是布尔值'
    return 2
    ;;
  esac
}
_merge_config_restart() {
  local was_tun_active=false tun_enabled=false tun_state_rc=0

  tunstatus >&/dev/null && was_tun_active=true
  # rc=1：候选配置合并或校验失败，原 runtime 保持不变。
  _merge_config || return 1

  _is_tun_enabled || tun_state_rc=$?
  case $tun_state_rc in
  0) tun_enabled=true ;;
  1) ;;
  *) return 2 ;;
  esac

  if [ "$was_tun_active" = true ]; then
    service_sudo_stop >/dev/null 2>&1 || :
    if service_is_active >&/dev/null; then
      _ui_error "运行配置已更新，但未能停止 $CLASHCTL_KERNEL 服务"
      return 2
    fi
  else
    service_stop >/dev/null 2>&1 || :
    if service_is_active >&/dev/null; then
      _ui_error "运行配置已更新，但未能停止 $CLASHCTL_KERNEL 服务"
      return 2
    fi
  fi

  sleep 0.1

  # rc=2：合并成功（runtime 已是新配置）但服务重启失败
  if [ "$tun_enabled" = true ]; then
    service_sudo_start >/dev/null 2>&1 || :
    sleep 1
    if ! service_is_active >&/dev/null || ! tunstatus >&/dev/null; then
      _ui_error "运行配置已更新，但 Tun 模式重启失败，请检查代理内核日志"
      return 2
    fi
  else
    service_start >/dev/null 2>&1 || :
    sleep 0.1
    service_is_active >&/dev/null || {
      _ui_error "运行配置已更新，但服务重启失败，请检查代理内核日志"
      return 2
    }
  fi
  return 0
}
