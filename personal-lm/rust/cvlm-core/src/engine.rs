//! Engine：加载 bundle（config.json + tokenizer.json + model.safetensors），
//! 提供 complete/compose。支持热加载（manifest.json mtime 变化即重载）。

use crate::gpt::GptTensors;
use crate::tokenizer::Tokenizer;
use crate::anyhow_result::{err, Result};
use candle_core::{DType, Device, Tensor};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

pub struct Engine {
    pub bundle_dir: PathBuf,
    pub version: String,
    pub device_label: String,
    tok: Tokenizer,
    model: GptTensors,
    pub vocab_size: usize,
    pub block_size: usize,
    manifest_mtime: (i64, u32),
}

#[derive(Clone)]
pub struct GenParams {
    pub max_tokens: usize,
    pub temperature: f32,
    pub top_k: usize,
    pub stop_on_newline: bool,
    /// 重复惩罚：>1 时对已出现 token 的 logit 除以该值（1.0 = 关闭）
    pub rep_penalty: f32,
}

impl Engine {
    /// 选择设备：优先 Metal（可用时），否则 CPU。
    fn pick_device() -> (Device, String) {
        match Device::new_metal(0) {
            Ok(d) => (d, "metal".into()),
            Err(_) => (Device::Cpu, "cpu".into()),
        }
    }

    pub fn load(bundle_dir: &Path) -> Result<Self> {
        let cfg: serde_json::Value = serde_json::from_str(
            &std::fs::read_to_string(bundle_dir.join("config.json"))?,
        )?;
        let model_cfg = &cfg["model"];
        let n_layer = model_cfg["n_layer"].as_u64().ok_or_else(|| err("cfg n_layer"))? as usize;
        let n_head = model_cfg["n_head"].as_u64().ok_or_else(|| err("cfg n_head"))? as usize;
        let tok = Tokenizer::load(&bundle_dir.join("tokenizer.json"))?;
        // metal 优先；遇到无内核的 op 在首次 forward 时才会暴露 → 这里只做加载，
        // generate 失败时由 SharedEngine 回退 CPU 重载。
        let meta = std::fs::metadata(bundle_dir.join("manifest.json"))?;
        let mtime = meta
            .modified()
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| (d.as_secs() as i64, d.subsec_nanos()))
            .unwrap_or((0, 0));
        let (device, device_label) = match std::env::var("CVLM_DEVICE").as_deref() {
            Ok("cpu") => (Device::Cpu, "cpu".into()),
            _ => Self::pick_device(),
        };
        let map = candle_core::safetensors::load(bundle_dir.join("model.safetensors"), &device)?;
        let model = GptTensors::load(&map, n_layer, n_head)?;
        // 加载后做一次 1-token forward 冒烟：metal 缺内核立刻暴露，可回退
        if device_label != "cpu" {
            let smoke = Tensor::new(vec![0u32], &device)?.reshape((1, 1))?;
            if model.forward(&smoke).is_err() {
                let map = candle_core::safetensors::load(
                    bundle_dir.join("model.safetensors"), &Device::Cpu)?;
                let model = GptTensors::load(&map, n_layer, n_head)?;
                return Ok(Self {
                    version: cfg["version"].as_str().unwrap_or("unknown").into(),
                    bundle_dir: bundle_dir.to_path_buf(),
                    device_label: "cpu-fallback".into(),
                    tok, model,
                    vocab_size: model_cfg["vocab_size"].as_u64().unwrap_or(0) as usize,
                    block_size: model_cfg["block_size"].as_u64().unwrap_or(512) as usize,
                    manifest_mtime: mtime,
                });
            }
        }
        Ok(Self {
            version: cfg["version"].as_str().unwrap_or("unknown").into(),
            bundle_dir: bundle_dir.to_path_buf(),
            device_label,
            tok,
            model,
            vocab_size: model_cfg["vocab_size"].as_u64().unwrap_or(0) as usize,
            block_size: model_cfg["block_size"].as_u64().unwrap_or(512) as usize,
            manifest_mtime: mtime,
        })
    }

    /// manifest.json mtime 变了 → bundle 已更新，需要重载。
    pub fn needs_reload(&self) -> bool {
        match std::fs::metadata(self.bundle_dir.join("manifest.json")) {
            Ok(meta) => {
                let m = meta
                    .modified()
                    .ok()
                    .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                    .map(|d| (d.as_secs() as i64, d.subsec_nanos()))
                    .unwrap_or((0, 0));
                m != self.manifest_mtime
            }
            Err(_) => false,
        }
    }

    pub fn tokenize(&self, text: &str) -> Vec<u32> {
        self.tok.encode(text)
    }

    pub fn debug_logits(&self, ids: &[u32]) -> Result<Vec<f32>> {
        let idx = Tensor::new(ids.to_vec(), &self.model.device)?
            .reshape((1, ids.len()))?
            .to_dtype(DType::U32)?;
        let logits = self.model.forward(&idx)?;
        logits
            .narrow(1, ids.len() - 1, 1)?
            .squeeze(1)?
            .squeeze(0)?
            .to_vec1::<f32>()
            .map_err(|e| crate::anyhow_result::err(e.to_string()))
    }

    /// 续写。ctx 截断到 block_size。
    pub fn generate(&self, prompt: &str, p: &GenParams) -> Result<String> {
        let mut ids = self.tok.encode(prompt);
        if ids.len() > self.block_size - p.max_tokens.min(self.block_size / 2) {
            let keep = self.block_size.saturating_sub(p.max_tokens);
            ids = ids[ids.len() - keep..].to_vec();
        }
        let mut out: Vec<u32> = Vec::with_capacity(p.max_tokens);
        for _ in 0..p.max_tokens {
            let ctx_len = ids.len().min(self.block_size);
            let ctx = &ids[ids.len() - ctx_len..];
            let idx = Tensor::new(ctx.to_vec(), &self.model.device)?
                .reshape((1, ctx_len))?
                .to_dtype(DType::U32)?;
            let logits = self.model.forward(&idx)?; // (1,T,V)
            let last = logits.narrow(1, ctx_len - 1, 1)?.squeeze(1)?; // (1,V)
            let next = sample(
                &last.to_dtype(DType::F32)?.squeeze(0)?.to_vec1::<f32>()?,
                p,
                &ids,
            )?;
            if next == 0 {
                break; // NUL 视作终止
            }
            let text_piece = self.tok.decode(&[next]);
            if p.stop_on_newline && text_piece.contains('\n') {
                break;
            }
            out.push(next);
            ids.push(next);
        }
        Ok(self.tok.decode(&out))
    }
}

