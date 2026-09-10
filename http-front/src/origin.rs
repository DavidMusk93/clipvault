//! CV01 origin frames. Not HTTP — the only HTTP hop is the browser-facing server.

use std::io;
use std::pin::Pin;
use std::task::{Context, Poll};

use bytes::Bytes;
use http_body::Frame;
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWriteExt, ReadBuf};
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::UnixStream;

pub const MAGIC: &[u8; 4] = b"CV01";
pub const STREAM_LEN: u32 = u32::MAX;
pub const MAX_META: usize = 256 * 1024;
pub const MAX_BODY: usize = 8 * 1024 * 1024;

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct Meta {
    #[serde(default)]
    pub method: String,
    #[serde(default)]
    pub path: String,
    #[serde(default)]
    pub status: u16,
    #[serde(default)]
    pub headers: Vec<(String, String)>,
    #[serde(default)]
    pub stream: bool,
}

pub fn encode(meta: &Meta, body: &[u8], stream: bool) -> Result<Vec<u8>, String> {
    let json = serde_json::to_vec(meta).map_err(|e| e.to_string())?;
    if json.len() > MAX_META {
        return Err("cv01 meta too large".into());
    }
    if !stream && body.len() > MAX_BODY {
        return Err("cv01 body too large".into());
    }
    let mut out = Vec::with_capacity(12 + json.len() + body.len());
    out.extend_from_slice(MAGIC);
    out.extend_from_slice(&(json.len() as u32).to_be_bytes());
    out.extend_from_slice(&json);
    let blen = if stream { STREAM_LEN } else { body.len() as u32 };
    out.extend_from_slice(&blen.to_be_bytes());
    if !stream {
        out.extend_from_slice(body);
    }
    Ok(out)
}

pub async fn write_request(
    wr: &mut OwnedWriteHalf,
    method: &str,
    path: &str,
    headers: Vec<(String, String)>,
    body: &[u8],
) -> io::Result<()> {
    let meta = Meta {
        method: method.to_string(),
        path: path.to_string(),
        headers,
        ..Meta::default()
    };
    let frame = encode(&meta, body, false).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    wr.write_all(&frame).await
}

pub async fn read_response_header(rd: &mut OwnedReadHalf) -> io::Result<(Meta, Option<u64>)> {
    let mut mag = [0u8; 4];
    rd.read_exact(&mut mag).await?;
    if &mag != MAGIC {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "cv01 magic"));
    }
    let mut nbuf = [0u8; 4];
    rd.read_exact(&mut nbuf).await?;
    let jlen = u32::from_be_bytes(nbuf) as usize;
    if jlen == 0 || jlen > MAX_META {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "cv01 meta len"));
    }
    let mut json = vec![0u8; jlen];
    rd.read_exact(&mut json).await?;
    rd.read_exact(&mut nbuf).await?;
    let blen = u32::from_be_bytes(nbuf);
    let meta: Meta = serde_json::from_slice(&json)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    if blen == STREAM_LEN || meta.stream {
        Ok((meta, None))
    } else {
        if blen as usize > MAX_BODY {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "cv01 body len"));
        }
        Ok((meta, Some(blen as u64)))
    }
}

pub fn split(stream: UnixStream) -> (OwnedReadHalf, OwnedWriteHalf) {
    stream.into_split()
}

/// Origin response bytes as a hyper body. `left = None` means until EOF.
pub struct OriginBody {
    rd: OwnedReadHalf,
    _wr: Option<OwnedWriteHalf>,
    left: Option<u64>,
}

impl OriginBody {
    pub fn new(rd: OwnedReadHalf, wr: OwnedWriteHalf, left: Option<u64>) -> Self {
        Self {
            rd,
            _wr: Some(wr),
            left,
        }
    }
}

impl http_body::Body for OriginBody {
    type Data = Bytes;
    type Error = io::Error;

    fn poll_frame(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Bytes>, Self::Error>>> {
        let this = self.get_mut();
        if let Some(0) = this.left {
            return Poll::Ready(None);
        }
        let mut tmp = [0u8; 8192];
        let max = match this.left {
            Some(n) => std::cmp::min(n as usize, tmp.len()),
            None => tmp.len(),
        };
        let mut buf = ReadBuf::new(&mut tmp[..max]);
        match Pin::new(&mut this.rd).poll_read(cx, &mut buf) {
            Poll::Pending => Poll::Pending,
            Poll::Ready(Err(e)) => Poll::Ready(Some(Err(e))),
            Poll::Ready(Ok(())) => {
                let n = buf.filled().len();
                if n == 0 {
                    this.left = Some(0);
                    return Poll::Ready(None);
                }
                if let Some(left) = this.left.as_mut() {
                    *left -= n as u64;
                }
                Poll::Ready(Some(Ok(Frame::data(Bytes::copy_from_slice(buf.filled())))))
            }
        }
    }

    fn is_end_stream(&self) -> bool {
        matches!(self.left, Some(0))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frame_roundtrip_fixed() {
        let meta = Meta {
            method: "GET".into(),
            path: "/api/clips?limit=1".into(),
            headers: vec![("host".into(), "127.0.0.1".into())],
            ..Meta::default()
        };
        let bytes = encode(&meta, b"{}", false).unwrap();
        assert_eq!(&bytes[..4], MAGIC);
        let jlen = u32::from_be_bytes(bytes[4..8].try_into().unwrap()) as usize;
        let got: Meta = serde_json::from_slice(&bytes[8..8 + jlen]).unwrap();
        assert_eq!(got.method, "GET");
        assert_eq!(got.path, "/api/clips?limit=1");
        let blen_off = 8 + jlen;
        let blen = u32::from_be_bytes(bytes[blen_off..blen_off + 4].try_into().unwrap());
        assert_eq!(blen, 2);
        assert_eq!(&bytes[blen_off + 4..], b"{}");
    }

    #[test]
    fn stream_sentinel() {
        let meta = Meta {
            status: 200,
            stream: true,
            headers: vec![("content-type".into(), "text/event-stream".into())],
            ..Meta::default()
        };
        let bytes = encode(&meta, b"", true).unwrap();
        let jlen = u32::from_be_bytes(bytes[4..8].try_into().unwrap()) as usize;
        let blen = u32::from_be_bytes(bytes[8 + jlen..12 + jlen].try_into().unwrap());
        assert_eq!(blen, STREAM_LEN);
        assert_eq!(bytes.len(), 12 + jlen);
    }
}
