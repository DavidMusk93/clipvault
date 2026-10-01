//! clipvault-session: the SA-v1 facade (HTTP + SSE), backed by PostgreSQL.
//!
//! `clipvault-session` serves the read plane and pin/ack. Collectors write
//! directly to PostgreSQL; the facade learns of new rows through
//! `LISTEN clipvault_hook`.

use std::path::PathBuf;

use anyhow::Result;
use clipvault_session::config;
use clipvault_session::{db, facade};
use tokio::sync::broadcast;

fn main() -> Result<()> {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;
    runtime.block_on(async_main())
}

async fn async_main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let pg = config::pg_config()?;
    let pool = db::build_pool(pg.clone())?;

    let (tx, _) = broadcast::channel::<serde_json::Value>(256);
    tokio::spawn(db::listen_forever(pg, tx.clone()));

    let web_dirs: Vec<PathBuf> = config::var("CLIPVAULT_SESSION_WEB_DIR", "")
        .split(':')
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .collect();

    let state = facade::AppState {
        pool,
        backend_id: config::var("CLIPVAULT_BACKEND_ID", "local"),
        corpus_id: config::var("CLIPVAULT_CORPUS_ID", "clipvault"),
        role: config::var("CLIPVAULT_BACKEND_ROLE", "primary"),
        store_label: config::var("CLIPVAULT_PG_DB", "clipvault"),
        tx,
        web_dirs,
    };

    let host = config::var("CLIPVAULT_TRAE_HTTP_HOST", "127.0.0.1");
    let port = config::var("CLIPVAULT_TRAE_HTTP_PORT", "9488");
    let addr = format!("{host}:{port}");
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    tracing::info!(%addr, backend = %state.backend_id, "clipvault-session listening");
    axum::serve(listener, facade::router(state))
        .with_graceful_shutdown(shutdown_signal())
        .await?;
    Ok(())
}

async fn shutdown_signal() {
    let _ = tokio::signal::ctrl_c().await;
    tracing::info!("shutdown");
}
