//! PostgreSQL pool + `LISTEN` fan-out + row -> JSON.

use std::future::poll_fn;
use std::time::Duration;

use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use deadpool_postgres::{Manager, ManagerConfig, RecyclingMethod, Runtime};
use serde_json::{Map, Value};
use tokio::sync::{broadcast, mpsc};
use tokio_postgres::types::{ToSql, Type};
use tokio_postgres::{AsyncMessage, NoTls, Row as PgRow};

pub use deadpool_postgres::Pool;

pub type Client = deadpool_postgres::Client;

/// A typed column value. Keeps `INSERT` parameter typing explicit (int4 vs int8
/// matters) and lets callers build heterogeneous rows without boxing at the site.
#[derive(Clone, Debug)]
pub enum PgVal {
    Text(Option<String>),
    Int(Option<i64>),
    Int4(Option<i32>),
    Float(Option<f64>),
    Bool(Option<bool>),
    Ts(Option<DateTime<Utc>>),
}

impl PgVal {
    pub fn boxed(&self) -> Box<dyn ToSql + Send + Sync> {
        match self {
            PgVal::Text(v) => Box::new(v.clone()),
            PgVal::Int(v) => Box::new(*v),
            PgVal::Int4(v) => Box::new(*v),
            PgVal::Float(v) => Box::new(*v),
            PgVal::Bool(v) => Box::new(*v),
            PgVal::Ts(v) => Box::new(*v),
        }
    }

    pub fn as_i64(&self) -> Option<i64> {
        match self {
            PgVal::Int(v) => *v,
            PgVal::Int4(v) => v.map(i64::from),
            _ => None,
        }
    }

    pub fn as_f64(&self) -> Option<f64> {
        match self {
            PgVal::Float(v) => *v,
            _ => None,
        }
    }

    pub fn as_text(&self) -> Option<&str> {
        match self {
            PgVal::Text(v) => v.as_deref(),
            _ => None,
        }
    }
}
/// A row as ordered (column, value) pairs. Column names are the wire contract.
pub type Row = Vec<(&'static str, PgVal)>;

pub fn row_get<'a>(row: &'a Row, col: &str) -> Option<&'a PgVal> {
    row.iter().find(|(name, _)| *name == col).map(|(_, v)| v)
}

/// One `INSERT ... VALUES (…),(…) ON CONFLICT DO NOTHING` for many rows.
///
/// Every row must supply every column in `cols`; a missing column is inserted as
/// a `NULL` of the column's type is *not* attempted (that would mistype int8 as
/// text). Callers pass the exact column set their rows carry.
pub async fn insert_batch(
    client: &tokio_postgres::Client,
    table: &str,
    cols: &[&str],
    rows: &[Row],
) -> Result<usize> {
    if rows.is_empty() {
        return Ok(0);
    }
    let mut tuples: Vec<String> = Vec::with_capacity(rows.len());
    let mut params: Vec<Box<dyn ToSql + Send + Sync>> = Vec::with_capacity(rows.len() * cols.len());
    for row in rows {
        let mut placeholders: Vec<String> = Vec::with_capacity(cols.len());
        for col in cols {
            let value = row_get(row, col).cloned().unwrap_or(PgVal::Text(None));
            params.push(value.boxed());
            placeholders.push(format!("${}", params.len()));
        }
        tuples.push(format!("({})", placeholders.join(", ")));
    }
    let sql = format!(
        "INSERT INTO {table} ({}) VALUES {} ON CONFLICT DO NOTHING",
        cols.join(", "),
        tuples.join(", ")
    );
    let refs: Vec<&(dyn ToSql + Sync)> = params
        .iter()
        .map(|b| b.as_ref() as &(dyn ToSql + Sync))
        .collect();
    client.execute(&sql, &refs).await?;
    Ok(rows.len())
}

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
pub fn row_to_value(row: &PgRow) -> Value {
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
