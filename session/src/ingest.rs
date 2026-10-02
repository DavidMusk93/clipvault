//! Cold path: rebuild the metrics plane from pi session JSONL.
//!
//! Ports `pi_session_ingest.py`. The hot path (the pi extension) can supply
//! `ttft_ms`; the cold path is lossless, retroactive, and carries the full
//! system-prompt `sections`, but has no ttft. Both upsert on the same key.

use std::collections::BTreeMap;
use std::sync::LazyLock;

use chrono::{DateTime, TimeZone, Utc};
use regex::Regex;
use serde_json::{json, Map, Value};

use crate::db::{PgVal, Row};
use crate::metrics::{
    CTX_COLS, CTX_TABLE, DEFAULT_CHARS_PER_TOKEN, MIN_ELAPSED_MS, USAGE_COLS, USAGE_TABLE,
};

/// Live-only fields the cold path cannot supply; keep them on re-ingest.
pub const USAGE_LIVE_COLS: &[&str] = &["ttft_ms", "decode_ms", "tok_s_decode"];

static RE_SKILL_NAME: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"<name>([\w.:-]+)</name>").unwrap());
static RE_SKILL_PATH: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"/skills/([\w.:-]+)/").unwrap());
static RE_MEMORY: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"nowledgemem://memory/([\w.:-]+)").unwrap());
static RE_TOOL_LINE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?m)^-\s+([\w.:-]+)\s*:").unwrap());
static RE_READ_CMD: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(^|[|;&]\s*)(cat|bat|less|head|tail|sed|awk|rg|grep|nl)\b").unwrap()
});

const READ_CALL_TOOLS: &[&str] = &["read", "readfile", "read_file", "view", "cat"];
const SHELL_CALL_TOOLS: &[&str] = &["bash", "runcmd", "run_command", "shell", "powershell"];

const SECTION_COLUMNS: &[(&str, &str)] = &[
    ("preamble", "preamble_tokens"),
    ("tools", "tools_tokens"),
    ("rules", "rules_tokens"),
    ("docs", "docs_tokens"),
    ("project_context", "project_tokens"),
    ("skills", "skills_tokens"),
];

fn num(v: Option<&Value>) -> Option<i64> {
    match v {
        Some(Value::Number(n)) => n.as_i64().or_else(|| n.as_f64().map(|f| f as i64)),
        Some(Value::String(s)) => s.parse::<f64>().ok().map(|f| f as i64),
        _ => None,
    }
}

fn flt(v: Option<&Value>) -> Option<f64> {
    match v {
        Some(Value::Number(n)) => n.as_f64(),
        Some(Value::String(s)) => s.parse::<f64>().ok(),
        _ => None,
    }
}

fn opt_str(v: Option<&Value>) -> Option<String> {
    match v {
        Some(Value::String(s)) => Some(s.clone()),
        Some(Value::Number(n)) => Some(n.to_string()),
        _ => None,
    }
}

/// pi timestamps: epoch millis (numbers) or ISO strings.
pub fn parse_ts(value: Option<&Value>) -> Option<DateTime<Utc>> {
    match value {
        Some(Value::Number(n)) => n
            .as_f64()
            .and_then(|ms| Utc.timestamp_millis_opt(ms as i64).single()),
        Some(Value::String(s)) if !s.is_empty() => {
            let text = s.trim().replacen('Z', "+00:00", 1);
            if let Ok(dt) = DateTime::parse_from_rfc3339(&text) {
                return Some(dt.with_timezone(&Utc));
            }
            for fmt in ["%Y-%m-%dT%H:%M:%S%.f", "%Y-%m-%d %H:%M:%S%.f"] {
                if let Ok(naive) = chrono::NaiveDateTime::parse_from_str(s.trim(), fmt) {
                    return Some(naive.and_utc());
                }
            }
            None
        }
        _ => None,
    }
}

