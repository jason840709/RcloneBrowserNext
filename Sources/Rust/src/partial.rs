//! Report-bound recovery of verified local partial files on macOS.
//! The host obtains confirmation before apply and separate confirmation before cleanup.
#[cfg(target_os = "macos")]
pub use mac::{apply, cleanup, preview};

#[cfg(not(target_os = "macos"))]
mod unsupported {
    use crate::Result;
    use serde_json::Value;
    use std::path::Path;
    pub fn preview(_report: &Path, _plan: &Path) -> Result<Value> {
        Err("暫存檔修復只支援 macOS。".into())
    }
    pub fn apply(_plan: &Path, _receipt: &Path) -> Result<Value> {
        Err("暫存檔修復只支援 macOS。".into())
    }
    pub fn cleanup(_receipt: &Path, _result: &Path) -> Result<Value> {
        Err("暫存檔修復只支援 macOS。".into())
    }
}
#[cfg(not(target_os = "macos"))]
pub use unsupported::{apply, cleanup, preview};

#[cfg(target_os = "macos")]
mod mac {
    use crate::Result;
    use serde::{Deserialize, Serialize};
    use serde_json::{Value, json};
    use sha2::{Digest, Sha256};
    use std::{
        collections::{HashMap, HashSet},
        ffi::{CStr, CString},
        fs::File,
        io::{self, Seek, SeekFrom, Write},
        mem::MaybeUninit,
        os::{
            fd::{AsRawFd, FromRawFd},
            unix::fs::FileExt,
        },
        path::{Path, PathBuf},
        sync::Arc,
    };
    use unicode_normalization::UnicodeNormalization;
    const MIB: usize = 1024 * 1024;
    const DIR: i32 = libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC;
    const READ: i32 = libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC;
    const CREATE: i32 =
        libc::O_RDWR | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC;
    const PLAN: &str = "local-partial-recovery-plan";
    const RECEIPT: &str = "local-partial-recovery-receipt";

