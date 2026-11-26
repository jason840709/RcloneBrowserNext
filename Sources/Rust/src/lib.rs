pub type Result<T> = std::result::Result<T, String>;
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
pub mod accounts;
pub mod engine;
pub mod local;
pub mod models;
pub mod process;
pub mod report;
pub mod retry;
pub mod stats;
pub mod storage;
pub mod tools;
pub mod updater;
pub fn now() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

pub mod catalog;
pub mod logging;
pub mod partial;

pub mod native;

pub mod native_requests;

pub mod history;

/// Foundation UUID(uuidString:) accepts the standard 36-character spelling.
pub fn valid_id(value: &str) -> bool {
    value.len() == 36 && uuid::Uuid::parse_str(value).is_ok()
}

#[cfg(windows)]
pub mod windows_local;

pub mod platform_text;

#[cfg(target_os = "macos")]
pub mod mac_exports;
