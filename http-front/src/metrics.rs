//! HTTP-front metrics for metrics-based opt.
//!
//! Per-request `http_req` lands in `ui-metrics.db` via a JSONL spool that
//! Swift drains. Payload has no content keys. Drop rather than block the hop.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::OnceLock;
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::json;
use tokio::sync::mpsc;

static INFLIGHT: AtomicU64 = AtomicU64::new(0);
static TX: OnceLock<mpsc::UnboundedSender<HttpEvent>> = OnceLock::new();

const SPOOL_CAP: u64 = 2 * 1024 * 1024;

#[derive(Clone)]
struct HttpEvent {
    ts_ms: i64,
    dur_ms: f64,
    ok: bool,
    status: u16,
    method: String,
    route: String,
    proto: String,
    phase: String,
    origin_ms: f64,
    bytes_in: u64,
    bytes_out: u64,
}

pub fn inflight_inc() {
    INFLIGHT.fetch_add(1, Ordering::Relaxed);
}

pub fn inflight_dec() {
    INFLIGHT.fetch_sub(1, Ordering::Relaxed);
}

pub fn start(home: PathBuf) {
    let (tx, mut rx) = mpsc::unbounded_channel::<HttpEvent>();
    let _ = TX.set(tx);
    let path = home.join("run").join("http-metrics.jsonl");
    tokio::spawn(async move {
        if let Some(dir) = path.parent() {
            let _ = fs::create_dir_all(dir);
        }
        let mut buf: Vec<HttpEvent> = Vec::with_capacity(32);
        loop {
            buf.clear();
            match rx.recv().await {
                Some(ev) => buf.push(ev),
                None => break,
            }
            while buf.len() < 32 {
                match rx.try_recv() {
                    Ok(ev) => buf.push(ev),
                    Err(_) => break,
                }
            }
            if let Err(e) = flush(&path, &buf) {
                eprintln!("[http] metrics spool: {e}");
            }
        }
    });
}

pub fn emit(
    dur_ms: f64,
    origin_ms: f64,
    ok: bool,
    status: u16,
    method: &str,
    path: &str,
    proto: &str,
    phase: &str,
    bytes_in: u64,
    bytes_out: u64,
) {
    let Some(tx) = TX.get() else { return };
    let ev = HttpEvent {
        ts_ms: now_ms(),
        dur_ms,
        ok,
        status,
        method: clip32(&method.to_ascii_lowercase()),
        route: route(path),
        proto: clip32(proto),
        phase: clip32(phase),
        origin_ms,
        bytes_in,
        bytes_out,
    };
    let _ = tx.send(ev);
}

pub fn route(path: &str) -> String {
    let bare = path.split('?').next().unwrap_or("/");
    let mut out = String::new();
    for part in bare.split('/') {
        if part.is_empty() {
            continue;
        }
        out.push('/');
        if looks_id(part) {
            out.push('_');
        } else {
            out.push_str(part);
        }
    }
    if out.is_empty() {
        out.push('/');
    }
    clip32(&out)
}

fn looks_id(s: &str) -> bool {
    let n = s.len();
    if n == 64 && s.bytes().all(|b| b.is_ascii_hexdigit()) {
        return true;
    }
    if n == 36 {
        let b = s.as_bytes();
        return b[8] == b'-'
            && b[13] == b'-'
            && b[18] == b'-'
            && b[23] == b'-'
            && s.bytes().all(|c| c.is_ascii_hexdigit() || c == b'-');
    }
    false
}

fn clip32(s: &str) -> String {
    if s.len() <= 32 {
        s.to_string()
    } else {
        s.chars().take(32).collect()
    }
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn flush(path: &std::path::Path, batch: &[HttpEvent]) -> std::io::Result<()> {
    if batch.is_empty() {
        return Ok(());
    }
    if let Ok(meta) = fs::metadata(path) {
        if meta.len() > SPOOL_CAP {
            let _ = fs::remove_file(path);
        }
    }
    let mut f = OpenOptions::new().create(true).append(true).open(path)?;
    for ev in batch {
        let line = json!({
            "name": "http_req",
            "ts": ev.ts_ms,
            "dur_ms": ev.dur_ms,
            "ok": ev.ok,
            "session": "http",
            "payload": {
                "kind": ev.method,
                "route": ev.route,
                "proto": ev.proto,
                "phase": ev.phase,
                "n": ev.status,
                "lag": ev.origin_ms,
                "bytes": ev.bytes_out,
                "value": ev.bytes_in,
            }
        });
        writeln!(f, "{line}")?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::route;

    #[test]
    fn route_strips_query_and_ids() {
        assert_eq!(route("/"), "/");
        assert_eq!(route("/api/clips?limit=40"), "/api/clips");
        assert_eq!(
            route("/api/image?sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
            "/api/image"
        );
        assert_eq!(
            route("/api/items/11111111-1111-1111-1111-111111111111/events"),
            "/api/items/_/events"
        );
        let asset = route("/assets/notes-editor/notes-editor.js");
        assert!(asset.starts_with("/assets/notes-editor/"));
        assert!(asset.len() <= 32);
    }
}
