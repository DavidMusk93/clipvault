"""Session mining: sessions are an asset only if they produce feedback.

Does not return tool bodies. Heads of tool_input/response are enough to
rank cwd, git, files, tools, MCP, and turn phases.
"""

from __future__ import annotations

import json
import re
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

DIRECTIONS: list[dict[str, str]] = [
    {"id": "user.cwd", "axis": "user", "title": "工作目录"},
    {"id": "user.git", "axis": "user", "title": "Git 库"},
    {"id": "user.taste", "axis": "user", "title": "Taste / 规范"},
    {"id": "agent.files", "axis": "agent", "title": "读写文件"},
    {"id": "agent.tools", "axis": "agent", "title": "工具调用"},
    {"id": "agent.mcp", "axis": "agent", "title": "MCP"},
    {"id": "agent.phases", "axis": "agent", "title": "任务阶段"},
]

DIR_IDS = tuple(d["id"] for d in DIRECTIONS)

FETCH_SQL = """
SELECT
    event_id,
    CAST(ts AS VARCHAR) AS ts,
    session_id,
    instance_id,
    cwd,
    hook_event,
    tool_name,
    llm_tool_name,
    prompt,
    last_assistant_message,
    substr(coalesce(tool_input, ''), 1, 1500) AS input_head,
    substr(coalesce(tool_response, ''), 1, 400) AS resp_head
FROM hook_events
WHERE hook_event IN ('PostToolUse', 'UserPromptSubmit', 'Stop')
"""

_RE_FILE_PATH = re.compile(r'"file_path"\s*:\s*"((?:\\.|[^"\\])*)"')
_RE_WORKDIR = re.compile(r'"(?:workdir|cwd)"\s*:\s*"((?:\\.|[^"\\])*)"')
_RE_CMD = re.compile(r'"(?:cmd|command)"\s*:\s*"((?:\\.|[^"\\]){1,500})"')
_RE_WALL = re.compile(r'"wall_time_seconds"\s*:\s*([0-9]+(?:\.[0-9]+)?)')
_RE_EXIT = re.compile(r'"exit_code"\s*:\s*(-?[0-9]+)')
_RE_REPO_AT = re.compile(r"/repos/([^/@]+)(?:@|--)([^/]+)")
_RE_TASTE_FILE = re.compile(
    r"(AGENTS\.md|design-taste\.md|SKILL\.md|nmem-knowledge-format\.md)",
    re.I,
)
_RE_PATH_TOKEN = re.compile(
    r"(?:^|[\s\"'=])(/[^\s:\"']+\.[A-Za-z0-9]{1,8}|[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+\.[A-Za-z0-9]{1,8})"
)

_PHASES = (
    ("review", re.compile(r"review|评审|code review|\bmr\b|pull request", re.I)),
    ("taste", re.compile(r"AGENTS\.md|design-taste|taste|风格|规范|nmem", re.I)),
    ("debug", re.compile(r"为什么|怎么会|不对|失败|bug|报错", re.I)),
    ("ship", re.compile(r"提交|push|合并|发 mr|开 mr", re.I)),
    ("implement", re.compile(r"改|修|实现|加上|补|落地", re.I)),
)


def unescape(s: str) -> str:
    return s.replace("\\/", "/").replace("\\\"", '"').replace("\\\\", "\\")


