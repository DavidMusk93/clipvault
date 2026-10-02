//! ClipVault session plane.
//!
//! One PostgreSQL corpus, exposed as Session API v1 (SA-v1) by a facade
//! (`clipvault-session`) and fed by a fail-open collector (`clipvault-hook`).
//! See `docs/design-session-backends.md`.

pub mod config;
pub mod db;
pub mod facade;
pub mod metrics;
pub mod model;
pub mod role;

/// Wire timestamp: naive UTC `YYYY-MM-DD HH:MM:SS` (INV-5).
pub fn wire_ts(dt: &chrono::DateTime<chrono::Utc>) -> String {
    dt.format("%Y-%m-%d %H:%M:%S").to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    #[test]
    fn wire_ts_is_naive_utc_seconds() {
        let dt = chrono::Utc
            .with_ymd_and_hms(2026, 9, 30, 15, 7, 31)
            .unwrap();
        assert_eq!(wire_ts(&dt), "2026-09-30 15:07:31");
    }
}
