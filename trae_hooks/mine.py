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
_RE_PROJECT_DOC = re.compile(
    r"(?:^|/)([\w.-]+)/(AGENTS\.md|design-taste\.md|nmem-knowledge-format\.md)\b",
    re.I,
)
_TASTE_SKIP_PARENT = {".tmp", "tmp", "refs", "references", "node_modules"}
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


def cmd_family(cmd: str | None) -> str:
    c = str(cmd or "")
    if re.search(r"\bgit\b", c):
        return "git"
    if re.search(r"\b(rg|grep|ag|ack)\b", c):
        return "search"
    if re.search(r"\b(cat|head|tail|less|bat|sed -n)\b", c):
        return "read"
    if re.search(r"\b(pytest|ctest|cargo test|go test|googletest)\b", c):
        return "test"
    if re.search(r"\b(ninja|make\b|blade|bazel|cmake|cargo build)\b", c):
        return "build"
    if re.search(r"\b(ssh|scp|rsync)\b", c):
        return "remote"
    return "shell"


def is_wait_tool(name: str | None) -> bool:
    n = str(name or "")
    return n in ("CheckCommandStatus", "StopCommand", "WriteStdin")


def git_from_path(path: str | None) -> tuple[str, str] | None:
    p = str(path or "").replace("\\", "/")
    if not p:
        return None
    m = _RE_REPO_AT.search(p)
    if m:
        return m.group(1), m.group(2)
    if p.endswith(".git"):
        return Path(p).stem, ""
    return None


def first_line(text: str | None, n: int = 160) -> str:
    line = str(text or "").strip().split("\n", 1)[0]
    return line[:n]


def _project_name(parent: str) -> str:
    p = str(parent or "").strip()
    m = re.match(r"^([^/@\s]+)(?:@|--).+$", p)
    return m.group(1) if m else p


def taste_keys(*parts: str | None) -> list[str]:
    """Identity for a spec file: skill name or project/AGENTS.md, never a bare filename."""
    bits: list[str] = []
    for p in parts:
        s = str(p or "").replace("\\", "/").strip()
        if not s:
            continue
        if "/" in s and not s.endswith("/"):
            s += "/"
        bits.append(s)
    blob = "\n".join(bits)
    keys: list[str] = []
    seen: set[str] = set()

    def add(key: str) -> None:
        key = str(key or "").strip()
        if key and key not in seen:
            seen.add(key)
            keys.append(key)

    for m in re.finditer(r"/skills/([\w.-]+)/", blob, re.I):
        add(f"skill:{m.group(1)}")
    for m in _RE_PROJECT_DOC.finditer(blob):
        parent = _project_name(m.group(1))
        if not parent or parent in _TASTE_SKIP_PARENT:
            continue
        if re.search(r"\.[a-zA-Z0-9]{1,8}$", parent):
            continue
        add(f"{parent}/{m.group(2)}")
    if not keys:
        m = _RE_TASTE_FILE.search(blob)
        parent = ""
        for p in reversed(parts):
            raw = str(p or "").replace("\\", "/").rstrip("/")
            if "/" not in raw:
                continue
            name = Path(raw).name
            if name and not name.endswith(".md") and re.match(r"^[\w.-]+$", name):
                parent = _project_name(name)
                if parent in _TASTE_SKIP_PARENT or re.search(r"\.[a-zA-Z0-9]{1,8}$", parent):
                    parent = ""
                    continue
                break
        if m and parent:
            add(f"{parent}/{m.group(1)}")
    return keys


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


def _rank(counter: Counter[str], n: int = 20) -> list[dict[str, Any]]:
    return [{"key": k, "n": v} for k, v in counter.most_common(n) if k]


def _table(rows: list[dict[str, Any]], cols: list[tuple[str, str]], caption: str = "") -> dict[str, Any]:
    return {
        "caption": caption,
        "cols": [{"id": i, "title": t} for i, t in cols],
        "rows": rows,
    }


