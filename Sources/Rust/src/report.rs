//! Swift 0.11.0 compatible append-only evidence, category ledgers and cursors.
use crate::{Result, now, retry::Failure};
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    fs::{self, File, OpenOptions},
    io::{BufRead, BufReader, BufWriter, Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    time::{Duration, Instant},
};
const MAX_RECORD: usize = 2 * 1024 * 1024;
const MAX_COUNTER: u64 = 9_007_199_254_740_991;
const SUFFIXES: [(&str, &str); 6] = [
    ("all", ".report.jsonl"),
    ("success", ".report.success.jsonl"),
    ("errors", ".report.errors.jsonl"),
    ("skipped", ".report.skipped.jsonl"),
    ("comparison", ".report.comparison.jsonl"),
    ("raw", ".comparison.log"),
];
const COUNTERS: &[&str] = &[
    "eventCount",
    "successEvents",
    "copiedEvents",
    "movedEvents",
    "deletedEvents",
    "errorEvents",
    "unattributedErrors",
    "plannedEvents",
    "informationEvents",
    "comparisonEvents",
    "matchedEvents",
    "skippedEvents",
    "candidateEvents",
    "missingSourceEvents",
    "comparisonErrorEvents",
    "comparisonMalformed",
    "comparisonPendingBytes",
    "copiedBytes",
    "failedCopyBytes",
    "copySizeMissingEvents",
    "sizeMismatchEvents",
    "growingSourceEvents",
    "retryFailures",
    "lastAttempt",
    "maxAttempts",
    "cleanupEvents",
    "cleanupFailureEvents",
    "directoryDeletedEvents",
    "directoryPlannedEvents",
];
pub struct Report {
    path: PathBuf,
    outputs: BTreeMap<String, BufWriter<File>>,
    counts: BTreeMap<String, u64>,
    complete: bool,
    failures: Vec<Failure>,
    overflow: bool,
    attempt_offset: usize,
    limit: Option<usize>,
    recent: BTreeMap<String, (u64, u64, u64)>,
    visible: Instant,
}
fn valid_id(id: &str) -> Result<()> {
    if crate::valid_id(id) {
        Ok(())
    } else {
        Err("工作編號格式不正確。".into())
    }
}
fn create(path: &Path) -> Result<File> {
    let mut o = OpenOptions::new();
    o.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        o.mode(0o600);
    }
    o.open(path).map_err(|e| e.to_string())
}
fn read_regular(path: &Path) -> Result<Option<File>> {
    let mut o = OpenOptions::new();
    o.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        o.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        o.custom_flags(0x00200000);
    }
    let file = match o.open(path) {
        Ok(f) => f,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e.to_string()),
    };
    let meta = file.metadata().map_err(|e| e.to_string())?;
    if !meta.is_file() {
        return Err("請選擇一般檔案。".into());
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if meta.file_attributes() & 0x400 != 0 {
            return Err("請選擇一般檔案。".into());
        }
    }
    Ok(Some(file))
}
fn count(v: &Value) -> Option<u64> {
    v.as_f64()
        .filter(|n| n.is_finite() && *n >= 0. && n.fract() == 0. && *n <= MAX_COUNTER as f64)
        .map(|n| n as u64)
}
fn original_path(path: &str, kind: Option<&str>) -> Option<String> {
    let leaf = path.rsplit('/').next()?;
    if kind != Some("*local.Object")
        || leaf.len() > 97
        || leaf.len() <= 17
        || !path.ends_with(".partial")
    {
        return None;
    }
    let before = path.strip_suffix(".partial")?;
    let (original, hex) = before.rsplit_once('.')?;
    if hex.len() == 8
        && hex
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        Some(original.to_owned())
    } else {
        None
    }
}
fn size_mismatch(message: &str) -> Option<(u64, u64)> {
    if message.len() > 65536 || !message.starts_with("corrupted on transfer: sizes differ src(") {
        return None;
    }
    let (a, b) = message.rsplit_once(" vs dst(")?;
    fn trailing(text: &str) -> Option<u64> {
        let (_, raw) = text.rsplit_once(") ")?;
        if raw.is_empty() || !raw.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        let n = raw.parse().ok()?;
        if n <= MAX_COUNTER { Some(n) } else { None }
    }
    let (a, b) = (trailing(a)?, trailing(b)?);
    if a != b { Some((a, b)) } else { None }
}
fn retry_details(message: &str) -> Option<(usize, usize, bool)> {
    let rest = message.strip_prefix("Attempt ")?;
    let (numbers, result) = rest.split_once(' ')?;
    let (a, b) = numbers.split_once('/')?;
    let (a, b) = (a.parse::<usize>().ok()?, b.parse::<usize>().ok()?);
    if a == 0
        || b < a
        || b > 1_000_000
        || !(result == "succeeded" || result.starts_with("failed with "))
    {
        return None;
    }
    Some((a, b, result != "succeeded"))
}
fn error_action(message: &str) -> &'static str {
    if [
        "Failed to copy:",
        "Not deleting source as copy failed:",
        "corrupted on transfer:",
    ]
    .iter()
    .any(|s| message.starts_with(s))
    {
        "copy"
    } else if message.starts_with("Couldn't move:") {
        "move"
    } else if message.starts_with("Couldn't delete:") {
        "delete"
    } else if message.starts_with("partial file rename failed:") {
        "rename"
    } else {
        "operation"
    }
}
// Foundation JSONEncoder escapes solidus characters. Preserve byte cursors
// and the maximum-record limit for paths containing forward slashes.
fn encoded_json(value: &Value) -> Result<Vec<u8>> {
    let bytes = serde_json::to_vec(value).map_err(|e| e.to_string())?;
    let count = bytes.iter().filter(|byte| **byte == b'/').count();
    if count == 0 {
        return Ok(bytes);
    }
    let mut escaped = Vec::with_capacity(bytes.len() + count);
    for byte in bytes {
        if byte == b'/' {
            escaped.push(b'\\');
        }
        escaped.push(byte);
    }
    Ok(escaped)
}
impl Report {
    pub fn new(directory: &Path, id: &str) -> Result<Self> {
        valid_id(id)?;
        let mut outputs = BTreeMap::new();
        let mut created = vec![];
        for (kind, suffix) in SUFFIXES {
            let p = directory.join(format!("{id}{suffix}"));
            match create(&p) {
                Ok(f) => {
                    created.push(p);
                    outputs.insert(kind.into(), BufWriter::with_capacity(65536, f));
                }
                Err(e) => {
                    drop(outputs);
                    for p in created {
                        let _ = fs::remove_file(p);
                    }
                    return Err(e);
                }
            }
        }
        Ok(Self {
            path: directory.join(format!("{id}.report.jsonl")),
            outputs,
            counts: COUNTERS.iter().map(|s| (s.to_string(), 0)).collect(),
            complete: false,
            failures: vec![],
            overflow: false,
            attempt_offset: 0,
            limit: None,
            recent: BTreeMap::new(),
            visible: Instant::now(),
        })
    }
    fn add(&mut self, key: &str, n: u64) {
        let value = self.counts.entry(key.into()).or_default();
        *value = value.saturating_add(n).min(MAX_COUNTER);
    }
    fn output(&mut self, kind: &str, bytes: &[u8]) -> Result<()> {
        self.outputs
            .get_mut(kind)
            .ok_or("找不到逐檔記錄分類。")?
            .write_all(bytes)
            .map_err(|e| e.to_string())
    }
    pub fn append(&mut self, mut record: Value) -> Result<()> {
        record["sequence"] = json!(self.counts["eventCount"] + 1);
        if record["time"].is_null() {
            record["time"] = json!(now());
        }
        let mut bytes = encoded_json(&record)?;
        if bytes.len() > MAX_RECORD {
            return Err("單筆逐檔記錄過大，無法完整儲存。".into());
        }
        bytes.push(b'\n');
        self.output("all", &bytes)?;
        let status = record["status"].as_str().unwrap_or("");
        if status == "success" {
            self.output("success", &bytes)?;
        }
        if status == "error" || status == "comparison-error" {
            self.output("errors", &bytes)?;
        }
        if status == "skipped" || status == "matched" {
            self.output("skipped", &bytes)?;
        }
        if record["evidence"] == "comparison" {
            self.output("comparison", &bytes)?;
        }
        self.add("eventCount", 1);
        self.periodic()
    }
    pub fn begin(&mut self, attempt: usize, limit: usize) {
        self.attempt_offset = attempt.saturating_sub(1);
        self.limit = Some(limit);
        self.counts.insert(
            "lastAttempt".into(),
            self.counts["lastAttempt"].max(attempt as u64),
        );
        self.counts.insert("maxAttempts".into(), limit as u64);
        self.failures.clear();
        self.overflow = false;
    }
    pub fn configuration(&mut self, request: &Value, scope: &str) -> Result<()> {
        self.configuration_details(request, None, None, None, Some(scope), None)
    }
    pub fn configuration_details(
        &mut self,
        request: &Value,
        version: Option<&str>,
        window: Option<&str>,
        copy: Option<&str>,
        scope: Option<&str>,
        names: Option<&str>,
    ) -> Result<()> {
        let mut metadata = json!({"kind":"complete","schemaVersion":1,"request":request,"engineVersion":version,"effectiveModifyWindow":window});
        for (k, v) in [
            ("effectiveLocalCopyPolicy", copy),
            ("retryScope", scope),
            ("effectiveLocalNamePolicy", names),
        ] {
            if let Some(v) = v {
                metadata[k] = json!(v);
            }
        }
        let mut records = vec![];
        if encoded_json(&metadata)?.len() <= MAX_RECORD / 2 {
            records.push(metadata);
        } else {
            let mut basic = request.clone();
            let selection = basic
                .as_object_mut()
                .ok_or("傳輸設定格式不正確。")?
                .remove("selection")
                .unwrap_or(json!([]));
            let mut collections = vec![("request.selection".to_owned(), selection)];
            for key in ["include", "exclude", "extraArgs"] {
                let value = basic["options"]
                    .as_object_mut()
                    .ok_or("傳輸設定格式不正確。")?
                    .remove(key)
                    .unwrap_or(json!([]));
                collections.push((format!("request.options.{key}"), value));
            }
            metadata["kind"] = json!("header");
            metadata["request"] = basic;
            metadata["collections"] = json!(
                collections
                    .iter()
                    .map(|(k, v)| (k.clone(), v.as_array().map_or(0, Vec::len)))
                    .collect::<BTreeMap<_, _>>()
            );
            records.push(metadata);
            for (name, items) in collections {
                if let Some(items) = items.as_array() {
                    for (start, chunk) in items.chunks(32).enumerate() {
                        records.push(json!({"kind":"collection","name":name,"offset":start*32,"items":chunk}));
                    }
                }
            }
        }
        self.counts.insert(
            "maxAttempts".into(),
            request["options"]["retries"].as_u64().unwrap_or(0),
        );
        for metadata in records {
            self.append(json!({"status":"info","action":"configuration","evidence":"app-configuration","message":"傳輸設定","configuration":metadata}))?;
            self.add("informationEvents", 1);
        }
        self.flush()
    }
    pub fn consume(&mut self, raw: &Value, dry: bool) -> Result<()> {
        if !raw["stats"].is_null() || raw["app"] == true {
            return Ok(());
        }
        let level = raw["level"].as_str().unwrap_or("info").to_lowercase();
        let message = raw["msg"].as_str().or(raw["error"].as_str()).unwrap_or("");
        let object = raw["object"].as_str();
        let kind = raw["objectType"].as_str();
        let is_fs = kind.is_some_and(|k| k.ends_with(".Fs") || k.ends_with(".fs"));
        let path = object.filter(|p| !p.is_empty() && !is_fs);
        let retry = retry_details(message);
        let cleanup_failed = message.starts_with("Failed to remove failed copy:")
            || message.starts_with("Failed to remove failed partial copy:");
        let error = (["error", "fatal", "alert", "emergency"].contains(&level.as_str())
            && retry.is_none())
            || cleanup_failed;
        let skipped = raw["skipped"].as_str();
        if object.is_none() && !error && skipped.is_none() && retry.is_none() {
            return Ok(());
        }
        let (mut status, mut action, mut issue) = ("info", "information", None);
        if retry.is_some() {
            action = "retry";
        } else if error {
            status = "error";
            action = error_action(message);
        } else if let Some(skip) = skipped {
            status = if dry { "planned" } else { "skipped" };
            action = skip;
        } else if message.starts_with("Copied (") || message.starts_with("Multi-thread Copied (") {
            status = if dry { "planned" } else { "success" };
            action = "copy";
        } else if message == "Moved (server-side)"
            || message.starts_with("Moved (server-side) to: ")
        {
            status = if dry { "planned" } else { "success" };
            action = "move";
        } else if message == "Deleted" {
            status = if dry { "planned" } else { "success" };
            action = "delete";
        } else if message == "Moved into backup dir" {
            status = if dry { "planned" } else { "success" };
            action = "backup";
        } else if message == "Can't follow symlink without -L/--copy-links" {
            status = "skipped";
            action = "symlink";
            issue = Some("symlink-ignored");
        } else if message == "Can't transfer non file/directory" {
            status = "skipped";
            action = "special";
            issue = Some("special-ignored");
        }
        if cleanup_failed {
            issue = Some("cleanup-failed");
            action = "cleanup";
        } else if message == "Removing failed copy" {
            action = "cleanup";
        } else if matches!(
            message,
            "not deleting directories as there were IO errors"
                | "not deleting files as there were IO errors"
        ) {
            issue = Some("deletion-deferred");
        } else if error && message.contains("can't copy - source file is being updated") {
            issue = Some("source-changed");
        } else if error
            && action == "rename"
            && kind == Some("*local.Object")
            && [
                ": operation not permitted",
                ": permission denied",
                ": access is denied.",
            ]
            .iter()
            .any(|s| message.to_lowercase().ends_with(s))
        {
            issue = Some("partial-rename-denied");
        }
        let mut record = json!({"time":raw["time"].as_str().map(str::to_owned).unwrap_or_else(now),"status":status,"action":action,"level":level,"evidence":"json-log","message":message});
        for (k, v) in [("object", object), ("path", path), ("objectType", kind)] {
            if let Some(v) = v {
                record[k] = json!(v);
            }
        }
        if issue == Some("partial-rename-denied") {
            if let Some(p) = path.and_then(|p| original_path(p, kind)) {
                record["relatedPath"] = json!(p);
            }
        }
        if let Some(n) = count(&raw["size"]) {
            record["size"] = json!(n);
        }
        self.counts
            .insert("lastAttempt".into(), self.counts["lastAttempt"].max(1));
        if let Some((attempt, limit, failed)) = retry {
            let attempt = self.attempt_offset + attempt;
            let limit = self.limit.unwrap_or(limit);
            record["attempt"] = json!(attempt);
            record["attemptLimit"] = json!(limit);
            self.counts.insert(
                "lastAttempt".into(),
                self.counts["lastAttempt"].max(attempt as u64),
            );
            self.counts.insert(
                "maxAttempts".into(),
                self.counts["maxAttempts"].max(limit as u64),
            );
            if failed {
                self.add("retryFailures", 1);
            }
        }
        if error {
            if let Some(path) = path {
                if let Some((source, destination)) = size_mismatch(message) {
                    issue = Some("size-mismatch");
                    record["action"] = json!("copy");
                    record["sourceSize"] = json!(source);
                    record["destinationSize"] = json!(destination);
                    self.add("sizeMismatchEvents", 1);
                    self.add("failedCopyBytes", destination);
                    let related = original_path(path, kind);
                    if let Some(related) = &related {
                        record["relatedPath"] = json!(related);
                    }
                    let key = related.unwrap_or_else(|| path.into());
                    if let Some((ps, pd, _)) = self.recent.get(&key) {
                        if destination > source && pd > ps && source > *ps && source >= *pd {
                            issue = Some("source-growing");
                            self.add("growingSourceEvents", 1);
                        }
                    }
                    if !self.recent.contains_key(&key) && self.recent.len() >= 256 {
                        if let Some(oldest) = self
                            .recent
                            .iter()
                            .min_by_key(|(_, (_, _, seq))| *seq)
                            .map(|(k, _)| k.clone())
                        {
                            self.recent.remove(&oldest);
                        }
                    }
                    self.recent
                        .insert(key, (source, destination, self.counts["eventCount"]));
                }
            }
        }
        if let Some(issue) = issue {
            record["issue"] = json!(issue);
        }
        self.append(record)?;
        match status {
            "success" => {
                self.add("successEvents", 1);
                match action {
                    "copy" => {
                        self.add("copiedEvents", 1);
                        if let Some(size) = count(&raw["size"]) {
                            self.add("copiedBytes", size);
                        } else {
                            self.add("copySizeMissingEvents", 1);
                        }
                    }
                    "move" => self.add("movedEvents", 1),
                    "delete" => self.add("deletedEvents", 1),
                    _ => {}
                }
            }
            "error" => {
                self.add("errorEvents", 1);
                if path.is_none() {
                    self.add("unattributedErrors", 1);
                }
                if self.failures.len() < 50001 {
                    self.failures.push(Failure {
                        path: path.map(str::to_owned),
                        object_type: kind.map(str::to_owned),
                        message: message.into(),
                    });
                } else {
                    self.overflow = true;
                }
            }
            "planned" => self.add("plannedEvents", 1),
            "skipped" => self.add("skippedEvents", 1),
            _ => self.add("informationEvents", 1),
        }
        if message == "Removing failed copy" {
            self.add("cleanupEvents", 1);
        }
        if cleanup_failed {
            self.add("cleanupFailureEvents", 1);
        }
        self.periodic()
    }
    pub fn comparison_line(&mut self, line: &str, terminated: bool) -> Result<()> {
        self.output("raw", line.as_bytes())?;
        if terminated {
            self.output("raw", b"\n")?;
        }
        self.complete = false;
        let bytes = line.as_bytes();
        let valid = terminated
            && bytes.len() <= MAX_RECORD
            && bytes.len() >= 3
            && bytes[1] == b' '
            && b"=+*-!".contains(&bytes[0])
            && !line.chars().any(|c| (c as u32) < 32 || c as u32 == 127);
        if !valid {
            self.add("comparisonMalformed", 1);
            if self.counts["comparisonMalformed"] == 1 {
                self.append(json!({"status":"info","action":"unparsed-comparison","evidence":"comparison","message":"部分比對紀錄無法解析，可匯出原始比對紀錄查看。"}))?;
            }
            return self.periodic();
        }
        if self.counts["lastAttempt"] == 0 {
            self.counts.insert("lastAttempt".into(), 1);
        }
        let (status, action, message, counter) = match bytes[0] {
            b'=' => (
                "matched",
                "match",
                "依本次比對與略過設定，不需更新。",
                "matchedEvents",
            ),
            b'+' => (
                "candidate",
                "missing-destination",
                "目標缺少此檔案，已列入傳輸清單。",
                "candidateEvents",
            ),
            b'*' => (
                "candidate",
                "different",
                "檔案有變更，已列入傳輸清單。",
                "candidateEvents",
            ),
            b'-' => (
                "comparison",
                "missing-source",
                "只有目標有此檔案。",
                "missingSourceEvents",
            ),
            _ => (
                "comparison-error",
                "comparison-error",
                "此檔案處理失敗，原因列於錯誤紀錄。",
                "comparisonErrorEvents",
            ),
        };
        self.append(json!({"status":status,"action":action,"message":message,"evidence":"comparison","timeKind":"observed","path":&line[2..],"sigil":&line[..1]}))?;
        self.add("comparisonEvents", 1);
        self.add(counter, 1);
        self.periodic()
    }
    pub fn poll(&mut self, final_pass: bool) -> Result<()> {
        if final_pass {
            self.complete = true;
            self.flush()
        } else {
            self.periodic()
        }
    }
    pub fn retry_note(
        &mut self,
        message: &str,
        attempt: usize,
        files: Option<usize>,
    ) -> Result<()> {
        let record = json!({"status":"info","action":"retry-plan","evidence":"app","message":message,"attempt":attempt});
        let _ = files;
        self.append(record)?;
        self.add("informationEvents", 1);
        self.flush()
    }
    pub fn directory_deleted(&mut self, path: &str, dry: bool) -> Result<()> {
        self.append(json!({"status":if dry{"planned"}else{"success"},"action":"cleanup","path":path,"evidence":"app","objectType":"directory","issue":"empty-directory","message":if dry{"預演：會刪除來源不存在的空資料夾。"}else{"已刪除來源不存在的空資料夾。"}}))?;
        if dry {
            self.add("plannedEvents", 1);
            self.add("directoryPlannedEvents", 1);
        } else {
            self.add("successEvents", 1);
            self.add("cleanupEvents", 1);
            self.add("directoryDeletedEvents", 1);
        }
        self.periodic()
    }
    pub fn take_failures(&mut self) -> (Vec<Failure>, bool) {
        (
            std::mem::take(&mut self.failures),
            std::mem::replace(&mut self.overflow, false),
        )
    }
    pub fn summary(&self) -> Value {
        let mut v = json!(self.counts);
        v["available"] = json!(true);
        v["formatVersion"] = json!(2);
        v["comparisonComplete"] = json!(self.complete);
        v["copyByteTotalsAvailable"] = json!(self.counts["copySizeMissingEvents"] == 0);
        v["failedFiles"] = Value::Null;
        v["skippedFiles"] = Value::Null;
        v
    }
    fn periodic(&mut self) -> Result<()> {
        if self.visible.elapsed() >= Duration::from_secs(1) {
            self.flush()
        } else {
            Ok(())
        }
    }
    pub fn flush(&mut self) -> Result<()> {
        for out in self.outputs.values_mut() {
            out.flush().map_err(|e| e.to_string())?;
        }
        self.visible = Instant::now();
        Ok(())
    }
    pub fn finish(&mut self) -> Result<()> {
        self.poll(true)?;
        for out in self.outputs.values() {
            out.get_ref().sync_all().map_err(|e| e.to_string())?;
        }
        Ok(())
    }
    pub fn path(&self) -> &Path {
        &self.path
    }
}
pub fn page(directory: &Path, id: &str, query: &Value, summary: Value) -> Result<Value> {
    valid_id(id)?;
    let map = query.as_object().ok_or("逐檔報告查詢格式不正確。")?;
    if map
        .keys()
        .any(|k| !["category", "cursor", "limit"].contains(&k.as_str()))
    {
        return Err("逐檔報告查詢格式不正確。".into());
    }
    let category = match query.get("category") {
        None => "all",
        Some(v) => v.as_str().ok_or("報告分類格式不正確。")?,
    };
    let cursor = match query.get("cursor") {
        None => 0,
        Some(v) => count(v)
            .filter(|n| *n <= 9_000_000_000_000_000)
            .ok_or("報告位置必須是 0 至 9000000000000000 的整數。")?,
    };
    let limit = match query.get("limit") {
        None => 100,
        Some(v) => count(v)
            .filter(|n| (1..=200).contains(n))
            .ok_or("每頁筆數必須是 1 至 200 的整數。")?,
    } as usize;
    let suffix = SUFFIXES
        .iter()
        .find(|(kind, _)| *kind == category && *kind != "raw")
        .map(|(_, s)| *s)
        .ok_or("逐檔報告分類不正確。")?;
    let Some(mut input) = read_regular(&directory.join(format!("{id}{suffix}")))? else {
        return Ok(json!({"available":false,"items":[],"nextCursor":null,"category":category}));
    };
    let length = input.metadata().map_err(|e| e.to_string())?.len();
    if cursor > length {
        return Err("逐檔記錄的分頁位置已失效。".into());
    }
    if cursor > 0 {
        input
            .seek(SeekFrom::Start(cursor - 1))
            .map_err(|e| e.to_string())?;
        let mut b = [0];
        input.read_exact(&mut b).map_err(|e| e.to_string())?;
        if b != [b'\n'] {
            return Err("逐檔記錄的分頁位置不正確。".into());
        }
    }
    input
        .seek(SeekFrom::Start(cursor))
        .map_err(|e| e.to_string())?;
    let mut reader = BufReader::with_capacity(65536, input.take(length - cursor));
    let mut consumed = cursor;
    let mut items = vec![];
    let mut page_bytes = 0;
    let mut incomplete = false;
    while items.len() < limit && (page_bytes < 1024 * 1024 || items.is_empty()) {
        let mut line = Vec::new();
        let n = (&mut reader)
            .take(MAX_RECORD as u64 + 2)
            .read_until(b'\n', &mut line)
            .map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        if line.last() != Some(&b'\n') {
            if line.len() > MAX_RECORD {
                return Err("單筆逐檔記錄過大。".into());
            }
            incomplete = true;
            break;
        }
        let row: Value = serde_json::from_slice(&line)
            .map_err(|_| "逐檔記錄內容不完整，請匯出原始記錄查看。")?;
        if !row.is_object() || row.get("sequence").is_none() {
            return Err("逐檔記錄內容不完整，請匯出原始記錄查看。".into());
        }
        consumed += n as u64;
        page_bytes += n;
        items.push(row);
    }
    let mut out = json!({"available":true,"items":items,"nextCursor":if consumed<length{json!(consumed)}else{Value::Null},"category":category,"incompleteTail":incomplete,"cursor":cursor});
    if summary["available"] == true {
        out["summary"] = summary;
    }
    Ok(out)
}
pub fn path(directory: &Path, id: &str, format: &str) -> Result<PathBuf> {
    valid_id(id)?;
    let (suffix, ext) = match format {
        "jsonl" => (".report.jsonl", "jsonl"),
        "comparison" => (".comparison.log", "txt"),
        _ => return Err("不支援這個逐檔記錄格式。".into()),
    };
    let mut input = read_regular(&directory.join(format!("{id}{suffix}")))?
        .ok_or("這項工作尚未產生逐檔記錄。")?;
    let mut length = input.metadata().map_err(|e| e.to_string())?.len();
    if format == "jsonl" && length > 0 {
        let mut position = length;
        let mut found = false;
        while position > 0 && !found {
            if length - position > MAX_RECORD as u64 {
                return Err("逐檔紀錄不完整，請查看原始紀錄。".into());
            }
            let begin = position.saturating_sub(65536);
            input
                .seek(SeekFrom::Start(begin))
                .map_err(|e| e.to_string())?;
            let mut bytes = vec![0; (position - begin) as usize];
            input.read_exact(&mut bytes).map_err(|e| e.to_string())?;
            if let Some(i) = bytes.iter().rposition(|b| *b == b'\n') {
                length = begin + i as u64 + 1;
                found = true;
            } else {
                position = begin;
            }
        }
        if !found {
            length = 0;
        }
    }
    input.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
    let target = directory.join(format!("{id}.report-export-{}.{ext}", uuid::Uuid::new_v4()));
    let result = (|| {
        let mut out = create(&target)?;
        let copied = std::io::copy(&mut input.take(length), &mut out).map_err(|e| e.to_string())?;
        if copied != length {
            return Err("逐檔記錄在匯出時發生變更，請重新匯出。".into());
        }
        out.sync_all().map_err(|e| e.to_string())?;
        Ok(target.clone())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&target);
    }
    result
}

