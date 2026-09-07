#!/usr/bin/env python3
"""ClipVault Trae store: DuckDB single-writer + Quack + HTTP query API."""

from __future__ import annotations

import argparse
import json
import logging
import os
import signal
import sys
import threading
import time
import traceback
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse

import duckdb

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from row import utc_now  # noqa: E402

LOG = logging.getLogger("clipvault-trae")

INSERT_SQL = """
INSERT INTO hook_events (
    event_id, ts, instance_id, session_id, hook_event, source, cwd,
    workspace_roots, tool_name, llm_tool_name, tool_use_id, prompt,
    last_assistant_message, notification_type, notification_message,
    stop_hook_active, loop_count, tool_input, tool_response,
    raw_json, raw_hash, host, pid
) VALUES (
    ?, ?, ?, ?, ?, ?, ?,
    ?, ?, ?, ?, ?,
    ?, ?, ?,
    ?, ?, ?, ?,
    ?, ?, ?, ?
)
ON CONFLICT (event_id) DO NOTHING
"""

UI_PATH = _HERE / "web" / "sessions.html"
UI_DIR = _HERE / "web"
CLIP_WEB = _HERE.parent / "web"
SCHEMA_PATH = _HERE / "schema.sql"
STATIC_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".mjs": "text/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".map": "application/json; charset=utf-8",
}
DEFAULT_QUACK_EXT = Path.home() / ".duckdb/extensions/v1.5.5/osx_arm64/quack.duckdb_extension"


def json_default(value: Any) -> Any:
    if isinstance(value, datetime):
        return value.isoformat(sep=" ", timespec="seconds")
    return str(value)


class Store:
    def __init__(self, db_path: Path) -> None:
        self.db_path = db_path
        self.lock = threading.Lock()
        db_path.parent.mkdir(parents=True, exist_ok=True)
        self.con = duckdb.connect(str(db_path))
        self.con.execute(SCHEMA_PATH.read_text(encoding="utf-8"))
        LOG.info("opened %s", db_path)

    def load_quack(self) -> None:
        ext = Path(os.environ.get("CLIPVAULT_QUACK_EXTENSION", str(DEFAULT_QUACK_EXT)))
        if ext.is_file():
            self.con.execute(f"LOAD '{ext}'")
            LOG.info("loaded quack extension %s", ext)
            return
        try:
            self.con.execute("INSTALL quack FROM core")
        except Exception as exc:  # noqa: BLE001
            LOG.warning("INSTALL quack FROM core: %s", exc)
            self.con.execute("INSTALL quack FROM core_nightly")
        self.con.execute("LOAD quack")

    def serve_quack(self, uri: str, token: str) -> None:
        self.con.execute(
            "CALL quack_identify(name => 'clipvault-trae', provider => 'clipvault', "
            "hostname => 'localhost', region => 'local', "
            "meta => '{\"role\":\"trae-hooks\"}')"
        )
        result = self.con.execute(
            "CALL quack_serve(?, token := ?, allow_other_hostname := true, disable_ssl := true)",
            [uri, token],
        ).fetchall()
        safe = [(r[0], "<redacted>") if len(r) >= 2 else r for r in result]
        LOG.info("quack_serve %s -> %s", uri, safe)

    def insert_row(self, row: dict[str, Any]) -> bool:
        params = [
            row.get("event_id"),
            row.get("ts") or utc_now(),
            row.get("instance_id"),
            row.get("session_id"),
            row.get("hook_event"),
            row.get("source") or "trae",
            row.get("cwd"),
            row.get("workspace_roots"),
            row.get("tool_name"),
            row.get("llm_tool_name"),
            row.get("tool_use_id"),
            row.get("prompt"),
            row.get("last_assistant_message"),
            row.get("notification_type"),
            row.get("notification_message"),
            row.get("stop_hook_active"),
            row.get("loop_count"),
            row.get("tool_input"),
            row.get("tool_response"),
            row.get("raw_json"),
            row.get("raw_hash"),
            row.get("host"),
            row.get("pid"),
        ]
        with self.lock:
            self.con.execute(INSERT_SQL, params)
            exists = self.con.execute(
                "SELECT 1 FROM hook_events WHERE event_id = ? LIMIT 1",
                [row.get("event_id")],
            ).fetchone()
        return bool(exists)

    def query(self, sql: str, params: list[Any] | None = None) -> list[dict[str, Any]]:
        with self.lock:
            rel = self.con.execute(sql, params or [])
            cols = [d[0] for d in rel.description]
            rows = rel.fetchall()
        return [dict(zip(cols, row, strict=False)) for row in rows]

    def health(self) -> dict[str, Any]:
        rows = self.query(
            "SELECT count(*) AS n, max(ts) AS last_ts FROM hook_events"
        )
        stats = rows[0] if rows else {"n": 0, "last_ts": None}
        return {
            "ok": True,
            "role": "clipvault-trae",
            "duckdb": duckdb.__version__,
            "db": str(self.db_path),
            "events": stats.get("n"),
            "last_ts": json_default(stats.get("last_ts")) if stats.get("last_ts") else None,
        }

    def checkpoint(self) -> None:
        with self.lock:
            self.con.execute("CHECKPOINT")

    def stop_quack(self, uri: str) -> None:
        try:
            with self.lock:
                self.con.execute("CALL quack_stop(?)", [uri])
        except Exception as exc:  # noqa: BLE001
            LOG.warning("quack_stop: %s", exc)

    def close(self) -> None:
        try:
            self.checkpoint()
        except Exception as exc:  # noqa: BLE001
            LOG.warning("checkpoint: %s", exc)
        self.con.close()


