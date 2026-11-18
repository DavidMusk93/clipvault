//! cc 侧链接（P3 跨 host）：cc 作为链接 peer 加入 mac 的 `clip_link_ops` 真源。
//!
//! 存储：独立 `links.db`（不耦合 notebase schema）：
//!   clip_link_ops（真源 op 账本）+ clip_links（按 pair 折叠投影，linked=1 生效）
//! pull：mac trx `kind=clip_link` → 解析 `note` JSON payload → 记 op + 折叠。
//! publish：cc agent 建链 → 组 trx op（payload 与 mac `recordLocalClipLink` 逐键对齐）
//!          → `POST /api/batch`；mac 侧 `applySyncClipLinkLocked` 校验 from 存在后吸收。
//!
//! id/pair_key 归一：mac 用 `UUID().uuidString`（大写）构 pair_key —— cc 全部大写化，
//! 否则同一逻辑链在两台机器上会得到不同 pair_key（nn:lower vs nn:upper）分裂。

use std::sync::Mutex;

use rusqlite::Connection;
use serde_json::{json, Value};

pub const LINK_KINDS: [&str; 6] = [
    "related",
    "mentions",
    "explains",
    "follows",
    "supersedes",
    "contradicts",
];
pub const DEGREE_CAP: usize = 32;

/// mac 语义：uuid → 大写规范化；无法解析则原样返回。
pub fn norm_id(raw: &str) -> String {
    match uuid::Uuid::parse_str(raw.trim()) {
        Ok(u) => u.to_string().to_uppercase(),
        Err(_) => raw.trim().to_string(),
    }
}

pub fn normalize_hash(raw: Option<&str>) -> Option<String> {
    let h = raw?.trim().to_lowercase();
    if h.len() == 64 && h.chars().all(|c| c.is_ascii_hexdigit()) {
        Some(h)
    } else {
        None
    }
}

#[derive(Debug, Clone)]
pub struct LinkOp {
    pub op_id: String,
    pub ts: f64,
    pub action: String, // link | unlink
    pub from_item_id: String,
    pub to_item_id: Option<String>,
    pub to_content_hash: Option<String>,
    pub to_is_note: bool,
    pub kind: String,
    pub pair_key: String,
    pub source: String,
}

pub struct LinkEdge {
    pub pair_key: String,
    pub kind: String,
    pub peer_id: String,          // 对端 id（note）或 clip 行 id 未知时为空
    pub peer_hash: Option<String>, // clip 对端的 content hash
    pub to_is_note: bool,
}

pub struct LinkStore {
    conn: Mutex<Connection>,
}

