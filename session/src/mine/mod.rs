//! Session mining: sessions are an asset only if they produce feedback.
//!
//! Rust port of `trae_hooks/mine.py`. Layered on purpose so each layer compiles
//! and is testable on its own:
//!
//!   primitives  (this module)      parsing / classification / path identity
//!   rows        mine_rows          per-event extraction into counters + turns
//!   metrics     metrics_analysis   cost / cache / context facts
//!   losses      build_losses       attributable loss ledger
//!   brief       agent_brief/view   the agent/human output contract
//!   acks        attach_acks        L3 write-back
//!   run         mine()             orchestration + SQL fetch
//!
//! Contract: `docs/session-analysis.md`.

pub mod primitives;

pub use primitives::*;

/// Canonical direction ids, in catalog order.
pub fn dir_ids() -> Vec<&'static str> {
    DIRECTIONS.iter().map(|d| d.id).collect()
}