pub fn content_to_text(content: &Value) -> String {
    match content {
        Value::String(s) => s.clone(),
        Value::Array(parts) => {
            let mut out: Vec<String> = Vec::new();
            for part in parts {
                let Value::Object(o) = part else { continue };
                match o.get("type").and_then(Value::as_str) {
                    Some("text") => out.push(
                        o.get("text")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_string(),
                    ),
                    Some("thinking") => out.push(
                        o.get("thinking")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_string(),
                    ),
                    Some("toolCall") => out.push(
                        o.get("arguments")
                            .map(|a| serde_json::to_string(a).unwrap_or_default())
                            .unwrap_or_default(),
                    ),
                    Some("toolResult") => {
                        out.push(content_to_text(o.get("content").unwrap_or(&Value::Null)))
                    }
                    _ => {}
                }
            }
            out.join("\n")
        }
        _ => String::new(),
    }
}

pub fn load_entries(path: &std::path::Path) -> Vec<Value> {
    let Ok(text) = std::fs::read_to_string(path) else {
        return vec![];
    };
    text.lines()
        .filter(|l| !l.trim().is_empty())
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .collect()
}

fn skill_names(tools_section: &str, skills_section: &str) -> Vec<String> {
    let mut names: Vec<String> = RE_SKILL_NAME
        .captures_iter(if skills_section.is_empty() {
            ""
        } else {
            skills_section
        })
        .map(|c| c[1].to_string())
        .collect();
    if names.is_empty() {
        names = RE_TOOL_LINE
            .captures_iter(tools_section)
            .map(|c| c[1].to_string())
            .collect();
    }
    let mut set: BTreeMap<String, ()> = BTreeMap::new();
    for n in names {
        if !n.is_empty() {
            set.insert(n, ());
        }
    }
    set.into_keys().collect()
}

/// Skill name if this tool call reads a file under `/skills/<name>/`.
pub fn skill_from_call(name: Option<&Value>, args: &Value) -> Option<String> {
    let tool = name.and_then(Value::as_str).unwrap_or("").to_lowercase();
    let a = args.as_object();
    let target = if READ_CALL_TOOLS.contains(&tool.as_str()) {
        a.and_then(|o| o.get("path").or_else(|| o.get("file_path")))
            .and_then(Value::as_str)
            .map(str::to_string)
    } else if SHELL_CALL_TOOLS.contains(&tool.as_str()) {
        let cmd = a
            .and_then(|o| o.get("command").or_else(|| o.get("cmd")))
            .and_then(Value::as_str)
            .unwrap_or("");
        if RE_READ_CMD.is_match(cmd) {
            Some(cmd.to_string())
        } else {
            None
        }
    } else {
        None
    };
    let hit = RE_SKILL_PATH.captures(target.as_deref().unwrap_or(""))?;
    let name_out = hit[1].to_string();
    if name_out.trim_matches('.').is_empty() {
        None
    } else {
        Some(name_out)
    }
}

#[derive(Clone, Debug)]
pub struct Record {
    pub entry_id: String,
    pub ts: Option<DateTime<Utc>>,
    pub turn_index: i64,
    pub usage: Value,
    pub model: Option<String>,
    pub provider: Option<String>,
    pub api: Option<String>,
    pub stop_reason: Option<String>,
    pub response_id: Option<String>,
    pub elapsed_ms: Option<i64>,
    pub sections: Vec<(String, i64)>,
    pub tools_section: String,
    pub history_chars: i64,
    pub prompt_chars: i64,
    pub prompt_total_chars: i64,
    pub memories: Vec<String>,
    pub skills_loaded: Vec<String>,
    pub skill_bytes: Vec<(String, i64)>,
}

#[derive(Clone, Debug)]
pub struct Analysis {
    pub session_id: String,
    pub cwd: Option<String>,
    pub model: Option<String>,
    pub records: Vec<Record>,
    pub cpt: f64,
}

