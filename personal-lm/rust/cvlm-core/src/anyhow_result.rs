//! 轻量 error 容器（避免 anyhow 依赖）
    use std::fmt;

    #[derive(Debug)]
    pub struct Error(pub String);
    impl fmt::Display for Error {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            write!(f, "{}", self.0)
        }
    }
    impl std::error::Error for Error {}
    pub type Result<T> = std::result::Result<T, Error>;
    pub fn err(msg: impl Into<String>) -> Error {
        Error(msg.into())
    }
    pub fn ensure(cond: bool, msg: &str) -> Result<()> {
        if cond {
            Ok(())
        } else {
            Err(err(msg.to_string()))
        }
    }
    impl From<serde_json::Error> for Error {
        fn from(e: serde_json::Error) -> Self {
            Error(e.to_string())
        }
    }
    impl From<regex::Error> for Error {
        fn from(e: regex::Error) -> Self {
            Error(e.to_string())
        }
    }
    impl From<std::num::ParseIntError> for Error {
        fn from(e: std::num::ParseIntError) -> Self {
            Error(e.to_string())
        }
    }
    impl From<candle_core::Error> for Error {
        fn from(e: candle_core::Error) -> Self {
            Error(e.to_string())
        }
    }
    impl From<std::io::Error> for Error {
        fn from(e: std::io::Error) -> Self {
            Error(e.to_string())
        }
    }
