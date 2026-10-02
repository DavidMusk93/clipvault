//! clipvault-flush: the collector's PostgreSQL writer.
//!
//! Two modes:
//!   * `--once`  : drain the spool and exit (one-shot watchdog for cron/launchd).
//!   * default   : long-lived daemon. It holds one PostgreSQL connection and
//!                 drains on a **readiness wakeup** (a 1-byte UDP datagram the
//!                 hook sends after spooling), with a slow watchdog fallback.
//!
//! The hook never touches PostgreSQL: a per-event connection over `ssh -L`
//! costs a full SCRAM handshake (~6 RTT). The daemon amortises that, and every
//! drain collapses a burst into **one** multi-row INSERT per table.
//!
//!     clipvault-hook  --udp-->  clipvault-flush  --persistent conn--> PostgreSQL
//!          |                         ^
//!          +---- one JSONL file per event ----+

use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{Context, Result};
use clipvault_session::config;
use clipvault_session::db;
use clipvault_session::metrics;
use clipvault_session::model::{self, HookEvent};
use serde_json::Value;
use tokio::net::UdpSocket;
use tokio::task::JoinHandle;
use tokio_postgres::{Client, NoTls};

const WATCHDOG: Duration = Duration::from_secs(30);

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    let once = std::env::args().any(|a| a == "--once");
    let spool_dir = PathBuf::from(config::var(
        "CLIPVAULT_HOOK_SPOOL",
        "/var/tmp/clipvault-hooks/spool",
    ));
    std::fs::create_dir_all(&spool_dir).ok();

    let mut sink = PgSink::new(config::pg_config()?);
    if once {
        println!("flushed {} rows", sink.drain(&spool_dir).await);
        return Ok(());
    }

    let wake_addr = config::var("CLIPVAULT_FLUSH_WAKE", "127.0.0.1:19499");
    let socket = UdpSocket::bind(&wake_addr)
        .await
        .with_context(|| format!("bind wake socket {wake_addr}"))?;
    eprintln!("clipvault-flush: listening for wakeups on {wake_addr}");

    let mut buf = [0u8; 16];
    loop {
        tokio::select! {
            r = socket.recv_from(&mut buf) => {
                if let Err(e) = r {
                    eprintln!("wake recv: {e}");
                    tokio::time::sleep(Duration::from_secs(1)).await;
                }
            }
            _ = tokio::time::sleep(WATCHDOG) => {}
        }
        // Drain until empty so a burst of wakeups collapses into one pass.
        while sink.drain(&spool_dir).await > 0 {}
    }
}

/// A reconnectable PostgreSQL writer. The driver task is aborted and the
/// connection rebuilt on failure so a tunnel/db bounce does not wedge the loop.
struct PgSink {
    cfg: tokio_postgres::Config,
    conn: Option<(Client, JoinHandle<()>)>,
}

/// A spooled hook file: its raw lines and the parsed row per line (`None` =
/// unparsable, kept and re-written rather than dropped).
struct HookFile {
    path: PathBuf,
    lines: Vec<String>,
    rows: Vec<Option<HookEvent>>,
}

impl PgSink {
    fn new(cfg: tokio_postgres::Config) -> Self {
        Self { cfg, conn: None }
    }

    async fn client(&mut self) -> Result<&Client> {
        if self.conn.is_none() {
            let (client, connection) = self.cfg.connect(NoTls).await.context("pg connect")?;
            let driver = tokio::spawn(async move {
                let _ = connection.await;
            });
            self.conn = Some((client, driver));
        }
        Ok(&self.conn.as_ref().expect("connected").0)
    }

    fn drop_connection(&mut self) {
        if let Some((_, driver)) = self.conn.take() {
            driver.abort();
        }
    }

    /// Insert every spooled row. Files move to `done/` only when every line
    /// landed; a bad store leaves rows in the spool and never stops the loop.
    async fn drain(&mut self, spool_dir: &Path) -> usize {
        let (hook_files, metric_files) = self.collect(spool_dir);
        let mut written = self.drain_hooks(spool_dir, hook_files).await;
        written += self.drain_metrics(spool_dir, &metric_files).await;
        written
    }

