//! Hook payload -> `hook_events` row, plus the SSE stub and the fail-open spool.
//!
//! Port of the Python `row.py` / `hook_client.py` ingest rules:
//!   * `raw_hash` = sha256 of canonical (sorted-key, compact) JSON
//!   * `event_id` = `raw_hash[..32]`
//!   * `ts` = capture clock, naive UTC (INV-2)
//!   * every non-fatal error path still exits 0 (INV-4)

use std::io::Write;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};

pub const OFFICIAL_EVENTS: [&str; 6] = [
    "SessionStart",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "Stop",
    "Notification",
];

pub const METRIC_EVENTS: [&str; 2] = ["UsageReport", "ContextReport"];

/// PostgreSQL NOTIFY channel the facade LISTENs on.
pub const NOTIFY_CHANNEL: &str = "clipvault_hook";

pub const INSERT_SQL: &str = "INSERT INTO hook_events (
        event_id, ts, instance_id, session_id, hook_event, source, cwd,
        workspace_roots, tool_name, llm_tool_name, tool_use_id, prompt,
        last_assistant_message, notification_type, notification_message,
        stop_hook_active, loop_count, tool_input, tool_response,
        raw_json, raw_hash, host, pid
    ) VALUES (
        $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23
    ) ON CONFLICT (event_id) DO NOTHING";

#[derive(Debug, Clone)]
pub struct HookEvent {
    pub event_id: String,
    pub ts: DateTime<Utc>,
    pub instance_id: String,
    pub session_id: Option<String>,
    pub hook_event: String,
    pub source: String,
    pub cwd: Option<String>,
    pub workspace_roots: Option<String>,
    pub tool_name: Option<String>,
    pub llm_tool_name: Option<String>,
    pub tool_use_id: Option<String>,
    pub prompt: Option<String>,
    pub last_assistant_message: Option<String>,
    pub notification_type: Option<String>,
    pub notification_message: Option<String>,
    pub stop_hook_active: Option<bool>,
    pub loop_count: Option<i32>,
    pub tool_input: Option<String>,
    pub tool_response: Option<String>,
    pub raw_json: String,
    pub raw_hash: String,
    pub host: Option<String>,
    pub pid: i32,
}

fn as_str(v: Option<&Value>) -> Option<String> {
    match v {
        Some(Value::String(s)) => Some(s.clone()),
        Some(Value::Number(n)) => Some(n.to_string()),
        Some(Value::Bool(b)) => Some(b.to_string()),
        _ => None,
    }
}

/// JSON-dump a payload field: keep strings verbatim, stringify everything else.
fn dumps(v: Option<&Value>) -> Option<String> {
    match v {
        None | Some(Value::Null) => None,
        Some(Value::String(s)) => Some(s.clone()),
        Some(other) => Some(other.to_string()),
    }
}

pub fn canonical_json(payload: &Value) -> String {
    // serde_json maps are BTreeMap-backed (sorted keys); `to_string` is compact.
    serde_json::to_string(payload).unwrap_or_else(|_| "{}".to_string())
}

pub fn payload_hash(payload: &Value) -> String {
    let mut hasher = Sha256::new();
    hasher.update(canonical_json(payload).as_bytes());
    hex::encode(hasher.finalize())
}

impl HookEvent {
    pub fn from_payload(
        payload: &Value,
        hook_event: Option<&str>,
        instance_id: &str,
        source: &str,
    ) -> Self {
        let obj = payload.as_object();
        let get = |k: &str| obj.and_then(|o| o.get(k));
        let event = hook_event
            .map(|s| s.to_string())
            .or_else(|| as_str(get("hook_event_name")))
            .or_else(|| as_str(get("hookEventName")))
            .unwrap_or_else(|| "Unknown".to_string());
        let raw_json = canonical_json(payload);
        let raw_hash = payload_hash(payload);
        let event_id = raw_hash.chars().take(32).collect::<String>();
        let pid = std::process::id() as i32;
        Self {
            event_id,
            ts: Utc::now(),
            instance_id: instance_id.to_string(),
            session_id: as_str(get("session_id")),
            hook_event: event.clone(),
            source: source.to_string(),
            cwd: as_str(get("cwd")),
            workspace_roots: dumps(get("workspace_roots")),
            tool_name: as_str(get("tool_name")),
            llm_tool_name: as_str(get("llm_tool_name")),
            tool_use_id: as_str(get("tool_use_id")),
            prompt: as_str(get("prompt")),
            last_assistant_message: as_str(get("last_assistant_message")),
            notification_type: as_str(get("notification_type")),
            notification_message: if event == "Notification" {
                as_str(get("message"))
            } else {
                None
            },
            stop_hook_active: get("stop_hook_active").and_then(Value::as_bool),
            loop_count: get("loop_count").and_then(Value::as_i64).map(|n| n as i32),
            tool_input: dumps(get("tool_input")),
            tool_response: dumps(get("tool_response")),
            raw_json,
            raw_hash,
            host: hostname::get().ok().map(|h| h.to_string_lossy().to_string()),
            pid,
        }
    }

