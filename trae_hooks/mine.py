"""Session mining: sessions are an asset only if they produce feedback.

Does not return tool bodies. Heads of tool_input/response are enough to
rank cwd, git, files, tools, MCP, and turn phases.
"""

from __future__ import annotations

import bisect
import json
import os
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

DIRECTIONS: list[dict[str, str]] = [
    {"id": "user.cwd", "axis": "user", "title": "工作目录"},
    {"id": "user.git", "axis": "user", "title": "Git 库"},
    {"id": "user.taste", "axis": "user", "title": "Taste / 规范"},
    {"id": "user.prompt", "axis": "user", "title": "任务描述"},
    {"id": "user.reminders", "axis": "user", "title": "用户提醒"},
    {"id": "user.flow", "axis": "user", "title": "操作流程"},
    {"id": "agent.files", "axis": "agent", "title": "读写文件"},
    {"id": "agent.tools", "axis": "agent", "title": "工具调用"},
    {"id": "agent.failures", "axis": "agent", "title": "失败/重试"},
    {"id": "agent.hot", "axis": "agent", "title": "热点/冗余"},
    {"id": "agent.mcp", "axis": "agent", "title": "MCP"},
    {"id": "agent.phases", "axis": "agent", "title": "任务阶段"},
    {"id": "agent.metrics", "axis": "agent", "title": "成本/缓存/上下文"},
]

# Tool names that mutate files. A file_path is a write only when one of these fired;
# RunCommand paths are reads. This is what separates "read 43 times" from "wrote 0".
_WRITE_TOOLS = {
    "Write", "Edit", "MultiEdit", "NotebookEdit",
    "str_replace", "apply_patch", "create_file", "write_file", "edit_file",
}

_RE_PROMPT_REPO = re.compile(
    r"repo|仓库|分支|branch|git\b|/repos?/|[A-Za-z0-9_.-]+@[A-Za-z0-9_./-]+", re.I,
)

DIR_IDS = tuple(d["id"] for d in DIRECTIONS)

# The Agent's optimization surface. `id` is stable across sessions; UI and Agent
# both read these keys, so never rename one without evolving the contract in
# docs/session-analysis.md.
METRICS: tuple[dict[str, Any], ...] = (
    {"id": "turns", "label": "回合", "unit": "", "dir": "flat", "target": None, "note": "窗口内回合数"},
    {"id": "tools", "label": "工具调用", "unit": "", "dir": "flat", "target": None, "note": "PostToolUse 次数"},
    {"id": "tools_per_turn", "label": "工具/回合", "unit": "", "dir": "down", "target": 25, "note": "单回合超过 25 次即过载"},
    {"id": "work_s", "label": "工作秒", "unit": "s", "dir": "flat", "target": None, "note": "非等待工具墙钟"},
    {"id": "wait_s", "label": "等待秒", "unit": "s", "dir": "down", "target": None, "note": "轮询/等待墙钟"},
    {"id": "wall_s", "label": "墙钟", "unit": "s", "dir": "flat", "target": None, "note": "工作 + 等待"},
    {"id": "waste_pct", "label": "浪费占比", "unit": "%", "dir": "down", "target": 20, "note": "(等待 + 失败) / 墙钟"},
    {"id": "fail_n", "label": "失败调用", "unit": "", "dir": "down", "target": 0, "note": "exit_code != 0"},
    {"id": "fail_rate_pct", "label": "失败率", "unit": "%", "dir": "down", "target": 5, "note": "失败 / 工具"},
    {"id": "retry_n", "label": "同回合重试", "unit": "", "dir": "down", "target": 0, "note": "同族失败后又跑一次"},
    {"id": "reread_extra", "label": "多余读取", "unit": "", "dir": "down", "target": None, "note": "同一文件第 2 次起计数"},
    {"id": "reread_ratio", "label": "重复读/文件", "unit": "次", "dir": "down", "target": 2.0, "note": "读取次数 / 去重文件数"},
    {"id": "locate_s", "label": "定位搜索秒", "unit": "s", "dir": "down", "target": None, "note": "缺路径线索回合的搜索族墙钟"},
    {"id": "idle_s", "label": "空档秒", "unit": "s", "dir": "down", "target": None, "note": ">600s（>10 分钟无事件）累计"},
    {"id": "extra_trips", "label": "额外往返", "unit": "", "dir": "down", "target": 0, "note": "短催 + 纠正 + 催促"},
    {"id": "cost_usd", "label": "费用", "unit": "USD", "dir": "down", "target": None, "note": "实测计费"},
    {"id": "cache_hit_pct", "label": "缓存命中率", "unit": "%", "dir": "up", "target": 90, "note": "cacheRead / (cacheRead + 未缓存 input)"},
    {"id": "cache_write_n", "label": "写缓存回合", "unit": "", "dir": "down", "target": 0, "note": "前缀被改写"},
    {"id": "skill_tokens", "label": "skill 重复传输", "unit": "tok", "dir": "down", "target": None, "note": "估算：正文 tokens × 剩余回合"},
    {"id": "loss_usd", "label": "可归因损耗 $", "unit": "USD", "dir": "down", "target": None, "note": "损耗账本合计"},
    {"id": "loss_s", "label": "可归因损耗秒", "unit": "s", "dir": "down", "target": None, "note": "损耗账本合计"},
)

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

# Metrics plane. Tolerated to be missing on stores created before this feature.
USAGE_SQL = """
SELECT
    CAST(ts AS VARCHAR) AS ts,
    session_id,
    model,
    provider,
    turn_index,
    input_tokens,
    output_tokens,
    cache_read_tokens,
    cache_write_tokens,
    reasoning_tokens,
    total_tokens,
    cost_total,
    ttft_ms,
    elapsed_ms,
    decode_ms,
    tok_s_decode,
    tok_s_e2e
FROM llm_usage
WHERE 1=1
"""

