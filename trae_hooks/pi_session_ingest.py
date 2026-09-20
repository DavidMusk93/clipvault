#!/usr/bin/env python3
"""Backfill the ClipVault metrics plane from pi session JSONL.

pi writes one JSONL per session under ~/.pi/agent/sessions/<slug>/<ts>_<id>.jsonl.
Every assistant message carries `usage` (input/output/cacheRead/cacheWrite/
reasoning/cost) and the system message carries `sections` (preamble/tools/rules/
docs/project_context/skills). The session hook throws all of that away; this
script rebuilds it into llm_usage + turn_context.

Why cold path is the source of truth
------------------------------------
* lossless and retroactive -- works on every session already on disk;
* has the full system-prompt sections, which the hook payload never carries;
* only ttft is missing (JSONL does not store it), so tok_s_decode stays NULL
  and tok_s_e2e is computed from consecutive entry timestamps.

Idempotent: deterministic primary key (<session_id>:<message_id>) + ON CONFLICT
DO NOTHING, so re-running over the same file is a no-op.

Usage
-----
    pi_session_ingest.py --dry-run                 # parse + report, write nothing
    pi_session_ingest.py --since 30                # last 30 days -> Quack
    pi_session_ingest.py --session-id <id>         # one session
    pi_session_ingest.py --out metrics.ndjson      # dump rows instead of INSERT
"""

from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from metrics import (  # noqa: E402
    CTX_COLS,
    CTX_TABLE,
    DEFAULT_CHARS_PER_TOKEN,
    MIN_ELAPSED_MS,
    SECTION_COLUMNS,
    USAGE_COLS,
    USAGE_TABLE,
    chunked,
    insert_sql,
    upsert_sql,
)

# Live-only fields the cold path cannot supply; keep them on re-ingest.
USAGE_LIVE_COLS = ("ttft_ms", "decode_ms", "tok_s_decode")

DEFAULT_SESSIONS_DIR = Path.home() / ".pi/agent/sessions"
_TS_RE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})T")
_RE_SKILL_NAME = re.compile(r"<name>([\w.:-]+)</name>")
_RE_SKILL_PATH = re.compile(r"/skills/([\w.:-]+)/")
_RE_MEMORY = re.compile(r"nowledgemem://memory/([\w.:-]+)")
_RE_TOOL_LINE = re.compile(r"^-\s+([\w.:-]+)\s*:", re.M)
# A skill only costs context when its file body is pulled in. writes/edits on the
# skill path return a one-line confirmation, not the skill text, so they are not
# context cost.
_READ_CALL_TOOLS = {"read", "readfile", "read_file", "view", "cat"}
_SHELL_CALL_TOOLS = {"bash", "runcmd", "run_command", "shell", "powershell"}
_RE_READ_CMD = re.compile(r"(^|[|;&]\s*)(cat|bat|less|head|tail|sed|awk|rg|grep|nl)\b")


def skill_from_call(name: Any, args: Any) -> str | None:
    """Skill name if this tool call reads a file under /skills/<name>/."""
    tool = str(name or "").lower()
    a = args if isinstance(args, dict) else {}
    if tool in _READ_CALL_TOOLS:
        hit = _RE_SKILL_PATH.search(str(a.get("path") or a.get("file_path") or ""))
    elif tool in _SHELL_CALL_TOOLS:
        cmd = str(a.get("command") or a.get("cmd") or "")
        hit = _RE_SKILL_PATH.search(cmd) if _RE_READ_CMD.search(cmd) else None
    else:
        return None
    if not hit:
        return None
    name_out = hit.group(1)
    return name_out if name_out.strip(".") else None
INSERT_BATCH = 500


# --------------------------------------------------------------------------- io


def parse_ts(value: Any) -> datetime | None:
    if isinstance(value, (int, float)):
        return datetime.fromtimestamp(float(value) / 1000.0, tz=timezone.utc).replace(tzinfo=None)
    if not isinstance(value, str) or not value:
        return None
    text = value.strip().replace("Z", "+00:00")
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        return None
    if dt.tzinfo is not None:
        dt = dt.astimezone(timezone.utc).replace(tzinfo=None)
    return dt


def content_to_text(content: Any) -> str:
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts: list[str] = []
    for part in content:
        if not isinstance(part, dict):
            continue
        kind = part.get("type")
        if kind in ("text", "thinking"):
            parts.append(str(part.get("text") or part.get("thinking") or ""))
        elif kind == "toolCall":
            args = part.get("arguments")
            parts.append(json.dumps(args, ensure_ascii=False) if args is not None else "")
        elif kind == "toolResult":
            parts.append(content_to_text(part.get("content")))
    return "\n".join(parts)


