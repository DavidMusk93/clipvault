#!/usr/bin/env python3
"""Metrics-plane fixtures (llm_usage / turn_context). Run: python3 tests/session_metrics_main.py

Covers the pieces that are easy to get quietly wrong:
  * join key is <session_id>:<message.timestamp>, shared by hot + cold paths
  * elapsed = entry.timestamp (completion) - message.timestamp (request start)
  * skill context cost comes from the read result, never from a write/edit ack
  * upsert preserves the hot-path-only ttft fields
"""
from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "trae_hooks"))

import metrics  # noqa: E402
import pi_session_ingest as ingest  # noqa: E402
from mine import metrics_analysis  # noqa: E402


def ok(name: str, cond: bool, detail: str = "") -> None:
    if cond:
        print(f"OK {name}")
        return
    print(f"FAIL {name} {detail}", file=sys.stderr)
    raise SystemExit(1)


SCHEMA = (ROOT / "trae_hooks" / "schema.sql").read_text(encoding="utf-8")

MSG_TS = 1789906825648
ENTRY_TS = "2026-09-20T12:20:28.263Z"  # MSG_TS + 2615 ms
SKILL_TEXT = "SKILL BODY " * 300  # ~3300 chars, definitely a real context payload


def build_entries() -> list[dict]:
    sections = {
        "preamble": "p" * 100,
        "tools": "- read: read a file\n- bash: run a command\n",
        "rules": "r" * 400,
        "project_context": "c" * 800,
        "skills": "<skills><skill><name>bytedcli</name></skill><skill><name>other</name></skill></skills>",
    }
    return [
        {"type": "session", "id": "sess-1", "cwd": "/tmp", "timestamp": "2026-09-20T12:20:16.458Z"},
        {
            "type": "message",
            "id": "m0",
            "timestamp": "2026-09-20T12:20:25.647Z",
            "message": {"role": "system", "content": "", "sections": sections, "timestamp": MSG_TS - 1},
        },
        {
            "type": "message",
            "id": "m1",
            "timestamp": "2026-09-20T12:20:25.648Z",
            "message": {"role": "user", "content": "do the thing", "timestamp": MSG_TS - 3},
        },
        {
            "type": "message",
            "id": "m2",
            "timestamp": ENTRY_TS,
            "message": {
                "role": "assistant",
                "timestamp": MSG_TS,
                "api": "openai-completions",
                "provider": "opencode-go",
                "model": "deepseek-v4.1-flash",
                "usage": {
                    "input": 100,
                    "output": 50,
                    "cacheRead": 1000,
                    "cacheWrite": 0,
                    "reasoning": 5,
                    "totalTokens": 1150,
                    "cost": {"input": 0.001, "output": 0.002, "cacheRead": 0.0001, "cacheWrite": 0, "total": 0.0031},
                },
                "stopReason": "toolUse",
                "responseId": "resp-1",
                "content": [{"type": "toolCall", "id": "call-1", "name": "read", "arguments": {"path": "/x/.pi/agent/skills/bytedcli/SKILL.md"}}],
            },
        },
        {
            "type": "message",
            "id": "m3",
            "timestamp": "2026-09-20T12:20:29.000Z",
            "message": {"role": "toolResult", "toolCallId": "call-1", "toolName": "read", "content": [{"type": "text", "text": SKILL_TEXT}], "isError": False, "timestamp": MSG_TS + 2600},
        },
    ]


