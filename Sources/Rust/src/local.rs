use crate::{Result, models::TransferRequest};
use std::{collections::BTreeMap, path::Path, sync::atomic::AtomicBool};
use unicode_normalization::UnicodeNormalization;

pub const RAW_ENCODING: &str = "Slash,Ctl,Del,Dot";
pub const LOCAL_ENCODING: &str = "--local-encoding=Slash,Ctl,Del,Dot";
pub const SMB_ENCODING: &str = "--smb-encoding=Slash,Ctl,Del,Dot";
fn raw_platform() -> bool {
    cfg!(any(target_os = "macos", target_os = "linux"))
}
fn apply_flags(mut args: Vec<String>, flags: &[&str]) -> Vec<String> {
    let Some(boundary) = args.iter().position(|s| s == "--") else {
        return args;
    };
    let tail = args.split_off(boundary);
    args.retain(|arg| {
        !flags
            .iter()
            .any(|f| arg.split('=').next() == f.split('=').next())
    });
    args.extend(flags.iter().map(|s| s.to_string()));
    args.extend(tail);
    args
}
pub fn clone_policy_applies(req: &TransferRequest, platform: &str) -> bool {
    platform == "darwin"
        && req.source.remote.is_none()
        && req.destination.remote.is_none()
        && matches!(req.mode.as_str(), "copy" | "sync" | "move")
}
pub fn clone_arguments(args: Vec<String>, req: &TransferRequest, platform: &str) -> Vec<String> {
    if clone_policy_applies(req, platform) {
        apply_flags(args, &["--local-no-clone"])
    } else {
        args
    }
}
pub fn local_arguments(args: Vec<String>, req: &TransferRequest) -> Vec<String> {
    if !raw_platform() || req.source.remote.is_some() || req.destination.remote.is_some() {
        return args;
    }
    let args = clone_arguments(
        args,
        req,
        if cfg!(target_os = "macos") {
            "darwin"
        } else {
            "linux"
        },
    );
    apply_flags(args, &[LOCAL_ENCODING])
}
fn remote_type<'a>(types: &'a BTreeMap<String, String>, name: &str) -> Option<&'a String> {
    types.get(&name.nfc().collect::<String>()).or_else(|| {
        types
            .iter()
            .find(|(key, _)| key.nfc().eq(name.nfc()))
            .map(|(_, value)| value)
    })
}
pub fn smb_arguments(args: Vec<String>, types: &BTreeMap<String, String>) -> Vec<String> {
    smb_arguments_for(args, types, raw_platform())
}
fn smb_arguments_for(
    args: Vec<String>,
    types: &BTreeMap<String, String>,
    raw: bool,
) -> Vec<String> {
    if !raw {
        return args;
    }
    let Some(i) = args.iter().position(|a| a == "--") else {
        return args;
    };
    let bounds = &args[i + 1..];
    if !bounds.iter().any(|s| {
        !s.starts_with('/')
            && s.split_once(':')
                .is_some_and(|(name, _)| remote_type(types, name).is_some_and(|s| s == "smb"))
    }) {
        return args;
    }
    let local = bounds.iter().any(|s| s.starts_with('/'));
    let flags: &[&str] = if local {
        &[SMB_ENCODING, LOCAL_ENCODING]
    } else {
        &[SMB_ENCODING]
    };
    apply_flags(args, flags)
}
pub fn annotate_mounted_locations(locations: &mut [serde_json::Value], darwin: bool) {
    for item in locations {
        if item["group"] == "network" {
            item["connection"] = serde_json::json!(if darwin {
                "mac-mounted"
            } else {
                "system-mounted"
            });
        }
    }
}
#[cfg(test)]
mod smb_platform_tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn windows_commands_retain_existing_encoding_behavior() {
        let original = ["copy", "--", "nas:path", "C:/target"]
            .map(str::to_owned)
            .to_vec();
        let types = BTreeMap::from([("nas".to_owned(), "smb".to_owned())]);
        assert_eq!(smb_arguments_for(original.clone(), &types, false), original);
    }
    #[test]
    fn only_os_mounted_network_locations_receive_mount_label() {
        let original = vec![
            json!({"name":"NAS","group":"network"}),
            json!({"name":"Disk","group":"local"}),
        ];
        let mut mac = original.clone();
        let mut linux = original;
        annotate_mounted_locations(&mut mac, true);
        annotate_mounted_locations(&mut linux, false);
        assert_eq!(mac[0]["connection"], "mac-mounted");
        assert!(mac[1].get("connection").is_none());
        assert_eq!(linux[0]["connection"], "system-mounted");
    }
}
fn mixed_smb(req: &TransferRequest, types: &BTreeMap<String, String>) -> bool {
    let endpoints = [&req.source, &req.destination];
    endpoints.iter().any(|e| e.remote.is_none())
        && endpoints.iter().any(|e| {
            e.remote
                .as_ref()
                .and_then(|n| remote_type(types, n))
                .is_some_and(|k| k == "smb")
        })
}
pub fn listing_name_flags(req: &TransferRequest, types: &BTreeMap<String, String>) -> Vec<String> {
    if raw_platform()
        && ((req.source.remote.is_none() && req.destination.remote.is_none())
            || mixed_smb(req, types))
    {
        vec![LOCAL_ENCODING.into()]
    } else {
        vec![]
    }
}
pub fn smb_filter_rules(
    rules: Vec<String>,
    req: &TransferRequest,
    types: &BTreeMap<String, String>,
) -> Vec<String> {
    if !cfg!(target_os = "macos") || !mixed_smb(req, types) {
        return rules;
    }
    let mut out = vec![];
    for s in rules {
        let c: String = s.nfc().collect();
        let d: String = s.nfd().collect();
        out.push(s.clone());
        if c != s {
            out.push(c.clone());
        }
        if d != s && d != c {
            out.push(d);
        }
    }
    out
}
#[cfg(target_os = "macos")]
pub fn mounted_fs(path: &Path) -> Option<String> {
    use std::{
        ffi::CStr, fs::OpenOptions, io, mem::MaybeUninit, os::fd::AsRawFd,
        os::unix::fs::OpenOptionsExt,
    };
    let mut candidate = path;
    loop {
        let result = (|| -> io::Result<String> {
            let file = OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_EVTONLY | libc::O_CLOEXEC)
                .open(candidate)?;
            let mut info = MaybeUninit::<libc::statfs>::uninit();
            // SAFETY: the descriptor remains open; fstatfs initializes info on success.
            if unsafe { libc::fstatfs(file.as_raw_fd(), info.as_mut_ptr()) } != 0 {
                return Err(io::Error::last_os_error());
            }
            let info = unsafe { info.assume_init() };
            // SAFETY: statfs supplies a NUL-terminated mount type in f_fstypename.
            Ok(unsafe { CStr::from_ptr(info.f_fstypename.as_ptr()) }
                .to_string_lossy()
                .into_owned())
        })();
        match result {
            Ok(kind) => return Some(kind),
            Err(err) if matches!(err.raw_os_error(), Some(libc::ENOENT | libc::ENOTDIR)) => {
                candidate = candidate.parent()?
            }
            Err(_) => return None,
        }
    }
}
pub fn precision_message(request: &TransferRequest) -> Option<String> {
    #[cfg(target_os = "macos")]
    {
        let (duration, systems) = detect_precision(request, mounted_fs)?;
        Some(format!(
            "偵測到 {}，時間容許差已自動設為 {duration}，避免因磁碟時間精度差異而重傳。",
            systems.join(", ")
        ))
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = request;
        None
    }
}
pub fn automatic_modify_window(r: &TransferRequest) -> Option<&'static str> {
    #[cfg(target_os = "macos")]
    {
        detect_precision(r, mounted_fs).map(|(duration, _)| duration)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = r;
        None
    }
}
pub fn detect_precision(
    r: &TransferRequest,
    mut lookup: impl FnMut(&Path) -> Option<String>,
) -> Option<(&'static str, Vec<String>)> {
    if r.options["modifyWindow"] != ""
        || (!matches!(
            r.options["comparison"].as_str(),
            Some("default" | "modtime")
        ) && r.options["updateOnly"] != true)
    {
        return None;
    }
    let mut kinds = BTreeMap::new();
    for endpoint in [&r.source, &r.destination]
        .into_iter()
        .filter(|e| e.remote.is_none())
    {
        let Some(kind) = lookup(Path::new(&endpoint.path)).map(|s| s.to_ascii_lowercase()) else {
            continue;
        };
        let precision = match kind.as_str() {
            "msdos" => (2000, "2s"),
            "hfs" => (1000, "1s"),
            "exfat" => (10, "10ms"),
            _ => continue,
        };
        kinds.insert(kind, precision);
    }
    let (_, duration) = kinds.values().copied().max()?;
    Some((duration, kinds.into_keys().collect()))
}
#[cfg(all(test, any(target_os = "macos", target_os = "linux")))]
fn detect_modify_window(
    r: &TransferRequest,
    lookup: impl FnMut(&Path) -> Option<String>,
) -> Option<&'static str> {
    detect_precision(r, lookup).map(|(duration, _)| duration)
}
pub fn prune_empty_directories(
    source: &Path,
    destination: &Path,
    candidates: &[String],
    maximum: i64,
    dry_run: bool,
    cancelled: &AtomicBool,
    record: &mut dyn FnMut(&str, bool) -> Result<()>,
) -> Result<usize> {
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    {
        pruning::prune(
            source,
            destination,
            candidates,
            maximum,
            dry_run,
            &mut || cancelled.load(std::sync::atomic::Ordering::Acquire),
            record,
        )
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        let _ = (
            source,
            destination,
            candidates,
            maximum,
            dry_run,
            cancelled,
            record,
        );
        Ok(0)
    }
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
mod pruning {
    use super::*;
    use std::{
        collections::HashSet,
        ffi::{CStr, CString},
        fs::{File, OpenOptions},
        io,
        mem::MaybeUninit,
        os::fd::{AsRawFd, FromRawFd, IntoRawFd},
        os::unix::fs::{MetadataExt, OpenOptionsExt},
    };

    fn cname(s: &str) -> Result<CString> {
        CString::new(s).map_err(|_| "空資料夾清理清單含有不安全的路徑。".into())
    }
    const FLAGS: i32 = libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC;
    #[derive(PartialEq, Eq, Clone, Copy)]
    struct Identity {
        dev: u64,
        ino: u64,
    }
    impl Identity {
        fn on_volume_of(self, other: Self) -> bool {
            self.dev == other.dev
        }
    }
    #[cfg(test)]
    #[test]
    fn pruning_volume_boundaries_follow_device_not_inode_or_mount_id() {
        // Synthetic inode metadata only. Equal device IDs are accepted even for distinct mount IDs.
        let root = (Identity { dev: 9, ino: 21 }, 100);
        let same_volume_other_mount = (Identity { dev: 9, ino: 41 }, 200);
        let other_volume = (Identity { dev: 10, ino: 41 }, 300);
        assert_ne!(root.1, same_volume_other_mount.1);
        assert!(same_volume_other_mount.0.on_volume_of(root.0));
        assert!(!other_volume.0.on_volume_of(root.0));
    }
    fn identity(info: &std::fs::Metadata) -> Identity {
        Identity {
            dev: info.dev(),
            ino: info.ino(),
        }
    }
    fn lookup(parent: &File, name: &CStr) -> io::Result<(Identity, bool)> {
        let mut st = MaybeUninit::<libc::stat>::uninit();
        // SAFETY: parent is open and name terminated. fstatat initializes st on success.
        if unsafe {
            libc::fstatat(
                parent.as_raw_fd(),
                name.as_ptr(),
                st.as_mut_ptr(),
                libc::AT_SYMLINK_NOFOLLOW,
            )
        } != 0
        {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: successful fstatat initialized this stat.
        let st = unsafe { st.assume_init() };
        Ok((
            Identity {
                dev: st.st_dev as u64,
                ino: st.st_ino as u64,
            },
            st.st_mode & libc::S_IFMT == libc::S_IFDIR,
        ))
    }
    fn open_child(parent: &File, name: &CStr) -> io::Result<File> {
        // SAFETY: valid descriptor and terminated name; openat never follows a final symlink.
        let fd = unsafe { libc::openat(parent.as_raw_fd(), name.as_ptr(), FLAGS) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: ownership of the freshly opened descriptor is moved to File.
        Ok(unsafe { File::from_raw_fd(fd) })
    }
    struct Stream(*mut libc::DIR);
    impl Drop for Stream {
        fn drop(&mut self) {
            // SAFETY: this stream is uniquely owned.
            unsafe {
                libc::closedir(self.0);
            }
        }
    }
    fn names(fd: &File) -> Result<Vec<String>> {
        // A new open file description has an independent directory cursor.
        let scan = open_child(fd, c".")
            .map_err(|_| "無法完整讀取來源目錄，已停止清理。")?
            .into_raw_fd();
        // SAFETY: fdopendir takes ownership on success; close on failure.
        let raw = unsafe { libc::fdopendir(scan) };
        if raw.is_null() {
            unsafe {
                libc::close(scan);
            }
            return Err("無法完整讀取來源目錄，已停止清理。".into());
        }
        let stream = Stream(raw);
        let mut out = vec![];
        loop {
            // SAFETY: platform errno is a pointer to this thread's errno.
            #[cfg(target_os = "macos")]
            unsafe {
                *libc::__error() = 0;
            }
            #[cfg(target_os = "linux")]
            unsafe {
                *libc::__errno_location() = 0;
            }
            // SAFETY: the stream is open and used exclusively on this thread.
            let entry = unsafe { libc::readdir(stream.0) };
            if entry.is_null() {
                let e = io::Error::last_os_error();
                return if e.raw_os_error() == Some(0) {
                    Ok(out)
                } else {
                    Err("來源目錄讀取不完整，已停止清理。".into())
                };
            }
            // SAFETY: a successful readdir returns a valid record with a terminated name until the next call.
            let name = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) }
                .to_str()
                .map_err(|_| "來源有無法辨識的檔名，已停止清理。")?;
            if !matches!(name, "." | "..") {
                out.push(name.to_owned());
            }
        }
    }
    struct Root<'a> {
        file: File,
        path: &'a Path,
        id: Identity,
    }
    impl<'a> Root<'a> {
        fn open(path: &'a Path) -> Result<Self> {
            let file = OpenOptions::new()
                .read(true)
                .custom_flags(FLAGS)
                .open(path)
                .map_err(|_| "同步位置無法讀取，已停止空資料夾清理。")?;
            let id = identity(
                &file
                    .metadata()
                    .map_err(|_| "目錄無法讀取，已停止空資料夾清理。")?,
            );
            let root = Self { file, path, id };
            root.validate()?;
            Ok(root)
        }
        fn validate(&self) -> Result<()> {
            let m = std::fs::symlink_metadata(self.path)
                .map_err(|_| "同步位置在清理期間改變，已停止清理。")?;
            if !m.is_dir() || identity(&m) != self.id {
                return Err("同步位置在清理期間改變，已停止清理。".into());
            }
            Ok(())
        }
        fn missing(&self, parts: &[&str]) -> Result<bool> {
            let mut chain = Chain::new(self);
            for (index, part) in parts.iter().enumerate() {
                let file = chain.last();
                let name = cname(part)?;
                let normalized: String = part.nfc().collect();
                if !names(file)?.iter().any(|s| s.nfc().eq(normalized.chars())) {
                    if lookup(file, &name).is_err_and(|e| e.raw_os_error() == Some(libc::ENOENT)) {
                        chain.validate()?;
                        return Ok(true);
                    }
                    return Ok(false);
                }
                // A visible but unreadable name protects its entire subtree.
                if index + 1 == parts.len() || chain.push(name).is_err() {
                    return Ok(false);
                }
            }
            Ok(false)
        }
    }
    struct Chain<'a> {
        root: &'a Root<'a>,
        nodes: Vec<(CString, File, Identity)>,
    }
    impl<'a> Chain<'a> {
        fn new(root: &'a Root<'a>) -> Self {
            Self {
                root,
                nodes: vec![],
            }
        }
        fn last(&self) -> &File {
            self.nodes.last().map_or(&self.root.file, |n| &n.1)
        }
        fn push(&mut self, name: CString) -> Result<()> {
            let file =
                open_child(self.last(), &name).map_err(|_| "子目錄無法讀取，保留該目錄。")?;
            let id = identity(
                &file
                    .metadata()
                    .map_err(|_| "目錄無法讀取，已停止空資料夾清理。")?,
            );
            if !id.on_volume_of(self.root.id) {
                return Err("保留其他磁碟上的目錄。".into());
            }
            self.nodes.push((name, file, id));
            Ok(())
        }
        fn validate(&self) -> Result<()> {
            self.root.validate()?;
            let mut parent = &self.root.file;
            for (name, child, id) in &self.nodes {
                let (current, dir) =
                    lookup(parent, name).map_err(|_| "目錄路徑在清理期間改變，已停止清理。")?;
                if !dir || current != *id {
                    return Err("目錄路徑在清理期間改變，已停止清理。".into());
                }
                parent = child;
            }
            Ok(())
        }
    }
    pub(super) fn prune(
        source: &Path,
        destination: &Path,
        candidates: &[String],
        maximum: i64,
        dry_run: bool,
        cancelled: &mut dyn FnMut() -> bool,
        record: &mut dyn FnMut(&str, bool) -> Result<()>,
    ) -> Result<usize> {
        if maximum == 0 {
            return Ok(0);
        }
        if candidates.len() > 250000 {
            return Err("空資料夾清理清單過大，已停止清理。".into());
        }
        let mut unique = HashSet::new();
        let mut paths = Vec::new();
        for path in candidates {
            if !unique.insert(path.as_str()) {
                continue;
            }
            let parts: Vec<_> = path.split('/').collect();
            if parts.len() > 1024
                || parts
                    .iter()
                    .any(|s| matches!(*s, "" | "." | "..") || s.contains('\0'))
            {
                return Err("空資料夾清理清單含有不安全的路徑。".into());
            }
            paths.push((path, parts, path.nfc().collect::<String>()));
        }
        paths.sort_by(|(_, a, a_key), (_, b, b_key)| b.len().cmp(&a.len()).then(a_key.cmp(b_key)));
        let from = Root::open(source)?;
        let to = Root::open(destination)?;
        if from.id == to.id {
            return Err("來源與目的目錄不能相同。".into());
        }
        let mut count = 0usize;
        let mut planned = HashSet::new();
        for (path, parts, _) in paths {
            if cancelled() || (maximum >= 0 && count as i64 >= maximum) {
                break;
            }
            from.validate()?;
            to.validate()?;
            if !from.missing(&parts)? {
                continue;
            }
            let mut chain = Chain::new(&to);
            if parts
                .iter()
                .any(|part| cname(part).and_then(|n| chain.push(n)).is_err())
            {
                continue;
            }
            let entries = names(chain.last())?;
            if !(entries.is_empty()
                || dry_run
                    && entries
                        .iter()
                        .all(|s| planned.contains(&format!("{path}/{s}"))))
            {
                continue;
            }
            if cancelled() {
                break;
            }
            from.validate()?;
            chain.validate()?;
            if !from.missing(&parts)? {
                continue;
            }
            if !dry_run {
                // Revalidate the target after the complete second source listing.
                chain.validate()?;
                let Some((name, _directory, _)) = chain.nodes.pop() else {
                    return Err("不能刪除根目錄。".into());
                };
                if cancelled() {
                    break;
                }
                // SAFETY: only an empty directory may be removed, relative to the pinned parent.
                if unsafe {
                    libc::unlinkat(chain.last().as_raw_fd(), name.as_ptr(), libc::AT_REMOVEDIR)
                } != 0
                {
                    let e = io::Error::last_os_error();
                    if matches!(
                        e.raw_os_error(),
                        Some(libc::ENOENT | libc::ENOTEMPTY | libc::EEXIST | libc::ENOTDIR)
                    ) {
                        continue;
                    }
                    let code = e.raw_os_error().unwrap_or(libc::EIO);
                    // SAFETY: strerror returns a NUL-terminated OS error description.
                    let reason = unsafe { CStr::from_ptr(libc::strerror(code)) }.to_string_lossy();
                    return Err(format!("無法刪除空資料夾：{path}（{reason}）。"));
                }
            }
            count += 1;
            planned.insert(path.clone());
            record(path, dry_run)?;
        }
        Ok(count)
    }
}

