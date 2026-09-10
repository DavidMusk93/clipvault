//! ClipVault browser HTTP.
//!
//! One HTTP hop. HTTP/2 is the protocol.
//! - no TLS → :80  (h2c prior-knowledge; HTTP/1.1 on the same socket for browsers)
//! - TLS    → :443 (ALPN h2)
//! App origin is CV01 frames on a Unix socket — not HTTP.

mod origin;

use std::convert::Infallible;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use bytes::Bytes;
use http::header::{CONTENT_LENGTH, HOST, HeaderName, HeaderValue};
use http_body_util::{BodyExt, Full, combinators::BoxBody};
use hyper::body::Incoming;
use hyper::service::service_fn;
use hyper::{Request, Response, StatusCode};
use hyper_util::rt::{TokioExecutor, TokioIo, TokioTimer};
use hyper_util::server::conn::auto::Builder as ConnBuilder;
use rustls::ServerConfig;
use rustls::pki_types::{CertificateDer, PrivateKeyDer};
use tokio::net::{TcpListener, UnixStream};
use tokio_rustls::TlsAcceptor;

use origin::{OriginBody, write_request};

type RespBody = BoxBody<Bytes, std::io::Error>;

fn env_path(key: &str, fallback: PathBuf) -> PathBuf {
    std::env::var_os(key).map(PathBuf::from).unwrap_or(fallback)
}

fn keepsake_home() -> PathBuf {
    env_path("KEEPSAKE_HOME", dirs_fallback())
}

fn dirs_fallback() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    PathBuf::from(home).join("Library/Application Support/Keepsake")
}

fn tls_enabled() -> bool {
    match std::env::var("CLIPVAULT_TLS") {
        Ok(v) => matches!(v.as_str(), "1" | "true" | "TRUE" | "yes" | "on"),
        Err(_) => false,
    }
}

fn listen_addrs() -> Vec<SocketAddr> {
    if let Ok(raw) = std::env::var("CLIPVAULT_LISTEN") {
        let parsed: Vec<SocketAddr> = raw
            .split(',')
            .filter_map(|s| s.trim().parse().ok())
            .collect();
        if !parsed.is_empty() {
            return parsed;
        }
    }
    if tls_enabled() {
        vec![
            "127.0.0.1:443".parse().unwrap(),
            "[::1]:443".parse().unwrap(),
        ]
    } else {
        vec!["127.0.0.1:80".parse().unwrap(), "[::1]:80".parse().unwrap()]
    }
}

fn origin_sock() -> PathBuf {
    env_path("CLIPVAULT_ORIGIN", keepsake_home().join("run/http.sock"))
}

fn tls_dir() -> PathBuf {
    env_path("CLIPVAULT_TLS_DIR", keepsake_home().join("tls"))
}

fn full_io(msg: &'static str) -> RespBody {
    Full::new(Bytes::from_static(msg.as_bytes()))
        .map_err(|never| match never {})
        .boxed()
}

fn boxed_origin(body: OriginBody) -> RespBody {
    body.boxed()
}

