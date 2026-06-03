# AGENTS.md — clash-for-linux-install

## Project Overview

A Bash-based one-click deployment & management tool for **mihomo** (preferred) and **clash** proxy kernels on Linux. Installs the kernel, Web dashboard, subconverter, and a `clashctl` CLI. Supports `systemd`/`OpenRC`/`runit`/`sysvinit`/`nohup` init systems and works for both root and non-root users.

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/nelvko/clash-for-linux-install/dev/install.sh | bash -s -- [mihomo|clash] [订阅URL]
```

Install options are configured via `.env.install` (or environment variables) before running.

## Directory Layout

```
.
├── install.sh                 # Entry point — sources preflight.sh
├── update.sh                  # Self-update entry (tarball-based, no git) — sources preflight.sh, calls deploy_clashctl
├── uninstall.sh               # Removal script (installed to $CLASHCTL_HOME)
├── .env                       # Runtime env vars (auto-generated after install)
├── .env.install               # User configuration for installation
├── archives/
│   └── dist.zip               # Web UI dashboard (pre-packaged)
├── resources/                 # Shipped config templates
│   ├── mixin.yaml             #  user-editable override config
│   ├── profiles.yaml          # Subscription metadata DB (YAML)
│   └── profiles/              # Per-subscription config files (1 per profile)
├── scripts/
│   ├── preflight.sh           # Install orchestrator (env checks, download, unpack, setup)
│   ├── lib/
│   │   ├── common.sh          # Shared helpers: logging (_okcat/_failcat/_errorcat), _set_env, _color_log, port/IP/random helpers
│   │   ├── config.sh          # Config management: _merge_config, _detect_proxy_port, _detect_ext_addr, tunstatus, _valid_config
│   │   ├── convert.sh         # Subscription conversion via subconverter: _download_config, _start_convert, _stop_convert
│   │   ├── service.sh         # init-agnostic service manager abstraction
│   │   └── update.sh          # Self-update deploy core: backup/restore, deploy_clashctl, _deploy_* (shared by update.sh & `clashctl update`)
│   ├── cmd/
│   │   ├── clashctl.sh        # Central dispatcher — sources all cmd/*.sh, routes subcommands
│   │   ├── clashctl.fish      # Native Fish shell integration (sources proxy env as Fish vars)
│   │   ├── help.sh / on.sh / off.sh / status.sh / ui.sh / sub.sh / tun.sh / mixin.sh / secret.sh / log.sh / update.sh / upgrade.sh
│   └── init/
│       ├── systemd.sh         # systemd unit template
│       ├── openrc.sh          # OpenRC init script template
│       ├── runit.sh           # runit run script template
│       └── sysvinit.sh        # SysVinit init script template
├── .shellcheckrc              # ShellCheck: disables SC1091, SC2155, SC2296, SC2153
├── .editorconfig              # LF line endings, 2-space indent
└── .gitignore                 # Excludes .idea, .vscode, config.yaml*, archives/* (except dist.zip), test.sh
```

## Runtime Directory Layout (`$CLASHCTL_HOME`, default `~/clashctl`)

```
~/clashctl/
├── .env                       # Auto-generated runtime vars (INIT_TYPE, CLASHCTL_KERNEL, CLASHCTL_REV, GH_PROXY, CLASHCTL_DOWNLOAD_TIMEOUT)
├── .bak/                      # Self-update backups (clashctl-backup-<ts>.tar.gz, newest 3 kept; excludes bin/)
├── uninstall.sh               # Copy of uninstall.sh
├── bin/
│   ├── mihomo (or clash)      # Kernel binary
│   ├── yq                     # YAML processor
│   └── subconverter/          # Subscription conversion tool
├── resources/
│   ├── config.yaml            # Active subscription config (base)
│   ├── mixin.yaml             # User overlay config (shipped from repo)
│   ├── runtime.yaml           # Merged result of base + mixin
│   ├── temp.yaml              # Scratch file for downloads/validation
│   ├── profiles.yaml          # Subscription metadata (YAML array)
│   └── profiles/              # Per-subscription YAML configs
├── scripts/
│   ├── cmd/                   # Copied from repo
│   ├── lib/                   # Copied from repo
│   └── init/                  # Copied from repo (service templates)
```

## Command Architecture & Control Flow

### Invocation chain

1. User runs `clashctl <subcommand> [args]`
2. `~/.bashrc` sources `$CLASHCTL_HOME/scripts/cmd/clashctl.sh`
3. `clashctl.sh` sources the `.env`, then all `scripts/lib/*.sh`, then all `scripts/cmd/*.sh` (except itself)
4. `clashctl()` dispatches: `clashctl on` → calls `clashon()`, `clashctl sub add <url>` → calls `clashsub()`, etc.
5. Each `clash<name>()` function lives in the matching `scripts/cmd/<name>.sh` file (e.g., `clashon` → `on.sh`)
6. Commands returning proxy env vars (`clashon` without `--service-only`) export `http_proxy`/`https_proxy`/`all_proxy`/`no_proxy` to the current shell

### Fish shell path

- `clashon`/`clashoff` are native Fish functions (from `clashctl.fish`)
- `clashon` captures Bash output via `_dump_proxy_env_fish`, writes a temp Fish script, sources it to set proxy vars persistently in Fish
- Other subcommands are auto-wrapped via a `for cmd_file in ...` loop calling `__clashctl_run` (delegates to Bash)

### Subcommand dispatch table

| Command | Function | File |
|---|---|---|
| `clashctl on` | `clashon` | `on.sh` |
| `clashctl off` | `clashoff` | `off.sh` |
| `clashctl status` | `clashstatus` | `status.sh` |
| `clashctl ui` | `clashui` | `ui.sh` |
| `clashctl sub` | `clashsub` | `sub.sh` |
| `clashctl tun` | `clashtun` | `tun.sh` |
| `clashctl mixin` | `clashmixin` | `mixin.sh` |
| `clashctl secret` | `clashsecret` | `secret.sh` |
| `clashctl log` | `clashlog` | `log.sh` |
| `clashctl update` | `clashupdate` | `update.sh` |
| `clashctl upgrade` | `clashupgrade` | `upgrade.sh` |
| `clashctl help` | `clashhelp` | `help.sh` |

## Key Conventions & Patterns

### Function naming
- **Public CLI commands**: `clash<name>()` — e.g., `clashon`, `clashoff`, `clashsub`
- **Core lib functions**: `install_service()`, `detect_service_manager()`, `_merge_config()`
- **Internal helpers** prefixed with `_`: `_get_secret`, `_merge_config`, `_detect_proxy_port`, `_okcat`, `_failcat`, `_errorcat`
- **Subcommand-specific helpers** prefixed with sub-command name: `sub_add()`, `_sub_del()`, `on_env_only()`, `tunon()`, `tunoff()`

### Logging
- `_okcat <emoji> <message>` — success/info (stdout, returns 0)
- `_failcat <emoji> <message>` — warning (stderr, returns 1)
- `_errorcat <emoji> <message>` — error (stderr, returns 1, only prints if args given)
- All support custom color via 24-bit hex in `_color_log`
- Default emojis: 😼 success, 😾 warning, 📢 error

### Style
- `#!/usr/bin/env bash` shebang everywhere
- 2-space indentation (`.editorconfig` enforces)
- LF line endings
- Variables in `SCREAMING_CASE` for config/global, `snake_case` for locals
- Functions use `local` for all local variables
- `$()` for command substitution (no backticks)
- `printf '%s\n'` instead of `echo`
- String comparisons use `[[ ]]` (Bash conditional expression)

### ShellCheck
Disabled warnings (via `.shellcheckrc`):
- `SC1091` — can't follow sourced files
- `SC2155` — declare+assign separate
- `SC2296` — parentheses in expanded variables
- `SC2153` — possible misspelling

### Sourcing pattern
```bash
. "$CLASHCTL_SRC/scripts/preflight.sh"   # install.sh / uninstall.sh
. "$CLASHCTL_HOME/.env"                   # clashctl.sh (runtime)
for lib_file in "$CLASHCTL_SRC"/scripts/lib/*.sh; do
    [ -f "$lib_file" ] || continue
    . "$lib_file"
done
```

## Core Architecture

### Service Manager Abstraction (`scripts/lib/service.sh`)
Detects the init system by inspecting `/proc/1/exe` and `/proc/1/cgroup`. Supports **systemd**, **OpenRC**, **runit**, **sysvinit**, and **nohup** (fallback for containers/non-root). All service operations go through `detect_service_manager()` once, then dispatch to the correct command via case/esac.

Key abstraction functions:
- `service_start` / `service_stop` / `service_restart` / `service_status` / `service_is_active`
- `service_sudo_start` / `service_sudo_stop` — required for TUN mode (needs root)
- `service_log` / `service_follow_log` / `service_read_log` — log access
- `install_service` / `uninstall_service` — service registration/unregistration
- Init scripts use `placeholder_*` variables that get `sed`-replaced at install time

### Config Merge System (`scripts/lib/config.sh`)
```yaml
base (from subscription) + mixin (user edits) → runtime.yaml
```

The `_merge_config()` function uses `yq eval-all` to deep-merge with custom logic:
- `rules`: prepend + original + append
- `proxies`: prepend + override-by-name + append
- `proxy-groups`: prepend + override-by-name + append + inject (inject extra nodes into named groups)
- `_custom` key is deleted from mixin before merge
- Invalid merges roll back from `temp.yaml`

### Subscription Management (`scripts/cmd/sub.sh`)
Multiple subscriptions are stored as files in `resources/profiles/` with metadata in `resources/profiles.yaml`:
```yaml
use: 1                               # currently active profile ID
profiles:
  - id: 1
    path: /path/to/profiles/1.yaml
    url: https://example.com/sub
```
- `clashctl sub add <url>` — downloads, validates, adds
- `clashctl sub use <id>` — copies profile to `config.yaml`, merges, restarts
- `clashctl sub del <id>` — removes (can't delete active subscription)
- `clashctl sub update [--auto]` — re-downloads, with optional crontab scheduling
- Subscription download first validates raw config; if validation fails, automatically converts via subconverter

### Subscription Conversion (`scripts/lib/convert.sh`)
- Uses `subconverter` binary (bundled dependency)
- `_start_convert` starts subconverter on a random port, polls `/version` endpoint with 10s timeout
- `_stop_convert` kills via `pkill -TERM` then `-KILL`
- Conversion URL: `http://127.0.0.1:<port>/sub?target=clash&url=<encoded-url>`

### TUN Mode (`scripts/cmd/tun.sh`)
- Requires root/sudo for both enable and disable
- Sets `tun.enable = true` in mixin, then uses `service_sudo_start`
- mihomo fallback: if TUN fails, retries with `tun.auto-redirect = false`
- TUN status checked via `ip link show` looking for the tun device name

### Install Process (`install.sh` → `preflight.sh`)
1. Validates env (required commands, writable path, no existing install)
2. Parses args for kernel type and subscription URL
3. Downloads dependencies (mihomo/clash, yq, subconverter) based on CPU architecture and SSE level
4. Unpacks and installs binaries, resources, scripts
5. Registers init service with `install_service()`
6. Installs `clashctl` into shell RC files (bashrc/zshrc/fish)
7. Merges config, detects proxy port, seeds a random secret
8. Adds the initial subscription

### Self-Update Process (`update.sh` / `clashctl update` → `scripts/lib/update.sh`)

**`update` (project scripts/resources) is distinct from `upgrade` (proxy kernel).** Both entry points share one non-destructive deploy core, `deploy_clashctl()`:

- **`update.sh`** (source-side): downloads the latest `dev` tarball from `codeload.github.com` (honoring `GH_PROXY`) into a temp dir, then calls `deploy_clashctl`. No git required.
- **`clashctl update`** (`cmd/update.sh` → `clashupdate`): same tarball-download logic, reusing lib functions `_update_remote_sha` and `_update_fetch_src`. `-c/--check` shows current↔latest only; `-f/--force` redeploys even when already latest.

`deploy_clashctl` steps: require-installed → restore real `CLASHCTL_KERNEL`/`INIT_TYPE` from installed `.env` → **tar backup** `$CLASHCTL_HOME` to `.bak/` (excludes `bin/`) → `_deploy_apply` → on success prune backups + re-source `clashctl.sh`; **on any failure auto-rollback** from the backup.

**File classification (`_deploy_apply`) is the heart of the design:**
- **Overwrite (code/static):** `scripts/{cmd,lib,init}` (`rm -rf`+`cp -a`, drops upstream-removed files), `uninstall.sh`, `resources/Country.mmdb`, `resources/geosite.dat`.
- **Never touch (user data):** `resources/config.yaml` (active subscription base — **NOT** a template at runtime), `runtime.yaml`, `profiles.yaml`, `profiles/`, `bin/`.
- **Merge/special:** `.env` via `_env_add_missing` (adds new keys only, never overwrites existing values); `mixin.yaml` preserved (restored from source only if missing — new template keys are NOT auto-merged); `GH_PROXY`/`CLASHCTL_DOWNLOAD_TIMEOUT` persisted into `.env` (`_deploy_persist_proxy`) so `clashctl update` can reach GitHub; `CLASHCTL_REV` recorded (`_deploy_record_rev`).

After deploy, `_deploy_refresh_runtime` rebuilds `runtime.yaml` and only restarts the service if the merged output actually changed.

**Gotchas:**
- `preflight.sh` sources the repo template `.env` (empty `CLASHCTL_KERNEL`) — `_deploy_restore_env_identity` re-reads the installed `.env` first so service/kernel paths stay correct.
- `clashupdate` runs as an already-loaded Bash function; overwriting its own `cmd/update.sh`/`lib/update.sh` mid-run is safe (function bodies live in memory). The trailing `. clashctl.sh` reloads new definitions.
- `install_clashctl` reuses `_deploy_persist_proxy`/`_deploy_record_rev` so fresh installs also record `GH_PROXY` + `CLASHCTL_REV`.

## Important Gotchas & Non-Obvious Patterns

### Shell environment quirks
- `clashctl on` must be **sourced** (`. clashctl on` or via alias) to export proxy vars into the current shell — a subprocess can't modify parent env. The RC sourcing handles this.
- Fish shell has a dedicated path: `clashon` writes proxy vars to `$XDG_CACHE_HOME/clashctl/proxy.fish` then `source`s it.
- After install: user must run `source ~/.bashrc` (or equivalent) to activate clashctl in the current shell.
- TUN mode uses `sudo` — `service_sudo_start` explicitly runs `sudo sh -c "nohup ..."` and calls `stty opost` afterward to restore terminal settings (fix for terminal display corruption).

### CPU architecture & version resolution
- `download_zip()` detects x86_64 CPU features (SSE4.2, POPCNT, AVX2, FMA) to determine `v1`/`v2`/`v3` level and appends to `VERSION_MIHOMO` before URL construction.
- If GitHub API rate-limited, version resolution fails — user must set `VERSION_MIHOMO`, `VERSION_YQ`, `VERSION_SUBCONVERTER` manually in `.env.install`.
- `GH_PROXY` prefix is applied to all download URLs if set.

### Port conflict resolution
- `_detect_proxy_port()` and `_detect_ext_addr()` check if configured ports are in use.
- If conflict found and service is not running: a random port is assigned and written to `mixin.yaml`, then config is re-merged.
- `_is_port_used()` falls back from `ss` to `netstat`.

### YAML config management
- `yq` (Go version) is the only YAML processor — never use `grep`/`sed` for YAML values.
- `mixin.yaml` fields (`rules.prepend`, `rules.append`, `proxies.override`, `proxy-groups.inject`, etc.) have special merge semantics — documented in `mixin.yaml` comments.
- `_valid_config()` runs `$BIN_KERNEL -t` (config test) on the merged runtime config. On failure, rolls back from `temp.yaml`.
- Mixin changes trigger `_merge_config_restart()`: merge → stop → start.

### File paths
- All file paths are defined in `scripts/lib/common.sh` (e.g., `CLASH_CONFIG_BASE`, `CLASH_CONFIG_MIXIN`, `CLASH_CONFIG_RUNTIME`, `BIN_YQ`, etc.).
- The `CLASHCTL_KERNEL` variable dynamically determines binary name, init scripts, log/pid paths.

### Environment variable escaping
- `_set_env()` in `common.sh` must escape `\`, `&`, and `|` before `sed` replacement.
- `_dump_proxy_env_fish()` escapes `\` and `'` for Fish compatibility.

### Network constraints
- `--insecure` flag used on all `curl` calls (accepts self-signed certs behind proxy).
- `--noproxy "*"` used for local-only requests (upgrade, UI IP detection).
- Download timeout configurable via `CLASHCTL_DOWNLOAD_TIMEOUT` (default 60s).
- Subscription download timeout via `CLASHCTL_SUB_TIMEOUT` (default 5s).

### Subscription download fallback
- `_download_raw_config` tries `curl` first, falls back to `wget`.
- If raw config fails validation, attempts automatic conversion via subconverter (`_download_convert_config`).

## Tests & Lint

- **No formal test framework** — this is a Bash installer/management tool.
- **ShellCheck**: `shellcheck scripts/**/*.sh` (uses `.shellcheckrc` config).
- Testing involves running `install.sh` in a container/VM and verifying `clashctl` commands.

## Config Files Summary

| File | Purpose | User-editable? |
|---|---|---|
| `.env.install` | Install options (path, kernel, sub URL, versions, proxy) | Yes, before install |
| `.env` | Runtime vars (auto-generated after install) | No (auto-managed) |
| `resources/mixin.yaml` | User overlay config for clash kernel | Yes (via `clashctl mixin -e`) |
| `resources/profiles.yaml` | Subscription metadata DB | No (managed by `clashctl sub`) |

## Git Conventions

- Commit messages use `type: subject` format: `feat:`, `fix:`, `docs:`, `refactor:`, `chore:`, `perf:`
- PRs squash-merged
- Branch: `master` (default)
