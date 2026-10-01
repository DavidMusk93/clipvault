//! Session API v1 (SA-v1): read plane + SSE + pin/ack. Stateless w.r.t. storage.

use std::collections::BTreeMap;
use std::convert::Infallible;
use std::path::PathBuf;
use std::time::Duration;

use axum::extract::{Query, State};
use axum::http::StatusCode;
use axum::response::sse::{Event, KeepAlive, Sse};
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::{Json, Router};
use futures::stream::Stream;
use serde_json::{json, Map, Value};
use tokio::sync::broadcast;
use tokio_postgres::types::ToSql;
use tokio_stream::wrappers::BroadcastStream;
use tokio_stream::StreamExt as _;

use crate::db::{self, Pool};

const EVENT_LIST_SQL: &str = "SELECT event_id, ts, instance_id, session_id, hook_event, source, \
    cwd, tool_name, llm_tool_name, tool_use_id, prompt, last_assistant_message, \
    notification_type, notification_message, loop_count, raw_hash \
    FROM hook_events";

#[derive(Clone)]
pub struct AppState {
    pub pool: Pool,
    pub backend_id: String,
    pub corpus_id: String,
    pub role: String,
    pub store_label: String,
    pub tx: broadcast::Sender<Value>,
    pub web_dirs: Vec<PathBuf>,
}

type ApiError = (StatusCode, Json<Value>);

fn err(status: StatusCode, msg: &str) -> ApiError {
    (status, Json(json!({ "error": msg })))
}

fn internal(e: impl std::fmt::Display) -> ApiError {
    err(StatusCode::INTERNAL_SERVER_ERROR, &e.to_string())
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/healthz", get(health))
        .route("/api/health", get(health))
        .route("/api/sessions", get(sessions))
        .route("/api/events", get(events))
        .route("/api/event", get(event_by_id))
        .route("/api/stream", get(stream))
        .route("/api/sessions/pin", post(pin))
        .route("/api/mine", get(mine))
        .route("/api/mine/ack", post(ack))
        .route("/api/notify", post(notify))
        .fallback(get(static_asset))
        .with_state(state)
}

// ---------------------------------------------------------------- health ----

async fn health(State(st): State<AppState>) -> Result<Json<Value>, ApiError> {
    let client = st.pool.get().await.map_err(internal)?;
    let row = client
        .query_one("SELECT count(*) AS events, max(ts) AS last_ts FROM hook_events", &[])
        .await
        .map_err(internal)?;
    let events: i64 = row.get("events");
    let last_ts: Option<chrono::DateTime<chrono::Utc>> = row.get("last_ts");
    let version: String = client
        .query_one("SHOW server_version", &[])
        .await
        .map_err(internal)?
        .get(0);
    Ok(Json(json!({
        "ok": true,
        "service": "clipvault-session",
        "backend_id": st.backend_id,
        "role": st.role,
        "corpus_id": st.corpus_id,
        "store": { "engine": "postgresql", "database": st.store_label },
        "pg": version,
        "events": events,
        "last_ts": last_ts.as_ref().map(crate::wire_ts),
    })))
}

// -------------------------------------------------------------- sessions ----

async fn sessions(
    State(st): State<AppState>,
    Query(q): Query<BTreeMap<String, String>>,
) -> Result<Json<Value>, ApiError> {
    let limit: i64 = q
        .get("limit")
        .and_then(|v| v.parse().ok())
        .unwrap_or(50)
        .clamp(1, 200);
    let client = st.pool.get().await.map_err(internal)?;
    let sql = "SELECT s.session_id, s.first_ts, s.last_ts, s.event_count, s.hook_kinds, \
        s.cwd, s.instance_id, s.source, s.last_prompt, p.pinned_at \
        FROM ( \
            SELECT session_id, \
                   min(ts) AS first_ts, \
                   max(ts) AS last_ts, \
                   count(*) AS event_count, \
                   count(DISTINCT hook_event) AS hook_kinds, \
                   (array_agg(cwd ORDER BY ts DESC))[1] AS cwd, \
                   (array_agg(instance_id ORDER BY ts DESC))[1] AS instance_id, \
                   (array_agg(source ORDER BY ts DESC))[1] AS source, \
                   (array_agg(prompt ORDER BY ts DESC) FILTER (WHERE coalesce(prompt,'') <> ''))[1] AS last_prompt \
            FROM hook_events \
            GROUP BY session_id \
        ) s \
        LEFT JOIN session_pins p ON p.session_id = s.session_id \
        ORDER BY (p.pinned_at IS NULL) ASC, p.pinned_at DESC, s.last_ts DESC \
        LIMIT $1";
    let rows = client.query(sql, &[&limit]).await.map_err(internal)?;
    let out: Vec<Value> = rows.iter().map(db::row_to_value).collect();
    Ok(Json(json!({ "sessions": out })))
}

