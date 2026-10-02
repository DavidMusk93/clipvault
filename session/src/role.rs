//! Backend role as a closed type.
//!
//! A backend is either the primary (accepts writes) or a replica (read-only).
//! Modelling it as an enum keeps the illegal third state unrepresentable, and
//! `parse` fails fast on an unknown value instead of silently defaulting to
//! primary (which would mis-route writes).

use anyhow::{bail, Result};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BackendRole {
    Primary,
    Replica,
}

impl BackendRole {
    pub fn parse(raw: &str) -> Result<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "primary" | "" => Ok(Self::Primary),
            "replica" => Ok(Self::Replica),
            other => bail!("unknown CLIPVAULT_BACKEND_ROLE {other:?} (primary|replica)"),
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Primary => "primary",
            Self::Replica => "replica",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_both_roles_case_insensitively() {
        assert_eq!(BackendRole::parse("primary").unwrap(), BackendRole::Primary);
        assert_eq!(BackendRole::parse("Replica").unwrap(), BackendRole::Replica);
        assert_eq!(BackendRole::parse("").unwrap(), BackendRole::Primary);
    }

    #[test]
    fn rejects_unknown_role() {
        assert!(BackendRole::parse("leader").is_err());
    }
}