impl LinkStore {
    pub fn open(path: &std::path::Path) -> LinkStore {
        let conn = Connection::open(path).expect("open links.db");
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS clip_link_ops (
                op_id TEXT PRIMARY KEY,
                ts REAL NOT NULL,
                action TEXT NOT NULL,
                from_item_id TEXT NOT NULL,
                to_item_id TEXT,
                to_content_hash TEXT,
                to_is_note INTEGER NOT NULL DEFAULT 0,
                kind TEXT NOT NULL DEFAULT 'related',
                pair_key TEXT NOT NULL,
                source TEXT NOT NULL DEFAULT 'sync'
            );
            CREATE INDEX IF NOT EXISTS idx_link_ops_pair ON clip_link_ops(pair_key, ts);
            CREATE INDEX IF NOT EXISTS idx_link_ops_from ON clip_link_ops(from_item_id);
            CREATE TABLE IF NOT EXISTS clip_links (
                pair_key TEXT PRIMARY KEY,
                from_item_id TEXT NOT NULL,
                to_item_id TEXT,
                to_content_hash TEXT,
                to_is_note INTEGER NOT NULL DEFAULT 0,
                kind TEXT NOT NULL DEFAULT 'related',
                last_op_id TEXT NOT NULL,
                updated_at REAL NOT NULL,
                linked INTEGER NOT NULL DEFAULT 1
            );
            CREATE INDEX IF NOT EXISTS idx_clip_links_from ON clip_links(from_item_id);
            CREATE INDEX IF NOT EXISTS idx_clip_links_to ON clip_links(to_item_id);",
        )
        .expect("init links.db");
        LinkStore { conn: Mutex::new(conn) }
    }

    /// 记 op 并折叠该 pair 投影（以该 pair 内 ts 最新的 op 为准）。
    pub fn record(&self, op: &LinkOp) {
        {
            let conn = self.conn.lock().expect("links lock");
            let _ = conn.execute(
                "INSERT OR IGNORE INTO clip_link_ops
                 (op_id, ts, action, from_item_id, to_item_id, to_content_hash, to_is_note, kind, pair_key, source)
                 VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)",
                rusqlite::params![
                    op.op_id,
                    op.ts,
                    op.action,
                    op.from_item_id,
                    op.to_item_id,
                    op.to_content_hash,
                    op.to_is_note as i64,
                    op.kind,
                    op.pair_key,
                    op.source,
                ],
            );
        }
        self.fold(&op.pair_key);
    }

    /// 该 pair 的最新 op → 投影。与 mac `foldPairKeyIntoLinks` 同语义。
    pub fn fold(&self, pair_key: &str) {
        let conn = self.conn.lock().expect("links lock");
        let latest: Option<(String, String, String, Option<String>, Option<String>, i64, String, f64)> = conn
            .query_row(
                "SELECT op_id, action, from_item_id, to_item_id, to_content_hash, to_is_note, kind, ts
                 FROM clip_link_ops WHERE pair_key = ?1
                 ORDER BY ts DESC, rowid DESC LIMIT 1",
                [pair_key],
                |r| {
                    Ok((
                        r.get(0)?,
                        r.get(1)?,
                        r.get(2)?,
                        r.get(3)?,
                        r.get(4)?,
                        r.get(5)?,
                        r.get(6)?,
                        r.get(7)?,
                    ))
                },
            )
            .ok();
        if let Some((op_id, action, from, to_item, to_hash, to_note, kind, ts)) = latest {
            let linked: i64 = if action == "link" { 1 } else { 0 };
            let _ = conn.execute(
                "INSERT INTO clip_links
                 (pair_key, from_item_id, to_item_id, to_content_hash, to_is_note, kind, last_op_id, updated_at, linked)
                 VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)
                 ON CONFLICT(pair_key) DO UPDATE SET
                   to_item_id=excluded.to_item_id, to_content_hash=excluded.to_content_hash,
                   to_is_note=excluded.to_is_note, kind=excluded.kind,
                   last_op_id=excluded.last_op_id, updated_at=excluded.updated_at, linked=excluded.linked",
                rusqlite::params![pair_key, from, to_item, to_hash, to_note, kind, op_id, ts, linked],
            );
        }
    }

    /// direction=out：from=me；back：to=me。只回 linked=1 的生效边。
    pub fn edges(&self, direction: &str, item_id: &str, kind: Option<&str>) -> Vec<LinkEdge> {
        let conn = self.conn.lock().expect("links lock");
        let (col, peer_col, peer_hash_col) = if direction == "out" {
            ("from_item_id", "to_item_id", "to_content_hash")
        } else {
            ("to_item_id", "from_item_id", "to_content_hash")
        };
        let mut sql = format!(
            "SELECT pair_key, kind, COALESCE({peer_col}, ''), {peer_hash_col}, to_is_note
             FROM clip_links WHERE {col} = ?1 AND linked = 1"
        );
        if kind.is_some() {
            sql.push_str(" AND kind = ?2");
        }
        sql.push_str(" ORDER BY updated_at DESC LIMIT 100");
        let mut stmt = match conn.prepare(&sql) {
            Ok(s) => s,
            Err(_) => return vec![],
        };
        let map = |r: &rusqlite::Row| -> rusqlite::Result<LinkEdge> {
            Ok(LinkEdge {
                pair_key: r.get(0)?,
                kind: r.get(1)?,
                peer_id: r.get(2)?,
                peer_hash: r.get(3)?,
                to_is_note: r.get::<_, i64>(4)? != 0,
            })
        };
        let rows = if let Some(k) = kind {
            stmt.query_map(rusqlite::params![item_id, k], map)
        } else {
            stmt.query_map([item_id], map)
        };
        rows.map(|rs| rs.filter_map(Result::ok).collect()).unwrap_or_default()
    }

    /// 一跳邻居 + 二跳（co-link 信号用）：我链接的、以及与我共邻的笔记 id 集。
    pub fn neighborhood(&self, item_id: &str) -> (Vec<String>, Vec<String>) {
        let direct = self.peer_ids(item_id);
        let mut second: Vec<String> = Vec::new();
        for pid in &direct {
            for e in self.edges("out", pid, None).into_iter().chain(self.edges("back", pid, None)) {
                if !e.to_is_note || e.peer_id.is_empty() { continue; }
                if e.peer_id.eq_ignore_ascii_case(item_id) { continue; }
                if direct.iter().any(|d| d.eq_ignore_ascii_case(&e.peer_id)) { continue; }
                second.push(e.peer_id.clone());
            }
        }
        second.sort();
        second.dedup();
        (direct, second)
    }

    /// 双向邻接（related 排除已链接对端用）。
    pub fn peer_ids(&self, item_id: &str) -> Vec<String> {
        let mut out: Vec<String> = self.edges("out", item_id, None)
            .into_iter()
            .filter(|e| e.to_is_note)
            .map(|e| e.peer_id.clone())
            .collect();
        out.extend(
            self.edges("back", item_id, None)
                .into_iter()
                .filter(|e| e.to_is_note)
                .map(|e| e.peer_id),
        );
        out
    }

    pub fn degree(&self, item_id: &str) -> usize {
        self.edges("out", item_id, None).len() + self.edges("back", item_id, None).len()
    }

    /// 该 pair 当前是否已生效链接。
    pub fn pair_linked(&self, pair_key: &str) -> bool {
        let conn = self.conn.lock().expect("links lock");
        conn.query_row(
            "SELECT linked FROM clip_links WHERE pair_key = ?1",
            [pair_key],
            |r| r.get::<_, i64>(0),
        )
        .map(|v| v != 0)
        .unwrap_or(false)
    }

    pub fn has_ops_for_pair(&self, pair_key: &str) -> bool {
        let conn = self.conn.lock().expect("links lock");
        conn.query_row(
            "SELECT 1 FROM clip_link_ops WHERE pair_key = ?1 LIMIT 1",
            [pair_key],
            |_| Ok(()),
        )
        .is_ok()
    }

    /// 笔记/条目消失（tombstone/删除）→ 清双向边。
    pub fn purge_item(&self, item_id: &str) {
        let conn = self.conn.lock().expect("links lock");
        let _ = conn.execute("DELETE FROM clip_links WHERE from_item_id = ?1 OR to_item_id = ?1", [item_id]);
        let _ = conn.execute("DELETE FROM clip_link_ops WHERE from_item_id = ?1 OR to_item_id = ?1", [item_id]);
    }
}

