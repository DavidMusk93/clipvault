//! ostore trx wire（D2b）：cc 作为新 peer host 加入既有 per-host trx 日志。
//!
//! pull：轮询 `{prefix}/trx` list → 逐 host 按 seq 增量 GET → apply：
//!   - `compose`+note：整篇 body 覆盖（wallTs 新者胜，mac↔mac 同规则）
//!   - `tombstone`+note：vault.delete（回收箱真相仍在 mac 侧）
//!   - 其余 kind 记数跳过（墙/判断/阅读态是 mac 的面）
//! publish：本机写入 → `compose` op → `POST /api/batch` 写 `{prefix}/trx/{host}/{seq}.json`。
//!
//! 禁止（沿 AGENTS/ostore-sync.md）：不用 list.sha256 校验（历史是 MD5）；
//! 事件不做业务判断，真相来自 list + 游标；token 不进日志。

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use serde_json::{json, Value};
use std::sync::Arc;

use crate::App;

#[derive(Clone)]
pub struct SyncConfig {
    pub base: String,
    pub token: String,
    pub prefix: String,
    pub host_id: String,
    pub poll_secs: u64,
}

fn env_token_from_ostore_env() -> Option<String> {
    let raw = std::fs::read_to_string("/etc/ostore.env").ok()?;
    for line in raw.lines() {
        if let Some(rest) = line.strip_prefix("OSTORE_TOKEN=") {
            let t = rest.trim();
            if !t.is_empty() {
                return Some(t.to_string());
            }
        }
    }
    None
}

impl SyncConfig {
    /// 非 cc 环境（无 /etc/ostore.env 且无 env token）→ None = 同步关闭，服务照常。
    pub fn from_env() -> Option<SyncConfig> {
        let token = std::env::var("CLIPVAULT_SYNC_OSTORE_TOKEN")
            .ok()
            .filter(|t| !t.trim().is_empty())
            .or_else(env_token_from_ostore_env)?;
        Some(SyncConfig {
            base: std::env::var("CLIPVAULT_SYNC_OSTORE_BASE")
                .unwrap_or_else(|_| "http://127.0.0.1:8781".into()),
            token,
            prefix: std::env::var("CLIPVAULT_SYNC_PREFIX")
                .unwrap_or_else(|_| "clipvault/sync/v1".into()),
            host_id: std::env::var("CLIPVAULT_SYNC_HOST_ID").unwrap_or_else(|_| "cc".into()),
            poll_secs: std::env::var("CLIPVAULT_SYNC_POLL_SECS")
                .ok()
                .and_then(|p| p.parse().ok())
                .unwrap_or(2),
        })
    }

    fn req(&self, method: &str, url: &str, body: Option<Value>) -> Result<String, String> {
        let resp = match body {
            Some(b) => ureq::request(method, url)
                .set("Authorization", &format!("Bearer {}", self.token))
                .timeout(std::time::Duration::from_secs(15))
                .send_json(b)
                .map_err(|e| format!("{method} {url}: {e}"))?,
            None => ureq::request(method, url)
                .set("Authorization", &format!("Bearer {}", self.token))
                .timeout(std::time::Duration::from_secs(15))
                .call()
                .map_err(|e| format!("{method} {url}: {e}"))?,
        };
        resp.into_string()
            .map_err(|e| format!("{method} {url}: read body: {e}"))
    }
}

#[derive(serde::Deserialize)]
struct ListEntry {
    path: String,
}

#[derive(serde::Deserialize)]
#[allow(dead_code)]
struct SyncOp {
    #[allow(dead_code)]
    host: String,
    #[allow(dead_code)]
    seq: u64,
    kind: String,
    #[serde(rename = "item_id")]
    item_id: String,
    #[serde(rename = "type")]
    item_type: Option<String>,
    #[serde(rename = "wall_ts")]
    wall_ts: f64,
    #[serde(rename = "text_content")]
    text_content: Option<String>,
}