pub fn analyze(entries: &[Value], chars_per_token: Option<f64>) -> Analysis {
    let mut session_id = String::new();
    let mut cwd: Option<String> = None;
    let mut model: Option<String> = None;
    let mut records: Vec<Record> = Vec::new();

    let mut raw_sections: Vec<(String, String)> = Vec::new();
    let mut tools_section = String::new();
    let mut history_chars: i64 = 0;
    let mut pending_prompt_chars: i64 = 0;
    let mut turn_index: i64 = -1;
    let mut pending_memories: BTreeMap<String, ()> = BTreeMap::new();
    let mut pending_skills: BTreeMap<String, ()> = BTreeMap::new();
    let mut pending_skill_calls: BTreeMap<String, String> = BTreeMap::new();

    for entry in entries {
        let kind = entry.get("type").and_then(Value::as_str).unwrap_or("");
        let entry_ts = parse_ts(entry.get("timestamp"));
        match kind {
            "session" => {
                session_id = entry
                    .get("id")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                cwd = opt_str(entry.get("cwd"));
            }
            "message" => {
                let msg = entry.get("message").cloned().unwrap_or(Value::Null);
                let msg_ms: Option<i64> = msg.get("timestamp").and_then(|v| match v {
                    Value::Number(n) => n.as_f64().map(|f| f as i64),
                    _ => None,
                });
                let role = msg.get("role").and_then(Value::as_str).unwrap_or("");
                match role {
                    "system" => {
                        let patch = msg.get("sections").and_then(Value::as_object);
                        if let Some(p) = patch {
                            if !p.is_empty() {
                                for (name, val) in p {
                                    if val.is_null() {
                                        raw_sections.retain(|(n, _)| n.as_str() != name.as_str());
                                    } else {
                                        let text = val
                                            .as_str()
                                            .map(str::to_string)
                                            .unwrap_or_else(|| val.to_string());
                                        match raw_sections
                                            .iter_mut()
                                            .find(|(n, _)| n.as_str() == name.as_str())
                                        {
                                            Some(e) => e.1 = text,
                                            None => raw_sections.push((name.clone(), text)),
                                        }
                                    }
                                }
                            } else if raw_sections.is_empty() {
                                raw_sections.push((
                                    "system".into(),
                                    content_to_text(msg.get("content").unwrap_or(&Value::Null)),
                                ));
                            }
                        } else if raw_sections.is_empty() {
                            raw_sections.push((
                                "system".into(),
                                content_to_text(msg.get("content").unwrap_or(&Value::Null)),
                            ));
                        }
                        tools_section = raw_sections
                            .iter()
                            .find(|(n, _)| n == "tools")
                            .map(|(_, v)| v.clone())
                            .unwrap_or_default();
                    }
                    "user" => {
                        pending_prompt_chars +=
                            content_to_text(msg.get("content").unwrap_or(&Value::Null))
                                .chars()
                                .count() as i64;
                    }
                    "toolResult" => {
                        let text = content_to_text(msg.get("content").unwrap_or(&Value::Null));
                        history_chars += text.chars().count() as i64;
                        for c in RE_MEMORY.captures_iter(&text) {
                            pending_memories.insert(c[1].to_string(), ());
                        }
                        let cid = msg
                            .get("toolCallId")
                            .and_then(Value::as_str)
                            .map(str::to_string);
                        let name = cid.as_ref().and_then(|c| pending_skill_calls.remove(c));
                        if let (Some(name), Some(last)) = (name, records.last_mut()) {
                            let n = text.chars().count() as i64;
                            match last.skill_bytes.iter_mut().find(|(k, _)| *k == name) {
                                Some(e) => e.1 += n,
                                None => last.skill_bytes.push((name, n)),
                            }
                        }
                    }
                    "assistant" => {
                        turn_index += 1;
                        let usage = msg.get("usage").cloned().unwrap_or(Value::Null);
                        let this_model = opt_str(msg.get("model"));
                        if this_model.is_some() {
                            model = this_model.clone();
                        }
                        let elapsed_ms = match (msg_ms, entry_ts) {
                            (Some(m), Some(t)) => Some((t.timestamp_millis() - m).max(0)),
                            _ => None,
                        };
                        let sections: Vec<(String, i64)> = raw_sections
                            .iter()
                            .map(|(n, v)| (n.clone(), v.chars().count() as i64))
                            .collect();
                        let prompt_total_chars = sections.iter().map(|(_, c)| *c).sum::<i64>()
                            + history_chars
                            + pending_prompt_chars;
                        records.push(Record {
                            entry_id: msg_ms
                                .map(|m| m.to_string())
                                .unwrap_or_else(|| format!("t{turn_index}")),
                            ts: entry_ts.or_else(|| parse_ts(msg.get("timestamp"))),
                            turn_index,
                            usage,
                            model: this_model.or_else(|| model.clone()),
                            provider: opt_str(msg.get("provider")),
                            api: opt_str(msg.get("api")),
                            stop_reason: opt_str(msg.get("stopReason")),
                            response_id: opt_str(msg.get("responseId")),
                            elapsed_ms,
                            sections,
                            tools_section: tools_section.clone(),
                            history_chars,
                            prompt_chars: pending_prompt_chars,
                            prompt_total_chars,
                            memories: pending_memories.keys().cloned().collect(),
                            skills_loaded: pending_skills.keys().cloned().collect(),
                            skill_bytes: Vec::new(),
                        });
                        if let Value::Array(parts) =
                            msg.get("content").cloned().unwrap_or(Value::Null)
                        {
                            for part in parts {
                                let Value::Object(o) = &part else { continue };
                                if o.get("type").and_then(Value::as_str) != Some("toolCall") {
                                    continue;
                                }
                                if let Some(skill) = skill_from_call(
                                    o.get("name"),
                                    o.get("arguments").unwrap_or(&Value::Null),
                                ) {
                                    if let Some(id) = o.get("id").and_then(Value::as_str) {
                                        pending_skill_calls.insert(id.to_string(), skill.clone());
                                    }
                                    pending_skills.insert(skill, ());
                                }
                            }
                        }
                        pending_memories.clear();
                        pending_skills.clear();
                        history_chars += pending_prompt_chars;
                        pending_prompt_chars = 0;
                        history_chars += content_to_text(msg.get("content").unwrap_or(&Value::Null))
                            .chars()
                            .count() as i64;
                    }
                    _ => {}
                }
            }
            _ => {}
        }
    }

    let cpt = chars_per_token.unwrap_or_else(|| calibrate(&records));
    Analysis {
        session_id,
        cwd,
        model,
        records,
        cpt,
    }
}