def load_entries(path: Path) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    with path.open(encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(entry, dict):
                out.append(entry)
    return out


# ---------------------------------------------------------------------- analyse


def _section_chars(sections: dict[str, Any]) -> dict[str, int]:
    return {str(k): len(str(v or "")) for k, v in sections.items()}


def _skill_names(tools_section: str, skills_section: str) -> list[str]:
    names = _RE_SKILL_NAME.findall(skills_section or "")
    if not names:
        names = _RE_TOOL_LINE.findall(tools_section or "")
    return sorted({n for n in names if n})


def analyze(entries: list[dict[str, Any]], *, chars_per_token: float | None = None) -> dict[str, Any]:
    """Single pass -> per-assistant records (no row building yet)."""
    session_id = ""
    cwd = None
    model = None
    records: list[dict[str, Any]] = []

    sections: dict[str, int] = {}
    raw_sections: dict[str, str] = {}
    tools_section = ""
    history_chars = 0
    pending_prompt_chars = 0
    turn_index = -1
    pending_memories: set[str] = set()
    pending_skills: set[str] = set()
    pending_skill_calls: dict[str, str] = {}
    last_rec: dict[str, Any] | None = None

    for entry in entries:
        kind = entry.get("type")
        entry_ts = parse_ts(entry.get("timestamp"))
        msg_ms: int | None = None
        if kind == "session":
            session_id = str(entry.get("id") or "")
            cwd = entry.get("cwd")
        elif kind == "message":
            msg = entry.get("message") or {}
            raw_ms = msg.get("timestamp")
            msg_ms = int(raw_ms) if isinstance(raw_ms, (int, float)) else None
            role = msg.get("role")
            if role == "system":
                # System entries patch `sections` by name; null removes one.
                patch = msg.get("sections")
                if isinstance(patch, dict) and patch:
                    for name, val in patch.items():
                        if val is None:
                            raw_sections.pop(str(name), None)
                        else:
                            raw_sections[str(name)] = str(val)
                elif not raw_sections:
                    raw_sections["system"] = content_to_text(msg.get("content"))
                sections = _section_chars(raw_sections)
                tools_section = raw_sections.get("tools", "")
            elif role == "user":
                pending_prompt_chars += len(content_to_text(msg.get("content")))
            elif role == "toolResult":
                text = content_to_text(msg.get("content"))
                history_chars += len(text)
                pending_memories.update(_RE_MEMORY.findall(text))
                # A skill file read dumps its whole text into context: bill the tokens
                # to the turn whose tool call asked for it (position-independent).
                cid = msg.get("toolCallId")
                name = pending_skill_calls.pop(str(cid), None) if cid else None
                if name and last_rec is not None:
                    bucket = last_rec.setdefault("skill_bytes", {})
                    bucket[name] = bucket.get(name, 0) + len(text)
            elif role == "assistant":
                turn_index += 1
                usage = msg.get("usage") or {}
                model = msg.get("model") or model
                # message.timestamp = request start; entry.timestamp = completion.
                elapsed_ms = None
                if msg_ms is not None and entry_ts is not None:
                    entry_ms = int(entry_ts.replace(tzinfo=timezone.utc).timestamp() * 1000)
                    elapsed_ms = max(0, entry_ms - msg_ms)
                records.append(
                    {
                        "entry_id": str(msg_ms) if msg_ms is not None else f"t{turn_index}",
                        "ts": entry_ts or parse_ts(msg_ms),
                        "turn_index": turn_index,
                        "usage": usage,
                        "model": msg.get("model") or model,
                        "provider": msg.get("provider"),
                        "api": msg.get("api"),
                        "stop_reason": msg.get("stopReason"),
                        "response_id": msg.get("responseId"),
                        "elapsed_ms": elapsed_ms,
                        "sections": dict(sections),
                        "tools_section": tools_section,
                        "history_chars": history_chars,
                        "prompt_chars": pending_prompt_chars,
                        "prompt_total_chars": sum(sections.values()) + history_chars + pending_prompt_chars,
                        "memories": sorted(pending_memories),
                        "skills_loaded": sorted(pending_skills),
                        "skill_bytes": {},
                    }
                )
                last_rec = records[-1]
                # This turn's tool calls decide which skill files get pulled next.
                for part in msg.get("content") or []:
                    if not isinstance(part, dict) or part.get("type") != "toolCall":
                        continue
                    skill = skill_from_call(part.get("name"), part.get("arguments") or {})
                    if skill:
                        if part.get("id"):
                            pending_skill_calls[str(part.get("id"))] = skill
                        pending_skills.add(skill)
                pending_memories = set()
                pending_skills = set()
                history_chars += pending_prompt_chars
                pending_prompt_chars = 0
                text = content_to_text(msg.get("content"))
                history_chars += len(text)

    cpt = chars_per_token or _calibrate(records)
    return {"session_id": session_id, "cwd": cwd, "model": model, "records": records, "cpt": cpt}


def _calibrate(records: list[dict[str, Any]]) -> float:
    """chars/token from real usage: prompt_chars / (input + cacheRead)."""
    ratios: list[float] = []
    for rec in records:
        usage = rec["usage"]
        actual = int(usage.get("input") or 0) + int(usage.get("cacheRead") or 0)
        if actual > 200 and rec["prompt_total_chars"] > 0:
            ratios.append(rec["prompt_total_chars"] / actual)
    if not ratios:
        return DEFAULT_CHARS_PER_TOKEN
    median = statistics.median(ratios)
    return round(min(6.0, max(2.0, median)), 3)


# ----------------------------------------------------------------- build rows


def _rate(tokens: Any, ms: Any) -> float | None:
    try:
        n = int(tokens or 0)
        m = int(ms or 0)
    except (TypeError, ValueError):
        return None
    if n <= 0 or m < MIN_ELAPSED_MS:
        return None
    return round(n / (m / 1000.0), 4)


def build_rows(analysis: dict[str, Any], *, instance_id: str, source: str, host: str) -> tuple[list[dict], list[dict]]:
    session_id = analysis["session_id"]
    cpt = analysis["cpt"] or DEFAULT_CHARS_PER_TOKEN
    usage_rows: list[dict] = []
    ctx_rows: list[dict] = []

    for rec in analysis["records"]:
        mid = rec["entry_id"]
        row_id = f"{session_id}:{mid}"
        usage = rec["usage"] or {}
        cost = usage.get("cost") or {}
        output = usage.get("output")
        elapsed = rec.get("elapsed_ms")

        usage_rows.append(
            {
                "usage_id": row_id,
                "ts": rec["ts"],
                "session_id": session_id,
                "instance_id": instance_id,
                "source": source,
                "model": rec.get("model"),
                "provider": rec.get("provider"),
                "api": rec.get("api"),
                "message_id": mid,
                "turn_index": rec["turn_index"],
                "input_tokens": usage.get("input"),
                "output_tokens": output,
                "cache_read_tokens": usage.get("cacheRead"),
                "cache_write_tokens": usage.get("cacheWrite"),
                "reasoning_tokens": usage.get("reasoning"),
                "total_tokens": usage.get("totalTokens"),
                "cost_input": cost.get("input"),
                "cost_output": cost.get("output"),
                "cost_cache_read": cost.get("cacheRead"),
                "cost_cache_write": cost.get("cacheWrite"),
                "cost_total": cost.get("total"),
                "ttft_ms": None,
                "elapsed_ms": elapsed,
                "decode_ms": None,
                "tok_s_decode": None,
                "tok_s_e2e": _rate(output, elapsed),
                "stop_reason": rec.get("stop_reason"),
                "response_id": rec.get("response_id"),
                "host": host,
            }
        )

        sections = rec.get("sections") or {}
        ctx: dict[str, Any] = {
            "ctx_id": row_id,
            "ts": rec["ts"],
            "session_id": session_id,
            "instance_id": instance_id,
            "source": source,
            "model": rec.get("model"),
            "message_id": mid,
            "turn_index": rec["turn_index"],
            "est_chars_per_token": cpt,
            "sections_json": json.dumps(sections, ensure_ascii=False),
            "skill_names": ",".join(rec.get("skills_loaded") or []),
            "skill_loaded_tokens": json.dumps(
                {k: round(v / cpt) for k, v in (rec.get("skill_bytes") or {}).items() if v > 0},
                ensure_ascii=False,
            )
            if rec.get("skill_bytes")
            else None,
            "memory_ids": ",".join(rec.get("memories") or []),
            "tool_schema_names": ",".join(_skill_names(rec.get("tools_section", ""), "")),
            "host": host,
        }
        system_tokens = 0
        for name, chars in sections.items():
            toks = round(chars / cpt)
            system_tokens += toks
            col = SECTION_COLUMNS.get(name)
            if col:
                ctx[col] = toks
        ctx["system_tokens"] = system_tokens
        ctx["prompt_tokens"] = round((rec.get("prompt_chars") or 0) / cpt)
        ctx["history_tokens"] = round((rec.get("history_chars") or 0) / cpt)
        ctx["tool_result_tokens"] = None
        ctx["prompt_total_tokens"] = round((rec.get("prompt_total_chars") or 0) / cpt)
        ctx_rows.append(ctx)

    return usage_rows, ctx_rows


# --------------------------------------------------------------------- output


def write_quack(
    table: str,
    cols: tuple[str, ...],
    rows: list[dict],
    token_file: Path,
    probe: float,
    *,
    upsert: bool = False,
    key: str = "usage_id",
    preserve: tuple[str, ...] = (),
) -> int:
    from hook_client import load_token, open_quack_client, pick_uri, quack_exec, quack_uris

    uri = pick_uri(quack_uris(), probe)
    if uri is None:
        raise RuntimeError("no quack endpoint reachable")
    token = load_token(token_file)
    con = open_quack_client()
    written = 0
    try:
        for batch in chunked(rows, INSERT_BATCH):
            sql = upsert_sql(table, cols, batch, key, preserve) if upsert else insert_sql(table, cols, batch)
            quack_exec(sql, uri, token, con=con)
            written += len(batch)
    finally:
        con.close()
    return written


def main() -> int:
    parser = argparse.ArgumentParser(description="Backfill ClipVault metrics from pi session JSONL")
    parser.add_argument("--sessions-dir", default=str(DEFAULT_SESSIONS_DIR))
    parser.add_argument("--instance-id", default=os.environ.get("CLIPVAULT_INSTANCE_ID", "mac-work"))
    parser.add_argument("--source", default=os.environ.get("CLIPVAULT_HOOK_SOURCE", "pi"))
    parser.add_argument("--since", type=int, default=30, help="only files modified in the last N days (0 = all)")
    parser.add_argument("--session-id", action="append", default=[], help="restrict to these session ids")
    parser.add_argument("--chars-per-token", type=float, default=None, help="skip auto calibration")
    parser.add_argument("--token-file", default=os.environ.get("CLIPVAULT_QUACK_TOKEN_FILE", ""))
    parser.add_argument("--probe", type=float, default=float(os.environ.get("CLIPVAULT_QUACK_PROBE_SEC", "0.2")))
    parser.add_argument("--out", default="", help="write NDJSON rows here instead of INSERT")
    parser.add_argument("--dry-run", action="store_true", help="parse and report, write nothing")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    import socket

    sessions_dir = Path(args.sessions_dir).expanduser()
    if not sessions_dir.is_dir():
        raise SystemExit(f"sessions dir missing: {sessions_dir}")

    cutoff = None
    if args.since and args.since > 0:
        cutoff = datetime.now().timestamp() - args.since * 86400

    files = sorted(sessions_dir.rglob("*.jsonl"))
    if cutoff:
        files = [f for f in files if f.stat().st_mtime >= cutoff]
    if args.session_id:
        wanted = set(args.session_id)
        files = [f for f in files if any(w in f.name for w in wanted)]

    host = socket.gethostname()
    total_usage = total_ctx = total_files = 0
    cost_sum = 0.0
    token_file = Path(args.token_file).expanduser() if args.token_file else Path(
        os.environ.get("CLIPVAULT_HOME") or os.environ.get("KEEPSAKE_HOME") or Path.home() / "Documents/ClipFlow"
    ) / "config" / "trae-quack.token"

    out_fh = open(args.out, "w", encoding="utf-8") if args.out else None
    try:
        for path in files:
            analysis = analyze(load_entries(path), chars_per_token=args.chars_per_token)
            if not analysis["records"]:
                continue
            usage_rows, ctx_rows = build_rows(analysis, instance_id=args.instance_id, source=args.source, host=host)
            cost_sum += sum(r.get("cost_total") or 0 for r in usage_rows)
            total_files += 1
            total_usage += len(usage_rows)
            total_ctx += len(ctx_rows)
            if not args.quiet:
                sid = analysis["session_id"][:12]
                print(
                    f"  {sid}  turns={len(usage_rows):3}  cpt={analysis['cpt']:.2f}  "
                    f"cost=${sum(r.get('cost_total') or 0 for r in usage_rows):.4f}"
                )
            if args.dry_run:
                continue
            if out_fh is not None:
                for table, cols, rows in ((USAGE_TABLE, USAGE_COLS, usage_rows), (CTX_TABLE, CTX_COLS, ctx_rows)):
                    for row in rows:
                        out_fh.write(json.dumps({"table": table, "row": row}, ensure_ascii=False, default=str) + "\n")
                continue
            write_quack(
                USAGE_TABLE,
                USAGE_COLS,
                usage_rows,
                token_file,
                args.probe,
                upsert=True,
                key="usage_id",
                preserve=USAGE_LIVE_COLS,
            )
            write_quack(CTX_TABLE, CTX_COLS, ctx_rows, token_file, args.probe, upsert=True, key="ctx_id")
    finally:
        if out_fh is not None:
            out_fh.close()

    mode = "dry-run" if args.dry_run else ("ndjson" if args.out else "quack")
    print(
        f"\n{mode}: files={total_files} llm_usage={total_usage} turn_context={total_ctx} "
        f"cost_total=${cost_sum:.4f}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
