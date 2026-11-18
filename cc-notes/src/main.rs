//! clipvault-notes — cc 侧笔记/记忆层 facade（D1 骨架）。
//!
//! 设计：`docs/design-cc-memory-layer.md`。内嵌 notebase 引擎（Rust 原生，
//! 无 FFI 跨界），API 与 mac `/api/notes*` 同形状，鉴权 Bearer token。
//! 写入 = notebase delta oplog（无整篇副本堆积）；幂等台账走 vault_meta
//! `opid:<id>`（重启不丢）。trx 双向同步属 D2，不在本骨架。

use std::sync::{Arc, Mutex};

use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::{Json, Router};
use serde::Deserialize;
use serde_json::{json, Value};

use notebase_store::Vault;

struct App {
    vault: Mutex<Vault>,
    token: String,
}

#[derive(Debug)]
struct AppError {
    status: StatusCode,
    message: String,
}

impl AppError {
    fn bad(msg: impl Into<String>) -> Self {
        AppError { status: StatusCode::BAD_REQUEST, message: msg.into() }
    }
    fn not_found(msg: impl Into<String>) -> Self {
        AppError { status: StatusCode::NOT_FOUND, message: msg.into() }
    }
    fn internal(msg: impl Into<String>) -> Self {
        AppError { status: StatusCode::INTERNAL_SERVER_ERROR, message: msg.into() }
    }
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        (self.status, Json(json!({ "ok": false, "message": self.message }))).into_response()
    }
}

type AppResult<T> = Result<T, AppError>;

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct ListQuery {
    q: Option<String>,
    limit: Option<usize>,
    offset: Option<usize>,
    tag: Option<String>,
    since: Option<f64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SaveNoteBody {
    body: String,
    title: Option<String>,
    id: Option<String>,
    op_id: Option<String>,
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

/// 在 spawn_blocking 里跑阻塞的 sqlite/loro 工作，std::Mutex 不越 await。
async fn with_vault<T, F>(app: Arc<App>, f: F) -> AppResult<T>
where
    T: Send + 'static,
    F: FnOnce(&Vault) -> notebase_store::Result<T> + Send + 'static,
{
    tokio::task::spawn_blocking(move || {
        let vault = app
            .vault
            .lock()
            .map_err(|_| AppError::internal("vault poisoned"))?;
        f(&vault).map_err(|e| AppError::internal(e.to_string()))
    })
    .await
    .map_err(|e| AppError::internal(e.to_string()))?
}

/// mac `/api/notes*` 同形状的 item head（textContent 只在单篇读取时给全文）。
fn item_json(id: &str, title: &str, created_at: i64, updated_at: i64, markdown: Option<String>) -> Value {
    let mut item = json!({
        "id": id,
        "type": "note",
        "title": title,
        "timestamp": updated_at as f64,
        "createdAt": created_at as f64,
        "editCount": 0,
        "pinnedAt": Value::Null,
        "inTrash": false,
    });
    if let Some(md) = markdown {
        item["textContent"] = Value::String(md);
    }
    item
}

async fn meta(State(_state): State<Arc<App>>) -> Json<Value> {
    Json(json!({
        "ok": true,
        "api": "clipvault-notes",
        "host": "cc",
        "version": "d1",
        "endpoints": {
            "POST /api/notes": "create/update a note (body required; id to update; opId idempotent)",
            "GET /api/notes": "list notes (?q= fts, ?limit=, ?offset=)",
            "GET /api/notes/{id}": "single note (markdown projection)",
            "GET /api/notes/_meta": "this capability list",
        },
    }))
}

async fn list_notes(
    State(state): State<Arc<App>>,
    Query(q): Query<ListQuery>,
) -> AppResult<Json<Value>> {
    if q.tag.is_some() || q.since.is_some() {
        // D1 子集：tag/since 属 D3（note_tags 投影与 since 游标）。
        return Err(AppError::bad("tag/since not available in d1"));
    }
    let limit = q.limit.unwrap_or(50).min(200);
    let offset = q.offset.unwrap_or(0);
    let query = q.q;
    let notes = with_vault(state.clone(), move |vault| match query.as_deref() {
        Some(qs) if !qs.trim().is_empty() => vault
            .search(qs.trim(), limit)
            .map(|hits| {
                hits.into_iter()
                    .map(|h| json!({ "id": h.note_id, "title": h.title, "preview": h.snippet }))
                    .collect::<Vec<_>>()
            })
            .map_err(|e| e),
        _ => vault.list(limit, offset).map(|rows| {
            rows.into_iter()
                .map(|n| {
                    json!({
                        "id": n.id,
                        "title": n.title,
                        "createdAt": n.created_at,
                        "updatedAt": n.updated_at,
                        "saves": n.saves,
                    })
                })
                .collect::<Vec<_>>()
        }),
    })
    .await?;
    Ok(Json(json!({ "ok": true, "count": notes.len(), "notes": notes })))
}

type LoadedNote = (String, String, i64, i64, String);

fn load_full(vault: &Vault, id: &str) -> notebase_store::Result<Option<LoadedNote>> {
    Ok(vault.load(id)?.map(|doc| {
        (
            doc.id(),
            doc.title(),
            doc.created_at().unwrap_or(0),
            doc.updated_at().unwrap_or(0),
            doc.to_markdown(),
        )
    }))
}

async fn show_note(
    State(state): State<Arc<App>>,
    Path(id): Path<String>,
) -> AppResult<Json<Value>> {
    let out = with_vault(state.clone(), move |vault| load_full(vault, &id)).await?;
    match out {
        None => Err(AppError::not_found("笔记不存在")),
        Some((id, title, created, updated, markdown)) => Ok(Json(json!({
            "ok": true,
            "item": item_json(&id, &title, created, updated, Some(markdown)),
            "tags": [],
        }))),
    }
}

async fn save_note(
    State(state): State<Arc<App>>,
    Json(body): Json<SaveNoteBody>,
) -> AppResult<Json<Value>> {
    if body.body.trim().is_empty() {
        return Err(AppError::bad("expected {body}"));
    }

    // 幂等：同 opId 已接受过 → 返回那篇现状，不再写。台账在 vault_meta，
    // 重启不丢（mac 侧用 agent_note_ops 表，cc 侧复用引擎自带 kv）。
    if let Some(op_id) = body.op_id.clone().filter(|s| !s.is_empty() && s.chars().count() <= 128) {
        let existing = with_vault(state.clone(), move |vault| {
            vault
                .store()
                .vault_meta(&format!("opid:{op_id}"))
                .map(|opt| opt.map(|item_id| item_id))
        })
        .await?;
        if let Some(item_id) = existing {
            if let Some((id, title, created, updated, markdown)) =
                with_vault(state.clone(), move |vault| load_full(vault, &item_id)).await?
            {
                return Ok(Json(json!({
                    "ok": true,
                    "idempotent": true,
                    "item": item_json(&id, &title, created, updated, Some(markdown)),
                })));
            }
            // 台账命中但笔记已消失 → 继续正常写（重放重建）。
        }
    }

    let out = with_vault(state.clone(), move |vault| {
        let now = now_ms();
        let (id, title, created, updated, created_new) = match body.id.as_deref() {
            Some(id) => {
                let doc = vault
                    .load(id)?
                    .ok_or_else(|| notebase_store::Error::NotFound(id.to_string()))?;
                if let Some(title) = &body.title {
                    doc.set_title(title);
                }
                doc.set_markdown(&body.body)?;
                vault.save_and_index(&doc)?;
                (
                    doc.id(),
                    doc.title(),
                    doc.created_at().unwrap_or(now),
                    doc.updated_at().unwrap_or(now),
                    false,
                )
            }
            None => {
                let doc = vault.import_markdown(&body.body)?;
                if let Some(title) = &body.title {
                    doc.set_title(title);
                    vault.save_and_index(&doc)?;
                }
                (
                    doc.id(),
                    doc.title(),
                    doc.created_at().unwrap_or(now),
                    doc.updated_at().unwrap_or(now),
                    true,
                )
            }
        };
        if let Some(op_id) = body.op_id.as_deref().filter(|s| !s.is_empty()) {
            vault.store().set_vault_meta(&format!("opid:{op_id}"), id.as_str())?;
        }
        notebase_store::Result::Ok((id, title, created, updated, created_new))
    })
    .await?;
    let (id, title, created, updated, created_new) = out;
    Ok(Json(json!({
        "ok": true,
        "created": created_new,
        "item": item_json(&id, &title, created, updated, None),
    })))
}

async fn auth(
    State(state): State<Arc<App>>,
    req: axum::extract::Request,
    next: Next,
) -> Response {
    let ok = req
        .headers()
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .map(|t| constant_eq(t, &state.token))
        .unwrap_or(false);
    if !ok {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({ "error": "unauthorized" })),
        )
            .into_response();
    }
    next.run(req).await
}

