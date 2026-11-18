//! clipvault-notes — cc 侧笔记/记忆层 facade（D1 骨架）。
//!
//! 设计：`docs/designs/design-cc-memory-layer.md`。内嵌 notebase 引擎（Rust 原生，
//! 无 FFI 跨界），API 与 mac `/api/notes*` 同形状，鉴权 Bearer token。
//! 写入 = notebase delta oplog（无整篇副本堆积）；幂等台账走 vault_meta
//! `opid:<id>`（重启不丢）。trx 双向同步属 D2，不在本骨架。

mod blobs;
mod links;
mod sync;
mod tags;

use std::sync::{Arc, Mutex};

use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use axum::extract::DefaultBodyLimit;
use serde::Deserialize;
use serde_json::{json, Value};

use notebase_store::Vault;

/// agent 参考文档自举：编译期嵌入仓库 docs/references/agent-api-v1.md，
/// agent 从服务本身拉取（GET /api/notes/_doc），不必找仓库。
const AGENT_USAGE_DOC: &str = include_str!("../../docs/references/agent-api-v1.md");

/// 多 agent 身份面：tokens.json = [{"name":"pi","token":"<hex>"}, ...]。
/// 命中任意活跃 token 即授权；identity = token name（agent:<name> 归因）。
/// 文件每次鉴权即时读取（小文件，运维改完即生效，无需重启）。
struct TokenRegistry {
    tokens: Vec<(String, String)>, // (name, token)
}

impl TokenRegistry {
    fn load(path: Option<&std::path::Path>) -> TokenRegistry {
        let mut tokens: Vec<(String, String)> = Vec::new();
        if let Some(p) = path {
            if let Ok(raw) = std::fs::read_to_string(p) {
                if let Ok(v) = serde_json::from_str::<Vec<serde_json::Value>>(&raw) {
                    for e in v {
                        let name = e.get("name").and_then(|x| x.as_str()).unwrap_or("").trim().to_string();
                        let token = e.get("token").and_then(|x| x.as_str()).unwrap_or("").trim().to_string();
                        if !name.is_empty() && !token.is_empty() {
                            tokens.push((name, token));
                        }
                    }
                }
            }
        }
        TokenRegistry { tokens }
    }

    /// 返回命中的 agent 身份名。
    fn identify(&self, presented: &str) -> Option<String> {
        self.tokens
            .iter()
            .find(|(_, t)| constant_eq(presented, t))
            .map(|(n, _)| n.clone())
    }

    fn is_empty(&self) -> bool {
        self.tokens.is_empty()
    }
}

struct App {
    vault: Mutex<Vault>,
    token: String,
    tokens: TokenRegistry,
    sync: Option<sync::SyncConfig>,
    tag_store: tags::TagStore,
    link_store: links::LinkStore,
    blob_store: blobs::BlobStore,
    rate: RateLimiter,
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
    kind: Option<String>,
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
    // 对齐 mac 形状：应答层用 unix 秒（notebase 内部是 ms）。
    let mut item = json!({
        "id": id,
        "type": "note",
        "title": title,
        "timestamp": updated_at as f64 / 1000.0,
        "createdAt": created_at as f64 / 1000.0,
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
        "version": "v1",
        "docs": "/api/v1/notes/_doc (agent usage, markdown)",
        "endpoints": {
            "POST /api/notes": "create/update a note (body required; id to update; opId idempotent)",
            "GET /api/notes": "list notes (?q= fts, ?limit=, ?offset=)",
            "GET /api/notes/{id}": "single note (markdown projection + tags)",
            "GET /api/notes/tags": "tag counts",
            "GET /api/notes/{id}/...": "list also accepts ?tag= and ?since= (d3)",
        },
    }))
}

