//! Environment-driven configuration. One DSN shape everywhere; discrete vars
//! plus a `chmod 600` password file are accepted so a secret never lands in an
//! env var or on the command line.

use std::path::PathBuf;
use std::time::Duration;

use anyhow::{Context, Result};

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|v| !v.is_empty())
}

pub fn pg_password() -> Option<String> {
    if let Some(path) = env("CLIPVAULT_PG_PASSWORD_FILE") {
        if let Ok(text) = std::fs::read_to_string(PathBuf::from(path).expand_home()) {
            let t = text.trim();
            if !t.is_empty() {
                return Some(t.to_string());
            }
        }
    }
    env("CLIPVAULT_PG_PASSWORD")
}

pub fn connect_timeout() -> Duration {
    let secs = env("CLIPVAULT_PG_CONNECT_TIMEOUT_SEC")
        .and_then(|v| v.parse::<f64>().ok())
        .unwrap_or(3.0);
    Duration::from_secs_f64(secs.max(0.2))
}

/// Build a `tokio_postgres` config. `options` pins the session timezone to UTC so
/// naive-UTC writes are stored verbatim and timestamptz reads come back in UTC.
pub fn pg_config() -> Result<tokio_postgres::Config> {
    let mut cfg = if let Some(dsn) = env("CLIPVAULT_PG_DSN") {
        dsn.parse::<tokio_postgres::Config>()
            .context("parse CLIPVAULT_PG_DSN")?
    } else {
        let mut c = tokio_postgres::Config::new();
        c.host(env("CLIPVAULT_PG_HOST").unwrap_or_else(|| "127.0.0.1".into()));
        c.port(
            env("CLIPVAULT_PG_PORT")
                .and_then(|v| v.parse::<u16>().ok())
                .unwrap_or(55432),
        );
        c.dbname(env("CLIPVAULT_PG_DB").unwrap_or_else(|| "clipvault".into()));
        c.user(env("CLIPVAULT_PG_USER").unwrap_or_else(|| "clipvault".into()));
        if let Some(pw) = pg_password() {
            c.password(pw);
        }
        c
    };
    cfg.options("-c TimeZone=UTC");
    cfg.connect_timeout(connect_timeout());
    Ok(cfg)
}

pub fn pool_size() -> usize {
    env("CLIPVAULT_PG_POOL")
        .and_then(|v| v.parse().ok())
        .unwrap_or(8)
}

/// Read a single string env var with a default.
pub fn var(name: &str, default: &str) -> String {
    env(name).unwrap_or_else(|| default.to_string())
}

/// Small helper so `~` in file paths works without a `dirs` dependency.
trait ExpandHome {
    fn expand_home(self) -> PathBuf;
}

impl ExpandHome for PathBuf {
    fn expand_home(self) -> PathBuf {
        let s = self.to_string_lossy().to_string();
        if let Some(rest) = s.strip_prefix("~/") {
            if let Ok(home) = std::env::var("HOME") {
                return PathBuf::from(home).join(rest);
            }
        }
        self
    }
}
