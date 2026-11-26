//! Windows local endpoints, as handled by the 0.11.0 compatibility host.
use crate::Result;
use crate::models::{Endpoint, Selection, absolute_local};
use serde_json::{Value, json};
use std::{
    cmp::Ordering,
    collections::{HashMap, HashSet},
    mem::size_of,
    ptr,
};
use windows_sys::{
    Win32::{
        Foundation::{
            CloseHandle, ERROR_DIRECTORY, ERROR_FILE_NOT_FOUND, ERROR_NO_MORE_FILES,
            ERROR_PATH_NOT_FOUND, GetLastError, HANDLE, INVALID_HANDLE_VALUE,
        },
        Globalization::{
            CSTR_EQUAL, CSTR_GREATER_THAN, CSTR_LESS_THAN, CompareStringEx, NORM_IGNORECASE,
            NORM_IGNOREWIDTH, SORT_DIGITSASNUMBERS,
        },
        Storage::FileSystem::*,
        System::{
            Com::CoTaskMemFree,
            Diagnostics::Debug::{
                FORMAT_MESSAGE_FROM_SYSTEM, FORMAT_MESSAGE_IGNORE_INSERTS, FormatMessageW,
            },
            WindowsProgramming::{DRIVE_CDROM, DRIVE_REMOTE, DRIVE_REMOVABLE},
        },
        UI::Shell::{
            FOLDERID_Desktop, FOLDERID_Documents, FOLDERID_Downloads, FOLDERID_Music,
            FOLDERID_Pictures, FOLDERID_Profile, FOLDERID_Videos, SHGetKnownFolderPath,
        },
    },
    core::GUID,
};

const NAME_SURROGATE: u32 = 0x2000_0000;
fn extended(path: &str) -> String {
    let mut value = path.replace('/', r"\");
    let bytes = value.as_bytes();
    if bytes.len() >= 4
        && bytes[0] == b'\\'
        && bytes[1].is_ascii_alphabetic()
        && bytes[2] == b':'
        && bytes[3] == b'\\'
    {
        value.remove(0);
    }
    if value.len() == 2 && value.ends_with(':') {
        value.push('\\');
    }
    if value.starts_with(r"\\?\") {
        value
    } else if let Some(rest) = value.strip_prefix(r"\\") {
        format!(r"\\?\UNC\{rest}")
    } else {
        format!(r"\\?\{value}")
    }
}
fn child_path(path: &str, name: &str) -> String {
    if path.ends_with(['\\', '/']) {
        format!("{path}{name}")
    } else {
        format!(r"{path}\{name}")
    }
}
fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}
fn win_error(op: &str, path: &str, code: u32) -> String {
    let mut buf = [0u16; 2048];
    // The system writes at most buf.len() UTF-16 units into caller-owned memory.
    let len = unsafe {
        FormatMessageW(
            FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
            ptr::null(),
            code,
            0,
            buf.as_mut_ptr(),
            buf.len() as u32,
            ptr::null(),
        )
    };
    let message = if len == 0 {
        "Windows filesystem operation failed.".into()
    } else {
        String::from_utf16_lossy(&buf[..len as usize])
            .trim()
            .to_owned()
    };
    format!("{op}: {path} — {message} (Windows {code})")
}
fn last_error(op: &str, path: &str) -> String {
    win_error(op, path, unsafe { GetLastError() })
}
fn attributes(path: &str, allow_missing: bool) -> Result<Option<u32>> {
    let spelling = wide(&extended(path));
    let attributes = unsafe { GetFileAttributesW(spelling.as_ptr()) };
    if attributes != INVALID_FILE_ATTRIBUTES {
        return Ok(Some(attributes));
    }
    let code = unsafe { GetLastError() };
    if allow_missing && matches!(code, ERROR_FILE_NOT_FOUND | ERROR_PATH_NOT_FOUND) {
        Ok(None)
    } else {
        Err(win_error("Read attributes", path, code))
    }
}
fn is_directory(attributes: u32) -> bool {
    attributes & FILE_ATTRIBUTE_DIRECTORY != 0
}
fn is_link(attributes: u32, tag: u32) -> bool {
    attributes & FILE_ATTRIBUTE_REPARSE_POINT != 0 && tag & NAME_SURROGATE != 0
}
fn require_directory(path: &str) -> Result<()> {
    if attributes(path, false)?.is_some_and(is_directory) {
        Ok(())
    } else {
        Err(win_error("Open directory", path, ERROR_DIRECTORY))
    }
}
#[derive(Clone)]
struct Entry {
    name: String,
    directory: bool,
    link: bool,
    bytes: u64,
    modified: u64,
}
impl Entry {
    fn value(&self) -> Result<Value> {
        let size = if self.directory {
            -1
        } else {
            i64::try_from(self.bytes).map_err(|_| "檔案大小超出支援範圍。")?
        };
        let seconds = self.modified as f64 / 10_000_000.0 - 11_644_473_600.0;
        let modified = chrono::DateTime::from_timestamp(seconds.floor() as i64, 0)
            .map(|v| v.to_rfc3339_opts(chrono::SecondsFormat::Secs, true))
            .unwrap_or_default();
        Ok(
            json!({"name":self.name,"path":self.name,"size":size,"modified":modified,
                  "isDir":self.directory,"isLink":self.link}),
        )
    }
}
struct FindHandle(HANDLE);
impl Drop for FindHandle {
    fn drop(&mut self) {
        unsafe {
            FindClose(self.0);
        }
    }
}
struct OwnedHandle(HANDLE);
impl Drop for OwnedHandle {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.0);
        }
    }
}

