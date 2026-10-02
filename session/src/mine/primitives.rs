//! Layer 1: parsing, classification and path identity.
//!
//! Pure functions, no I/O. Every rule that decides "is this the same file",
//! "which command family", "is the user reminding me" is here so the higher
//! layers stay declarative.

use std::collections::HashSet;
use std::sync::LazyLock;

use regex::Regex;
use serde_json::Value;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Direction {
    pub id: &'static str,
    pub axis: &'static str,
    pub title: &'static str,
}

pub const DIRECTIONS: &[Direction] = &[
    Direction { id: "user.cwd", axis: "user", title: "工作目录" },
    Direction { id: "user.git", axis: "user", title: "Git 库" },
    Direction { id: "user.taste", axis: "user", title: "Taste / 规范" },
    Direction { id: "user.prompt", axis: "user", title: "任务描述" },
    Direction { id: "user.reminders", axis: "user", title: "用户提醒" },
    Direction { id: "user.flow", axis: "user", title: "操作流程" },
    Direction { id: "agent.files", axis: "agent", title: "读写文件" },
    Direction { id: "agent.tools", axis: "agent", title: "工具调用" },
    Direction { id: "agent.failures", axis: "agent", title: "失败/重试" },
    Direction { id: "agent.hot", axis: "agent", title: "热点/冗余" },
    Direction { id: "agent.mcp", axis: "agent", title: "MCP" },
    Direction { id: "agent.phases", axis: "agent", title: "任务阶段" },
    Direction { id: "agent.metrics", axis: "agent", title: "成本/缓存/上下文" },
];

/// Tool names that mutate files. A `file_path` is a write only when one of these
/// fired; `RunCommand` paths are reads. This separates "read 43 times" from
/// "wrote 0".
pub const WRITE_TOOLS: &[&str] = &[
    "Write",
    "Edit",
    "MultiEdit",
    "NotebookEdit",
    "str_replace",
    "apply_patch",
    "create_file",
    "write_file",
    "edit_file",
];

/// Phases, in check order (first match wins).
const PHASES: &[(&str, &str)] = &[
    ("review", r"review|评审|code review|\bmr\b|pull request"),
    ("taste", r"AGENTS\.md|design-taste|taste|风格|规范|nmem"),
    ("debug", r"为什么|怎么会|不对|失败|bug|报错"),
    ("ship", r"提交|push|合并|发 mr|开 mr"),
    ("implement", r"改|修|实现|加上|补|落地"),
];

static RE_PROMPT_REPO: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"repo|仓库|分支|branch|git\b|/repos?/|[A-Za-z0-9_.-]+@[A-Za-z0-9_./-]+").unwrap()
});
static RE_FILE_PATH: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r#""file_path"\s*:\s*"((?:\\.|[^"\\])*)""#).unwrap());
static RE_WORKDIR: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r#""(?:workdir|cwd)"\s*:\s*"((?:\\.|[^"\\])*)""#).unwrap());
static RE_CMD: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r#""(?:cmd|command)"\s*:\s*"((?:\\.|[^"\\]){1,500})""#).unwrap()
});
static RE_WALL: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r#""wall_time_seconds"\s*:\s*([0-9]+(?:\.[0-9]+)?)"#).unwrap());
static RE_EXIT: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r#""exit_code"\s*:\s*(-?[0-9]+)"#).unwrap());
static RE_REPO_AT: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"/repos/([^/@]+)(?:@|--)([^/]+)").unwrap());
static RE_TASTE_FILE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)(AGENTS\.md|design-taste\.md|SKILL\.md|nmem-knowledge-format\.md)").unwrap()
});
static RE_PROJECT_DOC: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)(?:^|/)([\w.-]+)/(AGENTS\.md|design-taste\.md|nmem-knowledge-format\.md)\b")
        .unwrap()
});
static RE_PATH_TOKEN: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r#"(?:^|[\s"'=])(/[^\s:"']+\.[A-Za-z0-9]{1,8}|[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+\.[A-Za-z0-9]{1,8})"#,
    )
    .unwrap()
});
static RE_SHELL_PROLOGUE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)^(?:set|export|source|shopt)\b|^[{}]$").unwrap()
});
static RE_CONTINUE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)^(?:继续|接着|往下|go on|next|ok|好)[。.!！~ ]*$").unwrap()
});
static RE_STRUCTURED: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?m)^\s*[-*•]|\b1\.[^0-9]").unwrap());
static RE_TURN_MENTION: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)\btaste\b|风格|规范").unwrap());

