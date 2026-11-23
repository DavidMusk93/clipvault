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
                min_confidence: 0.0,
            };
            match eng.generate(&text, &p) {
                Ok(out) => println!("{out}"),
                Err(e) => eprintln!("generate: {e}"),
            }
        }
        "serve" => {
            let port: u16 = arg_flag(&args, "--port").and_then(|v| v.parse().ok()).unwrap_or(8788);
            let bundle = arg_flag(&args, "--bundle").map(PathBuf::from).unwrap_or_else(default_bundle);
            let retrieval = cvlm_core::retrieval::load_optional(
                Some(&bundle.join("retrieval_lines.jsonl")));
            let retrieval = std::sync::Arc::new(retrieval);
            eprintln!("[cv-lm] retrieval: {}", if retrieval.is_some() { "loaded" } else { "off" });
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
                let retrieval = retrieval.clone();
                std::thread::spawn(move || handle_conn(stream, &shared, retrieval));
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

fn handle_conn(mut stream: TcpStream, shared: &SharedEngine, retrieval: std::sync::Arc<Option<cvlm_core::retrieval::Retrieval>>) {
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
                    .unwrap_or(if is_complete { 40 } else { 256 })
                    .min(512),
                temperature: v["temperature"].as_f64().map(|x| x as f32)
                    .unwrap_or(if is_complete { 0.35 } else { 0.8 }),
                top_k: v["top_k"].as_u64().map(|x| x as usize).unwrap_or(if is_complete { 20 } else { 40 }),
                stop_on_newline: is_complete,   // ghost：到行尾即停，多行补全无意义且拖慢首字延迟
                rep_penalty: v["rep_penalty"].as_f64().map(|x| x as f32)
                    .unwrap_or(if is_complete { 1.2 } else { 1.15 }),
                min_confidence: 0.0,
            };
            if is_complete {
                // 意图召回优先（行级对齐）：正在打的行是历史某行的前缀 → 补那行的剩余部分。
                // 构造上保证相关；不再做跨行模糊召回（曾把主题相似的无关 MR 流水账塞进「应该用」后面）。
                let cur: String = match prefix.rfind('\n') {
                    Some(i) => prefix[i + 1..].to_string(),
                    None => prefix.to_string(),
                };
                if !cur.trim().is_empty() {
                    if let Some(idx) = retrieval.as_ref() {
                        if let Some(rest) = idx.query_line(&cur) {
                            eprintln!("[retrieval] line-hit len={} cur={:?}", rest.chars().count(), cur.trim());
                            let ver = shared.version().unwrap_or_default();
                            respond(&mut stream, "200 OK",
                                    &json!({"completion": rest, "version": ver, "source": "retrieval"}));
                            return;
                        }
                    }
                }
                eprintln!("[retrieval] miss cur={:?}", cur.trim());
            }
            if is_complete && std::env::var("CVLM_COMPLETE_BACKEND").is_ok() {
                // 显式指定补全也走大模型后端（延迟高，默认不用）
                let text = proxy_backend(prefix, true, &v)
                    .unwrap_or_else(|e| format!("<backend-error: {e}>"));
                let ver = format!("qwen-backend+{}", shared.version().unwrap_or_default());
                respond(&mut stream, "200 OK", &json!({"completion": text, "version": ver, "source": "qwen"}));
            } else if !is_complete && std::env::var("CVLM_BACKEND_URL").is_ok() {
                // compose：聪明引擎优先（Qwen LoRA），失败回落本地小模型
                let max_tokens = v["max_tokens"].as_u64().map(|x| x as usize).unwrap_or(256);
                match proxy_backend(prefix, false, &v) {
                    Ok(text) if !text.trim().is_empty() => {
                        respond(&mut stream, "200 OK",
                                &json!({"text": text, "version": "qwen-backend", "source": "qwen"}));
                        return;
                    }
                    _ => {} // 回落到本地引擎
                }
                let p2 = cvlm_core::GenParams { max_tokens: max_tokens.min(512), ..p };
                let guard = shared.engine.lock().unwrap();
                let eng = guard.as_ref().unwrap();
                match eng.generate(prefix, &p2) {
                    Ok(text) => respond(&mut stream, "200 OK",
                                        &json!({"text": text, "version": eng.version})),
                    Err(e) => respond(&mut stream, "500 Internal Server Error",
                                      &json!({"error": e.to_string()})),
                }
            } else if is_complete {
                // ghost text：确定性贪心 + 跳过 ---/时间戳样板，给内容行。
                // 采样会让多轮续写分歧；贪心保证结构预测（---+时间戳+列表项）稳定可跳过。
                let min_conf: f32 = std::env::var("CVLM_GHOST_MIN_CONF")
                    .ok().and_then(|v| v.parse().ok()).unwrap_or(0.55);
                let p_complete = cvlm_core::GenParams {
                    temperature: 0.0,      // 纯贪心：rep_penalty 会把时间戳等合法重复掰成乱码
                    top_k: 1,
                    rep_penalty: 1.0,
                    min_confidence: min_conf,
                    max_tokens: p.max_tokens.max(1).min(60),   // 尊重调用方（编辑器发 28）；不再强制抬到 ≥60（曾致 1.2s 延迟）
                    ..p.clone()
                };
                // ghost：贪心 + 行尾即停 + 样板行跳过（每次重试复用 KV，开销几近 0）
                let text = {
                    // mlx 路径：同样要跳样板行（---/时间戳/```），每次重试是 ~10ms 的增量 KV 查询
                    let mut result = String::new();
                    let mut accum = String::new();
                    for _ in 0..4 {
                        let piece = match ghost_via_mlx(&format!("{prefix}{accum}"), p_complete.max_tokens) {
                            Some(t) => t,
                            None => break,
                        };
                        if !is_boilerplate_line(piece.trim()) {
                            result = piece.trim().to_string();
                            break;
                        }
                        eprintln!("[ghost] mlx boilerplate piece={:?}", piece.trim());
                        accum.push_str(piece.trim());
                        accum.push('\n');
                    }
                    if !result.is_empty() { result } else {
                    // 本地 candle 兜底（含 conf 门控 + 相同样板重试）
                    let t_ghost = std::time::Instant::now();
                    let mut result = String::new();
                    let mut accum = String::new();
                    let mut tries = 0;
                    for _ in 0..4 {
                        let prev = shared.gen_ctx.lock().unwrap().take();
                        let prompt_now = format!("{prefix}{accum}");
                        let guard = shared.engine.lock().unwrap();
                        let eng = guard.as_ref().unwrap();
                        let out = eng.generate_with_ctx(&prompt_now, &p_complete, prev);
                        drop(guard);
                        match out {
                            Ok((piece, ctx)) => {
                                tries += 1;
                                *shared.gen_ctx.lock().unwrap() = Some(ctx);
                                if piece.trim().is_empty() {
                                    eprintln!("[ghost] gate-empty tries={tries} ms={}", t_ghost.elapsed().as_millis());
                                    break;
                                }
                                let s = piece.trim();
                                if !is_boilerplate_line(s) {
                                    result = s.to_string();
                                    break;
                                }
                                eprintln!("[ghost] boilerplate tries={tries} piece={s:?}");
                                // 样板行（---/时间戳）：引擎停在行尾换行前；补回 \n 让下一轮跳下一行
                                accum.push_str(s);
                                accum.push('\n');
                            }
                            Err(e) => {
                                eprintln!("[ghost] engine err: {e}");
                                *shared.gen_ctx.lock().unwrap() = None;   // 出错丢弃，下一请求冷启动
                                break;
                            }
                        }
                    }
                    eprintln!("[ghost] local-fallback done tries={tries} ms={} result={result:?}", t_ghost.elapsed().as_millis());
                    result
                    }
                };
                let ver = shared.version().unwrap_or_default();
                respond(&mut stream, "200 OK", &json!({"completion": text, "version": ver, "source": "lm"}));
            } else {
                let guard = shared.engine.lock().unwrap();
                let eng = guard.as_ref().unwrap();
                match eng.generate(prefix, &p) {
                    Ok(text) => respond(&mut stream, "200 OK",
                                        &json!({"text": text, "version": eng.version})),
                    Err(e) => respond(&mut stream, "500 Internal Server Error",
                                      &json!({"error": e.to_string()})),
                }
            }
        }
        _ => respond(&mut stream, "404 Not Found", &json!({"error": "not found"})),
    }
}