fn meta_key_applied(host: &str) -> String {
    format!("sync.applied.{host}")
}

/// 一轮 pull。返回 (applied, skipped, advanced_hosts)。
pub async fn pull_once(app: Arc<App>) -> Result<(usize, usize, usize), String> {
    let cfg = match app.sync.clone() {
        Some(c) => c,
        None => return Ok((0, 0, 0)),
    };
    // 1) 发现 host：非递归列 trx/ 的子目录（Entry.type = dir）。
    let cfg2 = cfg.clone();
    let list_raw = tokio::task::spawn_blocking(move || {
        cfg2.req(
            "GET",
            &format!("{}/api/list?path={}/trx&limit=1000", cfg2.base, cfg2.prefix),
            None,
        )
    })
    .await
    .map_err(|e| e.to_string())??;
    let parsed: Value = serde_json::from_str(&list_raw).map_err(|e| format!("list parse: {e}"))?;
    let hosts: Vec<String> = match parsed.get("entries") {
        Some(v) => serde_json::from_value::<Vec<ListEntry>>(v.clone())
            .unwrap_or_default()
            .into_iter()
            .filter_map(|e| {
                let parts: Vec<&str> = e.path.split('/').filter(|s| !s.is_empty()).collect();
                if parts.len() >= 2 {
                    Some(parts[parts.len() - 1].to_string())
                } else {
                    None
                }
            })
            .collect(),
        None => return Ok((0, 0, 0)),
    };

    let mut applied = 0usize;
    let mut skipped = 0usize;
    let mut advanced = 0usize;
    for host in hosts {
        if host == cfg.host_id {
            continue; // 自己发的，publish 侧管理
        }
        let key = meta_key_applied(&host);
        let cursor = vault_meta_i64(&app, &key).await?;
        if cursor == 0 {
            // 首次见到：尾页定位 max seq 作为初始游标（backlog 跳过，回填是显式任务）。
            let max = max_seq(&cfg, &host).await?;
            set_vault_meta_i64(&app, &key, max as i64).await?;
            if max > 0 {
                eprintln!("[sync] host {host}: 初始游标={max}（存量 backlog 跳过，回填待 D3）");
            }
            continue;
        }
        // 2) 逐 seq 精确 GET，404 即追平。单轮上限 200，剩余下一轮。
        let mut seq = cursor as u64 + 1;
        let mut got = 0usize;
        while got < 200 {
            let cfg2 = cfg.clone();
            let host2 = host.clone();
            let attempt = seq;
            let fetch = tokio::task::spawn_blocking(move || {
                let url = format!(
                    "{}/api/files/{}/trx/{host2}/{attempt:016}.json",
                    cfg2.base, cfg2.prefix
                );
                // 404 → None（追平）；其它错误 → Err
                match ureq::get(&url)
                    .set("Authorization", &format!("Bearer {}", cfg2.token))
                    .timeout(std::time::Duration::from_secs(15))
                    .call()
                {
                    Ok(resp) => resp
                        .into_string()
                        .map(Some)
                        .map_err(|e| format!("read {url}: {e}")),
                    Err(ureq::Error::Status(404, _)) => Ok(None),
                    Err(e) => Err(format!("get {url}: {e}")),
                }
            })
            .await
            .map_err(|e| e.to_string())??;
            let raw = match fetch {
                Some(raw) => raw,
                None => {
                    // cursor+1 缺失：探测 max seq，有跳号则跳（记日志），否则追平。
                    let max = max_seq(&cfg, &host).await?;
                    if (max as i64) > seq as i64 {
                        eprintln!("[sync] host {host}: seq {seq} 缺失，跳到 max={max}");
                        set_vault_meta_i64(&app, &key, max as i64).await?;
                        advanced += 1;
                    }
                    break;
                }
            };
            let op: SyncOp = match serde_json::from_str(&raw) {
                Ok(op) => op,
                Err(e) => {
                    eprintln!("[sync] parse {host}/{seq}: {e} — 推进游标跳过坏行");
                    set_vault_meta_i64(&app, &key, seq as i64).await?;
                    seq += 1;
                    continue;
                }
            };
            let (a, s) = apply_op(&app, &op).await?;
            applied += a;
            skipped += s;
            set_vault_meta_i64(&app, &key, seq as i64).await?;
            advanced += 1;
            seq += 1;
            got += 1;
        }
    }
    Ok((applied, skipped, advanced))
}

