//! Raw rclone logs retain the 0.11.0 five-segment, 20 MiB format.
use crate::Result;
use serde_json::json;
use std::{
    fs::{self, File, OpenOptions},
    io::{self, Write},
    path::{Path, PathBuf},
};
const SEGMENT_BYTES: u64 = 20 * 1024 * 1024;
const ROTATION_MESSAGE: &str = "紀錄檔已自動輪替（每項工作最多保留最近 100 MiB）。";
pub struct Log {
    path: PathBuf,
    file: Option<File>,
    bytes: u64,
}
fn open(path: &Path, append: bool) -> Result<File> {
    let mut options = OpenOptions::new();
    options.write(true).create(true);
    if append {
        options.append(true);
    } else {
        options.truncate(true);
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(path).map_err(|e| e.to_string())
}
fn remove_item(path: &Path) -> Result<()> {
    let metadata = fs::symlink_metadata(path).map_err(|e| e.to_string())?;
    if metadata.is_dir() && !metadata.file_type().is_symlink() {
        fs::remove_dir_all(path)
    } else {
        fs::remove_file(path)
    }
    .map_err(|e| e.to_string())
}
impl Log {
    pub fn new(directory: &Path, id: &str) -> Result<Self> {
        let path = directory.join(format!("{id}.jsonl"));
        let file = open(&path, true)?;
        let bytes = file.metadata().map_err(|e| e.to_string())?.len();
        Ok(Self {
            path,
            file: Some(file),
            bytes,
        })
    }
    pub fn append(&mut self, line: &str) -> Result<()> {
        let newline = !line.ends_with('\n');
        let additional = line.len() as u64 + u64::from(newline);
        if self.bytes.saturating_add(additional) > SEGMENT_BYTES {
            if let Some(file) = self.file.take() {
                file.sync_all().map_err(|e| e.to_string())?;
                drop(file);
            }
            let oldest = PathBuf::from(format!("{}.4", self.path.display()));
            if oldest.exists() {
                remove_item(&oldest)?;
            }
            for i in (0..4).rev() {
                let from = if i == 0 {
                    self.path.clone()
                } else {
                    PathBuf::from(format!("{}.{i}", self.path.display()))
                };
                if from.exists() {
                    fs::rename(&from, format!("{}.{}", self.path.display(), i + 1))
                        .map_err(|e| e.to_string())?;
                }
            }
            let marker=serde_json::to_vec(&json!({"time":crate::now(),"level":"notice","msg":ROTATION_MESSAGE,"appLogRotation":true})).map_err(|e|e.to_string())?;
            let mut file = open(&self.path, false)?;
            file.write_all(&marker)
                .and_then(|_| file.write_all(b"\n"))
                .map_err(|e| e.to_string())?;
            self.bytes = marker.len() as u64 + 1;
            self.file = Some(file);
        }
        let file = self.file.as_mut().ok_or("工作記錄已關閉。")?;
        file.write_all(line.as_bytes())
            .and_then(|_| {
                if newline {
                    file.write_all(b"\n")
                } else {
                    Ok(())
                }
            })
            .map_err(|e| e.to_string())?;
        self.bytes += additional;
        Ok(())
    }
    pub fn flush(&mut self) -> Result<()> {
        if let Some(file) = self.file.as_ref() {
            file.sync_all().map_err(|e| e.to_string())?;
        }
        Ok(())
    }
}
pub fn export(directory: &Path, id: &str) -> Result<PathBuf> {
    uuid::Uuid::parse_str(id).map_err(|_| "工作編號不正確。")?;
    let base = directory.join(format!("{id}.jsonl"));
    if !base.exists() {
        return Err("這項工作尚未產生記錄。".into());
    }
    if !Path::new(&format!("{}.1", base.display())).exists() {
        return Ok(base);
    }
    let target = directory.join(format!("{id}.export.jsonl"));
    let mut writer = open(&target, false)?;
    for i in (0..5).rev() {
        let segment = if i == 0 {
            base.clone()
        } else {
            PathBuf::from(format!("{}.{i}", base.display()))
        };
        if segment.exists() {
            let mut reader = File::open(segment).map_err(|e| e.to_string())?;
            io::copy(&mut reader, &mut writer).map_err(|e| e.to_string())?;
        }
    }
    writer.sync_all().map_err(|e| e.to_string())?;
    Ok(target)
}
#[cfg(test)]
mod tests {
    use super::*;
    fn root() -> PathBuf {
        let base = std::env::var_os("RBN_TEST_ROOT")
            .map(PathBuf::from)
            .unwrap_or_else(std::env::temp_dir);
        let path = base.join(format!("log-parity-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&path).unwrap();
        path
    }
    #[test]
    fn existing_newlines_and_empty_records_match_swift() {
        let root = root();
        let id = uuid::Uuid::new_v4().to_string();
        let mut log = Log::new(&root, &id).unwrap();
        for line in ["first\n", "second", "", "third\n\n"] {
            log.append(line).unwrap();
        }
        log.flush().unwrap();
        drop(log);
        assert_eq!(
            fs::read(export(&root, &id).unwrap()).unwrap(),
            b"first\nsecond\n\nthird\n\n"
        );
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn rotation_closes_old_segment_writes_notice_and_exports_in_chronological_order() {
        let root = root();
        let id = "7b62d6d2-aee5-46b0-a5c2-43dbabca5799";
        let mut log = Log::new(&root, id).unwrap();
        log.append("first\n").unwrap();
        log.append(&"x".repeat(SEGMENT_BYTES as usize - 8)).unwrap();
        log.append("rotation-trigger").unwrap();
        log.flush().unwrap();
        drop(log);
        let previous = fs::read(root.join(format!("{id}.jsonl.1"))).unwrap();
        assert_eq!(previous.len() as u64, SEGMENT_BYTES - 1);
        assert_eq!(&previous[..6], b"first\n");
        assert_eq!(previous.last(), Some(&b'\n'));
        let current = fs::read(root.join(format!("{id}.jsonl"))).unwrap();
        let split = current.iter().position(|b| *b == b'\n').unwrap();
        let marker: serde_json::Value = serde_json::from_slice(&current[..split]).unwrap();
        assert_eq!(marker["appLogRotation"], true);
        assert_eq!(marker["level"], "notice");
        assert_eq!(marker["msg"], ROTATION_MESSAGE);
        assert_eq!(&current[split + 1..], b"rotation-trigger\n");
        let full = fs::read(export(&root, id).unwrap()).unwrap();
        assert_eq!(full.len(), previous.len() + current.len());
        assert_eq!(&full[..previous.len()], previous.as_slice());
        assert_eq!(&full[previous.len()..], current.as_slice());
        fs::remove_dir_all(root).unwrap();
    }
}