def parse_head(text: str | None) -> dict[str, Any]:
    raw = str(text or "")
    out: dict[str, Any] = {}
    if not raw:
        return out
    try:
        obj = json.loads(raw)
        if isinstance(obj, dict):
            if obj.get("file_path"):
                out["file_path"] = str(obj["file_path"])
            if obj.get("cmd") or obj.get("command"):
                out["cmd"] = str(obj.get("cmd") or obj.get("command"))
            if obj.get("workdir") or obj.get("cwd"):
                out["workdir"] = str(obj.get("workdir") or obj.get("cwd"))
            if obj.get("path") and not out.get("file_path"):
                out["file_path"] = str(obj["path"])
            if obj.get("wall_time_seconds") is not None:
                out["wall_s"] = float(obj["wall_time_seconds"])
            if obj.get("exit_code") is not None:
                out["exit_code"] = int(obj["exit_code"])
            return out
    except (json.JSONDecodeError, TypeError, ValueError):
        pass
    m = _RE_FILE_PATH.search(raw)
    if m:
        out["file_path"] = unescape(m.group(1))
    m = _RE_WORKDIR.search(raw)
    if m:
        out["workdir"] = unescape(m.group(1))
    m = _RE_CMD.search(raw)
    if m:
        out["cmd"] = unescape(m.group(1))
    m = _RE_WALL.search(raw)
    if m:
        out["wall_s"] = float(m.group(1))
    m = _RE_EXIT.search(raw)
    if m:
        out["exit_code"] = int(m.group(1))
    return out


def git_from_path(path: str | None) -> tuple[str, str] | None:
    p = str(path or "").replace("\\", "/")
    if not p:
        return None
    m = _RE_REPO_AT.search(p)
    if m:
        return m.group(1), m.group(2)
    name = Path(p.rstrip("/")).name
    if not name or name in (".", "/"):
        return None
    if name.startswith("."):
        return None
    return name, ""


def mcp_parts(name: str | None) -> tuple[str, str] | None:
    raw = str(name or "")
    if raw.startswith("mcp__"):
        bits = raw.split("__")
        if len(bits) >= 3:
            return bits[1], "__".join(bits[2:])
    if raw.startswith("mcp_"):
        bits = raw.split("_")
        if len(bits) >= 3:
            return bits[1], "_".join(bits[2:])
    return None


def classify_phase(prompt: str | None) -> str:
    text = str(prompt or "")
    for name, rx in _PHASES:
        if rx.search(text):
            return name
    return "other"


def paths_from_cmd(cmd: str | None) -> list[str]:
    out: list[str] = []
    for m in _RE_PATH_TOKEN.finditer(str(cmd or "")):
        p = m.group(1)
        if p.count("/") < 1:
            continue
        if len(p) > 220:
            continue
        out.append(p.split(":")[0])
    return out[:8]


def _rank(counter: Counter[str], n: int = 8) -> list[dict[str, Any]]:
    return [{"key": k, "n": v} for k, v in counter.most_common(n) if k]


def _table(rows: list[dict[str, Any]], cols: list[tuple[str, str]]) -> dict[str, Any]:
    return {"cols": [{"id": i, "title": t} for i, t in cols], "rows": rows}