    fn io_error(e: io::Error) -> String {
        if let Some(code) = e.raw_os_error() {
            // SAFETY: strerror returns the NUL-terminated system description for this errno.
            let reason = unsafe { CStr::from_ptr(libc::strerror(code)) }.to_string_lossy();
            format!("errno {code}（{reason}）")
        } else {
            e.to_string()
        }
    }
    fn failure(op: &str, e: io::Error) -> String {
        format!("{op}：{}", io_error(e))
    }
    fn set_error_code(v: &mut Value, message: &str) {
        if let Some(code) = message
            .rsplit_once("errno ")
            .and_then(|(_, s)| s.split_once('（'))
            .and_then(|(s, _)| s.parse::<i32>().ok())
        {
            v["errorCode"] = json!(code);
        }
    }
    fn errno() -> String {
        io_error(io::Error::last_os_error())
    }
    fn str_key<'a>(v: &'a Value, k: &str) -> Result<&'a str> {
        v[k].as_str().ok_or_else(|| format!("缺少必要欄位 {k}。"))
    }
    fn array<'a>(v: &'a Value, k: &str) -> Result<&'a [Value]> {
        v[k].as_array()
            .map(Vec::as_slice)
            .ok_or_else(|| format!("{k} 格式不正確。"))
    }
    fn digest(data: &[u8]) -> String {
        format!("{:x}", Sha256::digest(data))
    }
    fn normalized(s: &str) -> String {
        s.nfc().collect()
    }
    fn overlap(a: &str, b: &str) -> bool {
        let a = normalized(a).to_lowercase();
        let b = normalized(b).to_lowercase();
        a == b || a.starts_with(&(b.clone() + "/")) || b.starts_with(&(a + "/"))
    }
    fn rel(s: &str) -> Result<Vec<&str>> {
        let p: Vec<_> = s.split('/').collect();
        if s.len() > 16384
            || s.bytes().any(|b| b < 32 || b == 127)
            || p.iter()
                .any(|p| p.len() > 255 || matches!(*p, "" | "." | ".."))
        {
            return Err("路徑含有空名稱、控制字元、過長名稱或目錄穿越。".into());
        }
        Ok(p)
    }
    fn absolute(s: &str) -> Result<Vec<&str>> {
        if s == "/" {
            return Ok(vec![]);
        }
        rel(s.strip_prefix('/').ok_or("必須使用本機絕對路徑。")?)
    }
    fn path_text(p: &Path) -> Result<&str> {
        let s = p.to_str().ok_or("路徑編碼無法辨識。")?;
        if absolute(s)?.is_empty() {
            return Err("請指定具體的檔案或資料夾，不可使用磁碟根目錄。".into());
        }
        Ok(s)
    }
    fn c(s: &str) -> Result<CString> {
        CString::new(s).map_err(|_| "路徑含有控制字元。".into())
    }
    fn openat(fd: i32, name: &CStr, flags: i32) -> io::Result<File> {
        // SAFETY: the descriptor is held by our chain, name is terminated, and the
        // variadic creation mode is supplied even when O_CREAT is absent.
        let f = unsafe { libc::openat(fd, name.as_ptr(), flags, 0o600 as libc::c_int) };
        if f < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: ownership of the returned descriptor is transferred exactly once.
        Ok(unsafe { File::from_raw_fd(f) })
    }
    fn stat_fd(f: &File) -> Result<libc::stat> {
        let mut st = MaybeUninit::uninit();
        // SAFETY: fstat initializes this stat when its return value is zero.
        if unsafe { libc::fstat(f.as_raw_fd(), st.as_mut_ptr()) } != 0 {
            return Err(errno());
        }
        Ok(unsafe { st.assume_init() })
    }
    fn stat_at(f: &File, n: &CStr) -> io::Result<libc::stat> {
        let mut st = MaybeUninit::uninit();
        // SAFETY: fstatat writes a stat for the held directory and terminated name.
        if unsafe {
            libc::fstatat(
                f.as_raw_fd(),
                n.as_ptr(),
                st.as_mut_ptr(),
                libc::AT_SYMLINK_NOFOLLOW,
            )
        } != 0
        {
            return Err(io::Error::last_os_error());
        }
        Ok(unsafe { st.assume_init() })
    }
    fn fstype(f: &File, operation: &str) -> Result<String> {
        let mut st = MaybeUninit::uninit();
        // SAFETY: fstatfs initializes all returned fields including f_fstypename.
        if unsafe { libc::fstatfs(f.as_raw_fd(), st.as_mut_ptr()) } != 0 {
            return Err(failure(operation, io::Error::last_os_error()));
        }
        let st = unsafe { st.assume_init() };
        Ok(unsafe { CStr::from_ptr(st.f_fstypename.as_ptr()) }
            .to_string_lossy()
            .into_owned())
    }
    #[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
    struct Node {
        device: i64,
        inode: u64,
    }
    fn node(st: &libc::stat) -> Node {
        Node {
            device: st.st_dev.into(),
            inode: st.st_ino,
        }
    }
    #[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Snapshot {
        node: Node,
        size: i64,
        mode: u32,
        links: u64,
        user: u32,
        group: u32,
        flags: u32,
        modified_seconds: i64,
        modified_nanoseconds: i64,
        changed_seconds: i64,
        changed_nanoseconds: i64,
    }
    impl Snapshot {
        fn new(st: &libc::stat) -> Self {
            Self {
                node: node(st),
                size: st.st_size,
                mode: st.st_mode.into(),
                links: st.st_nlink.into(),
                user: st.st_uid,
                group: st.st_gid,
                flags: st.st_flags,
                modified_seconds: st.st_mtime,
                modified_nanoseconds: st.st_mtime_nsec,
                changed_seconds: st.st_ctime,
                changed_nanoseconds: st.st_ctime_nsec,
            }
        }
        fn same_content(self, other: Self) -> bool {
            Self {
                flags: other.flags,
                changed_seconds: other.changed_seconds,
                changed_nanoseconds: other.changed_nanoseconds,
                ..self
            } == other
        }
    }
    fn decode<T: serde::de::DeserializeOwned>(v: &Value) -> Result<T> {
        serde_json::from_value(v.clone()).map_err(|e| e.to_string())
    }
    #[derive(Clone)]
    struct Link {
        name: CString,
        file: Arc<File>,
        id: Node,
    }
    #[derive(Clone)]
    struct Chain {
        root: Arc<File>,
        nodes: Vec<Link>,
    }
    impl Chain {
        fn absolute(path: &str) -> Result<Self> {
            let root = Arc::new(File::open("/").map_err(|e| failure("無法開啟根目錄", e))?);
            Self {
                root,
                nodes: vec![],
            }
            .append(&absolute(path)?)
        }
        fn last(&self) -> &File {
            self.nodes
                .last()
                .map_or(self.root.as_ref(), |n| n.file.as_ref())
        }
        fn id(&self) -> Result<Node> {
            Ok(node(&stat_fd(self.last())?))
        }
        fn contains(&self, id: Node) -> Result<bool> {
            Ok(node(&stat_fd(&self.root)?) == id || self.nodes.iter().any(|n| n.id == id))
        }
        fn append(&self, parts: &[&str]) -> Result<Self> {
            let mut chain = self.clone();
            for p in parts {
                let name = c(p)?;
                let f = openat(chain.last().as_raw_fd(), &name, DIR)
                    .map_err(|e| failure(&format!("目錄不存在、無法讀取或含有符號連結：{p}"), e))?;
                let id = node(&stat_fd(&f)?);
                chain.nodes.push(Link {
                    name,
                    file: Arc::new(f),
                    id,
                });
            }
            chain.validate()?;
            Ok(chain)
        }
        fn validate(&self) -> Result<()> {
            let mut parent = self.root.as_ref();
            for link in &self.nodes {
                let st = stat_at(parent, &link.name)
                    .map_err(|_| "目錄路徑被替換或改成符號連結，已停止處理。")?;
                if st.st_mode & libc::S_IFMT != libc::S_IFDIR
                    || node(&st) != link.id
                    || node(&stat_fd(&link.file)?) != link.id
                {
                    return Err("目錄路徑被替換或改成符號連結，已停止處理。".into());
                }
                parent = link.file.as_ref();
            }
            Ok(())
        }
        fn exists(&self, n: &str) -> Result<bool> {
            self.validate()?;
            match stat_at(self.last(), &c(n)?) {
                Ok(_) => Ok(true),
                Err(e) if e.raw_os_error() == Some(libc::ENOENT) => Ok(false),
                Err(e) => Err(failure("無法確認正式檔名是否已存在", e)),
            }
        }
    }
    struct Bound {
        parent: Chain,
        leaf: CString,
        file: File,
    }
    impl Bound {
        fn open(parent: Chain, leaf: &str, flags: i32) -> Result<Self> {
            parent.validate()?;
            let name = c(leaf)?;
            let file = openat(parent.last().as_raw_fd(), &name, flags).map_err(|e| {
                if flags & libc::O_CREAT != 0 {
                    failure("輸出檔已存在或無法建立；請選擇新檔名", e)
                } else {
                    failure(&format!("檔案不存在、無法讀取或是符號連結：{leaf}"), e)
                }
            })?;
            let leaf = name;
            let b = Self { parent, leaf, file };
            b.snapshot()?;
            Ok(b)
        }
        fn snapshot(&self) -> Result<Snapshot> {
            self.parent.validate()?;
            let leaf = self.leaf.to_string_lossy();
            let held =
                stat_fd(&self.file).map_err(|_| format!("只接受仍存在的一般檔案：{leaf}"))?;
            if held.st_mode & libc::S_IFMT != libc::S_IFREG
                || held.st_nlink == 0
                || held.st_size < 0
            {
                return Err(format!("只接受仍存在的一般檔案：{leaf}"));
            }
            let st = Snapshot::new(&held);
            let changed = || format!("檔案在檢查期間被替換或改變：{leaf}");
            let named = stat_at(self.parent.last(), &self.leaf).map_err(|_| changed())?;
            if st != Snapshot::new(&named) {
                return Err(changed());
            }
            Ok(st)
        }
        fn check(&self, expected: Snapshot) -> Result<()> {
            if self.snapshot()? != expected {
                return Err(format!(
                    "檔案已與預覽時不同，請重新預覽：{}",
                    self.leaf.to_string_lossy()
                ));
            }
            Ok(())
        }
        fn stable_hash(&self) -> Result<(String, Snapshot)> {
            let state = self.snapshot()?;
            let mut hasher = Sha256::new();
            let mut buf = vec![0; MIB];
            let mut offset = 0;
            while offset < state.size as u64 {
                let count = read_chunk(&self.file, &mut buf, offset, state.size as u64 - offset)?;
                hasher.update(&buf[..count]);
                offset += count as u64;
            }
            self.check(state)?;
            Ok((format!("{:x}", hasher.finalize()), state))
        }
        fn ensure_empty_id(&self, s: Snapshot) -> Result<()> {
            if s.size == 0
                && matches!(
                    fstype(&self.file, "無法確認空檔案所在磁碟的檔案識別能力")?.as_str(),
                    "msdos" | "exfat"
                )
            {
                return Err("此磁碟格式的空檔案無法確保唯一識別碼，不自動改名。".into());
            }
            Ok(())
        }
    }
    fn read_chunk(f: &File, buf: &mut [u8], offset: u64, left: u64) -> Result<usize> {
        let want = buf.len().min(left as usize);
        loop {
            match f.read_at(&mut buf[..want], offset) {
                Ok(0) => return Err("讀取檔案時提早結束。".into()),
                Ok(n) => return Ok(n),
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) => return Err(io_error(e)),
            }
        }
    }
    fn split_leaf<'a, 'b>(parts: &'a [&'b str]) -> Result<(&'b str, &'a [&'b str])> {
        parts
            .split_last()
            .map(|(s, p)| (*s, p))
            .ok_or_else(|| "需要完整檔案名稱。".into())
    }
    fn read_document(path: &Path, limit: usize) -> Result<Vec<u8>> {
        let p = absolute(path_text(path)?)?;
        let (leaf, parent) = split_leaf(&p)?;
        let chain = Chain::absolute("/")?.append(parent)?;
        let file = Bound::open(chain, leaf, READ)?;
        let st = file.snapshot()?;
        if st.size <= 0 || st.size as u64 > limit as u64 {
            return Err("報告或計畫檔案大小異常。".into());
        }
        let mut bytes = vec![0; st.size as usize];
        file.file
            .read_exact_at(&mut bytes, 0)
            .map_err(|e| failure("無法讀取報告或計畫檔案", e))?;
        file.check(st)?;
        Ok(bytes)
    }
    struct Output {
        bound: Bound,
        id: Node,
        append: bool,
    }
    impl Output {
        fn open(path: &Path, r: &Report, roots: &Roots, append: bool) -> Result<Self> {
            let name = path_text(path)?;
            if overlap(name, &r.source) || overlap(name, &r.destination) || name == r.path {
                return Err("修復計畫與收據必須存放在來源與目標目錄之外。".into());
            }
            let p = absolute(name)?;
            let (leaf, parent) = split_leaf(&p)?;
            let parent = Chain::absolute("/")?.append(parent)?;
            if parent.contains(roots.s.id()?)? || parent.contains(roots.d.id()?)? {
                return Err("輸出位置不可位於來源或目標目錄內。".into());
            }
            let bound = Bound::open(
                parent,
                leaf,
                CREATE | if append { libc::O_APPEND } else { 0 },
            )?;
            let state = bound.snapshot()?;
            if state.links != 1 {
                return Err("無法確認輸出檔案身分。".into());
            }
            Ok(Self {
                bound,
                id: state.node,
                append,
            })
        }
        fn persist(&mut self, v: &Value) -> Result<()> {
            let st = self.bound.snapshot()?;
            if st.node != self.id || st.links != 1 {
                return Err("輸出檔被替換或連結，已停止處理。".into());
            }
            let f = &mut self.bound.file;
            let mut bytes = if self.append {
                serde_json::to_vec(v)
            } else {
                serde_json::to_vec_pretty(v)
            }
            .map_err(|e| e.to_string())?;
            bytes.push(b'\n');
            if !self.append {
                f.seek(SeekFrom::Start(0))
                    .map_err(|e| failure("無法更新修復收據", e))?;
                f.set_len(0).map_err(|e| failure("無法更新修復收據", e))?;
            }
            f.write_all(&bytes)
                .map_err(|e| failure("修復收據寫入失敗", e))?;
            f.sync_all()
                .map_err(|e| failure("修復收據無法同步至磁碟", e))
        }
    }
    #[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
    #[serde(rename_all = "camelCase")]
    struct Candidate {
        id: String,
        relative_path: String,
        temporary_relative_path: String,
        rename_sequence: i64,
    }
    struct Report {
        path: String,
        hash: String,
        source: String,
        destination: String,
        candidates: Vec<Candidate>,
        excluded: Vec<Value>,
    }
    struct Roots {
        s: Chain,
        d: Chain,
    }
    impl Roots {
        fn new(r: &Report) -> Result<Self> {
            let s = Chain::absolute(&r.source)?;
            let d = Chain::absolute(&r.destination)?;
            if s.contains(d.id()?)? || d.contains(s.id()?)? {
                return Err("來源與目標指向同一個實際目錄或互相重疊。".into());
            }
            Ok(Self { s, d })
        }
        fn parents<'a>(&self, c: &'a Candidate) -> Result<(Chain, &'a str, Chain, &'a str)> {
            let orig = rel(&c.relative_path)?;
            let tmp = rel(&c.temporary_relative_path)?;
            let (leaf, src) = split_leaf(&orig)?;
            let (partial, dest) = split_leaf(&tmp)?;
            Ok((self.s.append(src)?, leaf, self.d.append(dest)?, partial))
        }
    }

    fn parse_report(path: &Path) -> Result<Report> {
        let bytes = read_document(path, 64 * MIB)?;
        let raw = std::str::from_utf8(&bytes).map_err(|_| "報告不是有效的 UTF-8 JSONL 檔案。")?;
        let mut rows = vec![];
        let mut seq = 0i64;
        for line in raw.strip_suffix('\n').unwrap_or(raw).split('\n') {
            if line.len() > 256 * 1024 || rows.len() >= 200000 {
                return Err("報告筆數或紀錄長度超過單次可處理上限。".into());
            }
            let row: Value = serde_json::from_str(line).map_err(|e| e.to_string())?;
            let current = row["sequence"]
                .as_i64()
                .filter(|n| *n > seq)
                .ok_or("報告含有無效序號。")?;
            seq = current;
            rows.push(row);
        }
        let first = rows.first().ok_or("報告缺少完整設定。")?;
        let cfg = &first["configuration"];
        let req = &cfg["request"];
        if first["action"] != "configuration"
            || first["evidence"] != "app-configuration"
            || first["sequence"] != 1
            || cfg["kind"] != "complete"
            || cfg["schemaVersion"] != 1
            || !matches!(req["mode"].as_str(), Some("copy" | "sync" | "move"))
            || req["dryRun"] != false
            || !req["source"]["remote"].is_null()
            || !req["destination"]["remote"].is_null()
            || rows
                .iter()
                .filter(|r| r["action"] == "configuration")
                .count()
                != 1
        {
            return Err("僅支援含完整設定的本機複製、同步或移動報告（不含預演）。".into());
        }
        let source = str_key(&req["source"], "path")?.trim_end_matches('/');
        let destination = str_key(&req["destination"], "path")?.trim_end_matches('/');
        if absolute(source)?.is_empty()
            || absolute(destination)?.is_empty()
            || overlap(source, destination)
        {
            return Err("來源與目標不得重疊或使用根目錄。".into());
        }
        let mut all = HashSet::new();
        let mut dirs = HashSet::new();
        for e in array(req, "selection")? {
            let n = str_key(e, "name")?;
            if rel(n)?.len() != 1 {
                return Err("報告中的選取範圍格式不正確。".into());
            }
            let dir = e["isDir"].as_bool().ok_or("報告中的選取範圍格式不正確。")?;
            all.insert(normalized(n));
            if dir {
                dirs.insert(normalized(n));
            }
        }
        let in_scope = |s: &str| {
            all.is_empty()
                || all.contains(&normalized(s))
                || s.split_once('/')
                    .is_some_and(|(n, _)| dirs.contains(&normalized(n)))
        };
        let mut missing = HashSet::new();
        for row in rows.iter().filter(|r| r["action"] == "missing-destination") {
            let n = str_key(row, "path")?;
            rel(n)?;
            if row["evidence"] != "comparison" || row["status"] != "candidate" || !in_scope(n) {
                return Err("報告缺少有效的來源路徑或含有選取範圍外的來源項目。".into());
            }
            missing.insert(normalized(n));
        }
        let mut seen = HashSet::new();
        let mut candidates = vec![];
        let mut excluded = vec![];
        for row in rows
            .iter()
            .filter(|r| r["action"] == "rename" && r["status"] == "error")
        {
            let tmp = str_key(row, "path")?;
            let msg = str_key(row, "message")?;
            let seq = row["sequence"].as_i64().ok_or("改名失敗的紀錄不完整。")?;
            if row["evidence"] != "json-log" {
                return Err("改名失敗的紀錄不完整。".into());
            }
            let parts = rel(tmp)?;
            if !seen.insert(normalized(tmp)) {
                continue;
            }
            let (leaf, _) = split_leaf(&parts)?;
            let orig = tmp
                .strip_suffix(".partial")
                .and_then(|s| s.rsplit_once('.'))
                .filter(|(_, suffix)| {
                    suffix.len() == 8
                        && suffix
                            .bytes()
                            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
                })
                .map(|(s, _)| s);
            if orig.is_some_and(|s| !in_scope(s)) {
                return Err("報告含有選取範圍外的暫存檔。".into());
            }
            if let Some(original)=orig.filter(|s|!s.is_empty()&&leaf.len()<=97&&missing.contains(&normalized(s))
            &&normalized(msg)==normalized(&format!("partial file rename failed: rename {destination}/{tmp} {destination}/{s}: operation not permitted"))){
            rel(original)?;candidates.push(Candidate{id:digest(format!("{original}\0{tmp}").as_bytes()),relative_path:original.into(),temporary_relative_path:tmp.into(),rename_sequence:seq});
        }else{excluded.push(json!({"sequence":seq,"temporaryRelativePath":tmp,"reason":"無法精確配對原始檔案與改名錯誤紀錄（或屬檔名過長等其他錯誤），不自動改名。"}));}
            if candidates.len() + excluded.len() > 10000 {
                return Err("待修復項目過多，請縮小報告範圍。".into());
            }
        }
        Ok(Report {
            path: path_text(path)?.into(),
            hash: digest(&bytes),
            source: source.into(),
            destination: destination.into(),
            candidates,
            excluded,
        })
    }
    fn validate_pair(s: &Bound, p: &Bound, src: Snapshot, tmp: Snapshot) -> Result<()> {
        if tmp.links != 1 || src.node == tmp.node {
            return Err("暫存檔為硬連結或與來源為同一檔案，不進行修復。".into());
        }
        s.ensure_empty_id(src)?;
        p.ensure_empty_id(tmp)
    }
    fn bump(v: &mut Value, k: &str) {
        let n = v[k].as_u64().unwrap_or(0);
        v[k] = json!(n + 1);
    }
    fn preview_item(roots: &Roots, candidate: &Candidate) -> Result<Value> {
        let dstparts = rel(&candidate.temporary_relative_path)?;
        let (_, parent) = split_leaf(&dstparts)?;
        let orig = rel(&candidate.relative_path)?;
        let (leaf, _) = split_leaf(&orig)?;
        let dest = roots.d.append(parent)?;
        if dest.exists(leaf)? {
            return Ok(
                json!({"candidate":candidate,"status":"existing","message":"正式檔名已存在，保留原檔不覆寫。"}),
            );
        }
        let (s, n, d, tmp) = roots.parents(candidate)?;
        let source = Bound::open(s, n, READ)?;
        let partial = Bound::open(d, tmp, READ)?;
        let (src, part) = (source.snapshot()?, partial.snapshot()?);
        validate_pair(&source, &partial, src, part)?;
        if src.size != part.size {
            return Ok(
                json!({"candidate":candidate,"status":"mismatch","message":"來源與暫存檔大小不同，不改名。"}),
            );
        }
        let (sh, src) = source.stable_hash()?;
        let (ph, part) = partial.stable_hash()?;
        source.check(src)?;
        partial.check(part)?;
        if sh != ph {
            return Ok(
                json!({"candidate":candidate,"status":"mismatch","message":"來源與暫存檔的 SHA-256 不同，不改名。"}),
            );
        }
        Ok(
            json!({"candidate":candidate,"status":"ready","message":"檔案大小與 SHA-256 完全一致，可還原為正式檔名。","source":src,"temporary":part,"sourceParent":source.parent.id()?,"destinationParent":partial.parent.id()?,"sha256":sh}),
        )
    }
    pub fn preview(report: &Path, plan: &Path) -> Result<Value> {
        let r = parse_report(report)?;
        let roots = Roots::new(&r)?;
        let mut output = Output::open(plan, &r, &roots, false)?;
        let mut counts = json!({"total":r.candidates.len()+r.excluded.len(),"ready":0,"existing":0,"mismatch":0,"blocked":r.excluded.len()});
        let mut items = vec![];
        for c in &r.candidates {
            let item = preview_item(&roots, c)
                .unwrap_or_else(|e| json!({"candidate":c,"status":"blocked","message":e}));
            bump(&mut counts, str_key(&item, "status")?);
            items.push(item);
        }
        roots.s.validate()?;
        roots.d.validate()?;
        let plan = json!({"schemaVersion":1,"kind":PLAN,"createdAt":crate::now(),"reportPath":r.path,"reportSHA256":r.hash,"sourceRoot":r.source,"destinationRoot":r.destination,
        "sourceRootIdentity":roots.s.id()?,"destinationRootIdentity":roots.d.id()?,"items":items,"excluded":r.excluded,"counts":counts});
        output.persist(&plan)?;
        Ok(plan)
    }
    struct Loaded {
        value: Value,
        hash: String,
        report: Report,
        roots: Roots,
    }
    fn load_plan(path: &Path) -> Result<Loaded> {
        let bytes = read_document(path, 32 * MIB)?;
        let plan: Value = serde_json::from_slice(&bytes).map_err(|e| e.to_string())?;
        if plan["schemaVersion"] != 1 || plan["kind"] != PLAN {
            return Err("此版本不支援這份暫存檔修復計畫。".into());
        }
        let report = parse_report(Path::new(str_key(&plan, "reportPath")?))?;
        if plan["reportSHA256"] != report.hash
            || plan["sourceRoot"] != report.source
            || plan["destinationRoot"] != report.destination
        {
            return Err("原始報告或來源／目標路徑已變更，請重新預覽。".into());
        }
        let allowed: HashMap<_, _> = report.candidates.iter().map(|c| (&c.id, c)).collect();
        let mut seen = HashSet::new();
        for item in array(&plan, "items")? {
            let c: Candidate = decode(&item["candidate"])?;
            if allowed.get(&c.id).copied() != Some(&c)
                || !seen.insert(c.id)
                || !matches!(
                    item["status"].as_str(),
                    Some("ready" | "existing" | "mismatch" | "blocked")
                )
            {
                return Err("修復計畫含有重複、未在原始報告中或不支援的項目。".into());
            }
        }
        let roots = Roots::new(&report)?;
        if decode::<Node>(&plan["sourceRootIdentity"])? != roots.s.id()?
            || decode::<Node>(&plan["destinationRootIdentity"])? != roots.d.id()?
        {
            return Err("來源或目標目錄已變更，請重新預覽。".into());
        }
        Ok(Loaded {
            value: plan,
            hash: digest(&bytes),
            report,
            roots,
        })
    }
    struct Verified {
        source: Bound,
        partial: Bound,
        src: Snapshot,
        tmp: Snapshot,
        hash: String,
        final_leaf: String,
    }
    impl Verified {
        fn new(roots: &Roots, item: &Value, candidate: &Candidate) -> Result<Self> {
            let (s, n, d, t) = roots.parents(candidate)?;
            if s.id()? != decode(&item["sourceParent"])?
                || d.id()? != decode(&item["destinationParent"])?
            {
                return Err("來源上層目錄已變更，請重新預覽。".into());
            }
            let source = Bound::open(s, n, READ)?;
            let partial = Bound::open(d, t, READ)?;
            let hash = str_key(item, "sha256")?.to_owned();
            if hash.len() != 64
                || !hash
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            {
                return Err("修復計畫缺少原始檔案識別或校驗值。".into());
            }
            Ok(Self {
                source,
                partial,
                src: decode(&item["source"])?,
                tmp: decode(&item["temporary"])?,
                hash,
                final_leaf: n.into(),
            })
        }
        fn verify(&self) -> Result<()> {
            self.source.check(self.src)?;
            self.partial.check(self.tmp)?;
            validate_pair(&self.source, &self.partial, self.src, self.tmp)?;
            if self.source.stable_hash()?.0 != self.hash
                || self.partial.stable_hash()?.0 != self.hash
            {
                return Err("來源或暫存檔內容已變更，未改名；請重新預覽。".into());
            }
            self.source.check(self.src)?;
            self.partial.check(self.tmp)
        }
    }
    fn set_flags(f: &File, flags: u32) -> Result<()> {
        // SAFETY: only the previously verified partial's held descriptor is modified.
        if unsafe { libc::fchflags(f.as_raw_fd(), flags) } != 0 {
            Err(errno())
        } else {
            Ok(())
        }
    }
    enum Commit {
        Renamed(bool),
        Unsupported(i32),
    }
    fn commit(v: &Verified, force_unsupported: bool) -> Result<Commit> {
        commit_partial(&v.partial, v.tmp, &v.final_leaf, force_unsupported)
    }
    fn commit_partial(
        partial: &Bound,
        expected: Snapshot,
        final_leaf: &str,
        force_unsupported: bool,
    ) -> Result<Commit> {
        partial.check(expected)?;
        if expected.links != 1 {
            return Err("暫存檔已變成硬連結，未改名。".into());
        }
        let n = c(final_leaf)?;
        let clear = expected.flags & libc::UF_IMMUTABLE != 0;
        if clear {
            set_flags(&partial.file, expected.flags & !libc::UF_IMMUTABLE)
                .map_err(|e| format!("無法解除此暫存檔的鎖定：{e}"))?;
        }
        let mut renamed = false;
        let result = (|| {
            let state = partial.snapshot()?;
            if !state.same_content(expected) || state.flags != expected.flags & !libc::UF_IMMUTABLE
            {
                return Err("暫存檔在解除鎖定時發生變更，未改名。".into());
            }
            let parent = partial.parent.last();
            let rc = if force_unsupported {
                -1
            } else {
                // SAFETY: both names are validated single components relative to the pinned parent.
                // RENAME_EXCL never overwrites another file; no hard links are used.
                unsafe {
                    libc::renameatx_np(
                        parent.as_raw_fd(),
                        partial.leaf.as_ptr(),
                        parent.as_raw_fd(),
                        n.as_ptr(),
                        libc::RENAME_EXCL,
                    )
                }
            };
            if rc != 0 {
                let e = if force_unsupported {
                    io::Error::from_raw_os_error(libc::ENOTSUP)
                } else {
                    io::Error::last_os_error()
                };
                if let Some(code @ (libc::ENOTSUP | libc::ENOSYS)) = e.raw_os_error() {
                    return Ok(Commit::Unsupported(code));
                }
                return Err(failure("正式檔名已存在，或無法執行不覆寫的原子改名", e));
            }
            renamed = true;
            partial.parent.validate()?;
            let named = stat_at(parent, &n).map_err(|_| "改名後的檔案狀態或內容異常。")?;
            let held = Snapshot::new(&stat_fd(&partial.file)?);
            if Snapshot::new(&named) != held
                || !held.same_content(expected)
                || held.flags != state.flags
            {
                return Err("改名後的檔案狀態或內容異常。".into());
            }
            Ok(Commit::Renamed(clear))
        })();
        if !matches!(result, Ok(Commit::Renamed(_))) && clear {
            set_flags(&partial.file, expected.flags)
                .map_err(|e| format!("無法還原暫存檔的鎖定屬性：{e}"))?;
        }
        result.map_err(|e: String| {
            if renamed {
                format!("已改名但最終核對未通過，請檢查正式檔案與修復收據。{e}")
            } else {
                e
            }
        })
    }

    enum RecoveryError {
        File(String),
        Journal(String),
    }
    impl From<String> for RecoveryError {
        fn from(e: String) -> Self {
            Self::File(e)
        }
    }
    type Step<T> = std::result::Result<T, RecoveryError>;
    fn event(j: &mut Output, kind: &str, c: &Candidate, outcome: Option<&Value>) -> Result<()> {
        let mut record = json!({"event":kind,"time":crate::now(),"candidate":c});
        if let Some(o) = outcome {
            record["outcome"] = o.clone();
        }
        j.persist(&record)
    }
    struct NewFile {
        bound: Bound,
        creation: Node,
        pinned: Option<Node>,
        filesystem: String,
    }
    impl NewFile {
        fn validate(&mut self, bytes: u64, v: &Verified, finish: bool) -> Result<Snapshot> {
            let state = self.bound.snapshot()?;
            if state.node.device != self.creation.device
                || state.links != 1
                || state.size as u64 != bytes
                || state.node == v.src.node
                || state.node == v.tmp.node
                || state.flags & libc::UF_IMMUTABLE != 0
                || self.pinned.is_some_and(|id| id != state.node)
            {
                return Err("新檔的大小、權限或識別狀態異常，未確認修復完成。".into());
            }
            if self.pinned.is_none() && (finish || bytes > 0 && state.node != self.creation) {
                self.pinned = Some(state.node);
            }
            Ok(state)
        }
        fn set_time(&self, v: &Verified) -> Result<()> {
            let times = [
                libc::timespec {
                    tv_sec: 0,
                    tv_nsec: libc::UTIME_OMIT as _,
                },
                libc::timespec {
                    tv_sec: v.src.modified_seconds,
                    tv_nsec: v.src.modified_nanoseconds,
                },
            ];
            // SAFETY: futimens is given a held file and two initialized timespecs.
            if unsafe { libc::futimens(self.bound.file.as_raw_fd(), times.as_ptr()) } != 0 {
                return Err(failure("無法保留新檔修改時間", io::Error::last_os_error()));
            }
            self.bound
                .file
                .sync_all()
                .map_err(|e| failure("新檔修改時間無法同步至磁碟", e))
        }
        fn time_matches(&self, state: Snapshot, src: Snapshot) -> bool {
            let delta = (i128::from(state.modified_seconds) - i128::from(src.modified_seconds))
                * 1000000000
                + i128::from(state.modified_nanoseconds)
                - i128::from(src.modified_nanoseconds);
            let tolerance = match self.filesystem.as_str() {
                "msdos" => 2000000000,
                "hfs" => 1000000000,
                "exfat" => 10000000,
                _ => 0,
            };
            delta.abs() <= tolerance
        }
    }
    struct RebuildProgress<'a> {
        candidate: &'a Candidate,
        retained: Snapshot,
        rename_errno: i32,
        created: bool,
        output: Option<Snapshot>,
        written: u64,
    }
    impl RebuildProgress<'_> {
        fn outcome(&self, status: &str, message: &str, retained: bool) -> Value {
            let mut o = json!({"candidate":self.candidate,"status":status,"message":message,"clearedUserImmutable":false,"method":"verified-exclusive-copy","renameErrno":self.rename_errno,"bytesWritten":self.written});
            if let Some(state) = self.output {
                o["newOutput"] = json!(state);
            }
            if retained {
                o["retainedPartial"] = json!(self.retained);
                o["partialRetained"] = json!(true);
            }
            o
        }
        fn journal(&self, j: &mut Output, kind: &str) -> Step<()> {
            let status = if self.created {
                "failed-new-output"
            } else {
                "pending-rebuild"
            };
            let o = self.outcome(
                status,
                "新檔尚待最終確認；後續記錄為修復完成才算成功。原暫存檔已保留。",
                true,
            );
            event(j, kind, self.candidate, Some(&o)).map_err(RecoveryError::Journal)
        }
    }
    #[cfg(test)]
    thread_local! { static AFTER_DURABLE_PROGRESS: std::cell::RefCell<Option<Box<dyn FnOnce()>>> = const { std::cell::RefCell::new(None) }; }

    fn rebuild(
        v: &Verified,
        candidate: &Candidate,
        code: i32,
        journal: &mut Output,
    ) -> Step<Value> {
        let mut progress = RebuildProgress {
            candidate,
            retained: v.tmp,
            rename_errno: code,
            created: false,
            output: None,
            written: 0,
        };
        let mut collision = false;
        let mut opened: Option<NewFile> = None;
        let result = (|| -> Step<()> {
            v.verify()?;
            progress.journal(journal, "rebuild-intent")?;
            let parent = v.partial.parent.clone();
            parent.validate()?;
            let leaf = c(&v.final_leaf)?;
            #[cfg(test)]
            if tests::before_exclusive_create_enabled() {
                tests::swift_callback("beforeExclusiveCreate")?;
            }
            let file = openat(parent.last().as_raw_fd(), &leaf, CREATE).map_err(|e| {
                collision = e.raw_os_error() == Some(libc::EEXIST);
                failure("無法以不覆寫方式建立正式檔案", e)
            })?;
            progress.created = true;
            let bound = Bound { parent, leaf, file };
            let initial = bound.snapshot()?;
            progress.output = Some(initial);
            let filesystem = fstype(&bound.file, "無法確認新檔的系統識別資訊")?;
            let pinned = if initial.size == 0 && matches!(filesystem.as_str(), "msdos" | "exfat") {
                None
            } else {
                Some(initial.node)
            };
            let new = opened.insert(NewFile {
                bound,
                creation: initial.node,
                pinned,
                filesystem,
            });
            progress.output = Some(new.validate(0, v, false)?);
            progress.journal(journal, "rebuild-created")?;
            let mut hash = Sha256::new();
            let mut buf = vec![0; MIB];
            while progress.written < v.tmp.size as u64 {
                let n = read_chunk(
                    &v.partial.file,
                    &mut buf,
                    progress.written,
                    v.tmp.size as u64 - progress.written,
                )?;
                let mut consumed = 0;
                while consumed < n {
                    match new.bound.file.write_at(&buf[consumed..n], progress.written) {
                        Ok(0) => return Err("新檔寫入提早結束。".to_string().into()),
                        Ok(k) => {
                            consumed += k;
                            progress.written += k as u64;
                        }
                        Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                        Err(e) => return Err(failure("新檔寫入失敗；原暫存檔保留", e).into()),
                    }
                }
                hash.update(&buf[..n]);
                new.bound
                    .file
                    .sync_all()
                    .map_err(|e| failure("新檔內容無法同步至磁碟", e))?;
                progress.output = Some(new.validate(progress.written, v, false)?);
                v.source.check(v.src)?;
                v.partial.check(v.tmp)?;
                progress.journal(journal, "rebuild-progress")?;
                #[cfg(test)]
                if tests::after_durable_progress_enabled() {
                    tests::swift_callback("afterDurableProgress")?;
                }
                #[cfg(test)]
                AFTER_DURABLE_PROGRESS.with(|slot| {
                    if let Some(action) = slot.take() {
                        action();
                    }
                });
            }
            if format!("{:x}", hash.finalize()) != v.hash {
                return Err("重建過程的 SHA-256 校驗不符，保留原暫存檔。"
                    .to_string()
                    .into());
            }
            new.set_time(v)?;
            let final_state = new.validate(progress.written, v, true)?;
            progress.output = Some(final_state);
            if !new.time_matches(final_state, v.src)
                || new.bound.stable_hash()? != (v.hash.clone(), final_state)
            {
                return Err("新檔修改時間或完整 SHA-256 核對未通過。".to_string().into());
            }
            v.verify()?;
            new.bound.check(final_state)?;
            Ok(())
        })();
        match result {
            Ok(()) => Ok(progress.outcome(
                "recovered",
                "已另建正式檔案並完成完整內容核對；原 .partial 暫存檔與鎖定仍保留。",
                true,
            )),
            Err(RecoveryError::Journal(e)) => Err(RecoveryError::Journal(e)),
            Err(RecoveryError::File(e)) => {
                if let Some(new) = opened.as_ref() {
                    if let Ok(st) = stat_fd(&new.bound.file) {
                        progress.output = Some(Snapshot::new(&st));
                    }
                }
                let status = if progress.created {
                    "failed-new-output"
                } else if collision {
                    "skipped"
                } else {
                    "failed"
                };
                let message = if progress.created {
                    format!(
                        "已建立正式檔案，但尚未確認修復完成；新檔與原 .partial 皆已保留，請依收據檢查。{e}"
                    )
                } else {
                    format!("未能完成新檔建立，已保留原 .partial 暫存檔。{e}")
                };
                let mut o = progress.outcome(status, &message, v.partial.check(v.tmp).is_ok());
                set_error_code(&mut o, &e);
                Ok(o)
            }
        }
    }
    fn process_ready(
        roots: &Roots,
        item: &Value,
        candidate: &Candidate,
        j: &mut Output,
        force_unsupported: bool,
    ) -> Step<Value> {
        let parts = rel(&candidate.temporary_relative_path)?;
        let (_, parent) = split_leaf(&parts)?;
        let dest = roots.d.append(parent)?;
        if dest.id()? != decode(&item["destinationParent"])? {
            return Err("目標上層目錄已變更，請重新預覽。".to_string().into());
        }
        let orig = rel(&candidate.relative_path)?;
        let (leaf, _) = split_leaf(&orig)?;
        if dest.exists(leaf)? {
            return Ok(
                json!({"candidate":candidate,"status":"skipped","message":"正式檔名已存在，保留原檔不覆寫。","clearedUserImmutable":false}),
            );
        }
        let mut v = Verified::new(roots, item, candidate)?;
        v.verify()?;
        match commit(&v, force_unsupported)? {
            Commit::Renamed(clear) => Ok(
                json!({"candidate":candidate,"status":"recovered","message":"已核對完整內容並還原為正式檔名。","method":"atomic-rename","partialRetained":false,"clearedUserImmutable":clear}),
            ),
            Commit::Unsupported(code) => {
                let restored = v.partial.snapshot()?;
                if !restored.same_content(v.tmp) || restored.flags != v.tmp.flags {
                    return Err("無法使用不覆寫的原子改名，且無法確認原暫存檔與鎖定狀態已還原，因此未建立新檔。"
                        .to_string()
                        .into());
                }
                v.tmp = restored;
                rebuild(&v, candidate, code, j)
            }
        }
    }
    fn journal_path(p: &Path) -> Result<PathBuf> {
        Ok(PathBuf::from(format!("{}.journal.jsonl", path_text(p)?)))
    }
    pub fn apply(plan: &Path, receipt: &Path) -> Result<Value> {
        apply_with(plan, receipt, false)
    }
    fn apply_with(plan: &Path, destination: &Path, force_unsupported: bool) -> Result<Value> {
        let loaded = load_plan(plan)?;
        let r = &loaded.report;
        let roots = &loaded.roots;
        let planned = array(&loaded.value, "items")?;
        let output_path = journal_path(destination)?;
        let mut output = Output::open(destination, r, roots, false)?;
        let mut journal = Output::open(&output_path, r, roots, true)?;
        let mut receipt = json!({"schemaVersion":1,"kind":RECEIPT,"startedAt":crate::now(),"planPath":path_text(plan)?,"planSHA256":loaded.hash,"journalPath":path_text(&output_path)?,
        "reportPath":r.path,"reportSHA256":r.hash,"sourceRoot":r.source,"destinationRoot":r.destination,"excluded":r.excluded,"items":[],
        "counts":{"total":planned.len()+r.excluded.len(),"recovered":0,"skipped":r.excluded.len(),"failed":0,"renamed":0,"rebuilt":0,"retainedPartials":0,"failedNewOutputs":0}});
        output.persist(&receipt)?;
        journal.persist(&receipt)?;
        let mut items = vec![];
        for item in planned {
            let c: Candidate = decode(&item["candidate"])?;
            let outcome = if item["status"] != "ready" {
                json!({"candidate":c,"status":"skipped","message":format!("預覽未列為可修復：{}",str_key(item,"message")?),"clearedUserImmutable":false})
            } else {
                event(&mut journal, "intent", &c, None)?;
                match process_ready(roots, item, &c, &mut journal, force_unsupported) {
                    Ok(o) => o,
                    Err(RecoveryError::Journal(e)) => return Err(e),
                    Err(RecoveryError::File(e)) => {
                        let mut o = json!({"candidate":c,"status":"failed","message":e});
                        set_error_code(&mut o, &e);
                        o
                    }
                }
            };
            let counts = &mut receipt["counts"];
            let status = str_key(&outcome, "status")?;
            bump(
                counts,
                if status == "failed-new-output" {
                    "failed"
                } else {
                    status
                },
            );
            if status == "recovered" {
                bump(
                    counts,
                    if outcome["method"] == "atomic-rename" {
                        "renamed"
                    } else {
                        "rebuilt"
                    },
                );
            }
            if status == "failed-new-output" {
                bump(counts, "failedNewOutputs");
            }
            if outcome["partialRetained"] == true {
                bump(counts, "retainedPartials");
            }
            event(&mut journal, "outcome", &c, Some(&outcome))?;
            items.push(outcome);
        }
        receipt["finishedAt"] = json!(crate::now());
        receipt["items"] = json!(items);
        journal
            .persist(&json!({"event":"finished","time":crate::now(),"counts":receipt["counts"]}))?;
        output.persist(&receipt)?;
        Ok(receipt)
    }
    fn verify_journal(receipt: &Value) -> Result<()> {
        let bytes = read_document(Path::new(str_key(receipt, "journalPath")?), 64 * MIB)?;
        let mut lines = bytes.split(|b| *b == b'\n').filter(|l| !l.is_empty());
        let first = lines.next().ok_or("原修復日誌不完整。")?;
        let initial: Value = serde_json::from_slice(first).map_err(|e| e.to_string())?;
        for k in [
            "schemaVersion",
            "kind",
            "startedAt",
            "planPath",
            "planSHA256",
            "reportPath",
            "reportSHA256",
            "sourceRoot",
            "destinationRoot",
            "journalPath",
        ] {
            if initial[k] != receipt[k] {
                return Err("收據與原修復日誌不一致。".into());
            }
        }
        if !initial["finishedAt"].is_null() || !array(&initial, "items")?.is_empty() {
            return Err("原修復日誌起始狀態異常。".into());
        }
        let mut completed = HashMap::new();
        let mut last = Value::Null;
        for (i, line) in lines.enumerate() {
            if i >= 199999 {
                return Err("修復日誌過長。".into());
            }
            let e: Value = serde_json::from_slice(line).map_err(|e| e.to_string())?;
            str_key(&e, "event")?;
            str_key(&e, "time")?;
            if e["event"] == "outcome" {
                let c: Candidate = decode(&e["candidate"])?;
                if e["candidate"] != e["outcome"]["candidate"]
                    || completed.insert(c.id, e["outcome"].clone()).is_some()
                {
                    return Err("修復日誌含有重複或不完整結果。".into());
                }
            }
            last = e;
        }
        let items = array(receipt, "items")?;
        if last["event"] != "finished"
            || last["counts"] != receipt["counts"]
            || completed.len() != items.len()
            || !items.iter().all(|i| {
                i["candidate"]["id"]
                    .as_str()
                    .and_then(|id| completed.get(id))
                    == Some(i)
            })
        {
            return Err("收據內容與原修復日誌不一致，不清理暫存檔。".into());
        }
        Ok(())
    }
    fn cleanup_one(
        roots: &Roots,
        item: &Value,
        candidate: &Candidate,
        recovered: &Value,
    ) -> Result<bool> {
        if item["status"] != "ready" {
            return Err("預覽項目未驗證。".into());
        }
        let mut v = Verified::new(roots, item, candidate)?;
        let retained: Snapshot = decode(&recovered["retainedPartial"])?;
        let new: Snapshot = decode(&recovered["newOutput"])?;
        if !retained.same_content(v.tmp)
            || retained.flags != v.tmp.flags
            || new.size != v.tmp.size
            || recovered["bytesWritten"].as_i64() != Some(v.tmp.size)
            || new.links != 1
            || new.node == v.src.node
            || new.node == retained.node
        {
            return Err("收據缺少新檔或原暫存檔的驗證資訊，不清理。".into());
        }
        v.tmp = retained;
        v.verify()?;
        let final_file = Bound::open(v.partial.parent.clone(), &v.final_leaf, READ)?;
        final_file.check(new)?;
        if final_file.stable_hash()?.0 != v.hash {
            return Err("來源、暫存檔或正式檔的 SHA-256 不一致，保留原暫存檔。".into());
        }
        v.source.check(v.src)?;
        v.partial.check(v.tmp)?;
        final_file.check(new)?;
        let cleared = v.tmp.flags & libc::UF_IMMUTABLE != 0;
        if cleared {
            set_flags(&v.partial.file, v.tmp.flags & !libc::UF_IMMUTABLE)
                .map_err(|e| format!("無法解除此暫存檔的鎖定，未清理：{e}"))?;
        }
        let result = (|| {
            let state = v.partial.snapshot()?;
            if !state.same_content(v.tmp) || state.flags != v.tmp.flags & !libc::UF_IMMUTABLE {
                return Err("暫存檔在解除鎖定時發生變更，未清理。".into());
            }
            v.source.check(v.src)?;
            final_file.check(new)?;
            v.partial.check(state)?;
            // SAFETY: this is the verified receipt-bound partial in its held parent.
            // macOS has no inode-conditional unlink; the UI requires other writers to stop.
            if unsafe {
                libc::unlinkat(
                    v.partial.parent.last().as_raw_fd(),
                    v.partial.leaf.as_ptr(),
                    0,
                )
            } != 0
            {
                return Err(failure("清理指定暫存檔失敗", io::Error::last_os_error()));
            }
            Ok(cleared)
        })();
        if result.is_err() && cleared {
            set_flags(&v.partial.file, v.tmp.flags)
                .map_err(|e| format!("無法還原暫存檔的鎖定狀態，請手動檢查此檔案。{e}"))?;
        }
        result
    }
    pub fn cleanup(receipt_path: &Path, result_path: &Path) -> Result<Value> {
        let bytes = read_document(receipt_path, 32 * MIB)?;
        let receipt: Value = serde_json::from_slice(&bytes).map_err(|e| e.to_string())?;
        if receipt["schemaVersion"] != 1
            || receipt["kind"] != RECEIPT
            || receipt["finishedAt"].as_str().is_none()
        {
            return Err("只接受已完成全部步驟的修復收據。".into());
        }
        let plan_path = Path::new(str_key(&receipt, "planPath")?);
        let loaded = load_plan(plan_path)?;
        let r = &loaded.report;
        let roots = &loaded.roots;
        if receipt["planSHA256"] != loaded.hash
            || receipt["reportSHA256"] != r.hash
            || receipt["reportPath"] != r.path
            || receipt["sourceRoot"] != r.source
            || receipt["destinationRoot"] != r.destination
        {
            return Err("收據、計畫與原始報告不一致，不清理暫存檔。".into());
        }
        let planned = array(&loaded.value, "items")?
            .iter()
            .map(|v| Ok((str_key(&v["candidate"], "id")?, v)))
            .collect::<Result<HashMap<_, _>>>()?;
        let recovered = array(&receipt, "items")?;
        let mut seen = HashSet::new();
        for o in recovered {
            let id = str_key(&o["candidate"], "id")?;
            if !seen.insert(id)
                || planned
                    .get(id)
                    .is_none_or(|p| p["candidate"] != o["candidate"])
            {
                return Err("收據含有重複或不在計畫中的項目，不清理暫存檔。".into());
            }
        }
        verify_journal(&receipt)?;
        let mut output = Output::open(result_path, r, roots, false)?;
        let jp = journal_path(result_path)?;
        let mut journal = Output::open(&jp, r, roots, true)?;
        let mut result = json!({"schemaVersion":1,"kind":"local-partial-cleanup-receipt","startedAt":crate::now(),"recoveryReceiptPath":path_text(receipt_path)?,"recoveryReceiptSHA256":digest(&bytes),"journalPath":path_text(&jp)?,
        "planPath":path_text(plan_path)?,"planSHA256":loaded.hash,"reportPath":r.path,"reportSHA256":r.hash,"sourceRoot":r.source,"destinationRoot":r.destination,
        "items":[],"counts":{"total":recovered.len(),"removed":0,"skipped":0,"failed":0}});
        output.persist(&result)?;
        journal.persist(&result)?;
        let mut items = vec![];
        for o in recovered {
            let c: Candidate = decode(&o["candidate"])?;
            let mut outcome = if o["status"] != "recovered"
                || o["method"] != "verified-exclusive-copy"
                || o["partialRetained"] != true
            {
                json!({"candidate":c,"status":"skipped","message":"此項目不是已驗證完成、並保留原暫存檔的重建結果，不能清理。","clearedUserImmutable":false})
            } else {
                event(&mut journal, "cleanup-intent", &c, None)?;
                let item = planned.get(c.id.as_str()).ok_or("收據項目不在計畫中。")?;
                match cleanup_one(roots, item, &c, o) {
                    Ok(cleared) => {
                        json!({"candidate":c,"status":"removed","message":"已再次核對來源與重建檔案內容一致，並清除此暫存檔。","clearedUserImmutable":cleared,"partialRetained":false})
                    }
                    Err(e) => {
                        let mut o = json!({"candidate":c,"status":"failed","message":e});
                        set_error_code(&mut o, &e);
                        o
                    }
                }
            };
            outcome["method"] = json!("verified-partial-cleanup");
            bump(&mut result["counts"], str_key(&outcome, "status")?);
            event(&mut journal, "outcome", &c, Some(&outcome))?;
            items.push(outcome);
        }
        result["finishedAt"] = json!(crate::now());
        result["items"] = json!(items);
        journal
            .persist(&json!({"event":"finished","time":crate::now(),"counts":result["counts"]}))?;
        output.persist(&result)?;
        Ok(result)
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use std::fs;
        thread_local! {
            static BRIDGE_HOOKS: std::cell::Cell<(bool, bool)> = const { std::cell::Cell::new((false, false)) };
        }
        pub(super) fn before_exclusive_create_enabled() -> bool {
            BRIDGE_HOOKS.get().0
        }
        pub(super) fn after_durable_progress_enabled() -> bool {
            BRIDGE_HOOKS.get().1
        }

        fn bridge_input() -> Result<Value> {
            let mut message = String::new();
            if std::io::stdin()
                .read_line(&mut message)
                .map_err(|e| e.to_string())?
                == 0
            {
                // The supervising Swift test process was killed at a durable checkpoint.
                // Stop before another write, journal transition, or cleanup.
                std::process::exit(73);
            }
            serde_json::from_str(&message).map_err(|e| e.to_string())
        }
        fn bridge_output(message: Value) {
            println!("\nRBN-TEST {}", message);
            std::io::stdout().flush().unwrap();
        }
        pub(super) fn swift_callback(name: &str) -> Result<()> {
            bridge_output(json!({"callback":name}));
            let ack = bridge_input()?;
            if ack["ok"] == true {
                Ok(())
            } else {
                Err(ack["error"]
                    .as_str()
                    .unwrap_or("Missing callback acknowledgement")
                    .into())
            }
        }
        fn dispatch_swift_fixture(row: &Value) -> Result<Value> {
            let a = str_key(row, "first")?;
            let b = str_key(row, "second")?;
            match str_key(row, "method")? {
                "preview" => preview(Path::new(a), Path::new(b)),
                "cleanup" => cleanup(Path::new(a), Path::new(b)),
                "apply" => {
                    BRIDGE_HOOKS.set((
                        row["beforeExclusiveCreate"] == true,
                        row["afterDurableProgress"] == true,
                    ));
                    apply_with(
                        Path::new(a),
                        Path::new(b),
                        row["forceUnsupportedRename"] == true,
                    )
                }
                "atomicCommit" => {
                    let final_leaf = str_key(row, "third")?;
                    if rel(b)?.len() != 1 || rel(final_leaf)?.len() != 1 {
                        return Err("測試檔名不合法。".into());
                    }
                    let parent = Chain::absolute(a)?;
                    let file = Bound::open(parent, b, READ)?;
                    let expected = file.snapshot()?;
                    commit_partial(&file, expected, final_leaf, false)?;
                    Ok(Value::Null)
                }
                _ => Err("Unrecognized Swift regression operation".into()),
            }
        }
        #[test]
        #[ignore = "invoked by the original Swift regression driver on synthetic fixtures"]
        fn swift_assertion_bridge() {
            let result = bridge_input().and_then(|row| dispatch_swift_fixture(&row));
            match result {
                Ok(value) => bridge_output(json!({"result":value})),
                Err(error) => bridge_output(json!({"error":error})),
            }
        }
        struct Fixture {
            area: PathBuf,
            src: PathBuf,
            dest: PathBuf,
            report: PathBuf,
            plan: PathBuf,
            receipt: PathBuf,
            rows: Vec<Value>,
        }
        impl Fixture {
            fn new() -> Self {
                let temp = std::env::temp_dir().canonicalize().unwrap();
                let area = temp.join(format!("rbn-recovery-{}", uuid::Uuid::new_v4()));
                let src = area.join("src");
                let dest = area.join("dest");
                fs::create_dir_all(src.join("books")).unwrap();
                fs::create_dir_all(dest.join("books")).unwrap();
                let original = "books/test.pdf";
                let partial = "books/test.pdf.09abcdef.partial";
                let data = vec![0x35; MIB + 37];
                fs::write(src.join(original), &data).unwrap();
                fs::write(dest.join(partial), &data).unwrap();
                let rows = vec![
                    json!({"sequence":1,"action":"configuration","status":"info","evidence":"app-configuration","configuration":{"schemaVersion":1,"kind":"complete","request":{"mode":"sync","dryRun":false,"source":{"remote":null,"path":src},"destination":{"remote":null,"path":dest},"selection":[{"name":"books","isDir":true}]}}}),
                    json!({"sequence":2,"action":"missing-destination","status":"candidate","evidence":"comparison","path":original}),
                    json!({"sequence":3,"action":"rename","status":"error","evidence":"json-log","path":partial,"message":format!("partial file rename failed: rename {}/{} {}/{}: operation not permitted",dest.display(),partial,dest.display(),original)}),
                ];
                let v = Self {
                    report: area.join("report.jsonl"),
                    plan: area.join("plan.json"),
                    receipt: area.join("receipt.json"),
                    area,
                    src,
                    dest,
                    rows,
                };
                v.write();
                v
            }
            fn write(&self) {
                fs::write(
                    &self.report,
                    self.rows
                        .iter()
                        .map(|v| v.to_string() + "\n")
                        .collect::<String>(),
                )
                .unwrap();
            }
            fn partial(&self) -> PathBuf {
                self.dest.join("books/test.pdf.09abcdef.partial")
            }
            fn final_file(&self) -> PathBuf {
                self.dest.join("books/test.pdf")
            }
            fn original(&self) -> PathBuf {
                self.src.join("books/test.pdf")
            }
            fn plan(&self) -> Value {
                preview(&self.report, &self.plan).unwrap()
            }
            fn apply(&self, force: bool) -> Value {
                apply_with(&self.plan, &self.receipt, force).unwrap()
            }
            fn clean(&self) -> Value {
                cleanup(&self.receipt, &self.area.join("cleanup.json")).unwrap()
            }
        }
        impl Drop for Fixture {
            fn drop(&mut self) {
                let _ = fs::remove_dir_all(&self.area);
            }
        }
        #[test]
        fn atomic_rename_and_receipt() {
            let f = Fixture::new();
            assert_eq!(f.plan()["counts"]["ready"], 1);
            let r = f.apply(false);
            assert_eq!(r["counts"]["renamed"], 1);
            assert!(f.final_file().is_file() && !f.partial().exists());
            assert_eq!(
                fs::read(f.original()).unwrap(),
                fs::read(f.final_file()).unwrap()
            );
            assert_eq!(f.clean()["counts"]["skipped"], 1);
        }
        #[test]
        fn atomic_recovery_restores_verified_immutable_partial() {
            let f = Fixture::new();
            let file = File::open(f.partial()).unwrap();
            let old = stat_fd(&file).unwrap().st_flags;
            struct Reset(File, u32);
            impl Drop for Reset {
                fn drop(&mut self) {
                    let _ = set_flags(&self.0, self.1);
                }
            }
            let reset = Reset(file, old);
            set_flags(&reset.0, old | libc::UF_IMMUTABLE).unwrap();
            assert_eq!(f.plan()["counts"]["ready"], 1);
            let r = f.apply(false);
            assert_eq!(r["items"][0]["clearedUserImmutable"], true);
            assert_eq!(stat_fd(&reset.0).unwrap().st_flags, old);
        }
        #[test]
        fn fallback_copy_journal_cleanup() {
            let f = Fixture::new();
            f.plan();
            let r = f.apply(true);
            assert_eq!(r["counts"]["rebuilt"], 1);
            assert_eq!(r["counts"]["retainedPartials"], 1);
            assert!(f.partial().is_file());
            assert_eq!(
                fs::read(f.original()).unwrap(),
                fs::read(f.final_file()).unwrap()
            );
            let j = fs::read_to_string(journal_path(&f.receipt).unwrap()).unwrap();
            assert!(j.contains("rebuild-created") && j.contains("rebuild-progress"));
            assert_eq!(f.clean()["counts"]["removed"], 1);
            assert!(!f.partial().exists() && f.final_file().exists() && f.original().exists());
        }
        #[test]
        fn changed_rebuilt_file_protects_partial() {
            let f = Fixture::new();
            f.plan();
            assert_eq!(f.apply(true)["counts"]["rebuilt"], 1);
            fs::write(f.final_file(), b"modified").unwrap();
            assert_eq!(f.clean()["counts"]["failed"], 1);
            assert!(f.partial().exists());
        }
        #[test]
        fn forged_journal_and_plan_rejected() {
            let f = Fixture::new();
            let mut p = f.plan();
            p["items"][0]["candidate"]["temporaryRelativePath"] = json!("../outside");
            fs::write(&f.plan, p.to_string()).unwrap();
            assert!(apply(&f.plan, &f.receipt).is_err());
            assert!(f.partial().exists());
            let f = Fixture::new();
            f.plan();
            f.apply(true);
            fs::write(journal_path(&f.receipt).unwrap(), "{}\n").unwrap();
            assert!(cleanup(&f.receipt, &f.area.join("clean.json")).is_err());
            assert!(f.partial().exists());
        }
        #[test]
        fn preview_rejects_bad_scope_and_refuses_existing_outputs() {
            let mut f = Fixture::new();
            f.rows[1]["path"] = json!("outside");
            f.write();
            assert!(preview(&f.report, &f.plan).is_err());
            f.rows[1]["path"] = json!("books/test.pdf");
            f.rows[0]["configuration"]["request"]["dryRun"] = json!(true);
            f.write();
            assert!(preview(&f.report, &f.plan).is_err());
            let f = Fixture::new();
            assert!(preview(&f.report, &f.src.join("plan.json")).is_err());
            fs::write(&f.plan, "original").unwrap();
            assert!(preview(&f.report, &f.plan).is_err());
            assert_eq!(fs::read(&f.plan).unwrap(), b"original");
        }
        #[test]
        fn protected_files_and_excluded_pairs() {
            let mut f = Fixture::new();
            f.rows[2]["message"] = json!("some other error");
            f.write();
            assert_eq!(f.plan()["counts"]["blocked"], 1);
            let f = Fixture::new();
            fs::write(f.partial(), vec![1; MIB + 37]).unwrap();
            assert_eq!(f.plan()["counts"]["mismatch"], 1);
            let f = Fixture::new();
            fs::write(f.final_file(), b"keep").unwrap();
            assert_eq!(f.plan()["counts"]["existing"], 1);
            let f = Fixture::new();
            std::os::unix::fs::symlink(f.original(), f.dest.join("symlink")).unwrap();
            let old = f.partial();
            fs::remove_file(&old).unwrap();
            std::os::unix::fs::symlink(f.original(), &old).unwrap();
            assert_eq!(f.plan()["counts"]["blocked"], 1);
        }
        #[test]
        fn durable_interruption_retains_partial_output_and_refuses_cleanup() {
            const CHILD_DIR: &str = "RBN_TEST_DURABLE_RECOVERY_CHILD";
            if let Some(path) = std::env::var_os(CHILD_DIR) {
                let root = PathBuf::from(path);
                AFTER_DURABLE_PROGRESS
                    .with(|s| s.replace(Some(Box::new(|| std::process::exit(77)))));
                apply_with(&root.join("plan.json"), &root.join("receipt.json"), true).unwrap();
                panic!("child passed the interruption point");
            }
            let f = Fixture::new();
            f.plan();
            // Capture the nested libtest harness so its banner cannot split
            // the parent case's status line in the execution receipt.
            let output=std::process::Command::new(std::env::current_exe().unwrap())
                .args(["--exact","partial::mac::tests::durable_interruption_retains_partial_output_and_refuses_cleanup"])
                .env(CHILD_DIR,&f.area).output().unwrap();
            assert_eq!(output.status.code(), Some(77), "{output:?}");
            assert!(f.partial().exists());
            assert!(f.final_file().exists());
            assert_eq!(std::fs::metadata(f.final_file()).unwrap().len(), MIB as u64);
            let receipt: Value = serde_json::from_slice(&fs::read(&f.receipt).unwrap()).unwrap();
            assert!(receipt["finishedAt"].is_null());
            let j = fs::read_to_string(journal_path(&f.receipt).unwrap()).unwrap();
            let last: Value = serde_json::from_str(j.lines().last().unwrap()).unwrap();
            assert_eq!(last["event"], "rebuild-progress");
            assert_eq!(last["outcome"]["status"], "failed-new-output");
            assert_eq!(last["outcome"]["bytesWritten"], MIB as i64);
            assert!(cleanup(&f.receipt, &f.area.join("cleanup.json")).is_err());
            assert!(f.partial().exists());
        }
        #[test]
        fn journal_path_substitution_aborts_entire_repair() {
            let f = Fixture::new();
            f.plan();
            let journal = journal_path(&f.receipt).unwrap();
            let held = f.area.join("held-journal.jsonl");
            AFTER_DURABLE_PROGRESS.with(|s| {
                s.replace(Some(Box::new(move || {
                    fs::rename(&journal, held).unwrap();
                    fs::write(journal, b"replacement").unwrap();
                })))
            });
            assert!(apply_with(&f.plan, &f.receipt, true).is_err());
            assert_eq!(
                fs::read(journal_path(&f.receipt).unwrap()).unwrap(),
                b"replacement"
            );
            let r: Value = serde_json::from_slice(&fs::read(&f.receipt).unwrap()).unwrap();
            assert!(r["finishedAt"].is_null());
            assert!(f.partial().exists());
        }
        #[test]
        fn atomic_collision_restores_only_partial_flags() {
            let f = Fixture::new();
            let opened = File::open(f.partial()).unwrap();
            let flags = stat_fd(&opened).unwrap().st_flags;
            struct Reset(File, u32);
            impl Drop for Reset {
                fn drop(&mut self) {
                    let _ = set_flags(&self.0, self.1);
                }
            }
            let restore = Reset(opened, flags);
            set_flags(&restore.0, flags | libc::UF_IMMUTABLE).unwrap();
            let plan = f.plan();
            let loaded = load_plan(&f.plan).unwrap();
            let item = &plan["items"][0];
            let c: Candidate = decode(&item["candidate"]).unwrap();
            let v = Verified::new(&loaded.roots, item, &c).unwrap();
            v.verify().unwrap();
            fs::write(f.final_file(), b"winner").unwrap();
            assert!(commit(&v, false).is_err());
            assert_eq!(
                stat_fd(&restore.0).unwrap().st_flags,
                flags | libc::UF_IMMUTABLE
            );
            assert_eq!(fs::read(f.final_file()).unwrap(), b"winner");
            assert!(f.partial().exists());
        }
        #[test]
        fn aliases_tampering_and_unreported_partials_are_protected() {
            let f = Fixture::new();
            let other = f.dest.join("not-in-report.deadbeef.partial");
            fs::hard_link(f.partial(), &other).unwrap();
            assert_eq!(f.plan()["counts"]["blocked"], 1);
            assert_eq!(f.apply(false)["counts"]["skipped"], 1);
            assert!(other.is_file() && f.partial().is_file());
            let mut f = Fixture::new();
            f.plan();
            f.rows[1]["path"] = json!("books/something-else");
            f.write();
            assert!(apply(&f.plan, &f.receipt).is_err());
            assert!(f.partial().exists());
            let f = Fixture::new();
            f.plan();
            fs::write(f.partial(), b"changed").unwrap();
            assert_eq!(f.apply(false)["counts"]["failed"], 1);
            assert!(!f.final_file().exists());
        }
        #[test]
        fn swift_recovery_messages_and_counts() {
            let cases: Vec<Value> =
                serde_json::from_str(include_str!("../tests/fixtures/partial-0.11.0.json"))
                    .unwrap();
            for case in cases {
                let mut f = Fixture::new();
                fs::write(f.original(), b"source").unwrap();
                fs::write(f.partial(), b"source").unwrap();
                match case["name"].as_str().unwrap() {
                    "ready" => {}
                    "existing" => fs::write(f.final_file(), b"sentinel").unwrap(),
                    "size" => fs::write(f.partial(), b"s").unwrap(),
                    "hash" => fs::write(f.partial(), b"target").unwrap(),
                    "hardlink" => fs::hard_link(f.partial(), f.dest.join("other")).unwrap(),
                    "partial-symlink" => {
                        fs::remove_file(f.partial()).unwrap();
                        std::os::unix::fs::symlink(f.original(), f.partial()).unwrap();
                    }
                    "source-symlink" | "source-parent-symlink" => {
                        let old = if case["name"] == "source-symlink" {
                            f.original()
                        } else {
                            f.src.join("books")
                        };
                        let new = f.src.join("held");
                        fs::rename(&old, &new).unwrap();
                        std::os::unix::fs::symlink(new, old).unwrap();
                    }
                    "unmatched-error" => {
                        f.rows[2]["message"] = json!("different message");
                        f.write();
                    }
                    unknown => panic!("unknown fixture {unknown}"),
                }
                for (phase, outcome) in [("preview", f.plan()), ("apply", f.apply(false))] {
                    let items: Vec<_> = outcome["items"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .map(|item| {
                            let mut projected = json!({});
                            for key in [
                                "status",
                                "message",
                                "method",
                                "partialRetained",
                                "clearedUserImmutable",
                                "errorCode",
                            ] {
                                if let Some(value) = item.get(key) {
                                    projected[key] = value.clone();
                                }
                            }
                            projected
                        })
                        .collect();
                    assert_eq!(
                        json!({"counts":outcome["counts"],"items":items}),
                        case[phase],
                        "{} {phase}",
                        case["name"]
                    );
                }
            }
        }
        #[test]
        fn fallback_preserves_locked_source_time_and_never_replaces_collision() {
            use std::time::{Duration, UNIX_EPOCH};
            let f = Fixture::new();
            let source = File::options()
                .read(true)
                .write(true)
                .open(f.original())
                .unwrap();
            source
                .set_modified(UNIX_EPOCH + Duration::new(1_700_000_000, 125_000_000))
                .unwrap();
            let flags = stat_fd(&source).unwrap().st_flags;
            struct Reset(File, u32);
            impl Drop for Reset {
                fn drop(&mut self) {
                    let _ = set_flags(&self.0, self.1);
                }
            }
            let held = Reset(source, flags);
            set_flags(&held.0, flags | libc::UF_IMMUTABLE).unwrap();
            let src = Snapshot::new(&stat_fd(&held.0).unwrap());
            let p = f.plan();
            let loaded = load_plan(&f.plan).unwrap();
            let c: Candidate = decode(&p["items"][0]["candidate"]).unwrap();
            let v = Verified::new(&loaded.roots, &p["items"][0], &c).unwrap();
            let mut journal = Output::open(
                &f.area.join("isolated-journal"),
                &loaded.report,
                &loaded.roots,
                true,
            )
            .unwrap();
            fs::write(f.final_file(), b"sentinel").unwrap();
            let Ok(collision) = rebuild(&v, &c, libc::ENOTSUP, &mut journal) else {
                panic!("collision lost journal");
            };
            assert_eq!(collision["status"], "skipped");
            assert_eq!(collision["errorCode"], libc::EEXIST);
            assert_eq!(fs::read(f.final_file()).unwrap(), b"sentinel");
            fs::remove_file(f.final_file()).unwrap();
            assert_eq!(f.apply(true)["counts"]["rebuilt"], 1);
            let new = Snapshot::new(&stat_fd(&File::open(f.final_file()).unwrap()).unwrap());
            assert_eq!(
                (src.modified_seconds, src.modified_nanoseconds),
                (new.modified_seconds, new.modified_nanoseconds)
            );
            assert_eq!(Snapshot::new(&stat_fd(&held.0).unwrap()), src);
            assert_eq!(new.flags & libc::UF_IMMUTABLE, 0);
            assert!(f.partial().is_file());
        }
        #[test]
        fn partial_recovery_never_guesses_truncated_names() {
            let mut f = Fixture::new();
            let original = format!("books/{}.pdf", "a".repeat(99));
            let temporary = format!("{}.09abcdef.partial", original);
            f.rows[1]["path"] = json!(original);
            f.rows[2]["path"] = json!(temporary);
            f.rows[2]["message"] = json!(format!(
                "partial file rename failed: rename {}/{} {}/{}: operation not permitted",
                f.dest.display(),
                temporary,
                f.dest.display(),
                original
            ));
            f.write();
            let p = f.plan();
            assert_eq!(p["counts"]["ready"], 0);
            assert_eq!(p["counts"]["blocked"], 1);
            assert_eq!(f.apply(false)["counts"]["recovered"], 0);
            assert!(f.partial().is_file());
        }
        #[test]
        fn local_copy_move_and_direct_file_selections() {
            for mode in ["move", "copy"] {
                let mut f = Fixture::new();
                let request = &mut f.rows[0]["configuration"]["request"];
                request["mode"] = json!(mode);
                request["source"]["path"] = json!(f.src.join("books"));
                request["destination"]["path"] = json!(f.dest.join("books"));
                request["selection"] = json!([{"name":"test.pdf","isDir":false}]);
                f.rows[1]["path"] = json!("test.pdf");
                f.rows[2]["path"] = json!("test.pdf.09abcdef.partial");
                f.write();
                assert_eq!(f.plan()["counts"]["ready"], 1);
                assert_eq!(f.apply(false)["counts"]["recovered"], 1);
                assert_eq!(
                    fs::read(f.original()).unwrap(),
                    fs::read(f.final_file()).unwrap()
                );
            }
        }
        #[test]
        fn cleanup_checks_all_three_files_and_the_original_receipt() {
            for kind in ["source", "partial", "final", "scope", "identity"] {
                let f = Fixture::new();
                f.plan();
                let mut receipt = f.apply(true);
                let file = match kind {
                    "source" => Some(f.original()),
                    "partial" => Some(f.partial()),
                    "final" => Some(f.final_file()),
                    _ => None,
                };
                if let Some(path) = file {
                    fs::write(path, vec![42; MIB + 37]).unwrap();
                    let before = fs::read(f.partial()).unwrap();
                    let result = f.clean();
                    assert_eq!(result["counts"]["removed"], 0);
                    assert_eq!(result["counts"]["failed"], 1);
                    assert_eq!(fs::read(f.partial()).unwrap(), before);
                } else {
                    if kind == "scope" {
                        receipt["items"][0]["candidate"]["temporaryRelativePath"] =
                            json!("outside.09abcdef.partial");
                    } else {
                        receipt["items"][0]["newOutput"]["node"]["inode"] = json!(123456789);
                    }
                    fs::write(&f.receipt, receipt.to_string()).unwrap();
                    assert!(cleanup(&f.receipt, &f.area.join("clean.json")).is_err());
                    assert!(f.partial().is_file());
                    assert_eq!(
                        fs::read(f.original()).unwrap(),
                        fs::read(f.final_file()).unwrap()
                    );
                }
            }
        }
        #[test]
        fn recovery_rejects_symbolic_roots_ancestors_and_leaves() {
            for i in 0..4 {
                let f = Fixture::new();
                let old = [
                    f.original(),
                    f.src.join("books"),
                    f.dest.clone(),
                    f.src.clone(),
                ][i]
                    .clone();
                let actual = f.area.join("held");
                fs::rename(&old, &actual).unwrap();
                std::os::unix::fs::symlink(&actual, &old).unwrap();
                let result = preview(&f.report, &f.plan);
                if i < 2 {
                    assert_eq!(result.unwrap()["counts"]["blocked"], 1);
                } else {
                    assert!(result.is_err());
                }
                assert_eq!(
                    fs::read(f.original()).unwrap(),
                    fs::read(f.partial()).unwrap()
                );
            }
        }
        #[test]
        fn partial_report_signals_and_output_conflicts() {
            let f = Fixture::new();
            let extra = f.dest.join("books/unreported.09abcdef.partial");
            fs::write(&extra, b"unreported").unwrap();
            f.plan();
            fs::write(&f.receipt, b"receipt sentinel").unwrap();
            assert!(apply(&f.plan, &f.receipt).is_err());
            assert_eq!(fs::read(&f.receipt).unwrap(), b"receipt sentinel");
            fs::remove_file(&f.receipt).unwrap();
            assert_eq!(f.apply(false)["counts"]["recovered"], 1);
            assert_eq!(fs::read(&extra).unwrap(), b"unreported");
            for invalid in ["invalid JSON", "remote", "traversal", "roots"] {
                let mut f = Fixture::new();
                match invalid {
                    "invalid JSON" => fs::write(&f.report, "invalid JSON").unwrap(),
                    "remote" => {
                        f.rows[0]["configuration"]["request"]["source"]["remote"] =
                            json!("synthetic");
                        f.write();
                    }
                    "traversal" => {
                        f.rows[1]["path"] = json!("books/../other");
                        f.write();
                    }
                    _ => {
                        f.rows[0]["configuration"]["request"]["source"]["path"] =
                            json!(f.dest.join("books"));
                        f.write();
                    }
                }
                assert!(preview(&f.report, &f.plan).is_err(), "{invalid}");
                assert!(f.partial().exists());
            }
        }
        #[test]
        fn changed_source_or_claimed_target_never_overwritten() {
            let f = Fixture::new();
            f.plan();
            fs::write(f.original(), b"changed").unwrap();
            assert_eq!(f.apply(false)["counts"]["failed"], 1);
            assert!(f.partial().exists() && !f.final_file().exists());
            let f = Fixture::new();
            f.plan();
            fs::write(f.final_file(), b"keep").unwrap();
            assert_eq!(f.apply(false)["counts"]["skipped"], 1);
            assert_eq!(fs::read(f.final_file()).unwrap(), b"keep");
        }
    }
}

