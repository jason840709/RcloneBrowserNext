use crate::Result;
use serde_json::Value;
use std::{
    fs::{self, File, OpenOptions},
    io::{self, Read, Write},
    path::{Path, PathBuf},
};
use unicode_normalization::UnicodeNormalization;
use uuid::Uuid;

pub fn private_directory(path: &Path) -> Result<()> {
    let mut dir = fs::DirBuilder::new();
    dir.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        dir.mode(0o700);
    }
    dir.create(path).map_err(|e| e.to_string())?;
    let meta = fs::metadata(path).map_err(|e| e.to_string())?;
    if !meta.is_dir() {
        return Err("無法建立專用資料夾。".into());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
        let opened = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY)
            .open(path)
            .map_err(|e| e.to_string())?;
        opened
            .set_permissions(fs::Permissions::from_mode(0o700))
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}
pub fn atomic_data(path: &Path, data: &[u8]) -> Result<()> {
    let dir = path.parent().ok_or("儲存位置不正確。")?;
    let base = path.file_name().ok_or("儲存位置不正確。")?;
    let temp = dir.join(format!(
        ".{}.{}.tmp",
        base.to_string_lossy(),
        Uuid::new_v4()
    ));
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut writer = options
        .open(&temp)
        .map_err(|_| format!("無法寫入 {}。", base.to_string_lossy()))?;
    let result = (|| -> Result<()> {
        writer.write_all(data).map_err(|e| e.to_string())?;
        writer.sync_all().map_err(|e| e.to_string())?;
        #[cfg(windows)]
        {
            drop(writer);
            crate::accounts::replace_file(&temp, path)?;
        }
        #[cfg(not(windows))]
        {
            fs::rename(&temp, path).map_err(|e| e.to_string())?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                writer
                    .set_permissions(fs::Permissions::from_mode(0o600))
                    .map_err(|e| e.to_string())?;
            }
        }
        Ok(())
    })();
    if result.is_err() {
        let _ = remove_file_if_present(&temp);
    }
    result
}
pub fn atomic_json(path: &Path, value: &Value) -> Result<()> {
    if !value.is_object() && !value.is_array() {
        return Err("資料無法儲存成 JSON。".into());
    }
    let mut data = serde_json::to_vec_pretty(value).map_err(|e| e.to_string())?;
    data.push(b'\n');
    atomic_data(path, &data)
}
#[cfg(windows)]
pub(crate) fn win32_wide(path: &Path) -> Vec<u16> {
    let value = path.to_string_lossy().replace('/', r"\");
    let extended = if value.starts_with(r"\\?\") {
        value
    } else if let Some(rest) = value.strip_prefix(r"\\") {
        format!(r"\\?\UNC\{rest}")
    } else {
        format!(r"\\?\{value}")
    };
    extended.encode_utf16().chain(Some(0)).collect()
}
pub(crate) fn remove_file_if_present(path: &Path) -> Result<()> {
    #[cfg(windows)]
    let outcome = {
        let wide = win32_wide(path);
        if unsafe { windows_sys::Win32::Storage::FileSystem::DeleteFileW(wide.as_ptr()) } != 0 {
            Ok(())
        } else {
            Err(io::Error::last_os_error())
        }
    };
    #[cfg(not(windows))]
    let outcome = fs::remove_file(path);
    match outcome {
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        other => other.map_err(|e| e.to_string()),
    }
}
/// Decode persisted or whole-document JSON using Foundation's encoding detection.
pub fn decode_json_bytes(bytes: &[u8]) -> Result<Value> {
    // Test the four-byte BOM first: UTF-32LE shares its prefix with UTF-16LE.
    // Foundation sniffs unmarked UTF-16/32 only when more than four bytes exist.
    let decoded = match bytes {
        [0xff, 0xfe, 0, 0, data @ ..] => decode_utf32(data, u32::from_le_bytes)?,
        [0, 0, 0xfe, 0xff, data @ ..] => decode_utf32(data, u32::from_be_bytes)?,
        [0xff, 0xfe, data @ ..] => decode_utf16(data, u16::from_le_bytes)?,
        [0xfe, 0xff, data @ ..] => decode_utf16(data, u16::from_be_bytes)?,
        [0xef, 0xbb, 0xbf, data @ ..] => {
            return serde_json::from_slice(data).map_err(|e| e.to_string());
        }
        [_, 0, 0, 0, _, ..] => decode_utf32(bytes, u32::from_le_bytes)?,
        [0, 0, 0, _, _, ..] => decode_utf32(bytes, u32::from_be_bytes)?,
        [_, 0, _, 0, _, ..] => decode_utf16(bytes, u16::from_le_bytes)?,
        [0, _, 0, _, _, ..] => decode_utf16(bytes, u16::from_be_bytes)?,
        _ => return serde_json::from_slice(bytes).map_err(|e| e.to_string()),
    };
    serde_json::from_str(&decoded).map_err(|e| e.to_string())
}

// The released reader disregards a partial trailing code unit. JSON syntax
// still has to be complete, and all complete code units must encode scalars.
fn decode_utf16(data: &[u8], unit: fn([u8; 2]) -> u16) -> Result<String> {
    char::decode_utf16(data.chunks_exact(2).map(|pair| unit([pair[0], pair[1]])))
        .collect::<std::result::Result<String, _>>()
        .map_err(|e| e.to_string())
}

fn decode_utf32(data: &[u8], unit: fn([u8; 4]) -> u32) -> Result<String> {
    data.chunks_exact(4)
        .map(|c| {
            char::from_u32(unit([c[0], c[1], c[2], c[3]]))
                .ok_or_else(|| "JSON 包含無效的 UTF-32 碼位。".to_owned())
        })
        .collect()
}

pub fn read_json(path: &Path, fallback: Value) -> Result<Value> {
    const LIMIT: u64 = 32 * 1024 * 1024;
    let Ok(meta) = fs::metadata(path) else {
        return Ok(fallback);
    };
    if meta.is_file() && meta.len() <= LIMIT {
        let read = (|| -> io::Result<Vec<u8>> {
            let mut bytes = Vec::new();
            File::open(path)?.take(LIMIT + 1).read_to_end(&mut bytes)?;
            Ok(bytes)
        })();
        if let Ok(bytes) = read {
            if bytes.len() as u64 <= LIMIT {
                if let Ok(value) = decode_json_bytes(&bytes) {
                    return Ok(value);
                }
            }
        }
    }
    let mut backup = path.as_os_str().to_owned();
    backup.push(format!(".unreadable-{}", Uuid::new_v4()));
    // The legacy store offers its fallback even when the backup cannot be moved.
    let _ = fs::rename(path, backup);
    Ok(fallback)
}
/// Returns a comparison key only. Path casing and Unicode spelling can differ
/// from the actual directory, so callers must never use this for I/O.
pub fn canonical_local(input: &str) -> Result<PathBuf> {
    let normalized = crate::models::standardized(input)?;
    let mut candidate = Path::new(&normalized);
    let mut missing = Vec::new();
    let mut resolved = loop {
        match fs::canonicalize(candidate) {
            Ok(path) => break path,
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                missing.push(candidate.file_name().ok_or("無法解析本機路徑。")?);
                candidate = candidate.parent().ok_or("無法解析本機路徑。")?;
            }
            Err(e) => return Err(e.to_string()),
        }
    };
    for part in missing.iter().rev() {
        resolved.push(part);
    }
    let text = resolved.to_str().ok_or("本機路徑編碼無法辨識。")?;
    #[cfg(windows)]
    let path = {
        let normalized = text.replace('\\', "/");
        if let Some(rest) = normalized.strip_prefix("//?/UNC/") {
            format!("//{rest}")
        } else {
            normalized
                .strip_prefix("//?/")
                .unwrap_or(&normalized)
                .into()
        }
    };
    #[cfg(not(windows))]
    let path = text.to_owned();
    let key = if cfg!(any(target_os = "macos", windows)) {
        path.to_lowercase()
    } else {
        path
    };
    Ok(PathBuf::from(key.nfc().collect::<String>()))
}
#[cfg(test)]
mod platform_file_tests {
    use super::*;
    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!("rbn-platform-file-{}", Uuid::new_v4()));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn exclusive_unicode_create_preserves_existing_bytes() {
        let f = Fixture::new();
        let path = f.0.join("測試-日本語.txt");
        crate::accounts::create_exclusive(&path)
            .unwrap()
            .write_all(b"original")
            .unwrap();
        assert!(crate::accounts::create_exclusive(&path).is_err());
        assert_eq!(fs::read(path).unwrap(), b"original");
    }
    #[test]
    fn regular_reader_handles_missing_files_bytes_and_directories() {
        let f = Fixture::new();
        assert_eq!(
            crate::accounts::read_regular(&f.0.join("missing"), 1024).unwrap(),
            None
        );
        let path = f.0.join("測試-日本語.txt");
        fs::write(&path, b"original").unwrap();
        assert_eq!(
            crate::accounts::read_regular(&path, 1024).unwrap().unwrap(),
            b"original"
        );
        assert!(crate::accounts::read_regular(&f.0, 1024).is_err());
    }
    #[test]
    fn atomic_replacement_commits_complete_bytes_and_removes_staging() {
        let f = Fixture::new();
        let source = f.0.join("new.txt");
        let target = f.0.join("old.txt");
        fs::write(&source, b"new-data").unwrap();
        fs::write(&target, b"old-data").unwrap();
        crate::accounts::replace_file(&source, &target).unwrap();
        assert_eq!(fs::read(target).unwrap(), b"new-data");
        assert!(!source.exists());
    }
    #[test]
    fn missing_unlink_is_harmless_directory_unlink_is_rejected() {
        let f = Fixture::new();
        remove_file_if_present(&f.0.join("absent")).unwrap();
        assert!(remove_file_if_present(&f.0).is_err());
        assert!(f.0.is_dir());
    }
    #[cfg(unix)]
    #[test]
    fn report_reader_rejects_symlink_and_unlink_preserves_target() {
        let f = Fixture::new();
        let target = f.0.join("keep.txt");
        let id = Uuid::new_v4().to_string();
        let link = f.0.join(format!("{id}.report.jsonl"));
        fs::write(&target, b"keep").unwrap();
        std::os::unix::fs::symlink(&target, &link).unwrap();
        assert!(crate::accounts::read_regular(&link, 1024).is_err());
        assert!(crate::report::path(&f.0, &id, "jsonl").is_err());
        remove_file_if_present(&link).unwrap();
        assert_eq!(fs::read(target).unwrap(), b"keep");
    }
}