def mine_rows(
    rows: list[dict[str, Any]],
    *,
    dirs: list[str] | None = None,
    session_id: str | None = None,
    scope: str = "session",
) -> dict[str, Any]:
    want = [d for d in (dirs or list(DIR_IDS)) if d in DIR_IDS]
    if not want:
        want = list(DIR_IDS)

    cwd_n: Counter[str] = Counter()
    git_n: Counter[str] = Counter()
    git_branch: dict[str, Counter[str]] = defaultdict(Counter)
    file_n: Counter[str] = Counter()
    tool_n: Counter[str] = Counter()
    tool_s: dict[str, float] = defaultdict(float)
    tool_fail: Counter[str] = Counter()
    mcp_n: Counter[str] = Counter()
    mcp_tool: Counter[str] = Counter()
    taste_n: Counter[str] = Counter()
    phase_n: Counter[str] = Counter()
    phase_s: dict[str, float] = defaultdict(float)

    beats: list[dict[str, Any]] = []
    for raw in rows:
        hook = str(raw.get("hook_event") or "")
        ts = str(raw.get("ts") or "")
        if hook in ("UserPromptSubmit", "Stop"):
            beats.append(raw)
        cwd = str(raw.get("cwd") or "").rstrip("/")
        if cwd:
            cwd_n[cwd] += 1
            g = git_from_path(cwd)
            if g:
                git_n[g[0]] += 1
                if g[1]:
                    git_branch[g[0]][g[1]] += 1
        if hook != "PostToolUse":
            prompt = str(raw.get("prompt") or "")
            for hit in _RE_TASTE_FILE.findall(prompt):
                taste_n[hit] += 1
            if re.search(r"\btaste\b|风格|规范", prompt, re.I):
                taste_n["taste-mention"] += 1
            continue
        name = str(raw.get("tool_name") or raw.get("llm_tool_name") or "tool")
        tool_n[name] += 1
        parsed = parse_head(raw.get("input_head"))
        parsed.update({k: v for k, v in parse_head(raw.get("resp_head")).items() if k not in parsed or k in ("wall_s", "exit_code")})
        wall = float(parsed.get("wall_s") or 0)
        tool_s[name] += wall
        if parsed.get("exit_code") not in (None, 0):
            tool_fail[name] += 1
        wd = str(parsed.get("workdir") or cwd or "").rstrip("/")
        if wd:
            cwd_n[wd] += 1
            g = git_from_path(wd)
            if g:
                git_n[g[0]] += 1
                if g[1]:
                    git_branch[g[0]][g[1]] += 1
        fp = str(parsed.get("file_path") or "")
        if fp:
            file_n[fp] += 1
            if _RE_TASTE_FILE.search(fp):
                taste_n[Path(fp).name] += 2
        for p in paths_from_cmd(parsed.get("cmd")):
            file_n[p] += 1
            if _RE_TASTE_FILE.search(p):
                taste_n[Path(p).name] += 1
        mcp = mcp_parts(name) or mcp_parts(raw.get("llm_tool_name"))
        if mcp:
            mcp_n[mcp[0]] += 1
            mcp_tool[f"{mcp[0]}/{mcp[1]}"] += 1
        cmd = str(parsed.get("cmd") or "")
        if re.search(r"\bgit\b", cmd):
            g = git_from_path(wd)
            if g:
                git_n[g[0]] += 2

    # Turns: UserPromptSubmit → next Stop, tools between.
    turns: list[dict[str, Any]] = []
    pending: dict[str, Any] | None = None
    for raw in sorted(rows, key=lambda r: (str(r.get("ts") or ""), str(r.get("event_id") or ""))):
        hook = str(raw.get("hook_event") or "")
        if hook == "UserPromptSubmit":
            pending = {
                "ts": raw.get("ts"),
                "prompt": raw.get("prompt") or "",
                "phase": classify_phase(raw.get("prompt")),
                "wall_s": 0.0,
                "tools": 0,
            }
            continue
        if pending and hook == "PostToolUse":
            pending["tools"] += 1
            pending["wall_s"] += float(parse_head(raw.get("resp_head")).get("wall_s") or 0)
        if pending and hook == "Stop":
            turns.append(pending)
            pending = None
    if pending:
        turns.append(pending)
    for t in turns:
        phase_n[t["phase"]] += 1
        phase_s[t["phase"]] += float(t["wall_s"] or 0)

    blocks: dict[str, Any] = {}
    if "user.cwd" in want:
        blocks["user.cwd"] = {
            "title": "工作目录",
            "axis": "user",
            "table": _table(
                [{"path": r["key"], "n": r["n"]} for r in _rank(cwd_n)],
                [("path", "目录"), ("n", "次")],
            ),
        }
    if "user.git" in want:
        rows_g = []
        for r in _rank(git_n):
            br = git_branch[r["key"]].most_common(1)
            rows_g.append({"repo": r["key"], "branch": br[0][0] if br else "", "n": r["n"]})
        blocks["user.git"] = {
            "title": "Git 库",
            "axis": "user",
            "table": _table(rows_g, [("repo", "库"), ("branch", "分支"), ("n", "次")]),
        }
    if "user.taste" in want:
        blocks["user.taste"] = {
            "title": "Taste / 规范",
            "axis": "user",
            "table": _table(
                [{"doc": r["key"], "n": r["n"]} for r in _rank(taste_n)],
                [("doc", "线索"), ("n", "次")],
            ),
        }
    if "agent.files" in want:
        blocks["agent.files"] = {
            "title": "读写文件",
            "axis": "agent",
            "table": _table(
                [{"path": r["key"], "n": r["n"]} for r in _rank(file_n, 12)],
                [("path", "文件"), ("n", "次")],
            ),
        }
    if "agent.tools" in want:
        rows_t = []
        for r in _rank(tool_n, 12):
            rows_t.append({
                "tool": r["key"],
                "n": r["n"],
                "sec": round(tool_s.get(r["key"], 0), 1),
                "fail": tool_fail.get(r["key"], 0),
            })
        blocks["agent.tools"] = {
            "title": "工具调用",
            "axis": "agent",
            "table": _table(rows_t, [("tool", "工具"), ("n", "次"), ("sec", "秒"), ("fail", "失败")]),
        }
    if "agent.mcp" in want:
        rows_m = [{"mcp": r["key"], "n": r["n"]} for r in _rank(mcp_tool, 12)]
        if not rows_m:
            rows_m = [{"mcp": r["key"], "n": r["n"]} for r in _rank(mcp_n)]
        blocks["agent.mcp"] = {
            "title": "MCP",
            "axis": "agent",
            "table": _table(rows_m, [("mcp", "调用"), ("n", "次")]),
        }
    if "agent.phases" in want:
        total_s = sum(phase_s.values()) or 1.0
        rows_p = []
        for name, n in phase_n.most_common():
            sec = phase_s.get(name, 0)
            rows_p.append({
                "phase": name,
                "n": n,
                "sec": round(sec, 1),
                "share": round(100 * sec / total_s, 1),
            })
        blocks["agent.phases"] = {
            "title": "任务阶段",
            "axis": "agent",
            "table": _table(rows_p, [("phase", "阶段"), ("n", "回合"), ("sec", "秒"), ("share", "%")]),
        }

    feedback = _insights(
        cwd_n=cwd_n,
        git_n=git_n,
        tool_n=tool_n,
        tool_s=tool_s,
        mcp_n=mcp_n,
        mcp_tool=mcp_tool,
        taste_n=taste_n,
        phase_n=phase_n,
        phase_s=phase_s,
        file_n=file_n,
        turns=turns,
    )
    return {
        "ok": True,
        "scope": scope,
        "session_id": session_id or "",
        "n_rows": len(rows),
        "n_turns": len(turns),
        "directions": DIRECTIONS,
        "active": want,
        "blocks": blocks,
        "feedback": feedback,
    }