fn constant_eq(a: &str, b: &str) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.bytes().zip(b.bytes()).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

#[tokio::main]
async fn main() {
    let home = std::env::var("CLIPVAULT_NOTES_HOME").unwrap_or_else(|_| "./cc-notes-data".into());
    std::fs::create_dir_all(&home).expect("create notes home");
    let token = match std::env::var("CLIPVAULT_NOTES_TOKEN") {
        Ok(t) if !t.trim().is_empty() => t.trim().to_string(),
        _ => {
            let path = std::path::Path::new(&home).join("token");
            std::fs::read_to_string(&path)
                .map(|t| t.trim().to_string())
                .ok()
                .filter(|t| !t.is_empty())
                .expect("no token: CLIPVAULT_NOTES_TOKEN env or <home>/token file")
        }
    };
    let vault = Vault::open(std::path::Path::new(&home).join("notes.vault"))
        .expect("open notebase vault");
    let port: u16 = std::env::var("CLIPVAULT_NOTES_PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(9490);
    let state = Arc::new(App {
        vault: Mutex::new(vault),
        token,
    });

    let app = Router::new()
        .route("/api/notes/_meta", get(meta))
        .route("/api/notes", get(list_notes).post(save_note))
        .route("/api/notes/{id}", get(show_note))
        .layer(middleware::from_fn_with_state(state.clone(), auth))
        .with_state(state);

    let addr = std::net::SocketAddr::from(([127, 0, 0, 1], port));
    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .expect("bind 127.0.0.1 notes port");
    println!("[clipvault-notes] listening on {addr} (d1)");
    axum::serve(listener, app).await.expect("serve");
}
