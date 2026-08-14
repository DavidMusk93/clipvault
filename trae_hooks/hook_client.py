#!/usr/bin/env python3
"""Trae hook client: spool first, then best-effort Quack INSERT. Always exit 0."""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import traceback
from pathlib import Path

# Allow `python hook_client.py` from any cwd.
_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from row import parse_stdin, row_from_payload  # noqa: E402

INSERT_COLS = (
    "event_id",
    "ts",
    "instance_id",
    "session_id",
    "hook_event",
    "source",
    "cwd",
    "workspace_roots",
    "tool_name",
    "llm_tool_name",
    "tool_use_id",
    "prompt",
    "last_assistant_message",
    "notification_type",
    "notification_message",
    "stop_hook_active",
    "loop_count",
    "tool_input",
    "tool_response",
    "raw_json",
    "raw_hash",
    "host",
    "pid",
)


def env_path(name: str, default: str) -> Path:
    return Path(os.environ.get(name, default)).expanduser()


def load_token(path: Path) -> str:
    return path.read_text(encoding="utf-8").strip()


def append_spool(spool_dir: Path, row: dict) -> Path:
    spool_dir.mkdir(parents=True, exist_ok=True)
    day = time.strftime("%Y%m%d")
    path = spool_dir / f"hooks-{day}.jsonl"
    line = json.dumps(row, ensure_ascii=False, default=str) + "\n"
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(fd, line.encode("utf-8"))
        os.fsync(fd)
    finally:
        os.close(fd)
    return path


def sql_lit(value) -> str:
    if value is None:
        return "NULL"
    if isinstance(value, bool):
        return "TRUE" if value else "FALSE"
    if isinstance(value, int) and not isinstance(value, bool):
        return str(value)
    text = value.isoformat(sep=" ") if hasattr(value, "isoformat") else str(value)
    return "'" + text.replace("'", "''") + "'"


def build_insert_sql(row: dict) -> str:
    cols = ", ".join(INSERT_COLS)
    vals = ", ".join(sql_lit(row.get(c)) for c in INSERT_COLS)
    return f"INSERT INTO hook_events ({cols}) VALUES ({vals}) ON CONFLICT (event_id) DO NOTHING"


def quack_uris() -> list[str]:
    raw = os.environ.get("CLIPVAULT_QUACK_URI", "quack:127.0.0.1:9494")
    return [part.strip() for part in raw.split(",") if part.strip()]


def parse_quack_hostport(uri: str) -> tuple[str, int]:
    rest = uri
    if rest.startswith("quack:"):
        rest = rest[len("quack:") :]
    host, sep, port_s = rest.rpartition(":")
    if not sep:
        return rest or "127.0.0.1", 9494
    try:
        return host or "127.0.0.1", int(port_s)
    except ValueError:
        return rest, 9494


def tcp_ready(uri: str, timeout: float = 0.2) -> bool:
    import socket

    host, port = parse_quack_hostport(uri)
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        sock.connect((host, port))
        return True
    except OSError:
        return False
    finally:
        sock.close()


def quack_extension() -> Path | None:
    env = os.environ.get("CLIPVAULT_QUACK_EXTENSION")
    if env and Path(env).is_file():
        return Path(env)
    import platform

    sysname = platform.system().lower()
    machine = platform.machine().lower()
    if sysname == "darwin":
        plat = "osx_arm64" if machine in ("arm64", "aarch64") else "osx_amd64"
    else:
        plat = "linux_amd64" if machine in ("x86_64", "amd64") else "linux_arm64"
    cand = Path.home() / ".duckdb/extensions/v1.5.5" / plat / "quack.duckdb_extension"
    return cand if cand.is_file() else None


def open_quack_client() -> object:
    import duckdb

    con = duckdb.connect(":memory:")
    ext = quack_extension()
    if ext is not None:
        con.execute(f"LOAD '{ext}'")
        return con
    try:
        con.execute("INSTALL quack FROM core")
    except Exception:
        con.execute("INSTALL quack FROM core_nightly")
    con.execute("LOAD quack")
    return con


def quack_insert(row: dict, uri: str, token: str, con: object | None = None) -> None:
    own = con is None
    if own:
        con = open_quack_client()
    try:
        sql = build_insert_sql(row)
        con.execute(
            "FROM quack_query(?, ?, token := ?, disable_ssl := true)",
            [uri, sql, token],
        )
    finally:
        if own:
            con.close()


def pick_uri(uris: list[str], probe: float) -> str | None:
    for uri in uris:
        if tcp_ready(uri, timeout=probe):
            return uri
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description="ClipVault Trae hook client")
    parser.add_argument("--event", default="", help="hook event name")
    args = parser.parse_args()
    hook_event = args.event or os.environ.get("CLIPVAULT_HOOK_EVENT") or ""

    instance_id = os.environ.get("CLIPVAULT_INSTANCE_ID", "mac-work")
    source = os.environ.get("CLIPVAULT_HOOK_SOURCE", "trae")
    spool_dir = env_path("CLIPVAULT_HOOK_SPOOL", "/var/tmp/clipvault-hooks/spool")
    token_file = env_path(
        "CLIPVAULT_QUACK_TOKEN_FILE",
        "~/Documents/ClipFlow/config/trae-quack.token",
    )
    skip_quack = os.environ.get("CLIPVAULT_HOOK_SPOOL_ONLY", "") in ("1", "true", "yes")
    probe = float(os.environ.get("CLIPVAULT_QUACK_PROBE_SEC", "0.2"))

    try:
        raw = sys.stdin.read()
        payload = parse_stdin(raw, hook_event or None)
        row = row_from_payload(
            payload,
            hook_event=hook_event or None,
            instance_id=instance_id,
            source=source,
        )
        append_spool(spool_dir, row)
    except Exception:
        # Last resort: do not block Trae.
        try:
            Path("/var/tmp/clipvault-hooks").mkdir(parents=True, exist_ok=True)
            Path("/var/tmp/clipvault-hooks/client.err").write_text(
                traceback.format_exc(), encoding="utf-8"
            )
        except Exception:
            pass
        return 0

    if skip_quack:
        return 0
    try:
        uri = pick_uri(quack_uris(), probe)
        if uri is None:
            return 0
        token = load_token(token_file)
        quack_insert(row, uri, token)
    except Exception:
        try:
            err = Path("/var/tmp/clipvault-hooks/quack.err")
            err.parent.mkdir(parents=True, exist_ok=True)
            err.write_text(traceback.format_exc(), encoding="utf-8")
        except Exception:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