/// cc 侧 trx publish payload —— 与 mac `recordLocalClipLink` 逐键对齐。
pub fn trx_note_payload(op: &LinkOp) -> Value {
    let mut body = json!({
        "action": op.action,
        "kind": op.kind,
        "to_is_note": op.to_is_note,
        "pair_key": op.pair_key,
        "from_item_id": op.from_item_id,
    });
    if let Some(to_item) = &op.to_item_id {
        body["to_item_id"] = json!(to_item);
    }
    if let Some(to_hash) = &op.to_content_hash {
        body["to_content_hash"] = json!(to_hash);
    }
    body
}

/// 从 trx SyncOp.note JSON 解析（mac 侧同字段）。
pub fn parse_trx_payload(note: &str, fallback_from: &str, ts: f64, op_id: &str, source: &str) -> Option<LinkOp> {
    let obj: Value = serde_json::from_str(note).ok()?;
    let pair_key = obj.get("pair_key")?.as_str()?.trim().to_string();
    let action = obj.get("action")?.as_str()?.to_string();
    if pair_key.is_empty() || (action != "link" && action != "unlink") {
        return None;
    }
    let from = obj
        .get("from_item_id")
        .and_then(|v| v.as_str())
        .unwrap_or(fallback_from)
        .to_string();
    Some(LinkOp {
        op_id: op_id.to_string(),
        ts,
        action,
        from_item_id: norm_id(&from),
        to_item_id: obj.get("to_item_id").and_then(|v| v.as_str()).map(norm_id),
        to_content_hash: normalize_hash(obj.get("to_content_hash").and_then(|v| v.as_str())),
        to_is_note: obj.get("to_is_note").and_then(|v| v.as_bool()).unwrap_or(false),
        kind: obj
            .get("kind")
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .unwrap_or("related")
            .to_string(),
        pair_key,
        source: source.to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> LinkStore {
        let conn = Connection::open_in_memory().expect("mem db");
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS clip_link_ops (
                op_id TEXT PRIMARY KEY, ts REAL NOT NULL, action TEXT NOT NULL,
                from_item_id TEXT NOT NULL, to_item_id TEXT, to_content_hash TEXT,
                to_is_note INTEGER NOT NULL DEFAULT 0, kind TEXT NOT NULL DEFAULT 'related',
                pair_key TEXT NOT NULL, source TEXT NOT NULL DEFAULT 'sync');
            CREATE TABLE IF NOT EXISTS clip_links (
                pair_key TEXT PRIMARY KEY, from_item_id TEXT NOT NULL, to_item_id TEXT,
                to_content_hash TEXT, to_is_note INTEGER NOT NULL DEFAULT 0,
                kind TEXT NOT NULL DEFAULT 'related', last_op_id TEXT NOT NULL,
                updated_at REAL NOT NULL, linked INTEGER NOT NULL DEFAULT 1);",
        )
        .unwrap();
        LinkStore { conn: Mutex::new(conn) }
    }

    #[test]
    fn record_fold_and_edges() {
        let s = store();
        let a = "AAAAAAAA-1111-1111-1111-111111111111";
        let b = "BBBBBBBB-2222-2222-2222-222222222222";
        s.record(&LinkOp {
            op_id: "op1".into(),
            ts: 1.0,
            action: "link".into(),
            from_item_id: a.into(),
            to_item_id: Some(b.into()),
            to_content_hash: None,
            to_is_note: true,
            kind: "explains".into(),
            pair_key: format!("nn:{a}:{b}"),
            source: "test".into(),
        });
        assert!(s.pair_linked(&format!("nn:{a}:{b}")));
        assert_eq!(s.edges("out", a, Some("explains")).len(), 1);
        assert_eq!(s.edges("back", b, None).len(), 1);
        // unlink 折叠回去
        s.record(&LinkOp {
            op_id: "op2".into(),
            ts: 2.0,
            action: "unlink".into(),
            from_item_id: a.into(),
            to_item_id: Some(b.into()),
            to_content_hash: None,
            to_is_note: true,
            kind: "explains".into(),
            pair_key: format!("nn:{a}:{b}"),
            source: "test".into(),
        });
        assert!(!s.pair_linked(&format!("nn:{a}:{b}")));
        assert_eq!(s.edges("out", a, None).len(), 0);
        s.purge_item(a);
        assert!(!s.has_ops_for_pair(&format!("nn:{a}:{b}")));
    }
}