/// 某 host 的最大 trx seq：两次请求（total_count → 尾页）。
async fn max_seq(cfg: &SyncConfig, host: &str) -> Result<u64, String> {
    let cfg2 = cfg.clone();
    let host2 = host.to_string();
    let first = tokio::task::spawn_blocking(move || {
        cfg2.req(
            "GET",
            &format!(
                "{}/api/list?path={}/trx/{host2}&recursive=1&limit=1",
                cfg2.base, cfg2.prefix
            ),
            None,
        )
    })
    .await
    .map_err(|e| e.to_string())??;
    let v: Value = serde_json::from_str(&first).map_err(|e| format!("list parse: {e}"))?;
    let total = v.get("total_count").and_then(|t| t.as_u64()).unwrap_or(0);
    if total == 0 {
        return Ok(0);
    }
    let cfg2 = cfg.clone();
    let host2 = host.to_string();
    let last_off = total - 1;
    let tail = tokio::task::spawn_blocking(move || {
        cfg2.req(
            "GET",
            &format!(
                "{}/api/list?path={}/trx/{host2}&recursive=1&limit=1&offset={last_off}",
                cfg2.base, cfg2.prefix
            ),
            None,
        )
    })
    .await
    .map_err(|e| e.to_string())??;
    let v: Value = serde_json::from_str(&tail).map_err(|e| format!("list parse: {e}"))?;
    let entries: Vec<ListEntry> = serde_json::from_value(
        v.get("entries").cloned().unwrap_or(Value::Null),
    )
    .unwrap_or_default();
    Ok(entries
        .last()
        .and_then(|e| {
            e.path
                .rsplit('/')
                .next()
                .and_then(|f| f.strip_suffix(".json"))
                .and_then(|s| s.parse::<u64>().ok())
        })
        .unwrap_or(0))
}

async fn vault_meta_i64(app: &Arc<App>, key: &str) -> Result<i64, String> {
    let key = key.to_string();
    tokio::task::spawn_blocking({
        let app = app.clone();
        move || {
            let vault = app.vault.lock().map_err(|_| "vault poisoned")?;
            Ok::<_, String>(
                vault
                    .store()
                    .vault_meta(&key)
                    .map_err(|e| e.to_string())?
                    .and_then(|v| v.parse::<i64>().ok())
                    .unwrap_or(0),
            )
        }
    })
    .await
    .map_err(|e| e.to_string())?
}

async fn set_vault_meta_i64(app: &Arc<App>, key: &str, value: i64) -> Result<(), String> {
    let key = key.to_string();
    tokio::task::spawn_blocking({
        let app = app.clone();
        move || {
            let vault = app.vault.lock().map_err(|_| "vault poisoned")?;
            vault
                .store()
                .set_vault_meta(&key, &value.to_string())
                .map_err(|e| e.to_string())
        }
    })
    .await
    .map_err(|e| e.to_string())?
}

