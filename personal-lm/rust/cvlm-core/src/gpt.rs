//! GPT 前向（candle），state_dict 键名与 Python train/model.py 完全一致：
//!   tok_emb.weight, pos_emb.weight, blocks.N.{ln1,attn.qkv,attn.proj,ln2,mlp.fc,mlp.proj},
//!   ln_f.weight/bias, head.weight

use candle_core::{DType, Device, Result, Tensor, D};
use std::collections::HashMap;

/// 手写 layer_norm（candle 0.11 metal 后端无 layer-norm 内核，用基础算子拼）。
fn layer_norm(x: &Tensor, w: &Tensor, b: &Tensor, eps: f64) -> Result<Tensor> {
    let mean = x.mean_keepdim(D::Minus1)?;                 // (..., 1)
    let centered = x.broadcast_sub(&mean)?;
    let var = centered.sqr()?.mean_keepdim(D::Minus1)?;    // (..., 1)
    let norm = centered.broadcast_div(&(var + eps)?.sqrt()?)?;
    norm.broadcast_mul(w)?.broadcast_add(b)
}

pub struct GptTensors {
    pub tok_emb: Tensor,   // (V, C)
    pub pos_emb: Tensor,   // (P, C)
    pub blocks: Vec<Block>,
    pub ln_f_w: Tensor,
    pub ln_f_b: Tensor,
    pub head_w: Tensor,    // (V, C)
    pub device: Device,
    pub d_model: usize,
    pub n_head: usize,
}

struct Block {
    ln1_w: Tensor,
    ln1_b: Tensor,
    qkv_w: Tensor,
    qkv_b: Tensor,
    proj_w: Tensor,
    proj_b: Tensor,
    ln2_w: Tensor,
    ln2_b: Tensor,
    fc_w: Tensor,
    fc_b: Tensor,
    mlp_proj_w: Tensor,
    mlp_proj_b: Tensor,
}

fn lin(t: &HashMap<String, Tensor>, key: &str) -> Result<(Tensor, Tensor)> {
    let w = t
        .get(&format!("{key}.weight"))
        .ok_or_else(|| candle_core::Error::Msg(format!("missing {key}.weight")))?
        .to_dtype(DType::F32)?;
    let b = t
        .get(&format!("{key}.bias"))
        .ok_or_else(|| candle_core::Error::Msg(format!("missing {key}.bias")))?
        .to_dtype(DType::F32)?;
    Ok((w, b))
}

impl GptTensors {
    pub fn load(map: &HashMap<String, Tensor>, n_layer: usize, n_head: usize) -> Result<Self> {
        let device = map
            .values()
            .next()
            .ok_or_else(|| candle_core::Error::Msg("empty safetensors".into()))?
            .device()
            .clone();
        let tok_emb = map
            .get("tok_emb.weight")
            .ok_or_else(|| candle_core::Error::Msg("missing tok_emb".into()))?
            .to_dtype(DType::F32)?;
        let pos_emb = map.get("pos_emb.weight").unwrap().to_dtype(DType::F32)?;
        let (ln_f_w, ln_f_b) = lin(map, "ln_f")?;
        let head_w = map.get("head.weight").unwrap().to_dtype(DType::F32)?;
        let d_model = tok_emb.dim(D::Minus1)?;
        let mut blocks = Vec::new();
        for i in 0..n_layer {
            let (ln1_w, ln1_b) = lin(map, &format!("blocks.{i}.ln1"))?;
            let (qkv_w, qkv_b) = lin(map, &format!("blocks.{i}.attn.qkv"))?;
            let (proj_w, proj_b) = lin(map, &format!("blocks.{i}.attn.proj"))?;
            let (ln2_w, ln2_b) = lin(map, &format!("blocks.{i}.ln2"))?;
            let (fc_w, fc_b) = lin(map, &format!("blocks.{i}.mlp.fc"))?;
            let (mlp_proj_w, mlp_proj_b) = lin(map, &format!("blocks.{i}.mlp.proj"))?;
            blocks.push(Block {
                ln1_w, ln1_b, qkv_w, qkv_b, proj_w, proj_b,
                ln2_w, ln2_b, fc_w, fc_b, mlp_proj_w, mlp_proj_b,
            });
        }
        Ok(Self { tok_emb, pos_emb, blocks, ln_f_w, ln_f_b, head_w, device, d_model, n_head })
    }

    fn dbg(name: &str, t: &Tensor) {
        if let Ok(flat) = t.to_dtype(DType::F32).and_then(|f| f.flatten_all()).and_then(|f| f.to_vec1::<f32>()) {
            let n = flat.len().min(4);
            let mean = flat.iter().sum::<f32>() / flat.len() as f32;
            let std = (flat.iter().map(|v| (v-mean)*(v-mean)).sum::<f32>() / flat.len() as f32).sqrt();
            let absmax = flat.iter().fold(0.0f32, |a, v| a.max(v.abs()));
            println!("[dbg] {name}: mean={mean:.5} std={std:.5} absmax={absmax:.5} first4={:?}",
                     &flat[..n]);
        }
    }

