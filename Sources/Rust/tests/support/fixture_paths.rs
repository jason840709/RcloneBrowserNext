//! Match Foundation's ordinary absolute path spelling at JSON boundaries.
//! Rust canonicalize adds a Win32 verbatim prefix; that implementation detail
//! is not a user endpoint or a change to the original filename assertions.
use std::{
    fs,
    path::{Path, PathBuf},
};
pub fn wire(path: &Path) -> String {
    let text = path.to_str().expect("UTF-8 synthetic fixture path");
    #[cfg(windows)]
    {
        let ordinary = if let Some(rest) = text.strip_prefix(r"\\?\UNC\") {
            format!(r"\\{rest}")
        } else {
            text.strip_prefix(r"\\?\").unwrap_or(text).to_owned()
        };
        ordinary.replace('\\', "/")
    }
    #[cfg(not(windows))]
    {
        text.to_owned()
    }
}
pub fn canonical(path: &Path) -> PathBuf {
    PathBuf::from(wire(&fs::canonicalize(path).unwrap()))
}
