//! ClipVault session plane.
//!
//! One PostgreSQL corpus, exposed as Session API v1 (SA-v1) by a facade
//! (`clipvault-session`) and fed by a fail-open collector (`clipvault-hook`).
//! See `docs/design-session-backends.md`.

pub mod config;
pub mod db;
pub mod facade;
pub mod model;

/// Wire timestamp: naive UTC `YYYY-MM-DD HH:MM:SS` (INV-5).
pub fn wire_ts(dt: &chrono::DateTime<chrono::Utc>) -> String {
    dt.format("%Y-%m-%d %H:%M:%S").to_string()
}
