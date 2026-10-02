//! clipvault-ingest: cold-path backfill of llm_usage / turn_context from pi
//! session JSONL. Lossless + retroactive; only ttft is missing (hot path owns it,
//! so re-ingest preserves it via COALESCE).

use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use clipvault_session::config;
use clipvault_session::db;
use clipvault_session::ingest;
use clipvault_session::metrics;
use tokio_postgres::NoTls;

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    let mut sessions_dir = config::var("CLIPVAULT_PI_SESSIONS", "~/.pi/agent/sessions");
    let mut instance_id = config::var("CLIPVAULT_INSTANCE_ID", "unknown");
    let mut source = config::var("CLIPVAULT_HOOK_SOURCE", "pi");
    let mut since_days = 30i64;
    let mut chars_per_token: Option<f64> = None;
    let mut dry_run = false;
    let mut quiet = false;
    let mut want_sessions: Vec<String> = Vec::new();

    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut i = 0;
    while i < args.len() {
        let need = |i: usize| args.get(i + 1).cloned().unwrap_or_default();
        match args[i].as_str() {
            "--sessions-dir" => {
                sessions_dir = need(i);
                i += 2;
            }
            "--instance-id" => {
                instance_id = need(i);
                i += 2;
            }
            "--source" => {
                source = need(i);
                i += 2;
            }
            "--since" => {
                since_days = need(i).parse().unwrap_or(30);
                i += 2;
            }
            "--chars-per-token" => {
                chars_per_token = need(i).parse().ok();
                i += 2;
            }
            "--session-id" => {
                want_sessions.push(need(i));
                i += 2;
            }
            "--dry-run" => {
                dry_run = true;
                i += 1;
            }
            "--quiet" => {
                quiet = true;
                i += 1;
            }
            _ => i += 1,
        }
    }

    let dir = expand_home(&sessions_dir);
    let mut files = collect_jsonl(&dir);
    files.sort();
    if since_days > 0 {
        let cutoff = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0)
            .saturating_sub((since_days as u64) * 86400);
        files.retain(|p| {
            std::fs::metadata(p)
                .and_then(|m| m.modified())
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_secs() >= cutoff)
                .unwrap_or(true)
        });
    }
    if !want_sessions.is_empty() {
        files.retain(|p| {
            let name = p.file_name().and_then(|n| n.to_str()).unwrap_or("");
            want_sessions.iter().any(|w| name.contains(w))
        });
    }

    let host = hostname::get()
        .map(|h| h.to_string_lossy().to_string())
        .unwrap_or_default();

    let mut client_opt = None;
    if !dry_run {
        let cfg = config::pg_config()?;
        let (client, connection) = cfg.connect(NoTls).await.context("pg connect")?;
        tokio::spawn(async move {
            let _ = connection.await;
        });
        client_opt = Some(client);
    }

    let mut total_usage = 0usize;
    let mut total_ctx = 0usize;
    let mut total_files = 0usize;
    let mut cost_sum = 0.0f64;
    let mut usage_buf: Vec<db::Row> = Vec::new();
    let mut ctx_buf: Vec<db::Row> = Vec::new();
    for path in &files {
        let entries = ingest::load_entries(path);
        let analysis = ingest::analyze(&entries, chars_per_token);
        if analysis.records.is_empty() {
            continue;
        }
        let (usage_rows, ctx_rows) = ingest::build_rows(&analysis, &instance_id, &source, &host);
        let file_cost: f64 = usage_rows
            .iter()
            .map(|r| match metrics::get(r, "cost_total") {
                Some(v) => v.as_f64().unwrap_or(0.0),
                None => 0.0,
            })
            .sum();
        cost_sum += file_cost;
        total_files += 1;
        total_usage += usage_rows.len();
        total_ctx += ctx_rows.len();
        if !quiet {
            let sid = &analysis.session_id[..analysis.session_id.len().min(12)];
            println!(
                "  {sid}  turns={:3}  cpt={:.2}  cost=${:.4}",
                usage_rows.len(),
                analysis.cpt,
                file_cost
            );
        }
        if dry_run {
            continue;
        }
        usage_buf.extend(usage_rows);
        ctx_buf.extend(ctx_rows);
        if let Some(client) = client_opt.as_ref() {
            if usage_buf.len() >= 500 {
                metrics::upsert_batch(
                    client,
                    ingest::USAGE_TABLE_NAME,
                    ingest::USAGE_KEY,
                    &usage_buf,
                    ingest::USAGE_LIVE_COLS,
                )
                .await?;
                usage_buf.clear();
            }
            if ctx_buf.len() >= 500 {
                metrics::upsert_batch(
                    client,
                    ingest::CTX_TABLE_NAME,
                    ingest::CTX_KEY,
                    &ctx_buf,
                    &[],
                )
                .await?;
                ctx_buf.clear();
            }
        }
    }

    if let Some(client) = client_opt.as_ref() {
        if !usage_buf.is_empty() {
            metrics::upsert_batch(
                client,
                ingest::USAGE_TABLE_NAME,
                ingest::USAGE_KEY,
                &usage_buf,
                ingest::USAGE_LIVE_COLS,
            )
            .await?;
        }
        if !ctx_buf.is_empty() {
            metrics::upsert_batch(
                client,
                ingest::CTX_TABLE_NAME,
                ingest::CTX_KEY,
                &ctx_buf,
                &[],
            )
            .await?;
        }
    }

    let mode = if dry_run { "dry-run" } else { "postgres" };
    println!(
        "\n{mode}: files={total_files} llm_usage={total_usage} turn_context={total_ctx} cost_total=${cost_sum:.4}"
    );
    Ok(())
}

fn expand_home(p: &str) -> PathBuf {
    if let Some(rest) = p.strip_prefix("~/") {
        if let Ok(home) = std::env::var("HOME") {
            return PathBuf::from(home).join(rest);
        }
    }
    PathBuf::from(p)
}

fn collect_jsonl(dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let Ok(rd) = std::fs::read_dir(dir) else {
        return out;
    };
    for entry in rd.flatten() {
        let path = entry.path();
        if path.is_dir() {
            out.extend(collect_jsonl(&path));
        } else if path.extension().and_then(|e| e.to_str()) == Some("jsonl") {
            out.push(path);
        }
    }
    out
}