fn contents(path: &str) -> Result<Vec<Entry>> {
    require_directory(path)?;
    let pattern = wide(&child_path(&extended(path), "*"));
    let mut data = WIN32_FIND_DATAW::default();
    let raw = unsafe { FindFirstFileW(pattern.as_ptr(), &mut data) };
    if raw == INVALID_HANDLE_VALUE {
        let code = unsafe { GetLastError() };
        if code == ERROR_FILE_NOT_FOUND {
            require_directory(path)?;
            return Ok(vec![]);
        }
        return Err(win_error("List directory", path, code));
    }
    let handle = FindHandle(raw);
    let mut entries = Vec::new();
    loop {
        let len = data
            .cFileName
            .iter()
            .position(|&u| u == 0)
            .unwrap_or(data.cFileName.len());
        let name = String::from_utf16_lossy(&data.cFileName[..len]);
        if name != "." && name != ".." {
            if entries.len() >= 250_000 {
                return Err("目錄超過 250,000 個項目，請選擇較小的資料夾。".into());
            }
            entries.push(Entry {
                name,
                directory: is_directory(data.dwFileAttributes),
                link: is_link(data.dwFileAttributes, data.dwReserved0),
                bytes: (u64::from(data.nFileSizeHigh) << 32) | u64::from(data.nFileSizeLow),
                modified: (u64::from(data.ftLastWriteTime.dwHighDateTime) << 32)
                    | u64::from(data.ftLastWriteTime.dwLowDateTime),
            });
        }
        if unsafe { FindNextFileW(handle.0, &mut data) } == 0 {
            let code = unsafe { GetLastError() };
            if code == ERROR_NO_MORE_FILES {
                return Ok(entries);
            }
            return Err(win_error("List directory", path, code));
        }
    }
}
fn locale_cmp(a: &str, b: &str) -> Ordering {
    let (x, y) = (wide(a), wide(b));
    let compare = |flags| unsafe {
        CompareStringEx(
            ptr::null(),
            flags,
            x.as_ptr(),
            -1,
            y.as_ptr(),
            -1,
            ptr::null(),
            ptr::null(),
            0,
        )
    };
    match compare(SORT_DIGITSASNUMBERS | NORM_IGNORECASE | NORM_IGNOREWIDTH) {
        CSTR_LESS_THAN => Ordering::Less,
        CSTR_GREATER_THAN => Ordering::Greater,
        CSTR_EQUAL => match compare(0) {
            CSTR_LESS_THAN => Ordering::Less,
            CSTR_GREATER_THAN => Ordering::Greater,
            _ => x.cmp(&y),
        },
        _ => x.cmp(&y),
    }
}
pub fn list(endpoint: &Endpoint) -> Result<Vec<Value>> {
    let mut entries = contents(&endpoint.path)?;
    entries.sort_by(|a, b| {
        b.directory
            .cmp(&a.directory)
            .then_with(|| locale_cmp(&a.name, &b.name))
    });
    entries.iter().map(Entry::value).collect()
}
pub fn size(endpoint: &Endpoint) -> Result<Value> {
    let mut paths = vec![endpoint.path.clone()];
    let mut count = 0i64;
    let mut bytes = 0i64;
    const LARGE: &str = "資料夾容量超出支援範圍。";
    while let Some(path) = paths.pop() {
        for entry in contents(&path)? {
            if entry.link {
                continue;
            }
            if entry.directory {
                paths.push(child_path(&path, &entry.name));
            } else {
                bytes = bytes
                    .checked_add(i64::try_from(entry.bytes).map_err(|_| LARGE)?)
                    .ok_or(LARGE)?;
                count = count.checked_add(1).ok_or(LARGE)?;
            }
        }
    }
    Ok(json!({"count":count,"bytes":bytes}))
}
pub fn mkdir(endpoint: &Endpoint, name: &str) -> Result<()> {
    let child = endpoint.child(name)?;
    require_directory(&endpoint.path)?;
    if attributes(&child.path, true)?.is_some() {
        return Err("同名項目已存在。".into());
    }
    let path = wide(&extended(&child.path));
    if unsafe { CreateDirectoryW(path.as_ptr(), ptr::null()) } == 0 {
        return Err(last_error("Create directory", &child.path));
    }
    Ok(())
}

