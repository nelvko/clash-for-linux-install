#!/usr/bin/env python3
"""Loopback dashboard HTTP server."""
from __future__ import annotations

import json
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Any

from store import TrafficStore, format_utc


class DashboardHandler(BaseHTTPRequestHandler):
    server_version = "clashctl-traffic/1"

    @property
    def dashboard_server(self) -> "DashboardServer":
        return self.server  # type: ignore[return-value]

    def log_message(self, _format: str, *_args: Any) -> None:
        return

    def _send(self, status: int, content_type: str, body: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Length", str(len(body)))
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "
            "connect-src 'self'; img-src 'self' data:; base-uri 'none'; frame-ancestors 'none'",
        )
        self.end_headers()
        self.wfile.write(body)

    def _json(self, value: Any, status: int = 200) -> None:
        body = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()
        self._send(status, "application/json; charset=utf-8", body)

    def do_GET(self) -> None:  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)
        try:
            if parsed.path in {"/", "/index.html"}:
                self._send(200, "text/html; charset=utf-8", self.dashboard_server.dashboard_html)
                return
            if parsed.path == "/api/health":
                self._json(self.dashboard_server.health())
                return
            if parsed.path == "/api/summary":
                since = params.get("since", ["today"])[0]
                self._json(
                    self.dashboard_server.store.summary(
                        self.dashboard_server.store.since_value(since)
                    )
                )
                return
            if parsed.path == "/api/range":
                since = params.get("since", ["24h"])[0]
                self._json(
                    {
                        "since": since,
                        "series": self.dashboard_server.store.series(
                            self.dashboard_server.store.since_value(since)
                        ),
                    }
                )
                return
            if parsed.path == "/api/live":
                self._json({"identities": self.dashboard_server.store.live()})
                return
            self._json({"error": "not_found"}, 404)
        except ValueError as exc:
            self._json({"error": str(exc)}, 400)
        except Exception:
            self._json({"error": "internal_error"}, 500)


class DashboardServer(HTTPServer):

    def __init__(
        self,
        address: tuple[str, int],
        store: TrafficStore,
        dashboard_html: bytes,
        interval: float,
    ):
        super().__init__(address, DashboardHandler)
        self.store = store
        self.dashboard_html = dashboard_html
        self.interval = interval
        self.started_at = int(time.time())

    def health(self) -> dict[str, Any]:
        return {
            "status": "ok",
            "collector": "clashctl-traffic",
            "started_at": format_utc(self.started_at),
            "last_sample_at": format_utc(self.store.get_meta("last_sample_at")),
            "controller_reachable": self.store.get_meta("controller_reachable") == "1",
            "last_error": self.store.get_meta("last_error") or None,
            "sample_interval": self.interval,
            "dashboard_bind": f"{self.server_address[0]}:{self.server_address[1]}",
        }


def load_dashboard(script_path: Path) -> bytes:
    dashboard = script_path.with_name("dashboard.html")
    try:
        return dashboard.read_bytes()
    except OSError as exc:
        raise RuntimeError(f"找不到 dashboard.html：{dashboard}") from exc