async fn list_notes(
    State(state): State<Arc<App>>,
    Query(q): Query<ListQuery>,
) -> AppResult<Json<Value>> {
    // D3：?tag= 走 tags.db 索引；?since=（unix 秒）按 updated_at 过滤；?q= 走 FTS。
    if let Some(tag) = q.tag.as_deref().map(str::trim).filter(|t| !t.is_empty()) {
        let ids = state.tag_store.notes_with_tag(&tag.to_lowercase());
        let mut notes: Vec<Value> = Vec::new();
        for id in ids.iter().take(q.limit.unwrap_or(50).min(200)) {
            let id2 = id.clone();
            if let Ok(Some(meta)) = with_vault(state.clone(), move |vault| {
                vault.store().note(&id2)
            })
            .await
            {
                if q.since.map(|since| (meta.updated_at as f64 / 1000.0) <= since) != Some(true) {
                    notes.push(json!({
                        "id": meta.id, "title": meta.title,
                        "createdAt": meta.created_at, "updatedAt": meta.updated_at,
                    }));
                }
            }
        }
        return Ok(Json(json!({ "ok": true, "count": notes.len(), "notes": notes })));
    }
    let limit = q.limit.unwrap_or(50).min(200);
    let offset = q.offset.unwrap_or(0);
    let since_ms = q.since.map(|s| (s * 1000.0) as i64);
    let query = q.q;
    let mut notes = with_vault(state.clone(), move |vault| match query.as_deref() {
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
                        "createdAt": n.created_at as f64 / 1000.0,
                        "updatedAt": n.updated_at as f64 / 1000.0,
                        "saves": n.saves,
                    })
                })
                .collect::<Vec<_>>()
        }),
    })
    .await?;
    if let Some(ms) = since_ms {
        notes.retain(|n| n.get("updatedAt").and_then(|v| v.as_i64()).unwrap_or(0) > ms);
    }
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
        Some((id, title, created, updated, markdown)) => {
            let note_tags = state.tag_store.for_note(&id);
            Ok(Json(json!({
                "ok": true,
                "item": item_json(&id, &title, created, updated, Some(markdown)),
                "tags": note_tags,
            })))
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BackfillNote {
    id: String,
    body: String,
    created_at: f64,
    updated_at: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BackfillBody {
    notes: Vec<BackfillNote>,
}

/// POST /api/notes/_backfill — operator 一次性迁移：把既有笔记导入 cc 引擎。
/// 只落本机（import + tags），**不发 trx**（mac 已是真源，发布会造成 wallTs 噪声）。
/// 已存在的 id 幂等跳过。token 鉴权同其它端点。
async fn backfill_notes(
    State(state): State<Arc<App>>,
    Json(body): Json<BackfillBody>,
) -> AppResult<Json<Value>> {
    if body.notes.len() > 500 {
        return Err(AppError::bad("max 500 notes per batch"));
    }
    let out = with_vault(state.clone(), move |vault| {
        let mut imported = 0usize;
        let mut skipped = 0usize;
        for n in &body.notes {
            if n.body.trim().is_empty() {
                skipped += 1;
                continue;
            }
            let created = (n.created_at * 1000.0) as i64;
            let updated = (n.updated_at * 1000.0) as i64;
            match vault
                .import_markdown_as(&n.id, &n.body, created, updated)
                .map_err(|e| e.to_string())
            {
                Ok(Some(_)) => {
                    state.tag_store.refresh(&n.id, &n.body);
                    imported += 1;
                }
                Ok(None) => skipped += 1, // id 已存在
                Err(_) => skipped += 1,
            }
        }
        Ok::<_, notebase_store::Error>((imported, skipped))
    })
    .await?;
    let (imported, skipped) = out;
    Ok(Json(json!({
        "ok": true,
        "imported": imported,
        "skippedExisting": skipped,
        "published": 0,
    })))
}

async fn note_tags_counts(State(state): State<Arc<App>>) -> Json<Value> {
    let rows: Vec<Value> = state
        .tag_store
        .counts()
        .into_iter()
        .map(|(tag, n)| json!({ "tag": tag, "count": n }))
        .collect();
    Json(json!({ "ok": true, "tags": rows }))
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
                .map(|opt| opt)
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

    let sync_cfg = state.sync.clone();
    let sync_cfg2 = sync_cfg.clone();
    // blob relay（publish 侧）在 vault 闭包之外执行（网络 IO 不进锁）。
    let mut ready_keys: Vec<String> = Vec::new();
    if sync_cfg.is_some() && body.body.contains("/api/image?sha=") {
        for key in crate::sync::blob_keys_in(&body.body) {
            let cfg = sync_cfg.clone().unwrap();
            let fetched = tokio::task::spawn_blocking(move || {
                let url = format!(
                    "{}/api/files/{}/attach/{key}.bin",
                    cfg.base, cfg.prefix
                );
                let resp = ureq::get(&url)
                    .set("Authorization", &format!("Bearer {}", cfg.token))
                    .timeout(std::time::Duration::from_secs(30))
                    .call();
                match resp {
                    Ok(r) => {
                        let mut bytes = Vec::new();
                        use std::io::Read;
                        r.into_reader().read_to_end(&mut bytes).map(|_| (key.clone(), bytes))
                            .map_err(|e| format!("{key}: {e}"))
                    }
                    Err(_) => Err(format!("{key}: attach missing")),
                }
            })
            .await;
            if let Ok(Ok((key, bytes))) = fetched {
                if let Err(e) = state.blob_store.put(&key, &bytes) {
                    eprintln!("[blob relay] put {}: {e}", key[..8].to_string());
                    continue;
                }
                ready_keys.push(key);
            }
        }
    }
    let ready_keys_in = ready_keys.clone();
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
        // 同步发布：序号与 op 在 vault 锁内落账，HTTP 发布在锁外。
        let sync_op = match &sync_cfg2 {
            Some(cfg) => {
                let seq = vault
                    .store()
                    .vault_meta("sync.seq")
                    .map(|v| v.and_then(|s| s.parse::<u64>().ok()).unwrap_or(0))
                    .unwrap_or(0)
                    + 1;
                vault.store().set_vault_meta("sync.seq", &seq.to_string())?;
                let mut trx = sync::build_compose_op(
                    &cfg.host_id,
                    seq,
                    id.as_str(),
                    &body.body,
                    updated,
                );
                if !ready_keys_in.is_empty() {
                    trx["blob_keys"] = json!(ready_keys_in.clone());
                }
                Some(trx)
            }
            None => None,
        };
        notebase_store::Result::Ok((id, title, created, updated, created_new, sync_op, body.body.clone()))
    })
    .await?;
    let (id, title, created, updated, created_new, sync_op, body_md) = out;
    state.tag_store.refresh(&id, &body_md);
    if let (Some(cfg), Some(op)) = (sync_cfg.as_ref(), sync_op) {
        let cfg = cfg.clone();
        let path = format!(
            "{}/trx/{}/{:016}.json",
            cfg.prefix, cfg.host_id,
            op["seq"].as_u64().unwrap_or(0)
        );
        tokio::task::spawn_blocking(move || sync::publish(&cfg, &path, &op))
            .await
            .ok();
    }
    Ok(Json(json!({
        "ok": true,
        "created": created_new,
        "item": item_json(&id, &title, created, updated, None),
    })))
}