fn selected_entries(endpoint: &Endpoint, selection: &[Selection]) -> Result<Vec<(String, Entry)>> {
    let paths: Vec<_> = selection
        .iter()
        .map(|s| endpoint.child(&s.name).map(|e| e.path))
        .collect::<Result<_>>()?;
    // Rust String equality preserves literal UTF-16 distinctions of all Swift-decoded names.
    let entries: HashMap<_, _> = contents(&endpoint.path)?
        .into_iter()
        .map(|e| (e.name.clone(), e))
        .collect();
    selection
        .iter()
        .zip(paths)
        .map(|(item, path)| {
            let entry = entries
                .get(&item.name)
                .filter(|e| e.directory == item.is_dir)
                .ok_or_else(|| format!("「{}」已不存在或類型已改變，請重新整理。", item.name))?;
            Ok((path, entry.clone()))
        })
        .collect()
}
pub fn rename(endpoint: &Endpoint, name: &str, new_name: &str, is_dir: bool) -> Result<()> {
    let target = endpoint.child(new_name)?;
    let selected = selected_entries(
        endpoint,
        &[Selection {
            name: name.into(),
            is_dir,
        }],
    )?;
    let source = &selected[0].0;
    if name == new_name {
        return Ok(());
    }
    if attributes(&target.path, true)?.is_some() {
        return Err("新名稱已存在，請選擇其他名稱。".into());
    }
    if attributes(source, false)?.is_none_or(|a| is_directory(a) != is_dir) {
        return Err("原項目已不存在或類型已改變。".into());
    }
    let from = wide(&extended(source));
    let to = wide(&extended(&target.path));
    if unsafe { MoveFileExW(from.as_ptr(), to.as_ptr(), 0) } == 0 {
        return Err(last_error("Rename", source));
    }
    Ok(())
}
enum Removal {
    Visit(String, bool),
    Finish(String, OwnedHandle),
}
pub fn remove(endpoint: &Endpoint, selection: &[Selection]) -> Result<()> {
    if selection.is_empty() {
        return Err("請先選取要刪除的項目。".into());
    }
    for (path, entry) in selected_entries(endpoint, selection)? {
        let mut pending = vec![Removal::Visit(path, entry.directory)];
        while let Some(step) = pending.pop() {
            match step {
                Removal::Visit(path, expected) => {
                    let access = DELETE
                        | FILE_READ_ATTRIBUTES
                        | if expected { FILE_LIST_DIRECTORY } else { 0 };
                    let spelled = wide(&extended(&path));
                    let raw = unsafe {
                        CreateFileW(
                            spelled.as_ptr(),
                            access,
                            FILE_SHARE_READ,
                            ptr::null(),
                            OPEN_EXISTING,
                            FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS,
                            ptr::null_mut(),
                        )
                    };
                    if raw == INVALID_HANDLE_VALUE {
                        return Err(last_error("Open for deletion", &path));
                    }
                    let handle = OwnedHandle(raw);
                    let mut info = BY_HANDLE_FILE_INFORMATION::default();
                    if unsafe { GetFileInformationByHandle(raw, &mut info) } == 0 {
                        return Err(last_error("Read deletion target", &path));
                    }
                    if is_directory(info.dwFileAttributes) != expected {
                        return Err("原項目已不存在或類型已改變。".into());
                    }
                    let mut link = false;
                    if info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
                        let mut tag = FILE_ATTRIBUTE_TAG_INFO::default();
                        if unsafe {
                            GetFileInformationByHandleEx(
                                raw,
                                FileAttributeTagInfo,
                                (&mut tag as *mut FILE_ATTRIBUTE_TAG_INFO).cast(),
                                size_of::<FILE_ATTRIBUTE_TAG_INFO>() as u32,
                            )
                        } == 0
                        {
                            return Err(last_error("Read reparse point", &path));
                        }
                        link = is_link(info.dwFileAttributes, tag.ReparseTag);
                    }
                    // The parent handle remains alive without delete/write sharing until every child is done.
                    pending.push(Removal::Finish(path.clone(), handle));
                    if expected && !link {
                        for child in contents(&path)?.into_iter().rev() {
                            pending.push(Removal::Visit(
                                child_path(&path, &child.name),
                                child.directory,
                            ));
                        }
                    }
                }
                Removal::Finish(path, handle) => {
                    let disposition = FILE_DISPOSITION_INFO { DeleteFile: true };
                    if unsafe {
                        SetFileInformationByHandle(
                            handle.0,
                            FileDispositionInfo,
                            (&disposition as *const FILE_DISPOSITION_INFO).cast(),
                            size_of::<FILE_DISPOSITION_INFO>() as u32,
                        )
                    } == 0
                    {
                        return Err(last_error("Delete", &path));
                    }
                }
            }
        }
    }
    Ok(())
}

