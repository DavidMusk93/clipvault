//! cvlm-core — ClipVault 个人小模型推理核心（candle）。
//! bundle 布局见 docs/designs/feature-personal-lm.md；applet 复用：
//!   let eng = cvlm_core::Engine::load(bundle_dir)?;
//!   eng.generate(prompt, &GenParams{..})?;

pub mod anyhow_result;
pub mod engine;
pub mod gpt;
pub mod tokenizer;

pub use engine::{Engine, GenParams, SharedEngine};
