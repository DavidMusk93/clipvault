//! Metrics plane: `llm_usage` + `turn_context` row builders (hot path).
//!
//! Port of the Python `metrics.py` row builders. The hot path is the pi
//! extension (`UsageReport` / `ContextReport`) — the only writer that can supply
//! `ttft_ms`. The cold backfill from pi session JSONL is a separate ingester.

use anyhow::{Context, Result};
use chrono::{DateTime, NaiveDateTime, Utc};
use serde_json::Value;
use tokio_postgres::types::ToSql;

pub const MIN_ELAPSED_MS: f64 = 120.0;
pub const DEFAULT_CHARS_PER_TOKEN: f64 = 3.6;

pub const USAGE_TABLE: &str = "llm_usage";
pub const CTX_TABLE: &str = "turn_context";

pub const USAGE_COLS: &[&str] = &[
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
];

pub const CTX_COLS: &[&str] = &[
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
];

const SECTION_COLUMNS: &[(&str, &str)] = &[
    ("preamble", "preamble_tokens"),
    ("tools", "tools_tokens"),
    ("rules", "rules_tokens"),
    ("docs", "docs_tokens"),
    ("project_context", "project_tokens"),
    ("skills", "skills_tokens"),
];

pub use crate::db::{row_get as get, PgVal, Row};

fn s(v: Option<&Value>) -> Option<String> {
    match v {
        Some(Value::String(s)) => Some(s.clone()),
        Some(Value::Number(n)) => Some(n.to_string()),
        Some(Value::Bool(b)) => Some(b.to_string()),
        _ => None,
    }
}

fn text(v: Option<&Value>) -> PgVal {
    PgVal::Text(s(v))
}

fn tok(v: Option<&Value>) -> Option<i64> {
    match v {
        Some(Value::Number(n)) => n.as_i64().or_else(|| n.as_f64().map(|f| f.round() as i64)),
        Some(Value::String(s)) => s.parse::<f64>().ok().map(|f| f.round() as i64),
        _ => None,
    }
}

