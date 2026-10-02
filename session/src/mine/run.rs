//! Layer 7: SQL fetch, `mine()` orchestration and `ack_finding`.
//!
//! Ports `mine.py::fetch_rows`, `fetch_metrics`, `fetch_baseline`, `mine`,
//! `ack_finding`. The query surface is PostgreSQL (`$n`); the analysis layers
//! are storage-agnostic.

use anyhow::{Context, Result};
use serde_json::{json, Value};
use tokio_postgres::types::ToSql;

use super::analysis::{self, agent_view, g, parse_ts_v, sv};
use super::rows::mine_rows;

pub const FETCH_SQL: &str =
    "SELECT event_id, CAST(ts AT TIME ZONE 'UTC' AS VARCHAR) AS ts, session_id, instance_id, cwd, \
    hook_event, tool_name, llm_tool_name, prompt, last_assistant_message, \
    substr(coalesce(tool_input, ''), 1, 1500) AS input_head, \
    substr(coalesce(tool_response, ''), 1, 400) AS resp_head \
    FROM hook_events WHERE hook_event IN ('PostToolUse','UserPromptSubmit','Stop')";

pub const USAGE_SQL: &str = "SELECT CAST(ts AT TIME ZONE 'UTC' AS VARCHAR) AS ts, session_id, model, provider, turn_index, \
    input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens, \
    total_tokens, cost_total, ttft_ms, elapsed_ms, decode_ms, tok_s_decode, tok_s_e2e \
    FROM llm_usage WHERE 1=1";

pub const CTX_SQL: &str = "SELECT CAST(ts AT TIME ZONE 'UTC' AS VARCHAR) AS ts, session_id, turn_index, system_tokens, \
    preamble_tokens, tools_tokens, rules_tokens, docs_tokens, project_tokens, skills_tokens, \
    prompt_tokens, history_tokens, prompt_total_tokens, skill_names, skill_loaded_tokens, memory_ids \
    FROM turn_context WHERE 1=1";

fn scope_filter(
    sql: &str,
    params: &mut Vec<Box<dyn ToSql + Send + Sync>>,
    session_id: Option<&str>,
    scope: &str,
    since: Option<&str>,
    until: Option<&str>,
) -> String {
    let mut q = sql.to_string();
    if let Some(s) = since {
        params.push(Box::new(s.to_string()));
        q += &format!(" AND ts >= CAST(${} AS TIMESTAMP)", params.len());
    }
    if let Some(u) = until {
        params.push(Box::new(u.to_string()));
        q += &format!(" AND ts < CAST(${} AS TIMESTAMP)", params.len());
    }
    if since.is_none() && until.is_none() {
        if scope == "session" && session_id.map(|s| !s.is_empty()).unwrap_or(false) {
            params.push(Box::new(session_id.unwrap_or("").to_string()));
            q += &format!(" AND session_id = ${}", params.len());
        } else if scope == "recent" {
            q += " AND ts >= (now() - INTERVAL '7 days')";
        } else {
            params.push(Box::new(session_id.unwrap_or("").to_string()));
            q += &format!(" AND session_id = ${}", params.len());
        }
    }
    q
}

async fn query(
    client: &tokio_postgres::Client,
    sql: &str,
    params: &[Box<dyn ToSql + Send + Sync>],
) -> Result<Vec<Value>> {
    let refs: Vec<&(dyn ToSql + Sync)> = params
        .iter()
        .map(|b| b.as_ref() as &(dyn ToSql + Sync))
        .collect();
    let rows = client
        .query(sql, &refs)
        .await
        .with_context(|| format!("query: {sql}"))?;
    Ok(rows.iter().map(crate::db::row_to_value).collect())
}

pub async fn fetch_rows(
    client: &tokio_postgres::Client,
    session_id: Option<&str>,
    scope: &str,
    since: Option<&str>,
    until: Option<&str>,
) -> Vec<Value> {
    let mut params: Vec<Box<dyn ToSql + Send + Sync>> = Vec::new();
    let mut sql = scope_filter(FETCH_SQL, &mut params, session_id, scope, since, until);
    sql += " ORDER BY ts ASC LIMIT 12000";
    query(client, &sql, &params).await.unwrap_or_default()
}