    fn collect(&self, spool_dir: &Path) -> (Vec<HookFile>, Vec<(PathBuf, Vec<String>)>) {
        let mut hook_files = Vec::new();
        let mut metric_files = Vec::new();
        let Ok(read) = std::fs::read_dir(spool_dir) else {
            return (hook_files, metric_files);
        };
        let mut entries: Vec<PathBuf> = read.filter_map(|e| e.ok().map(|e| e.path())).collect();
        entries.sort();
        for path in entries {
            let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
                continue;
            };
            let hooks = name.starts_with("hooks-") && name.ends_with(".jsonl");
            let metrics = name.starts_with("metrics-") && name.ends_with(".jsonl");
            if !hooks && !metrics {
                continue;
            }
            let Ok(text) = std::fs::read_to_string(&path) else {
                continue;
            };
            let lines: Vec<String> = text
                .lines()
                .filter(|l| !l.trim().is_empty())
                .map(str::to_string)
                .collect();
            if hooks {
                let rows = lines
                    .iter()
                    .map(|l| {
                        serde_json::from_str::<Value>(l)
                            .ok()
                            .and_then(|v| model::from_row_value(&v))
                    })
                    .collect();
                hook_files.push(HookFile { path, lines, rows });
            } else {
                metric_files.push((path, lines));
            }
        }
        (hook_files, metric_files)
    }

    async fn drain_hooks(&mut self, spool_dir: &Path, files: Vec<HookFile>) -> usize {
        let batch: Vec<db::Row> = files
            .iter()
            .flat_map(|f| f.rows.iter().flatten())
            .map(HookEvent::to_row)
            .collect();
        if batch.is_empty() {
            for file in &files {
                finish_file(spool_dir, &file.path, file.lines.clone());
            }
            return 0;
        }

        if self.batch_hooks(&batch).await {
            let mut written = 0;
            for file in &files {
                written += file.rows.iter().filter(|r| r.is_some()).count();
                let unparsable: Vec<String> = file
                    .lines
                    .iter()
                    .zip(&file.rows)
                    .filter(|(_, r)| r.is_none())
                    .map(|(l, _)| l.clone())
                    .collect();
                finish_file(spool_dir, &file.path, unparsable);
            }
            return written;
        }

        // Batch failed: isolate per row so one bad row cannot block the rest.
        let mut written = 0;
        for file in &files {
            let mut remain = Vec::new();
            for (line, row) in file.lines.iter().zip(&file.rows) {
                match row {
                    Some(event) if self.write_hook_one(event).await => written += 1,
                    _ => remain.push(line.clone()),
                }
            }
            finish_file(spool_dir, &file.path, remain);
        }
        written
    }

    async fn drain_metrics(&mut self, spool_dir: &Path, files: &[(PathBuf, Vec<String>)]) -> usize {
        let mut written = 0;
        for (path, lines) in files {
            let mut remain = Vec::new();
            for line in lines {
                let ok = match serde_json::from_str::<Value>(line) {
                    Ok(value) => self.write_metric(&value).await,
                    Err(_) => false,
                };
                if ok {
                    written += 1;
                } else {
                    remain.push(line.clone());
                }
            }
            finish_file(spool_dir, path, remain);
        }
        written
    }

    async fn batch_hooks(&mut self, rows: &[db::Row]) -> bool {
        let Ok(client) = self.client().await else {
            return false;
        };
        match db::insert_batch(client, "hook_events", &model::HOOK_COLS, rows).await {
            Ok(_) => true,
            Err(_) => {
                self.drop_connection();
                false
            }
        }
    }

    async fn write_hook_one(&mut self, row: &HookEvent) -> bool {
        let Ok(client) = self.client().await else {
            return false;
        };
        match row.insert(client).await {
            Ok(n) => {
                if n > 0 {
                    notify(client, &row.sse_payload().to_string()).await;
                }
                true
            }
            Err(_) => {
                self.drop_connection();
                false
            }
        }
    }

    async fn write_metric(&mut self, payload: &Value) -> bool {
        let event = payload
            .get("hook_event_name")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let (table, cols, row) = if event == "UsageReport" {
            (
                metrics::USAGE_TABLE,
                metrics::USAGE_COLS,
                metrics::usage_row(payload),
            )
        } else if event == "ContextReport" {
            (
                metrics::CTX_TABLE,
                metrics::CTX_COLS,
                metrics::ctx_row(payload),
            )
        } else {
            return false;
        };
        let Ok(client) = self.client().await else {
            return false;
        };
        match metrics::insert_row(client, table, cols, &row).await {
            Ok(()) => true,
            Err(_) => {
                self.drop_connection();
                false
            }
        }
    }
}

/// Move a consumed file to `done/`, or rewrite the lines that did not land.
fn finish_file(spool_dir: &Path, path: &Path, remain: Vec<String>) {
    if remain.is_empty() {
        let done = spool_dir.join("done");
        std::fs::create_dir_all(&done).ok();
        let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("spool");
        std::fs::rename(path, unique(&done, name)).ok();
    } else {
        let _ = std::fs::write(path, format!("{}\n", remain.join("\n")));
    }
}

async fn notify(client: &Client, payload: &str) {
    if payload.len() > 7900 {
        return;
    }
    let _ = client
        .execute(
            "SELECT pg_notify($1, $2)",
            &[&model::NOTIFY_CHANNEL, &payload],
        )
        .await;
}

fn unique(dir: &Path, name: &str) -> PathBuf {
    let dest = dir.join(name);
    if !dest.exists() {
        return dest;
    }
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    dir.join(format!("{stamp}-{name}"))
}
