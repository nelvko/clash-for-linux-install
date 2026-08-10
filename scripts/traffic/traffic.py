#!/usr/bin/env python3
"""CLI entry point for clashctl traffic accounting and dashboard."""
from __future__ import annotations

import argparse
import csv
import os
import signal
import sys
import time
from pathlib import Path

from collector import TrafficError, acquire_pid_file, is_running, remove_pid_file, stop_collector
from server import DashboardServer, load_dashboard
from store import TrafficStore, format_utc, linux_user_id, utc_now

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8765
DEFAULT_INTERVAL = 5.0


def state_dir_from_arg(value: str | None) -> Path:
    if value:
        return Path(value).expanduser()
    root = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state"))
    return root / "clashctl"


def bytes_label(value: int) -> str:
    units = ("B", "KB", "MB", "GB", "TB")
    amount = float(value)
    for unit in units:
        if amount < 1024 or unit == units[-1]:
            return f"{amount:.1f} {unit}" if unit != "B" else f"{int(value)} B"
        amount /= 1024
    return f"{int(value)} B"


def serve(args: argparse.Namespace) -> int:
    state_dir = state_dir_from_arg(args.state_dir)
    state_dir.mkdir(parents=True, exist_ok=True)
    acquire_pid_file(state_dir)
    store: TrafficStore | None = None
    server: DashboardServer | None = None
    stop_requested = False

    def request_stop(_signum: int, _frame: object) -> None:
        nonlocal stop_requested
        stop_requested = True

    try:
        store = TrafficStore(state_dir / "traffic.sqlite3")
        signal.signal(signal.SIGTERM, request_stop)
        signal.signal(signal.SIGINT, request_stop)
        server = DashboardServer(
            (args.host, int(args.port)),
            store,
            load_dashboard(Path(__file__)),
            max(1.0, float(args.interval)),
        )
        server.timeout = 0.25
        from collector import collect_once, runtime_connection_config

        config_path = Path(args.config_path).expanduser()
        next_sample = 0.0
        while not stop_requested:
            now = time.monotonic()
            if now >= next_sample:
                try:
                    controller, secret = runtime_connection_config(config_path)
                    collect_once(store, controller, secret)
                except TrafficError as exc:
                    store.record_error(str(exc))
                next_sample = now + server.interval
            server.handle_request()
    finally:
        if server is not None:
            server.server_close()
        if store is not None:
            store.close()
        remove_pid_file(state_dir)
    return 0


def command_status(args: argparse.Namespace) -> int:
    state_dir = state_dir_from_arg(args.state_dir)
    running, pid = is_running(state_dir)
    store_path = state_dir / "traffic.sqlite3"
    if running:
        print(f"collector=running pid={pid} state={store_path}")
        return 0
    print(f"collector=stopped state={store_path}")
    return 1


def command_stop(args: argparse.Namespace) -> int:
    stopped = stop_collector(state_dir_from_arg(args.state_dir))
    print("collector=stopping" if stopped else "collector=stopped")
    return 0


def report(args: argparse.Namespace) -> int:
    store = TrafficStore(state_dir_from_arg(args.state_dir) / "traffic.sqlite3")
    try:
        since = store.since_value(args.since)
        rows = store.users(since)
        print(f"范围：{format_utc(since)} → now")
        print("Linux UID    身份                 合计       置信度")
        print("-" * 68)
        for row in rows[: args.limit]:
            upload = int(row["upload"] or 0)
            download = int(row["download"] or 0)
            user_id = "—" if row["user_id"] is None else str(row["user_id"])
            print(
                f"{user_id:<13}"
                f"{row['display_name'][:19]:<21}"
                f"{bytes_label(upload + download):<12}"
                f"{row['confidence']}"
            )
        if not rows:
            print("暂无采样数据。先运行：clashctl traffic start")
        return 0
    finally:
        store.close()


def live_report(args: argparse.Namespace) -> int:
    store = TrafficStore(state_dir_from_arg(args.state_dir) / "traffic.sqlite3")
    try:
        rows = store.live()
        print("Linux UID    身份                 连接     当前流量       置信度")
        print("-" * 76)
        for row in rows:
            current = int(row["upload_bytes"]) + int(row["download_bytes"])
            user_id = "—" if row["user_id"] is None else str(row["user_id"])
            print(
                f"{user_id:<13}"
                f"{row['display_name'][:19]:<21}"
                f"{int(row['connection_count']):<9}"
                f"{bytes_label(current):<15}"
                f"{row['confidence']}"
            )
        if not rows:
            print("当前没有活跃连接，或采集器尚未成功连接 Mihomo。")
        return 0
    finally:
        store.close()


def export_csv(args: argparse.Namespace) -> int:
    store = TrafficStore(state_dir_from_arg(args.state_dir) / "traffic.sqlite3")
    try:
        since = store.since_value(args.since)
        until = store.since_value(args.until) if args.until else utc_now() + 60
        writer = csv.writer(sys.stdout)
        writer.writerow(
            [
                "bucket_start_utc",
                "user_id",
                "identity",
                "identity_kind",
                "confidence",
                "upload_bytes",
                "download_bytes",
                "total_bytes",
                "samples",
            ]
        )
        rows = store.connection.execute(
            "SELECT bucket_start, identity_key, display_name, identity_kind, "
            "confidence, upload_bytes, download_bytes, samples FROM traffic_minute "
            "WHERE bucket_start >= ? AND bucket_start < ? "
            "ORDER BY bucket_start, (upload_bytes + download_bytes) DESC",
            (since, until),
        ).fetchall()
        for row in rows:
            upload = int(row["upload_bytes"])
            download = int(row["download_bytes"])
            writer.writerow(
                [
                    format_utc(row["bucket_start"]),
                    linux_user_id(row["identity_key"], row["identity_kind"]),
                    row["display_name"],
                    row["identity_kind"],
                    row["confidence"],
                    upload,
                    download,
                    upload + download,
                    row["samples"],
                ]
            )
        return 0
    finally:
        store.close()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="traffic.py")
    sub = parser.add_subparsers(dest="command", required=True)

    serve_parser = sub.add_parser("serve")
    serve_parser.add_argument("--config-path", required=True)
    serve_parser.add_argument("--state-dir")
    serve_parser.add_argument("--host", default=DEFAULT_HOST)
    serve_parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    serve_parser.add_argument("--interval", type=float, default=DEFAULT_INTERVAL)
    serve_parser.set_defaults(func=serve)

    status_parser = sub.add_parser("status")
    status_parser.add_argument("--state-dir")
    status_parser.set_defaults(func=command_status)

    stop_parser = sub.add_parser("stop")
    stop_parser.add_argument("--state-dir")
    stop_parser.set_defaults(func=command_stop)

    report_parser = sub.add_parser("report")
    report_parser.add_argument("--state-dir")
    report_parser.add_argument("--since", default="today")
    report_parser.add_argument("--limit", type=int, default=50)
    report_parser.set_defaults(func=report)

    live_parser = sub.add_parser("live")
    live_parser.add_argument("--state-dir")
    live_parser.set_defaults(func=live_report)

    export_parser = sub.add_parser("export")
    export_parser.add_argument("--state-dir")
    export_parser.add_argument("--since", default="today")
    export_parser.add_argument("--until")
    export_parser.set_defaults(func=export_csv)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return int(args.func(args))
    except (TrafficError, ValueError) as exc:
        print(f"clashctl traffic: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