async fn fetch_one_metrics(
    client: &tokio_postgres::Client,
    base: &str,
    session_id: Option<&str>,
    scope: &str,
    since: Option<&str>,
    until: Option<&str>,
) -> Vec<Value> {
    let mut params: Vec<Box<dyn ToSql + Send + Sync>> = Vec::new();
    let mut sql = scope_filter(base, &mut params, session_id, scope, since, until);
    sql += " ORDER BY ts ASC LIMIT 20000";
    query(client, &sql, &params).await.unwrap_or_default()
}

pub async fn fetch_metrics(
    client: &tokio_postgres::Client,
    session_id: Option<&str>,
    scope: &str,
    since: Option<&str>,
    until: Option<&str>,
) -> (Vec<Value>, Vec<Value>) {
    let usage = fetch_one_metrics(client, USAGE_SQL, session_id, scope, since, until).await;
    let ctx = fetch_one_metrics(client, CTX_SQL, session_id, scope, since, until).await;
    (usage, ctx)
}

/// Previous equal-length window. Empty when there is no earlier window.
pub async fn fetch_baseline(
    client: &tokio_postgres::Client,
    session_id: Option<&str>,
    scope: &str,
    rows: &[Value],
) -> (Vec<Value>, Vec<Value>, Vec<Value>, String) {
    let ts: Vec<f64> = rows.iter().filter_map(|r| parse_ts_v(g(r, "ts"))).collect();
    if ts.is_empty() {
        return (vec![], vec![], vec![], String::new());
    }
    let start = ts.iter().cloned().fold(f64::INFINITY, f64::min);
    let end = ts.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
    let span = 60.0f64.max(end - start);
    if scope == "session" && session_id.map(|s| !s.is_empty()).unwrap_or(false) {
        let sql = "SELECT session_id FROM hook_events WHERE ts < CAST($1 AS TIMESTAMP) AND session_id != $2 \
                   GROUP BY session_id ORDER BY max(ts) DESC LIMIT 1";
        let got = query(
            client,
            sql,
            &[
                Box::new(analysis::ts_str(start)),
                Box::new(session_id.unwrap_or("").to_string()),
            ],
        )
        .await
        .unwrap_or_default();
        let prev = got
            .first()
            .map(|r| sv(g(r, "session_id")))
            .unwrap_or_default();
        if prev.is_empty() {
            return (vec![], vec![], vec![], String::new());
        }
        let (usage, ctx) = fetch_metrics(client, Some(&prev), "session", None, None).await;
        let rows = fetch_rows(client, Some(&prev), "session", None, None).await;
        let label = format!("上一个会话 {}", &prev[..prev.len().min(8)]);
        return (rows, usage, ctx, label);
    }
    let since = analysis::ts_str(start - span);
    let until = analysis::ts_str(start);
    let (usage, ctx) = fetch_metrics(client, None, scope, Some(&since), Some(&until)).await;
    let rows = fetch_rows(client, None, scope, Some(&since), Some(&until)).await;
    let label = format!("前 {} 小时", ((span / 3600.0) * 10.0).round() / 10.0);
    (rows, usage, ctx, label)
}

