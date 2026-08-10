from __future__ import annotations

import json
import socket
import subprocess  # nosec B404  # nosemgrep
import sys
import tempfile
import threading
import time
import unittest
import urllib.request
from unittest import mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TRAFFIC_DIR = ROOT / "scripts" / "traffic"
sys.path.insert(0, str(TRAFFIC_DIR))

from model import ConnectionSample, Identity, identify_connection  # noqa: E402
from server import DashboardServer  # noqa: E402
from store import TrafficStore, format_utc  # noqa: E402
import traffic as traffic_cli  # noqa: E402


def start_json_server(payloads: list[dict]):
    from http.server import BaseHTTPRequestHandler, HTTPServer

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, _format, *_args):
            return

        def do_GET(self):  # noqa: N802
            body = json.dumps(payloads.pop(0)).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    server = HTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, thread


def stop_http_server(server, thread) -> None:
    server.shutdown()
    server.server_close()
    thread.join(timeout=2)


def traffic_payload(upload: int, download: int) -> dict:
    return {
        "uploadTotal": upload,
        "downloadTotal": download,
        "connections": [
            {
                "id": "connection-1",
                "upload": upload,
                "download": download,
                "metadata": {
                    "inboundUser": "alice",
                    "host": "private.example",
                    "processPath": "/sensitive/process",
                },
            }
        ],
    }