    /// idx: (B, T) u32 → logits (B, T, V)
    pub fn forward(&self, idx: &Tensor) -> Result<Tensor> {
        let (b_size, t) = idx.dims2()?;
        let dh = self.d_model / self.n_head;
        // embedding 查表：idx (B,T) → (B,T,C)；pos (T,) → (1,T,C)
        let b_size0 = b_size;
        let tok_rows: Vec<Tensor> = (0..b_size0)
            .map(|b| {
                let row = idx.narrow(0, b, 1)?.squeeze(0)?; // (T,)
                self.tok_emb.index_select(&row, 0)
            })
            .collect::<Result<Vec<_>>>()?;
        let tok_lut = Tensor::cat(&tok_rows, 0)?; // (B*T, C)
        let pos_idx = Tensor::arange(0u32, t as u32, &self.device)?;
        let pos_lut = self.pos_emb.index_select(&pos_idx, 0)?; // (T, C)
        let pos_lut = pos_lut.unsqueeze(0)?; // (1,T,C)
        let mut x = tok_lut
            .reshape((b_size, t, self.d_model))?
            .broadcast_add(&pos_lut)?;
        if std::env::var("CVLM_DEBUG").is_ok() {
            Self::dbg("emb_sum", &x);
        }

        // 因果 mask (T,T)，一次性缓存成本可接受
        let mask: Vec<Vec<f32>> = (0..t)
            .map(|i| {
                (0..t)
                    .map(|j| if j > i { f32::NEG_INFINITY } else { 0.0 })
                    .collect()
            })
            .collect();
        let mask = Tensor::new(mask, &self.device)?;

        let mut first = true;
        for blk in &self.blocks {
            let h = layer_norm(&x, &blk.ln1_w, &blk.ln1_b, 1e-5)?;
            let h2d = h.reshape((b_size * t, self.d_model))?;
            let qkv = h2d
                .matmul(&blk.qkv_w.t()?)?
                .broadcast_add(&blk.qkv_b.reshape((1, blk.qkv_b.elem_count()))?)?
                .reshape((b_size, t, 3, self.d_model))?;
            let q = qkv.narrow(2, 0, 1)?.squeeze(2)?;
            let k = qkv.narrow(2, 1, 1)?.squeeze(2)?;
            let v = qkv.narrow(2, 2, 1)?.squeeze(2)?;
            // (B,T,C) → (B,nh,T,dh)
            let shape = (b_size, t, self.n_head, dh);
            let q = q.reshape(shape)?.transpose(1, 2)?.contiguous()?;
            let k = k.reshape(shape)?.transpose(1, 2)?.contiguous()?;
            let v = v.reshape(shape)?.transpose(1, 2)?.contiguous()?;
            let att = q.matmul(&k.transpose(D::Minus2, D::Minus1)?.contiguous()?)?;
            let att = att
                .affine(1.0 / (dh as f64).sqrt(), 0.0)?
                .broadcast_add(&mask.reshape((1, 1, t, t))?)?;
            let att = candle_nn::ops::softmax_last_dim(&att)?;
            let y = att.matmul(&v)?; // (B,nh,T,dh)
            let y = y
                .transpose(1, 2)?
                .reshape((b_size, t, self.d_model))?
                .contiguous()?;
            let y2d = y.reshape((b_size * t, self.d_model))?;
            let attn_out = y2d
                .matmul(&blk.proj_w.t()?)?
                .broadcast_add(&blk.proj_b.reshape((1, blk.proj_b.elem_count()))?)?
                .reshape((b_size, t, self.d_model))?;
            if std::env::var("CVLM_DEBUG").is_ok() && first {
                Self::dbg("q3d", &qkv);
                Self::dbg("attn_out", &attn_out);
            }
            x = (x + attn_out)?;

            let h2 = layer_norm(&x, &blk.ln2_w, &blk.ln2_b, 1e-5)?;
            let h2d2 = h2.reshape((b_size * t, self.d_model))?;
            let m = h2d2
                .matmul(&blk.fc_w.t()?)?
                .broadcast_add(&blk.fc_b.reshape((1, blk.fc_b.elem_count()))?)?;
            let m = m.gelu_erf()?;
            let m = m
                .matmul(&blk.mlp_proj_w.t()?)?
                .broadcast_add(&blk.mlp_proj_b.reshape((1, blk.mlp_proj_b.elem_count()))?)?
                .reshape((b_size, t, self.d_model))?;
            if std::env::var("CVLM_DEBUG").is_ok() && first {
                Self::dbg("mlp_out", &m);
            }
            x = (x + m)?;
            first = false;
        }

        let x = layer_norm(&x, &self.ln_f_w, &self.ln_f_b, 1e-5)?;
        let x2d = x.reshape((b_size * t, self.d_model))?;
        x2d.matmul(&self.head_w.t()?)?.reshape((b_size, t, self.head_w.dim(0)?))
    }
}