/// Full analysis result, or the machine contract when `fmt == "agent"`.
#[allow(clippy::too_many_arguments)]
pub async fn mine(
    client: &tokio_postgres::Client,
    session_id: Option<&str>,
    scope: &str,
    dirs: Option<&[String]>,
    baseline: bool,
    fmt: &str,
    host: &str,
) -> Value {
    let scope = if scope == "recent" {
        "recent"
    } else {
        "session"
    };
    let rows = fetch_rows(client, session_id, scope, None, None).await;
    let (usage_rows, ctx_rows) = fetch_metrics(client, session_id, scope, None, None).await;
    let mut result = mine_rows(&rows, dirs, session_id, scope, &usage_rows, &ctx_rows);

    let ack_rows = fetch_ack_rows(client, session_id, scope).await;
    let acks = analysis::fetch_acks(&ack_rows);
    analysis::attach_acks(&mut result, &acks);

    let mut query_parts = vec![format!("--scope {scope}")];
    if session_id.map(|s| !s.is_empty()).unwrap_or(false) && scope == "session" {
        query_parts.push(format!("--session-id {}", session_id.unwrap_or("")));
    }
    if let Some(d) = dirs {
        if !d.is_empty() {
            query_parts.push(format!("--dirs {}", d.join(",")));
        }
    }
    if let Some(o) = result.as_object_mut() {
        o.insert("host".into(), json!(host));
        o.insert(
            "rerun".into(),
            json!(format!(
                "clipvault-session mine --agent {}",
                query_parts.join(" ")
            )),
        );
    }

    let mut base_metrics: Vec<Value> = vec![];
    if baseline {
        let (b_rows, b_usage, b_ctx, label) =
            fetch_baseline(client, session_id, scope, &rows).await;
        if !b_rows.is_empty() {
            let base = mine_rows(&b_rows, dirs, session_id, scope, &b_usage, &b_ctx);
            base_metrics = match g(&base, "metrics") {
                Value::Array(a) => a.clone(),
                _ => vec![],
            };
            if let Value::Array(ms) = g(&result, "metrics").clone() {
                let mut ms = ms;
                analysis::attach_baseline(&mut ms, &base_metrics);
                if let Some(o) = result.as_object_mut() {
                    o.insert("metrics".into(), Value::Array(ms));
                }
            }
            if let Some(o) = result.as_object_mut() {
                o.insert(
                    "baseline".into(),
                    json!({
                        "source": label,
                        "window": g(&base, "window"),
                        "metrics": base_metrics,
                        "losses": g(&base, "losses"),
                    }),
                );
            }
        } else if let Some(o) = result.as_object_mut() {
            o.insert("baseline".into(), Value::Null);
        }
    }

    if fmt == "agent" {
        return agent_view(&result, &base_metrics);
    }
    result
}

async fn fetch_ack_rows(
    client: &tokio_postgres::Client,
    session_id: Option<&str>,
    scope: &str,
) -> Vec<Value> {
    let sql = "SELECT finding_id, CAST(ts AT TIME ZONE 'UTC' AS VARCHAR) AS ts, status, note, metric_id, metric_now, target \
               FROM analysis_acks WHERE scope = $1 AND session_id = $2 ORDER BY ts DESC";
    query(
        client,
        sql,
        &[
            Box::new(scope.to_string()),
            Box::new(session_id.unwrap_or("").to_string()),
        ],
    )
    .await
    .unwrap_or_default()
}

/// Record that a finding was applied/dismissed. Latest status per window wins.
pub async fn ack_finding(
    client: &tokio_postgres::Client,
    scope: &str,
    session_id: Option<&str>,
    finding_id: &str,
    status: &str,
    note: &str,
    metric: &Value,
    instance_id: &str,
) -> Result<Value> {
    let scope = if scope == "recent" {
        "recent"
    } else {
        "session"
    };
    let status = if status == "dismissed" {
        "dismissed"
    } else {
        "applied"
    };
    let fid = finding_id.trim();
    if fid.is_empty() {
        return Ok(json!({"ok": false, "error": "finding_id required"}));
    }
    let sid = session_id.unwrap_or("");
    let ack_id = format!("{scope}:{}:{fid}", if sid.is_empty() { "-" } else { sid });
    let note: String = note.chars().take(500).collect();
    let metric_id = sv(g(metric, "id"));
    let metric_now = metric.get("now").and_then(Value::as_f64);
    let target = metric.get("target").and_then(Value::as_f64);
    client
        .execute(
            "INSERT INTO analysis_acks (ack_id, ts, instance_id, scope, session_id, finding_id, \
             status, note, metric_id, metric_now, target) \
             VALUES ($1, now(), $2, $3, $4, $5, $6, $7, $8, $9, $10) \
             ON CONFLICT (ack_id) DO UPDATE SET ts = excluded.ts, status = excluded.status, \
             note = excluded.note, metric_id = excluded.metric_id, metric_now = excluded.metric_now, \
             target = excluded.target, instance_id = excluded.instance_id",
            &[
                &ack_id,
                &instance_id,
                &scope,
                &sid,
                &fid,
                &status,
                &note,
                &metric_id,
                &metric_now,
                &target,
            ],
        )
        .await
        .context("ack insert")?;
    Ok(json!({"ok": true, "ack_id": ack_id, "finding_id": fid, "status": status}))
}
