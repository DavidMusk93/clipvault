"""Metrics plane for ClipVault: llm_usage + turn_context row builders.

Content lives in hook_events. Money / speed / context composition live here.
Two producers, one schema:

  hot path  (pi/clipvault-session.ts -> UsageReport/ContextReport)
      hooks into live events for ttft + realtime dashboards.
  cold path (pi_session_ingest.py -> session JSONL)
      lossless, backfills history, computes context sections.

Both are idempotent: deterministic primary key + ON CONFLICT DO NOTHING.
Trae cannot feed this plane at all -- its hook stdin has no usage/model/cost.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any

USAGE_TABLE = "llm_usage"
CTX_TABLE = "turn_context"

USAGE_COLS = (
    "usage_id",
    "ts",
    "session_id",
    "instance_id",
    "source",
    "model",
    "provider",
    "api",
    "message_id",
    "turn_index",
    "input_tokens",
    "output_tokens",
    "cache_read_tokens",
    "cache_write_tokens",
    "reasoning_tokens",
    "total_tokens",
    "cost_input",
    "cost_output",
    "cost_cache_read",
    "cost_cache_write",
    "cost_total",
    "ttft_ms",
    "elapsed_ms",
    "decode_ms",
    "tok_s_decode",
    "tok_s_e2e",
    "stop_reason",
    "response_id",
    "host",
)

CTX_COLS = (
    "ctx_id",
    "ts",
    "session_id",
    "instance_id",
    "source",
    "model",
    "message_id",
    "turn_index",
    "system_tokens",
    "preamble_tokens",
    "tools_tokens",
    "rules_tokens",
    "docs_tokens",
    "project_tokens",
    "skills_tokens",
    "prompt_tokens",
    "history_tokens",
    "tool_result_tokens",
    "prompt_total_tokens",
    "est_chars_per_token",
    "sections_json",
    "skill_names",
    "skill_loaded_tokens",
    "memory_ids",
    "tool_schema_names",
    "host",
)

# Section name -> (ctx column, extra names). Unknown sections fold into system only.
SECTION_COLUMNS = {
    "preamble": "preamble_tokens",
    "tools": "tools_tokens",
    "rules": "rules_tokens",
    "docs": "docs_tokens",
    "project_context": "project_tokens",
    "skills": "skills_tokens",
}

METRIC_EVENTS = ("UsageReport", "ContextReport")

DEFAULT_CHARS_PER_TOKEN = 3.6
# Below this a "generation" is a retry/abort stub, not a real decode window.
MIN_ELAPSED_MS = 120


def sql_lit(value: Any) -> str:
    if value is None:
        return "NULL"
    if isinstance(value, bool):
        return "TRUE" if value else "FALSE"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return "NULL" if value != value else repr(value)  # NaN -> NULL
    text = value.isoformat(sep=" ") if hasattr(value, "isoformat") else str(value)
    return "'" + text.replace("'", "''") + "'"


def values_tuple(row: dict[str, Any], cols: tuple[str, ...]) -> str:
    return "(" + ", ".join(sql_lit(row.get(c)) for c in cols) + ")"


def insert_sql(table: str, cols: tuple[str, ...], rows: list[dict[str, Any]]) -> str:
    if not rows:
        return ""
    body = ",".join(values_tuple(r, cols) for r in rows)
    return (
        f"INSERT INTO {table} ({', '.join(cols)}) VALUES {body} "
        "ON CONFLICT DO NOTHING"
    )


def upsert_sql(
    table: str,
    cols: tuple[str, ...],
    rows: list[dict[str, Any]],
    key: str,
    preserve: tuple[str, ...] = (),
) -> str:
    """INSERT ... ON CONFLICT (key) DO UPDATE.

    `preserve` columns keep the existing value when the new one is NULL. The cold
    path uses this so a later, better-calibrated re-ingest overwrites hot-path rows
    without wiping the one field only the hot path can supply (ttft_ms).
    """
    if not rows:
        return ""
    body = ",".join(values_tuple(r, cols) for r in rows)
    sets = []
    for col in cols:
        if col == key:
            continue
        if col in preserve:
            sets.append(f"{col} = COALESCE(excluded.{col}, {table}.{col})")
        else:
            sets.append(f"{col} = excluded.{col}")
    return (
        f"INSERT INTO {table} ({', '.join(cols)}) VALUES {body} "
        f"ON CONFLICT ({key}) DO UPDATE SET {', '.join(sets)}"
    )


def chunked(items: list[Any], size: int) -> list[list[Any]]:
    return [items[i : i + size] for i in range(0, len(items), size)]


def _ms(value: Any) -> int | None:
    if value is None:
        return None
    try:
        return int(round(float(value)))
    except (TypeError, ValueError):
        return None


def _tok(value: Any) -> int | None:
    if value is None or value == "":
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _rate(num: Any, ms: Any) -> float | None:
    n = _tok(num)
    m = _ms(ms)
    if n is None or m is None or n <= 0 or m < MIN_ELAPSED_MS:
        return None
    return round(n / (m / 1000.0), 4)


def usage_row_from_report(payload: dict[str, Any]) -> dict[str, Any]:
    """Hot path: build a llm_usage row from a UsageReport hook payload."""
    usage = payload.get("usage") or {}
    cost = usage.get("cost") or {}
    session_id = str(payload.get("session_id") or "")
    message_id = str(payload.get("message_id") or payload.get("tool_use_id") or "")
    elapsed = _ms(payload.get("elapsed_ms"))
    ttft = _ms(payload.get("ttft_ms"))
    decode = None
    if elapsed is not None:
        decode = max(0, elapsed - (ttft or 0))
    output = _tok(usage.get("output"))
    return {
        "usage_id": f"{session_id}:{message_id}",
        "ts": payload.get("ts") or datetime.utcnow(),
        "session_id": session_id,
        "instance_id": payload.get("instance_id"),
        "source": payload.get("source") or "pi",
        "model": payload.get("model"),
        "provider": payload.get("provider"),
        "api": payload.get("api"),
        "message_id": message_id,
        "turn_index": payload.get("turn_index"),
        "input_tokens": _tok(usage.get("input")),
        "output_tokens": output,
        "cache_read_tokens": _tok(usage.get("cacheRead")),
        "cache_write_tokens": _tok(usage.get("cacheWrite")),
        "reasoning_tokens": _tok(usage.get("reasoning")),
        "total_tokens": _tok(usage.get("totalTokens")),
        "cost_input": cost.get("input"),
        "cost_output": cost.get("output"),
        "cost_cache_read": cost.get("cacheRead"),
        "cost_cache_write": cost.get("cacheWrite"),
        "cost_total": cost.get("total"),
        "ttft_ms": ttft,
        "elapsed_ms": elapsed,
        "decode_ms": decode,
        "tok_s_decode": _rate(output, decode),
        "tok_s_e2e": _rate(output, elapsed),
        "stop_reason": payload.get("stop_reason"),
        "response_id": payload.get("response_id"),
        "host": payload.get("host"),
    }


def ctx_row_from_report(payload: dict[str, Any]) -> dict[str, Any]:
    """Hot path: build a turn_context row from a ContextReport hook payload."""
    import json as _json

    session_id = str(payload.get("session_id") or "")
    message_id = str(payload.get("message_id") or payload.get("tool_use_id") or "")
    sections = payload.get("sections") or {}
    cpt = payload.get("est_chars_per_token") or DEFAULT_CHARS_PER_TOKEN
    row: dict[str, Any] = {
        "ctx_id": f"{session_id}:{message_id}",
        "ts": payload.get("ts") or datetime.utcnow(),
        "session_id": session_id,
        "instance_id": payload.get("instance_id"),
        "source": payload.get("source") or "pi",
        "model": payload.get("model"),
        "message_id": message_id,
        "turn_index": payload.get("turn_index"),
        "est_chars_per_token": cpt,
        "sections_json": _json.dumps(sections, ensure_ascii=False),
        "skill_names": payload.get("skill_names"),
        "skill_loaded_tokens": payload.get("skill_loaded_tokens"),
        "memory_ids": payload.get("memory_ids"),
        "tool_schema_names": payload.get("tool_schema_names"),
        "host": payload.get("host"),
    }
    total_system = 0
    for name, value in sections.items():
        chars = value if isinstance(value, int) else len(str(value or ""))
        toks = round(chars / cpt)
        total_system += toks
        col = SECTION_COLUMNS.get(name)
        if col:
            row[col] = toks
    row["system_tokens"] = total_system
    row["prompt_tokens"] = _tok(payload.get("prompt_tokens"))
    row["history_tokens"] = _tok(payload.get("history_tokens"))
    row["tool_result_tokens"] = _tok(payload.get("tool_result_tokens"))
    parts = [row.get("system_tokens") or 0, row.get("prompt_tokens") or 0, row.get("history_tokens") or 0]
    row["prompt_total_tokens"] = sum(p for p in parts if p) or None
    return row


def rows_from_report(payload: dict[str, Any], event: str) -> tuple[str, tuple[str, ...], list[dict[str, Any]]]:
    if event == "UsageReport":
        return USAGE_TABLE, USAGE_COLS, [usage_row_from_report(payload)]
    if event == "ContextReport":
        return CTX_TABLE, CTX_COLS, [ctx_row_from_report(payload)]
    raise ValueError(f"not a metric event: {event}")