/// chars/token from real usage: prompt_chars / (input + cacheRead).
pub fn calibrate(records: &[Record]) -> f64 {
    let mut ratios: Vec<f64> = Vec::new();
    for rec in records {
        let actual =
            num(rec.usage.get("input")).unwrap_or(0) + num(rec.usage.get("cacheRead")).unwrap_or(0);
        if actual > 200 && rec.prompt_total_chars > 0 {
            ratios.push(rec.prompt_total_chars as f64 / actual as f64);
        }
    }
    if ratios.is_empty() {
        return DEFAULT_CHARS_PER_TOKEN;
    }
    ratios.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let n = ratios.len();
    let median = if n % 2 == 1 {
        ratios[n / 2]
    } else {
        (ratios[n / 2 - 1] + ratios[n / 2]) / 2.0
    };
    let clamped = median.clamp(2.0, 6.0);
    (clamped * 1000.0).round() / 1000.0
}

fn rate(tokens: Option<i64>, ms: Option<i64>) -> Option<f64> {
    let n = tokens?;
    let m = ms?;
    if n <= 0 || (m as f64) < MIN_ELAPSED_MS {
        return None;
    }
    Some(((n as f64) / (m as f64 / 1000.0) * 10000.0).round() / 10000.0)
}

fn sections_json(sections: &[(String, i64)]) -> String {
    let mut m = Map::new();
    for (k, v) in sections {
        m.insert(k.clone(), json!(v));
    }
    serde_json::to_string(&Value::Object(m)).unwrap_or_else(|_| "{}".into())
}

