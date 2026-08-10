#!/usr/bin/env python3
"""SQLite persistence and aggregation for sampled traffic telemetry."""
from __future__ import annotations

import datetime as datetime_module
import os
import sqlite3
import time
from pathlib import Path
from typing import Any, Iterable

from model import ConnectionSample

STALE_CONNECTION_SECONDS = 180


def utc_now() -> int:
    return int(time.time())


def format_utc(timestamp: int | float | str | None) -> str | None:
    if timestamp is None:
        return None
    return datetime_module.datetime.fromtimestamp(
        float(timestamp), datetime_module.timezone.utc
    ).isoformat().replace("+00:00", "Z")


def linux_user_id(identity_key: str, identity_kind: str) -> int | None:
    """Return the numeric Linux UID, never a generic identity string."""
    if identity_kind != "linux-user" or not identity_key.startswith("uid:"):
        return None
    try:
        uid = int(identity_key.removeprefix("uid:"))
    except ValueError:
        return None
    return uid if uid >= 0 else None


class TrafficStore:
    def __init__(self, path: Path):
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)
        try:
            os.chmod(self.path.parent, 0o700)
        except OSError:
            pass
        self.connection = sqlite3.connect(self.path, timeout=30)
        self.connection.row_factory = sqlite3.Row
        self.connection.execute("PRAGMA journal_mode=WAL")
        self.connection.execute("PRAGMA synchronous=NORMAL")
        self._create_schema()
        try:
            os.chmod(self.path, 0o600)
        except OSError:
            pass

    def close(self) -> None:
        self.connection.close()

    def _create_schema(self) -> None:
        self.connection.executescript(
            """
            CREATE TABLE IF NOT EXISTS traffic_minute (
                bucket_start INTEGER NOT NULL,
                identity_key TEXT NOT NULL,
                display_name TEXT NOT NULL,
                identity_kind TEXT NOT NULL,
                confidence TEXT NOT NULL,
                upload_bytes INTEGER NOT NULL DEFAULT 0,
                download_bytes INTEGER NOT NULL DEFAULT 0,
                samples INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (bucket_start, identity_key)
            );
            CREATE INDEX IF NOT EXISTS idx_traffic_minute_bucket
                ON traffic_minute(bucket_start);

            CREATE TABLE IF NOT EXISTS sample_minute (
                bucket_start INTEGER PRIMARY KEY,
                samples INTEGER NOT NULL DEFAULT 0
            );

            CREATE TABLE IF NOT EXISTS connection_state (
                connection_id TEXT PRIMARY KEY,
                identity_key TEXT NOT NULL,
                display_name TEXT NOT NULL,
                identity_kind TEXT NOT NULL,
                confidence TEXT NOT NULL,
                upload_bytes INTEGER NOT NULL,
                download_bytes INTEGER NOT NULL,
                last_seen INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_connection_state_last_seen
                ON connection_state(last_seen);

            CREATE TABLE IF NOT EXISTS live_identity (
                identity_key TEXT PRIMARY KEY,
                display_name TEXT NOT NULL,
                identity_kind TEXT NOT NULL,
                confidence TEXT NOT NULL,
                connection_count INTEGER NOT NULL,
                upload_bytes INTEGER NOT NULL,
                download_bytes INTEGER NOT NULL,
                observed_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS collector_meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """
        )
        self.connection.commit()

    def set_meta(self, key: str, value: Any) -> None:
        self.connection.execute(
            "INSERT INTO collector_meta(key, value) VALUES(?, ?) "
            "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            (key, str(value)),
        )

    def get_meta(self, key: str) -> str | None:
        row = self.connection.execute(
            "SELECT value FROM collector_meta WHERE key = ?", (key,)
        ).fetchone()
        return str(row[0]) if row else None

    def record_error(self, message: str) -> None:
        self.set_meta("last_error", message[:300])
        self.set_meta("controller_reachable", "0")
        self.connection.commit()

    def record_sample(
        self,
        samples: Iterable[ConnectionSample],
        observed_at: int,
        global_upload: int | None = None,
        global_download: int | None = None,
    ) -> dict[str, int]:
        bucket = observed_at - observed_at % 60
        deltas: dict[str, dict[str, Any]] = {}
        live: dict[str, dict[str, Any]] = {}
        total_upload = 0
        total_download = 0

        with self.connection:
            self.connection.execute(
                "INSERT INTO sample_minute(bucket_start, samples) VALUES(?, 1) "
                "ON CONFLICT(bucket_start) DO UPDATE SET "
                "samples=sample_minute.samples + 1",
                (bucket,),
            )
            for sample in samples:
                previous = self.connection.execute(
                    "SELECT upload_bytes, download_bytes FROM connection_state "
                    "WHERE connection_id = ?",
                    (sample.connection_id,),
                ).fetchone()
                if previous is None:
                    delta_upload = 0
                    delta_download = 0
                else:
                    old_upload = int(previous[0])
                    old_download = int(previous[1])
                    delta_upload = (
                        sample.upload - old_upload
                        if sample.upload >= old_upload
                        else sample.upload
                    )
                    delta_download = (
                        sample.download - old_download
                        if sample.download >= old_download
                        else sample.download
                    )

                identity = sample.identity
                if delta_upload or delta_download:
                    item = deltas.setdefault(
                        identity.key,
                        {"identity": identity, "upload": 0, "download": 0},
                    )
                    item["upload"] += delta_upload
                    item["download"] += delta_download
                    total_upload += delta_upload
                    total_download += delta_download

                live_item = live.setdefault(
                    identity.key,
                    {
                        "identity": identity,
                        "connections": 0,
                        "upload": 0,
                        "download": 0,
                    },
                )
                live_item["connections"] += 1
                live_item["upload"] += sample.upload
                live_item["download"] += sample.download

                self.connection.execute(
                    "INSERT INTO connection_state("
                    "connection_id, identity_key, display_name, identity_kind, "
                    "confidence, upload_bytes, download_bytes, last_seen) "
                    "VALUES(?, ?, ?, ?, ?, ?, ?, ?) "
                    "ON CONFLICT(connection_id) DO UPDATE SET "
                    "identity_key=excluded.identity_key, "
                    "display_name=excluded.display_name, "
                    "identity_kind=excluded.identity_kind, "
                    "confidence=excluded.confidence, "
                    "upload_bytes=excluded.upload_bytes, "
                    "download_bytes=excluded.download_bytes, "
                    "last_seen=excluded.last_seen",
                    (
                        sample.connection_id,
                        identity.key,
                        identity.label,
                        identity.kind,
                        identity.confidence,
                        sample.upload,
                        sample.download,
                        observed_at,
                    ),
                )

            for item in deltas.values():
                identity = item["identity"]
                self.connection.execute(
                    "INSERT INTO traffic_minute("
                    "bucket_start, identity_key, display_name, identity_kind, "
                    "confidence, upload_bytes, download_bytes, samples) "
                    "VALUES(?, ?, ?, ?, ?, ?, ?, 1) "
                    "ON CONFLICT(bucket_start, identity_key) DO UPDATE SET "
                    "display_name=excluded.display_name, "
                    "identity_kind=excluded.identity_kind, "
                    "confidence=excluded.confidence, "
                    "upload_bytes=traffic_minute.upload_bytes + excluded.upload_bytes, "
                    "download_bytes=traffic_minute.download_bytes + excluded.download_bytes, "
                    "samples=traffic_minute.samples + 1",
                    (
                        bucket,
                        identity.key,
                        identity.label,
                        identity.kind,
                        identity.confidence,
                        item["upload"],
                        item["download"],
                    ),
                )

            self.connection.execute("DELETE FROM live_identity")
            for item in live.values():
                identity = item["identity"]
                self.connection.execute(
                    "INSERT INTO live_identity("
                    "identity_key, display_name, identity_kind, confidence, "
                    "connection_count, upload_bytes, download_bytes, observed_at) "
                    "VALUES(?, ?, ?, ?, ?, ?, ?, ?)",
                    (
                        identity.key,
                        identity.label,
                        identity.kind,
                        identity.confidence,
                        item["connections"],
                        item["upload"],
                        item["download"],
                        observed_at,
                    ),
                )

            self.connection.execute(
                "DELETE FROM connection_state WHERE last_seen < ?",
                (observed_at - STALE_CONNECTION_SECONDS,),
            )
            self.set_meta("last_sample_at", observed_at)
            self.set_meta("last_error", "")
            self.set_meta("controller_reachable", "1")
            self.set_meta("sample_count", int(self.get_meta("sample_count") or "0") + 1)
            self.set_meta("last_delta_upload", total_upload)
            self.set_meta("last_delta_download", total_download)
            if global_upload is not None:
                self.set_meta("global_upload_total", global_upload)
            if global_download is not None:
                self.set_meta("global_download_total", global_download)

        return {
            "connections": sum(int(item["connections"]) for item in live.values()),
            "identities": len(live),
            "upload": total_upload,
            "download": total_download,
        }

    @staticmethod
    def since_value(value: str | None, now: int | None = None) -> int:
        now = now or utc_now()
        if not value or value == "today":
            current = datetime_module.datetime.fromtimestamp(
                now, datetime_module.timezone.utc
            )
            start = datetime_module.datetime(
                current.year,
                current.month,
                current.day,
                tzinfo=datetime_module.timezone.utc,
            )
            return int(start.timestamp())
        if value in {"24h", "day"}:
            return now - 24 * 3600
        if value in {"7d", "week"}:
            return now - 7 * 24 * 3600
        if value.isdigit():
            return now - int(value) * 3600
        try:
            parsed = datetime_module.datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError as exc:
            raise ValueError(f"无法解析时间范围：{value}") from exc
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=datetime_module.timezone.utc)
        return int(parsed.timestamp())

    def users(self, since: int, until: int | None = None) -> list[dict[str, Any]]:
        upper = until or utc_now() + 60
        rows = self.connection.execute(
            "SELECT identity_key, display_name, identity_kind, confidence, "
            "SUM(upload_bytes) AS upload, SUM(download_bytes) AS download, "
            "SUM(samples) AS samples FROM traffic_minute "
            "WHERE bucket_start >= ? AND bucket_start < ? "
            "GROUP BY identity_key, display_name, identity_kind, confidence "
            "ORDER BY (SUM(upload_bytes) + SUM(download_bytes)) DESC",
            (since, upper),
        ).fetchall()
        return [
            {
                **dict(row),
                "user_id": linux_user_id(
                    str(row["identity_key"]), str(row["identity_kind"])
                ),
            }
            for row in rows
        ]

    def series(
        self, since: int, until: int | None = None, step: int = 300
    ) -> list[dict[str, Any]]:
        upper = until or utc_now() + 60
        traffic_rows = self.connection.execute(
            "SELECT bucket_start, identity_kind, SUM(upload_bytes) AS upload, "
            "SUM(download_bytes) AS download FROM traffic_minute "
            "WHERE bucket_start >= ? AND bucket_start < ? "
            "GROUP BY bucket_start, identity_kind ORDER BY bucket_start",
            (since, upper),
        ).fetchall()
        sample_rows = self.connection.execute(
            "SELECT bucket_start FROM sample_minute "
            "WHERE bucket_start >= ? AND bucket_start < ?",
            (since, upper),
        ).fetchall()
        buckets: dict[int, dict[str, Any]] = {}
        for row in traffic_rows:
            bucket = int(row["bucket_start"]) // step * step
            item = buckets.setdefault(
                bucket,
                {
                    "upload": 0,
                    "download": 0,
                    "attributed": 0,
                    "unattributed": 0,
                    "sampled": False,
                },
            )
            upload = int(row["upload"] or 0)
            download = int(row["download"] or 0)
            item["upload"] += upload
            item["download"] += download
            if row["identity_kind"] == "unknown":
                item["unattributed"] += upload + download
            else:
                item["attributed"] += upload + download
        for row in sample_rows:
            bucket = int(row["bucket_start"]) // step * step
            item = buckets.setdefault(
                bucket,
                {
                    "upload": 0,
                    "download": 0,
                    "attributed": 0,
                    "unattributed": 0,
                    "sampled": False,
                },
            )
            item["sampled"] = True
        first = since // step * step
        last = (upper - 1) // step * step
        empty = {
            "upload": 0,
            "download": 0,
            "attributed": 0,
            "unattributed": 0,
            "sampled": False,
        }
        return [
            {"timestamp": bucket, **buckets.get(bucket, empty)}
            for bucket in range(first, last + 1, step)
        ]

    def live(self) -> list[dict[str, Any]]:
        rows = self.connection.execute(
            "SELECT identity_key, display_name, identity_kind, confidence, "
            "connection_count, upload_bytes, download_bytes, observed_at "
            "FROM live_identity ORDER BY (upload_bytes + download_bytes) DESC"
        ).fetchall()
        return [
            {
                **dict(row),
                "user_id": linux_user_id(
                    str(row["identity_key"]), str(row["identity_kind"])
                ),
                "observed_at": format_utc(row["observed_at"]),
            }
            for row in rows
        ]

    def summary(self, since: int) -> dict[str, Any]:
        users = self.users(since)
        upload = sum(int(item["upload"] or 0) for item in users)
        download = sum(int(item["download"] or 0) for item in users)
        attributed = sum(
            int(item["upload"] or 0) + int(item["download"] or 0)
            for item in users
            if item["identity_kind"] != "unknown"
        )
        total = upload + download
        return {
            "since": format_utc(since),
            "upload": upload,
            "download": download,
            "total": total,
            "active_identities": len(self.live()),
            "tracked_identities": len(users),
            "attributed": attributed,
            "unattributed": max(0, total - attributed),
            "attribution_percent": round(attributed * 100 / total, 1) if total else 100.0,
            "sample_count": int(self.get_meta("sample_count") or "0"),
            "last_sample_at": format_utc(self.get_meta("last_sample_at")),
            "controller_reachable": self.get_meta("controller_reachable") == "1",
            "last_error": self.get_meta("last_error") or None,
            "users": users,
        }