// ---------------------------------------------------------------- events ----

async fn events(
    State(st): State<AppState>,
    Query(q): Query<BTreeMap<String, String>>,
) -> Result<Json<Value>, ApiError> {
    let g = |k: &str| q.get(k).cloned().unwrap_or_default();
    let session_id = g("session_id");
    let hook_event = g("hook_event");
    let search = g("q");
    let view = g("view");
    let limit: i64 = q
        .get("limit")
        .and_then(|v| v.parse().ok())
        .unwrap_or(200)
        .clamp(1, 500);
    let client = st.pool.get().await.map_err(internal)?;

    if !session_id.is_empty() && hook_event.is_empty() && search.is_empty() {
        let mut beats: Vec<Value> = vec![];
        let mut tools: Vec<Value> = vec![];
        if view != "tools" {
            let sql = "SELECT event_id, ts, instance_id, session_id, hook_event, source, cwd, \
                tool_name, llm_tool_name, tool_use_id, prompt, last_assistant_message, \
                notification_type, notification_message, loop_count, tool_input, tool_response, raw_hash \
                FROM hook_events WHERE session_id = $1 AND (hook_event IN \
                ('UserPromptSubmit','Stop','Notification') OR tool_name = 'AskUserQuestion' \
                OR llm_tool_name = 'AskUserQuestion') ORDER BY ts ASC";
            let rows = client.query(sql, &[&session_id]).await.map_err(internal)?;
            beats = rows.iter().map(db::row_to_value).collect();
        }
        if view != "beats" {
            let sql = "SELECT event_id, ts, session_id, hook_event, tool_name, llm_tool_name, tool_use_id \
                FROM hook_events WHERE session_id = $1 AND hook_event IN ('PreToolUse','PostToolUse') \
                AND coalesce(tool_name,'') <> 'AskUserQuestion' AND coalesce(llm_tool_name,'') <> 'AskUserQuestion' \
                ORDER BY ts ASC";
            let rows = client.query(sql, &[&session_id]).await.map_err(internal)?;
            tools = index_session_tools(&rows.iter().map(db::row_to_value).collect::<Vec<_>>());
        }
        let mut seen = std::collections::HashSet::new();
        let mut out = Vec::with_capacity(beats.len() + tools.len());
        for item in beats.into_iter().chain(tools.into_iter()) {
            let eid = item
                .get("event_id")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string();
            if seen.insert(eid) {
                out.push(item);
            }
        }
        return Ok(Json(json!({ "events": out, "view": if view.is_empty() { "full" } else { &view } })));
    }

    let mut where_parts: Vec<String> = vec!["1=1".into()];
    let mut owned: Vec<Box<dyn ToSql + Send + Sync>> = Vec::new();
    if !session_id.is_empty() {
        owned.push(Box::new(session_id.clone()));
        where_parts.push(format!("session_id = ${}", owned.len()));
    }
    if !hook_event.is_empty() {
        owned.push(Box::new(hook_event.clone()));
        where_parts.push(format!("hook_event = ${}", owned.len()));
    }
    if !search.is_empty() {
        let like = format!("%{search}%");
        owned.push(Box::new(like.clone()));
        let i = owned.len();
        where_parts.push(format!(
            "(coalesce(prompt,'') ILIKE ${i} OR coalesce(tool_name,'') ILIKE ${i} \
             OR coalesce(last_assistant_message,'') ILIKE ${i} OR coalesce(raw_json,'') ILIKE ${i})"
        ));
    }
    owned.push(Box::new(limit));
    let limit_idx = owned.len();
    let sql = format!(
        "{} WHERE {} ORDER BY ts DESC LIMIT ${limit_idx}",
        EVENT_LIST_SQL,
        where_parts.join(" AND ")
    );
    let refs: Vec<&(dyn ToSql + Sync)> = owned
        .iter()
        .map(|b| b.as_ref() as &(dyn ToSql + Sync))
        .collect();
    let rows = client.query(&sql, &refs).await.map_err(internal)?;
    let out: Vec<Value> = rows.iter().map(db::row_to_value).collect();
    Ok(Json(json!({ "events": out })))
}