/// (applied, skipped)
async fn apply_op(app: &Arc<App>, op: &SyncOp) -> Result<(usize, usize), String> {
    if op.kind == "tombstone" && op.item_type.as_deref() == Some("note") {
        let app = app.clone();
        let id = op.item_id.clone();
        tokio::task::spawn_blocking(move || {
            let vault = app.vault.lock().map_err(|_| "vault poisoned")?;
            let existed = vault.store().note(&id).map_err(|e| e.to_string())?.is_some();
            if existed {
                vault.delete(&id).map_err(|e| e.to_string())?;
                app.tag_store.clear(&id);
            }
            Ok::<_, String>((existed as usize, (!existed) as usize))
        })
        .await
        .map_err(|e| e.to_string())?
    } else if op.kind == "compose" && op.item_type.as_deref() == Some("note") {
        let body = op.text_content.clone().unwrap_or_default();
        if body.trim().is_empty() {
            return Ok((0, 1));
        }
        let app = app.clone();
        let id = op.item_id.clone();
        let wall_ms = (op.wall_ts * 1000.0) as i64;
        tokio::task::spawn_blocking(move || {
            let vault = app.vault.lock().map_err(|_| "vault poisoned")?;
            match vault.load(&id).map_err(|e| e.to_string())? {
                Some(doc) => {
                    if doc.updated_at().unwrap_or(0) >= wall_ms {
                        Ok((0, 1)) // 旧于现状：wallTs 新者胜，跳过
                    } else {
                        doc.set_markdown(&body).map_err(|e| e.to_string())?;
                        vault.save_and_index(&doc).map_err(|e| e.to_string())?;
                        app.tag_store.refresh(&id, &body);
                        Ok((1, 0))
                    }
                }
                None => {
                    match vault
                        .import_markdown_as(&id, &body, wall_ms, wall_ms)
                        .map_err(|e| e.to_string())?
                    {
                        Some(_) => {
                            app.tag_store.refresh(&id, &body);
                            Ok((1, 0))
                        }
                        None => Ok((0, 1)), // 已存在（并发）
                    }
                }
            }
        })
        .await
        .map_err(|e| e.to_string())?
    } else {
        Ok((0, 1))
    }
}

/// 发布一个 op（fire-and-forget：失败仅记日志，下一轮 pull 的游标不涉及发送侧）。
pub fn publish(cfg: &SyncConfig, path: &str, op: &Value) {
    let payload = json!({
        "objects": [{
            "path": path,
            "data_b64": B64.encode(serde_json::to_vec(op).unwrap_or_default()),
            "content_type": "application/json",
        }]
    });
    match cfg.req("POST", &format!("{}/api/batch", cfg.base), Some(payload)) {
        Ok(_) => {}
        Err(e) => eprintln!("[sync] publish {path}: {e}"),
    }
}

pub fn build_compose_op(host_id: &str, seq: u64, item_id: &str, body: &str, wall_ms: i64) -> Value {
    let wall_ts = wall_ms as f64 / 1000.0;
    json!({
        "v": 1,
        "op_id": uuid::Uuid::new_v4().to_string(),
        "host": host_id,
        "seq": seq,
        "kind": "compose",
        "item_id": item_id,
        "type": "note",
        "wall_ts": wall_ts,
        "hlc": format!("{}-{}-{}", wall_ms, host_id, seq),
        "text_content": body,
        "source_app": "ClipVault",
        "note": "compose",
    })
}

pub fn build_tombstone_op(host_id: &str, seq: u64, item_id: &str, wall_ms: i64) -> Value {
    let wall_ts = wall_ms as f64 / 1000.0;
    json!({
        "v": 1,
        "op_id": uuid::Uuid::new_v4().to_string(),
        "host": host_id,
        "seq": seq,
        "kind": "tombstone",
        "item_id": item_id,
        "type": "note",
        "wall_ts": wall_ts,
        "hlc": format!("{}-{}-{}", wall_ms, host_id, seq),
    })
}

pub async fn pull_loop(app: Arc<App>) {
    let poll = app.sync.as_ref().map(|c| c.poll_secs).unwrap_or(2);
    let mut tick = tokio::time::interval(std::time::Duration::from_secs(poll));
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    loop {
        tick.tick().await;
        match pull_once(app.clone()).await {
            Ok((a, s, _)) if a > 0 || s > 0 => {
                println!("[sync] pull applied={a} skipped={s}");
            }
            Ok(_) => {}
            Err(e) => eprintln!("[sync] pull error: {e}"),
        }
    }
}