/// 样板行判定：--- 分隔行、纯数字/时间戳形态行（小模型生成的时间戳常是乱码）。
fn is_boilerplate_line(s: &str) -> bool {
    let t = s.trim();
    if t.is_empty() || t == "---" || t == "***" || t == "___" {
        return true;
    }
    // 单一字符重复行（====、---- 等）：结构装饰
    if t.len() >= 3 && t.chars().all(|c| c == t.chars().next().unwrap()) {
        return true;
    }
    // 短 ASCII 碎片以数字/横线开头：截断的时间戳产物（"2026-"、"-09-"）
    if t.len() < 6 {
        return t.starts_with('-')
            || t.chars().next().map(|c| c.is_ascii_digit()).unwrap_or(false);
    }
    if !t.chars().all(|c| c.is_ascii()) {
        return false;
    }
    let digits = t.chars().filter(|c| c.is_ascii_digit()).count();
    let ratio = digits as f32 / t.len() as f32;
    ratio >= 0.4 && (t.contains('-') || t.contains(':'))
}

/// ghost 解码走 MLX 服务（:8787，retrieval 仍在本地）。失败/未部署 → None（回落本地 candle）。
fn ghost_via_mlx(prefix: &str, max_tokens: usize) -> Option<String> {
    let base = std::env::var("CVLM_LM_URL").ok().filter(|s| !s.is_empty())?;
    let (host, port, path) = parse_base(&base).ok()?;
    let payload = serde_json::json!({"prefix": prefix, "max_tokens": max_tokens});
    let text = http_post_json(&host, port, &path, &payload.to_string()).ok()?;
    let v: serde_json::Value = serde_json::from_str(&text).ok()?;
    let out = v["completion"].as_str()?.trim().to_string();
    if out.is_empty() { None } else { Some(out) }   // mlx 侧 conf 门控空 → None
}