def _block(title: str, axis: str, note: str, tables: list[dict[str, Any]]) -> dict[str, Any]:
    return {"title": title, "axis": axis, "note": note, "table": tables[0] if tables else _table([], []), "tables": tables}


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
    file_write: Counter[str] = Counter()
    dir_n: Counter[str] = Counter()
    ext_n: Counter[str] = Counter()
    tool_n: Counter[str] = Counter()
    tool_s: dict[str, float] = defaultdict(float)
    tool_fail: Counter[str] = Counter()
    family_n: Counter[str] = Counter()
    family_s: dict[str, float] = defaultdict(float)
    mcp_n: Counter[str] = Counter()
    mcp_tool: Counter[str] = Counter()
    taste_n: Counter[str] = Counter()
    inst_n: Counter[str] = Counter()
    phase_n: Counter[str] = Counter()
    phase_s: dict[str, float] = defaultdict(float)
    phase_work: dict[str, float] = defaultdict(float)
    wait_s = 0.0
    work_s = 0.0

    ordered = sorted(rows, key=lambda r: (str(r.get("ts") or ""), str(r.get("event_id") or "")))
    for raw in ordered:
        hook = str(raw.get("hook_event") or "")
        inst = str(raw.get("instance_id") or "")
        if inst:
            inst_n[inst] += 1
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
            for key in taste_keys(prompt, cwd):
                taste_n[key] += 1
            if re.search(r"\btaste\b|风格|规范", prompt, re.I) and not taste_keys(prompt, cwd):
                taste_n["taste-mention"] += 1
            continue
        name = str(raw.get("tool_name") or raw.get("llm_tool_name") or "tool")
        tool_n[name] += 1
        parsed = parse_head(raw.get("input_head"))
        parsed.update({
            k: v for k, v in parse_head(raw.get("resp_head")).items()
            if k not in parsed or k in ("wall_s", "exit_code")
        })
        wall = float(parsed.get("wall_s") or 0)
        tool_s[name] += wall
        if is_wait_tool(name):
            wait_s += wall
        else:
            work_s += wall
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
            file_write[fp] += 1
            dir_n[str(Path(fp).parent)] += 1
            if Path(fp).suffix:
                ext_n[Path(fp).suffix] += 1
        cmd = str(parsed.get("cmd") or "")
        fam = cmd_family(cmd) if cmd else ""
        if fam:
            family_n[fam] += 1
            family_s[fam] += wall
        cmd_paths = paths_from_cmd(cmd)
        for p in cmd_paths:
            file_n[p] += 1
            dir_n[str(Path(p).parent)] += 1
            if Path(p).suffix:
                ext_n[Path(p).suffix] += 1
        for key in taste_keys(fp, wd, cwd, cmd, *cmd_paths):
            taste_n[key] += 1
        mcp = mcp_parts(name) or mcp_parts(raw.get("llm_tool_name"))
        if mcp:
            mcp_n[mcp[0]] += 1
            mcp_tool[f"{mcp[0]}/{mcp[1]}"] += 1
        if re.search(r"\bgit\b", cmd):
            g = git_from_path(wd)
            if g:
                git_n[g[0]] += 2

    turns: list[dict[str, Any]] = []
    pending: dict[str, Any] | None = None
    for raw in ordered:
        hook = str(raw.get("hook_event") or "")
        if hook == "UserPromptSubmit":
            pending = {
                "ts": str(raw.get("ts") or ""),
                "prompt": first_line(raw.get("prompt"), 200),
                "phase": classify_phase(raw.get("prompt")),
                "wall_s": 0.0,
                "work_s": 0.0,
                "wait_s": 0.0,
                "tools": 0,
            }
            continue
        if pending and hook == "PostToolUse":
            name = str(raw.get("tool_name") or "")
            wall = float(parse_head(raw.get("resp_head")).get("wall_s") or 0)
            pending["tools"] += 1
            pending["wall_s"] += wall
            if is_wait_tool(name):
                pending["wait_s"] += wall
            else:
                pending["work_s"] += wall
        if pending and hook == "Stop":
            turns.append(pending)
            pending = None
    if pending:
        turns.append(pending)
    for t in turns:
        phase_n[t["phase"]] += 1
        phase_s[t["phase"]] += float(t["wall_s"] or 0)
        phase_work[t["phase"]] += float(t["work_s"] or 0)

    total_s = wait_s + work_s or 1.0
    blocks: dict[str, Any] = {}
    if "user.cwd" in want:
        blocks["user.cwd"] = _block(
            "工作目录",
            "user",
            "cwd / workdir 出现次数。主目录应写进 prompt，避免 agent 在邻近树里乱走。",
            [_table([{"path": r["key"], "n": r["n"]} for r in _rank(cwd_n)], [("path", "目录"), ("n", "次")])],
        )
    if "user.git" in want:
        rows_g = []
        for r in _rank(git_n):
            br = git_branch[r["key"]].most_common(3)
            rows_g.append({
                "repo": r["key"],
                "branch": ", ".join(b for b, _ in br),
                "n": r["n"],
            })
        blocks["user.git"] = _block(
            "Git 库",
            "user",
            "只认 `.tmp/repos/<name>@branch` 或 `--branch` 工作树，不用目录名猜库。",
            [_table(rows_g, [("repo", "库"), ("branch", "分支"), ("n", "次")])],
        )
    if "user.taste" in want:
        blocks["user.taste"] = _block(
            "Taste / 规范",
            "user",
            "线索必须带项目或技能名（`clipvault/AGENTS.md`、`skill:ce-code-review`），禁止只记 SKILL.md 文件名。",
            [_table([{"doc": r["key"], "n": r["n"]} for r in _rank(taste_n)], [("doc", "线索"), ("n", "次")])],
        )
    if "agent.files" in want:
        blocks["agent.files"] = _block(
            "读写文件",
            "agent",
            "Write 的 file_path + shell 命令里的路径。热文件应直接写进下一轮 prompt。",
            [
                _table(
                    [{"path": r["key"], "n": r["n"], "writes": file_write.get(r["key"], 0)} for r in _rank(file_n)],
                    [("path", "文件"), ("n", "次"), ("writes", "写入")],
                    "文件",
                ),
                _table(
                    [{"path": r["key"], "n": r["n"]} for r in _rank(dir_n, 12)],
                    [("path", "目录"), ("n", "次")],
                    "目录簇",
                ),
                _table(
                    [{"ext": r["key"], "n": r["n"]} for r in _rank(ext_n, 10)],
                    [("ext", "后缀"), ("n", "次")],
                    "语言/后缀",
                ),
            ],
        )
    if "agent.tools" in want:
        rows_t = []
        for r in _rank(tool_n):
            sec = tool_s.get(r["key"], 0)
            rows_t.append({
                "tool": r["key"],
                "n": r["n"],
                "sec": round(sec, 1),
                "share": round(100 * sec / total_s, 1),
                "fail": tool_fail.get(r["key"], 0),
                "kind": "等待" if is_wait_tool(r["key"]) else "工作",
            })
        rows_f = [{
            "family": r["key"],
            "n": r["n"],
            "sec": round(family_s.get(r["key"], 0), 1),
        } for r in _rank(family_n)]
        blocks["agent.tools"] = _block(
            "工具调用",
            "agent",
            f"墙钟合计 {round(total_s, 1)}s，其中工作 {round(work_s, 1)}s、等待（CheckCommandStatus 等）{round(wait_s, 1)}s。等待不是任务阶段。",
            [
                _table(rows_t, [("tool", "工具"), ("kind", "类"), ("n", "次"), ("sec", "秒"), ("share", "%"), ("fail", "失败")], "工具"),
                _table(rows_f, [("family", "shell 族"), ("n", "次"), ("sec", "秒")], "RunCommand 族（git / rg / read / build / test）"),
            ],
        )
    if "agent.mcp" in want:
        rows_m = []
        for r in _rank(mcp_tool):
            kind = "search" if "search" in r["key"] else ("write" if r["key"].endswith("add") or "memory_add" in r["key"] else "other")
            rows_m.append({"mcp": r["key"], "kind": kind, "n": r["n"]})
        blocks["agent.mcp"] = _block(
            "MCP",
            "agent",
            "search 远多于 add = 知识只读不沉淀。",
            [_table(rows_m, [("mcp", "调用"), ("kind", "类"), ("n", "次")])],
        )
    if "agent.phases" in want:
        work_total = sum(phase_work.values()) or 1.0
        rows_p = []
        for name, n in phase_n.most_common():
            rows_p.append({
                "phase": name,
                "n": n,
                "sec": round(phase_s.get(name, 0), 1),
                "work": round(phase_work.get(name, 0), 1),
                "share": round(100 * phase_work.get(name, 0) / work_total, 1),
            })
        rows_turn = [{
            "ts": t["ts"],
            "phase": t["phase"],
            "tools": t["tools"],
            "work": round(t["work_s"], 1),
            "wait": round(t["wait_s"], 1),
            "prompt": t["prompt"],
        } for t in turns]
        blocks["agent.phases"] = _block(
            "任务阶段",
            "agent",
            "阶段按用户 prompt 分类；占比用工作秒，不含 CheckCommandStatus 空等。每回合 prompt 全文首行。",
            [
                _table(rows_p, [("phase", "阶段"), ("n", "回合"), ("work", "工作秒"), ("sec", "墙钟秒"), ("share", "工作%")], "阶段占比"),
                _table(rows_turn, [("ts", "时间"), ("phase", "阶段"), ("tools", "工具"), ("work", "工作秒"), ("wait", "等待秒"), ("prompt", "用户首行")], "回合时间线"),
            ],
        )

    summary = {
        "n_rows": len(rows),
        "n_turns": len(turns),
        "n_tools": sum(tool_n.values()),
        "work_s": round(work_s, 1),
        "wait_s": round(wait_s, 1),
        "instances": [{"id": k, "n": v} for k, v in inst_n.most_common()],
        "span": f"{ordered[0].get('ts') if ordered else ''} → {ordered[-1].get('ts') if ordered else ''}",
    }
    feedback = _insights(
        cwd_n=cwd_n,
        git_n=git_n,
        git_branch=git_branch,
        tool_n=tool_n,
        tool_s=tool_s,
        family_n=family_n,
        mcp_n=mcp_n,
        mcp_tool=mcp_tool,
        taste_n=taste_n,
        phase_n=phase_n,
        phase_s=phase_s,
        phase_work=phase_work,
        file_n=file_n,
        file_write=file_write,
        dir_n=dir_n,
        turns=turns,
        wait_s=wait_s,
        work_s=work_s,
        summary=summary,
    )
    return {
        "ok": True,
        "scope": scope,
        "session_id": session_id or "",
        "n_rows": len(rows),
        "n_turns": len(turns),
        "summary": summary,
        "directions": DIRECTIONS,
        "active": want,
        "blocks": blocks,
        "feedback": feedback,
        "draft": "\n".join(f.get("draft") or "" for f in feedback if f.get("draft")).strip(),
    }