def _insights(**kw: Any) -> list[dict[str, str]]:
    out: list[dict[str, str]] = []
    tool_n: Counter[str] = kw["tool_n"]
    tool_s: dict[str, float] = kw["tool_s"]
    mcp_tool: Counter[str] = kw["mcp_tool"]
    mcp_n: Counter[str] = kw["mcp_n"]
    phase_n: Counter[str] = kw["phase_n"]
    phase_s: dict[str, float] = kw["phase_s"]
    git_n: Counter[str] = kw["git_n"]
    taste_n: Counter[str] = kw["taste_n"]
    file_n: Counter[str] = kw["file_n"]
    cwd_n: Counter[str] = kw["cwd_n"]
    turns: list[dict[str, Any]] = kw["turns"]

    total_tools = sum(tool_n.values()) or 1
    total_s = sum(phase_s.values()) or sum(tool_s.values()) or 1.0
    run_n = tool_n.get("RunCommand", 0)
    if run_n / total_tools >= 0.45:
        out.append({
            "audience": "agent",
            "use": "agents.md",
            "text": (
                f"工具里 RunCommand 占 {round(100 * run_n / total_tools)}%。"
                "文件轨迹主要靠 shell/rg，Read 几乎缺席。"
                "AGENTS 应写清：改代码先 Read 目标文件，禁止用全库 rg 代替阅读。"
            ),
        })
    search_n = sum(v for k, v in mcp_tool.items() if "search" in k or "memory_search" in k)
    add_n = sum(v for k, v in mcp_tool.items() if k.endswith("memory_add") or k.endswith("/memory_add"))
    if search_n >= 3 and add_n == 0:
        out.append({
            "audience": "agent",
            "use": "agents.md",
            "text": (
                f"nmem/MCP 搜索 {search_n} 次、写入 {add_n} 次。"
                "知识只读不沉淀。非琐碎结论必须 memory_add。"
            ),
        })
    elif mcp_n:
        top = mcp_n.most_common(1)[0]
        out.append({
            "audience": "agent",
            "use": "prompt",
            "text": f"MCP 集中在 {top[0]}（{top[1]} 次）。确认这是本任务该用的记忆面，而不是顺手乱搜。",
        })
    review_s = phase_s.get("review", 0)
    if any(t["phase"] == "review" or "review" in str(t.get("prompt") or "").lower() for t in turns):
        share = 100 * review_s / total_s
        if share < 20:
            out.append({
                "audience": "agent",
                "use": "agents.md",
                "text": (
                    f"用户提到 review，但 review 阶段只占工具耗时 {round(share, 1)}%。"
                    "把 review 闸门写成硬约束：改完必须对照 diff/测试，不能只用实现回合收尾。"
                ),
            })
    if git_n:
        repo, n = git_n.most_common(1)[0]
        out.append({
            "audience": "user",
            "use": "prompt",
            "text": f"最常落在 git 库 {repo}（{n} 次）。新开任务时在 prompt 里写明仓库根，避免 agent 在邻近目录里乱找。",
        })
    if cwd_n:
        cwd, n = cwd_n.most_common(1)[0]
        out.append({
            "audience": "user",
            "use": "prompt",
            "text": f"主工作目录 {cwd}（{n} 次）。",
        })
    if taste_n:
        doc, n = taste_n.most_common(1)[0]
        out.append({
            "audience": "agent",
            "use": "agents.md",
            "text": f"本会话反复碰到 {doc}（{n}）。规范被提到却未成为闸门时，把对应约束写进 AGENTS.md，不要只靠口头 taste。",
        })
    if file_n:
        path, n = file_n.most_common(1)[0]
        out.append({
            "audience": "agent",
            "use": "prompt",
            "text": f"读写最热文件 {path}（{n}）。若这是核心模块，prompt 应直接点名，减少搜索回合。",
        })
    if not out:
        out.append({
            "audience": "user",
            "use": "prompt",
            "text": "事件太少，还不够形成稳定习惯。多几个完整回合后再分析。",
        })
    return out[:8]


def fetch_rows(query_fn, *, session_id: str | None, scope: str) -> list[dict[str, Any]]:
    sql = FETCH_SQL
    params: list[Any] = []
    if scope == "session" and session_id:
        sql += " AND session_id = ?"
        params.append(session_id)
    elif scope == "recent":
        sql += " AND ts >= (current_timestamp - INTERVAL 7 DAY)"
    else:
        sql += " AND session_id = ?"
        params.append(session_id or "")
    sql += " ORDER BY ts ASC LIMIT 12000"
    return query_fn(sql, params)


def mine(
    query_fn,
    *,
    session_id: str | None = None,
    scope: str = "session",
    dirs: list[str] | None = None,
) -> dict[str, Any]:
    if scope not in ("session", "recent"):
        scope = "session"
    rows = fetch_rows(query_fn, session_id=session_id, scope=scope)
    return mine_rows(rows, dirs=dirs, session_id=session_id, scope=scope)