fn index_session_tools(rows: &[Value]) -> Vec<Value> {
    let keys = [
        "event_id",
        "ts",
        "session_id",
        "hook_event",
        "tool_name",
        "llm_tool_name",
        "tool_use_id",
    ];
    let posted: std::collections::HashSet<String> = rows
        .iter()
        .filter(|r| r.get("hook_event").and_then(Value::as_str) == Some("PostToolUse"))
        .filter_map(|r| r.get("tool_use_id").and_then(Value::as_str).map(str::to_string))
        .collect();
    let mut out = Vec::new();
    for row in rows {
        let is_pre = row.get("hook_event").and_then(Value::as_str) == Some("PreToolUse");
        let tuid = row.get("tool_use_id").and_then(Value::as_str).unwrap_or_default();
        if is_pre && !tuid.is_empty() && posted.contains(tuid) {
            continue;
        }
        let mut m = Map::new();
        for k in keys {
            m.insert(k.to_string(), row.get(k).cloned().unwrap_or(Value::Null));
        }
        out.push(Value::Object(m));
    }
    out
}

async fn event_by_id(
    State(st): State<AppState>,
    Query(q): Query<BTreeMap<String, String>>,
) -> Result<Json<Value>, ApiError> {
    let id = q.get("id").cloned().unwrap_or_default();
    if id.is_empty() {
        return Err(err(StatusCode::BAD_REQUEST, "id required"));
    }
    let full = matches!(q.get("full").map(String::as_str), Some("1") | Some("true"));
    let client = st.pool.get().await.map_err(internal)?;
    let rows = client
        .query("SELECT * FROM hook_events WHERE event_id = $1 LIMIT 1", &[&id])
        .await
        .map_err(internal)?;
    let Some(row) = rows.first() else {
        return Err(err(StatusCode::NOT_FOUND, "not found"));
    };
    let mut value = db::row_to_value(row);
    if !full {
        if let Some(obj) = value.as_object_mut() {
            let mut truncated = false;
            for key in ["raw_json", "tool_input", "tool_response"] {
                if let Some(Value::String(s)) = obj.get(key).cloned() {
                    if s.chars().count() > 16000 {
                        let head: String = s.chars().take(16000).collect();
                        obj.insert(key.into(), Value::String(format!("{head}\n/* truncated */")));
                        truncated = true;
                    }
                }
            }
            if truncated {
                obj.insert("raw_truncated".into(), Value::Bool(true));
            }
        }
    }
    Ok(Json(json!({ "event": value })))
}

// ------------------------------------------------------------------ SSE ----

async fn stream(
    State(st): State<AppState>,
) -> Sse<impl Stream<Item = Result<Event, Infallible>>> {
    let rx = st.tx.subscribe();
    let stream = BroadcastStream::new(rx).filter_map(|item| match item {
        Ok(v) => Some(Ok(Event::default().data(v.to_string()))),
        Err(_) => None,
    });
    Sse::new(stream).keep_alive(
        KeepAlive::new()
            .interval(Duration::from_secs(15))
            .text("ping"),
    )
}

async fn notify(State(st): State<AppState>, Json(mut body): Json<Value>) -> Json<Value> {
    if let Some(obj) = body.as_object_mut() {
        obj.entry("type").or_insert_with(|| json!("hook_event"));
        let needs = obj
            .get("needs_user")
            .and_then(Value::as_bool)
            .unwrap_or(false)
            || matches!(
                obj.get("notification_type").and_then(Value::as_str),
                Some("permission_prompt") | Some("ask_user_question")
            );
        obj.insert("needs_user".into(), Value::Bool(needs));
    }
    let _ = st.tx.send(body);
    Json(json!({ "ok": true }))
}