const TASTE_SKIP_PARENT: &[&str] = &[".tmp", "tmp", "refs", "references", "node_modules"];

static PHASE_RES: LazyLock<Vec<(&'static str, Regex)>> =
    LazyLock::new(|| PHASES.iter().map(|(n, p)| (*n, Regex::new(p).unwrap())).collect());
static FAMILY_RES: LazyLock<Vec<(&'static str, Regex)>> = LazyLock::new(|| {
    vec![
        ("git", Regex::new(r"\bgit\b").unwrap()),
        ("search", Regex::new(r"\b(rg|grep|ag|ack)\b").unwrap()),
        ("read", Regex::new(r"\b(cat|head|tail|less|bat|sed -n)\b").unwrap()),
        ("test", Regex::new(r"\b(pytest|ctest|cargo test|go test|googletest)\b").unwrap()),
        ("build", Regex::new(r"\b(ninja|make\b|blade|bazel|cmake|cargo build)\b").unwrap()),
        ("remote", Regex::new(r"\b(ssh|scp|rsync)\b").unwrap()),
    ]
});
static RE_WS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s+").unwrap());
static RE_NUM: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\b[0-9]+\b").unwrap());
static RE_NUMERIC: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[0-9]+(?:\.[0-9]+)?$").unwrap());
static RE_PARENT_AT: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^([^/@\s]+)(?:@|--).+$").unwrap());
static RE_EXT: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\.[a-zA-Z0-9]{1,8}$").unwrap());
static RE_WORD: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[\w.-]+$").unwrap());
static RE_SKILLS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)/skills/([\w.-]+)/").unwrap());
static REMINDER_RES: LazyLock<Vec<(&'static str, Regex)>> = LazyLock::new(|| {
    vec![
        ("纠正", Regex::new(r"认知错误|搞错|不对|不正确|有误|不是.{0,8}而是|不符合预期|太浅|有问题").unwrap()),
        ("重申约束", Regex::new(r"注意|记得|必须|一定要|禁止|唯一|只能|不要|别|不需要|无需|不用|应该").unwrap()),
        ("催促", Regex::new(r"为什么|怎么还|多久|尽快|还没|没有结果|太慢|用了这么多时间|尚未").unwrap()),
        ("没看到", Regex::new(r"没看到|没有看到|都丢了|丢了|不见了|停了|挂了|崩了|没结果").unwrap()),
        ("加载上下文", Regex::new(r"(?i)从\s*nmem|加载|guideline|上下文|taste|规范|读取").unwrap()),
        ("重新执行", Regex::new(r"重新|再次|重跑|再测|再来|重试").unwrap()),
        ("推进", Regex::new(r"(?i)继续|接着|往下|go on|next").unwrap()),
    ]
});
static RE_NMEM_ACTION: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"写入|记录|整理|梳理|沉淀|结构化|落到|落盘|存(?:入|到)|更新到|补充到|写到").unwrap());

/// Parsed heads of `tool_input` / `tool_response`.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Head {
    pub file_path: Option<String>,
    pub cmd: Option<String>,
    pub workdir: Option<String>,
    pub wall_s: Option<f64>,
    pub exit_code: Option<i64>,
}

impl Head {
    /// Fill missing fields from `other`; `wall_s` / `exit_code` always override
    /// when present (they only appear in the response).
    pub fn merge(&mut self, other: &Head) {
        if self.file_path.is_none() {
            self.file_path = other.file_path.clone();
        }
        if self.cmd.is_none() {
            self.cmd = other.cmd.clone();
        }
        if self.workdir.is_none() {
            self.workdir = other.workdir.clone();
        }
        if other.wall_s.is_some() {
            self.wall_s = other.wall_s;
        }
        if other.exit_code.is_some() {
            self.exit_code = other.exit_code;
        }
    }
}

pub fn unescape(s: &str) -> String {
    s.replace("\\/", "/").replace("\\\"", "\"").replace("\\\\", "\\")
}

/// Absolute-ish key for a file path so relative and absolute spellings collapse.
pub fn norm_path(p: Option<&str>, base: Option<&str>) -> String {
    let s = unescape(p.unwrap_or(""));
    let s = s.trim();
    if s.is_empty() {
        return String::new();
    }
    if s.starts_with('/') {
        return s.to_string();
    }
    let b = base.unwrap_or("").trim_end_matches('/');
    if b.is_empty() {
        return s.to_string();
    }
    if s.starts_with(&format!("{b}/")) {
        return s.to_string();
    }
    format!("{b}/{s}")
}

