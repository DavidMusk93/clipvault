//! Session backend registry: the fan-in plugin list.
//!
//! One JSON descriptor per backend under `~/.config/clipvault/backends.d/`.
//! Backends that share a `corpus_id` are replicas of one corpus; the aggregator
//! fails over within a corpus and merges across corpora.

use std::path::Path;

use anyhow::Context;
use serde::Deserialize;

#[derive(Clone, Debug, Deserialize)]
pub struct Backend {
    pub id: String,
    #[serde(default)]
    pub label: String,
    #[serde(default = "default_api_version")]
    pub api_version: u32,
    pub corpus_id: String,
    #[serde(default = "default_role")]
    pub role: String,
    #[serde(default)]
    pub priority: i64,
    pub base_url: String,
}

fn default_api_version() -> u32 {
    1
}
fn default_role() -> String {
    "replica".to_string()
}

impl Backend {
    pub fn is_primary(&self) -> bool {
        self.role == "primary"
    }
}

#[derive(Clone, Debug, Default)]
pub struct Registry {
    pub backends: Vec<Backend>,
}

impl Registry {
    /// Load every `*.json` descriptor. A malformed file is reported but does not
    /// abort startup: the remaining backends still serve.
    pub fn load(dir: &Path) -> Self {
        let mut backends = Vec::new();
        let Ok(read) = std::fs::read_dir(dir) else {
            eprintln!("registry: {} unreadable; starting empty", dir.display());
            return Self { backends };
        };
        let mut paths: Vec<_> = read.filter_map(|e| e.ok().map(|e| e.path())).collect();
        paths.sort();
        for path in paths {
            if path.extension().and_then(|e| e.to_str()) != Some("json") {
                continue;
            }
            match std::fs::read_to_string(&path)
                .context("read descriptor")
                .and_then(|t| serde_json::from_str::<Backend>(&t).context("parse descriptor"))
            {
                Ok(backend) => backends.push(backend),
                Err(e) => eprintln!("registry: skipping {}: {e:#}", path.display()),
            }
        }
        Self { backends }
    }

    pub fn corpora(&self) -> Vec<String> {
        let mut ids: Vec<String> = self.backends.iter().map(|b| b.corpus_id.clone()).collect();
        ids.sort();
        ids.dedup();
        ids
    }

    pub fn members(&self, corpus: &str) -> Vec<&Backend> {
        self.backends
            .iter()
            .filter(|b| b.corpus_id == corpus)
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn groups_members_by_corpus_and_sorts() {
        let reg = Registry {
            backends: vec![
                Backend {
                    id: "d2".into(),
                    label: String::new(),
                    api_version: 1,
                    corpus_id: "clipvault".into(),
                    role: "primary".into(),
                    priority: 100,
                    base_url: "http://127.0.0.1:29488".into(),
                },
                Backend {
                    id: "cc".into(),
                    label: String::new(),
                    api_version: 1,
                    corpus_id: "clipvault".into(),
                    role: "replica".into(),
                    priority: 10,
                    base_url: "http://127.0.0.1:29489".into(),
                },
            ],
        };
        assert_eq!(reg.corpora(), vec!["clipvault".to_string()]);
        let members = reg.members("clipvault");
        assert_eq!(members.len(), 2);
        assert!(members[0].is_primary());
    }
}