/// 代理到 OpenAI 兼容后端（mlx_lm.server :8790）。
/// complete=true → 温度0、行截断+样板跳过；compose → 温度0.8 全文。
fn proxy_backend(prefix: &str, is_complete: bool, body: &Value) -> Result<String, String> {
    let base = std::env::var("CVLM_BACKEND_URL").unwrap_or_default();
    if base.is_empty() {
        return Err("CVLM_BACKEND_URL not set".into());
    }
    let (host, port, path) = parse_base(&base)?;
    let max_tokens = if is_complete { 80 } else {
        body["max_tokens"].as_u64().map(|x| x as usize).unwrap_or(256).min(1024)
    };
    let temperature = if is_complete { 0.0 } else {
        body["temperature"].as_f64().map(|x| x as f64).unwrap_or(0.8)
    };
    let payload = serde_json::json!({
        "prompt": prefix,
        "max_tokens": max_tokens,
        "temperature": temperature,
        "stop": if is_complete { serde_json::json!(["\n\n"]) } else { serde_json::json!([]) },
    });
    let text = http_post_json(&host, port, &path, &payload.to_string())?;
    let v: serde_json::Value = serde_json::from_str(&text)
        .map_err(|e| format!("bad json from backend: {e}"))?;
    let mut out = v["choices"][0]["text"].as_str().unwrap_or("").to_string();
    out = break_sentence_loops(&break_loops(&out));
    if is_complete {
        out = out.trim_start_matches(['\n', '\r', ' ']).to_string();
        loop {
            let end = out.find('\n');
            let Some(end) = end else { break };
            let line = out[..end].trim().to_string();
            if is_boilerplate_line(&line) {
                out = out[end + 1..].trim_start_matches(['\n', '\r']).to_string();
                continue;
            }
            out.truncate(end);
            break;
        }
        if let Some(end) = out.find('\n') {
            out.truncate(end);
        }
    }
    Ok(out)
}

