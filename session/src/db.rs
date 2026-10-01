//! PostgreSQL pool + `LISTEN` fan-out + row -> JSON.

use std::future::poll_fn;
use std::time::Duration;

use anyhow::{Context, Result};
use deadpool_postgres::{Manager, ManagerConfig, RecyclingMethod, Runtime};
use serde_json::{Map, Value};
use tokio::sync::{broadcast, mpsc};
use tokio_postgres::types::Type;
use tokio_postgres::{AsyncMessage, NoTls, Row};

pub use deadpool_postgres::Pool;

pub type Client = deadpool_postgres::Client;

pub fn build_pool(cfg: tokio_postgres::Config) -> Result<Pool> {
    let manager = Manager::from_config(
        cfg,
        NoTls,
        ManagerConfig {
            recycling_method: RecyclingMethod::Fast,
        },
    );
    Pool::builder(manager)
        .max_size(crate::config::pool_size())
        .runtime(Runtime::Tokio1)
        .build()
        .context("build pg pool")
}

/// Dedicated connection, `LISTEN`, forward notifications into the broadcast hub.
///
/// The connection is driven in a task so `Client` requests (the `LISTEN` itself)
/// are serviced; `AsyncMessage::Notification` is forwarded over an mpsc channel.
/// Reconnects forever; the facade never fails because the listener is down.
pub async fn listen_forever(cfg: tokio_postgres::Config, tx: broadcast::Sender<Value>) {
    loop {
        match cfg.connect(NoTls).await {
            Ok((client, mut connection)) => {
                let (ntx, mut nrx) = mpsc::channel::<tokio_postgres::Notification>(256);
                let driver = tokio::spawn(async move {
                    loop {
                        match poll_fn(|cx| connection.poll_message(cx)).await {
                            Some(Ok(AsyncMessage::Notification(note))) => {
                                if ntx.send(note).await.is_err() {
                                    break;
                                }
                            }
                            Some(Ok(_)) => {}
                            Some(Err(e)) => {
                                tracing::warn!(error = %e, "pg listen connection error");
                                break;
                            }
                            None => break,
                        }
                    }
                });
                if let Err(e) = client.batch_execute("LISTEN clipvault_hook").await {
                    tracing::warn!(error = %e, "LISTEN clipvault_hook failed");
                    driver.abort();
                    tokio::time::sleep(Duration::from_secs(2)).await;
                    continue;
                }
                tracing::info!("LISTEN clipvault_hook");
                while let Some(note) = nrx.recv().await {
                    match serde_json::from_str::<Value>(note.payload()) {
                        Ok(v) => {
                            let _ = tx.send(v);
                        }
                        Err(e) => tracing::warn!(error = %e, "bad notify payload"),
                    }
                }
                driver.abort();
            }
            Err(e) => tracing::warn!(error = %e, "pg listen connect failed"),
        }
        tokio::time::sleep(Duration::from_secs(2)).await;
    }
}

/// Convert any result row to JSON, mapping known Postgres types explicitly so
/// integers stay integers and timestamps hit the naive-UTC wire format (INV-5).
pub fn row_to_value(row: &Row) -> Value {
    let mut map = Map::new();
    for (i, col) in row.columns().iter().enumerate() {
        let value = match *col.type_() {
            Type::BOOL => row
                .get::<_, Option<bool>>(i)
                .map(Value::Bool)
                .unwrap_or(Value::Null),
            Type::INT2 => row
                .get::<_, Option<i16>>(i)
                .map(|v| Value::from(v as i64))
                .unwrap_or(Value::Null),
            Type::INT4 => row
                .get::<_, Option<i32>>(i)
                .map(|v| Value::from(v as i64))
                .unwrap_or(Value::Null),
            Type::INT8 => row
                .get::<_, Option<i64>>(i)
                .map(Value::from)
                .unwrap_or(Value::Null),
            Type::FLOAT4 => row
                .get::<_, Option<f32>>(i)
                .map(|v| Value::from(v as f64))
                .unwrap_or(Value::Null),
            Type::FLOAT8 => row
                .get::<_, Option<f64>>(i)
                .map(Value::from)
                .unwrap_or(Value::Null),
            Type::TIMESTAMPTZ | Type::TIMESTAMP => {
                match row.get::<_, Option<chrono::DateTime<chrono::Utc>>>(i) {
                    Some(dt) => Value::String(crate::wire_ts(&dt)),
                    None => Value::Null,
                }
            }
            _ => match row.get::<_, Option<String>>(i) {
                Some(s) => Value::String(s),
                None => Value::Null,
            },
        };
        map.insert(col.name().to_string(), value);
    }
    Value::Object(map)
}
