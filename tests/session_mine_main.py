#!/usr/bin/env python3
"""Session mining fixtures. Run: python3 tests/session_mine_main.py"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "trae_hooks"))

from mine import classify_phase, cmd_family, git_from_path, mcp_parts, mine_rows, parse_head  # noqa: E402


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

    rows = [
        {"event_id": "u1", "ts": "1", "hook_event": "UserPromptSubmit", "prompt": "加载AGENTS.md,注意review 时间", "cwd": "/root/flowkit"},
        {
            "event_id": "t1", "ts": "2", "hook_event": "PostToolUse",
            "tool_name": "mcp__nowledge-mem__memory_search",
            "cwd": "/root/flowkit",
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
    texts = " ".join(f["text"] for f in out["feedback"])
    ok("insight-runcommand", "RunCommand" in texts)
    ok("insight-nmem", "搜索" in texts and "写入" in texts)
    ok("insight-review", "review" in texts.lower())
    files = out["blocks"]["agent.files"]["table"]["rows"]
    ok("file-write", any("a.cc" in r["path"] for r in files), str(files))
    ok("feedback-title", all(f.get("title") and f.get("evidence") for f in out["feedback"]))
    ok("feedback-draft", any(f.get("draft") for f in out["feedback"]))
    phases = out["blocks"]["agent.phases"]
    ok("phase-turns-table", len(phases.get("tables") or []) >= 2)
    ok("summary-work", out["summary"]["work_s"] >= 20)
    print("session-mine: all passed")


if __name__ == "__main__":
    main()