fn ensure_identity(
    dir: &Path,
) -> Result<(Vec<CertificateDer<'static>>, PrivateKeyDer<'static>), String> {
    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    let ca_path = dir.join("ca.pem");
    let cert_path = dir.join("cert.pem");
    let key_path = dir.join("key.pem");
    if !ca_path.exists() || !cert_path.exists() || !key_path.exists() {
        write_local_ca(dir)?;
    }
    let mut pem = std::fs::read(&cert_path).map_err(|e| e.to_string())?;
    pem.extend_from_slice(&std::fs::read(&ca_path).map_err(|e| e.to_string())?);
    let key_pem = std::fs::read(&key_path).map_err(|e| e.to_string())?;
    let mut certs = Vec::new();
    let mut cert_slice = pem.as_slice();
    for item in rustls_pemfile::certs(&mut cert_slice) {
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

fn write_local_ca(dir: &Path) -> Result<(), String> {
    use rcgen::{
        BasicConstraints, CertificateParams, DistinguishedName, DnType, ExtendedKeyUsagePurpose,
        IsCa, KeyPair, KeyUsagePurpose, SanType,
    };
    let mut ca_params = CertificateParams::default();
    ca_params.distinguished_name = DistinguishedName::new();
    ca_params
        .distinguished_name
        .push(DnType::CommonName, "ClipVault Local CA");
    ca_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    ca_params.key_usages = vec![KeyUsagePurpose::KeyCertSign, KeyUsagePurpose::CrlSign];
    let ca_key = KeyPair::generate().map_err(|e| e.to_string())?;
    let ca_cert = ca_params.self_signed(&ca_key).map_err(|e| e.to_string())?;

    let mut leaf = CertificateParams::new(vec!["localhost".into(), "127.0.0.1".into()])
        .map_err(|e| e.to_string())?;
    leaf.distinguished_name = DistinguishedName::new();
    leaf.distinguished_name
        .push(DnType::CommonName, "127.0.0.1");
    leaf.subject_alt_names = vec![
        SanType::DnsName(
            "localhost"
                .try_into()
                .map_err(|e: rcgen::Error| e.to_string())?,
        ),
        SanType::IpAddress(std::net::IpAddr::V4(std::net::Ipv4Addr::LOCALHOST)),
        SanType::IpAddress(std::net::IpAddr::V6(std::net::Ipv6Addr::LOCALHOST)),
    ];
    leaf.is_ca = IsCa::NoCa;
    leaf.key_usages = vec![
        KeyUsagePurpose::DigitalSignature,
        KeyUsagePurpose::KeyEncipherment,
    ];
    leaf.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];
    let leaf_key = KeyPair::generate().map_err(|e| e.to_string())?;
    let leaf_cert = leaf
        .signed_by(&leaf_key, &ca_cert, &ca_key)
        .map_err(|e| e.to_string())?;

    std::fs::write(dir.join("ca.pem"), ca_cert.pem()).map_err(|e| e.to_string())?;
    std::fs::write(dir.join("ca-key.pem"), ca_key.serialize_pem()).map_err(|e| e.to_string())?;
    std::fs::write(dir.join("cert.pem"), leaf_cert.pem()).map_err(|e| e.to_string())?;
    std::fs::write(dir.join("key.pem"), leaf_key.serialize_pem()).map_err(|e| e.to_string())?;
    eprintln!("[http] wrote local CA {}", dir.join("ca.pem").display());
    Ok(())
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
    cfg.alpn_protocols = vec![b"h2".to_vec()];
    Ok(TlsAcceptor::from(Arc::new(cfg)))
}

fn request_path(req: &Request<Incoming>) -> String {
    req.uri()
        .path_and_query()
        .map(|pq| pq.as_str().to_string())
        .unwrap_or_else(|| "/".into())
}

fn request_headers(req: &Request<Incoming>) -> Vec<(String, String)> {
    let mut out = Vec::new();
    if let Some(auth) = req.uri().authority() {
        out.push(("host".into(), auth.as_str().to_string()));
    } else if let Some(h) = req.headers().get(HOST).and_then(|v| v.to_str().ok()) {
        out.push(("host".into(), h.to_string()));
    }
    for (name, value) in req.headers() {
        let lname = name.as_str().to_ascii_lowercase();
        if matches!(
            lname.as_str(),
            "connection"
                | "keep-alive"
                | "proxy-connection"
                | "transfer-encoding"
                | "upgrade"
                | "te"
                | "trailer"
                | "host"
        ) {
            continue;
        }
        if let Ok(v) = value.to_str() {
            out.push((lname, v.to_string()));
        }
    }
    out
}

fn status_from(code: u16) -> StatusCode {
    StatusCode::from_u16(code).unwrap_or(StatusCode::OK)
}

async fn proxy(req: Request<Incoming>, sock: PathBuf) -> Result<Response<RespBody>, Infallible> {
    let method = req.method().as_str().to_string();
    let path = request_path(&req);
    let headers = request_headers(&req);
    let collected = match req.into_body().collect().await {
        Ok(c) => c.to_bytes(),
        Err(e) => {
            eprintln!("[http] body: {e}");
            let mut r = Response::new(full_io("bad request body"));
            *r.status_mut() = StatusCode::BAD_REQUEST;
            return Ok(r);
        }
    };
    if collected.len() > origin::MAX_BODY {
        let mut r = Response::new(full_io("payload too large"));
        *r.status_mut() = StatusCode::PAYLOAD_TOO_LARGE;
        return Ok(r);
    }
    let unix = match UnixStream::connect(&sock).await {
        Ok(s) => s,
        Err(e) => {
            eprintln!("[http] origin connect {}: {e}", sock.display());
            let mut r = Response::new(full_io("origin down"));
            *r.status_mut() = StatusCode::BAD_GATEWAY;
            return Ok(r);
        }
    };
    let (mut rd, mut wr) = origin::split(unix);
    if let Err(e) = write_request(&mut wr, &method, &path, headers, &collected).await {
        eprintln!("[http] origin write: {e}");
        let mut r = Response::new(full_io("origin write failed"));
        *r.status_mut() = StatusCode::BAD_GATEWAY;
        return Ok(r);
    }
    match origin::read_response_header(&mut rd).await {
        Ok((meta, left)) => {
            let status = if meta.status == 0 { 200 } else { meta.status };
            let mut res = match left {
                Some(n) => {
                    let mut buf = vec![0u8; n as usize];
                    if let Err(e) = tokio::io::AsyncReadExt::read_exact(&mut rd, &mut buf).await {
                        eprintln!("[http] origin body: {e}");
                        let mut r = Response::new(full_io("origin body failed"));
                        *r.status_mut() = StatusCode::BAD_GATEWAY;
                        return Ok(r);
                    }
                    drop(rd);
                    drop(wr);
                    Response::new(
                        Full::new(Bytes::from(buf))
                            .map_err(|never| match never {})
                            .boxed(),
                    )
                }
                None => Response::new(boxed_origin(OriginBody::new(rd, wr, None))),
            };
            *res.status_mut() = status_from(status);
            let parts = res.headers_mut();
            for (k, v) in meta.headers {
                let lname = k.to_ascii_lowercase();
                if matches!(
                    lname.as_str(),
                    "connection"
                        | "keep-alive"
                        | "transfer-encoding"
                        | "upgrade"
                        | "te"
                        | "trailer"
                        | "content-length"
                ) {
                    continue;
                }
                if let (Ok(name), Ok(value)) = (
                    HeaderName::from_bytes(lname.as_bytes()),
                    HeaderValue::from_str(&v),
                ) {
                    parts.append(name, value);
                }
            }
            if let Some(n) = left {
                parts.insert(CONTENT_LENGTH, HeaderValue::from(n));
            }
            Ok(res)
        }
        Err(e) => {
            eprintln!("[http] origin response: {e}");
            let mut r = Response::new(full_io("origin response failed"));
            *r.status_mut() = StatusCode::BAD_GATEWAY;
            Ok(r)
        }
    }
}

fn conn_builder() -> ConnBuilder<TokioExecutor> {
    let mut builder = ConnBuilder::new(TokioExecutor::new());
    builder
        .http2()
        .timer(TokioTimer::default())
        .keep_alive_interval(Some(Duration::from_secs(10)))
        .keep_alive_timeout(Duration::from_secs(20));
    builder
}

async fn serve_plain(listener: TcpListener, sock: PathBuf) {
    loop {
        let (tcp, peer) = match listener.accept().await {
            Ok(v) => v,
            Err(e) => {
                eprintln!("[http] accept: {e}");
                continue;
            }
        };
        let sock = sock.clone();
        tokio::spawn(async move {
            let io = TokioIo::new(tcp);
            let svc = service_fn(move |req| proxy(req, sock.clone()));
            if let Err(e) = conn_builder().serve_connection(io, svc).await {
                eprintln!("[http] conn {peer}: {e}");
            }
        });
    }
}

async fn serve_tls(listener: TcpListener, acceptor: TlsAcceptor, sock: PathBuf) {
    loop {
        let (tcp, peer) = match listener.accept().await {
            Ok(v) => v,
            Err(e) => {
                eprintln!("[http] accept: {e}");
                continue;
            }
        };
        let acceptor = acceptor.clone();
        let sock = sock.clone();
        tokio::spawn(async move {
            let tls = match acceptor.accept(tcp).await {
                Ok(s) => s,
                Err(e) => {
                    eprintln!("[http] tls {peer}: {e}");
                    return;
                }
            };
            let io = TokioIo::new(tls);
            let svc = service_fn(move |req| proxy(req, sock.clone()));
            if let Err(e) = conn_builder().serve_connection(io, svc).await {
                eprintln!("[http] conn {peer}: {e}");
            }
        });
    }
}

fn watch_parent() {
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
}

#[tokio::main]
async fn main() {
    let sock = origin_sock();
    let addrs = listen_addrs();
    if addrs.is_empty() {
        eprintln!("[http] CLIPVAULT_LISTEN empty");
        std::process::exit(2);
    }
    let tls = tls_enabled();
    eprintln!(
        "[http] one-hop HTTP/2 origin={} tls={} listen={:?}",
        sock.display(),
        tls,
        addrs
    );
    watch_parent();
    let mut joins = Vec::new();
    if tls {
        let acceptor = match tls_acceptor(&tls_dir()) {
            Ok(a) => a,
            Err(e) => {
                eprintln!("[http] tls: {e}");
                std::process::exit(2);
            }
        };
        for addr in addrs {
            match TcpListener::bind(addr).await {
                Ok(l) => {
                    eprintln!("[http] bound {addr} (tls h2)");
                    joins.push(tokio::spawn(serve_tls(l, acceptor.clone(), sock.clone())));
                }
                Err(e) => eprintln!("[http] bind {addr}: {e}"),
            }
        }
    } else {
        for addr in addrs {
            match TcpListener::bind(addr).await {
                Ok(l) => {
                    eprintln!("[http] bound {addr} (h2c + http/1.1)");
                    joins.push(tokio::spawn(serve_plain(l, sock.clone())));
                }
                Err(e) => eprintln!("[http] bind {addr}: {e}"),
            }
        }
    }
    if joins.is_empty() {
        std::process::exit(2);
    }
    let _ = tokio::signal::ctrl_c().await;
}