pub fn build_rows(
    analysis: &Analysis,
    instance_id: &str,
    source: &str,
    host: &str,
) -> (Vec<Row>, Vec<Row>) {
    let session_id = analysis.session_id.clone();
    let cpt = if analysis.cpt == 0.0 {
        DEFAULT_CHARS_PER_TOKEN
    } else {
        analysis.cpt
    };
    let mut usage_rows: Vec<Row> = Vec::new();
    let mut ctx_rows: Vec<Row> = Vec::new();

    for rec in &analysis.records {
        let mid = rec.entry_id.clone();
        let row_id = format!("{session_id}:{mid}");
        let usage = &rec.usage;
        let cost = usage.get("cost").cloned().unwrap_or(Value::Null);
        let output = num(usage.get("output"));
        let elapsed = rec.elapsed_ms;
        let ts = rec.ts.unwrap_or_else(Utc::now);
        usage_rows.push(vec![
            ("usage_id", PgVal::Text(Some(row_id.clone()))),
            ("ts", PgVal::Ts(Some(ts))),
            ("session_id", PgVal::Text(Some(session_id.clone()))),
            ("instance_id", PgVal::Text(Some(instance_id.to_string()))),
            ("source", PgVal::Text(Some(source.to_string()))),
            ("model", PgVal::Text(rec.model.clone())),
            ("provider", PgVal::Text(rec.provider.clone())),
            ("api", PgVal::Text(rec.api.clone())),
            ("message_id", PgVal::Text(Some(mid.clone()))),
            ("turn_index", PgVal::Int4(Some(rec.turn_index as i32))),
            ("input_tokens", PgVal::Int(num(usage.get("input")))),
            ("output_tokens", PgVal::Int(output)),
            ("cache_read_tokens", PgVal::Int(num(usage.get("cacheRead")))),
            (
                "cache_write_tokens",
                PgVal::Int(num(usage.get("cacheWrite"))),
            ),
            ("reasoning_tokens", PgVal::Int(num(usage.get("reasoning")))),
            ("total_tokens", PgVal::Int(num(usage.get("totalTokens")))),
            ("cost_input", PgVal::Float(flt(cost.get("input")))),
            ("cost_output", PgVal::Float(flt(cost.get("output")))),
            ("cost_cache_read", PgVal::Float(flt(cost.get("cacheRead")))),
            (
                "cost_cache_write",
                PgVal::Float(flt(cost.get("cacheWrite"))),
            ),
            ("cost_total", PgVal::Float(flt(cost.get("total")))),
            ("ttft_ms", PgVal::Int(None)),
            ("elapsed_ms", PgVal::Int(elapsed)),
            ("decode_ms", PgVal::Int(None)),
            ("tok_s_decode", PgVal::Float(None)),
            ("tok_s_e2e", PgVal::Float(rate(output, elapsed))),
            ("stop_reason", PgVal::Text(rec.stop_reason.clone())),
            ("response_id", PgVal::Text(rec.response_id.clone())),
            ("host", PgVal::Text(Some(host.to_string()))),
        ]);

        let mut ctx: Row = vec![
            ("ctx_id", PgVal::Text(Some(row_id.clone()))),
            ("ts", PgVal::Ts(Some(ts))),
            ("session_id", PgVal::Text(Some(session_id.clone()))),
            ("instance_id", PgVal::Text(Some(instance_id.to_string()))),
            ("source", PgVal::Text(Some(source.to_string()))),
            ("model", PgVal::Text(rec.model.clone())),
            ("message_id", PgVal::Text(Some(mid.clone()))),
            ("turn_index", PgVal::Int4(Some(rec.turn_index as i32))),
            ("est_chars_per_token", PgVal::Float(Some(cpt))),
            (
                "sections_json",
                PgVal::Text(Some(sections_json(&rec.sections))),
            ),
            (
                "skill_names",
                PgVal::Text(Some(rec.skills_loaded.join(","))),
            ),
            (
                "skill_loaded_tokens",
                if rec.skill_bytes.is_empty() {
                    PgVal::Text(None)
                } else {
                    let mut m = Map::new();
                    for (k, v) in &rec.skill_bytes {
                        if *v > 0 {
                            m.insert(k.clone(), json!(((*v as f64) / cpt).round() as i64));
                        }
                    }
                    PgVal::Text(Some(
                        serde_json::to_string(&Value::Object(m)).unwrap_or_default(),
                    ))
                },
            ),
            ("memory_ids", PgVal::Text(Some(rec.memories.join(",")))),
            (
                "tool_schema_names",
                PgVal::Text(Some(skill_names(&rec.tools_section, "").join(","))),
            ),
            ("host", PgVal::Text(Some(host.to_string()))),
        ];
        let mut system_tokens = 0i64;
        for (name, chars) in &rec.sections {
            let toks = ((*chars as f64) / cpt).round() as i64;
            system_tokens += toks;
            if let Some((_, col)) = SECTION_COLUMNS.iter().find(|(n, _)| n == name) {
                ctx.push((col, PgVal::Int(Some(toks))));
            }
        }
        ctx.push(("system_tokens", PgVal::Int(Some(system_tokens))));
        ctx.push((
            "prompt_tokens",
            PgVal::Int(Some(((rec.prompt_chars as f64) / cpt).round() as i64)),
        ));
        ctx.push((
            "history_tokens",
            PgVal::Int(Some(((rec.history_chars as f64) / cpt).round() as i64)),
        ));
        ctx.push(("tool_result_tokens", PgVal::Int(None)));
        ctx.push((
            "prompt_total_tokens",
            PgVal::Int(Some(((rec.prompt_total_chars as f64) / cpt).round() as i64)),
        ));
        ctx_rows.push(ctx);
    }

    (usage_rows, ctx_rows)
}