fn known_folder(id: &GUID) -> Option<String> {
    let mut value = ptr::null_mut();
    let result = unsafe { SHGetKnownFolderPath(id, 0, ptr::null_mut(), &mut value) };
    if result < 0 || value.is_null() {
        return None;
    }
    // SHGetKnownFolderPath returns a NUL-terminated UTF-16 string allocated with CoTaskMemAlloc.
    let path = unsafe {
        let mut len = 0;
        while *value.add(len) != 0 {
            len += 1;
        }
        let path = String::from_utf16_lossy(std::slice::from_raw_parts(value, len));
        CoTaskMemFree(value.cast());
        path
    };
    Some(path.replace('\\', "/"))
}
pub fn bootstrap(mut original: Value) -> Value {
    let mut locations = Vec::new();
    let mut seen = HashSet::new();
    let mut add = |path: String,
                   id: String,
                   kind: &str,
                   name: Option<String>,
                   group: &str,
                   removable: Option<bool>,
                   verify: bool| {
        if !absolute_local(&path)
            || (verify
                && !attributes(&path, false)
                    .ok()
                    .flatten()
                    .is_some_and(is_directory))
            || !seen.insert(path.replace('\\', "/").to_lowercase())
        {
            return;
        }
        let label = name.unwrap_or_else(|| {
            path.split('/')
                .rfind(|s| !s.is_empty())
                .unwrap_or(&path)
                .to_owned()
        });
        let mut item = json!({"id":id,"kind":kind,"name":label,"path":path,"group":group});
        if let Some(removable) = removable {
            item["isRemovable"] = json!(removable);
        }
        locations.push(item);
    };
    if let Some(home) =
        known_folder(&FOLDERID_Profile).or_else(|| original["home"].as_str().map(str::to_owned))
    {
        original["home"] = json!(home);
        add(home, "home".into(), "home", None, "local", None, true);
    }
    for (kind, id) in [
        ("desktop", FOLDERID_Desktop),
        ("documents", FOLDERID_Documents),
        ("downloads", FOLDERID_Downloads),
        ("pictures", FOLDERID_Pictures),
        ("music", FOLDERID_Music),
        ("movies", FOLDERID_Videos),
    ] {
        if let Some(path) = known_folder(&id) {
            add(path, kind.into(), kind, None, "local", None, true);
        }
    }
    let drives = unsafe { GetLogicalDrives() };
    for i in 0..26 {
        if drives & (1 << i) == 0 {
            continue;
        }
        let letter = char::from(b'A' + i as u8);
        let root = format!("{letter}:/");
        let spelling = wide(&format!(r"{letter}:\"));
        let ty = unsafe { GetDriveTypeW(spelling.as_ptr()) };
        add(
            root.clone(),
            format!("volume:{root}"),
            "volume",
            Some(format!("{letter}:")),
            if ty == DRIVE_REMOTE {
                "network"
            } else {
                "local"
            },
            Some(matches!(ty, DRIVE_REMOVABLE | DRIVE_CDROM)),
            false,
        );
    }
    original["localLocations"] = json!(locations);
    original
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn drive_and_unc_spellings_and_link_classification() {
        assert_eq!(extended("/C:/x"), r"\\?\C:\x");
        assert_eq!(extended("C:"), r"\\?\C:\");
        assert_eq!(
            extended("//server/share/name"),
            r"\\?\UNC\server\share\name"
        );
        assert_eq!(extended(r"\\?\C:\x"), r"\\?\C:\x");
        assert!(is_link(FILE_ATTRIBUTE_REPARSE_POINT, 0xA0000003));
        assert!(!is_link(FILE_ATTRIBUTE_REPARSE_POINT, 0x9000001A));
        assert!(!is_link(FILE_ATTRIBUTE_DIRECTORY, 0xA0000003));
    }
    #[test]
    fn entry_size_uses_full_unsigned_snapshot() {
        let e = Entry {
            name: "資料".into(),
            directory: false,
            link: false,
            bytes: 4_294_967_297,
            modified: 116_444_736_000_000_000,
        };
        let v = e.value().unwrap();
        assert_eq!(v["size"], 4_294_967_297i64);
        assert_eq!(v["modified"], "1970-01-01T00:00:00Z");
        assert!(
            Entry {
                bytes: u64::MAX,
                ..e.clone()
            }
            .value()
            .is_err()
        );
        assert_eq!(
            Entry {
                directory: true,
                bytes: u64::MAX,
                ..e
            }
            .value()
            .unwrap()["size"],
            -1
        );
    }
}
