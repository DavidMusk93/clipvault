//! clipvault-hook: the fail-open collector. stdin JSON -> spool -> wake the writer.
//!
//! The hot path never touches PostgreSQL. A per-event connection over `ssh -L`
//! costs a full SCRAM handshake (~6 RTT); instead this process appends to the
//! local spool and sends a 1-byte UDP wakeup to `clipvault-flush`, which holds a
//! persistent connection and drains. INV-4: every path exits 0.

use std::io::Read;
use std::net::UdpSocket;
use std::time::{SystemTime, UNIX_EPOCH};

use clipvault_session::config;
use clipvault_session::model::{self, HookEvent};
use serde_json::{json, Value};

fn main() {
    std::process::exit(run());
}

fn run() -> i32 {
    let hook_event = parse_event_arg()
        .filter(|s| !s.is_empty())
        .or_else(|| std::env::var("CLIPVAULT_HOOK_EVENT").ok())
        .unwrap_or_default();
    let instance_id = config::var("CLIPVAULT_INSTANCE_ID", "unknown");
    let source = config::var("CLIPVAULT_HOOK_SOURCE", "trae");
    let spool_dir = config::var("CLIPVAULT_HOOK_SPOOL", "/var/tmp/clipvault-hooks/spool");
    let spool = std::path::PathBuf::from(&spool_dir);

    let mut raw = String::new();
    let _ = std::io::stdin().read_to_string(&mut raw);
    let payload = parse_payload(&raw, &hook_event);

    let spooled = if model::METRIC_EVENTS.contains(&hook_event.as_str()) {
        model::append_metric_spool(&spool, &payload)
    } else {
        let row = HookEvent::from_payload(
            &payload,
            if hook_event.is_empty() {
                None
            } else {
                Some(&hook_event)
            },
            &instance_id,
            &source,
        );
        model::append_spool(&spool, &row)
    };

    if spooled.is_ok() {
        wake_writer();
    } else if let Err(e) = spooled {
        let _ = std::fs::create_dir_all(&spool_dir);
        let _ = std::fs::write(
            std::path::Path::new(&spool_dir).join("hook.err"),
            format!("{e:#}\n"),
        );
    }
    0
}

/// Fire-and-forget readiness signal to the local writer. Best effort: if the
/// daemon is down the spool still holds the rows and its watchdog drains them.
fn wake_writer() {
    let addr = config::var("CLIPVAULT_FLUSH_WAKE", "127.0.0.1:19499");
    if let Ok(socket) = UdpSocket::bind("127.0.0.1:0") {
        let _ = socket.send_to(b".", addr);
    }
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
    let fallback_event = if hook_event.is_empty() {
        "Unknown"
    } else {
        hook_event
    };
    if text.is_empty() {
        return json!({
            "hook_event_name": fallback_event,
            "empty_stdin": true,
            "client_event_id": fallback_id(),
        });
    }
    match serde_json::from_str::<Value>(text) {
        Ok(Value::Object(mut obj)) => {
            if !hook_event.is_empty() && !obj.contains_key("hook_event_name") {
                obj.insert(
                    "hook_event_name".into(),
                    Value::String(hook_event.to_string()),
                );
            }
            Value::Object(obj)
        }
        _ => json!({
            "hook_event_name": fallback_event,
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