#[cfg(all(test, any(target_os = "macos", target_os = "linux")))]
mod tests {
    use super::*;
    use serde_json::json;
    use std::fs;

    #[test]
    fn file_arrival_and_source_replacement_during_prune() {
        for replace_root in [false, true] {
            let root =
                std::env::temp_dir().join(format!("rbn-prune-race-{}", uuid::Uuid::new_v4()));
            let src = root.join("source");
            let dst = root.join("destination");
            fs::create_dir_all(&src).unwrap();
            fs::create_dir_all(dst.join("old")).unwrap();
            let mut checks = 0;
            let result = pruning::prune(
                &src,
                &dst,
                &["old".into()],
                -1,
                false,
                &mut || {
                    checks += 1;
                    if checks == 2 {
                        if replace_root {
                            fs::rename(&src, root.join("original")).unwrap();
                            fs::create_dir(&src).unwrap();
                        } else {
                            fs::write(dst.join("old/arrived"), b"preserve").unwrap();
                        }
                    }
                    false
                },
                &mut |_, _| panic!("entry was unexpectedly removed"),
            );
            if replace_root {
                assert!(result.is_err());
            } else {
                assert_eq!(result, Ok(0));
                assert_eq!(fs::read(dst.join("old/arrived")).unwrap(), b"preserve");
            }
            assert!(dst.join("old").is_dir());
            fs::remove_dir_all(root).unwrap();
        }
    }