    pub async fn insert(&self, client: &tokio_postgres::Client) -> Result<u64> {
        let n = client
            .execute(
                INSERT_SQL,
                &[
                    &self.event_id,
                    &self.ts,
                    &self.instance_id,
                    &self.session_id,
                    &self.hook_event,
                    &self.source,
                    &self.cwd,
                    &self.workspace_roots,
                    &self.tool_name,
                    &self.llm_tool_name,
                    &self.tool_use_id,
                    &self.prompt,
                    &self.last_assistant_message,
                    &self.notification_type,
                    &self.notification_message,
                    &self.stop_hook_active,
                    &self.loop_count,
                    &self.tool_input,
                    &self.tool_response,
                    &self.raw_json,
                    &self.raw_hash,
                    &self.host,
                    &self.pid,
                ],
            )
            .await
            .context("insert hook_event")?;
        Ok(n)
    }

    /// The small SSE stub; tool bodies stay on `GET /api/event?id=`.
    pub fn sse_payload(&self) -> Value {
        let msg = self.notification_message.clone().unwrap_or_default();
        let preview_src = self
            .prompt
            .clone()
            .or_else(|| {
                if msg.is_empty() {
                    None
                } else {
                    Some(msg.clone())
                }
            })
            .or_else(|| self.tool_name.clone())
            .unwrap_or_default();
        let preview: String = preview_src.chars().take(120).collect();
        json!({
            "type": "hook_event",
            "session_id": self.session_id.clone().unwrap_or_default(),
            "event_id": self.event_id,
            "hook_event": self.hook_event,
            "notification_type": self.notification_type.clone().unwrap_or_default(),
            "notification_message": msg.chars().take(200).collect::<String>(),
            "tool_name": self.tool_name.clone().or_else(|| self.llm_tool_name.clone()).unwrap_or_default(),
            "needs_user": matches!(self.notification_type.as_deref(), Some("permission_prompt") | Some("ask_user_question")),
            "preview": preview,
            "ts": crate::wire_ts(&self.ts),
        })
    }
}

/// Append one row to the spool, fail-open. Returns the path written.
pub fn append_spool(spool_dir: &Path, row: &HookEvent) -> Result<PathBuf> {
    append_line(spool_dir, "hooks", &serde_json::to_value(row_value(row))?)
}

/// Spool a raw metric payload for the metrics ingester (`clipvault-ingest`, TODO).
pub fn append_metric_spool(spool_dir: &Path, payload: &Value) -> Result<PathBuf> {
    append_line(spool_dir, "metrics", payload)
}

fn append_line(spool_dir: &Path, prefix: &str, value: &Value) -> Result<PathBuf> {
    std::fs::create_dir_all(spool_dir)?;
    let day = Utc::now().format("%Y%m%d");
    let path = spool_dir.join(format!("{prefix}-{day}.jsonl"));
    let line = format!("{}\n", serde_json::to_string(value)?);
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .with_context(|| format!("open spool {}", path.display()))?;
    file.write_all(line.as_bytes())?;
    file.sync_all().ok();
    Ok(path)
}

/// Serialise a `HookEvent` back to the payload-shaped JSON the spool/flush use.
pub fn row_value(row: &HookEvent) -> Value {
    let mut m = Map::new();
    m.insert("event_id".into(), json!(row.event_id));
    m.insert("ts".into(), json!(crate::wire_ts(&row.ts)));
    m.insert("instance_id".into(), json!(row.instance_id));
    m.insert("session_id".into(), json!(row.session_id));
    m.insert("hook_event".into(), json!(row.hook_event));
    m.insert("source".into(), json!(row.source));
    m.insert("cwd".into(), json!(row.cwd));
    m.insert("workspace_roots".into(), json!(row.workspace_roots));
    m.insert("tool_name".into(), json!(row.tool_name));
    m.insert("llm_tool_name".into(), json!(row.llm_tool_name));
    m.insert("tool_use_id".into(), json!(row.tool_use_id));
    m.insert("prompt".into(), json!(row.prompt));
    m.insert("last_assistant_message".into(), json!(row.last_assistant_message));
    m.insert("notification_type".into(), json!(row.notification_type));
    m.insert("notification_message".into(), json!(row.notification_message));
    m.insert("stop_hook_active".into(), json!(row.stop_hook_active));
    m.insert("loop_count".into(), json!(row.loop_count));
    m.insert("tool_input".into(), json!(row.tool_input));
    m.insert("tool_response".into(), json!(row.tool_response));
    m.insert("raw_json".into(), json!(row.raw_json));
    m.insert("raw_hash".into(), json!(row.raw_hash));
    m.insert("host".into(), json!(row.host));
    m.insert("pid".into(), json!(row.pid));
    Value::Object(m)
}