/// 采样：temperature=0 → argmax；否则 top-k + softmax + 加权随机。
fn sample(logits: &[f32], p: &GenParams, seen: &[u32]) -> Result<u32> {
    // 重复惩罚：已出现的 token，logit / penalty（贪心与采样都生效）
    let penalized: Vec<f32> = if p.rep_penalty > 1.0 {
        let mut counts: std::collections::HashMap<u32, u32> = std::collections::HashMap::new();
        for &t in seen {
            *counts.entry(t).or_insert(0) += 1;
        }
        logits
            .iter()
            .enumerate()
            .map(|(i, l)| {
                let c = counts.get(&(i as u32)).copied().unwrap_or(0);
                if c > 0 { l / (p.rep_penalty * c as f32) } else { *l }
            })
            .collect()
    } else {
        logits.to_vec()
    };
    let logits = &penalized[..];
    if p.temperature <= 1e-6 {
        return Ok(logits
            .iter()
            .enumerate()
            .max_by(|a, b| a.1.partial_cmp(b.1).unwrap())
            .map(|(i, _)| i as u32)
            .unwrap_or(0));
    }
    let mut idx: Vec<usize> = (0..logits.len()).collect();
    idx.sort_by(|a, b| logits[*b].partial_cmp(&logits[*a]).unwrap());
    let k = p.top_k.min(idx.len()).max(1);
    idx.truncate(k);
    let scale = p.temperature as f64;
    let vals: Vec<f64> = idx.iter().map(|&i| logits[i] as f64 / scale).collect();
    let max = vals.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
    let exps: Vec<f64> = vals.iter().map(|v| (v - max).exp()).collect();
    let sum: f64 = exps.iter().sum();
    // 简易熵源（纳秒）——MVP 够用
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.subsec_nanos() as u64)
        .unwrap_or(42);
    let mut acc: u64 = nanos.wrapping_mul(2654435761) | 1;
    acc ^= acc << 13;
    acc ^= acc >> 7;
    acc ^= acc << 17;
    let u = (acc % 1_000_000) as f64 / 1_000_000.0;
    let mut cum = 0.0;
    for (j, &i) in idx.iter().enumerate() {
        cum += exps[j] / sum;
        if u <= cum {
            return Ok(i as u32);
        }
    }
    Ok(*idx.last().unwrap() as u32)
}

/// 带热加载的共享引擎句柄（serve 模式用）。
pub struct SharedEngine {
    pub engine: Mutex<Option<Engine>>,
    pub bundle_dir: PathBuf,
}

impl SharedEngine {
    pub fn new(bundle_dir: PathBuf) -> Self {
        Self { engine: Mutex::new(None), bundle_dir }
    }

    /// 每次请求前调用：未加载或 manifest 变更 → 重载。
    pub fn ensure(&self) -> Result<()> {
        let mut guard = self.engine.lock().unwrap();
        let stale = match guard.as_ref() {
            None => true,
            Some(e) => e.needs_reload(),
        };
        if stale {
            eprintln!("[cv-lm] reloading bundle (manifest changed)");
            let e = Engine::load(&self.bundle_dir)?;
            *guard = Some(e);
        }
        Ok(())
    }

    pub fn version(&self) -> Option<String> {
        self.engine.lock().unwrap().as_ref().map(|e| e.version.clone())
    }
}
