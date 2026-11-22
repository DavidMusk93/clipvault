//! cv-lm — 其他 applet 加载个人小模型的统一入口。
//!
//!   cv-lm serve [--port 8788] [--bundle <dir>]   # HTTP API（applet / web UI 共用）
//!   cv-lm complete "prefix" [--bundle <dir>]     # CLI 单次续写
//!   cv-lm version
//!
//! HTTP API（仅绑定 127.0.0.1）：
//!   GET  /health                  → {status, version, device}
//!   POST /complete {"prefix":..,"max_tokens":24} → {"completion":".."}
//!   POST /compose  {"prompt":..,"max_tokens":256,"temperature":0.8} → {"text":".."}
//! CORS 允许 ClipVault UI (127.0.0.1:8080) 直连。

use cvlm_core::{Engine, GenParams, SharedEngine};
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;

fn default_bundle() -> PathBuf {
    if let Ok(v) = std::env::var("CVLM_BUNDLE") {
        return PathBuf::from(v);
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    PathBuf::from(home).join("Library/Application Support/Keepsake/models/personal-lm")
}

fn arg_flag(args: &[String], name: &str) -> Option<String> {
    args.iter()
        .position(|a| a == name)
        .and_then(|i| args.get(i + 1))
        .cloned()
}

fn read_request(mut stream: &TcpStream) -> Option<(String, String, Vec<u8>)> {
    let mut buf = [0u8; 16384];
    let mut data = Vec::new();
    let mut header_end: Option<usize> = None;
    loop {
        let n = stream.read(&mut buf).ok()?;
        if n == 0 {
            break;
        }
        data.extend_from_slice(&buf[..n]);
        if let Some(p) = find_header_end(&data) {
            header_end = Some(p);
            break;
        }
        if data.len() > 1 << 20 {
            return None;
        }
    }
    let header_end = header_end?;
    let head = String::from_utf8_lossy(&data[..header_end]).into_owned();
    let mut lines = head.lines();
    let request_line = lines.next()?.to_string();
    let mut parts = request_line.split_whitespace();
    let method = parts.next()?.to_string();
    let path = parts.next()?.to_string();
    let mut content_length = 0usize;
    for line in lines {
        let lower = line.to_ascii_lowercase();
        if let Some(v) = lower.strip_prefix("content-length:") {
            content_length = v.trim().parse().unwrap_or(0);
        }
    }
    let mut body = data[header_end + 4..].to_vec();
    while body.len() < content_length {
        let n = stream.read(&mut buf).ok()?;
        if n == 0 {
            break;
        }
        body.extend_from_slice(&buf[..n]);
    }
    Some((method, path, body))
}

fn find_header_end(data: &[u8]) -> Option<usize> {
    data.windows(4).position(|w| w == b"\r\n\r\n")
}

fn respond(stream: &mut TcpStream, status: &str, body: &Value) {
    let payload = body.to_string();
    let resp = format!(
        "HTTP/1.1 {status}\r\ncontent-type: application/json\r\ncontent-length: {}\r\n\
         access-control-allow-origin: *\r\naccess-control-allow-headers: content-type\r\n\
         access-control-allow-methods: GET, POST, OPTIONS\r\nconnection: close\r\n\r\n{payload}",
        payload.len()
    );
    let _ = stream.write_all(resp.as_bytes());
    let _ = stream.flush();
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let cmd = args.first().map(String::as_str).unwrap_or("help");

    match cmd {
        "version" => println!("cv-lm {}", env!("CARGO_PKG_VERSION")),
        "debug" => {
            // debug "text" --bundle: 打印最后一位置信度前8
            let text = args.get(1).cloned().unwrap_or_default();
            let bundle = arg_flag(&args, "--bundle").map(PathBuf::from).unwrap_or_else(default_bundle);
            let eng = Engine::load(&bundle).unwrap_or_else(|e| { eprintln!("load: {e}"); std::process::exit(1) });
            let ids = eng.tokenize(&text);
            eprintln!("ids: {:?}", ids);
            let logits = eng.debug_logits(&ids).unwrap();
            let mut v: Vec<(u32, f32)> = logits.iter().enumerate().map(|(i, x)| (i as u32, *x)).collect();
            v.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap());
            for (id, l) in v.iter().take(8) { println!("id={id} logit={l:.4}") }
        }
        "complete" => {
            let text = args.get(1).cloned().unwrap_or_default();
            let bundle = arg_flag(&args, "--bundle").map(PathBuf::from).unwrap_or_else(default_bundle);
            let eng = Engine::load(&bundle).unwrap_or_else(|e| {
                eprintln!("load bundle {bundle:?}: {e}");
                std::process::exit(1)
            });
            let p = GenParams {
                max_tokens: arg_flag(&args, "--max-tokens")
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(24),
                temperature: arg_flag(&args, "--temperature")
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(0.0),
                top_k: 40,
                stop_on_newline: !args.iter().any(|a| a == "--no-stop"),
                rep_penalty: 1.3,
            };
            match eng.generate(&text, &p) {
                Ok(out) => println!("{out}"),
                Err(e) => eprintln!("generate: {e}"),
            }
        }
        "serve" => {
            let port: u16 = arg_flag(&args, "--port").and_then(|v| v.parse().ok()).unwrap_or(8788);
            let bundle = arg_flag(&args, "--bundle").map(PathBuf::from).unwrap_or_else(default_bundle);
            let shared = std::sync::Arc::new(SharedEngine::new(bundle.clone()));
            let shared_ref = shared.clone();
            let listener = match TcpListener::bind(("127.0.0.1", port)) {
                Ok(l) => l,
                Err(e) => {
                    eprintln!("bind :{port}: {e}");
                    std::process::exit(1)
                }
            };
            eprintln!("[cv-lm] serving bundle {:?} on 127.0.0.1:{port}", bundle);
            for stream in listener.incoming() {
                let stream = match stream {
                    Ok(s) => s,
                    Err(_) => continue,
                };
                let shared = shared_ref.clone();
                std::thread::spawn(move || handle_conn(stream, &shared));
            }
        }
        _ => {
            println!(
                "cv-lm — ClipVault 个人小模型加载器\n\n\
                 用法:\n  cv-lm serve [--port 8788] [--bundle <dir>]\n  \
                 cv-lm complete \"prefix\" [--max-tokens 24] [--bundle <dir>]\n  \
                 cv-lm version"
            );
        }
    }
}