def drain_spool(store: Store, spool_dir: Path) -> int:
    if not spool_dir.is_dir():
        return 0
    ingested = 0
    for path in sorted(spool_dir.glob("hooks-*.jsonl")):
        done_dir = spool_dir / "done"
        fail_dir = spool_dir / "fail"
        remaining: list[str] = []
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except OSError:
            continue
        for line in lines:
            if not line.strip():
                continue
            try:
                row = json.loads(line)
                store.insert_row(row)
                ingested += 1
            except Exception:  # noqa: BLE001
                fail_dir.mkdir(parents=True, exist_ok=True)
                fail_path = fail_dir / (path.name + ".err")
                with fail_path.open("a", encoding="utf-8") as fh:
                    fh.write(line + "\n")
                    fh.write(traceback.format_exc() + "\n")
                remaining.append(line)
        if remaining:
            path.write_text("\n".join(remaining) + "\n", encoding="utf-8")
        else:
            done_dir.mkdir(parents=True, exist_ok=True)
            dest = done_dir / path.name
            if dest.exists():
                dest = done_dir / f"{path.stem}-{int(time.time())}{path.suffix}"
            path.replace(dest)
    return ingested


def make_handler(store: Store, http_origin_note: str) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt: str, *args: Any) -> None:
            LOG.info("%s %s", self.address_string(), fmt % args)

        def _send(self, status: int, body: bytes, content_type: str) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def _json(self, status: int, payload: Any) -> None:
            raw = json.dumps(payload, ensure_ascii=False, default=json_default).encode(
                "utf-8"
            )
            self._send(status, raw, "application/json; charset=utf-8")

        def do_OPTIONS(self) -> None:  # noqa: N802
            self.send_response(204)
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")
            self.end_headers()

        def do_GET(self) -> None:  # noqa: N802
            parsed = urlparse(self.path)
            path = parsed.path
            qs = parse_qs(parsed.query)
            if path in ("/healthz", "/api/health"):
                self._json(200, store.health())
                return
            if path in ("/", "/index.html", "/trae", "/sessions"):
                html = UI_PATH.read_bytes() if UI_PATH.is_file() else b"<h1>missing UI</h1>"
                self._send(200, html, "text/html; charset=utf-8")
                return
            static = _static_file(path)
            if static is not None:
                body, ctype = static
                self._send(200, body, ctype)
                return
            if path == "/api/sessions":
                limit = _int(qs.get("limit", ["50"])[0], 50, 1, 200)
                rows = store.query(
                    """
                    SELECT session_id,
                           min(ts) AS first_ts,
                           max(ts) AS last_ts,
                           count(*) AS event_count,
                           count(DISTINCT hook_event) AS hook_kinds,
                           arg_max(cwd, ts) AS cwd,
                           arg_max(instance_id, ts) AS instance_id,
                           arg_max(prompt, CASE WHEN coalesce(prompt, '') = '' THEN NULL ELSE ts END) AS last_prompt
                    FROM hook_events
                    GROUP BY session_id
                    ORDER BY last_ts DESC
                    LIMIT ?
                    """,
                    [limit],
                )
                self._json(200, {"sessions": rows, "note": http_origin_note})
                return
            if path == "/api/events":
                limit = _int(qs.get("limit", ["200"])[0], 200, 1, 500)
                session_id = (qs.get("session_id") or [""])[0]
                hook_event = (qs.get("hook_event") or [""])[0]
                q = (qs.get("q") or [""])[0]
                where = ["1=1"]
                params: list[Any] = []
                if session_id:
                    where.append("session_id = ?")
                    params.append(session_id)
                if hook_event:
                    where.append("hook_event = ?")
                    params.append(hook_event)
                if q:
                    where.append(
                        "(coalesce(prompt,'') ILIKE ? OR coalesce(tool_name,'') ILIKE ? "
                        "OR coalesce(last_assistant_message,'') ILIKE ? "
                        "OR coalesce(raw_json,'') ILIKE ?)"
                    )
                    like = f"%{q}%"
                    params.extend([like, like, like, like])
                params.append(limit)
                rows = store.query(
                    f"""
                    SELECT event_id, ts, instance_id, session_id, hook_event, source,
                           cwd, tool_name, llm_tool_name, tool_use_id, prompt,
                           last_assistant_message, notification_type, notification_message,
                           loop_count, tool_input, tool_response, raw_hash
                    FROM hook_events
                    WHERE {' AND '.join(where)}
                    ORDER BY ts DESC
                    LIMIT ?
                    """,
                    params,
                )
                self._json(200, {"events": rows})
                return
            if path == "/api/event":
                event_id = (qs.get("id") or [""])[0]
                if not event_id:
                    self._json(400, {"error": "id required"})
                    return
                rows = store.query(
                    "SELECT * FROM hook_events WHERE event_id = ? LIMIT 1",
                    [event_id],
                )
                if not rows:
                    self._json(404, {"error": "not found"})
                    return
                self._json(200, {"event": rows[0]})
                return
            self._json(404, {"error": "not found"})

    return Handler