/// Handles the existing native repair command before bootstrapping any user state.
/// The host forwards the caller's original two option/value pairs.
pub fn run_cli(
    args: &[String],
    stdout: &mut dyn std::io::Write,
    stderr: &mut dyn std::io::Write,
) -> Option<i32> {
    use serde_json::{Value, json};
    use std::{collections::BTreeMap, path::Path};
    if args.first().is_none_or(|a| a != "--repair-local-partials") {
        return None;
    }
    let result = (|| -> crate::Result<i32> {
        if args.len() != 6 || !matches!(args[1].as_str(), "preview" | "apply" | "cleanup") {
            return Err("用法：--repair-local-partials preview --report <JSONL> --plan <新檔案>，apply --plan <計畫> --receipt <新檔案>，或 cleanup --receipt <已完成收據> --result <新檔案>。命令列的 apply／cleanup 會直接執行而不跳確認視窗；執行前請先停止 App 傳輸與其他程式對來源、目標的寫入。".into());
        }
        let mut options = BTreeMap::new();
        for pair in args[2..].chunks_exact(2) {
            if !pair[1].starts_with('/')
                || options
                    .insert(pair[0].as_str(), Path::new(&pair[1]))
                    .is_some()
            {
                return Err("請使用不重複的參數與絕對路徑。".into());
            }
        }
        let get = |k: &str| {
            options
                .get(k)
                .copied()
                .ok_or_else(|| "修復參數不正確。".to_owned())
        };
        let data: Value = match args[1].as_str() {
            "preview" => preview(get("--report")?, get("--plan")?)?,
            "apply" => apply(get("--plan")?, get("--receipt")?)?,
            _ => cleanup(get("--receipt")?, get("--result")?)?,
        };
        serde_json::to_writer_pretty(&mut *stdout, &data).map_err(|e| e.to_string())?;
        stdout.write_all(b"\n").map_err(|e| e.to_string())?;
        Ok(i32::from(
            data["counts"]["failed"].as_i64().unwrap_or_default() != 0,
        ))
    })();
    Some(match result {
        Ok(code) => code,
        Err(e) => {
            if serde_json::to_writer(&mut *stderr, &json!({"error":e})).is_ok() {
                let _ = stderr.write_all(b"\n");
            }
            2
        }
    })
}
