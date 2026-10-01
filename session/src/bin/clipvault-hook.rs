//! clipvault-hook: fail-open collector. stdin JSON -> spool -> PostgreSQL -> NOTIFY.
//!
//! INV-4: every path exits 0. If the store is unreachable the row stays in the
//! spool (`hooks-YYYYMMDD.jsonl`) and an on-host flusher retries later.

use std::io::Read;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::Result;
use clipvault_session::config;
use clipvault_session::model::{self, HookEvent};
use serde_json::{json, Value};
use tokio_postgres::NoTls;

fn main() {
    let code = run();
    std::process::exit(code);
}

fn run() -> i32 {
    let event_arg = parse_event_arg();
    let hook_event = event_arg
        .clone()
        .filter(|s| !s.is_empty())
        .or_else(|| std::env::var("CLIPVAULT_HOOK_EVENT").ok())
        .unwrap_or_default();
    let instance_id = config::var("CLIPVAULT_INSTANCE_ID", "unknown");
    let source = config::var("CLIPVAULT_HOOK_SOURCE", "trae");
    let spool_dir = config::var("CLIPVAULT_HOOK_SPOOL", "/var/tmp/clipvault-hooks/spool");
    let spool_path = std::path::PathBuf::from(&spool_dir);

    let mut raw = String::new();
    let _ = std::io::stdin().read_to_string(&mut raw);
    let payload = parse_payload(&raw, &hook_event);

    if model::METRIC_EVENTS.contains(&hook_event.as_str()) {
        let _ = model::append_metric_spool(&spool_path, &payload);
        return 0;
    }

    let row = HookEvent::from_payload(
        &payload,
        if hook_event.is_empty() { None } else { Some(&hook_event) },
        &instance_id,
        &source,
    );
    let _ = model::append_spool(&spool_path, &row);

    if let Err(e) = deliver(&row) {
        let _ = std::fs::write(
            std::path::Path::new(&spool_dir).join("hook.err"),
            format!("{e:#}\n"),
        );
    }
    0
}

fn deliver(row: &HookEvent) -> Result<()> {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;
    runtime.block_on(async {
        let cfg = config::pg_config()?;
        let (client, connection) = cfg.connect(NoTls).await?;
        let driver = tokio::spawn(async move {
            let _ = connection.await;
        });
        let inserted = row.insert(&client).await?;
        if inserted > 0 {
            let payload = row.sse_payload().to_string();
            let _ = client
                .execute("SELECT pg_notify($1, $2)", &[&model::NOTIFY_CHANNEL, &payload])
                .await;
        }
        driver.abort();
        Ok::<(), anyhow::Error>(())
    })
}

fn parse_event_arg() -> Option<String> {
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        if arg == "--event" {
            return args.next();
        }
        if let Some(rest) = arg.strip_prefix("--event=") {
            return Some(rest.to_string());
        }
    }
    None
}

fn parse_payload(raw: &str, hook_event: &str) -> Value {
    let text = raw.trim();
    if text.is_empty() {
        return json!({
            "hook_event_name": if hook_event.is_empty() { "Unknown" } else { hook_event },
            "empty_stdin": true,
            "client_event_id": fallback_id(),
        });
    }
    match serde_json::from_str::<Value>(text) {
        Ok(Value::Object(mut obj)) => {
            if !hook_event.is_empty() && !obj.contains_key("hook_event_name") {
                obj.insert("hook_event_name".into(), Value::String(hook_event.to_string()));
            }
            Value::Object(obj)
        }
        _ => json!({
            "hook_event_name": if hook_event.is_empty() { "Unknown" } else { hook_event },
            "raw_text": text.chars().take(20000).collect::<String>(),
            "parse_error": true,
            "client_event_id": fallback_id(),
        }),
    }
}

fn fallback_id() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("{nanos:x}-{}", std::process::id())
}