def _static_file(url_path: str) -> tuple[bytes, str] | None:
    name = url_path.lstrip("/")
    if not name or ".." in name or name.startswith("/"):
        return None
    candidates = [UI_DIR / name, CLIP_WEB / name]
    for cand in candidates:
        try:
            resolved = cand.resolve()
        except OSError:
            continue
        roots = []
        for root in (UI_DIR, CLIP_WEB):
            try:
                roots.append(root.resolve())
            except OSError:
                continue
        if not any(resolved == root or root in resolved.parents for root in roots):
            continue
        if not resolved.is_file():
            continue
        ctype = STATIC_TYPES.get(resolved.suffix.lower(), "application/octet-stream")
        return resolved.read_bytes(), ctype
    return None


def _int(raw: str, default: int, lo: int, hi: int) -> int:
    try:
        value = int(raw)
    except ValueError:
        return default
    return max(lo, min(hi, value))


def main() -> int:
    parser = argparse.ArgumentParser(description="ClipVault Trae DuckDB/Quack server")
    parser.add_argument(
        "--home",
        default=os.environ.get("CLIPVAULT_HOME")
        or os.environ.get("KEEPSAKE_HOME")
        or str(Path.home() / "Documents/ClipFlow"),
    )
    parser.add_argument("--quack-uri", default=os.environ.get("CLIPVAULT_QUACK_URI", "quack:127.0.0.1:9494"))
    parser.add_argument("--http-host", default=os.environ.get("CLIPVAULT_TRAE_HTTP_HOST", "127.0.0.1"))
    parser.add_argument("--http-port", type=int, default=int(os.environ.get("CLIPVAULT_TRAE_HTTP_PORT", "9488")))
    parser.add_argument(
        "--token-file",
        default=os.environ.get(
            "CLIPVAULT_QUACK_TOKEN_FILE",
            "",
        ),
    )
    parser.add_argument(
        "--spool",
        default=os.environ.get("CLIPVAULT_HOOK_SPOOL", "/var/tmp/clipvault-hooks/spool"),
    )
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )

    home = Path(args.home).expanduser()
    token_file = Path(args.token_file).expanduser() if args.token_file else home / "config" / "trae-quack.token"
    if not token_file.is_file():
        raise SystemExit(f"token file missing: {token_file}")
    token = token_file.read_text(encoding="utf-8").strip()
    if len(token) < 8:
        raise SystemExit("token too short")

    db_path = home / "trae" / "hook_events.duckdb"
    store = Store(db_path)
    store.load_quack()
    store.serve_quack(args.quack_uri, token)

    spool_dir = Path(args.spool).expanduser()
    stop = threading.Event()

    def drain_loop() -> None:
        while not stop.is_set():
            try:
                n = drain_spool(store, spool_dir)
                if n:
                    LOG.info("spool ingested %s rows", n)
            except Exception:  # noqa: BLE001
                LOG.exception("spool drain failed")
            stop.wait(2.0)

    threading.Thread(target=drain_loop, name="spool-drain", daemon=True).start()

    handler = make_handler(store, f"http://{args.http_host}:{args.http_port}")
    httpd = ThreadingHTTPServer((args.http_host, args.http_port), handler)
    LOG.info("http://%s:%s  quack=%s  db=%s", args.http_host, args.http_port, args.quack_uri, db_path)

    def _handle(signum: int, _frame: object) -> None:
        LOG.info("signal %s", signum)
        stop.set()
        httpd.shutdown()

    signal.signal(signal.SIGTERM, _handle)
    signal.signal(signal.SIGINT, _handle)

    try:
        httpd.serve_forever(poll_interval=0.5)
    finally:
        stop.set()
        store.stop_quack(args.quack_uri)
        store.close()
        LOG.info("exited")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
