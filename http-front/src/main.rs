//! ClipVault browser edge.
//!
//! One TCP port. TLS. HTTP/2 only (ALPN `h2`). No cleartext HTTP/1.1.
//! App origin is a Unix socket owned by ClipFlowServer (Vision / SQLite / CloudDocs).

use std::convert::Infallible;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::Duration;

use bytes::Bytes;
use http::header::{HOST, HeaderName};
use http_body::Body as HttpBody;
use http_body::Frame;
use http_body_util::{BodyExt, Full, combinators::BoxBody};
use hyper::body::Incoming;
use hyper::service::service_fn;
use hyper::{Request, Response, StatusCode, Uri};
use hyper_util::rt::{TokioExecutor, TokioIo, TokioTimer};
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

/// Forwards origin bytes and, on drop, aborts the origin HTTP/1 connection so
/// the unix socket closes. Otherwise SSE/client cancel leaks origin fds.
struct ProxyBody {
    inner: Incoming,
    _sender: Option<hyper::client::conn::http1::SendRequest<Incoming>>,
    abort: Option<tokio::sync::oneshot::Sender<()>>,
}

impl Drop for ProxyBody {
    fn drop(&mut self) {
        self._sender.take();
        if let Some(tx) = self.abort.take() {
            let _ = tx.send(());
        }
    }
}

impl HttpBody for ProxyBody {
    type Data = Bytes;
    type Error = std::io::Error;

    fn poll_frame(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Bytes>, Self::Error>>> {
        let this = self.get_mut();
        Pin::new(&mut this.inner).poll_frame(cx).map(|opt| {
            opt.map(|r| r.map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e)))
        })
    }

    fn is_end_stream(&self) -> bool {
        self.inner.is_end_stream()
    }

    fn size_hint(&self) -> http_body::SizeHint {
        self.inner.size_hint()
    }
}

fn ensure_identity(dir: &Path) -> Result<(Vec<CertificateDer<'static>>, PrivateKeyDer<'static>), String> {
    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    let ca_path = dir.join("ca.pem");
    let cert_path = dir.join("cert.pem");
    let key_path = dir.join("key.pem");
    if !ca_path.exists() || !cert_path.exists() || !key_path.exists() {
        write_local_ca(dir)?;
    }
    // Leaf first, then issuing CA (Chrome needs the chain).
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
        SanType::DnsName("localhost".try_into().map_err(|e: rcgen::Error| e.to_string())?),
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
    eprintln!("[http2] wrote local CA {}", dir.join("ca.pem").display());
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
    let (abort_tx, abort_rx) = tokio::sync::oneshot::channel::<()>();
    tokio::spawn(async move {
        tokio::select! {
            _ = conn => {}
            _ = abort_rx => {}
        }
    });
    match sender.send_request(req).await {
        Ok(res) => {
            let (mut parts, body) = res.into_parts();
            strip_hop_headers(&mut parts.headers);
            let proxy_body = ProxyBody {
                inner: body,
                _sender: Some(sender),
                abort: Some(abort_tx),
            };
            Ok(Response::from_parts(parts, proxy_body.boxed()))
        }
        Err(e) => {
            let _ = abort_tx.send(());
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
            let mut builder = ConnBuilder::new(TokioExecutor::new());
            builder
                .http2()
                .timer(TokioTimer::default())
                .keep_alive_interval(Some(Duration::from_secs(10)))
                .keep_alive_timeout(Duration::from_secs(20));
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