pub const USAGE_KEY: &str = "usage_id";
pub const CTX_KEY: &str = "ctx_id";
pub const USAGE_TABLE_NAME: &str = USAGE_TABLE;
pub const CTX_TABLE_NAME: &str = CTX_TABLE;
pub const USAGE_COLUMNS: &[&str] = USAGE_COLS;
pub const CTX_COLUMNS: &[&str] = CTX_COLS;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn content_to_text_joins_parts() {
        let v = json!([
            {"type": "text", "text": "a"},
            {"type": "toolCall", "arguments": {"x": 1}},
            {"type": "toolResult", "content": "r"}
        ]);
        let t = content_to_text(&v);
        assert!(t.contains('a') && t.contains("r"));
    }

    #[test]
    fn skill_from_call_matches_read_and_shell() {
        assert_eq!(
            skill_from_call(
                Some(&json!("read")),
                &json!({"path": "/x/skills/goal/SKILL.md"})
            ),
            Some("goal".to_string())
        );
        assert_eq!(
            skill_from_call(
                Some(&json!("bash")),
                &json!({"command": "cat /x/skills/goal/SKILL.md"})
            ),
            Some("goal".to_string())
        );
        assert_eq!(
            skill_from_call(
                Some(&json!("write")),
                &json!({"path": "/x/skills/goal/SKILL.md"})
            ),
            None
        );
    }

    #[test]
    fn parse_ts_handles_ms_and_iso() {
        assert!(parse_ts(Some(&json!(1_700_000_000_000i64))).is_some());
        assert!(parse_ts(Some(&json!("2026-10-01T16:23:19.392Z"))).is_some());
    }
}