CTX_SQL = """
SELECT
    CAST(ts AS VARCHAR) AS ts,
    session_id,
    turn_index,
    system_tokens,
    preamble_tokens,
    tools_tokens,
    rules_tokens,
    docs_tokens,
    project_tokens,
    skills_tokens,
    prompt_tokens,
    history_tokens,
    prompt_total_tokens,
    skill_names,
    skill_loaded_tokens,
    memory_ids
FROM turn_context
WHERE 1=1
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


def norm_path(p: str | None, base: str | None = None) -> str:
    """Absolute-ish key for a file path so relative spellings collapse."""
    s = unescape(str(p or "")).strip()
    if not s:
        return ""
    if s.startswith("/"):
        return s
    b = str(base or "").rstrip("/")
    if not b:
        return s
    if s.startswith(b + "/"):
        return s
    return f"{b}/{s}"


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


def is_write_tool(name: str | None, llm_name: str | None = None) -> bool:
    return str(name or "") in _WRITE_TOOLS or str(llm_name or "") in _WRITE_TOOLS


def norm_cmd(cmd: str | None) -> str:
    """Collapse whitespace and numeric args so `sed -n '1,240p' X` groups."""
    c = re.sub(r"\s+", " ", cmd_label(cmd)).strip()
    c = re.sub(r"\b[0-9]+\b", "N", c)
    return c[:120]


_SHELL_PROLOGUE = re.compile(r"^(?:set|export|source|shopt)\b|^[{}]$", re.I)


def cmd_label(cmd: str | None) -> str:
    """First meaningful line: skip `set -euo pipefail` / `export` prologues."""
    for line in str(cmd or "").split("\n"):
        s = line.strip()
        if not s or _SHELL_PROLOGUE.match(s):
            continue
        return s[:120]
    return ""


def parse_ts(value: Any) -> float | None:
    """Epoch-ish floats (fixtures) or DuckDB timestamp strings (live)."""
    s = str(value or "").strip()
    if not s:
        return None
    if re.fullmatch(r"[0-9]+(?:\.[0-9]+)?", s):
        try:
            return float(s)
        except ValueError:
            return None
    cleaned = s.replace("Z", "+00:00")
    for sep in ("T", " "):
        if sep in cleaned:
            cleaned = cleaned.replace(" ", "T", 1)
            break
    try:
        from datetime import datetime
        return datetime.fromisoformat(cleaned).timestamp()
    except (ValueError, TypeError):
        return None


def prompt_has_path(text: str | None) -> bool:
    return "/" in str(text or "")


def prompt_has_repo(text: str | None) -> bool:
    return bool(_RE_PROMPT_REPO.search(str(text or "")))


_RE_CONTINUE = re.compile(r"^(?:继续|接着|往下|go on|next|ok|好)[。.!！~ ]*$", re.I)

# What the user keeps having to say. A theme that repeats should become an
# AGENTS.md gate instead of a spoken reminder every turn.
_GATE_DRAFT = {
    "纠正": "- 动手前先用一句话复述需求与验收标准，确认后再改。",
    "重申约束": "- 把「注意/必须/禁止」类约束固化进 AGENTS.md，执行前自查。",
    "催促": "- 长任务每完成一个子目标先给进展与结论，再继续。",
    "没看到": "- 交付前自查：结果/日志/run 是否可见、可复现。",
    "沉淀提醒": "- 非琐碎结论默认 memory_add，不等用户催。",
    "加载上下文": "- 开工先加载相关 AGENTS / skill / nmem，再动手。",
    "重新执行": "- 失败先读错误再改，禁止原样重跑。",
    "推进": "- 长任务自驱到阶段结论再停，不要一步一等。",
}


def reminder_hits(text: str | None) -> list[str]:
    """Themes that signal the user is reminding / correcting / nudging."""
    t = str(text or "")
    low = t.lower()
    hits: list[str] = []
    if re.search(r"认知错误|搞错|不对|不正确|有误|不是.{0,8}而是|不符合预期|太浅|有问题", t):
        hits.append("纠正")
    if re.search(r"注意|记得|必须|一定要|禁止|唯一|只能|不要|别|不需要|无需|不用|应该", t):
        hits.append("重申约束")
    if re.search(r"为什么|怎么还|多久|尽快|还没|没有结果|太慢|用了这么多时间|尚未", t):
        hits.append("催促")
    if re.search(r"没看到|没有看到|都丢了|丢了|不见了|停了|挂了|崩了|没结果", t):
        hits.append("没看到")
    if ("nmem" in low or "memory" in low) and re.search(r"写入|记录|整理|梳理|沉淀|结构化|落到|落盘|存(?:入|到)|更新到|补充到|写到", t):
        hits.append("沉淀提醒")
    if re.search(r"从\s*nmem|加载|guideline|上下文|taste|规范|读取", t, re.I):
        hits.append("加载上下文")
    if re.search(r"重新|再次|重跑|再测|再来|重试", t):
        hits.append("重新执行")
    if re.search(r"继续|接着|往下|go on|next", t, re.I):
        hits.append("推进")
    return hits


def prompt_is_nudge(text: str | None) -> bool:
    """Short, content-free push: “继续” / “继续吧” / “ok”."""
    t = str(text or "").strip()
    if not t:
        return False
    if _RE_CONTINUE.match(t):
        return True
    return len(t) <= 8 and not prompt_has_path(t) and not prompt_has_repo(t)


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


def _table(
    rows: list[dict[str, Any]],
    cols: list[tuple[str, str]],
    caption: str = "",
    chart: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """A fact table, optionally annotated with the chart that fits its shape.

    The chart kind is declared where the data is built (not guessed in the UI):
    part-to-whole -> stack/donut, trend -> line, ordered points -> columns,
    ranked comparison -> bars. The table is still rendered: 不折叠细节.
    """
    out: dict[str, Any] = {
        "caption": caption,
        "cols": [{"id": i, "title": t} for i, t in cols],
        "rows": rows,
    }
    if chart and rows:
        out["chart"] = chart
    return out


def _block(title: str, axis: str, note: str, tables: list[dict[str, Any]]) -> dict[str, Any]:
    return {"title": title, "axis": axis, "note": note, "table": tables[0] if tables else _table([], []), "tables": tables}


def _pct(part: float, whole: float) -> float:
    return round(100.0 * part / whole, 1) if whole else 0.0


def _avg(values: list[float]) -> float:
    return round(sum(values) / len(values), 1) if values else 0.0


def _skill_tokens_of(raw: Any) -> int:
    """skill -> tokens dict from turn_context.skill_loaded_tokens (cold path only)."""
    if not raw:
        return 0
    try:
        data = json.loads(raw) if isinstance(raw, str) else raw
    except (ValueError, TypeError):
        return 0
    if not isinstance(data, dict):
        return 0
    return sum(int(v or 0) for v in data.values())


# Section labels for the context-composition table, in prompt order.
_CTX_SECTIONS = (
    ("system", "system 合计"),
    ("rules", "rules (AGENTS)"),
    ("project", "project_context"),
    ("tools", "工具声明"),
    ("skills", "skills 索引"),
    ("history", "history 累计"),
    ("prompt", "当前 prompt"),
    ("total", "合计"),
)


def metrics_analysis(
    usage_rows: list[dict[str, Any]],
    ctx_rows: list[dict[str, Any]],
) -> tuple[dict[str, Any] | None, list[dict[str, str]]]:
    """Cost / cache / context read of the metrics plane.

    Money and tok/s are measured. Context tokens are estimates
    (chars / calibrated chars-per-token), so the block note says so and the
    realized estimate ratio is shown so nobody reads them as billing truth.
    """
    if not usage_rows:
        return None, []

    n = len(usage_rows)
    cost = sum(float(r.get("cost_total") or 0) for r in usage_rows)
    inp = sum(int(r.get("input_tokens") or 0) for r in usage_rows)
    cr = sum(int(r.get("cache_read_tokens") or 0) for r in usage_rows)
    cw = sum(int(r.get("cache_write_tokens") or 0) for r in usage_rows)
    out = sum(int(r.get("output_tokens") or 0) for r in usage_rows)
    reasoning = sum(int(r.get("reasoning_tokens") or 0) for r in usage_rows)
    hit = _pct(cr, inp + cr)
    decode = _avg([float(r["tok_s_decode"]) for r in usage_rows if r.get("tok_s_decode")])
    e2e = _avg([float(r["tok_s_e2e"]) for r in usage_rows if r.get("tok_s_e2e")])
    ttft = _avg([float(r["ttft_ms"]) for r in usage_rows if r.get("ttft_ms")])
    cold_turns = sum(1 for r in usage_rows if not r.get("cache_read_tokens"))
    write_turns = sum(1 for r in usage_rows if r.get("cache_write_tokens"))

    models: dict[str, dict[str, Any]] = {}
    for r in usage_rows:
        b = models.setdefault(str(r.get("model") or "?"), {"n": 0, "usd": 0.0, "inp": 0, "cr": 0, "out": 0, "e2e": []})
        b["n"] += 1
        b["usd"] += float(r.get("cost_total") or 0)
        b["inp"] += int(r.get("input_tokens") or 0)
        b["cr"] += int(r.get("cache_read_tokens") or 0)
        b["out"] += int(r.get("output_tokens") or 0)
        if r.get("tok_s_e2e"):
            b["e2e"].append(float(r["tok_s_e2e"]))

    days: dict[str, dict[str, Any]] = {}
    for r in usage_rows:
        b = days.setdefault(str(r.get("ts") or "")[:10], {"n": 0, "usd": 0.0, "out": 0, "cr": 0})
        b["n"] += 1
        b["usd"] += float(r.get("cost_total") or 0)
        b["out"] += int(r.get("output_tokens") or 0)
        b["cr"] += int(r.get("cache_read_tokens") or 0)

    def _mean(col: str) -> float:
        return _avg([float(r[col]) for r in ctx_rows if r.get(col)])

    sections = {
        "total": _mean("prompt_total_tokens"),
        "system": _mean("system_tokens"),
        "rules": _mean("rules_tokens"),
        "project": _mean("project_tokens"),
        "tools": _mean("tools_tokens"),
        "skills": _mean("skills_tokens"),
        "history": _mean("history_tokens"),
        "prompt": _mean("prompt_tokens"),
    }
    # Realized estimate ratio: context estimate vs billed prompt tokens.
    est_ratio = 0.0
    if ctx_rows:
        pairs = [
            float(r["prompt_total_tokens"]) / float(u["input_tokens"] + (u["cache_read_tokens"] or 0))
            for r, u in zip(ctx_rows, usage_rows)
            if r.get("prompt_total_tokens") and (u.get("input_tokens") or 0) + (u.get("cache_read_tokens") or 0) > 0
        ]
        est_ratio = _avg(pairs)

    # Loaded-skill context cost: tokens each SKILL.md dumped into context this turn.
    # Position-independent: measured from the toolResult the skill read produced.
    skill_tokens: dict[str, list[int]] = {}
    for r in ctx_rows:
        raw = r.get("skill_loaded_tokens")
        if not raw:
            continue
        try:
            data = json.loads(raw) if isinstance(raw, str) else raw
        except (ValueError, TypeError):
            continue
        for name, toks in (data or {}).items():
            skill_tokens.setdefault(str(name), []).append(int(toks or 0))
    mem_turns = sum(1 for r in ctx_rows if str(r.get("memory_ids") or "").strip())

    overview = [
        {"metric": "回合", "value": str(n)},
        {"metric": "费用 USD", "value": f"{cost:.4f}"},
        {"metric": "输出 tokens", "value": f"{out:,}"},
        {"metric": "推理 tokens", "value": f"{reasoning:,}"},
        {"metric": "未缓存输入", "value": f"{inp:,}"},
        {"metric": "缓存读", "value": f"{cr:,}"},
        {"metric": "缓存命中率", "value": f"{hit}%"},
        {"metric": "解码 tok/s", "value": str(decode) if decode else "-"},
        {"metric": "端到端 tok/s", "value": str(e2e) if e2e else "-"},
        {"metric": "首字延迟 ms", "value": str(ttft) if ttft else "-"},
        {"metric": "空缓存回合", "value": str(cold_turns)},
        {"metric": "写缓存回合", "value": str(write_turns)},
    ]
    model_rows = [
        {
            "model": m,
            "n": b["n"],
            "usd": round(b["usd"], 4),
            "inp": b["inp"],
            "cr": b["cr"],
            "out": b["out"],
            "hit": _pct(b["cr"], b["inp"] + b["cr"]),
            "e2e": _avg(b["e2e"]),
        }
        for m, b in sorted(models.items(), key=lambda kv: -kv[1]["usd"])
    ]
    ctx_tbl = [{"section": label, "tokens": sections.get(key, 0)} for key, label in _CTX_SECTIONS]
    day_rows = [
        {"day": d, "n": b["n"], "usd": round(b["usd"], 4), "out": b["out"], "cr": b["cr"]}
        for d, b in sorted(days.items())
    ]
    skill_tbl = [
        {
            "skill": k,
            "loads": len(v),
            "avg_tokens": _avg([float(x) for x in v]),
            "total_tokens": sum(v),
        }
        for k, v in sorted(skill_tokens.items(), key=lambda kv: -sum(kv[1]))
    ]

    note = (
        f"费用/tok 为实测；上下文 tokens 为估算（chars / 校准 cpt；本样本估算/实测 = {est_ratio}）。"
        "命中率 = cacheRead / (cacheRead + 未缓存 input)。"
    )
    block = _block(
        "成本 / 缓存 / 上下文",
        "agent",
        note,
        [
            _table(overview, [("metric", "指标"), ("value", "值")], "总览"),
            _table(model_rows, [("model", "模型"), ("n", "回合"), ("usd", "USD"), ("inp", "未缓存in"), ("cr", "缓存读"), ("out", "出"), ("hit", "命中%"), ("e2e", "e2e tok/s")], "按模型",
                    {"kind": "bars", "label": "model", "value": "usd", "unit": "USD"}),
            _table(ctx_tbl, [("section", "段"), ("tokens", "平均 tokens")], "上下文构成（估算）",
                    {"kind": "stack", "label": "section", "value": "tokens", "unit": "tok"}),
            _table(day_rows, [("day", "日期"), ("n", "回合"), ("usd", "USD"), ("out", "出"), ("cr", "缓存读")], "每天成本曲线",
                    {"kind": "line", "label": "day", "value": "usd", "unit": "USD"}),
            _table(skill_tbl, [("skill", "加载的 skill"), ("loads", "次数"), ("avg_tokens", "平均 tokens"), ("total_tokens", "合计 tokens")], "Skill 上下文成本（SKILL.md 正文）",
                    {"kind": "bars", "label": "skill", "value": "total_tokens", "unit": "tok"}),
        ],
    )

    # Metrics-plane findings (cache miss / skill cost / memory coverage) live in the
    # loss account (_insights) so there is exactly one place that turns a number
    # into a claim. This function returns facts only.
    return block, []


def mine_rows(
    rows: list[dict[str, Any]],
    *,
    dirs: list[str] | None = None,
    session_id: str | None = None,
    scope: str = "session",
    usage_rows: list[dict[str, Any]] | None = None,
    ctx_rows: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    want = [d for d in (dirs or list(DIR_IDS)) if d in DIR_IDS]
    if not want:
        want = list(DIR_IDS)

    cwd_n: Counter[str] = Counter()
    git_n: Counter[str] = Counter()
    git_branch: dict[str, Counter[str]] = defaultdict(Counter)
    file_n: Counter[str] = Counter()
    file_read: Counter[str] = Counter()
    file_write: Counter[str] = Counter()
    dir_n: Counter[str] = Counter()
    ext_n: Counter[str] = Counter()
    cmd_norm: Counter[str] = Counter()
    slow_cmds: list[tuple[float, str]] = []
    tool_n: Counter[str] = Counter()
    tool_s: dict[str, float] = defaultdict(float)
    tool_fail: Counter[str] = Counter()
    fail_tool: Counter[str] = Counter()
    fail_family: Counter[str] = Counter()
    family_n: Counter[str] = Counter()
    family_s: dict[str, float] = defaultdict(float)
    mcp_n: Counter[str] = Counter()
    mcp_tool: Counter[str] = Counter()
    taste_n: Counter[str] = Counter()
    inst_n: Counter[str] = Counter()
    phase_n: Counter[str] = Counter()
    phase_s: dict[str, float] = defaultdict(float)
    phase_work: dict[str, float] = defaultdict(float)
    ts_vals: list[float] = []
    prompt_n = 0
    prompt_chars: list[int] = []
    reminder_n: Counter[str] = Counter()
    reminder_samples: dict[str, list[str]] = defaultdict(list)
    nudge_n = 0
    structured_n = 0
    wait_s = 0.0
    work_s = 0.0
    fail_s = 0.0
    fail_n = 0

    ordered = sorted(rows, key=lambda r: (str(r.get("ts") or ""), str(r.get("event_id") or "")))
    for raw in ordered:
        tv = parse_ts(raw.get("ts"))
        if tv is not None:
            ts_vals.append(tv)
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
            if hook == "UserPromptSubmit" and prompt.strip():
                text = prompt.strip()
                prompt_n += 1
                prompt_chars.append(len(text))
                for theme in reminder_hits(text):
                    reminder_n[theme] += 1
                    if len(reminder_samples[theme]) < 3:
                        reminder_samples[theme].append(first_line(text, 140))
                if prompt_is_nudge(text):
                    nudge_n += 1
                if "\n" in text or re.search(r"^\s*[-*•]|\b1\.[^0-9]", text, re.M):
                    structured_n += 1
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
            fail_tool[name] += 1
            fail_n += 1
            fail_s += wall
        wd = str(parsed.get("workdir") or cwd or "").rstrip("/")
        if wd:
            cwd_n[wd] += 1
            g = git_from_path(wd)
            if g:
                git_n[g[0]] += 1
                if g[1]:
                    git_branch[g[0]][g[1]] += 1
        write_hit = is_write_tool(name, raw.get("llm_tool_name"))
        fp_raw = str(parsed.get("file_path") or "")
        # Canonical (absolute) path for counters: relative and absolute spellings of
        # the same file must not look like two files, or 重复读 double-counts.
        fp = norm_path(fp_raw, wd or cwd)
        if fp:
            file_n[fp] += 1
            if write_hit:
                file_write[fp] += 1
            else:
                file_read[fp] += 1
            dir_n[str(Path(fp).parent)] += 1
            if Path(fp).suffix:
                ext_n[Path(fp).suffix] += 1
        cmd = str(parsed.get("cmd") or "")
        fam = cmd_family(cmd) if cmd else ""
        if fam:
            family_n[fam] += 1
            family_s[fam] += wall
            if parsed.get("exit_code") not in (None, 0):
                fail_family[fam] += 1
        if cmd:
            label = cmd_label(cmd)
            if label:
                cmd_norm[norm_cmd(label)] += 1
                slow_cmds.append((wall, first_line(label, 120)))
        cmd_paths = paths_from_cmd(cmd)
        for p_raw in cmd_paths:
            p = norm_path(p_raw, wd or cwd)
            file_n[p] += 1
            if fam in ("read", "search"):
                file_read[p] += 1
            dir_n[str(Path(p).parent)] += 1
            if Path(p).suffix:
                ext_n[Path(p).suffix] += 1
        for key in taste_keys(fp_raw, wd, cwd, cmd, *cmd_paths):
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
    refs: dict[str, list[dict[str, Any]]] = {"fail": [], "wait": [], "read": [], "locate": []}
    # Exclusive second accounting (by priority: fail > retry > reread > locate):
    # a call is charged to at most one loss, so loss seconds never double count.
    sec_fail = 0.0
    sec_retry = 0.0
    sec_locate = 0.0
    sec_reread = 0.0
    reread_n = 0
    seen_reads: dict[str, int] = {}
    reread_files: Counter[str] = Counter()
    reread_s_files: dict[str, float] = defaultdict(float)

    def _ref(tidx: int, raw: dict[str, Any], label: str, wall: float, **extra: Any) -> dict[str, Any]:
        """One attributable pointer: the Agent must be able to jump to this event."""
        return {
            "turn": tidx,
            "ts": str(raw.get("ts") or ""),
            "event_id": raw.get("event_id"),
            "label": first_line(label, 100),
            "s": round(float(wall or 0), 1),
            **extra,
        }

    for raw in ordered:
        hook = str(raw.get("hook_event") or "")
        if hook == "UserPromptSubmit":
            # A new prompt closes the previous turn even without a Stop event:
            # the pi hook path has no Stop, so dropping it would merge a whole
            # session into one turn and make every per-turn number a lie.
            if pending is not None:
                turns.append(pending)
            prompt_text = str(raw.get("prompt") or "")
            hits = set(reminder_hits(prompt_text))
            pending = {
                "ts": str(raw.get("ts") or ""),
                "event_id": raw.get("event_id"),
                "prompt": first_line(prompt_text, 200),
                "phase": classify_phase(prompt_text),
                "wall_s": 0.0,
                "work_s": 0.0,
                "wait_s": 0.0,
                "retry_s": 0.0,
                "locate_s": 0.0,
                "locate_n": 0,
                "tools": 0,
                "fails": 0,
                "retries": 0,
                "fail_fams": set(),
                "has_path": prompt_has_path(prompt_text),
                "has_repo": prompt_has_repo(prompt_text),
                "nudge": prompt_is_nudge(prompt_text),
                "correction": "纠正" in hits,
                "push": "催促" in hits,
                "cost_usd": 0.0,
                "tokens_out": 0,
                "cache_read": 0,
                "cache_write": 0,
                "ctx_total": 0.0,
                "skill_tokens": 0,
            }
            continue
        if pending and hook == "PostToolUse":
            name = str(raw.get("tool_name") or "")
            inp = parse_head(raw.get("input_head"))
            resp = parse_head(raw.get("resp_head"))
            wall = float(resp.get("wall_s") or 0)
            exit_code = resp.get("exit_code")
            fam = cmd_family(inp.get("cmd"))
            label = cmd_label(inp.get("cmd")) or str(inp.get("file_path") or name)
            # 1-based to match turn["index"], so a ref can jump to its turn.
            tidx = len(turns) + 1
            wait_hit = is_wait_tool(name)
            is_fail = exit_code not in (None, 0)
            is_retry = (not is_fail) and bool(fam) and fam in pending["fail_fams"]
            vague = not pending["has_path"] and not pending["has_repo"]
            fp2 = str(inp.get("file_path") or "")
            write_hit = is_write_tool(name, raw.get("llm_tool_name"))
            read_key = "" if (write_hit or not fp2) else norm_path(fp2, str(inp.get("workdir") or ""))
            # Shell *reads* count too: `cat a.py` three times is the same context
            # rebuild. `rg` targets are not reads here: an unfocused search in a
            # vague turn is located cost, not a re-read.
            read_keys: list[str] = [read_key] if read_key else []
            if fam == "read":
                for p in paths_from_cmd(inp.get("cmd")):
                    k = norm_path(p, str(inp.get("workdir") or ""))
                    if k and k not in read_keys:
                        read_keys.append(k)
            is_locate = (not is_fail) and (not is_retry) and (not wait_hit) and fam == "search" and vague
            repeat_key = next((k for k in read_keys if k in seen_reads), "")
            is_reread = bool(repeat_key) and (not is_fail) and (not is_retry) and (not wait_hit)
            is_locate = is_locate and not is_reread
            for k in read_keys:
                seen_reads[k] = seen_reads.get(k, 0) + 1
            pending["tools"] += 1
            pending["wall_s"] += wall
            if wait_hit:
                pending["wait_s"] += wall
                if len(refs["wait"]) < 20:
                    refs["wait"].append(_ref(tidx, raw, name, wall, tool=name))
            else:
                pending["work_s"] += wall
            if is_fail:
                pending["fails"] += 1
                sec_fail += wall
                if fam:
                    pending["fail_fams"].add(fam)
                if len(refs["fail"]) < 40:
                    refs["fail"].append(_ref(tidx, raw, label, wall, exit_code=exit_code, family=fam or "?"))
            elif is_retry:
                pending["retries"] += 1
                pending["retry_s"] += wall
                sec_retry += wall
                pending["fail_fams"].discard(fam)
            elif is_locate:
                pending["locate_s"] += wall
                pending["locate_n"] += 1
                sec_locate += wall
                if len(refs["locate"]) < 20:
                    refs["locate"].append(_ref(tidx, raw, label, wall))
            elif is_reread:
                sec_reread += wall
                reread_n += 1
                reread_files[repeat_key] += 1
                reread_s_files[repeat_key] += wall
                pending["reread_n"] = int(pending.get("reread_n") or 0) + 1
            if read_key and len(refs["read"]) < 60:
                refs["read"].append(_ref(tidx, raw, label, wall, path=read_key))
        if pending and hook == "Stop":
            turns.append(pending)
            pending = None
    if pending:
        turns.append(pending)
    retry_n = 0
    for i, t in enumerate(turns):
        t["index"] = i + 1
        t.pop("fail_fams", None)
        retry_n += int(t.get("retries") or 0)
        phase_n[t["phase"]] += 1
        phase_s[t["phase"]] += float(t["wall_s"] or 0)
        phase_work[t["phase"]] += float(t["work_s"] or 0)

    # --- L1 attribution: money/tokens land on the turn that spent them ---
    starts = [parse_ts(t["ts"]) or 0.0 for t in turns]
    cache_write_tokens = 0
    cache_write_n = 0
    cold_turns = 0
    total_cost_usd = 0.0
    token_total = 0
    input_uncached_total = 0

    def _bucket(rows_in: list[dict[str, Any]]):
        for r in rows_in:
            tv = parse_ts(r.get("ts"))
            if tv is None or not starts:
                continue
            i = bisect.bisect_right(starts, tv) - 1
            yield (i if i >= 0 else 0), r

    for i, ur in _bucket(usage_rows or []):
        t = turns[i]
        cost = float(ur.get("cost_total") or 0)
        tin = int(ur.get("input_tokens") or 0)
        tout = int(ur.get("output_tokens") or 0)
        cr = int(ur.get("cache_read_tokens") or 0)
        cw = int(ur.get("cache_write_tokens") or 0)
        t["cost_usd"] = float(t.get("cost_usd") or 0) + cost
        t["tokens_out"] = int(t.get("tokens_out") or 0) + tout
        t["cache_read"] = int(t.get("cache_read") or 0) + cr
        t["cache_write"] = int(t.get("cache_write") or 0) + cw
        total_cost_usd += cost
        token_total += tin + tout + cr + cw
        input_uncached_total += tin
        cache_write_tokens += cw
        if cw > 0:
            cache_write_n += 1
        if cr == 0:
            cold_turns += 1
    for i, ctx_row in _bucket(ctx_rows or []):
        t = turns[i]
        t["ctx_total"] = float(t.get("ctx_total") or 0) + float(ctx_row.get("prompt_total_tokens") or 0)
        t["skill_tokens"] = int(t.get("skill_tokens") or 0) + _skill_tokens_of(ctx_row.get("skill_loaded_tokens"))

    unit_usd = (total_cost_usd / token_total) if token_total else 0.0
    tokens_out_total = sum(int(t.get("tokens_out") or 0) for t in turns)
    cache_read_total = sum(int(t.get("cache_read") or 0) for t in turns)
    cache_write_total = sum(int(t.get("cache_write") or 0) for t in turns)
    locate_s = sum(float(t.get("locate_s") or 0) for t in turns)
    locate_n = sum(int(t.get("locate_n") or 0) for t in turns)
    skill_resend = 0
    for i, t in enumerate(turns):
        tk = int(t.get("skill_tokens") or 0)
        if tk:
            skill_resend += tk * max(1, len(turns) - i)
    read_total = sum(file_read.values())
    read_distinct = sum(1 for n in file_read.values() if n > 0)
    reread_ratio = round(read_total / read_distinct, 2) if read_distinct else 0.0

    # --- derived signals: what the headline must say, not another count ---
    redundant_reads = sum(max(0, n - 1) for n in file_read.values())
    distinct_cwd = len(cwd_n)
    distinct_repo = len(git_n)
    total_tools_n = sum(tool_n.values())
    fail_rate = (fail_n / total_tools_n) if total_tools_n else 0.0
    waste_s = wait_s + fail_s
    spend_s = work_s + wait_s
    waste_pct = round(100 * waste_s / spend_s, 1) if spend_s else 0.0
    idle_s = 0.0
    duration_s = 0.0
    if len(ts_vals) >= 2:
        span_vals = sorted(ts_vals)
        gaps = [b - a for a, b in zip(span_vals, span_vals[1:])]
        idle_s = round(sum(g for g in gaps if g > 600), 1)
        duration_s = round(span_vals[-1] - span_vals[0], 1)
    tools_per_turn = round(total_tools_n / len(turns), 1) if turns else 0.0

    score = 100.0
    score -= min(30.0, fail_rate * 150)
    score -= min(25.0, waste_pct * 0.5)
    score -= min(15.0, redundant_reads * 0.05)
    score -= min(10.0, max(0, distinct_repo - 1) * 3)
    score = int(max(0, min(100, round(score))))
    grade = "稳" if score >= 85 else "尚可" if score >= 70 else "有损耗" if score >= 50 else "低效"
    health = {
        "score": score,
        "grade": grade,
        "fail_rate": round(100 * fail_rate, 1),
        "waste_pct": waste_pct,
        "redundant_reads": redundant_reads,
    }

    total_s = wait_s + work_s or 1.0
    blocks: dict[str, Any] = {}
    if "user.cwd" in want:
        blocks["user.cwd"] = _block(
            "工作目录",
            "user",
            "cwd / workdir 出现次数。主目录应写进 prompt，避免 agent 在邻近树里乱走。",
            [_table([{"path": r["key"], "n": r["n"]} for r in _rank(cwd_n)], [("path", "目录"), ("n", "次")],
                    chart={"kind": "bars", "label": "path", "value": "n"})],
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
            [_table(rows_g, [("repo", "库"), ("branch", "分支"), ("n", "次")],
                    chart={"kind": "bars", "label": "repo", "value": "n"})],
        )
    if "user.taste" in want:
        blocks["user.taste"] = _block(
            "Taste / 规范",
            "user",
            "线索必须带项目或技能名（`clipvault/AGENTS.md`、`skill:ce-code-review`），禁止只记 SKILL.md 文件名。",
            [_table([{"doc": r["key"], "n": r["n"]} for r in _rank(taste_n)], [("doc", "线索"), ("n", "次")],
                    chart={"kind": "bars", "label": "doc", "value": "n"})],
        )
    if "agent.files" in want:
        blocks["agent.files"] = _block(
            "读写文件",
            "agent",
            "file_path 来自 Write 族才算写入；RunCommand 里的路径算读取。读多写 0 = 上下文在反复重建。",
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
                _table(rows_t, [("tool", "工具"), ("kind", "类"), ("n", "次"), ("sec", "秒"), ("share", "%"), ("fail", "失败")], "工具",
                    {"kind": "bars", "label": "tool", "value": "sec", "unit": "s"}),
                _table(rows_f, [("family", "shell 族"), ("n", "次"), ("sec", "秒")], "RunCommand 族（git / rg / read / build / test）",
                    {"kind": "bars", "label": "family", "value": "sec", "unit": "s"}),
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
            [_table(rows_m, [("mcp", "调用"), ("kind", "类"), ("n", "次")],
                    chart={"kind": "bars", "label": "mcp", "value": "n"})],
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
            "index": t["index"],
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
                _table(rows_p, [("phase", "阶段"), ("n", "回合"), ("work", "工作秒"), ("sec", "墙钟秒"), ("share", "工作%")], "阶段占比",
                    {"kind": "donut", "label": "phase", "value": "work", "unit": "s"}),
                _table(rows_turn, [("ts", "时间"), ("phase", "阶段"), ("tools", "工具"), ("work", "工作秒"), ("wait", "等待秒"), ("prompt", "用户首行")], "回合时间线",
                    {"kind": "columns", "label": "ts", "value": "work", "unit": "s"}),
            ],
        )
    if "agent.failures" in want:
        rows_ft = [{
            "tool": r["key"],
            "n": tool_n.get(r["key"], 0),
            "fail": r["n"],
            "rate": round(100 * r["n"] / max(1, tool_n.get(r["key"], 0)), 1),
        } for r in _rank(fail_tool)]
        rows_ff = [{
            "family": r["key"],
            "n": family_n.get(r["key"], 0),
            "fail": r["n"],
        } for r in _rank(fail_family)]
        blocks["agent.failures"] = _block(
            "失败与重试",
            "agent",
            f"失败 {fail_n} 次（{round(100 * fail_rate, 1)}% of {total_tools_n}），同回合重试 {retry_n} 次。失败先读 stderr；同一族连续失败两次必须换策略。",
            [
                _table(rows_ft, [("tool", "工具"), ("n", "调用"), ("fail", "失败"), ("rate", "失败%")], "失败工具",
                    {"kind": "bars", "label": "tool", "value": "fail"}),
                _table(rows_ff, [("family", "命令族"), ("n", "调用"), ("fail", "失败")], "失败命令族",
                    {"kind": "bars", "label": "family", "value": "fail"}),
            ],
        )
    if "agent.hot" in want:
        rows_read = [{
            "path": r["key"],
            "reads": r["n"],
            "writes": file_write.get(r["key"], 0),
        } for r in _rank(file_read, 20)]
        rows_cmd = [{"cmd": r["key"], "n": r["n"]} for r in _rank(cmd_norm, 15)]
        rows_slow = [{"sec": round(w, 1), "cmd": c} for w, c in sorted(slow_cmds, reverse=True)[:12]]
        blocks["agent.hot"] = _block(
            "热点与冗余",
            "agent",
            f"冗余读 {redundant_reads} 次；重复命令与最慢命令是下一轮 prompt 应点名的对象。",
            [
                _table(rows_read, [("path", "文件"), ("reads", "读"), ("writes", "写")], "重复读取（与写入对比）",
                    {"kind": "bars", "label": "path", "value": "reads"}),
                _table(rows_cmd, [("cmd", "命令（数字归一）"), ("n", "次")], "重复命令",
                    {"kind": "bars", "label": "cmd", "value": "n"}),
                _table(rows_slow, [("sec", "秒"), ("cmd", "命令")], "最慢命令",
                    {"kind": "bars", "label": "cmd", "value": "sec", "unit": "s"}),
            ],
        )
    if "user.prompt" in want:
        rows_pr = [{
            "ts": t["ts"],
            "phase": t["phase"],
            "tools": t["tools"],
            "path": "有" if t.get("has_path") else "无",
            "repo": "有" if t.get("has_repo") else "无",
            "prompt": t["prompt"],
        } for t in turns]
        vague = sum(1 for t in turns if not t.get("has_path") and not t.get("has_repo"))
        note = f"{vague}/{len(turns)} 个 prompt 没有路径/仓库线索。" if turns else "还没有 prompt。"
        blocks["user.prompt"] = _block(
            "任务描述",
            "user",
            note + " 下一轮开头写死 cwd、仓库根、分支、目标文件。",
            [_table(rows_pr, [("ts", "时间"), ("phase", "阶段"), ("tools", "工具"), ("path", "路径"), ("repo", "仓库"), ("prompt", "首行")], "回合 prompt 质量")],
        )

    avg_prompt = round(sum(prompt_chars) / prompt_n, 1) if prompt_n else 0.0
    correction_n = reminder_n.get("纠正", 0)
    push_n = reminder_n.get("催促", 0)
    sink_n = reminder_n.get("沉淀提醒", 0)
    reminder_total = sum(reminder_n.values())
    extra_trips = nudge_n + correction_n + push_n
    if "user.reminders" in want:
        rows_rem = [{
            "theme": k,
            "n": v,
            "share": round(100 * v / max(1, prompt_n), 1),
        } for k, v in reminder_n.most_common()]
        sample_rows = []
        for k, _ in reminder_n.most_common(6):
            for s in reminder_samples.get(k, [])[:2]:
                sample_rows.append({"theme": k, "prompt": s})
        blocks["user.reminders"] = _block(
            "用户提醒",
            "user",
            f"{prompt_n} 条 prompt 出现 {reminder_total} 处提醒/纠正信号。反复出现的主题要变成 AGENTS 闸门，而不是每次口头重申。",
            [
                _table(rows_rem, [("theme", "主题"), ("n", "次"), ("share", "占比%")], "提醒主题",
                    {"kind": "bars", "label": "theme", "value": "n"}),
                _table(sample_rows, [("theme", "主题"), ("prompt", "样本首行")], "重复提醒样本"),
            ],
        )
    if "user.flow" in want:
        metrics = [
            {"metric": "prompt 数", "value": prompt_n},
            {"metric": "平均字数", "value": avg_prompt},
            {"metric": "≤8 字短催", "value": nudge_n},
            {"metric": "结构化(多行/列表)", "value": structured_n},
            {"metric": "纠正", "value": correction_n},
            {"metric": "催促", "value": push_n},
            {"metric": "沉淀提醒", "value": sink_n},
            {"metric": "额外往返(短催+纠正+催促)", "value": extra_trips},
        ]
        bucket_ranges = [(0, 8), (9, 40), (41, 120), (121, 400), (401, 10**9)]
        bucket_rows = []
        for lo, hi in bucket_ranges:
            label = f"≤{hi}" if lo == 0 else (f"{lo}-{hi}" if hi < 10**9 else f">{lo - 1}")
            bucket_rows.append({"bucket": label, "n": sum(1 for c in prompt_chars if lo <= c <= hi)})
        blocks["user.flow"] = _block(
            "操作流程",
            "user",
            f"额外往返 {extra_trips} 次（短催 {nudge_n} + 纠正 {correction_n} + 催促 {push_n}）。首条 prompt 给全 cwd/仓库/目标/验收，并要求「阶段结论再停」，能直接砍掉这些往返。",
            [
                _table(metrics, [("metric", "指标"), ("value", "值")], "流程摩擦"),
                _table(bucket_rows, [("bucket", "字数"), ("n", "条")], "prompt 长度分布",
                    {"kind": "columns", "label": "bucket", "value": "n"}),
            ],
        )

    summary = {
        "n_rows": len(rows),        "n_turns": len(turns),
        "n_tools": total_tools_n,
        "work_s": round(work_s, 1),
        "wait_s": round(wait_s, 1),
        "fail_n": fail_n,
        "fail_s": round(fail_s, 1),
        "waste_s": round(waste_s, 1),
        "waste_pct": waste_pct,
        "redundant_reads": redundant_reads,
        "reread_ratio": reread_ratio,
        "reread_extra": reread_n,
        "retry_n": retry_n,
        "locate_s": round(locate_s, 1),
        "cache_write_n": cache_write_n,
        "skill_resend_tokens": skill_resend,
        "tokens_out": tokens_out_total,
        "cache_read": cache_read_total,
        "cache_write": cache_write_total,
        "distinct_cwd": distinct_cwd,
        "distinct_repo": distinct_repo,
        "tools_per_turn": tools_per_turn,
        "duration_s": duration_s,
        "idle_s": idle_s,
        "health": health,
        "flow": {
            "prompt_n": prompt_n,
            "avg_chars": avg_prompt,
            "nudge_n": nudge_n,
            "correction_n": correction_n,
            "push_n": push_n,
            "sink_n": sink_n,
            "structured_n": structured_n,
            "reminder_total": reminder_total,
            "extra_roundtrips": extra_trips,
            "reminders": dict(reminder_n),
        },
        "instances": [{"id": k, "n": v} for k, v in inst_n.most_common()],
        "span": f"{ordered[0].get('ts') if ordered else ''} → {ordered[-1].get('ts') if ordered else ''}",
    }
    mblock: dict[str, Any] | None = None
    if "agent.metrics" in want:
        mblock, _mfeed = metrics_analysis(usage_rows or [], ctx_rows or [])
        if mblock:
            blocks["agent.metrics"] = mblock
        if usage_rows:
            mcost = sum(float(r.get("cost_total") or 0) for r in usage_rows)
            mcr = sum(int(r.get("cache_read_tokens") or 0) for r in usage_rows)
            minp = sum(int(r.get("input_tokens") or 0) for r in usage_rows)
            summary["cost_usd"] = round(mcost, 4)
            summary["cache_hit_pct"] = round(100.0 * mcr / (mcr + minp), 1) if (mcr + minp) else 0.0
            summary["usage_turns"] = len(usage_rows)

    total_cost_usd = total_cost_usd or float(summary.get("cost_usd") or 0)
    total_wall = round(work_s + wait_s, 1)
    plane = {
        "cache_write_n": cache_write_n,
        "cache_write_tokens": cache_write_tokens,
        "cold_turns": cold_turns,
        "skill_tokens": skill_resend,
    }
    losses = build_losses(
        turns=turns,
        refs=refs,
        fail_n=fail_n,
        sec_fail=sec_fail,
        sec_retry=sec_retry,
        retry_n=retry_n,
        wait_s=wait_s,
        sec_locate=sec_locate,
        locate_n=locate_n,
        sec_reread=sec_reread,
        reread_n=reread_n,
        reread_detail=sorted(
            [{"path": p, "reads": n, "s": round(reread_s_files.get(p, 0.0), 1)} for p, n in reread_files.items()],
            key=lambda r: -r["s"],
        ),
        cache_write_tokens=cache_write_tokens,
        cache_write_n=cache_write_n,
        unit_usd=unit_usd,
        cost_usd=total_cost_usd,
        idle_s=idle_s,
        skill_resend_tokens=skill_resend,
        total_wall=total_wall,
    )
    metrics = build_metrics(summary, losses, plane=plane)
    feedback = _insights(
        losses=losses,
        metrics=metrics,
        summary=summary,
        turns=turns,
        flow=summary.get("flow") or {},
        plane=plane,
    )
    # Compact per-turn ledger for the timeline: what the Agent actually did, turn by
    # turn, with the money that turn spent. Capped so the sheet stays one payload.
    turn_rows = [{
        "index": int(t["index"]),
        "ts": t["ts"],
        "phase": t["phase"],
        "tools": int(t["tools"]),
        "fails": int(t.get("fails") or 0),
        "retries": int(t.get("retries") or 0),
        "work_s": round(float(t["work_s"] or 0), 1),
        "wait_s": round(float(t["wait_s"] or 0), 1),
        "wall_s": round(float(t["wall_s"] or 0), 1),
        "cost_usd": round(float(t.get("cost_usd") or 0), 4),
        "tokens_out": int(t.get("tokens_out") or 0),
        "cache_write": int(t.get("cache_write") or 0),
        "prompt": t["prompt"],
        "nudge": bool(t.get("nudge")),
    } for t in turns[:400]]
    return {
        "ok": True,
        "scope": scope,
        "session_id": session_id or "",
        "n_rows": len(rows),
        "n_turns": len(turns),
        "window": {
            "from": ordered[0].get("ts") if ordered else "",
            "to": ordered[-1].get("ts") if ordered else "",
            "turns": len(turns),
            "tools": total_tools_n,
            "instances": [k for k, _ in inst_n.most_common()],
            "truncated": len(rows) >= 12000,
        },
        "summary": summary,
        "metrics": metrics,
        "losses": losses,
        "findings": feedback,
        "turns": turn_rows,
        "series": {
            # Charts read these directly: the gauge needs the split behind the ratio.
            "cache": {
                "hit_pct": summary.get("cache_hit_pct"),
                "read": cache_read_total,
                "uncached": input_uncached_total,
                "write": cache_write_total,
            },
        },
        "directions": DIRECTIONS,
        "active": want,
        "blocks": blocks,
        "feedback": feedback,
        "draft": "\n".join(f.get("draft") or "" for f in feedback if f.get("draft")).strip(),
        "rerun": "",
    }


def build_metrics(
    summary: dict[str, Any],
    losses: list[dict[str, Any]],
    *,
    plane: dict[str, Any] | None = None,
) -> list[dict[str, Any]]:
    """The Agent's optimization surface: stable ids, now-value, target, direction.

    Baseline is attached later (attach_baseline) because it needs a second window.
    """
    flow = summary.get("flow") or {}
    health = summary.get("health") or {}
    loss_by_id = {str(l.get("id")): l for l in losses}
    plane = plane or {}

    def val(mid: str) -> Any:
        if mid == "turns":
            return summary.get("n_turns", 0)
        if mid == "tools":
            return summary.get("n_tools", 0)
        if mid == "tools_per_turn":
            return summary.get("tools_per_turn", 0)
        if mid == "work_s":
            return summary.get("work_s", 0)
        if mid == "wait_s":
            return summary.get("wait_s", 0)
        if mid == "wall_s":
            return round(float(summary.get("work_s") or 0) + float(summary.get("wait_s") or 0), 1)
        if mid == "fail_n":
            return summary.get("fail_n", 0)
        if mid == "fail_rate_pct":
            return health.get("fail_rate", 0)
        if mid == "retry_n":
            return summary.get("retry_n", 0)
        if mid == "waste_pct":
            return health.get("waste_pct", 0)
        if mid == "reread_extra":
            return summary.get("reread_extra", summary.get("redundant_reads", 0))
        if mid == "reread_ratio":
            return summary.get("reread_ratio", 0)
        if mid == "locate_s":
            return summary.get("locate_s")
        if mid == "extra_trips":
            return flow.get("extra_roundtrips", 0)
        if mid == "idle_s":
            return summary.get("idle_s", 0)
        if mid == "cost_usd":
            return summary.get("cost_usd")
        if mid == "cache_hit_pct":
            return summary.get("cache_hit_pct")
        if mid == "cache_write_n":
            return plane.get("cache_write_n")
        if mid == "skill_tokens":
            return plane.get("skill_tokens")
        if mid == "loss_usd":
            return round(sum(float(l.get("usd") or 0) for l in losses), 4)
        if mid == "loss_s":
            return round(sum(float(l.get("s") or 0) for l in losses), 1)
        return None

    out: list[dict[str, Any]] = []
    for spec in METRICS:
        value = val(spec["id"])
        if value is None:
            continue
        out.append({
            "id": spec["id"],
            "label": spec["label"],
            "unit": spec["unit"],
            "dir": spec["dir"],
            "target": spec["target"],
            "value": value,
            "baseline": None,
            "delta": None,
            "note": spec["note"],
        })
    return out


def attach_baseline(metrics: list[dict[str, Any]], base: list[dict[str, Any]] | None) -> None:
    """Δ against the previous equal-length window. No baseline -> leave None, never guess."""
    if not base:
        return
    by_id = {str(m.get("id")): m for m in base}
    for m in metrics:
        b = by_id.get(str(m.get("id")))
        if b is None or b.get("value") is None or m.get("value") is None:
            continue
        try:
            prev = float(b["value"])
            now = float(m["value"])
        except (TypeError, ValueError):
            continue
        m["baseline"] = b["value"]
        m["delta"] = round(now - prev, 4)


def build_losses(
    *,
    turns: list[dict[str, Any]],
    refs: dict[str, Any],
    fail_n: int,
    sec_fail: float,
    sec_retry: float,
    retry_n: int,
    wait_s: float,
    sec_locate: float,
    locate_n: int,
    sec_reread: float,
    reread_n: int,
    reread_detail: list[dict[str, Any]],
    cache_write_tokens: int,
    cache_write_n: int,
    unit_usd: float,
    cost_usd: float,
    idle_s: float,
    skill_resend_tokens: int,
    total_wall: float,
) -> list[dict[str, Any]]:
    """L1: five kinds of loss, each attributable to turns/events with s or usd.

    Seconds are exclusive (a call is charged once, by priority fail > retry >
    reread > locate), so the ledger adds up instead of double counting.
    Everything outside this list is a ledger row, not a loss.
    """
    losses: list[dict[str, Any]] = []

    def add(lid: str, label: str, s: float, usd: float, kind: str, refs_in: list[Any], how: str) -> None:
        s = round(float(s or 0), 1)
        usd = round(float(usd or 0), 4)
        if s < 5 and usd < 0.01:
            return
        losses.append({
            "id": lid,
            "label": label,
            "s": s,
            "usd": usd,
            "kind": kind,
            "how": how,
            "refs": list(refs_in)[:8],
        })

    fail_usd = 0.0
    for t in turns:
        fails = int(t.get("fails") or 0)
        if fails and float(t.get("cost_usd") or 0):
            fail_usd += float(t["cost_usd"]) * (fails / max(1, int(t.get("tools") or 1)))
    add(
        "fail_retry", "失败与重试",
        sec_fail + sec_retry, fail_usd, "measured", refs.get("fail") or [],
        f"失败 {fail_n} 次（{round(sec_fail, 1)}s）+ 同回合重试 {retry_n} 次（{round(sec_retry, 1)}s）；$ 按回合内失败工具占比分摊",
    )

    add(
        "reread", "重复读（上下文重建）", sec_reread, 0.0, "measured",
        [r for r in (refs.get("read") or []) if r.get("path") in {d["path"] for d in reread_detail[:5]}][:8],
        f"同一窗口内多余读取 {reread_n} 次（第 2 次起计，已扣除计入失败/定位的调用）",
    )
    if reread_detail:
        losses[-1]["detail"] = reread_detail[:6]

    add("wait_poll", "空等轮询", wait_s, 0.0, "measured", refs.get("wait") or [],
        "CheckCommandStatus 类轮询墙钟；等待不产出")

    cache_usd = float(cache_write_tokens or 0) * float(unit_usd or 0)
    add(
        "cache_write", "前缀重填（缓存被改写）", 0.0, cache_usd, "estimated", [],
        f"{cache_write_n} 个回合 cacheWrite>0，共 {int(cache_write_tokens or 0):,} tokens 重新预填（按本窗混合单价 ${round(unit_usd or 0, 8)}/tok 估算）",
    )

    rework = [t for t in turns if t.get("nudge") or t.get("correction") or t.get("push")]
    rework_s = sum(float(t.get("wall_s") or 0) for t in rework)
    rework_usd = sum(float(t.get("cost_usd") or 0) for t in rework)
    kinds = []
    if any(t.get("correction") for t in rework):
        kinds.append("纠正")
    if any(t.get("nudge") for t in rework):
        kinds.append("短催")
    if any(t.get("push") for t in rework):
        kinds.append("催促")
    add(
        "rework", "返工往返", rework_s, rework_usd, "measured",
        [{"turn": t.get("index"), "ts": t.get("ts"), "event_id": t.get("event_id"), "label": first_line(t.get("prompt"), 90)}
         for t in rework][:8],
        f"{len(rework)} 个回合由{'/'.join(kinds) or '流程摩擦'}触发，整个回合视为损耗",
    )

    add("locate", "缺定位线索导致的搜索", sec_locate, 0.0, "measured", refs.get("locate") or [],
        f"{locate_n} 次 search 族调用落在没有路径/仓库线索的回合上")

    add("idle", "长时间空档", idle_s, 0.0, "measured", [],
        "相邻事件间隔 >600s（>10 分钟无任何事件）的时间累计")

    skill_usd = float(skill_resend_tokens or 0) * float(unit_usd or 0)
    add(
        "skill_bloat", "上下文重复传输（skill 正文）", 0.0, skill_usd, "estimated", [],
        f"skill 正文 {int(skill_resend_tokens or 0):,} tokens 在后续回合被重复传输（按混合单价估算）",
    )

    for l in losses:
        l["s_share"] = round(100 * float(l["s"]) / total_wall, 1) if total_wall else 0.0
        l["usd_share"] = round(100 * float(l["usd"]) / cost_usd, 1) if cost_usd else 0.0
    losses.sort(key=lambda l: (-float(l["usd"]), -float(l["s"])))
    return losses


_LOSS_FINDING: dict[str, dict[str, str]] = {
    "fail_retry": {
        "title": "失败与重试在烧时间",
        "cause": "命令/工具以非 0 退出，或同族失败后原样重试；错误没有转成新策略。",
        "action": "失败先读 stderr/输出；同一命令族连续失败 2 次必须换方案，禁止原样重跑。",
        "gate": "- 同一命令族失败 2 次必须停下读错误、换方案；禁止原样重试。",
        "metric": "fail_n",
    },
    "reread": {
        "title": "重复读：上下文在反复重建",
        "cause": "同一文件在窗口内被多次读取，说明每次都要重新建立上下文，而不是拿到接口/行号。",
        "action": "任务里直接点名文件与函数/行号；Agent 读一次就把关键接口写进结论，不要跨回合全量重读。",
        "gate": "- 同一文件不要跨回合反复全量读；只读相关函数，读到的接口写进结论。",
        "metric": "reread_ratio",
    },
    "wait_poll": {
        "title": "空等轮询占了墙钟",
        "cause": "CheckCommandStatus 一类轮询没有产出，只是等结果。",
        "action": "长任务先给阶段结论再继续；轮询合并成一次检查，不要一步一等。",
        "gate": "- 长任务不要一步一停：完成子目标先给结论+下一步，再等确认。",
        "metric": "wait_s",
    },
    "cache_write": {
        "title": "前缀被改写导致缓存重填",
        "cause": "会话进行中 system/AGENTS/skill 前缀变了，cacheWrite>0，下一回合整段重新预填。",
        "action": "同一会话内冻结前缀；规则/skill 的改动放到下一会话。",
        "gate": "- 会话进行中不改前缀（AGENTS / skill / system）；改动留到下一会话。",
        "metric": "cache_write_n",
    },
    "rework": {
        "title": "返工往返：整个回合是流程损耗",
        "cause": "用户用短催/纠正/催促推动，说明上一回合没有自驱到阶段结论，或方向没对齐。",
        "action": "首条 prompt 给全 cwd/仓库/目标/验收；每完成子目标先给结论+下一步再停。",
        "gate": "- 长任务自驱到阶段结论再停，不要一步一等。",
        "metric": "extra_trips",
    },
    "locate": {
        "title": "缺定位线索，先花时间找",
        "cause": "prompt 没给路径/仓库/文件，Agent 只能先用搜索族命令定位。",
        "action": "prompt 里点名文件或符号；Agent 先定位文件再读，禁止用全库 rg 代替阅读。",
        "gate": "- 首条 prompt 给 cwd + 仓库根 + 目标文件；禁止用全库 rg/grep 代替阅读。",
        "metric": "locate_s",
    },
    "idle": {
        "title": "长时间空档",
        "cause": "相邻事件间隔超过 10 分钟，中间没有可见进展（模型生成中不算）。",
        "action": "长任务每 10 分钟或每个子目标给一次进展与结论。",
        "gate": "- 长任务每 10 分钟或每个子目标给一次进展。",
        "metric": "idle_s",
    },
    "skill_bloat": {
        "title": "skill 正文重复进上下文",
        "cause": "整篇 SKILL.md 进 history，之后每回合重发。",
        "action": "skill 只取命中段；加载前先确认该 skill 与当前任务相关。",
        "gate": "- skill 只取命中段；SKILL.md 正文不整篇反复灌注。",
        "metric": "skill_tokens",
    },
}


def _sev_for(loss: dict[str, Any], cost_usd: float) -> str:
    usd = float(loss.get("usd") or 0)
    s = float(loss.get("s") or 0)
    share = max(float(loss.get("usd_share") or 0) if usd else 0.0, float(loss.get("s_share") or 0) if s else 0.0)
    if (usd and usd >= 0.5) or s >= 600 or share >= 35:
        return "high"
    if (usd and usd >= 0.15) or s >= 120 or share >= 12:
        return "med"
    return "note"


def _insights(
    *,
    losses: list[dict[str, Any]],
    metrics: list[dict[str, Any]],
    summary: dict[str, Any],
    turns: list[dict[str, Any]],
    flow: dict[str, Any],
    plane: dict[str, Any] | None = None,
) -> list[dict[str, Any]]:
    """L2: findings built only from the loss account + the metrics plane.

    Every finding must carry impact, action and a re-measurable metric; a loss
    without those would be demoted, so no keyword heuristic is allowed in.
    """
    plane = plane or {}
    out: list[dict[str, Any]] = []
    m_by_id = {str(m["id"]): m for m in metrics}
    cost_usd = float(summary.get("cost_usd") or 0)

    def add(
        fid: str,
        axis: str,
        title: str,
        claim: str,
        cause: str,
        action: str,
        gate: str,
        metric_id: str,
        impact_s: float,
        impact_usd: float,
        kind: str,
        refs: list[Any],
        evidence: str,
        sev: str,
        confidence: float,
    ) -> None:
        metric = m_by_id.get(metric_id)
        if sev == "high" and (not action or not metric):
            sev = "med"
        out.append({
            "id": fid,
            "axis": axis,
            "audience": "agent",
            "use": "agents.md",
            "title": title,
            "text": claim,
            "cause": cause,
            "action": action,
            "gate": gate,
            "draft": gate,
            "evidence": evidence,
            "sev": sev,
            "impact": {"s": round(impact_s, 1), "usd": round(impact_usd, 4), "kind": kind},
            "metric": ({"id": metric["id"], "now": metric["value"], "target": metric["target"], "unit": metric["unit"], "dir": metric["dir"]} if metric else None),
            "refs": refs[:8],
            "confidence": confidence,
        })

    for loss in losses:
        spec = _LOSS_FINDING.get(str(loss.get("id")))
        if not spec:
            continue
        sev = _sev_for(loss, cost_usd)
        detail = loss.get("detail") or []
        top = ""
        if detail:
            top = " · top: " + "、".join(f"{d['path']}×{d['reads']}" for d in detail[:3])
        shares = []
        if loss.get("s_share"):
            shares.append(f"s 占比 {loss['s_share']}%")
        if loss.get("usd_share"):
            shares.append(f"$ 占比 {loss['usd_share']}%")
        shares_txt = (" · " + " · ".join(shares)) if shares else ""
        evidence = f"{loss['label']} {loss['s']}s / ${loss['usd']}（{loss['kind']}{shares_txt}）{top}"
        add(
            str(loss["id"]), "agent", spec["title"],
            f"{loss['how']}。影响 {loss['s']}s" + (f" / ${loss['usd']}" if loss.get("usd") else "") + "。",
            spec["cause"], spec["action"], spec["gate"], spec["metric"],
            float(loss.get("s") or 0), float(loss.get("usd") or 0), str(loss.get("kind") or "measured"),
            loss.get("refs") or [], evidence, sev,
            0.9 if loss.get("kind") == "measured" else 0.6,
        )

    hit = summary.get("cache_hit_pct")
    usage_turns = int(summary.get("usage_turns") or 0)
    if hit is not None and usage_turns >= 20 and float(hit) < 80:
        cold = int(plane.get("cold_turns") or 0)
        add(
            "cache_miss", "agent", "缓存命中率偏低",
            f"缓存命中 {hit}%（{usage_turns} 个计费回合），{cold} 个回合完全未命中：前缀一改，整段 cache 失效。",
            "system / AGENTS / skill 前缀在会话中变化，或前缀结构不稳定。",
            "冻结会话内前缀；把大段规则前置并且保持字节稳定。",
            "- 会话进行中不改前缀（AGENTS / skill / system）；改动留到下一会话。",
            "cache_hit_pct", 0.0, 0.0, "measured", [],
            f"cache_hit={hit}% cold_turns={cold}/{usage_turns}",
            "high" if float(hit) < 60 else "med", 0.8,
        )

    if not out:
        if int(summary.get("n_tools") or 0) >= 20:
            add(
                "stable", "agent", "执行稳定",
                f"{summary.get('n_tools')} 次工具、失败 {summary.get('fail_n')} 次；损耗账本在阈值以下。",
                "没有可归因的损耗事件。",
                "保持当前前缀稳定性与定位方式。",
                "",
                "fail_n", 0.0, 0.0, "measured", [],
                f"tools={summary.get('n_tools')} fail={summary.get('fail_n')} waste={summary.get('health', {}).get('waste_pct')}%",
                "good", 0.8,
            )
        else:
            add(
                "sparse", "user", "样本不足",
                "事件太少，还不构成可归因的损耗账本。",
                f"窗口内只有 {summary.get('n_rows', 0)} 行事件。",
                "多跑几个完整回合再看分析。",
                "", "turns", 0.0, 0.0, "measured", [], f"n_rows={summary.get('n_rows', 0)}", "note", 1.0,
            )

    order = {"high": 0, "med": 1, "note": 2, "good": 3}
    out.sort(key=lambda f: (order.get(str(f.get("sev")), 2), -float(f.get("impact", {}).get("usd") or 0), -float(f.get("impact", {}).get("s") or 0)))
    return out


def _fmt_s(v: Any) -> str:
    n = float(v or 0)
    return f"{n / 3600:.1f}h" if n >= 3600 else f"{round(n, 1)}s"


def _agent_findings(findings: list[dict[str, Any]]) -> list[dict[str, Any]]:
    keep = ("id", "sev", "axis", "title", "text", "cause", "action", "gate", "impact", "metric", "refs", "confidence", "ack")
    return [{k: f.get(k) for k in keep if f.get(k) is not None} for f in findings]


def agent_brief(result: dict[str, Any]) -> str:
    """Markdown the Agent can read directly: conclusion -> impact -> action -> re-measure."""
    win = result.get("window") or {}
    lines = [
        f"# 会话分析 · {result.get('scope')}" + (f" · {result.get('session_id')}" if result.get("session_id") else ""),
        "",
        f"窗口 {win.get('from') or '?'} → {win.get('to') or '?'} · {win.get('turns', 0)} 回合 · {win.get('tools', 0)} 工具"
        + ("  ⚠ 12000 行截断" if win.get("truncated") else ""),
        "",
        "## 指标（Δ = 对基线）",
    ]
    for m in result.get("metrics") or []:
        d = m.get("delta")
        delta = "" if d is None else f"  Δ{d:+g} vs {m.get('baseline')}"
        tgt = f" → 目标 {m['target']}{m['unit']}" if m.get("target") is not None else ""
        lines.append(f"- {m['label']} ({m['id']}): {m['value']}{m['unit']}{tgt}{delta}")
    lines += ["", "## 损耗（按 $ / 秒）"]
    for l in result.get("losses") or []:
        usd = f" / ${l['usd']}" if l.get("usd") else ""
        lines.append(f"- {l['label']}: {l['s']}s{usd}（{l['kind']}）{l.get('how') or ''}")
    lines += ["", "## 结论与动作"]
    for f in result.get("findings") or []:
        imp = f.get("impact") or {}
        usd = f" / ${imp['usd']}" if imp.get("usd") else ""
        mt = f.get("metric")
        mtxt = f"  复测 {mt['id']}={mt['now']}→{mt['target']}{mt['unit']}" if mt and mt.get("target") is not None else (f"  复测 {mt['id']}={mt['now']}{mt['unit']}" if mt else "")
        lines.append(f"### [{f.get('sev')}] {f.get('title')}  ({imp.get('s')}s{usd}, {imp.get('kind')})")
        lines.append(f"- 依据: {f.get('text')}")
        if f.get("cause"):
            lines.append(f"- 原因: {f['cause']}")
        if f.get("action"):
            lines.append(f"- 动作: {f['action']}")
        if f.get("gate"):
            lines.append(f"- 闸门: {f['gate']}")
        if mtxt:
            lines.append(mtxt)
    verify = result.get("verify") or {}
    lines += ["", "## 复测", f"- {verify.get('rerun') or ''}", f"- 期望: {verify.get('expect') or ''}"]
    loop = result.get("loop") or {}
    acked = [f for f in (result.get("findings") or []) if f.get("ack")]
    if acked:
        lines += [
            "",
            f"## 闭环核对（已声明 {loop.get('total', 0)} 条 · 闭环 {len(loop.get('closed') or [])} · 未改善 {len(loop.get('open') or [])}）",
        ]
        for f in acked:
            a = f["ack"]
            mt = f.get("metric") or {}
            state = "闭环" if a.get("closed") is True else ("未改善" if a.get("closed") is False else "无目标")
            lines.append(
                f"- [{a.get('status')}] {f.get('title')}: {mt.get('id') or '-'} "
                f"{a.get('at_now')} -> {a.get('now')}（目标 {mt.get('target')}）=> {state}"
                + (f" · 备注: {a.get('note')}" if a.get("note") else "")
            )
    return "\n".join(lines)


def agent_view(result: dict[str, Any], base_metrics: list[dict[str, Any]] | None = None) -> dict[str, Any]:
    """Machine contract for analysis-based optimization."""
    metrics = [dict(m) for m in (result.get("metrics") or [])]
    attach_baseline(metrics, base_metrics)
    view = {
        "view": "agent",
        "ok": bool(result.get("ok")),
        "scope": result.get("scope"),
        "session_id": result.get("session_id") or "",
        "window": result.get("window"),
        "metrics": metrics,
        "losses": result.get("losses") or [],
        "findings": _agent_findings(result.get("findings") or []),
        "turns": result.get("turns") or [],
        "series": result.get("series") or {},
        "loop": result.get("loop"),
        "stable": [f.get("title") for f in (result.get("findings") or []) if f.get("sev") == "good"],
        "verify": {
            "metric_ids": [m["id"] for m in metrics if m.get("target") is not None],
            "rerun": result.get("rerun") or "",
            "expect": "同一窗口重跑，metric.value 向 target 移动；findings 里同一 id 不再出现或 sev 降低",
        },
    }
    view["brief"] = agent_brief({**result, "metrics": metrics, "verify": view["verify"]})
    return view


def _ts_str(epoch: float) -> str:
    from datetime import datetime
    return datetime.fromtimestamp(epoch).strftime("%Y-%m-%d %H:%M:%S.%f")


ACKS_SQL = """
SELECT finding_id, CAST(ts AS VARCHAR) AS ts, status, note, metric_id, metric_now, target
FROM analysis_acks
WHERE scope = ? AND session_id = ?
ORDER BY ts DESC
"""


def fetch_acks(query_fn, *, session_id: str | None, scope: str) -> dict[str, dict[str, Any]]:
    """Latest ack per finding for exactly this window. Missing table -> empty dict."""
    try:
        rows = query_fn(ACKS_SQL, [scope, session_id or ""])
    except Exception:  # noqa: BLE001 - store may predate the ack table
        return {}
    out: dict[str, dict[str, Any]] = {}
    for r in rows:
        fid = str(r.get("finding_id") or "")
        if not fid or fid in out:
            continue
        out[fid] = {
            "status": str(r.get("status") or "applied"),
            "ts": str(r.get("ts") or ""),
            "note": str(r.get("note") or ""),
            "metric_id": str(r.get("metric_id") or ""),
            "at_now": r.get("metric_now"),
            "target": r.get("target"),
        }
    return out


def _reached(value: Any, target: Any, direction: str | None) -> bool | None:
    """Is the metric at/through its target? Unknown target -> None, never a guess."""
    if value is None or target is None:
        return None
    try:
        v, t = float(value), float(target)
    except (TypeError, ValueError):
        return None
    if direction == "up":
        return v >= t
    if direction == "down":
        return v <= t
    return None


def attach_acks(result: dict[str, Any], acks: dict[str, dict[str, Any]]) -> None:
    """L3: does the claim hold? Each acked finding gets its before/after and state."""
    applied: list[str] = []
    dismissed: list[str] = []
    closed: list[str] = []
    still_open: list[str] = []
    untracked: list[str] = []
    for f in result.get("findings") or []:
        ack = acks.get(str(f.get("id")))
        if not ack:
            continue
        metric = f.get("metric") or {}
        now = metric.get("now")
        ack = dict(ack)
        ack["now"] = now
        ack["moved"] = (
            None if (ack.get("at_now") is None or now is None)
            else round(float(now) - float(ack["at_now"]), 4)
        )
        ack["closed"] = _reached(now, metric.get("target"), metric.get("dir"))
        f["ack"] = ack
        fid = str(f.get("id"))
        if ack["status"] == "dismissed":
            dismissed.append(fid)
            continue
        applied.append(fid)
        if ack["closed"] is True:
            closed.append(fid)
        elif ack["closed"] is False:
            still_open.append(fid)
        else:
            untracked.append(fid)
    if not (applied or dismissed):
        return
    result["loop"] = {
        "applied": applied,
        "dismissed": dismissed,
        "closed": closed,
        "open": still_open,
        "untracked": untracked,
        "total": len(applied) + len(dismissed),
    }


def fetch_rows(
    query_fn,
    *,
    session_id: str | None,
    scope: str,
    since: str | None = None,
    until: str | None = None,
) -> list[dict[str, Any]]:
    sql = FETCH_SQL
    params: list[Any] = []
    if since is not None:
        sql += " AND ts >= CAST(? AS TIMESTAMP)"
        params.append(since)
    if until is not None:
        sql += " AND ts < CAST(? AS TIMESTAMP)"
        params.append(until)
    if since is None and until is None:
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


def fetch_metrics(
    query_fn,
    *,
    session_id: str | None,
    scope: str,
    since: str | None = None,
    until: str | None = None,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """Metrics plane rows for the same scope. Missing tables -> empty, never raises."""
    def _one(sql: str) -> list[dict[str, Any]]:
        q = sql
        params: list[Any] = []
        if since is not None:
            q += " AND ts >= CAST(? AS TIMESTAMP)"
            params.append(since)
        if until is not None:
            q += " AND ts < CAST(? AS TIMESTAMP)"
            params.append(until)
        if since is None and until is None:
            if scope == "session" and session_id:
                q += " AND session_id = ?"
                params.append(session_id)
            elif scope == "recent":
                q += " AND ts >= (current_timestamp - INTERVAL 7 DAY)"
            else:
                q += " AND session_id = ?"
                params.append(session_id or "")
        q += " ORDER BY ts ASC LIMIT 20000"
        try:
            return query_fn(q, params)
        except Exception:  # noqa: BLE001 - store may predate the metrics plane
            return []

    return _one(USAGE_SQL), _one(CTX_SQL)


def fetch_baseline(query_fn, *, session_id: str | None, scope: str, rows: list[dict[str, Any]]):
    """Previous equal-length window: previous session, or the 7 days before this one.

    Returns (rows, usage, ctx, label). Empty when there is no earlier window: the
    UI must then show no delta instead of inventing a baseline.
    """
    ts = [t for t in (parse_ts(r.get("ts")) for r in rows) if t]
    if not ts:
        return [], [], [], ""
    start, end = min(ts), max(ts)
    span = max(60.0, end - start)
    if scope == "session" and session_id:
        got = query_fn(
            "SELECT session_id FROM hook_events WHERE ts < CAST(? AS TIMESTAMP) AND session_id != ? "
            "GROUP BY session_id ORDER BY max(ts) DESC LIMIT 1",
            [_ts_str(start), session_id],
        )
        prev = str((got[0] if got else {}).get("session_id") or "")
        if not prev:
            return [], [], [], ""
        usage, ctx = fetch_metrics(query_fn, session_id=prev, scope="session")
        return fetch_rows(query_fn, session_id=prev, scope="session"), usage, ctx, f"上一个会话 {prev[:8]}"
    since, until = _ts_str(start - span), _ts_str(start)
    usage, ctx = fetch_metrics(query_fn, session_id=None, scope=scope, since=since, until=until)
    return (
        fetch_rows(query_fn, session_id=None, scope=scope, since=since, until=until),
        usage,
        ctx,
        f"前 {round(span / 3600, 1)} 小时",
    )


def mine(
    query_fn,
    *,
    session_id: str | None = None,
    scope: str = "session",
    dirs: list[str] | None = None,
    baseline: bool = False,
    fmt: str = "full",
    host: str = "http://127.0.0.1:9488",
) -> dict[str, Any]:
    """Full analysis result, or the machine contract when fmt == "agent"."""
    if scope not in ("session", "recent"):
        scope = "session"
    rows = fetch_rows(query_fn, session_id=session_id, scope=scope)
    usage_rows, ctx_rows = fetch_metrics(query_fn, session_id=session_id, scope=scope)
    result = mine_rows(
        rows,
        dirs=dirs,
        session_id=session_id,
        scope=scope,
        usage_rows=usage_rows,
        ctx_rows=ctx_rows,
    )
    attach_acks(result, fetch_acks(query_fn, session_id=session_id, scope=scope))
    query = [f"--scope {scope}"]
    if session_id and scope == "session":
        query.append(f"--session-id {session_id}")
    if dirs:
        query.append(f"--dirs {','.join(dirs)}")
    result["host"] = host
    result["rerun"] = "python3 trae_hooks/mine.py --agent " + " ".join(query)

    base_metrics: list[dict[str, Any]] | None = None
    if baseline:
        b_rows, b_usage, b_ctx, label = fetch_baseline(query_fn, session_id=session_id, scope=scope, rows=rows)
        if b_rows:
            base = mine_rows(
                b_rows,
                dirs=dirs,
                session_id=session_id,
                scope=scope,
                usage_rows=b_usage,
                ctx_rows=b_ctx,
            )
            base_metrics = base.get("metrics") or []
            attach_baseline(result["metrics"], base_metrics)
            result["baseline"] = {
                "source": label,
                "window": base.get("window"),
                "metrics": base_metrics,
                "losses": base.get("losses") or [],
            }
        else:
            result["baseline"] = None

    if fmt == "agent":
        return agent_view(result, base_metrics)
    return result


def ack_finding(
    execute_fn,
    *,
    scope: str,
    session_id: str | None,
    finding_id: str,
    status: str,
    note: str = "",
    metric: dict[str, Any] | None = None,
    instance_id: str = "",
) -> dict[str, Any]:
    """Record that a finding was applied/dismissed. Latest status per window wins."""
    from row import utc_now

    if scope not in ("session", "recent"):
        scope = "session"
    status = "dismissed" if str(status) == "dismissed" else "applied"
    fid = str(finding_id or "").strip()
    if not fid:
        return {"ok": False, "error": "finding_id required"}
    sid = session_id or ""
    metric = metric or {}
    ack_id = f"{scope}:{sid or '-'}:{fid}"
    execute_fn(
        "INSERT INTO analysis_acks (ack_id, ts, instance_id, scope, session_id, finding_id, status, note, "
        "metric_id, metric_now, target) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) "
        "ON CONFLICT (ack_id) DO UPDATE SET ts = excluded.ts, status = excluded.status, "
        "note = excluded.note, metric_id = excluded.metric_id, metric_now = excluded.metric_now, "
        "target = excluded.target, instance_id = excluded.instance_id",
        [
            ack_id,
            utc_now(),
            instance_id or os.environ.get("CLIPVAULT_INSTANCE_ID", ""),
            scope,
            sid,
            fid,
            status,
            str(note or "")[:500],
            str(metric.get("id") or ""),
            metric.get("now"),
            metric.get("target"),
        ],
    )
    return {"ok": True, "ack_id": ack_id, "finding_id": fid, "status": status}


def _cli(argv: list[str] | None = None) -> int:
    import argparse
    import urllib.request
    from urllib.parse import urlencode

    ap = argparse.ArgumentParser(description="ClipVault session analysis (read-only HTTP client).")
    ap.add_argument("--agent", action="store_true", help="machine contract + markdown brief")
    ap.add_argument("--scope", default="session", choices=("session", "recent"))
    ap.add_argument("--session-id", default="")
    ap.add_argument("--dirs", default="")
    ap.add_argument("--host", default="http://127.0.0.1:9488")
    ap.add_argument("--json", action="store_true", help="print raw JSON instead of the brief")
    ap.add_argument("--no-baseline", action="store_true", help="skip the previous-window comparison")
    a = ap.parse_args(argv)

    q = {"scope": a.scope, "format": "agent" if a.agent else "full"}
    if a.session_id:
        q["session_id"] = a.session_id
    if a.dirs:
        q["dirs"] = a.dirs
    if not a.no_baseline:
        q["baseline"] = "1"
    url = a.host.rstrip("/") + "/api/mine?" + urlencode(q)
    try:
        with urllib.request.urlopen(url, timeout=60) as resp:  # noqa: S310 - localhost only
            data = json.loads(resp.read().decode("utf-8"))
    except Exception as exc:  # noqa: BLE001
        print(f"analysis unavailable: {exc}", file=sys.stderr)
        return 2
    if a.agent and not a.json:
        print(data.get("brief") or json.dumps(data, ensure_ascii=False, indent=2))
    else:
        print(json.dumps(data, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(_cli())
