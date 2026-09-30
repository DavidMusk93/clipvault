#!/usr/bin/env python3
"""Session mining fixtures. Run: python3 tests/session_mine_main.py"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "trae_hooks"))

from mine import (  # noqa: E402
    ack_finding, agent_view, attach_acks, classify_phase, cmd_family, fetch_acks, git_from_path,
    mcp_parts, mine_rows, parse_head, taste_keys,
)


def ok(name: str, cond: bool, detail: str = "") -> None:
    if cond:
        print(f"OK {name}")
        return
    print(f"FAIL {name} {detail}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    p = parse_head(
        '{"cmd":"rg foo src/a.cc","workdir":"/root/Documents/flowkit/.tmp/repos/stream_engine@fix-x","wall_time_seconds":1.5}'
    )
    ok("parse-cmd", p.get("cmd", "").startswith("rg foo"))
    ok("parse-workdir", "stream_engine@" in str(p.get("workdir")))

    truncated = '{"file_path":"/root/AGENTS.md","content":"' + ("x" * 2000)
    t = parse_head(truncated)
    ok("parse-truncated-write", t.get("file_path") == "/root/AGENTS.md")

    r = parse_head('{"chunk_id":"x","wall_time_seconds":30.0,"exit_code":1,"output":"boom"}')
    ok("parse-wall", r.get("wall_s") == 30.0)
    ok("parse-exit", r.get("exit_code") == 1)

    g = git_from_path("/root/Documents/flowkit/.tmp/repos/stream_engine@fix-csv")
    ok("git-repo", g == ("stream_engine", "fix-csv"))
    g2 = git_from_path("/root/Documents/flowkit/.tmp/repos/stream_engine--fix-taskmanager-crash-lifecycle")
    ok("git-repo-dash", g2 == ("stream_engine", "fix-taskmanager-crash-lifecycle"))
    ok("mcp", mcp_parts("mcp__nowledge-mem__memory_search") == ("nowledge-mem", "memory_search"))
    ok("phase-review", classify_phase("注意 review 时间，提交 mr") == "review")
    ok("cmd-rg", cmd_family("rg -n foo src/a.cc") == "search")
    ok("cmd-git", cmd_family("git status --short") == "git")
    ok("git-not-cwd-guess", git_from_path("/root/Documents/flowkit") is None)
    ok(
        "taste-skill",
        taste_keys("/root/Documents/flowkit/.trae/skills/ce-code-review/SKILL.md") == ["skill:ce-code-review"],
        str(taste_keys("/root/Documents/flowkit/.trae/skills/ce-code-review/SKILL.md")),
    )
    ok("taste-grok-skill", "skill:leetcode" in taste_keys("/Users/x/.grok/skills/leetcode/SKILL.md"))
    ok("taste-agents-project", "flowkit/AGENTS.md" in taste_keys("/root/Documents/flowkit/AGENTS.md"))
    ok("taste-agents-cwd", "flowkit/AGENTS.md" in taste_keys("加载AGENTS.md", "/root/flowkit"))
    ok("taste-not-bare", "SKILL.md" not in taste_keys("/root/flowkit/.trae/skills/ce-code-review/references/a.md"))
    ok(
        "taste-agents-worktree",
        "stream_engine/AGENTS.md" in taste_keys("/root/x/.tmp/repos/stream_engine--fix-x/AGENTS.md"),
        str(taste_keys("/root/x/.tmp/repos/stream_engine--fix-x/AGENTS.md")),
    )
    ok(
        "taste-not-prompt-blob",
        not any("提交mr" in k for k in taste_keys("好的，按照你的建议修改。提交mr。加载AGENTS.md", "/root/flowkit")),
        str(taste_keys("好的，按照你的建议修改。提交mr。加载AGENTS.md", "/root/flowkit")),
    )

    rows = [
        {"event_id": "u1", "ts": "1", "hook_event": "UserPromptSubmit", "prompt": "加载AGENTS.md,注意review 时间", "cwd": "/root/flowkit"},
        {
            "event_id": "t1", "ts": "2", "hook_event": "PostToolUse",
            "tool_name": "mcp__nowledge-mem__memory_search",
            "cwd": "/root/flowkit/.trae/skills/ce-code-review",
            "input_head": '{"args":{"query":"x"}}',
            "resp_head": '{"wall_time_seconds":0.2,"exit_code":0}',
        },
        {
            "event_id": "t1b", "ts": "2.1", "hook_event": "PostToolUse",
            "tool_name": "mcp__nowledge-mem__memory_search",
            "input_head": '{"args":{"query":"y"}}',
            "resp_head": '{"wall_time_seconds":0.2,"exit_code":0}',
        },
        {
            "event_id": "t1c", "ts": "2.2", "hook_event": "PostToolUse",
            "tool_name": "mcp__nowledge-mem__memory_search",
            "input_head": '{"args":{"query":"z"}}',
            "resp_head": '{"wall_time_seconds":0.2,"exit_code":0}',
        },
        {"event_id": "s0", "ts": "2.3", "hook_event": "Stop", "last_assistant_message": "ok"},
        {"event_id": "u2", "ts": "3", "hook_event": "UserPromptSubmit", "prompt": "按建议修改并落地", "cwd": "/root/flowkit"},
        {
            "event_id": "t2", "ts": "4", "hook_event": "PostToolUse",
            "tool_name": "RunCommand",
            "cwd": "/root/Documents/flowkit/.tmp/repos/stream_engine@fix-x",
            "input_head": '{"cmd":"rg foo src/a.cc","workdir":"/root/Documents/flowkit/.tmp/repos/stream_engine@fix-x"}',
            "resp_head": '{"wall_time_seconds":12.0,"exit_code":0}',
        },
        {
            "event_id": "t3", "ts": "5", "hook_event": "PostToolUse",
            "tool_name": "RunCommand",
            "cwd": "/root/Documents/flowkit/.tmp/repos/stream_engine@fix-x",
            "input_head": '{"cmd":"rg bar src/b.cc","workdir":"/root/Documents/flowkit/.tmp/repos/stream_engine@fix-x"}',
            "resp_head": '{"wall_time_seconds":8.0,"exit_code":0}',
        },
        {
            "event_id": "t4", "ts": "6", "hook_event": "PostToolUse",
            "tool_name": "RunCommand",
            "input_head": '{"cmd":"rg baz src/c.cc","workdir":"/root/Documents/flowkit/.tmp/repos/stream_engine@fix-x"}',
            "resp_head": '{"wall_time_seconds":7.0,"exit_code":0}',
        },
        {
            "event_id": "t5", "ts": "6.5", "hook_event": "PostToolUse",
            "tool_name": "RunCommand",
            "input_head": '{"cmd":"ls src","workdir":"/root/Documents/flowkit/.tmp/repos/stream_engine@fix-x"}',
            "resp_head": '{"wall_time_seconds":1.0,"exit_code":0}',
        },
        {
            "event_id": "w1", "ts": "7", "hook_event": "PostToolUse",
            "tool_name": "Write",
            "input_head": '{"file_path":"/root/Documents/flowkit/src/sink/a.cc","content":"int x;"}',
            "resp_head": '{"wall_time_seconds":0.1,"exit_code":0}',
        },
        {"event_id": "s1", "ts": "8", "hook_event": "Stop", "last_assistant_message": "done"},
    ]
    out = mine_rows(rows, session_id="s", scope="session")
    ok("turns", out["n_turns"] == 2)
    tools = {r["tool"]: r for r in out["blocks"]["agent.tools"]["table"]["rows"]}
    ok("runcommand-ranked", "RunCommand" in tools)
    git_rows = out["blocks"]["user.git"]["table"]["rows"]
    ok("git-stream", any(r["repo"] == "stream_engine" for r in git_rows), str(git_rows))
    # v2 contract: findings come from the attributable loss account, not keywords.
    ok("findings-shape", all(
        f.get("id") and f.get("sev") in ("high", "med", "note", "good")
        and isinstance(f.get("impact"), dict) and "s" in f["impact"] and f.get("evidence")
        for f in out["feedback"]
    ), str(out["feedback"])[:400])
    ok("losses-shape", all(
        l.get("id") and l.get("kind") in ("measured", "estimated") and "s" in l and "how" in l
        for l in out["losses"]
    ))
    metric_ids = {m["id"] for m in out["metrics"]}
    ok("metrics-registry", {"fail_n", "reread_ratio", "locate_s", "loss_s"} <= metric_ids, str(sorted(metric_ids)))
    ok("metrics-shape", all(m.get("dir") in ("up", "down", "flat") and "unit" in m for m in out["metrics"]))
    ok("turn-ledger", bool(out["turns"]) and all("index" in t and "phase" in t and "tools" in t for t in out["turns"]))
    ok("window-facts", out["window"]["turns"] == out["n_turns"] and out["window"]["tools"] == out["summary"]["n_tools"])
    ok("no-keyword-findings", not any("提醒" in f["title"] and "反复" in f["title"] for f in out["feedback"]), str(out["feedback"])[:300])
    taste_docs = [r["doc"] for r in out["blocks"]["user.taste"]["table"]["rows"]]
    ok("taste-named-skill", any(d.startswith("skill:ce-code-review") for d in taste_docs), str(taste_docs))
    ok("taste-named-agents", any(d.endswith("/AGENTS.md") or "AGENTS.md" in d for d in taste_docs), str(taste_docs))
    ok("taste-not-bare-filename", "SKILL.md" not in taste_docs, str(taste_docs))
    files = out["blocks"]["agent.files"]["table"]["rows"]
    ok("file-write", any("a.cc" in r["path"] for r in files), str(files))
    ok("feedback-title", all(f.get("title") and f.get("evidence") for f in out["feedback"]))
    ok("feedback-draft", all(f.get("draft") for f in out["feedback"] if f.get("sev") in ("high", "med")))
    phases = out["blocks"]["agent.phases"]
    ok("phase-turns-table", len(phases.get("tables") or []) >= 2)
    ok("summary-work", out["summary"]["work_s"] >= 20)
    ok("summary-health", "health" in out["summary"] and "score" in out["summary"]["health"])
    ok("hot-block", len(out["blocks"]["agent.hot"]["tables"]) == 3, str(list(out["blocks"])))
    ok("feedback-sev", all(f.get("sev") in ("high", "med", "note", "good") for f in out["feedback"]))
    ok("prompt-axis", "user.prompt" in out["blocks"])

    # Failure + retry + read/write split: a file read by shell is not a write.
    fail_rows = [
        {"event_id": "fu", "ts": "10", "hook_event": "UserPromptSubmit", "prompt": "继续 ", "cwd": "/root/p"},
        {
            "event_id": "ft1", "ts": "11", "hook_event": "PostToolUse", "tool_name": "RunCommand",
            "input_head": '{"cmd":"git push origin master","workdir":"/root/p"}',
            "resp_head": '{"wall_time_seconds":30.0,"exit_code":128,"output":"boom"}',
        },
        {
            "event_id": "ft2", "ts": "12", "hook_event": "PostToolUse", "tool_name": "RunCommand",
            "input_head": '{"cmd":"git push origin master","workdir":"/root/p"}',
            "resp_head": '{"wall_time_seconds":20.0,"exit_code":1,"output":"again"}',
        },
        {
            "event_id": "fr", "ts": "13", "hook_event": "PostToolUse", "tool_name": "RunCommand",
            "input_head": '{"cmd":"sed -n 1,200p /root/p/a/b.cc","workdir":"/root/p"}',
            "resp_head": '{"wall_time_seconds":0.2,"exit_code":0,"output":"x"}',
        },
        {
            "event_id": "fw", "ts": "14", "hook_event": "PostToolUse", "tool_name": "Write",
            "input_head": '{"file_path":"/root/p/a/b.cc","content":"int x;"}',
            "resp_head": '{"wall_time_seconds":0.1,"exit_code":0}',
        },
        {"event_id": "fs", "ts": "15", "hook_event": "Stop", "last_assistant_message": "ok"},
    ]
    out2 = mine_rows(fail_rows, session_id="f", scope="session")
    ok("fail-counted", out2["summary"]["fail_n"] == 2, str(out2["summary"]))
    ok("fail-insight", any("失败" in f["title"] for f in out2["feedback"]), str(out2["feedback"]))
    fail_fb = [f for f in out2["feedback"] if "失败" in f["title"]]
    ok("fail-sev", fail_fb and fail_fb[0]["sev"] in ("high", "med"), str(fail_fb))
    hot_files = {r["path"]: r for r in out2["blocks"]["agent.hot"]["table"]["rows"]}
    ok("read-not-write", hot_files.get("/root/p/a/b.cc", {}).get("writes") == 1, str(hot_files))

    # User input: repeated reminders + flow friction.
    flow_rows = [
        {"event_id": "p1", "ts": "20", "hook_event": "UserPromptSubmit", "prompt": "继续。"},
        {"event_id": "p2", "ts": "21", "hook_event": "UserPromptSubmit", "prompt": "注意 review，不要跳过测试。"},
        {"event_id": "p3", "ts": "22", "hook_event": "UserPromptSubmit", "prompt": "这里存在认知错误，应该先复述需求。"},
        {"event_id": "p3b", "ts": "22.5", "hook_event": "UserPromptSubmit", "prompt": "又搞错了，方向不对。"},
        {"event_id": "p4", "ts": "23", "hook_event": "UserPromptSubmit", "prompt": "为什么用了这么多时间？还没结果。"},
        {"event_id": "p5", "ts": "24", "hook_event": "UserPromptSubmit", "prompt": "把这个结论整理写入nmem。"},
        {"event_id": "p6", "ts": "25", "hook_event": "UserPromptSubmit", "prompt": "从nmem 中加载上下文再改。"},
        {"event_id": "p7", "ts": "26", "hook_event": "UserPromptSubmit", "prompt": "重新测试一下。"},
        {"event_id": "p8", "ts": "27", "hook_event": "UserPromptSubmit", "prompt": "还是不对，重新看。"},
        {"event_id": "p9", "ts": "28", "hook_event": "UserPromptSubmit", "prompt": "继续"},
    ]
    out3 = mine_rows(flow_rows, session_id="flow", scope="session")
    rem_themes = {r["theme"]: r["n"] for r in out3["blocks"]["user.reminders"]["table"]["rows"]}
    ok("reminder-themes", "纠正" in rem_themes and "重申约束" in rem_themes and "催促" in rem_themes, str(rem_themes))
    ok("reminder-sink", rem_themes.get("沉淀提醒", 0) >= 1, str(rem_themes))
    ok("reminder-load", rem_themes.get("加载上下文", 0) >= 1, str(rem_themes))
    ok("flow-nudge", out3["summary"]["flow"]["nudge_n"] >= 2, str(out3["summary"]["flow"]))
    ok("flow-trips", out3["summary"]["flow"]["extra_roundtrips"] >= 4, str(out3["summary"]["flow"]))
    ok("turns-ledger", len(out3["turns"]) >= 8, str(len(out3["turns"])))
    trips = {m["id"]: m for m in out3["metrics"]}
    ok("flow-metric", trips.get("extra_trips", {}).get("value") == out3["summary"]["flow"]["extra_roundtrips"])
    ok("flow-metric-target", trips.get("extra_trips", {}).get("target") == 0)

    # Agent contract: a brief to read, stable metric ids to re-measure, and no
    # actionable finding without an action + metric.
    ag_rows = fail_rows + [
        {"event_id": "fu2", "ts": "16", "hook_event": "UserPromptSubmit", "prompt": "继续", "cwd": "/root/p"},
        {"event_id": "ft3", "ts": "17", "hook_event": "PostToolUse", "tool_name": "RunCommand",
         "input_head": '{"cmd":"cargo test","workdir":"/root/p"}',
         "resp_head": '{"wall_time_seconds":30.0,"exit_code":1}'},
        {"event_id": "fs2", "ts": "18", "hook_event": "Stop"},
    ]
    usage = [
        {"ts": "11", "session_id": "f", "model": "m", "input_tokens": 1000, "output_tokens": 100,
         "cache_read_tokens": 2000, "cache_write_tokens": 500, "total_tokens": 3600, "cost_total": 0.05},
        {"ts": "17", "session_id": "f", "model": "m", "input_tokens": 1200, "output_tokens": 120,
         "cache_read_tokens": 100, "cache_write_tokens": 0, "total_tokens": 1420, "cost_total": 0.06},
    ]
    out4 = mine_rows(ag_rows, session_id="f", scope="session", usage_rows=usage)
    view = agent_view(out4, None)
    ok("agent-view", view["view"] == "agent" and view["ok"] is True)
    ok("agent-brief", view["brief"].startswith("# 会话分析") and "## 指标" in view["brief"] and "## 复测" in view["brief"])
    ok("agent-verify", bool(view["verify"]["metric_ids"]) and bool(view["verify"]["expect"]))
    ok("agent-high-has-action", all(f.get("metric") and f.get("action") for f in view["findings"] if f.get("sev") == "high"), str(view["findings"])[:400])
    ok("agent-usd-loss", any(l["usd"] > 0 for l in out4["losses"]), str(out4["losses"]))
    ok("agent-cache-metric", any(m["id"] == "cache_hit_pct" for m in out4["metrics"]), str([m["id"] for m in out4["metrics"]]))
    ok("fail-refs", any(r.get("exit_code") for l in out4["losses"] for r in l.get("refs", [])), str(out4["losses"])[:400])

    # Charts: the shape that fits is declared where the data is built.
    charted = [(t.get("caption"), t["chart"]["kind"]) for b in out["blocks"].values()
               for t in (b.get("tables") or []) if t.get("chart")]
    ok("chart-annotated", len(charted) >= 4, str(charted))
    ok("chart-kinds", {k for _, k in charted} <= {"bars", "donut", "line", "columns", "stack"}, str(charted))
    phase_tbl = out["blocks"]["agent.phases"]["tables"][0]
    ok("chart-phase-donut", phase_tbl["chart"]["kind"] == "donut" and phase_tbl["chart"]["value"] == "work", str(phase_tbl["chart"]))
    turn_tbl = out["blocks"]["agent.phases"]["tables"][1]
    ok("chart-turn-columns", turn_tbl["chart"]["kind"] == "columns" and "index" in turn_tbl["rows"][0], str(turn_tbl["chart"]))
    ok("chart-tool-bars", out["blocks"]["agent.tools"]["tables"][0]["chart"]["kind"] == "bars")
    ok("series-cache", "cache" in out4["series"] and "uncached" in out4["series"]["cache"], str(out4["series"]))

    # L3 loop: an ack records the claim; the next read says whether it moved.
    def _find(result, fid):
        return next(f for f in result["findings"] if f["id"] == fid)

    attach_acks(out4, {"fail_retry": {"status": "applied", "ts": "t1", "note": "先读 stderr",
                                      "metric_id": "fail_n", "at_now": 9, "target": 0}})
    acked = _find(out4, "fail_retry")
    ok("ack-attached", acked["ack"]["status"] == "applied" and acked["ack"]["closed"] is False, str(acked.get("ack")))
    ok("loop-state", out4["loop"]["applied"] == ["fail_retry"] and out4["loop"]["open"] == ["fail_retry"], str(out4["loop"]))
    v4 = agent_view(out4, None)
    ok("agent-loop-brief", "## 闭环核对" in v4["brief"] and "未改善" in v4["brief"], v4["brief"][-400:])
    ok("agent-loop-view", v4["loop"]["open"] == ["fail_retry"] and any("ack" in f for f in v4["findings"]))

    closed_probe = {"findings": [{"id": "fail_retry", "sev": "high",
                                  "metric": {"id": "fail_n", "now": 0, "target": 0, "dir": "down"}}]}
    attach_acks(closed_probe, {"fail_retry": {"status": "applied", "at_now": 9}})
    ok("loop-closed", closed_probe["findings"][0]["ack"]["closed"] is True
       and closed_probe["loop"]["closed"] == ["fail_retry"], str(closed_probe["loop"]))
    no_target = {"findings": [{"id": "idle", "metric": {"id": "idle_s", "now": 5, "target": None, "dir": "down"}}]}
    attach_acks(no_target, {"idle": {"status": "applied", "at_now": 0}})
    ok("loop-no-target", no_target["findings"][0]["ack"]["closed"] is None
       and no_target["loop"]["untracked"] == ["idle"], str(no_target["loop"]))
    dismissed = {"findings": [{"id": "idle", "metric": {"id": "idle_s", "now": 0, "target": None, "dir": "down"}}]}
    attach_acks(dismissed, {"idle": {"status": "dismissed", "at_now": 0}})
    ok("loop-dismissed", dismissed["loop"]["dismissed"] == ["idle"] and "closed" not in dismissed["loop"]["applied"], str(dismissed["loop"]))

    writes: list[tuple[str, list[Any]]] = []

    def _exec(sql: str, params: list[Any] | None = None) -> None:
        writes.append((sql, list(params or [])))

    res = ack_finding(_exec, scope="session", session_id="f", finding_id="fail_retry", status="applied",
                      note="n", metric={"id": "fail_n", "now": 9, "target": 0})
    ok("ack-write", bool(res.get("ok")) and res["ack_id"] == "session:f:fail_retry", str(res))
    ok("ack-upsert", "ON CONFLICT (ack_id) DO UPDATE" in writes[0][0])
    ok("ack-params", writes[0][1][5] == "fail_retry" and writes[0][1][6] == "applied" and writes[0][1][9] == 9, str(writes[0][1]))
    ok("ack-requires-finding", ack_finding(_exec, scope="session", session_id="f", finding_id="", status="applied")["ok"] is False)

    def _boom(sql: str, params: list[Any] | None = None) -> list[dict[str, Any]]:
        raise RuntimeError("no analysis_acks table")

    ok("acks-degrade", fetch_acks(_boom, session_id="f", scope="session") == {})
    print("session-mine: all passed")


if __name__ == "__main__":
    main()