fn handle_conn(mut stream: TcpStream, shared: &SharedEngine) {
    let (method, path, body) = match read_request(&stream) {
        Some(x) => x,
        None => return,
    };
    if method == "OPTIONS" {
        respond(&mut stream, "204 No Content", &json!({}));
        return;
    }
    match (method.as_str(), path.split('?').next().unwrap_or("/")) {
        ("GET", "/health") => {
            let loaded = shared.version();
            respond(
                &mut stream,
                "200 OK",
                &json!({"status": if loaded.is_some() {"ok"} else {"loading"},
                        "version": loaded, "server": "cv-lm"}),
            );
        }
        ("POST", "/complete") | ("POST", "/compose") => {
            if let Err(e) = shared.ensure() {
                respond(&mut stream, "503 Service Unavailable",
                        &json!({"error": format!("engine load failed: {e}")}));
                return;
            }
            let v: Value = serde_json::from_slice(&body).unwrap_or(json!({}));
            let prefix = v["prefix"]
                .as_str()
                .or(v["prompt"].as_str())
                .unwrap_or("");
            if prefix.trim().is_empty() {
                respond(&mut stream, "400 Bad Request", &json!({"error": "prefix/prompt required"}));
                return;
            }
            let is_complete = path == "/complete";
            let p = GenParams {
                max_tokens: v["max_tokens"].as_u64().map(|x| x as usize)
                    .unwrap_or(if is_complete { 24 } else { 256 })
                    .min(512),
                temperature: v["temperature"].as_f64().map(|x| x as f32)
                    .unwrap_or(if is_complete { 0.35 } else { 0.8 }),
                top_k: v["top_k"].as_u64().map(|x| x as usize).unwrap_or(if is_complete { 20 } else { 40 }),
                stop_on_newline: if is_complete { true } else { false },
                rep_penalty: v["rep_penalty"].as_f64().map(|x| x as f32)
                    .unwrap_or(if is_complete { 1.2 } else { 1.15 }),
            };
            let guard = shared.engine.lock().unwrap();
            let eng = guard.as_ref().unwrap();
            match eng.generate(prefix, &p) {
                Ok(mut text) => {
                    // 补全（ghost text）不应以换行/空白开头：标题行后续写的
                    // 第一个 token 往往就是 \n，直接吃掉
                    if is_complete {
                        text = text.trim_start_matches(['\n', '\r', ' ']).to_string();
                    }
                    let key = if is_complete { "completion" } else { "text" };
                    respond(&mut stream, "200 OK",
                            &json!({key: text, "version": eng.version}));
                }
                Err(e) => respond(&mut stream, "500 Internal Server Error",
                                  &json!({"error": e.to_string()})),
            }
        }
        _ => respond(&mut stream, "404 Not Found", &json!({"error": "not found"})),
    }
}
