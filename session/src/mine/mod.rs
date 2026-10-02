//! Session mining: sessions are an asset only if they produce feedback.
//!
//! Rust port of `trae_hooks/mine.py`. Layered so each layer compiles and is
//! testable on its own:
//!
//!   primitives  parsing / classification / path identity
//!   analysis    metrics_analysis, build_losses, insights, brief, acks attach
//!   rows        mine_rows (per-event extraction into counters + turns)
//!   run         SQL fetch + `mine()` orchestration + `ack_finding`
//!
//! Contract: `docs/session-analysis.md`.

use std::collections::HashMap;

pub mod analysis;
pub mod primitives;
pub mod rows;
pub mod run;

pub use primitives::*;

/// Canonical direction ids, in catalog order.
pub fn dir_ids() -> Vec<&'static str> {
    DIRECTIONS.iter().map(|d| d.id).collect()
}

/// An insertion-ordered multiset. Python's `Counter.most_common` is a stable
/// sort over insertion order, so ties must break by first-seen to match the
/// oracle byte-for-byte.
#[derive(Clone, Debug, Default)]
pub struct Counter {
    counts: HashMap<String, u64>,
    order: Vec<String>,
}

impl Counter {
    pub fn add(&mut self, key: &str, n: u64) {
        if !self.counts.contains_key(key) {
            self.order.push(key.to_string());
        }
        *self.counts.entry(key.to_string()).or_insert(0) += n;
    }

    pub fn bump(&mut self, key: &str) {
        self.add(key, 1);
    }

    pub fn get(&self, key: &str) -> u64 {
        self.counts.get(key).copied().unwrap_or(0)
    }

    pub fn is_empty(&self) -> bool {
        self.order.is_empty()
    }

    pub fn len(&self) -> usize {
        self.order.len()
    }

    /// Keys in insertion order (empty keys included; callers filter as Python does).
    pub fn keys(&self) -> &[String] {
        &self.order
    }

    pub fn values(&self) -> impl Iterator<Item = u64> + '_ {
        self.order.iter().map(|k| self.counts[k])
    }

    pub fn sum(&self) -> u64 {
        self.counts.values().sum()
    }

    /// Stable most-common: count desc, first-seen asc on ties.
    pub fn most_common(&self, n: usize) -> Vec<(String, u64)> {
        let mut v: Vec<(String, u64)> = self
            .order
            .iter()
            .map(|k| (k.clone(), self.counts[k]))
            .collect();
        v.sort_by(|a, b| b.1.cmp(&a.1));
        v.truncate(n);
        v
    }
}

/// `_rank`: most_common(n), dropping empty keys.
pub fn rank(counter: &Counter, n: usize) -> Vec<(String, u64)> {
    counter
        .most_common(n)
        .into_iter()
        .filter(|(k, _)| !k.is_empty())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counter_breaks_ties_by_first_seen() {
        let mut c = Counter::default();
        c.bump("b");
        c.bump("a");
        c.bump("b");
        // b has 2, a has 1 -> b first; equal counts would keep insertion order.
        assert_eq!(c.most_common(5), vec![("b".into(), 2), ("a".into(), 1)]);
        assert_eq!(c.get("z"), 0);
    }
}
