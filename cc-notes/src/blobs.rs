//! cc 侧 blob CAS（mac 域对齐）：**SHA256** 键（mac `/api/image?sha=` 的语义），
//! 独立 `blobs.db` —— notebase 自带 blobs 是 blake3 哈希域，两个域不混。
//! relay（pull/publish）只读写本 store；serve_blob 也只查这里。

use std::sync::Mutex;

use rusqlite::Connection;
use sha2::{Digest, Sha256};

pub struct BlobStore {
    conn: Mutex<Connection>,
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    let mut h = Sha256::new();
    h.update(bytes);
    hex(&h.finalize())
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

impl BlobStore {
    pub fn open(path: &std::path::Path) -> BlobStore {
        let conn = Connection::open(path).expect("open blobs.db");
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS blobs (
                sha TEXT PRIMARY KEY,
                size INTEGER NOT NULL,
                bytes BLOB NOT NULL
            );",
        )
        .expect("init blobs.db");
        BlobStore { conn: Mutex::new(conn) }
    }

    /// 按 CAS 语义写入：键 = 字节的 sha256（与 mac 一致）；内容不符即拒。
    pub fn put(&self, expect_sha: &str, bytes: &[u8]) -> Result<(), String> {
        let actual = sha256_hex(bytes);
        if !actual.eq_ignore_ascii_case(expect_sha) {
            return Err(format!(
                "blob sha mismatch: expected {expect_sha}, got {actual}"
            ));
        }
        let conn = self.conn.lock().expect("blobs lock");
        conn.execute(
            "INSERT OR REPLACE INTO blobs (sha, size, bytes) VALUES (?1, ?2, ?3)",
            rusqlite::params![expect_sha.to_lowercase(), bytes.len() as i64, bytes],
        )
        .map_err(|e| e.to_string())?;
        Ok(())
    }

    pub fn get(&self, sha: &str) -> Option<Vec<u8>> {
        let conn = self.conn.lock().expect("blobs lock");
        conn.query_row("SELECT bytes FROM blobs WHERE sha = ?1", [sha], |r| {
            r.get::<_, Vec<u8>>(0)
        })
        .ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cas_semantics() {
        let s = {
            let conn = Connection::open_in_memory().unwrap();
            conn.execute_batch("CREATE TABLE blobs (sha TEXT PRIMARY KEY, size INTEGER NOT NULL, bytes BLOB NOT NULL);").unwrap();
            BlobStore { conn: Mutex::new(conn) }
        };
        let bytes = b"hello blob";
        let sha = sha256_hex(bytes);
        s.put(&sha, bytes).unwrap();
        assert_eq!(s.get(&sha).unwrap(), bytes.to_vec());
        // 键与内容不符 = 拒（CAS 完整性）
        assert!(s.put(&sha, b"tampered").is_err());
        assert!(s.get("00").is_none());
    }
}