pub fn parse_head(text: &str) -> Head {
    let raw = text;
    let mut out = Head::default();
    if raw.is_empty() {
        return out;
    }
    if let Ok(Value::Object(obj)) = serde_json::from_str::<Value>(raw) {
        if let Some(v) = obj.get("file_path").and_then(Value::as_str) {
            out.file_path = Some(v.to_string());
        }
        if let Some(v) = obj
            .get("cmd")
            .or_else(|| obj.get("command"))
            .and_then(Value::as_str)
        {
            out.cmd = Some(v.to_string());
        }
        if let Some(v) = obj
            .get("workdir")
            .or_else(|| obj.get("cwd"))
            .and_then(Value::as_str)
        {
            out.workdir = Some(v.to_string());
        }
        if out.file_path.is_none() {
            if let Some(v) = obj.get("path").and_then(Value::as_str) {
                out.file_path = Some(v.to_string());
            }
        }
        if let Some(v) = obj.get("wall_time_seconds").and_then(Value::as_f64) {
            out.wall_s = Some(v);
        }
        if let Some(v) = obj.get("exit_code").and_then(Value::as_i64) {
            out.exit_code = Some(v);
        }
        return out;
    }
    if let Some(c) = RE_FILE_PATH.captures(raw) {
        out.file_path = Some(unescape(&c[1]));
    }
    if let Some(c) = RE_WORKDIR.captures(raw) {
        out.workdir = Some(unescape(&c[1]));
    }
    if let Some(c) = RE_CMD.captures(raw) {
        out.cmd = Some(unescape(&c[1]));
    }
    if let Some(c) = RE_WALL.captures(raw) {
        out.wall_s = c[1].parse().ok();
    }
    if let Some(c) = RE_EXIT.captures(raw) {
        out.exit_code = c[1].parse().ok();
    }
    out
}

pub fn mcp_parts(name: &str) -> Option<(String, String)> {
    if let Some(rest) = name.strip_prefix("mcp__") {
        let bits: Vec<&str> = rest.splitn(2, "__").collect();
        if bits.len() == 2 {
            return Some((bits[0].to_string(), bits[1].to_string()));
        }
    }
    if let Some(rest) = name.strip_prefix("mcp_") {
        let bits: Vec<&str> = rest.splitn(2, '_').collect();
        if bits.len() == 2 {
            return Some((bits[0].to_string(), bits[1].to_string()));
        }
    }
    None
}

pub fn classify_phase(prompt: &str) -> &'static str {
    for (name, rx) in PHASE_RES.iter() {
        if rx.is_match(prompt) {
            return name;
        }
    }
    "other"
}

pub fn cmd_family(cmd: &str) -> &'static str {
    for (family, rx) in FAMILY_RES.iter() {
        if rx.is_match(cmd) {
            return family;
        }
    }
    "shell"
}

pub fn is_wait_tool(name: &str) -> bool {
    matches!(name, "CheckCommandStatus" | "StopCommand" | "WriteStdin")
}

pub fn is_write_tool(name: &str, llm_name: Option<&str>) -> bool {
    WRITE_TOOLS.contains(&name) || llm_name.map(|l| WRITE_TOOLS.contains(&l)).unwrap_or(false)
}

/// First meaningful line: skip `set -euo pipefail` / `export` prologues.
pub fn cmd_label(cmd: &str) -> String {
    for line in cmd.split('\n') {
        let s = line.trim();
        if s.is_empty() || RE_SHELL_PROLOGUE.is_match(s) {
            continue;
        }
        return s.chars().take(120).collect();
    }
    String::new()
}

/// Collapse whitespace and numeric args so `sed -n '1,240p' X` groups.
pub fn norm_cmd(cmd: &str) -> String {
    let label = cmd_label(cmd);
    let collapsed = RE_WS.replace_all(&label, " ");
    let collapsed = collapsed.trim();
    let numbered = RE_NUM.replace_all(collapsed, "N");
    numbered.chars().take(120).collect()
}

/// Epoch-ish floats (fixtures) or timestamp strings (live). Naive strings are
/// read as UTC: the wire contract is naive UTC (`docs/design-session-backends`).
pub fn parse_ts(value: &str) -> Option<f64> {
    let s = value.trim();
    if s.is_empty() {
        return None;
    }
    if RE_NUMERIC.is_match(s) {
        return s.parse::<f64>().ok();
    }
    let cleaned = s.replacen('Z', "+00:00", 1);
    let cleaned = if cleaned.contains(' ') {
        cleaned.replacen(' ', "T", 1)
    } else {
        cleaned
    };
    if let Ok(dt) = chrono::DateTime::parse_from_rfc3339(&cleaned) {
        return Some(dt.timestamp_micros() as f64 / 1_000_000.0);
    }
    for fmt in ["%Y-%m-%dT%H:%M:%S%.f", "%Y-%m-%d %H:%M:%S%.f"] {
        if let Ok(naive) = chrono::NaiveDateTime::parse_from_str(s, fmt) {
            let dt = naive.and_utc();
            return Some(dt.timestamp_micros() as f64 / 1_000_000.0);
        }
    }
    None
}

