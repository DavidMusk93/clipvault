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
use std::time::{Duration, Instant, SystemTime};

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
const PRUNE_INTERVAL: Duration = Duration::from_secs(3600);
/// Bound one PostgreSQL call. docker-proxy accepts and ACKs on 127.0.0.1 even
/// when the container bridge is gone, so a query never errors and never
/// finishes. Without this the drain loop wedges and the spool grows forever.
const PG_CALL: Duration = Duration::from_secs(20);

/// Age after which a consumed spool file is deleted from `done/`. Set
/// `CLIPVAULT_DONE_RETENTION_DAYS=0` to keep every file forever.
fn done_retention() -> Option<Duration> {
    let days = config::var("CLIPVAULT_DONE_RETENTION_DAYS", "7")
        .parse::<u64>()
        .ok()?;
    (days > 0).then(|| Duration::from_secs(days * 24 * 3600))
}

/// Drop `done/` files older than `retention` (they are already in PostgreSQL).
/// Without this the archive grows without bound: one file per drained event.
fn prune_done(spool_dir: &Path, retention: Duration) -> usize {
    let Ok(read) = std::fs::read_dir(spool_dir.join("done")) else {
        return 0;
    };
    let now = SystemTime::now();
    let mut removed = 0;
    for entry in read.flatten() {
        let Ok(meta) = entry.metadata() else { continue };
        if !meta.is_file() {
            continue;
        }
        let expired = meta
            .modified()
            .ok()
            .and_then(|m| now.duration_since(m).ok())
            .map(|age| age >= retention)
            .unwrap_or(false);
        if expired && std::fs::remove_file(entry.path()).is_ok() {
            removed += 1;
        }
    }
    removed
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    let once = std::env::args().any(|a| a == "--once");
    let spool_dir = PathBuf::from(config::var(
        "CLIPVAULT_HOOK_SPOOL",
        "/var/tmp/clipvault-hooks/spool",
    ));
    std::fs::create_dir_all(&spool_dir).ok();

    let retention = done_retention();
    let mut sink = PgSink::new(config::pg_config()?);
    if once {
        println!("flushed {} rows", sink.drain(&spool_dir).await);
        if let Some(r) = retention {
            prune_done(&spool_dir, r);
        }
        return Ok(());
    }

    if let Some(r) = retention {
        let n = prune_done(&spool_dir, r);
        if n > 0 {
            eprintln!("clipvault-flush: pruned {n} done/ files");
        }
    }

    let wake_addr = config::var("CLIPVAULT_FLUSH_WAKE", "127.0.0.1:19499");
    let socket = UdpSocket::bind(&wake_addr)
        .await
        .with_context(|| format!("bind wake socket {wake_addr}"))?;
    eprintln!("clipvault-flush: listening for wakeups on {wake_addr}");

    let mut buf = [0u8; 16];
    let mut last_prune = Instant::now();
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
        if let Some(r) = retention {
            if last_prune.elapsed() >= PRUNE_INTERVAL {
                let n = prune_done(&spool_dir, r);
                if n > 0 {
                    eprintln!("clipvault-flush: pruned {n} done/ files");
                }
                last_prune = Instant::now();
            }
        }
    }
}

/// Why a write did not land. `Transport` means the connection itself is
/// unusable (timeout, reset); the spool file must stay for the next pass.
/// `Rejected` means PostgreSQL answered and refused the statement.
enum WriteError {
    Transport,
    Rejected,
}

fn classify(err: &anyhow::Error) -> WriteError {
    let text = format!("{err:#}").to_ascii_lowercase();
    if text.contains("connection")
        || text.contains("closed")
        || text.contains("timed out")
        || text.contains("timeout")
        || text.contains("broken pipe")
        || text.contains("reset")
        || text.contains("communicating")
    {
        WriteError::Transport
    } else {
        WriteError::Rejected
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

        match self.batch_hooks(&batch).await {
            Ok(()) => {
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
            // The bridge accepted the TCP handshake and then answered nothing.
            // Per-row retries would each wait out PG_CALL and pin the spool.
            Err(WriteError::Transport) => return 0,
            Err(WriteError::Rejected) => {}
        }

        // Statement rejected: isolate per row so one bad row cannot block the rest.
        // A transport failure stops the pass and leaves the remaining files untouched.
        let mut written = 0;
        for file in &files {
            let mut remain = Vec::new();
            let mut stopped = false;
            for (line, row) in file.lines.iter().zip(&file.rows) {
                if stopped {
                    remain.push(line.clone());
                    continue;
                }
                match row {
                    Some(event) => match self.write_hook_one(event).await {
                        Ok(()) => written += 1,
                        Err(WriteError::Rejected) => remain.push(line.clone()),
                        Err(WriteError::Transport) => {
                            stopped = true;
                            remain.push(line.clone());
                        }
                    },
                    None => remain.push(line.clone()),
                }
            }
            finish_file(spool_dir, &file.path, remain);
            if stopped {
                return written;
            }
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

    async fn batch_hooks(&mut self, rows: &[db::Row]) -> Result<(), WriteError> {
        let inserted = {
            let Ok(client) = self.client().await else {
                eprintln!("clipvault-flush: pg connect failed");
                return Err(WriteError::Transport);
            };
            tokio::time::timeout(
                PG_CALL,
                db::insert_batch(client, "hook_events", &model::HOOK_COLS, rows),
            )
            .await
        };
        match inserted {
            Ok(Ok(_)) => Ok(()),
            Ok(Err(e)) => {
                eprintln!("clipvault-flush: batch insert failed: {e:#}");
                self.drop_connection();
                Err(classify(&e))
            }
            Err(_) => {
                eprintln!("clipvault-flush: batch insert timed out");
                self.drop_connection();
                Err(WriteError::Transport)
            }
        }
    }

    async fn write_hook_one(&mut self, row: &HookEvent) -> Result<(), WriteError> {
        let inserted = {
            let Ok(client) = self.client().await else {
                eprintln!("clipvault-flush: pg connect failed");
                return Err(WriteError::Transport);
            };
            tokio::time::timeout(PG_CALL, row.insert(client)).await
        };
        match inserted {
            Ok(Ok(n)) => {
                if n > 0 {
                    if let Ok(client) = self.client().await {
                        notify(client, &row.sse_payload().to_string()).await;
                    }
                }
                Ok(())
            }
            Ok(Err(e)) => {
                eprintln!("clipvault-flush: insert failed: {e:#}");
                self.drop_connection();
                Err(classify(&e))
            }
            Err(_) => {
                eprintln!("clipvault-flush: insert timed out");
                self.drop_connection();
                Err(WriteError::Transport)
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
        let inserted = {
            let Ok(client) = self.client().await else {
                eprintln!("clipvault-flush: pg connect failed");
                return false;
            };
            tokio::time::timeout(PG_CALL, metrics::insert_row(client, table, cols, &row)).await
        };
        match inserted {
            Ok(Ok(())) => true,
            Ok(Err(e)) => {
                eprintln!("clipvault-flush: metric insert failed: {e:#}");
                self.drop_connection();
                false
            }
            Err(_) => {
                eprintln!("clipvault-flush: metric insert timed out");
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