pub fn normalized_summary(raw: &Value) -> Option<Value> {
    if !raw.is_object() || raw["available"] != true {
        return None;
    }
    let version = count(&raw["formatVersion"]).unwrap_or(1).min(2);
    let mut result = json!({"available":true,"formatVersion":version,"comparisonComplete":raw["comparisonComplete"]==true,"skippedFiles":null,"failedFiles":null});
    for key in &COUNTERS[..17] {
        result[*key] = json!(count(&raw[*key]).unwrap_or(0));
    }
    if version >= 2 {
        for key in &COUNTERS[17..] {
            result[*key] = json!(count(&raw[*key]).unwrap_or(0));
        }
        result["copyByteTotalsAvailable"] = json!(
            raw["copyByteTotalsAvailable"] == true
                && count(&raw["copiedBytes"]).is_some()
                && count(&raw["failedCopyBytes"]).is_some()
        );
    }
    Some(result)
}

/// Remove only the six owned ledgers and fully validated export snapshot names.
/// The first non-missing unlink failure stops this cleanup, as in 0.11.0.
pub fn remove(directory: &Path, id: &str) -> Result<()> {
    valid_id(id)?;
    for (_, suffix) in SUFFIXES {
        crate::storage::remove_file_if_present(&directory.join(format!("{id}{suffix}")))?;
    }
    let prefix = format!("{id}.report-export-");
    for entry in fs::read_dir(directory).map_err(|e| e.to_string())? {
        let entry = entry.map_err(|e| e.to_string())?;
        let name = entry.file_name();
        let Some(tail) = name.to_str().and_then(|n| n.strip_prefix(&prefix)) else {
            continue;
        };
        if let Some((uuid, ext)) = tail.rsplit_once('.') {
            if ["jsonl", "txt"].contains(&ext) && crate::valid_id(uuid) {
                crate::storage::remove_file_if_present(&entry.path())?;
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod encoding_tests {
    use super::*;
    #[test]
    fn foundation_solidus_escaping_keeps_exact_record_byte_offsets() {
        let value = json!({"path":"folder/file.txt","literal":r"before\/after","url":"https://example.invalid/a/b"});
        let encoded = encoded_json(&value).unwrap();
        assert_eq!(serde_json::from_slice::<Value>(&encoded).unwrap(), value);
        let plain = serde_json::to_vec(&value).unwrap();
        assert_eq!(
            encoded.len(),
            plain.len() + plain.iter().filter(|byte| **byte == b'/').count()
        );
        assert!(
            String::from_utf8(encoded)
                .unwrap()
                .contains(r"folder\/file.txt")
        );
    }
}