pub fn prompt_has_path(text: &str) -> bool {
    text.contains('/')
}

pub fn prompt_has_repo(text: &str) -> bool {
    RE_PROMPT_REPO.is_match(text)
}

/// Themes that signal the user is reminding / correcting / nudging. A theme that
/// repeats should become an AGENTS.md gate instead of a spoken reminder.
pub fn reminder_hits(text: &str) -> Vec<&'static str> {
    let low = text.to_lowercase();
    let mut hits = Vec::new();
    for (name, rx) in REMINDER_RES.iter() {
        if rx.is_match(text) {
            hits.push(*name);
        }
    }
    if (low.contains("nmem") || low.contains("memory")) && RE_NMEM_ACTION.is_match(text) {
        hits.push("沉淀提醒");
    }
    hits
}

/// Short, content-free push: "继续" / "继续吧" / "ok".
pub fn prompt_is_nudge(text: &str) -> bool {
    let t = text.trim();
    if t.is_empty() {
        return false;
    }
    if RE_CONTINUE.is_match(t) {
        return true;
    }
    t.chars().count() <= 8 && !prompt_has_path(t) && !prompt_has_repo(t)
}

pub fn git_from_path(path: &str) -> Option<(String, String)> {
    let p = path.replace('\\', "/");
    if p.is_empty() {
        return None;
    }
    if let Some(c) = RE_REPO_AT.captures(&p) {
        return Some((c[1].to_string(), c[2].to_string()));
    }
    if p.ends_with(".git") {
        let stem = p
            .trim_end_matches(".git")
            .rsplit('/')
            .next()
            .unwrap_or("")
            .to_string();
        return Some((stem, String::new()));
    }
    None
}

pub fn first_line(text: &str, n: usize) -> String {
    text.trim()
        .split('\n')
        .next()
        .unwrap_or("")
        .chars()
        .take(n)
        .collect()
}

pub fn project_name(parent: &str) -> String {
    let p = parent.trim();
    if let Some(c) = RE_PARENT_AT.captures(p) {
        return c[1].to_string();
    }
    p.to_string()
}

/// Identity for a spec file: skill name or project/AGENTS.md, never a bare
/// filename.
pub fn taste_keys(parts: &[&str]) -> Vec<String> {
    let mut bits: Vec<String> = Vec::new();
    for p in parts {
        let mut s = p.replace('\\', "/");
        s = s.trim().to_string();
        if s.is_empty() {
            continue;
        }
        if s.contains('/') && !s.ends_with('/') {
            s.push('/');
        }
        bits.push(s);
    }
    let blob = bits.join("\n");
    let mut keys: Vec<String> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    let add = |key: String, keys: &mut Vec<String>, seen: &mut HashSet<String>| {
        if !key.is_empty() && seen.insert(key.clone()) {
            keys.push(key);
        }
    };
    for c in RE_SKILLS.captures_iter(&blob) {
        add(format!("skill:{}", &c[1]), &mut keys, &mut seen);
    }
    for c in RE_PROJECT_DOC.captures_iter(&blob) {
        let parent = project_name(&c[1]);
        if parent.is_empty() || TASTE_SKIP_PARENT.contains(&parent.as_str()) {
            continue;
        }
        if RE_EXT.is_match(&parent) {
            continue;
        }
        add(format!("{parent}/{}", &c[2]), &mut keys, &mut seen);
    }
    if keys.is_empty() {
        let m = RE_TASTE_FILE.captures(&blob);
        let mut parent = String::new();
        for p in parts.iter().rev() {
            let raw = p.replace('\\', "/");
            let raw = raw.trim_end_matches('/');
            if !raw.contains('/') {
                continue;
            }
            let name = raw.rsplit('/').next().unwrap_or("");
            if !name.is_empty() && !name.ends_with(".md") && RE_WORD.is_match(name) {
                let cand = project_name(name);
                if TASTE_SKIP_PARENT.contains(&cand.as_str()) || RE_EXT.is_match(&cand) {
                    parent.clear();
                    continue;
                }
                parent = cand;
                break;
            }
        }
        if let (Some(c), true) = (m, !parent.is_empty()) {
            add(format!("{parent}/{}", &c[1]), &mut keys, &mut seen);
        }
    }
    keys
}