async fn delete_note(
    State(state): State<Arc<App>>,
    Path(id): Path<String>,
) -> AppResult<Json<Value>> {
    let sync_cfg = state.sync.clone();
    let sync_cfg2 = sync_cfg.clone();
    let id_for_op = id.clone();
    let out = with_vault(state.clone(), move |vault| {
        let existed = vault.store().note(&id_for_op)?.is_some();
        let mut tomb = None;
        if existed {
            vault.delete(&id_for_op)?;
            if let Some(cfg) = &sync_cfg2 {
                let seq = vault
                    .store()
                    .vault_meta("sync.seq")
                    .map(|v| v.and_then(|s| s.parse::<u64>().ok()).unwrap_or(0))
                    .unwrap_or(0)
                    + 1;
                vault.store().set_vault_meta("sync.seq", &seq.to_string())?;
                tomb = Some(sync::build_tombstone_op(&cfg.host_id, seq, &id_for_op, now_ms()));
            }
        }
        notebase_store::Result::Ok((existed, tomb))
    })
    .await?;
    let (existed, tomb) = out;
    if !existed {
        return Err(AppError::not_found("笔记不存在"));
    }
    state.tag_store.clear(&id);
    if let (Some(cfg), Some(op)) = (sync_cfg.as_ref(), tomb) {
        let cfg = cfg.clone();
        let path = format!(
            "{}/trx/{}/{:016}.json",
            cfg.prefix, cfg.host_id,
            op["seq"].as_u64().unwrap_or(0)
        );
        tokio::task::spawn_blocking(move || sync::publish(&cfg, &path, &op))
            .await
            .ok();
    }
    Ok(Json(json!({ "ok": true, "soft": false, "id": id })))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LinkCreateBody {
    to_id: Option<String>,
    to_hash: Option<String>,
    kind: Option<String>,
    linked: Option<bool>,
}

/// POST /api/notes/{id}/links { toId?|toHash?, kind?, linked? } — cc 侧建链，
/// 走 trx 发布到 mac 真源（payload 与 mac recordLocalClipLink 逐键对齐）。
async fn agent_note_link_create(
    State(state): State<Arc<App>>,
    Path(id): Path<String>,
    Json(body): Json<LinkCreateBody>,
) -> AppResult<Json<Value>> {
    let from_id = links::norm_id(&id);
    let linked = body.linked.unwrap_or(true);
    let kind = body
        .kind
        .as_deref()
        .map(str::trim)
        .filter(|k| !k.is_empty())
        .map(str::to_lowercase);
    if let Some(k) = &kind {
        if !links::LINK_KINDS.contains(&k.as_str()) {
            return Err(AppError::bad(format!(
                "kind 仅支持: {}",
                links::LINK_KINDS.join("|")
            )));
        }
    }
    let kind = kind.unwrap_or_else(|| "related".into());
    let to_id = body.to_id.as_deref().map(links::norm_id);
    let to_hash = links::normalize_hash(body.to_hash.as_deref());
    if to_id.is_none() && to_hash.is_none() {
        return Err(AppError::bad("expected {toId?|toHash?}"));
    }
    if to_id.as_deref() == Some(from_id.as_str()) {
        return Err(AppError::bad("不能关联自己"));
    }
    let to_is_note = to_id.is_some();

    // from 必须是 cc 引擎里的活笔记（大小写候选）。
    let from_exists = with_vault(state.clone(), {
        let raw = id.clone();
        move |vault| vault_load_any(vault, &raw).map(|o| o.is_some())
    })
    .await?;
    if !from_exists {
        return Err(AppError::not_found("笔记不存在"));
    }

    // pair_key：mac 语义（nn 大写排序 / nh noteId+capHash）。
    let pair_key = match (&to_id, &to_hash) {
        (Some(to), _) if to_is_note => {
            let (a, b) = if from_id.as_str() < to.as_str() {
                (from_id.as_str(), to.as_str())
            } else {
                (to.as_str(), from_id.as_str())
            };
            format!("nn:{a}:{b}")
        }
        (_, Some(hash)) => format!("nh:{from_id}:{hash}"),
        _ => return Err(AppError::bad("expected {toId?|toHash?}")),
    };

    // 度数上限（双向 32，与 mac 一致）。
    if linked && state.link_store.degree(&from_id) >= links::DEGREE_CAP {
        return Err(AppError::bad("最多 32 条关联"));
    }
    if linked {
        if let Some(to) = &to_id {
            if state.link_store.degree(to) >= links::DEGREE_CAP {
                return Err(AppError::bad("最多 32 条关联"));
            }
        }
    }

    // 幂等：已生效的同向 link → changed:false；无可回退的 unlink → changed:false。
    if linked && state.link_store.pair_linked(&pair_key) {
        return Ok(Json(json!({ "ok": true, "changed": false, "link": Value::Null })));
    }
    if !linked && !state.link_store.has_ops_for_pair(&pair_key) {
        return Ok(Json(json!({ "ok": true, "changed": false, "link": Value::Null })));
    }

    let op = links::LinkOp {
        op_id: uuid::Uuid::new_v4().to_string(),
        ts: now_ms() as f64 / 1000.0,
        action: if linked { "link" } else { "unlink" }.into(),
        from_item_id: from_id.clone(),
        to_item_id: to_id.clone(),
        to_content_hash: if to_is_note { None } else { to_hash.clone() },
        to_is_note,
        kind: kind.clone(),
        pair_key: pair_key.clone(),
        source: "cc".into(),
    };
    state.link_store.record(&op);

    // 发布 trx（与 mac 契约一致）；序号在 vault 锁内推进。
    let mut sync_op: Option<Value> = None;
    if state.sync.is_some() {
        let seq = with_vault(state.clone(), move |vault| {
            let seq = vault
                .store()
                .vault_meta("sync.seq")
                .map(|v| v.and_then(|s| s.parse::<u64>().ok()).unwrap_or(0))
                .unwrap_or(0)
                + 1;
            vault.store().set_vault_meta("sync.seq", &seq.to_string())?;
            Ok::<_, notebase_store::Error>(seq)
        })
        .await?;
        let mut trx = sync::compose_like_op(&state.sync, seq, "clip_link", &from_id);
        trx["content_hash"] = json!(if to_is_note { None } else { to_hash.clone() });
        trx["note"] = json!(links::trx_note_payload(&op).to_string());
        sync_op = Some(trx);
    }
    if let (Some(cfg), Some(op)) = (&state.sync, sync_op) {
        let cfg = cfg.clone();
        let path = format!(
            "{}/trx/{}/{:016}.json",
            cfg.prefix, cfg.host_id,
            op["seq"].as_u64().unwrap_or(0)
        );
        tokio::task::spawn_blocking(move || sync::publish(&cfg, &path, &op))
            .await
            .ok();
    }

    Ok(Json(json!({
        "ok": true,
        "changed": true,
        "link": { "pairKey": pair_key, "kind": kind, "linked": linked },
    })))
}

async fn agent_note_links(
    State(state): State<Arc<App>>,
    Path(id): Path<String>,
    Query(q): Query<ListQuery>,
) -> AppResult<Json<Value>> {
    links_view(state, &id, "out", q.kind).await
}

async fn agent_note_backlinks(
    State(state): State<Arc<App>>,
    Path(id): Path<String>,
    Query(q): Query<ListQuery>,
) -> AppResult<Json<Value>> {
    links_view(state, &id, "back", q.kind).await
}

async fn links_view(
    state: Arc<App>,
    id: &str,
    direction: &str,
    kind: Option<String>,
) -> AppResult<Json<Value>> {
    let item_id = links::norm_id(id);
    if let Some(k) = &kind {
        let k = k.trim().to_lowercase();
        if !links::LINK_KINDS.contains(&k.as_str()) {
            return Err(AppError::bad(format!(
                "kind 仅支持: {}",
                links::LINK_KINDS.join("|")
            )));
        }
        return build_links_view(state, item_id, direction, Some(k)).await;
    }
    build_links_view(state, item_id, direction, None).await
}

async fn build_links_view(
    state: Arc<App>,
    item_id: String,
    direction: &str,
    kind: Option<String>,
) -> AppResult<Json<Value>> {
    let edges = state.link_store.edges(direction, &item_id, kind.as_deref());
    let mut links: Vec<Value> = Vec::new();
    for e in edges {
        let mut peer = json!({
            "id": if e.to_is_note { Value::String(e.peer_id.clone()) } else { Value::Null },
            "type": if e.to_is_note { "note" } else { "clip" },
            "preview": Value::Null,
        });
        if e.to_is_note && !e.peer_id.is_empty() {
            if let Ok(Some(meta)) = with_vault(state.clone(), {
                let pid = e.peer_id.clone();
                move |vault| {
                    for cand in id_candidates(&pid) {
                        if let Some(m) = vault.store().note(&cand)? {
                            return Ok(Some(m));
                        }
                    }
                    Ok(None)
                }
            })
            .await
            {
                peer["title"] = json!(meta.title);
                peer["preview"] = json!(meta.plain.chars().take(200).collect::<String>());
                peer["id"] = json!(meta.id);
            }
        } else if let Some(h) = &e.peer_hash {
            peer["hash"] = json!(h);
        }
        links.push(json!({
            "kind": e.kind,
            "pairKey": e.pair_key,
            "peer": peer,
        }));
    }
    Ok(Json(json!({ "ok": true, "count": links.len(), "links": links })))
}

/// GET /api/notes/{id}/related — tags 作 FTS 词，排除自身与已链接对端。
async fn agent_note_related(
    State(state): State<Arc<App>>,
    Path(id): Path<String>,
    Query(q): Query<ListQuery>,
) -> AppResult<Json<Value>> {
    let item_id = links::norm_id(&id);
    let limit = q.limit.unwrap_or(10).min(50);
    // 笔记本体按原始 id 查（大小写候选）；tags 也按原始 id（tags.db 存的是写入时的 id）。
    let raw_id = id.clone();
    let row = with_vault(state.clone(), move |vault| vault_load_any(vault, &raw_id)).await?;
    let note_doc = row.ok_or_else(|| AppError::not_found("笔记不存在"))?;
    let note_id = note_doc.id();
    let tags = id_candidates(&note_id)
        .iter()
        .map(|c| state.tag_store.for_note(c))
        .find(|t| !t.is_empty())
        .unwrap_or_default();
    if tags.is_empty() {
        return Ok(Json(json!({ "ok": true, "basedOn": [], "count": 0, "items": [] })));
    }
    let linked_peers: Vec<String> = state.link_store.peer_ids(&note_id);
    let qstr = tags.join(" ");
    let limit_q = limit + linked_peers.len() + 5;
    let mut hits = with_vault(state.clone(), move |vault| {
        vault.search(&qstr, limit_q).map(|hits| {
            hits.into_iter()
                .map(|h| (h.note_id, h.title, h.snippet))
                .collect::<Vec<_>>()
        })
    })
    .await?;
    let mut items: Vec<Value> = Vec::new();
    for (hid, title, snippet) in hits.drain(..) {
        if hid == note_id || linked_peers.iter().any(|p| p.eq_ignore_ascii_case(&hid)) {
            continue;
        }
        let tags = id_candidates(&hid)
            .iter()
            .map(|c| state.tag_store.for_note(c))
            .find(|t| !t.is_empty())
            .unwrap_or_default();
        items.push(json!({
            "id": hid, "title": title, "preview": snippet, "tags": tags,
        }));
        if items.len() >= limit {
            break;
        }
    }
    Ok(Json(json!({ "ok": true, "basedOn": tags, "count": items.len(), "items": items })))
}


/// cc 引擎内 id 大小写不敏感查找候选（cc 自建 = 小写，mac 回填 = 大写）。
/// pair_key/trx 面仍一律大写归一（mac 契约），存储查找面例外。
fn id_candidates(id: &str) -> [String; 3] {
    [id.to_string(), id.to_uppercase(), id.to_lowercase()]
}

fn vault_load_any(vault: &Vault, id: &str) -> notebase_store::Result<Option<notebase::NoteDoc>> {
    for cand in id_candidates(id) {
        if let Some(doc) = vault.load(&cand)? {
            return Ok(Some(doc));
        }
    }
    Ok(None)
}


/// blob 出图（cc 侧 /api/image 的等价物）：notebase blob CAS 直接服务。
/// 内容嗅探四类型（jpeg/png/gif/webp），缺省 octet-stream。
async fn serve_blob(State(state): State<Arc<App>>, Path(sha): Path<String>) -> Response {
    let sha = sha.trim().to_lowercase();
    if sha.len() != 64 || !sha.chars().all(|c| c.is_ascii_hexdigit()) {
        return AppError::bad("expected a 64-hex sha").into_response();
    }
    let bytes = match state.blob_store.get(&sha) {
        Some(data) => Ok(Some(data)),
        None => with_vault(state.clone(), move |vault| vault.store().get_blob(&sha)).await,
    };
    match bytes {
        Ok(Some(data)) => {
            let ct = match data.first() {
                Some(0xFF) => "image/jpeg",
                Some(0x89) => "image/png",
                Some(0x47) => "image/gif",
                Some(0x52) if data.len() > 8 && &data[0..4] == b"RIFF" => "image/webp",
                _ => "application/octet-stream",
            };
            (
                StatusCode::OK,
                [
                    (axum::http::header::CONTENT_TYPE, axum::http::HeaderValue::from_str(ct).unwrap()),
                    (axum::http::header::CACHE_CONTROL, axum::http::HeaderValue::from_static("public, max-age=31536000, immutable")),
                ],
                data,
            )
                .into_response()
        }
        Ok(None) => AppError::not_found("no blob").into_response(),
        Err(e) => e.into_response(),
    }
}

async fn image_by_query(
    State(state): State<Arc<App>>,
    Query(q): Query<std::collections::HashMap<String, String>>,
) -> Response {
    let sha = q.get("sha").cloned().unwrap_or_default();
    serve_blob(State(state), Path(sha)).await
}

async fn usage_doc() -> Response {
    (
        StatusCode::OK,
        [(axum::http::header::CONTENT_TYPE, "text/markdown; charset=utf-8")],
        AGENT_USAGE_DOC,
    )
        .into_response()
}

/// 每“客户端 IP”令牌桶（CF-Connecting-IP 优先，直连/隧道回落 direct）。
/// 公网入口的唯一防滥用闸（token 之外的带宽防线）；内存态，重启即清零。
struct RateLimiter {
    buckets: std::sync::Mutex<std::collections::HashMap<String, (f64, std::time::Instant)>>,
    burst: f64,
    per_sec: f64,
}

impl RateLimiter {
    fn new() -> Self {
        // burst 30, sustained 1 req/s per IP（agent 轮询 + 偶发批量足够）。
        RateLimiter {
            buckets: std::sync::Mutex::new(Default::default()),
            burst: 30.0,
            per_sec: 1.0,
        }
    }

    fn take(&self, key: &str) -> bool {
        let mut m = self.buckets.lock().unwrap();
        let now = std::time::Instant::now();
        let (tokens, last) = m.entry(key.to_string()).or_insert((self.burst, now));
        let elapsed = now.duration_since(*last).as_secs_f64();
        *tokens = (self.burst).min(*tokens + elapsed * self.per_sec);
        *last = now;
        if *tokens >= 1.0 {
            *tokens -= 1.0;
            true
        } else {
            false
        }
    }
}

async fn rate_limit(
    State(state): State<Arc<App>>,
    req: axum::extract::Request,
    next: Next,
) -> Response {
    let ip = req
        .headers()
        .get("cf-connecting-ip")
        .and_then(|v| v.to_str().ok())
        .map(str::to_string)
        .unwrap_or_else(|| "direct".into());
    if !state.rate.take(&ip) {
        return (
            StatusCode::TOO_MANY_REQUESTS,
            [("Retry-After", "3")],
            Json(json!({ "ok": false, "message": "rate limited" })),
        )
            .into_response();
    }
    // 内存护栏：IP 桶数量封顶，防伪造头把表撑爆。
    if state.rate.buckets.lock().unwrap().len() > 10_000 {
        state.rate.buckets.lock().unwrap().clear();
    }
    next.run(req).await
}

async fn auth(
    State(state): State<Arc<App>>,
    mut req: axum::extract::Request,
    next: Next,
) -> Response {
    let token = req
        .headers()
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .map(str::to_string)
        .unwrap_or_default();
    let unauthorized = || {
        (
            StatusCode::UNAUTHORIZED,
            Json(json!({ "error": "unauthorized" })),
        )
            .into_response()
    };
    // 1) registry（tokens.json）优先 —— 多 agent 身份面。
    // 2) 回落单 token（legacy 部署）。identity 由各 handler 的 agent 归因使用。
    let identity = if !state.tokens.is_empty() {
        match state.tokens.identify(&token) {
            Some(name) => name,
            None => return unauthorized(),
        }
    } else if constant_eq(&token, &state.token) {
        "agent".to_string()
    } else {
        return unauthorized();
    };
    req.extensions_mut().insert(Identity(identity));
    next.run(req).await
}

/// 已鉴权的 agent 身份（token name 或 "agent"）。
#[derive(Clone)]
struct Identity(pub String);

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
    let tag_store = tags::TagStore::open(&std::path::Path::new(&home).join("tags.db"));
    let link_store = links::LinkStore::open(&std::path::Path::new(&home).join("links.db"));
    let blob_store = blobs::BlobStore::open(&std::path::Path::new(&home).join("blobs.db"));
    let port: u16 = std::env::var("CLIPVAULT_NOTES_PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(9490);
    let state = Arc::new(App {
        vault: Mutex::new(vault),
        token,
        tokens: TokenRegistry::load(std::env::var("CLIPVAULT_NOTES_TOKENS_FILE").ok().map(std::path::PathBuf::from).as_deref()),
        sync: sync::SyncConfig::from_env(),
        tag_store,
        link_store,
        blob_store,
        rate: RateLimiter::new(),
    });
    if let Some(cfg) = &state.sync {
        println!(
            "[clipvault-notes] sync wire on: prefix={} host={} poll={}s",
            cfg.prefix, cfg.host_id, cfg.poll_secs
        );
        tokio::spawn(sync::pull_loop(state.clone()));
    } else {
        println!("[clipvault-notes] sync wire off (no ostore token env /etc/ostore.env)");
    }

    // API v1：版本入路径（/api/v1/notes*），legacy /api/notes* 兼容别名。
    let notes_routes = Router::new()
        .route("/", get(list_notes).post(save_note))
        .route("/_doc", get(usage_doc))
        .route("/_backfill", post(backfill_notes))
        .route("/_meta", get(meta))
        .route("/tags", get(note_tags_counts))
        .route("/{id}", get(show_note).delete(delete_note))
        .route("/{id}/links", post(agent_note_link_create).get(agent_note_links))
        .route("/{id}/backlinks", get(agent_note_backlinks))
        .route("/{id}/related", get(agent_note_related))
        .route("/_raw_blobs/{sha}", get(serve_blob))
        .with_state(state.clone());
    let app = Router::new()
        .nest("/api/v1/notes", notes_routes.clone())
        .nest("/api/notes", notes_routes)
        .route("/api/v1/blobs/{sha}", get(serve_blob))
        .route("/api/blobs/{sha}", get(serve_blob))
        .route("/api/image", get(image_by_query))
        .route("/api/archive/asset", get(image_by_query))
        .layer(DefaultBodyLimit::max(512 * 1024))
        .layer(middleware::from_fn_with_state(state.clone(), rate_limit))
        .layer(middleware::from_fn_with_state(state.clone(), auth))
        .with_state(state);

    let addr = std::net::SocketAddr::from(([127, 0, 0, 1], port));
    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .expect("bind 127.0.0.1 notes port");
    println!("[clipvault-notes] listening on {addr}");
    axum::serve(listener, app).await.expect("serve");
}