fn parse_base(base: &str) -> Result<(String, u16, String), String> {
    // 期望 http://127.0.0.1:8790[/v1/completions]
    let rest = base.strip_prefix("http://").ok_or("only http://")?;
    let (hp, path) = match rest.find('/') {
        Some(i) => (&rest[..i], rest[i..].to_string()),
        None => (rest, "/v1/completions".to_string()),
    };
    let (host, port) = match hp.rsplit_once(':') {
        Some((h, p)) => (h.to_string(), p.parse::<u16>().map_err(|e| e.to_string())?),
        None => (hp.to_string(), 80),
    };
    Ok((host, port, path))
}

fn http_post_json(host: &str, port: u16, path: &str, body: &str) -> Result<String, String> {
    use std::io::{Read, Write};
    let mut s = std::net::TcpStream::connect((host, port)).map_err(|e| e.to_string())?;
    let req = format!(
        "POST {path} HTTP/1.1\r\nHost: {host}\r\ncontent-type: application/json\r\n\
         content-length: {}\r\nconnection: close\r\n\r\n{body}",
        body.len()
    );
    s.write_all(req.as_bytes()).map_err(|e| e.to_string())?;
    let mut resp = Vec::new();
    s.read_to_end(&mut resp).map_err(|e| e.to_string())?;
    let s = String::from_utf8_lossy(&resp);
    let idx = s.find("\r\n\r\n").ok_or("bad response")?;
    Ok(s[idx + 4..].to_string())
}


/// 循环断路器：贪心 "xyxyxy…" 退化。核心技巧：片段末字符若为标点（，。、,；）
/// 视为等价（"没有复用，没有复用，…没有复用。" 这种句号打断连续段的循环也能识别）。
fn break_loops(s: &str) -> String {
    let chars: Vec<char> = s.chars().collect();
    let is_punct = |c: char| matches!(c, '，' | '。' | '、' | ',' | ';' | '；' | '：' | ':');
    for p in 3..=16usize {
        if chars.len() < p * 4 { continue; }
        for start in 0..=(chars.len().saturating_sub(p * 4)) {
            // unit = 核心 (p-1) + 尾标点（任一标点等价）
            let core = &chars[start..start + p - 1];
            if !is_punct(chars[start + p - 1]) { continue; }
            let mut reps = 1;
            let mut i = start + p;
            while i + p <= chars.len()
                && &chars[i..i + p - 1] == core
                && is_punct(chars[i + p - 1])
            {
                reps += 1;
                i += p;
            }
            if reps >= 4 {
                return chars[..start + p].iter().collect::<String>().trim_end().to_string();
            }
        }
    }
    s.to_string()
}

/// 句子级循环：同一句（去编号/去空白）重复 >=3 次 → 截到第 2 次出现末尾。
/// 覆盖 "1.A。2.B。3.A。4.B。" 式交替循环。
fn break_sentence_loops(s: &str) -> String {
    let norm_sentence = |x: &str| -> String {
        let mut t: String = x
            .chars()
            .skip_while(|c| c.is_ascii_digit() || matches!(c, '.' | '、' | '：' | ':' | '-'))
            .collect();
        t = t.split_whitespace().collect();
        t.trim_end_matches(['。', '，', '；', '，', '.']).to_string()
    };
    let mut out = String::new();
    let mut seen: std::collections::HashMap<String, usize> = std::collections::HashMap::new();
    let mut rest = s;
    while let Some(pos) = rest.find(['。', '；', '！', '？']) {
        let end = pos + rest[pos..].chars().next().unwrap().len_utf8();
        let (sentence, tail) = rest.split_at(end);
        out.push_str(sentence);
        rest = tail;
        if sentence.chars().any(|c| !c.is_whitespace()) {
            let key = norm_sentence(sentence);
            if !key.is_empty() {
                let n = seen.entry(key).or_insert(0);
                *n += 1;
                if *n >= 3 {
                    return out;
                }
            }
        }
    }
    out.to_string() + rest
}