def _insights(**kw: Any) -> list[dict[str, str]]:
    out: list[dict[str, str]] = []
    tool_n: Counter[str] = kw["tool_n"]
    family_n: Counter[str] = kw["family_n"]
    mcp_tool: Counter[str] = kw["mcp_tool"]
    mcp_n: Counter[str] = kw["mcp_n"]
    phase_work: dict[str, float] = kw["phase_work"]
    git_n: Counter[str] = kw["git_n"]
    git_branch: dict[str, Counter[str]] = kw["git_branch"]
    taste_n: Counter[str] = kw["taste_n"]
    file_n: Counter[str] = kw["file_n"]
    file_write: Counter[str] = kw["file_write"]
    dir_n: Counter[str] = kw["dir_n"]
    cwd_n: Counter[str] = kw["cwd_n"]
    turns: list[dict[str, Any]] = kw["turns"]
    wait_s: float = kw["wait_s"]
    work_s: float = kw["work_s"]

    total_tools = sum(tool_n.values()) or 1
    work_total = sum(phase_work.values()) or (work_s or 1.0)
    run_n = tool_n.get("RunCommand", 0)
    search_cmd = family_n.get("search", 0)
    read_cmd = family_n.get("read", 0)
    write_n = tool_n.get("Write", 0)

    def add(audience: str, use: str, title: str, text: str, evidence: str, draft: str = "") -> None:
        out.append({
            "audience": audience,
            "use": use,
            "title": title,
            "text": text,
            "evidence": evidence,
            "draft": draft,
        })

    if run_n / total_tools >= 0.45:
        add(
            "agent", "agents.md",
            "阅读靠 shell，不靠 Read",
            (
                f"工具里 RunCommand 占 {round(100 * run_n / total_tools)}%"
                f"（rg/search {search_cmd} 次，cat/read {read_cmd} 次，Write {write_n} 次）。"
                "文件轨迹主要来自命令行，Read 工具几乎缺席。下一轮应直接点名热文件，禁止全库 rg 代替阅读。"
            ),
            f"RunCommand={run_n}/{total_tools} search={search_cmd} read={read_cmd} Write={write_n}",
            "- 改代码先 Read 目标文件；禁止用全库 rg/grep 代替阅读。",
        )
    if wait_s >= work_s and wait_s >= 30:
        add(
            "agent", "prompt",
            "墙钟大半是空等",
            (
                f"等待（CheckCommandStatus 等）{round(wait_s, 1)}s，真正工作 {round(work_s, 1)}s。"
                "阶段占比必须看工作秒，不能把轮询当 review/实现。"
            ),
            f"wait_s={round(wait_s,1)} work_s={round(work_s,1)}",
            "- 评估耗时用工作秒，忽略 CheckCommandStatus 轮询。",
        )
    search_n = sum(v for k, v in mcp_tool.items() if "search" in k)
    add_n = sum(v for k, v in mcp_tool.items() if "memory_add" in k or k.endswith("/add"))
    if search_n >= 3 and add_n == 0:
        add(
            "agent", "agents.md",
            "nmem 只搜不写",
            f"MCP 搜索 {search_n} 次、memory_add {add_n} 次。知识只读不沉淀。非琐碎结论必须 memory_add。",
            f"search={search_n} add={add_n} servers={dict(mcp_n)}",
            "- 非琐碎结论必须 memory_add；禁止只 search。",
        )
    elif mcp_n:
        top = mcp_n.most_common(1)[0]
        add(
            "agent", "prompt",
            "MCP 面过窄或过散",
            f"MCP 集中在 {top[0]}（{top[1]} 次，共 {sum(mcp_n.values())}）。确认这是本任务该用的记忆面。",
            f"mcp={list(mcp_tool.most_common(8))}",
        )
    review_work = phase_work.get("review", 0)
    if any("review" in (t.get("prompt") or "").lower() or t.get("phase") == "review" for t in turns):
        share = 100 * review_work / work_total
        if share < 25:
            add(
                "agent", "agents.md",
                "用户要 review，时间却没花在 review",
                (
                    f"用户 prompt 提到 review，但 review 阶段只占工作秒 {round(share, 1)}%"
                    f"（{round(review_work, 1)}s / {round(work_total, 1)}s）。"
                    "实现回合收尾不等于 review。"
                ),
                f"review_work={round(review_work,1)} work_total={round(work_total,1)} turns={len(turns)}",
                "- review 闸门：改完必须对照 diff/测试；不能只用实现回合收尾。",
            )
    if git_n:
        repo, n = git_n.most_common(1)[0]
        branches = ", ".join(b for b, _ in git_branch[repo].most_common(3)) or "（无分支标记）"
        add(
            "user", "prompt",
            "把仓库根写进任务",
            f"最常落在 git 库 {repo}（{n} 次，分支 {branches}）。新开任务在 prompt 里写明仓库根与分支。",
            f"repos={list(git_n.most_common(5))}",
            f"- 默认仓库 `{repo}`" + (f" 分支 `{branches}`。" if branches else "。"),
        )
    if cwd_n:
        cwd, n = cwd_n.most_common(1)[0]
        add(
            "user", "prompt",
            "主工作目录",
            f"主工作目录 {cwd}（{n} 次）。",
            f"cwd_top={list(cwd_n.most_common(5))}",
            f"- 工作目录 `{cwd}`。",
        )
    if taste_n:
        top = [k for k, _ in taste_n.most_common(4) if k != "taste-mention"]
        named = [k for k in top if "/" in k or k.startswith("skill:")]
        doc = named[0] if named else (top[0] if top else taste_n.most_common(1)[0][0])
        n = taste_n[doc]
        listing = "、".join(f"{k} ×{taste_n[k]}" for k in (named or top)[:4])
        add(
            "agent", "agents.md",
            "规范被提到却不是闸门",
            f"本会话碰到 {listing}。必须写明是哪个项目的 AGENTS、哪条 skill，禁止只说 SKILL.md。口头 taste 不会执行。",
            f"taste={dict(taste_n)}",
            f"- 执行 `{doc}` 的闸门（×{n}）；禁止只引用文件名 SKILL.md / AGENTS.md。",
        )
    if file_n:
        path, n = file_n.most_common(1)[0]
        hot_dir = dir_n.most_common(1)[0][0] if dir_n else ""
        add(
            "agent", "prompt",
            "点名热文件，少搜一轮",
            (
                f"最热文件 {path}（{n} 次，写入 {file_write.get(path, 0)}）。"
                + (f" 最热目录 {hot_dir}。" if hot_dir else "")
                + " 下一轮 prompt 直接点名这些路径。"
            ),
            f"files={list(file_n.most_common(8))}",
            f"- 核心文件 `{path}`。",
        )
    if not out:
        add("user", "prompt", "样本不足", "事件太少，还不够形成稳定习惯。多几个完整回合后再分析。", "n=0")
    return out


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
