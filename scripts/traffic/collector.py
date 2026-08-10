#!/usr/bin/env python3
"""Mihomo controller client and sampler lifecycle helpers."""
from __future__ import annotations

import http.client
import ipaddress
import json
import os
import re
import signal
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

from model import normalize_connection, parse_int
from store import TrafficStore, utc_now

MAX_RESPONSE_BYTES = 16 * 1024 * 1024


class TrafficError(RuntimeError):
    """A safe, user-facing collector error."""


def _strip_yaml_scalar(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    if " #" in value:
        value = value.split(" #", 1)[0].rstrip()
    return value


def runtime_connection_config(config_path: Path) -> tuple[str, str]:
    """Read only top-level controller fields without a YAML dependency."""
    controller = "127.0.0.1:9090"
    secret = ""
    try:
        lines = config_path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError as exc:
        raise TrafficError(f"无法读取 Mihomo runtime 配置：{config_path}") from exc
    for line in lines:
        match = re.match(r"^(external-controller|secret):\s*(.*)$", line)
        if not match:
            continue
        value = _strip_yaml_scalar(match.group(2))
        if match.group(1) == "external-controller":
            controller = value or controller
        else:
            secret = value
    return controller, secret


def controller_address(controller: str) -> str:
    value = (controller or "").strip()
    if value.startswith("[") and "]" in value:
        host = value[1 : value.index("]")]
        suffix = value[value.index("]") + 1 :]
        port = int(suffix[1:]) if suffix.startswith(":") else 9090
    elif ":" in value:
        host, port_value = value.rsplit(":", 1)
        port = int(port_value)
    else:
        host, port = value or "127.0.0.1", 9090
    if host in {"0.0.0.0", "::", "[::]", ""}:
        host = "127.0.0.1"
    return f"{host}:{port}"


def _read_response(response: Any) -> bytes:
    chunks: list[bytes] = []
    size = 0
    while True:
        chunk = response.read(64 * 1024)
        if not chunk:
            break
        size += len(chunk)
        if size > MAX_RESPONSE_BYTES:
            raise TrafficError("Mihomo connections 响应超过安全大小限制")
        chunks.append(chunk)
    return b"".join(chunks)


def fetch_connections(controller: str, secret: str) -> dict[str, Any]:
    request = urllib.request.Request(f"http://{controller_address(controller)}/connections")
    if secret:
        request.add_header("Authorization", f"Bearer {secret}")
    try:
        with urllib.request.urlopen(request, timeout=4) as response:
            payload = _read_response(response)
    except (OSError, urllib.error.URLError, http.client.HTTPException) as exc:
        raise TrafficError(f"Mihomo 控制接口不可用：{type(exc).__name__}") from exc
    try:
        value = json.loads(payload)
    except json.JSONDecodeError as exc:
        raise TrafficError("Mihomo 控制接口返回了无效 JSON") from exc
    if not isinstance(value, dict):
        raise TrafficError("Mihomo 控制接口返回格式不正确")
    return value


def proc_socket_uid_snapshot(
    proc_net: Path = Path("/proc/net"),
) -> dict[tuple[str, int], int]:
    """Return unambiguous local-port owners from Linux proc socket tables."""
    owners: dict[tuple[str, int], set[int]] = {}
    for name in ("tcp", "tcp6", "udp", "udp6"):
        path = proc_net / name
        try:
            lines = path.read_text(encoding="ascii", errors="replace").splitlines()[1:]
        except OSError:
            continue
        network = "tcp" if name.startswith("tcp") else "udp"
        for line in lines:
            fields = line.split()
            if len(fields) < 8:
                continue
            try:
                local_port = int(fields[1].rsplit(":", 1)[1], 16)
                uid = int(fields[7])
            except (IndexError, ValueError):
                continue
            if 0 < local_port <= 65535 and uid >= 0:
                owners.setdefault((network, local_port), set()).add(uid)
    return {
        key: next(iter(values))
        for key, values in owners.items()
        if len(values) == 1
    }


def local_socket_uid(
    metadata: dict[str, Any], snapshot: dict[tuple[str, int], int]
) -> int | None:
    """Resolve a loopback client's Linux UID from its local source port."""
    source_ip = str(metadata.get("sourceIP") or "").strip().strip("[]")
    try:
        address = ipaddress.ip_address(source_ip.split("%", 1)[0])
    except ValueError:
        return None
    if address.version == 6 and address.ipv4_mapped is not None:
        address = address.ipv4_mapped
    if not address.is_loopback:
        return None
    try:
        source_port = int(metadata.get("sourcePort"))
    except (TypeError, ValueError):
        return None
    if not 0 < source_port <= 65535:
        return None
    network = str(metadata.get("network") or "tcp").strip().lower()
    if network not in {"tcp", "udp"}:
        return None
    return snapshot.get((network, source_port))


def collect_once(store: TrafficStore, controller: str, secret: str) -> dict[str, int]:
    try:
        payload = fetch_connections(controller, secret)
        connections = payload.get("connections")
        if not isinstance(connections, list):
            raise TrafficError("Mihomo 返回中缺少 connections 列表")
        socket_uids = proc_socket_uid_snapshot()
        samples = []
        for item in connections:
            if not isinstance(item, dict):
                continue
            metadata = item.get("metadata")
            metadata = metadata if isinstance(metadata, dict) else {}
            samples.append(
                normalize_connection(
                    item,
                    local_uid=local_socket_uid(metadata, socket_uids),
                )
            )
        return store.record_sample(
            samples,
            utc_now(),
            parse_int(payload.get("uploadTotal"))
            if payload.get("uploadTotal") is not None
            else None,
            parse_int(payload.get("downloadTotal"))
            if payload.get("downloadTotal") is not None
            else None,
        )
    except TrafficError as exc:
        store.record_error(str(exc))
        raise


def pid_path(state_dir: Path) -> Path:
    return state_dir / "traffic.pid"


def read_pid(state_dir: Path) -> int | None:
    try:
        return int(pid_path(state_dir).read_text(encoding="ascii").strip())
    except (OSError, ValueError):
        return None


def process_matches(pid: int, state_dir: Path) -> bool:
    try:
        command = Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").decode()
    except (OSError, UnicodeDecodeError):
        return False
    return "traffic.py" in command and str(state_dir) in command


def is_running(state_dir: Path) -> tuple[bool, int | None]:
    pid = read_pid(state_dir)
    return bool(pid and process_matches(pid, state_dir)), pid


def acquire_pid_file(state_dir: Path) -> None:
    state_dir.mkdir(parents=True, exist_ok=True)
    path = pid_path(state_dir)
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        existing = read_pid(state_dir)
        if existing and process_matches(existing, state_dir):
            raise TrafficError(f"采集器已在运行（PID {existing}）")
        path.unlink(missing_ok=True)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="ascii") as handle:
        handle.write(str(os.getpid()))


def remove_pid_file(state_dir: Path) -> None:
    try:
        pid_path(state_dir).unlink()
    except FileNotFoundError:
        pass


def stop_collector(state_dir: Path) -> bool:
    running, pid = is_running(state_dir)
    if not running or not pid:
        remove_pid_file(state_dir)
        return False
    os.kill(pid, signal.SIGTERM)
    return True