    #[test]
    fn volume_time_precision_uses_only_relevant_local_endpoints() {
        let input = json!({"mode":"copy","source":{"path":"/source","remote":null},"destination":{"path":"/dest","remote":null},"options":{},"selection":[],"dryRun":false});
        let mut request = TransferRequest::parse(&input).unwrap();
        for (source, dest, expected) in [
            ("hfs", "exfat", Some("1s")),
            ("apfs", "msdos", Some("2s")),
            ("apfs", "exfat", Some("10ms")),
            ("apfs", "unrecognized", None),
        ] {
            let mut seen = Vec::new();
            assert_eq!(
                detect_modify_window(&request, |p| {
                    seen.push(p.to_owned());
                    Some(if p == Path::new("/source") {
                        source.into()
                    } else {
                        dest.into()
                    })
                }),
                expected
            );
            assert_eq!(seen, [Path::new("/source"), Path::new("/dest")]);
        }
        request.options["modifyWindow"] = json!("5s");
        assert_eq!(
            detect_modify_window(&request, |_| panic!("explicit option was overridden")),
            None
        );
        request.options["modifyWindow"] = json!("");
        request.options["comparison"] = json!("checksum-only");
        assert_eq!(
            detect_modify_window(&request, |_| panic!("unexpected volume query")),
            None
        );
        request.options["updateOnly"] = json!(true);
        request.destination.remote = Some("remote".into());
        assert_eq!(
            detect_modify_window(&request, |p| {
                assert_eq!(p, Path::new("/source"));
                Some("exfat".into())
            }),
            Some("10ms")
        );
    }
}

