//! clipvault-aggregator: the client-side fan-in for session backends.
//!
//! It implements Session API v1 for the browser (so ClipVault keeps proxying
//! `/trae/*` to `127.0.0.1:9488`) while fanning out to registered backends:
//!
//!     browser -> ClipVault -> aggregator -> { d2 (primary), cc (replica) }
//!
//!   * within a `corpus_id`: fail over to the highest-priority healthy member
//!   * across corpora: merge `/api/sessions`
//!   * writes (`pin`, `ack`): route to the corpus's `role=primary` member
//!   * `/api/stream`: pass the SSE stream through from the winning member
//!
//! Transport (tunnels) is out of scope: each descriptor's `base_url` must be
//! reachable. The initiating host's tunnel panel owns that lifecycle.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use axum::body::Body;
use axum::extract::State;
use axum::http::{header, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use clipvault_session::config;
use clipvault_session::registry::{Backend, Registry};
use serde_json::{json, Value};

struct AppState {
    registry: Registry,
    client: reqwest::Client,
    health: Mutex<HashMap<String, (bool, Instant)>>,
    health_ttl: Duration,
    default_corpus: String,
}

type ApiError = (StatusCode, Json<Value>);

fn err(status: StatusCode, msg: &str) -> ApiError {
    (status, Json(json!({ "error": msg })))
}

fn main() -> anyhow::Result<()> {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;
    runtime.block_on(async_main())
}

async fn async_main() -> anyhow::Result<()> {
    let dir = std::path::PathBuf::from(config::var(
        "CLIPVAULT_BACKENDS_DIR",
        "~/.config/clipvault/backends.d",
    ));
    let dir = expand_home(dir);
    let registry = Registry::load(&dir);
    eprintln!(
        "clipvault-aggregator: {} backend(s), corpora {:?}",
        registry.backends.len(),
        registry.corpora()
    );
    let default_corpus = config::var("CLIPVAULT_AGG_DEFAULT_CORPUS", "")
        .trim()
        .to_string();
    let default_corpus = if default_corpus.is_empty() {
        registry.corpora().into_iter().next().unwrap_or_default()
    } else {
        default_corpus
    };
    let state = Arc::new(AppState {
        registry,
        client: reqwest::Client::builder()
            .timeout(Duration::from_secs(20))
            .build()?,
        health: Mutex::new(HashMap::new()),
        health_ttl: Duration::from_secs(
            config::var("CLIPVAULT_AGG_HEALTH_TTL_SEC", "3")
                .parse()
                .unwrap_or(3),
        ),
        default_corpus,
    });

    let router = Router::new()
        .route("/api/health", get(health))
        .route("/api/sessions", get(sessions))
        .route("/api/events", get(proxy_get))
        .route("/api/event", get(proxy_get))
        .route("/api/mine", get(proxy_get))
        .route("/api/stream", get(stream))
        .route("/api/sessions/pin", post(proxy_post))
        .route("/api/mine/ack", post(proxy_post))
        .route("/api/notify", post(proxy_post))
        .fallback(get(proxy_get))
        .with_state(state.clone());

    let host = config::var("CLIPVAULT_AGG_HTTP_HOST", "127.0.0.1");
    let port = config::var("CLIPVAULT_AGG_HTTP_PORT", "9488");
    let addr = format!("{host}:{port}");
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    eprintln!("clipvault-aggregator: listening on {addr}");
    axum::serve(listener, router).await?;
    Ok(())
}

fn expand_home(path: std::path::PathBuf) -> std::path::PathBuf {
    let s = path.to_string_lossy();
    if let Some(rest) = s.strip_prefix("~/") {
        if let Ok(home) = std::env::var("HOME") {
            return std::path::PathBuf::from(home).join(rest);
        }
    }
    path
}

async fn is_healthy(st: &AppState, backend: &Backend) -> bool {
    if let Ok(cache) = st.health.lock() {
        if let Some((ok, at)) = cache.get(&backend.id) {
            if at.elapsed() < st.health_ttl {
                return *ok;
            }
        }
    }
    let ok = st
        .client
        .get(format!("{}/api/health", backend.base_url))
        .timeout(Duration::from_millis(1500))
        .send()
        .await
        .map(|r| r.status().is_success())
        .unwrap_or(false);
    if let Ok(mut cache) = st.health.lock() {
        cache.insert(backend.id.clone(), (ok, Instant::now()));
    }
    ok
}

/// Highest-priority healthy member of a corpus. Falls back to the highest
/// priority member when none probe healthy, so the upstream error surfaces
/// instead of a synthetic 503.
async fn winner(st: &AppState, corpus: &str) -> Option<Backend> {
    let mut members: Vec<Backend> = st.registry.members(corpus).into_iter().cloned().collect();
    members.sort_by(|a, b| b.priority.cmp(&a.priority));
    for backend in &members {
        if is_healthy(st, backend).await {
            return Some(backend.clone());
        }
    }
    members.into_iter().next()
}

fn primary(st: &AppState, corpus: &str) -> Option<Backend> {
    st.registry
        .members(corpus)
        .into_iter()
        .filter(|b| b.is_primary())
        .max_by_key(|b| b.priority)
        .cloned()
        .or_else(|| st.registry.members(corpus).into_iter().next().cloned())
}

// ------------------------------------------------------------- health ----

async fn health(State(st): State<Arc<AppState>>) -> Json<Value> {
    let mut backends = Vec::new();
    let mut winners = serde_json::Map::new();
    for backend in &st.registry.backends {
        backends.push(json!({
            "id": backend.id,
            "label": backend.label,
            "corpus_id": backend.corpus_id,
            "role": backend.role,
            "priority": backend.priority,
            "base_url": backend.base_url,
            "healthy": is_healthy(&st, backend).await,
        }));
    }
    let mut events = Value::Null;
    let mut last_ts = Value::Null;
    for corpus in st.registry.corpora() {
        if let Some(w) = winner(&st, &corpus).await {
            winners.insert(corpus.clone(), json!(w.id));
            // Surface the default corpus winner's event count / last_ts so the
            // health line keeps the pre-aggregator contract.
            if corpus == st.default_corpus {
                if let Ok(resp) = st
                    .client
                    .get(format!("{}/api/health", w.base_url))
                    .timeout(Duration::from_millis(1500))
                    .send()
                    .await
                {
                    if let Ok(v) = resp.json::<Value>().await {
                        events = v.get("events").cloned().unwrap_or(Value::Null);
                        last_ts = v.get("last_ts").cloned().unwrap_or(Value::Null);
                    }
                }
            }
        }
    }
    Json(json!({
        "ok": true,
        "service": "clipvault-aggregator",
        "default_corpus": st.default_corpus,
        "events": events,
        "last_ts": last_ts,
        "backends": backends,
        "winners": winners,
    }))
}

// ----------------------------------------------------------- sessions ----

async fn sessions(
    State(st): State<Arc<AppState>>,
    axum::extract::Query(q): axum::extract::Query<HashMap<String, String>>,
) -> Result<Json<Value>, ApiError> {
    let limit: usize = q
        .get("limit")
        .and_then(|v| v.parse().ok())
        .unwrap_or(50)
        .clamp(1, 200);
    let mut all: Vec<Value> = Vec::new();
    for corpus in st.registry.corpora() {
        let Some(b) = winner(&st, &corpus).await else {
            continue;
        };
        let url = format!("{}/api/sessions?limit={limit}", b.base_url);
        let Ok(resp) = st.client.get(url).send().await else {
            continue;
        };
        let Ok(body) = resp.json::<Value>().await else {
            continue;
        };
        if let Some(rows) = body.get("sessions").and_then(Value::as_array) {
            for row in rows {
                let mut row = row.clone();
                if let Some(obj) = row.as_object_mut() {
                    obj.insert("backend_id".into(), json!(b.id));
                    obj.insert("corpus_id".into(), json!(corpus));
                }
                all.push(row);
            }
        }
    }
    all.sort_by(|a, b| {
        let ka = a.get("last_ts").and_then(Value::as_str).unwrap_or("");
        let kb = b.get("last_ts").and_then(Value::as_str).unwrap_or("");
        kb.cmp(ka)
    });
    all.truncate(limit);
    Ok(Json(json!({ "sessions": all })))
}

// ------------------------------------------------------------ proxies ----

/// Read endpoints are corpus-scoped by query. We route to the winning member of
/// the corpus that owns the referenced session, falling back to the default
/// corpus. With one corpus this is a single upstream call.
async fn proxy_get(
    State(st): State<Arc<AppState>>,
    method: axum::http::Method,
    uri: axum::http::Uri,
) -> Response {
    let corpus = corpus_for_query(&st, uri.query());
    let Some(b) = winner(&st, &corpus).await else {
        return err(StatusCode::SERVICE_UNAVAILABLE, "no backend").into_response();
    };
    let url = format!(
        "{}{}",
        b.base_url,
        uri.path_and_query().map(|p| p.as_str()).unwrap_or("/")
    );
    forward(
        &st,
        reqwest::Method::from_bytes(method.as_str().as_bytes()).unwrap(),
        &url,
        None,
    )
    .await
}

async fn proxy_post(
    State(st): State<Arc<AppState>>,
    uri: axum::http::Uri,
    body: axum::body::Bytes,
) -> Response {
    // Writes must reach a primary. Determine the corpus from the session id when
    // present, otherwise use the default corpus.
    let corpus = corpus_for_query(&st, uri.query());
    let Some(b) = primary(&st, &corpus) else {
        return err(StatusCode::SERVICE_UNAVAILABLE, "no primary backend").into_response();
    };
    let url = format!(
        "{}{}",
        b.base_url,
        uri.path_and_query().map(|p| p.as_str()).unwrap_or("/")
    );
    forward(&st, reqwest::Method::POST, &url, Some(body)).await
}

async fn forward(
    st: &AppState,
    method: reqwest::Method,
    url: &str,
    body: Option<axum::body::Bytes>,
) -> Response {
    let mut req = st.client.request(method, url);
    if let Some(bytes) = body {
        req = req.header("content-type", "application/json").body(bytes);
    }
    match req.send().await {
        Ok(resp) => {
            let status =
                StatusCode::from_u16(resp.status().as_u16()).unwrap_or(StatusCode::BAD_GATEWAY);
            let content_type = resp
                .headers()
                .get(reqwest::header::CONTENT_TYPE)
                .cloned()
                .unwrap_or_else(|| HeaderValue::from_static("application/json; charset=utf-8"));
            match resp.bytes().await {
                Ok(bytes) => {
                    (status, [(header::CONTENT_TYPE, content_type)], bytes).into_response()
                }
                Err(e) => err(StatusCode::BAD_GATEWAY, &e.to_string()).into_response(),
            }
        }
        Err(e) => err(StatusCode::BAD_GATEWAY, &format!("upstream: {e}")).into_response(),
    }
}

/// SSE pass-through from the default corpus winner.
async fn stream(State(st): State<Arc<AppState>>) -> Response {
    let Some(b) = winner(&st, &st.default_corpus).await else {
        return err(StatusCode::SERVICE_UNAVAILABLE, "no backend").into_response();
    };
    let url = format!("{}/api/stream", b.base_url);
    match st.client.get(url).send().await {
        Ok(resp) if resp.status().is_success() => Response::builder()
            .status(StatusCode::OK)
            .header(header::CONTENT_TYPE, "text/event-stream; charset=utf-8")
            .header(header::CACHE_CONTROL, "no-cache, no-transform")
            .header(header::CONNECTION, "keep-alive")
            .body(Body::from_stream(resp.bytes_stream()))
            .unwrap_or_else(|_| err(StatusCode::BAD_GATEWAY, "stream").into_response()),
        Ok(resp) => err(
            StatusCode::from_u16(resp.status().as_u16()).unwrap_or(StatusCode::BAD_GATEWAY),
            "upstream stream",
        )
        .into_response(),
        Err(e) => err(StatusCode::BAD_GATEWAY, &format!("upstream: {e}")).into_response(),
    }
}

/// Corpus routing hint. Today the client sends `session_id` (default corpus) or
/// nothing; the default corpus applies to both.
fn corpus_for_query(st: &AppState, _query: Option<&str>) -> String {
    st.default_corpus.clone()
}