def main() -> None:
    # --- schema -----------------------------------------------------------------
    ok("schema-llm-usage", "CREATE TABLE IF NOT EXISTS llm_usage" in SCHEMA)
    ok("schema-turn-context", "CREATE TABLE IF NOT EXISTS turn_context" in SCHEMA)
    ok("schema-skill-col", "skill_loaded_tokens VARCHAR" in SCHEMA)
    ok("schema-alter-migration", "ADD COLUMN IF NOT EXISTS skill_loaded_tokens" in SCHEMA)
    for col in ("ttft_ms", "tok_s_decode", "cache_read_tokens", "cost_total"):
        ok(f"schema-usage-{col}", col in SCHEMA)

    # --- hot-path row builders --------------------------------------------------
    report = {
        "session_id": "sess-1",
        "message_id": str(MSG_TS),
        "ts": ENTRY_TS,
        "turn_index": 0,
        "model": "deepseek-v4.1-flash",
        "provider": "opencode-go",
        "api": "openai-completions",
        "usage": {"input": 100, "output": 50, "cacheRead": 1000, "cacheWrite": 0, "reasoning": 5, "totalTokens": 1150,
                  "cost": {"input": 0.001, "output": 0.002, "cacheRead": 0.0001, "cacheWrite": 0, "total": 0.0031}},
        "stop_reason": "stop",
        "elapsed_ms": 2615,
        "ttft_ms": 300,
    }
    urow = metrics.usage_row_from_report(report)
    ok("hot-usage-id", urow["usage_id"] == f"sess-1:{MSG_TS}", urow["usage_id"])
    ok("hot-decode-ms", urow["decode_ms"] == 2315, str(urow["decode_ms"]))
    ok("hot-tok-s-decode", abs(urow["tok_s_decode"] - 21.5983) < 0.01, str(urow["tok_s_decode"]))
    ok("hot-tok-s-e2e", abs(urow["tok_s_e2e"] - 19.1205) < 0.01, str(urow["tok_s_e2e"]))

    crows = metrics.rows_from_report(
        {"session_id": "sess-1", "message_id": str(MSG_TS), "ts": ENTRY_TS,
         "sections": {"preamble": "p" * 360, "rules": "r" * 360, "skills": "s" * 720}, "est_chars_per_token": 3.6},
        "ContextReport",
    )[2][0]
    ok("hot-ctx-preamble", crows["preamble_tokens"] == 100, str(crows["preamble_tokens"]))
    ok("hot-ctx-skills", crows["skills_tokens"] == 200, str(crows["skills_tokens"]))
    ok("hot-ctx-system", crows["system_tokens"] == 400, str(crows["system_tokens"]))

    # --- insert / upsert SQL ----------------------------------------------------
    ins = metrics.insert_sql("llm_usage", metrics.USAGE_COLS, [urow])
    ok("insert-on-conflict", ins.endswith("ON CONFLICT DO NOTHING"))
    up = metrics.upsert_sql("llm_usage", metrics.USAGE_COLS, [urow], "usage_id", ("ttft_ms", "decode_ms", "tok_s_decode"))
    ok("upsert-target", "ON CONFLICT (usage_id) DO UPDATE" in up)
    ok("upsert-preserve", "ttft_ms = COALESCE(excluded.ttft_ms, llm_usage.ttft_ms)" in up)
    ok("upsert-overwrite", "output_tokens = excluded.output_tokens" in up)

    # --- skill_from_call precision ---------------------------------------------
    sfc = ingest.skill_from_call
    ok("skill-read", sfc("read", {"path": "/x/.pi/agent/skills/bytedcli/SKILL.md"}) == "bytedcli")
    ok("skill-bash-cat", sfc("bash", {"command": "cat /x/skills/bytedcli/SKILL.md"}) == "bytedcli")
    ok("skill-write-no", sfc("write", {"path": "/x/skills/bytedcli/SKILL.md"}) is None)
    ok("skill-edit-no", sfc("edit", {"path": "/x/skills/bytedcli/SKILL.md"}) is None)
    ok("skill-nmem-add-no", sfc("nmem_memory_add", {"content": "see /x/skills/bytedcli/SKILL.md"}) is None)
    ok("skill-echo-no", sfc("bash", {"command": "echo /x/skills/bytedcli/SKILL.md"}) is None)

    # --- cold-path analyze ------------------------------------------------------
    analysis = ingest.analyze(build_entries())
    ok("cold-session", analysis["session_id"] == "sess-1")
    ok("cold-one-record", len(analysis["records"]) == 1, str(len(analysis["records"])))
    rec = analysis["records"][0]
    ok("cold-elapsed", rec["elapsed_ms"] == 2615, str(rec["elapsed_ms"]))
    ok("cold-turn-index", rec["turn_index"] == 0)
    ok("cold-skill-bytes", rec["skill_bytes"].get("bytedcli") == len(SKILL_TEXT), str(rec["skill_bytes"]))
    ok("cold-model", rec["model"] == "deepseek-v4.1-flash")

    usage_rows, ctx_rows = ingest.build_rows(analysis, instance_id="mac-work", source="pi", host="h")
    ok("cold-usage-id", usage_rows[0]["usage_id"] == f"sess-1:{MSG_TS}", usage_rows[0]["usage_id"])
    ok("cold-usage-ts", usage_rows[0]["ts"].isoformat() == "2026-09-20T12:20:28.263000", str(usage_rows[0]["ts"]))
    ok("cold-ttft-null", usage_rows[0]["ttft_ms"] is None)
    ok("cold-tok-s", usage_rows[0]["tok_s_e2e"] is not None)
    ok("cold-ctx-id", ctx_rows[0]["ctx_id"] == f"sess-1:{MSG_TS}")
    ok("cold-ctx-rules", (ctx_rows[0].get("rules_tokens") or 0) > 0)
    ok("cold-ctx-skill-col", "bytedcli" in (ctx_rows[0]["skill_loaded_tokens"] or ""), str(ctx_rows[0]["skill_loaded_tokens"]))
    system_tokens = ctx_rows[0]["system_tokens"]
    ok("cold-ctx-system-positive", system_tokens > 0 and system_tokens <= sum(
        ctx_rows[0].get(c) or 0 for c in (
            "preamble_tokens", "tools_tokens", "rules_tokens", "docs_tokens", "project_tokens", "skills_tokens")) + system_tokens,
       str(system_tokens))

    # analyze() must be the pure path: same input -> same ids, no writes
    again = ingest.analyze(build_entries())
    ok("cold-idempotent-ids", again["records"][0]["entry_id"] == rec["entry_id"])

    # --- mine metrics_analysis --------------------------------------------------
    block, feedback = metrics_analysis(usage_rows, ctx_rows)
    ok("mine-block", block is not None and block["title"].startswith("成本"))
    caps = [t["caption"] for t in block["tables"]]
    for want in ("总览", "按模型", "上下文构成（估算）", "每天成本曲线"):
        ok(f"mine-table-{want}", want in caps, str(caps))
    overview = {r["metric"]: r["value"] for r in block["tables"][0]["rows"]}
    ok("mine-cost", overview["费用 USD"] == "0.0031", overview.get("费用 USD", ""))
    ok("mine-hit", overview["缓存命中率"] == "90.9%", overview.get("缓存命中率", ""))
    ok("mine-tok-s", overview["端到端 tok/s"] == "19.1", overview.get("端到端 tok/s", ""))
    ok("mine-skill-feedback", any("bytedcli" in f["title"] for f in feedback), str([f["title"] for f in feedback]))

    ok("mine-empty-safe", metrics_analysis([], []) == (None, []))

    # --- end-to-end: fixture file -> analyze (no DB) ----------------------------
    with tempfile.TemporaryDirectory() as td:
        path = Path(td) / "2026-09-20T12-20-16-458Z_sess-1.jsonl"
        path.write_text("\n".join(json.dumps(e) for e in build_entries()), encoding="utf-8")
        entries = ingest.load_entries(path)
        ok("load-roundtrip", len(entries) == len(build_entries()))

    print("session-metrics: all passed")


if __name__ == "__main__":
    main()