pub fn preview_arguments(
    request: &TransferRequest,
    types: &BTreeMap<String, String>,
    failed_retries: bool,
) -> Result<(Vec<String>, Vec<String>)> {
    let options = &request.options;
    let complex = !request.selection.is_empty()
        && options["include"].as_array().is_some_and(|v| !v.is_empty());
    let mut args = request.arguments(complex.then_some(Path::new("<精確選取清單>")))?;
    let boundary = args
        .iter()
        .position(|arg| arg == "--")
        .ok_or("傳輸指令缺少端點。")?;
    let mut inserted = Vec::new();
    if !complex {
        let rules = crate::models::selection_filter_rules(request);
        inserted.extend(
            smb_filter_rules(rules, request, types)
                .into_iter()
                .map(|rule| format!("--filter={rule}")),
        );
    }
    inserted.push("--combined=-".into());
    args.splice(boundary..boundary, inserted);
    if failed_retries {
        for arg in &mut args {
            if arg.starts_with("--retries=") {
                *arg = "--retries=1".into();
            }
        }
    }
    let mut warnings = Vec::new();
    if request.mode == "sync" {
        let limit = options["maxDelete"].as_i64().unwrap_or(-1);
        warnings.push(if limit<0 {"同步會刪除目標端多出的檔案（本次不限刪除數量）。".into()}else{format!("同步會刪除目標端多出的檔案（本次最多刪除 {limit} 個；達上限前已刪除的檔案不會復原）。")});
        if !request.selection.is_empty() {
            warnings.push(
                "只將勾選的來源資料夾同步至目標同名子資料夾，未勾選的目標資料夾不會更動。".into(),
            );
        }
    }
    if request.mode == "move" {
        warnings.push("移動會在檔案傳送成功後刪除來源檔案。".into());
    }
    if request.mode == "sync" && options["deleteExcluded"] == true {
        warnings.push(
            "已開啟「刪除目標中符合排除規則的檔案」：目標端符合排除規則的檔案也會被刪除。".into(),
        );
    }
    if request.mode == "sync" && options["deleteMode"] == "before" {
        warnings.push(
            "目標端多出的檔案會在傳輸開始前先刪除；若後續傳輸失敗，已刪除的檔案不會復原。".into(),
        );
    }
    if options["comparison"] == "none" {
        warnings.push("本次會重傳範圍內的所有檔案（即使目標已有相同檔案）。".into());
    }
    #[cfg(target_os = "macos")]
    {
        if let Some(message) = precision_message(request) {
            warnings.push(message);
        }
        if request.source.remote.is_none() && request.destination.remote.is_none() {
            warnings.push("macOS 本機互傳改用一般串流複製，避免繼承來源檔案的鎖定屬性；暫存檔驗證與完成後改名仍照常執行。".into());
        }
    }
    if options["localHashPolicy"] == "none"
        && (request.source.remote.is_none() || request.destination.remote.is_none())
    {
        let message = match options["comparison"].as_str() {
            Some("default") => Some("本機比對僅檢查檔案大小與修改時間，不讀取檔案內容算雜湊。"),
            Some("modtime") => Some("本機比對僅檢查修改時間，不讀取檔案內容算雜湊。"),
            Some("size") => Some("本機比對僅檢查檔案大小，不讀取檔案內容算雜湊。"),
            _ => None,
        };
        if let Some(message) = message {
            warnings.push(message.into());
        }
    } else if options["ignoreChecksum"] == true {
        warnings.push("已略過傳完後的雜湊驗證（傳送前的比對仍依所選比對方式執行）。".into());
    }
    if request.dry_run {
        warnings.push("預演不會實際改動檔案，以下為模擬統計結果。".into());
    }
    if complex {
        warnings.push(if request.mode=="sync" {"只同步勾選資料夾內符合包含規則的檔案（開始前會先掃描兩端檔名；該範圍內目標多出的檔案也會一併刪除）。"}else{"只處理勾選範圍內且符合篩選規則的檔案（開始前會先掃描來源）。"}.into());
    }
    Ok((smb_arguments(args, types), warnings))
}

pub fn display_command(args: &[String]) -> String {
    args.iter()
        .map(|arg| {
            if !arg.is_empty()
                && arg
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"_@%+=:,./-".contains(&b))
            {
                arg.clone()
            } else {
                format!("'{}'", arg.replace('\'', "'\"'\"'"))
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod canonical_smb_tests {
    use super::*;
    #[test]
    fn canonical_remote_lookup_keeps_the_original_target_spelling() {
        let types = BTreeMap::from([("Né".to_owned(), "smb".to_owned())]);
        let original = vec![
            "copy".into(),
            "--".into(),
            "Ne\u{301}:folder".into(),
            "/synthetic/destination".into(),
        ];
        let result = smb_arguments_for(original.clone(), &types, true);
        assert!(result.iter().any(|arg| arg == SMB_ENCODING));
        assert_eq!(&result[result.len() - 2..], &original[original.len() - 2..]);
    }
}
