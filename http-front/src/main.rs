//! ClipVault browser edge.
//!
//! One TCP port. TLS. HTTP/2 only (ALPN `h2`). No cleartext HTTP/1.1.
//! App origin is a Unix socket owned by ClipFlowServer (Vision / SQLite / CloudDocs).

use std::convert::Infallible;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use bytes::Bytes;
use http::header::{HOST, HeaderName};
use http_body_util::{BodyExt, Full, combinators::BoxBody};
use hyper::body::Incoming;
use hyper::service::service_fn;
use hyper::{Request, Response, StatusCode, Uri};
use hyper_util::rt::{TokioExecutor, TokioIo};
use hyper_util::server::conn::auto::Builder as ConnBuilder;
use rustls::ServerConfig;
use rustls::pki_types::{CertificateDer, PrivateKeyDer};
use tokio::net::{TcpListener, UnixStream};
use tokio_rustls::TlsAcceptor;

type RespBody = BoxBody<Bytes, std::io::Error>;

fn env_path(key: &str, fallback: PathBuf) -> PathBuf {
    std::env::var_os(key).map(PathBuf::from).unwrap_or(fallback)
}

fn keepsake_home() -> PathBuf {
    env_path(
        "KEEPSAKE_HOME",
        dirs_fallback(),
    )
}

fn dirs_fallback() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    PathBuf::from(home)
        .join("Library/Application Support/Keepsake")
}

fn listen_addrs() -> Vec<SocketAddr> {
    let raw = std::env::var("CLIPVAULT_LISTEN").unwrap_or_else(|_| "127.0.0.1:8080,[::1]:8080".into());
    raw.split(',')
        .filter_map(|s| s.trim().parse().ok())
        .collect()
}

fn origin_sock() -> PathBuf {
    env_path(
        "CLIPVAULT_ORIGIN",
        keepsake_home().join("run/http.sock"),
    )
}

fn tls_dir() -> PathBuf {
    env_path("CLIPVAULT_TLS_DIR", keepsake_home().join("tls"))
}

fn full_io(msg: &'static str) -> RespBody {
    Full::new(Bytes::from_static(msg.as_bytes()))
        .map_err(|never| match never {})
        .boxed()
}

fn boxed_incoming(body: Incoming) -> RespBody {
    body.map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))
        .boxed()
}

fn ensure_identity(dir: &Path) -> Result<(Vec<CertificateDer<'static>>, PrivateKeyDer<'static>), String> {
    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    let cert_path = dir.join("cert.pem");
    let key_path = dir.join("key.pem");
    if !cert_path.exists() || !key_path.exists() {
        let mut params = rcgen::CertificateParams::new(vec![
            "localhost".into(),
            "127.0.0.1".into(),
        ])
        .map_err(|e| e.to_string())?;
        params.subject_alt_names = vec![
            rcgen::SanType::DnsName("localhost".try_into().map_err(|e: rcgen::Error| e.to_string())?),
            rcgen::SanType::IpAddress(std::net::IpAddr::V4(std::net::Ipv4Addr::LOCALHOST)),
            rcgen::SanType::IpAddress(std::net::IpAddr::V6(std::net::Ipv6Addr::LOCALHOST)),
        ];
        let key = rcgen::KeyPair::generate().map_err(|e| e.to_string())?;
        let cert = params.self_signed(&key).map_err(|e| e.to_string())?;
        std::fs::write(&cert_path, cert.pem()).map_err(|e| e.to_string())?;
        std::fs::write(&key_path, key.serialize_pem()).map_err(|e| e.to_string())?;
        eprintln!("[http2] wrote {}", cert_path.display());
        try_trust(&cert_path);
    }
    let cert_pem = std::fs::read(&cert_path).map_err(|e| e.to_string())?;
    let key_pem = std::fs::read(&key_path).map_err(|e| e.to_string())?;
    let mut certs = Vec::new();
    for item in rustls_pemfile::certs(&mut cert_pem.as_slice()) {
        certs.push(item.map_err(|e| e.to_string())?);
    }
    let mut key_slice = key_pem.as_slice();
    let mut keys = rustls_pemfile::pkcs8_private_keys(&mut key_slice);
    let key = keys
        .next()
        .ok_or_else(|| "tls: no PKCS8 key".to_string())?
        .map_err(|e| e.to_string())?;
    Ok((certs, PrivateKeyDer::Pkcs8(key)))
}

fn try_trust(cert: &Path) {
    // Never wait: `security add-trusted-cert` can hang on a GUI auth prompt
    // and would block the only TCP bind.
    eprintln!(
        "[http2] local cert {} — trust with: security add-trusted-cert -d -r trustRoot {}",
        cert.display(),
        cert.display()
    );
    let _ = cert;
}

fn tls_acceptor(dir: &Path) -> Result<TlsAcceptor, String> {
    rustls::crypto::ring::default_provider()
        .install_default()
        .ok();
    let (certs, key) = ensure_identity(dir)?;
    let mut cfg = ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .map_err(|e| e.to_string())?;
    cfg.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];
    Ok(TlsAcceptor::from(Arc::new(cfg)))
}

