//! clipvault-flush: drain the collector spool into PostgreSQL.
//!
//! Safe to run from a timer/systemd unit. Rows that fail to insert stay in the
//! spool; the file is moved to `done/` only when every line landed.

use std::path::{Path, PathBuf};

use anyhow::Result;
use clipvault_session::config;
use clipvault_session::metrics;
use clipvault_session::model::{self, HookEvent};
use serde_json::Value;
use tokio_postgres::NoTls;

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    let spool_dir = PathBuf::from(config::var(
        "CLIPVAULT_HOOK_SPOOL",
        "/var/tmp/clipvault-hooks/spool",
    ));
    std::fs::create_dir_all(&spool_dir).ok();
    let cfg = config::pg_config()?;
    let (client, connection) = cfg.connect(NoTls).await?;
    let driver = tokio::spawn(async move {
        let _ = connection.await;
    });
    let written = flush_once(&client, &spool_dir).await.unwrap_or(0);
    driver.abort();
    if written > 0 {
        println!("flushed {written} rows");
    }
    Ok(())
}

async fn flush_once(client: &tokio_postgres::Client, spool_dir: &Path) -> Result<usize> {
    let mut written = 0usize;
    let mut entries: Vec<PathBuf> = std::fs::read_dir(spool_dir)?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .collect();
    entries.sort();
    for path in entries {
        let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        let is_hooks = name.starts_with("hooks-") && name.ends_with(".jsonl");
        let is_metrics = name.starts_with("metrics-") && name.ends_with(".jsonl");
        if !is_hooks && !is_metrics {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(&path) else {
            continue;
        };
        let mut remain: Vec<String> = Vec::new();
        for line in text.lines() {
            if line.trim().is_empty() {
                continue;
            }
            let sent = match serde_json::from_str::<Value>(line) {
                Ok(value) => {
                    if is_hooks {
                        match model::from_row_value(&value) {
                            Some(row) => insert_hook(client, &row).await,
                            None => false,
                        }
                    } else {
                        insert_metric(client, &value).await
                    }
                }
                Err(_) => false,
            };
            if sent {
                written += 1;
            } else {
                remain.push(line.to_string());
            }
        }
        if remain.is_empty() {
            let done = spool_dir.join("done");
            std::fs::create_dir_all(&done).ok();
            let dest = unique(&done, name);
            std::fs::rename(&path, &dest).ok();
        } else {
            let _ = std::fs::write(&path, format!("{}\n", remain.join("\n")));
        }
    }
    Ok(written)
}

async fn insert_hook(client: &tokio_postgres::Client, row: &HookEvent) -> bool {
    row.insert(client).await.is_ok()
}

async fn insert_metric(client: &tokio_postgres::Client, payload: &Value) -> bool {
    let event = payload
        .get("hook_event_name")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let (table, cols, row) = if event == "UsageReport" {
        (metrics::USAGE_TABLE, metrics::USAGE_COLS, metrics::usage_row(payload))
    } else if event == "ContextReport" {
        (metrics::CTX_TABLE, metrics::CTX_COLS, metrics::ctx_row(payload))
    } else {
        return false;
    };
    metrics::insert_row(client, table, cols, &row).await.is_ok()
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