def start_incrementing_controller(counter: dict[str, int]):
    from http.server import BaseHTTPRequestHandler, HTTPServer

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, _format, *_args):
            return

        def do_GET(self):  # noqa: N802
            counter["value"] += 1
            value = counter["value"] * 1024
            body = json.dumps(
                {
                    "uploadTotal": value,
                    "downloadTotal": value * 2,
                    "connections": [
                        {
                            "id": "live-connection",
                            "upload": value,
                            "download": value * 2,
                            "metadata": {"inboundUser": "alice"},
                        }
                    ],
                }
            ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    server = HTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, thread


def available_loopback_port() -> int:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


def start_traffic_process(config_path: Path, state_dir: Path, port: int):
    return subprocess.Popen(  # nosec B603  # nosemgrep
        [
            sys.executable,
            str(TRAFFIC_DIR / "traffic.py"),
            "serve",
            "--config-path",
            str(config_path),
            "--state-dir",
            str(state_dir),
            "--port",
            str(port),
            "--interval",
            "1",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        text=True,
    )


def load_loopback_json(port: int, path: str, timeout: float = 2) -> dict:
    url = f"http://127.0.0.1:{port}{path}"
    with urllib.request.urlopen(url, timeout=timeout) as response:  # nosec B310
        return json.load(response)


def wait_for_collector_health(port: int, counter: dict[str, int]) -> dict | None:
    deadline = time.time() + 6
    while time.time() < deadline:
        try:
            health = load_loopback_json(port, "/api/health", timeout=1)
            if counter["value"] >= 2:
                return health
        except OSError:
            pass
        time.sleep(0.15)
    return None


def stop_traffic_process(state_dir: Path):
    return subprocess.run(  # nosec B603  # nosemgrep
        [
            sys.executable,
            str(TRAFFIC_DIR / "traffic.py"),
            "stop",
            "--state-dir",
            str(state_dir),
        ],
        text=True,
        capture_output=True,
        timeout=5,
        check=False,
    )


class IdentityTests(unittest.TestCase):
    def test_identity_precedence_prefers_authenticated_user(self) -> None:
        identity = identify_connection(
            {"inboundUser": "alice", "uid": 1000, "sourceIP": "10.0.0.8"}
        )
        self.assertEqual(identity.key, "account:alice")
        self.assertEqual(identity.confidence, "high")

    def test_uid_zero_falls_back_to_source_ip(self) -> None:
        identity = identify_connection({"uid": 0, "sourceIP": "127.0.0.1"})
        self.assertEqual(identity.key, "source-ip:127.0.0.1")
        self.assertEqual(identity.confidence, "low")

    def test_uid_zero_without_source_is_unattributed(self) -> None:
        identity = identify_connection({"uid": 0})
        self.assertEqual(identity.key, "unknown")


class StoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.store = TrafficStore(Path(self.temp_dir.name) / "traffic.sqlite3")
        self.alice = Identity("account:alice", "alice", "account", "high")

    def tearDown(self) -> None:
        self.store.close()
        self.temp_dir.cleanup()

    def sample(self, upload: int, download: int) -> ConnectionSample:
        return ConnectionSample("conn-1", self.alice, upload, download)

    def test_first_sample_is_baseline_and_second_records_only_delta(self) -> None:
        self.store.record_sample([self.sample(100, 500)], 1_700_000_000)
        self.assertEqual(self.store.users(1_699_999_900), [])

        result = self.store.record_sample([self.sample(180, 760)], 1_700_000_005)
        self.assertEqual(result["upload"], 80)
        self.assertEqual(result["download"], 260)
        users = self.store.users(1_699_999_900, 1_700_000_100)
        self.assertEqual(len(users), 1)
        self.assertEqual(users[0]["upload"], 80)
        self.assertEqual(users[0]["download"], 260)

    def test_counter_reset_counts_new_counter_value(self) -> None:
        self.store.record_sample([self.sample(100, 500)], 1_700_000_000)
        result = self.store.record_sample([self.sample(10, 20)], 1_700_000_005)
        self.assertEqual(result["upload"], 10)
        self.assertEqual(result["download"], 20)

    def test_database_does_not_store_destination_or_process_fields(self) -> None:
        schema_queries = (
            "PRAGMA table_info(traffic_minute)",
            "PRAGMA table_info(connection_state)",
            "PRAGMA table_info(live_identity)",
        )
        columns = {
            row[1]
            for query in schema_queries
            for row in self.store.connection.execute(query)
        }
        forbidden = {"host", "destination", "process", "process_path", "source_port"}
        self.assertTrue(columns.isdisjoint(forbidden))


class DashboardServerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.store = TrafficStore(Path(self.temp_dir.name) / "traffic.sqlite3")
        identity = Identity("account:alice", "alice", "account", "high")
        observed_at = int(time.time())
        self.store.record_sample(
            [ConnectionSample("conn", identity, 100, 200)], observed_at
        )
        self.store.record_sample(
            [ConnectionSample("conn", identity, 150, 350)], observed_at + 5
        )
        self.server = DashboardServer(
            ("127.0.0.1", 0), self.store, b"<html>ok</html>", 5.0
        )
        self.base_url = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self) -> None:
        self.server.server_close()
        self.store.close()
        self.temp_dir.cleanup()

    def request(self, path: str):
        result = {}
        error = {}

        def client() -> None:
            try:
                result["response"] = urllib.request.urlopen(  # nosec B310  # nosemgrep
                    self.base_url + path, timeout=2
                )
            except Exception as exc:  # re-raised in the test thread
                error["exception"] = exc

        thread = threading.Thread(target=client)
        thread.start()
        self.server.handle_request()
        thread.join(timeout=2)
        if "exception" in error:
            raise error["exception"]
        return result["response"]

    def test_summary_api_can_query_sqlite(self) -> None:
        with self.request("/api/summary?since=7d") as response:
            payload = json.load(response)
        self.assertEqual(response.status, 200)
        self.assertEqual(payload["total"], 200)
        self.assertEqual(payload["users"][0]["display_name"], "alice")
        self.assertIsNone(payload["users"][0]["user_id"])

    def test_security_header_is_not_duplicated(self) -> None:
        with self.request("/") as response:
            values = response.headers.get_all("X-Content-Type-Options")
        self.assertEqual(values, ["nosniff"])


class AdditionalStoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.store = TrafficStore(Path(self.temp_dir.name) / "traffic.sqlite3")

    def tearDown(self) -> None:
        self.store.close()
        self.temp_dir.cleanup()

    def test_multiple_connections_are_aggregated_by_identity(self) -> None:
        identity = Identity("account:alice", "alice", "account", "high")
        first = [
            ConnectionSample("one", identity, 10, 20),
            ConnectionSample("two", identity, 30, 40),
        ]
        second = [
            ConnectionSample("one", identity, 20, 50),
            ConnectionSample("two", identity, 60, 100),
        ]
        self.store.record_sample(first, 1_700_000_000)
        self.store.record_sample(second, 1_700_000_005)
        users = self.store.users(1_699_999_900, 1_700_000_100)
        self.assertEqual(users[0]["upload"], 40)
        self.assertEqual(users[0]["download"], 90)
        live = self.store.live()[0]
        self.assertEqual(live["connection_count"], 2)
        self.assertIsNone(live["user_id"])

    def test_stale_connection_state_is_removed(self) -> None:
        identity = Identity("account:alice", "alice", "account", "high")
        self.store.record_sample(
            [ConnectionSample("stale", identity, 1, 1)], 1_700_000_000
        )
        self.store.record_sample([], 1_700_000_181)
        count = self.store.connection.execute(
            "SELECT COUNT(*) FROM connection_state"
        ).fetchone()[0]
        self.assertEqual(count, 0)
        self.assertEqual(self.store.live(), [])

    def test_summary_reports_attribution_coverage(self) -> None:
        known = Identity("account:alice", "alice", "account", "high")
        unknown = Identity("unknown", "Unattributed", "unknown", "low")
        self.store.record_sample(
            [
                ConnectionSample("known", known, 0, 0),
                ConnectionSample("unknown", unknown, 0, 0),
            ],
            1_700_000_000,
        )
        self.store.record_sample(
            [
                ConnectionSample("known", known, 25, 75),
                ConnectionSample("unknown", unknown, 20, 80),
            ],
            1_700_000_005,
        )
        summary = self.store.summary(1_699_999_900)
        self.assertEqual(summary["total"], 200)
        self.assertEqual(summary["attribution_percent"], 50.0)


class CollectorTests(unittest.TestCase):
    def test_runtime_config_reads_only_top_level_controller_and_secret(self) -> None:
        from collector import runtime_connection_config

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "runtime.yaml"
            path.write_text(
                "external-controller: '0.0.0.0:9090'\n"
                "secret: \"safe-secret\"\n"
                "proxy-groups:\n"
                "  - secret: nested-value\n",
                encoding="utf-8",
            )
            self.assertEqual(
                runtime_connection_config(path), ("0.0.0.0:9090", "safe-secret")
            )

    def test_wildcard_controller_is_forced_to_loopback(self) -> None:
        from collector import controller_address

        self.assertEqual(controller_address("0.0.0.0:9090"), "127.0.0.1:9090")
        self.assertEqual(controller_address("[::]:9091"), "127.0.0.1:9091")
        self.assertEqual(controller_address("[::1]:9092"), "[::1]:9092")

    def test_controller_address_rejects_url_syntax_and_invalid_ports(self) -> None:
        from collector import controller_address

        for value in (
            "http://example.com:9090",
            "file:///tmp/controller",
            "user@example.com:9090",
            "127.0.0.1:9090/connections",
            "127.0.0.1:0",
            "127.0.0.1:65536",
        ):
            with self.subTest(value=value), self.assertRaises(ValueError):
                controller_address(value)

    def test_collect_once_reads_mihomo_payload_and_never_persists_destination(self) -> None:
        from collector import collect_once

        payloads = [traffic_payload(10, 20), traffic_payload(30, 70)]
        payloads[0].update(uploadTotal=100, downloadTotal=200)
        payloads[1].update(uploadTotal=150, downloadTotal=280)
        server, thread = start_json_server(payloads)
        try:
            with tempfile.TemporaryDirectory() as directory:
                store = TrafficStore(Path(directory) / "traffic.sqlite3")
                try:
                    address = f"127.0.0.1:{server.server_port}"
                    collect_once(store, address, "")
                    result = collect_once(store, address, "")
                    self.assertEqual((result["upload"], result["download"]), (20, 50))
                    schema = "\n".join(
                        row[0]
                        for row in store.connection.execute(
                            "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL"
                        )
                    )
                    rows = repr(
                        store.connection.execute(
                            "SELECT * FROM connection_state"
                        ).fetchall()
                    )
                    self.assertNotIn("private.example", schema + rows)
                    self.assertNotIn("/sensitive/process", schema + rows)
                finally:
                    store.close()
        finally:
            stop_http_server(server, thread)



class CliTests(unittest.TestCase):
    def setUp(self) -> None:
        self.subprocess = subprocess
        self.temp_dir = tempfile.TemporaryDirectory()
        self.state_dir = Path(self.temp_dir.name) / "state"
        store = TrafficStore(self.state_dir / "traffic.sqlite3")
        now = int(time.time())
        identity = Identity("account:alice", "alice", "account", "high")
        store.record_sample([ConnectionSample("c", identity, 0, 0)], now)
        store.record_sample([ConnectionSample("c", identity, 1024, 2048)], now + 1)
        store.close()

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def run_cli(self, *args: str):
        return self.subprocess.run(  # nosec B603  # nosemgrep
            [sys.executable, str(TRAFFIC_DIR / "traffic.py"), *args],
            text=True,
            capture_output=True,
            check=False,
        )

    def test_report_prints_identity_and_totals(self) -> None:
        result = self.run_cli(
            "report", "--state-dir", str(self.state_dir), "--since", "24h"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("alice", result.stdout)
        self.assertIn("3.0 KB", result.stdout)

    def test_export_writes_machine_readable_csv(self) -> None:
        result = self.run_cli(
            "export", "--state-dir", str(self.state_dir), "--since", "24h"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "bucket_start_utc,user_id,identity,identity_kind", result.stdout
        )
        self.assertIn(
            ",,alice,account,high,1024,2048,3072,",
            result.stdout,
        )


class SamplingPresenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.store = TrafficStore(Path(self.temp_dir.name) / "traffic.sqlite3")

    def tearDown(self) -> None:
        self.store.close()
        self.temp_dir.cleanup()

    def test_series_distinguishes_sampled_zero_from_missing_interval(self) -> None:
        identity = Identity("account:alice", "alice", "account", "high")
        start = 1_700_000_000
        self.store.record_sample([ConnectionSample("c", identity, 0, 0)], start)
        series = self.store.series(start - start % 300, start - start % 300 + 600)
        sampled = [point for point in series if point["sampled"]]
        missing = [point for point in series if not point["sampled"]]
        self.assertEqual(len(sampled), 1)
        self.assertEqual(sampled[0]["upload"] + sampled[0]["download"], 0)
        self.assertEqual(len(missing), 1)

    def test_failed_controller_read_does_not_mark_interval_sampled(self) -> None:
        self.store.record_error("unreachable")
        start = 1_700_000_000
        series = self.store.series(start - start % 300, start - start % 300 + 300)
        self.assertFalse(series[0]["sampled"])


class ProcessLifecycleTests(unittest.TestCase):
    def test_bind_failure_removes_pid_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state_dir = root / "state"
            config_path = root / "runtime.yaml"
            config_path.write_text(
                "external-controller: 127.0.0.1:9\nsecret: ''\n",
                encoding="utf-8",
            )
            blocker = socket.socket()
            blocker.bind(("127.0.0.1", 0))
            blocker.listen(1)
            port = blocker.getsockname()[1]
            try:
                result = subprocess.run(  # nosec B603  # nosemgrep
                    [
                        sys.executable,
                        str(TRAFFIC_DIR / "traffic.py"),
                        "serve",
                        "--config-path",
                        str(config_path),
                        "--state-dir",
                        str(state_dir),
                        "--port",
                        str(port),
                    ],
                    text=True,
                    capture_output=True,
                    timeout=5,
                    check=False,
                )
            finally:
                blocker.close()
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((state_dir / "traffic.pid").exists())

    def test_real_process_health_sampling_and_stop(self) -> None:
        counter = {"value": 0}
        controller, controller_thread = start_incrementing_controller(counter)
        try:
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                state_dir = root / "state"
                config_path = root / "runtime.yaml"
                config_path.write_text(
                    f"external-controller: 127.0.0.1:{controller.server_port}\n"
                    "secret: ''\n",
                    encoding="utf-8",
                )
                dashboard_port = available_loopback_port()
                process = start_traffic_process(config_path, state_dir, dashboard_port)
                try:
                    health = wait_for_collector_health(dashboard_port, counter)
                    self.assertIsNotNone(health)
                    self.assertTrue(health["controller_reachable"])
                    summary = load_loopback_json(
                        dashboard_port, "/api/summary?since=24h"
                    )
                    self.assertGreater(summary["total"], 0)
                    stop = stop_traffic_process(state_dir)
                    self.assertEqual(stop.returncode, 0, stop.stderr)
                    process.wait(timeout=5)
                    self.assertFalse((state_dir / "traffic.pid").exists())
                finally:
                    if process.poll() is None:
                        process.terminate()
                        process.wait(timeout=5)
        finally:
            stop_http_server(controller, controller_thread)



class InstallLifecycleTests(unittest.TestCase):
    def test_uninstall_stops_traffic_before_removing_installation(self) -> None:
        text = (ROOT / "uninstall.sh").read_text(encoding="utf-8")
        self.assertLess(text.index("traffic_stop"), text.index('rm -rf "$CLASHCTL_HOME"'))


class ModelEdgeTests(unittest.TestCase):
    def test_parse_and_normalize_edge_cases(self) -> None:
        from model import connection_id, normalize_connection, parse_int

        self.assertEqual(parse_int("12"), 12)
        self.assertEqual(parse_int(-5), 0)
        self.assertEqual(parse_int("bad"), 0)
        self.assertEqual(connection_id({"id": "explicit"}), "explicit")
        sample = normalize_connection(
            {
                "upload": "3",
                "download": "7",
                "start": "now",
                "metadata": {"sourceIP": "10.0.0.8", "sourcePort": 1},
            }
        )
        self.assertTrue(sample.connection_id.startswith("synthetic:"))
        self.assertEqual(sample.identity.kind, "source-ip")
        self.assertEqual((sample.upload, sample.download), (3, 7))

    def test_positive_uid_and_unknown_identity(self) -> None:
        positive = identify_connection({"uid": 999999})
        self.assertEqual(positive.key, "uid:999999")
        self.assertEqual(positive.confidence, "medium")
        self.assertEqual(identify_connection({}).key, "unknown")


class StoreRangeTests(unittest.TestCase):
    def test_time_range_parsing_and_formatting(self) -> None:
        now = 1_800_000_000
        self.assertEqual(TrafficStore.since_value("24h", now), now - 86400)
        self.assertEqual(TrafficStore.since_value("7d", now), now - 604800)
        self.assertEqual(TrafficStore.since_value("2", now), now - 7200)
        self.assertEqual(
            TrafficStore.since_value("2026-08-10T00:00:00Z"),
            1786320000,
        )
        self.assertIsNone(format_utc(None))
        self.assertTrue(format_utc(0).endswith("Z"))
        with self.assertRaises(ValueError):
            TrafficStore.since_value("not-a-range", now)


class DashboardRouteTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.store = TrafficStore(Path(self.temp_dir.name) / "traffic.sqlite3")
        self.server = DashboardServer(
            ("127.0.0.1", 0), self.store, b"<html>ok</html>", 5.0
        )
        self.base_url = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self) -> None:
        self.server.server_close()
        self.store.close()
        self.temp_dir.cleanup()

    def request(self, path: str):
        result = {}

        def client() -> None:
            try:
                result["response"] = urllib.request.urlopen(  # nosec B310  # nosemgrep
                    self.base_url + path, timeout=2
                )
            except Exception as exc:
                result["error"] = exc

        thread = threading.Thread(target=client)
        thread.start()
        self.server.handle_request()
        thread.join(timeout=2)
        return result

    def test_health_range_live_and_not_found_routes(self) -> None:
        for path in ("/api/health", "/api/range?since=24h", "/api/live"):
            result = self.request(path)
            self.assertNotIn("error", result)
            with result["response"] as response:
                self.assertEqual(response.status, 200)
                self.assertIsInstance(json.load(response), dict)
        result = self.request("/missing")
        error = result["error"]
        try:
            self.assertEqual(error.code, 404)
        finally:
            error.close()

    def test_invalid_range_returns_400(self) -> None:
        result = self.request("/api/range?since=invalid-range")
        error = result["error"]
        try:
            self.assertEqual(error.code, 400)
        finally:
            error.close()


class CollectorLifecycleUnitTests(unittest.TestCase):
    def test_stale_pid_is_replaced_and_removed(self) -> None:
        from collector import acquire_pid_file, is_running, pid_path, read_pid, remove_pid_file

        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            pid_path(state).write_text("99999999", encoding="ascii")
            acquire_pid_file(state)
            self.assertEqual(read_pid(state), __import__("os").getpid())
            running, pid = is_running(state)
            self.assertFalse(running)
            self.assertEqual(pid, __import__("os").getpid())
            remove_pid_file(state)
            self.assertIsNone(read_pid(state))

    def test_missing_runtime_config_and_bad_controller(self) -> None:
        from collector import TrafficError, controller_address, runtime_connection_config

        with self.assertRaises(TrafficError):
            runtime_connection_config(Path("/definitely/missing/config.yaml"))
        with self.assertRaises(ValueError):
            controller_address("127.0.0.1:not-a-port")


class DirectCliTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.state_dir = Path(self.temp_dir.name) / "state"
        store = TrafficStore(self.state_dir / "traffic.sqlite3")
        now = int(time.time())
        identity = Identity("account:alice", "alice", "account", "high")
        store.record_sample([ConnectionSample("direct", identity, 0, 0)], now)
        store.record_sample([ConnectionSample("direct", identity, 1024, 2048)], now + 1)
        store.close()

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def namespace(self, **kwargs):
        import argparse

        return argparse.Namespace(state_dir=str(self.state_dir), **kwargs)

    def capture(self, function, args):
        import contextlib
        import io

        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            result = function(args)
        return result, output.getvalue()

    def test_direct_report_live_export_status_stop_and_helpers(self) -> None:
        result, output = self.capture(
            traffic_cli.report, self.namespace(since="24h", limit=10)
        )
        self.assertEqual(result, 0)
        self.assertIn("alice", output)
        result, output = self.capture(traffic_cli.live_report, self.namespace())
        self.assertEqual(result, 0)
        self.assertIn("alice", output)
        result, output = self.capture(
            traffic_cli.export_csv,
            self.namespace(since="24h", until=None),
        )
        self.assertEqual(result, 0)
        self.assertIn("total_bytes", output)
        self.assertIn("user_id", output)
        self.assertNotIn(",account:alice,", output)
        result, output = self.capture(traffic_cli.command_status, self.namespace())
        self.assertEqual(result, 1)
        self.assertIn("collector=stopped", output)
        result, output = self.capture(traffic_cli.command_stop, self.namespace())
        self.assertEqual(result, 0)
        self.assertIn("collector=stopped", output)
        self.assertEqual(traffic_cli.bytes_label(1024), "1.0 KB")
        self.assertEqual(traffic_cli.state_dir_from_arg(str(self.state_dir)), self.state_dir)
        self.assertIn("serve", traffic_cli.build_parser().format_help())

    def test_main_reports_invalid_range(self) -> None:
        import contextlib
        import io

        error = io.StringIO()
        with contextlib.redirect_stderr(error):
            result = traffic_cli.main(
                [
                    "report",
                    "--state-dir",
                    str(self.state_dir),
                    "--since",
                    "bad-range",
                ]
            )
        self.assertEqual(result, 1)
        self.assertIn("无法解析", error.getvalue())


class DashboardMarkupTests(unittest.TestCase):
    def test_chart_empty_overlay_respects_hidden_attribute(self) -> None:
        html = (TRAFFIC_DIR / "dashboard.html").read_text(encoding="utf-8")
        self.assertIn(".chart-empty[hidden] { display: none; }", html)
        self.assertIn("empty.hidden = series.some", html)
        self.assertIn(".hero-card, .card { min-width: 0;", html)
        self.assertIn(".table-wrap { min-width: 0; max-width: 100%;", html)
        self.assertIn("Linux user_id", html)
        self.assertIn("item.user_id", html)


class LinuxSocketUidTests(unittest.TestCase):
    def test_user_id_is_numeric_linux_uid_only(self) -> None:
        from store import linux_user_id

        self.assertEqual(linux_user_id("uid:1009", "linux-user"), 1009)
        self.assertEqual(linux_user_id("uid:0", "linux-user"), 0)
        self.assertIsNone(linux_user_id("account:alice", "account"))
        self.assertIsNone(linux_user_id("source-ip:127.0.0.1", "source-ip"))
        self.assertIsNone(linux_user_id("uid:not-a-number", "linux-user"))

    def proc_line(self, local_port: int, remote_port: int, uid: int) -> str:
        return (
            f"0: 0100007F:{local_port:04X} 0100007F:{remote_port:04X} "
            f"01 00000000:00000000 00:00000000 00000000 {uid} 0 12345 1"
        )

    def test_proc_socket_snapshot_returns_unique_client_uid(self) -> None:
        from collector import proc_socket_uid_snapshot

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "tcp").write_text(
                "sl local_address rem_address st tx_queue tr tm->when retrnsmt uid timeout inode\n"
                + self.proc_line(58392, 7890, 1009)
                + "\n",
                encoding="ascii",
            )
            (root / "tcp6").write_text(
                "sl local_address rem_address st tx_queue tr tm->when retrnsmt uid timeout inode\n"
                + self.proc_line(7890, 58392, 0)
                + "\n",
                encoding="ascii",
            )
            snapshot = proc_socket_uid_snapshot(root)
        self.assertEqual(snapshot[("tcp", 58392)], 1009)
        self.assertEqual(snapshot[("tcp", 7890)], 0)

    def test_proc_socket_snapshot_rejects_ambiguous_port_ownership(self) -> None:
        from collector import proc_socket_uid_snapshot

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            header = (
                "sl local_address rem_address st tx_queue tr tm->when "
                "retrnsmt uid timeout inode\n"
            )
            (root / "tcp").write_text(
                header
                + self.proc_line(50000, 7890, 1009)
                + "\n"
                + self.proc_line(50000, 7890, 1010)
                + "\n",
                encoding="ascii",
            )
            snapshot = proc_socket_uid_snapshot(root)
        self.assertNotIn(("tcp", 50000), snapshot)

    def test_local_socket_uid_uses_loopback_source_only(self) -> None:
        from collector import local_socket_uid

        snapshot = {("tcp", 58392): 1009}
        self.assertEqual(
            local_socket_uid(
                {"sourceIP": "127.0.0.1", "sourcePort": 58392, "network": "tcp"},
                snapshot,
            ),
            1009,
        )
        self.assertIsNone(
            local_socket_uid(
                {"sourceIP": "10.0.0.8", "sourcePort": 58392, "network": "tcp"},
                snapshot,
            )
        )
        self.assertIsNone(
            local_socket_uid(
                {"sourceIP": "127.0.0.1", "sourcePort": 0, "network": "tcp"},
                snapshot,
            )
        )

    def test_normalize_connection_prefers_resolved_socket_uid(self) -> None:
        from model import normalize_connection

        sample = normalize_connection(
            {
                "id": "local",
                "upload": 1,
                "download": 2,
                "metadata": {
                    "uid": 0,
                    "sourceIP": "127.0.0.1",
                    "sourcePort": 58392,
                },
            },
            local_uid=1009,
        )
        self.assertEqual(sample.identity.key, "uid:1009")
        self.assertEqual(sample.identity.kind, "linux-user")

    def test_collect_once_takes_one_snapshot_and_attributes_local_uid(self) -> None:
        from collector import collect_once

        payload = {
            "connections": [
                {
                    "id": "local",
                    "upload": 10,
                    "download": 20,
                    "metadata": {
                        "uid": 0,
                        "sourceIP": "127.0.0.1",
                        "sourcePort": 58392,
                        "network": "tcp",
                    },
                }
            ]
        }
        with tempfile.TemporaryDirectory() as directory:
            store = TrafficStore(Path(directory) / "traffic.sqlite3")
            try:
                with mock.patch("collector.fetch_connections", return_value=payload), mock.patch(
                    "collector.proc_socket_uid_snapshot",
                    return_value={("tcp", 58392): 1009},
                ) as snapshot:
                    collect_once(store, "127.0.0.1:9090", "")
                snapshot.assert_called_once_with()
                row = store.connection.execute(
                    "SELECT identity_key, identity_kind FROM connection_state"
                ).fetchone()
                self.assertEqual(tuple(row), ("uid:1009", "linux-user"))
                live = store.live()[0]
                self.assertEqual(live["user_id"], 1009)
                self.assertIsInstance(live["user_id"], int)
            finally:
                store.close()


if __name__ == "__main__":
    unittest.main()