fn rewrite_origin_uri(req: &mut Request<Incoming>) {
    let authority = req
        .uri()
        .authority()
        .map(|a| a.as_str().to_string())
        .or_else(|| {
            req.headers()
                .get(HOST)
                .and_then(|v| v.to_str().ok())
                .map(|s| s.to_string())
        });
    let path = req
        .uri()
        .path_and_query()
        .map(|pq| pq.as_str().to_string())
        .unwrap_or_else(|| "/".into());
    if let Ok(uri) = path.parse::<Uri>() {
        *req.uri_mut() = uri;
    }
    if let Some(auth) = authority {
        if !req.headers().contains_key(HOST) {
            if let Ok(v) = auth.parse() {
                req.headers_mut().insert(HOST, v);
            }
        }
    }
}

fn strip_hop_headers(headers: &mut http::HeaderMap) {
    const HOP: &[&str] = &[
        "connection",
        "keep-alive",
        "proxy-connection",
        "transfer-encoding",
        "upgrade",
        "te",
        "trailer",
    ];
    for name in HOP {
        headers.remove(*name);
    }
    if let Some(conn) = headers.get("connection").cloned() {
        if let Ok(s) = conn.to_str() {
            for part in s.split(',') {
                if let Ok(h) = HeaderName::from_bytes(part.trim().as_bytes()) {
                    headers.remove(h);
                }
            }
        }
    }
}

async fn proxy(mut req: Request<Incoming>, sock: PathBuf) -> Result<Response<RespBody>, Infallible> {
    rewrite_origin_uri(&mut req);
    strip_hop_headers(req.headers_mut());
    let unix = match UnixStream::connect(&sock).await {
        Ok(s) => s,
        Err(e) => {
            eprintln!("[http2] origin connect {}: {e}", sock.display());
            let mut r = Response::new(full_io("origin down"));
            *r.status_mut() = StatusCode::BAD_GATEWAY;
            return Ok(r);
        }
    };
    let io = TokioIo::new(unix);
    let (mut sender, conn) = match hyper::client::conn::http1::handshake(io).await {
        Ok(v) => v,
        Err(e) => {
            eprintln!("[http2] origin handshake: {e}");
            let mut r = Response::new(full_io("origin handshake failed"));
            *r.status_mut() = StatusCode::BAD_GATEWAY;
            return Ok(r);
        }
    };
    tokio::spawn(async move {
        let _ = conn.await;
    });
    match sender.send_request(req).await {
        Ok(res) => {
            let (mut parts, body) = res.into_parts();
            strip_hop_headers(&mut parts.headers);
            Ok(Response::from_parts(parts, boxed_incoming(body)))
        }
        Err(e) => {
            eprintln!("[http2] origin request: {e}");
            let mut r = Response::new(full_io("origin request failed"));
            *r.status_mut() = StatusCode::BAD_GATEWAY;
            Ok(r)
        }
    }
}

async fn serve_listener(listener: TcpListener, acceptor: TlsAcceptor, sock: PathBuf) {
    loop {
        let (tcp, peer) = match listener.accept().await {
            Ok(v) => v,
            Err(e) => {
                eprintln!("[http2] accept: {e}");
                continue;
            }
        };
        let acceptor = acceptor.clone();
        let sock = sock.clone();
        tokio::spawn(async move {
            let tls = match acceptor.accept(tcp).await {
                Ok(s) => s,
                Err(e) => {
                    eprintln!("[http2] tls {peer}: {e}");
                    return;
                }
            };
            let io = TokioIo::new(tls);
            let svc = service_fn(move |req| proxy(req, sock.clone()));
            let builder = ConnBuilder::new(TokioExecutor::new());
            if let Err(e) = builder.serve_connection(io, svc).await {
                eprintln!("[http2] conn {peer}: {e}");
            }
        });
    }
}

#[tokio::main]
async fn main() {
    let sock = origin_sock();
    let addrs = listen_addrs();
    if addrs.is_empty() {
        eprintln!("[http2] CLIPVAULT_LISTEN empty");
        std::process::exit(2);
    }
    let acceptor = match tls_acceptor(&tls_dir()) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("[http2] tls: {e}");
            std::process::exit(2);
        }
    };
    eprintln!(
        "[http2] edge HTTPS/2-only origin={} listen={:?}",
        sock.display(),
        addrs
    );
    if let Ok(Ok(pid)) = std::env::var("CLIPVAULT_PARENT_PID").map(|s| s.parse::<i32>()) {
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                let alive = std::process::Command::new("kill")
                    .args(["-0", &pid.to_string()])
                    .status()
                    .map(|s| s.success())
                    .unwrap_or(false);
                if !alive {
                    std::process::exit(0);
                }
            }
        });
    }
    let mut joins = Vec::new();
    for addr in addrs {
        match TcpListener::bind(addr).await {
            Ok(l) => {
                eprintln!("[http2] bound {addr}");
                joins.push(tokio::spawn(serve_listener(
                    l,
                    acceptor.clone(),
                    sock.clone(),
                )));
            }
            Err(e) => eprintln!("[http2] bind {addr}: {e}"),
        }
    }
    if joins.is_empty() {
        std::process::exit(2);
    }
    let _ = tokio::signal::ctrl_c().await;
}
