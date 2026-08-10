#!/usr/bin/env python3
"""Identity resolution and Mihomo connection normalization."""
from __future__ import annotations

import hashlib
import json
import pwd
from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class Identity:
    key: str
    label: str
    kind: str
    confidence: str


@dataclass(frozen=True)
class ConnectionSample:
    connection_id: str
    identity: Identity
    upload: int
    download: int


def parse_int(value: Any) -> int:
    try:
        return max(0, int(value))
    except (TypeError, ValueError):
        return 0


def metadata_for(connection: dict[str, Any]) -> dict[str, Any]:
    value = connection.get("metadata")
    return value if isinstance(value, dict) else {}


def linux_uid_identity(uid: int) -> Identity:
    try:
        label = f"{pwd.getpwuid(uid).pw_name} · uid {uid}"
    except KeyError:
        label = f"uid {uid}"
    return Identity(f"uid:{uid}", label, "linux-user", "high")


def _metadata_uid(metadata: dict[str, Any]) -> int | None:
    value = metadata.get("uid")
    if value is None or not str(value).strip():
        return None
    try:
        uid = int(str(value))
    except ValueError:
        return None
    return uid if uid > 0 else None


def identify_connection(
    metadata: dict[str, Any], local_uid: int | None = None
) -> Identity:
    """Resolve identity without retaining socket or destination metadata.

    A UID resolved from the local client socket is trusted, including UID 0.
    Mihomo's raw UID 0 remains an unavailable sentinel and is not trusted.
    """
    inbound_user = str(metadata.get("inboundUser") or "").strip()
    if inbound_user:
        return Identity(f"account:{inbound_user}", inbound_user, "account", "high")

    if local_uid is not None and local_uid >= 0:
        return linux_uid_identity(local_uid)

    metadata_uid = _metadata_uid(metadata)
    if metadata_uid is not None:
        identity = linux_uid_identity(metadata_uid)
        return Identity(identity.key, identity.label, identity.kind, "medium")

    source_ip = str(metadata.get("sourceIP") or "").strip()
    if source_ip:
        return Identity(f"source-ip:{source_ip}", source_ip, "source-ip", "low")

    return Identity("unknown", "Unattributed", "unknown", "low")


def connection_id(connection: dict[str, Any]) -> str:
    raw_id = connection.get("id")
    if raw_id is not None and str(raw_id).strip():
        return str(raw_id)
    metadata = metadata_for(connection)
    seed = {
        "metadata": {
            "sourceIP": metadata.get("sourceIP"),
            "sourcePort": metadata.get("sourcePort"),
            "inboundPort": metadata.get("inboundPort"),
            "host": metadata.get("host"),
        },
        "start": connection.get("start"),
    }
    digest = hashlib.sha256(
        json.dumps(seed, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()[:32]
    return f"synthetic:{digest}"


def normalize_connection(
    connection: dict[str, Any], local_uid: int | None = None
) -> ConnectionSample:
    return ConnectionSample(
        connection_id=connection_id(connection),
        identity=identify_connection(metadata_for(connection), local_uid=local_uid),
        upload=parse_int(connection.get("upload")),
        download=parse_int(connection.get("download")),
    )
