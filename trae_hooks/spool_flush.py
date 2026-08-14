#!/usr/bin/env python3
"""Retry local hook spool into Quack. Safe to run from systemd/timer."""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import traceback
from pathlib import Path

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from hook_client import (  # noqa: E402
    env_path,
    load_token,
    open_quack_client,
    pick_uri,
    quack_insert,
    quack_uris,
)


def flush_once(spool_dir: Path, token: str, uri: str) -> int:
    sent = 0
    con = open_quack_client()
    try:
        for path in sorted(spool_dir.glob("hooks-*.jsonl")):
            try:
                lines = path.read_text(encoding="utf-8").splitlines()
            except OSError:
                continue
            remain: list[str] = []
            for line in lines:
                if not line.strip():
                    continue
                try:
                    row = json.loads(line)
                    quack_insert(row, uri, token, con=con)
                    sent += 1
                except Exception:
                    remain.append(line)
                    err = spool_dir / "flush.err"
                    err.write_text(traceback.format_exc(), encoding="utf-8")
            if remain:
                path.write_text("\n".join(remain) + "\n", encoding="utf-8")
            else:
                done = spool_dir / "done"
                done.mkdir(parents=True, exist_ok=True)
                dest = done / path.name
                if dest.exists():
                    dest = done / f"{path.stem}-{int(time.time())}{path.suffix}"
                path.replace(dest)
    finally:
        con.close()
    return sent


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--loop", action="store_true")
    parser.add_argument("--interval", type=float, default=15.0)
    args = parser.parse_args()
    spool_dir = env_path("CLIPVAULT_HOOK_SPOOL", "/var/tmp/clipvault-hooks/spool")
    token_file = env_path(
        "CLIPVAULT_QUACK_TOKEN_FILE",
        "~/Documents/ClipFlow/config/trae-quack.token",
    )
    probe = float(os.environ.get("CLIPVAULT_QUACK_PROBE_SEC", "0.25"))

    def tick() -> None:
        uri = pick_uri(quack_uris(), probe)
        if uri is None:
            return
        token = load_token(token_file)
        n = flush_once(spool_dir, token, uri)
        if n:
            print(f"flushed {n} via {uri}", flush=True)

    if not args.loop:
        tick()
        return 0
    while True:
        try:
            tick()
        except Exception:
            print(traceback.format_exc(), file=sys.stderr, flush=True)
        time.sleep(max(2.0, args.interval))


if __name__ == "__main__":
    raise SystemExit(main())