// ----------------------------------------------------------------- pins ----

async fn pin(
    State(st): State<AppState>,
    Json(body): Json<Value>,
) -> Result<Json<Value>, ApiError> {
    let sid = body
        .get("session_id")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim()
        .chars()
        .take(200)
        .collect::<String>();
    if sid.is_empty() {
        return Err(err(StatusCode::BAD_REQUEST, "session_id required"));
    }
    let want = match body.get("pinned") {
        Some(Value::Bool(b)) => Some(*b),
        None | Some(Value::Null) => None,
        _ => return Err(err(StatusCode::BAD_REQUEST, "pinned must be bool")),
    };
    let client = st.pool.get().await.map_err(internal)?;
    let have = client
        .query_opt("SELECT 1 FROM session_pins WHERE session_id = $1", &[&sid])
        .await
        .map_err(internal)?
        .is_some();
    let want = want.unwrap_or(!have);
    if want {
        client
            .execute(
                "INSERT INTO session_pins (session_id, pinned_at) VALUES ($1, now()) \
                 ON CONFLICT (session_id) DO UPDATE SET pinned_at = excluded.pinned_at",
                &[&sid],
            )
            .await
            .map_err(internal)?;
    } else {
        client
            .execute("DELETE FROM session_pins WHERE session_id = $1", &[&sid])
            .await
            .map_err(internal)?;
    }
    let pinned_at: Option<chrono::DateTime<chrono::Utc>> = if want {
        client
            .query_one("SELECT pinned_at FROM session_pins WHERE session_id = $1", &[&sid])
            .await
            .map_err(internal)?
            .get(0)
    } else {
        None
    };
    let result = json!({
        "ok": true,
        "session_id": sid,
        "pinned": want,
        "pinned_at": pinned_at.as_ref().map(crate::wire_ts),
    });
    let _ = st.tx.send(json!({
        "type": "session_pinned",
        "session_id": sid,
        "pinned": want,
        "pinned_at": pinned_at.as_ref().map(crate::wire_ts),
    }));
    Ok(Json(result))
}

// ----------------------------------------------------------- analysis (TODO) ----

async fn mine(Query(q): Query<BTreeMap<String, String>>) -> Json<Value> {
    if matches!(q.get("catalog").map(String::as_str), Some("1") | Some("true")) {
        return Json(json!({ "directions": DIRECTIONS }));
    }
    Json(json!({
        "ok": false,
        "error": "mine not yet ported to rust (Phase 2 follow-up)",
    }))
}

async fn ack(Json(_body): Json<Value>) -> Json<Value> {
    Json(json!({ "ok": false, "error": "ack not yet ported to rust" }))
}

const DIRECTIONS: &[&str] = &[
    "cwd", "git", "taste", "intent", "reminder", "flow", "file", "tool", "failure", "hot", "mcp", "phase",
];

// -------------------------------------------------------------- static ----

async fn static_asset(
    State(st): State<AppState>,
    uri: axum::http::Uri,
) -> Result<impl IntoResponse, ApiError> {
    let path = uri.path();
    let name = path.trim_start_matches('/');
    let target = if name.is_empty() || name == "trae" || name == "sessions" {
        "sessions.html"
    } else {
        name
    };
    if target.contains("..") {
        return Err(err(StatusCode::NOT_FOUND, "not found"));
    }
    for root in &st.web_dirs {
        let candidate = root.join(target);
        if let Ok(bytes) = tokio::fs::read(&candidate).await {
            let ctype = match candidate.extension().and_then(|e| e.to_str()) {
                Some("html") => "text/html; charset=utf-8",
                Some("js") | Some("mjs") => "text/javascript; charset=utf-8",
                Some("css") => "text/css; charset=utf-8",
                Some("map") => "application/json; charset=utf-8",
                _ => "application/octet-stream",
            };
            return Ok(([(axum::http::header::CONTENT_TYPE, ctype)], bytes));
        }
    }
    Err(err(StatusCode::NOT_FOUND, "not found"))
}