fn ms(v: Option<&Value>) -> Option<i64> {
    match v {
        Some(Value::Number(n)) => n.as_f64().map(|f| f.round() as i64),
        Some(Value::String(s)) => s.parse::<f64>().ok().map(|f| f.round() as i64),
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

fn rate(num: Option<i64>, ms: Option<i64>) -> Option<f64> {
    let n = num?;
    let m = ms?;
    if n <= 0 || (m as f64) < MIN_ELAPSED_MS {
        return None;
    }
    Some(((n as f64) / (m as f64 / 1000.0) * 10000.0).round() / 10000.0)
}

pub fn parse_ts(payload: &Value) -> DateTime<Utc> {
    if let Some(Value::String(s)) = payload.get("ts") {
        if let Ok(dt) = DateTime::parse_from_rfc3339(s) {
            return dt.with_timezone(&Utc);
        }
        for fmt in ["%Y-%m-%d %H:%M:%S%.f", "%Y-%m-%dT%H:%M:%S%.f"] {
            if let Ok(naive) = NaiveDateTime::parse_from_str(s, fmt) {
                return DateTime::from_naive_utc_and_offset(naive, Utc);
            }
        }
    }
    Utc::now()
}

fn id_pair(payload: &Value) -> (String, String) {
    let session_id = s(payload.get("session_id")).unwrap_or_default();
    let message_id = s(payload.get("message_id"))
        .or_else(|| s(payload.get("tool_use_id")))
        .unwrap_or_default();
    (session_id, message_id)
}

pub fn usage_row(payload: &Value) -> Row {
    let (session_id, message_id) = id_pair(payload);
    let usage = payload.get("usage").cloned().unwrap_or(Value::Null);
    let cost = usage.get("cost").cloned().unwrap_or(Value::Null);
    let elapsed = ms(payload.get("elapsed_ms"));
    let ttft = ms(payload.get("ttft_ms"));
    let decode = elapsed.map(|e| (e - ttft.unwrap_or(0)).max(0));
    let output = tok(usage.get("output"));
    vec![
        (
            "usage_id",
            PgVal::Text(Some(format!("{session_id}:{message_id}"))),
        ),
        ("ts", PgVal::Ts(Some(parse_ts(payload)))),
        ("session_id", PgVal::Text(Some(session_id))),
        ("instance_id", text(payload.get("instance_id"))),
        (
            "source",
            PgVal::Text(Some(
                s(payload.get("source")).unwrap_or_else(|| "pi".into()),
            )),
        ),
        ("model", text(payload.get("model"))),
        ("provider", text(payload.get("provider"))),
        ("api", text(payload.get("api"))),
        ("message_id", PgVal::Text(Some(message_id))),
        (
            "turn_index",
            PgVal::Int4(tok(payload.get("turn_index")).map(|v| v as i32)),
        ),
        ("input_tokens", PgVal::Int(tok(usage.get("input")))),
        ("output_tokens", PgVal::Int(output)),
        ("cache_read_tokens", PgVal::Int(tok(usage.get("cacheRead")))),
        (
            "cache_write_tokens",
            PgVal::Int(tok(usage.get("cacheWrite"))),
        ),
        ("reasoning_tokens", PgVal::Int(tok(usage.get("reasoning")))),
        ("total_tokens", PgVal::Int(tok(usage.get("totalTokens")))),
        ("cost_input", PgVal::Float(flt(cost.get("input")))),
        ("cost_output", PgVal::Float(flt(cost.get("output")))),
        ("cost_cache_read", PgVal::Float(flt(cost.get("cacheRead")))),
        (
            "cost_cache_write",
            PgVal::Float(flt(cost.get("cacheWrite"))),
        ),
        ("cost_total", PgVal::Float(flt(cost.get("total")))),
        ("ttft_ms", PgVal::Int(ttft)),
        ("elapsed_ms", PgVal::Int(elapsed)),
        ("decode_ms", PgVal::Int(decode)),
        ("tok_s_decode", PgVal::Float(rate(output, decode))),
        ("tok_s_e2e", PgVal::Float(rate(output, elapsed))),
        ("stop_reason", text(payload.get("stop_reason"))),
        ("response_id", text(payload.get("response_id"))),
        ("host", text(payload.get("host"))),
    ]
}

pub fn ctx_row(payload: &Value) -> Row {
    let (session_id, message_id) = id_pair(payload);
    let sections = payload.get("sections").cloned().unwrap_or(Value::Null);
    let cpt = flt(payload.get("est_chars_per_token")).unwrap_or(DEFAULT_CHARS_PER_TOKEN);
    let mut row: Vec<(&'static str, PgVal)> = vec![
        (
            "ctx_id",
            PgVal::Text(Some(format!("{session_id}:{message_id}"))),
        ),
        ("ts", PgVal::Ts(Some(parse_ts(payload)))),
        ("session_id", PgVal::Text(Some(session_id.clone()))),
        ("instance_id", text(payload.get("instance_id"))),
        (
            "source",
            PgVal::Text(Some(
                s(payload.get("source")).unwrap_or_else(|| "pi".into()),
            )),
        ),
        ("model", text(payload.get("model"))),
        ("message_id", PgVal::Text(Some(message_id))),
        (
            "turn_index",
            PgVal::Int4(tok(payload.get("turn_index")).map(|v| v as i32)),
        ),
        ("est_chars_per_token", PgVal::Float(Some(cpt))),
        (
            "sections_json",
            PgVal::Text(Some(
                serde_json::to_string(&sections).unwrap_or_else(|_| "{}".into()),
            )),
        ),
        ("skill_names", text(payload.get("skill_names"))),
        (
            "skill_loaded_tokens",
            text(payload.get("skill_loaded_tokens")),
        ),
        ("memory_ids", text(payload.get("memory_ids"))),
        ("tool_schema_names", text(payload.get("tool_schema_names"))),
        ("host", text(payload.get("host"))),
    ];
    let mut total_system: i64 = 0;
    if let Some(obj) = sections.as_object() {
        for (name, value) in obj {
            let chars = match value {
                Value::Number(n) => n.as_f64().unwrap_or(0.0),
                Value::String(s) => s.chars().count() as f64,
                Value::Null => 0.0,
                other => other.to_string().chars().count() as f64,
            };
            let toks = (chars / cpt).round() as i64;
            total_system += toks;
            if let Some((_, col)) = SECTION_COLUMNS.iter().find(|(n, _)| n == name) {
                row.push((col, PgVal::Int(Some(toks))));
            }
        }
    }
    let prompt_tokens = tok(payload.get("prompt_tokens"));
    let history_tokens = tok(payload.get("history_tokens"));
    let tool_result_tokens = tok(payload.get("tool_result_tokens"));
    let parts = total_system + prompt_tokens.unwrap_or(0) + history_tokens.unwrap_or(0);
    row.push(("system_tokens", PgVal::Int(Some(total_system))));
    row.push(("prompt_tokens", PgVal::Int(prompt_tokens)));
    row.push(("history_tokens", PgVal::Int(history_tokens)));
    row.push(("tool_result_tokens", PgVal::Int(tool_result_tokens)));
    row.push((
        "prompt_total_tokens",
        PgVal::Int(if parts == 0 { None } else { Some(parts) }),
    ));
    row
}

/// `INSERT ... ON CONFLICT DO NOTHING` for one metric row (hot path).
///
/// Only the columns present in `row` are written; absent ones take the column
/// default (NULL). This avoids typing a NULL placeholder for every optional
/// context section.
pub async fn insert_row(
    client: &tokio_postgres::Client,
    table: &str,
    _expected_cols: &[&str],
    row: &Row,
) -> Result<()> {
    let cols: Vec<&str> = row.iter().map(|(c, _)| *c).collect();
    let values: Vec<&PgVal> = row.iter().map(|(_, v)| v).collect();
    let placeholders: Vec<String> = (1..=cols.len()).map(|i| format!("${i}")).collect();
    let sql = format!(
        "INSERT INTO {table} ({}) VALUES ({}) ON CONFLICT DO NOTHING",
        cols.join(", "),
        placeholders.join(", ")
    );
    let boxed: Vec<Box<dyn ToSql + Send + Sync>> = values.iter().map(|v| v.boxed()).collect();
    let refs: Vec<&(dyn ToSql + Sync)> = boxed
        .iter()
        .map(|b| b.as_ref() as &(dyn ToSql + Sync))
        .collect();
    client
        .execute(&sql, &refs)
        .await
        .context("insert metric row")?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn rate_ignores_short_or_empty_windows() {
        assert_eq!(rate(Some(50), Some(800)), Some(62.5));
        assert_eq!(rate(Some(50), Some(100)), None); // below MIN_ELAPSED_MS
        assert_eq!(rate(Some(0), Some(800)), None);
    }

    #[test]
    fn usage_row_derives_decode_and_cost() {
        let p = json!({
            "session_id": "s", "message_id": "m",
            "elapsed_ms": 1000, "ttft_ms": 200,
            "usage": {"output": 50, "input": 100, "cost": {"total": 0.5}}
        });
        let row = usage_row(&p);
        assert_eq!(get(&row, "usage_id").and_then(PgVal::as_text), Some("s:m"));
        assert_eq!(get(&row, "decode_ms").and_then(PgVal::as_i64), Some(800));
        assert_eq!(
            get(&row, "tok_s_decode").and_then(PgVal::as_f64),
            Some(62.5)
        );
        assert_eq!(get(&row, "cost_total").and_then(PgVal::as_f64), Some(0.5));
        assert_unique_columns(&row);
    }

    #[test]
    fn ctx_row_sums_only_known_sections_but_counts_all() {
        let p = json!({
            "session_id": "s", "message_id": "m",
            "sections": {"rules": 360, "skills": 72, "prompt": 100},
            "prompt_tokens": 100, "history_tokens": 500
        });
        let row = ctx_row(&p);
        // 100 (rules) + 20 (skills) + 28 (unknown `prompt`) = 148
        assert_eq!(
            get(&row, "system_tokens").and_then(PgVal::as_i64),
            Some(148)
        );
        assert_eq!(get(&row, "rules_tokens").and_then(PgVal::as_i64), Some(100));
        assert_eq!(
            get(&row, "prompt_total_tokens").and_then(PgVal::as_i64),
            Some(748)
        );
        assert_unique_columns(&row);
    }

    fn assert_unique_columns(row: &Row) {
        let mut names: Vec<&str> = row.iter().map(|(c, _)| *c).collect();
        let n = names.len();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), n, "duplicate column in metric row");
    }
}
