//! note_tags 投影（D3-lite）：与 mac `NoteTags.swift` 同语义的服务端提取。
//! 存储用独立 `tags.db`（不耦合 notebase 的 schema），提取规则与 mac 一致：
//! 围栏外 `#tag`，tag 字符 `[\p{L}\p{N}_/-]{1,32}`，词界 = 前一字符非 ASCII `\w`/#，
//! 大小写不敏感去重保首形，小写落库。

use std::sync::Mutex;

use rusqlite::Connection;

pub struct TagStore {
    conn: Mutex<Connection>,
}

fn extract_tags(markdown: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut seen: std::collections::HashSet<String> = Default::default();
    let mut fence = false;
    for line in markdown.split('\n') {
        let trimmed = line.trim_start();
        let leading = line.len() - trimmed.len();
        if leading <= 3 && trimmed.starts_with("```") {
            fence = !fence;
            continue;
        }
        if fence {
            continue;
        }
        scan_line(line, &mut seen, &mut out);
        if out.len() >= 64 {
            return out;
        }
    }
    out
}

/// `(?<![A-Za-z0-9_#])#([\p{L}\p{N}_/-]{1,32})` —— Rust regex 不支持 lookbehind，
/// 手写逐行扫描：找 '#'，检查前一字符（或行首）非 ASCII 词字符/'#'，再吃 tag 字符。
fn simple_tag_re() -> &'static regex::Regex {
    use std::sync::OnceLock;
    static RE: OnceLock<regex::Regex> = OnceLock::new();
    RE.get_or_init(|| {
        regex::Regex::new(r"#([\p{L}\p{N}_/-]{1,32})").expect("tag regex")
    })
}

fn prev_is_boundary(line: &str, hash_pos: usize) -> bool {
    if hash_pos == 0 {
        return true;
    }
    // 与 JS `[^\w#]` 同语义：ASCII \w 与 '#' 都算不上边界。
    match line[..hash_pos].chars().last() {
        None => true,
        Some(c) => !(c.is_ascii_alphanumeric() || c == '_' || c == '#'),
    }
}

fn scan_line(line: &str, seen: &mut std::collections::HashSet<String>, out: &mut Vec<String>) {
    let bytes = line.as_bytes();
    for (i, b) in bytes.iter().enumerate() {
        if *b == b'#' && prev_is_boundary(line, i) {
            if let Some(m) = simple_tag_re().find_at(line, i) {
                if m.start() == i {
                    let raw = &m.as_str()[1..];
                    let key = raw.to_lowercase();
                    if seen.insert(key.clone()) {
                        out.push(key);
                    }
                }
            }
        }
        if out.len() >= 64 {
            return;
        }
    }
}

impl TagStore {
    pub fn open(path: &std::path::Path) -> TagStore {
        let conn = Connection::open(path).expect("open tags.db");
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS note_tags (
                item_id TEXT NOT NULL,
                tag TEXT NOT NULL,
                PRIMARY KEY (item_id, tag)
            );
            CREATE INDEX IF NOT EXISTS idx_note_tags_tag ON note_tags(tag, item_id);",
        )
        .expect("init tags.db");
        TagStore { conn: Mutex::new(conn) }
    }

    pub fn refresh(&self, item_id: &str, markdown: &str) {
        let tags = extract_tags(markdown);
        let mut conn = self.conn.lock().expect("tags lock");
        let _ = conn.execute("DELETE FROM note_tags WHERE item_id = ?1", [item_id]);
        for tag in tags {
            let _ = conn.execute(
                "INSERT OR IGNORE INTO note_tags (item_id, tag) VALUES (?1, ?2)",
                rusqlite::params![item_id, tag],
            );
        }
    }

    pub fn clear(&self, item_id: &str) {
        let mut conn = self.conn.lock().expect("tags lock");
        let _ = conn.execute("DELETE FROM note_tags WHERE item_id = ?1", [item_id]);
    }

    pub fn for_note(&self, item_id: &str) -> Vec<String> {
        let conn = self.conn.lock().expect("tags lock");
        let mut stmt = match conn.prepare("SELECT tag FROM note_tags WHERE item_id = ?1 ORDER BY tag") {
            Ok(s) => s,
            Err(_) => return vec![],
        };
        stmt.query_map([item_id], |r| r.get::<_, String>(0))
            .map(|rows| rows.filter_map(Result::ok).collect())
            .unwrap_or_default()
    }

    pub fn counts(&self) -> Vec<(String, i64)> {
        let conn = self.conn.lock().expect("tags lock");
        let mut stmt = match conn
            .prepare("SELECT tag, COUNT(*) n FROM note_tags GROUP BY tag ORDER BY n DESC, tag LIMIT 200")
        {
            Ok(s) => s,
            Err(_) => return vec![],
        };
        stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
            .map(|rows| rows.filter_map(Result::ok).collect())
            .unwrap_or_default()
    }

    pub fn notes_with_tag(&self, tag: &str) -> Vec<String> {
        let conn = self.conn.lock().expect("tags lock");
        let mut stmt = match conn
            .prepare("SELECT item_id FROM note_tags WHERE tag = ?1 ORDER BY rowid DESC LIMIT 200")
        {
            Ok(s) => s,
            Err(_) => return vec![],
        };
        stmt.query_map([tag], |r| r.get(0))
            .map(|rows| rows.filter_map(Result::ok).collect())
            .unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extraction_matches_mac_semantics() {
        assert_eq!(extract_tags("x #Foo y #foo z #FOO"), ["foo"]);
        assert_eq!(extract_tags("#a\n```\n#inside\n```\n#after"), ["a", "after"]);
        assert_eq!(extract_tags("abc#tag"), Vec::<String>::new());
        assert_eq!(extract_tags("结尾#标签1"), ["标签1"]);
        assert_eq!(extract_tags("##tag"), Vec::<String>::new());
        assert_eq!(extract_tags("#a #b"), ["a", "b"]);
        assert_eq!(extract_tags("#os/cc"), ["os/cc"]);
        assert_eq!(extract_tags("# 标题"), Vec::<String>::new());
    }
}