pub fn paths_from_cmd(cmd: &str) -> Vec<String> {
    let mut out = Vec::new();
    for c in RE_PATH_TOKEN.captures_iter(cmd) {
        let p = &c[1];
        if p.matches('/').count() < 1 || p.chars().count() > 220 {
            continue;
        }
        out.push(p.split(':').next().unwrap_or("").to_string());
        if out.len() >= 8 {
            break;
        }
    }
    out
}

/// True when the prompt looks like a list / numbered plan (structure signal).
pub fn prompt_is_structured(text: &str) -> bool {
    text.contains('\n') || RE_STRUCTURED.is_match(text)
}

pub fn prompt_mentions_taste(prompt: &str) -> bool {
    RE_TURN_MENTION.is_match(prompt)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn norm_path_collapses_relative_spellings() {
        assert_eq!(norm_path(Some("a/b.rs"), Some("/r")), "/r/a/b.rs");
        assert_eq!(norm_path(Some("/r/a/b.rs"), Some("/r")), "/r/a/b.rs");
        assert_eq!(norm_path(Some("  "), Some("/r")), "");
    }

    #[test]
    fn cmd_family_classifies() {
        assert_eq!(cmd_family("git status"), "git");
        assert_eq!(cmd_family("rg foo"), "search");
        assert_eq!(cmd_family("cat a.py"), "read");
        assert_eq!(cmd_family("cargo build"), "build");
        assert_eq!(cmd_family("echo hi"), "shell");
    }

    #[test]
    fn norm_cmd_collapses_numbers() {
        assert_eq!(norm_cmd("sed -n '1,240p' x"), "sed -n 'N,240p' x");
    }

    #[test]
    fn cmd_label_skips_prologue() {
        assert_eq!(cmd_label("set -euo pipefail\nexport A=1\nrg foo"), "rg foo");
    }

    #[test]
    fn parse_head_json_then_regex() {
        let h = parse_head(r#"{"file_path":"/a/b","wall_time_seconds":1.5,"exit_code":2}"#);
        assert_eq!(h.file_path.as_deref(), Some("/a/b"));
        assert_eq!(h.wall_s, Some(1.5));
        assert_eq!(h.exit_code, Some(2));
        let h = parse_head(r#"junk "cmd": "ls -la" junk"#);
        assert_eq!(h.cmd.as_deref(), Some("ls -la"));
    }

    #[test]
    fn mcp_parts_splits() {
        assert_eq!(mcp_parts("mcp__nowledge-mem__search"), Some(("nowledge-mem".into(), "search".into())));
        assert_eq!(mcp_parts("mcp_x_y"), Some(("x".into(), "y".into())));
        assert_eq!(mcp_parts("Bash"), None);
    }

    #[test]
    fn classify_phase_first_match_wins() {
        assert_eq!(classify_phase("review this MR"), "review");
        assert_eq!(classify_phase("为什么失败"), "debug");
        assert_eq!(classify_phase("改一下"), "implement");
        assert_eq!(classify_phase("hello"), "other");
    }

    #[test]
    fn reminder_hits_detects_themes() {
        let hits = reminder_hits("注意，必须禁止原样重跑，继续");
        assert!(hits.contains(&"重申约束"));
        assert!(hits.contains(&"重新执行"));
        assert!(hits.contains(&"推进"));
    }

    #[test]
    fn nudge_is_content_free_push() {
        assert!(prompt_is_nudge("继续"));
        assert!(prompt_is_nudge("ok"));
        assert!(!prompt_is_nudge("继续修 /a/b 的 bug"));
        assert!(!prompt_is_nudge("这是一段很长的说明文字超过八个字"));
    }

    #[test]
    fn taste_keys_identify_by_project_or_skill() {
        assert_eq!(taste_keys(&["/x/skills/goal/SKILL.md"]), vec!["skill:goal"]);
        assert_eq!(taste_keys(&["/p/foo/AGENTS.md"]), vec!["foo/AGENTS.md"]);
        assert_eq!(taste_keys(&["/legacy/proj/AGENTS.md"]), vec!["proj/AGENTS.md"]);
    }

    #[test]
    fn paths_from_cmd_extracts_paths() {
        let got = paths_from_cmd("rg foo src/main.rs --glob 'a/b*'");
        assert!(got.contains(&"src/main.rs".to_string()));
    }
}
