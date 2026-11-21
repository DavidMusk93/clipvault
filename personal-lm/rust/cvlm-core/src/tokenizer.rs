//! personal-lm BPE tokenizer（与 Python train/tokenizer.py 完全同构）。
//! tokenizer.json 格式: personal-lm-bpe-v1（vocab base64 bytes + ranks + specials）。

use regex::Regex;
use crate::anyhow_result::{ensure, err, Result};
use std::collections::HashMap;

pub struct Tokenizer {
    pub vocab: HashMap<u32, Vec<u8>>,
    pub ranks: HashMap<(u32, u32), u32>,
    pub specials: HashMap<String, u32>,
    pub next_id: u32,
}

/// 手写 base64 decode（避免引入依赖）
fn b64_decode(s: &str) -> Option<Vec<u8>> {
    const TBL: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = Vec::with_capacity(s.len() * 3 / 4);
    let bytes: Vec<u32> = s
        .bytes()
        .filter(|b| *b != b'=')
        .map(|b| TBL.iter().position(|t| *t == b).map(|p| p as u32))
        .collect::<Option<Vec<_>>>()?;
    let mut acc: u32 = 0;
    let mut nbits = 0;
    for v in bytes {
        acc = (acc << 6) | v;
        nbits += 6;
        if nbits >= 8 {
            nbits -= 8;
            out.push(((acc >> nbits) & 0xff) as u8);
        }
    }
    Some(out)
}

impl Tokenizer {
    pub fn load(path: &std::path::Path) -> Result<Self> {
        let raw = std::fs::read_to_string(path)?;
        let v: serde_json::Value = serde_json::from_str(&raw)?;
        ensure(v["format"] == "personal-lm-bpe-v1", "bad tokenizer format")?;
        let mut vocab = HashMap::new();
        for (k, val) in v["vocab"].as_object().expect("vocab obj") {
            let id: u32 = k.parse()?;
            let bytes = b64_decode(val.as_str().expect("b64 str"))
                .ok_or_else(|| err("bad b64"))?;
            vocab.insert(id, bytes);
        }
        let mut ranks = HashMap::new();
        for arr in v["ranks"].as_array().expect("ranks arr") {
            let a = arr[0].as_u64().expect("a") as u32;
            let b = arr[1].as_u64().expect("b") as u32;
            let r = arr[2].as_u64().expect("r") as u32;
            ranks.insert((a, b), r);
        }
        let mut specials = HashMap::new();
        for (k, val) in v["specials"].as_object().expect("specials obj") {
            specials.insert(k.clone(), val.as_u64().expect("sid") as u32);
        }
        let next_id = *vocab.keys().max().unwrap_or(&255) + 1;
        Ok(Self { vocab, ranks, specials, next_id })
    }

    /// 预切分：与 Python pretokenize 相同规则（中文 2 字块）。
    pub fn pretokenize(text: &str) -> Vec<String> {
        static RE: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
        let re = RE.get_or_init(|| {
            Regex::new(
                r"(\p{Han}+)|([\p{L}\p{M}]+)|(\p{N}{1,3})|( ?[^\s\p{L}\p{N}\p{Han}]+[\r\n]*)|(\s+)",
            )
            .unwrap()
        });
        let mut chunks = Vec::new();
        for caps in re.captures_iter(text) {
            let m = caps.get(0).unwrap();
            // 哪个组命中（1..=5）
            let kind = (1..=5).find(|i| caps.get(*i).is_some()).unwrap_or(5);
            let s = m.as_str();
            if kind == 1 {
                let chars: Vec<char> = s.chars().collect();
                let n = chars.len();
                let mut i = 0;
                while i + 1 < n {
                    chunks.push(chars[i].to_string() + &chars[i + 1].to_string());
                    i += 2;
                }
                if n % 2 == 1 {
                    chunks.push(chars[n - 1].to_string());
                }
            } else {
                chunks.push(s.to_string());
            }
        }
        chunks
    }

    fn encode_chunk(&self, chunk: &str) -> Vec<u32> {
        let mut ids: Vec<u32> = chunk.as_bytes().iter().map(|b| *b as u32).collect();
        loop {
            let mut best: Option<((u32, u32), u32)> = None;
            for pair in ids.windows(2) {
                if let Some(&r) = self.ranks.get(&(pair[0], pair[1])) {
                    if best.map(|(_, br)| r < br).unwrap_or(true) {
                        best = Some(((pair[0], pair[1]), r));
                    }
                }
            }
            let ((a, b), new_id) = match best {
                Some(x) => x,
                None => break,
            };
            let mut out = Vec::with_capacity(ids.len());
            let mut i = 0;
            while i < ids.len() {
                if ids[i] == a && i + 1 < ids.len() && ids[i + 1] == b {
                    out.push(new_id);
                    i += 2;
                } else {
                    out.push(ids[i]);
                    i += 1;
                }
            }
            ids = out;
        }
        ids
    }

    /// 与 Python encode 一致：special 作为整体边界。
    pub fn encode(&self, text: &str) -> Vec<u32> {
        let mut out = Vec::new();
        if self.specials.is_empty() {
            for ck in Self::pretokenize(text) {
                out.extend(self.encode_chunk(&ck));
            }
            return out;
        }
        // 构造 split 正则（每次调用构建成本可接受；specials 极少）
        let pat: String = self
            .specials
            .keys()
            .map(|s| regex::escape(s))
            .collect::<Vec<_>>()
            .join("|");
        let re = Regex::new(&format!("({})", pat)).unwrap();
        for part in re.split(text) {
            if part.is_empty() {
                continue;
            }
            if let Some(&sid) = self.specials.get(part) {
                out.push(sid);
            } else {
                for ck in Self::pretokenize(part) {
                    out.extend(self.encode_chunk(&ck));
                }
            }
        }
        out
    }

    pub fn decode(&self, ids: &[u32]) -> String {
        let mut bytes = Vec::new();
        for &id in ids {
            if let Some(b) = self.vocab.get(&id) {
                bytes.extend_from_slice(b);
            }
        }
        String::from_utf8_lossy(&bytes).into_owned()
    }
}

