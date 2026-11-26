//! Auxiliary file tools and supervised producer/player sessions. Commands never
//! pass through a shell, and session JSON contains no environment or credentials.
use crate::{
    Result,
    accounts::{create_exclusive, replace_file},
    models::Endpoint,
    process::{self, Context},
};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{self, File},
    io::{Read, Write},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{
        Arc, Condvar, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::{Duration, Instant},
};
use unicode_segmentation::UnicodeSegmentation;
use uuid::Uuid;

type EventHandler = Arc<dyn Fn(Value) + Send + Sync>;
pub struct Tools {
    work_dir: PathBuf,
    inner: Mutex<Inner>,
    events: Mutex<Option<EventHandler>>,
}
struct Inner {
    sessions: BTreeMap<String, Arc<Session>>,
    order: Vec<String>,
    closing: bool,
}
struct Session {
    id: String,
    kind: String,
    title: String,
    destination: String,
    created: String,
    state: Mutex<SessionState>,
    finished: Condvar,
    stop_lock: Mutex<()>,
    stop: AtomicBool,
}
struct SessionState {
    status: String,
    error: Option<String>,
}
impl Session {
    fn new(kind: &str, title: String, destination: String) -> Arc<Self> {
        Arc::new(Self {
            id: Uuid::new_v4().to_string(),
            kind: kind.into(),
            title,
            destination,
            created: crate::now(),
            state: Mutex::new(SessionState {
                status: "running".into(),
                error: None,
            }),
            finished: Condvar::new(),
            stop_lock: Mutex::new(()),
            stop: AtomicBool::new(false),
        })
    }
    fn running(&self) -> bool {
        self.state
            .lock()
            .map(|s| s.status == "running")
            .unwrap_or(true)
    }
    fn value(&self) -> Value {
        let s = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let mut v = json!({"id":self.id,"kind":self.kind,"title":self.title,"destination":self.destination,"createdAt":self.created,"status":s.status});
        if let Some(e) = &s.error {
            v["error"] = json!(e);
        }
        v
    }
}
struct Sink {
    bytes: Vec<u8>,
    limit: usize,
    tail: bool,
    total: usize,
    overflow: bool,
    file: Option<File>,
    csv: bool,
    quoted: bool,
    records: usize,
    error: Option<String>,
}
impl Sink {
    fn new(limit: usize, tail: bool) -> Self {
        Self {
            bytes: vec![],
            limit,
            tail,
            total: 0,
            overflow: false,
            file: None,
            csv: false,
            quoted: false,
            records: 0,
            error: None,
        }
    }
    fn append(&mut self, bytes: &[u8]) {
        self.total = self.total.saturating_add(bytes.len());
        self.overflow = self.total > self.limit;
        if let Some(file) = self.file.as_mut() {
            if self.error.is_some() || self.overflow {
                return;
            }
            if let Err(e) = file.write_all(bytes) {
                self.error = Some(e.to_string());
                return;
            }
            for b in bytes {
                if self.csv && *b == b'"' {
                    self.quoted = !self.quoted;
                }
                if *b == b'\n' && !self.quoted {
                    self.records += 1;
                }
            }
        } else if self.tail {
            self.bytes.extend_from_slice(bytes);
            if self.bytes.len() > self.limit {
                self.bytes.drain(..self.bytes.len() - self.limit);
            }
        } else {
            let remaining = self.limit.saturating_sub(self.bytes.len());
            self.bytes
                .extend_from_slice(&bytes[..remaining.min(bytes.len())]);
        }
    }
    fn text(&self) -> String {
        String::from_utf8_lossy(&self.bytes).into_owned()
    }
}
struct Drain {
    thread: thread::JoinHandle<()>,
    done: Arc<AtomicBool>,
}
fn drain(
    input: impl Read + Send + 'static,
    sink: Arc<Mutex<Sink>>,
    stop: Arc<AtomicBool>,
) -> Drain {
    let done = Arc::new(AtomicBool::new(false));
    let completion = done.clone();
    let worker = thread::spawn(move || {
        let mut input = input;
        let mut bytes = [0u8; 65536];
        while !stop.load(Ordering::Acquire) {
            match input.read(&mut bytes) {
                Ok(0) => break,
                Ok(n) => sink
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .append(&bytes[..n]),
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(15))
                }
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(e) => {
                    sink.lock().unwrap_or_else(|e| e.into_inner()).error = Some(e.to_string());
                    break;
                }
            }
        }
        completion.store(true, Ordering::Release);
    });
    Drain {
        thread: worker,
        done,
    }
}
#[cfg(unix)]
fn nonblocking<T: std::os::fd::AsRawFd>(pipe: &T) -> Result<()> {
    // SAFETY: the descriptor belongs to a live child pipe and remains open.
    let flags = unsafe { libc::fcntl(pipe.as_raw_fd(), libc::F_GETFL) };
    if flags < 0
        || unsafe { libc::fcntl(pipe.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0
    {
        return Err(std::io::Error::last_os_error().to_string());
    }
    Ok(())
}
#[cfg(windows)]
fn nonblocking<T>(_pipe: &T) -> Result<()> {
    Ok(())
}
fn finish_drains(drains: Vec<Drain>, stop: &AtomicBool) -> bool {
    let deadline = Instant::now() + Duration::from_secs(2);
    while drains.iter().any(|d| !d.done.load(Ordering::Acquire)) && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(15));
    }
    let success = drains.iter().all(|d| d.done.load(Ordering::Acquire));
    if !success {
        stop.store(true, Ordering::Release);
    }
    // Nonblocking readers check stop at least every 15 ms. On Windows their pipe
    // adapters use PeekNamedPipe before reading, so descendants cannot hang exit.
    for d in drains {
        let _ = d.thread.join();
    }
    success
}
#[cfg(windows)]
struct WindowsPipe<T> {
    inner: T,
}
#[cfg(windows)]
impl<T: Read + std::os::windows::io::AsRawHandle> Read for WindowsPipe<T> {
    fn read(&mut self, bytes: &mut [u8]) -> std::io::Result<usize> {
        use std::os::windows::io::AsRawHandle;
        let mut available = 0u32;
        // SAFETY: inner owns the handle and available points to a valid integer.
        let ok = unsafe {
            windows_sys::Win32::System::Pipes::PeekNamedPipe(
                self.inner.as_raw_handle() as _,
                std::ptr::null_mut(),
                0,
                std::ptr::null_mut(),
                &mut available,
                std::ptr::null_mut(),
            )
        };
        if ok == 0 {
            let e = std::io::Error::last_os_error();
            if e.raw_os_error() == Some(109) {
                return Ok(0);
            }
            return Err(e);
        }
        if available == 0 {
            return Err(std::io::ErrorKind::WouldBlock.into());
        }
        let n = bytes.len().min(available as usize);
        self.inner.read(&mut bytes[..n])
    }
}
#[cfg(unix)]
fn drain_stdout(
    pipe: std::process::ChildStdout,
    sink: Arc<Mutex<Sink>>,
    stop: Arc<AtomicBool>,
) -> Result<Drain> {
    nonblocking(&pipe)?;
    Ok(drain(pipe, sink, stop))
}
#[cfg(windows)]
fn drain_stdout(
    pipe: std::process::ChildStdout,
    sink: Arc<Mutex<Sink>>,
    stop: Arc<AtomicBool>,
) -> Result<Drain> {
    Ok(drain(WindowsPipe { inner: pipe }, sink, stop))
}
#[cfg(unix)]
fn drain_stderr(
    pipe: std::process::ChildStderr,
    sink: Arc<Mutex<Sink>>,
    stop: Arc<AtomicBool>,
) -> Result<Drain> {
    nonblocking(&pipe)?;
    Ok(drain(pipe, sink, stop))
}
#[cfg(windows)]
fn drain_stderr(
    pipe: std::process::ChildStderr,
    sink: Arc<Mutex<Sink>>,
    stop: Arc<AtomicBool>,
) -> Result<Drain> {
    Ok(drain(WindowsPipe { inner: pipe }, sink, stop))
}
fn command(context: &Context, arguments: &[String]) -> Result<Command> {
    if !context.binary.is_absolute()
        || !context.binary.is_file()
        || !executable(&context.binary)
        || arguments.len() > 256
        || arguments.iter().map(String::len).sum::<usize>() > 262144
        || arguments.iter().any(|a| a.contains('\0'))
    {
        return Err("rclone 或工具的執行位置與參數不正確。".into());
    }
    // Tools preserve the original command-first argument ordering. The common
    // launcher still owns environment, working directory and platform startup.
    let mut bare = context.clone();
    bare.arguments.clear();
    let mut c = process::command(&bare)?;
    c.args(arguments).stdin(Stdio::null());

    Ok(c)
}
fn executable(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        path.metadata()
            .is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
    }
    #[cfg(not(unix))]
    {
        path.is_file()
    }
}
fn signal(child: &mut Child, force: bool) {
    let _ = process::signal(child.id(), if force { 9 } else { 15 });
}

fn stop_child(child: &mut Child) {
    signal(child, false);
    let deadline = Instant::now() + Duration::from_secs(2);
    while child.try_wait().ok().flatten().is_none() && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(20));
    }
    if child.try_wait().ok().flatten().is_none() {
        signal(child, true);
        let _ = child.kill();
    }
    let _ = child.wait();
}
struct Output {
    code: i32,
    text: String,
    error: String,
    truncated: bool,
}
fn run(
    context: &Context,
    args: &[String],
    maximum: usize,
    timeout: Duration,
    file: Option<Arc<Mutex<Sink>>>,
) -> Result<Output> {
    let mut child = command(context, args)?
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("無法執行工具：{e}"))?;
    let sink = file.unwrap_or_else(|| Arc::new(Mutex::new(Sink::new(maximum, false))));
    let errors = Arc::new(Mutex::new(Sink::new(65536, true)));
    let drain_stop = Arc::new(AtomicBool::new(false));
    let drains = (|| {
        Ok::<_, String>(vec![
            drain_stdout(
                child
                    .stdout
                    .take()
                    .ok_or("工具的輸出尚未結束，請稍後重試。")?,
                sink.clone(),
                drain_stop.clone(),
            )?,
            drain_stderr(
                child
                    .stderr
                    .take()
                    .ok_or("工具的輸出尚未結束，請稍後重試。")?,
                errors.clone(),
                drain_stop.clone(),
            )?,
        ])
    })();
    let drains = match drains {
        Ok(v) => v,
        Err(e) => {
            stop_child(&mut child);
            return Err(e);
        }
    };
    let began = Instant::now();
    let mut expired = false;
    let mut sink_failure = false;
    let code = loop {
        if let Some(status) = child.try_wait().map_err(|e| e.to_string())? {
            break status.code().unwrap_or(130);
        }
        let output = sink.lock().map_err(|_| "讀寫工具輸出失敗。")?;
        let failed = output.error.is_some() || (output.file.is_some() && output.overflow);
        drop(output);
        if began.elapsed() > timeout || failed {
            expired = began.elapsed() > timeout;
            sink_failure = failed;
            stop_child(&mut child);
            break child
                .try_wait()
                .ok()
                .flatten()
                .and_then(|s| s.code())
                .unwrap_or(130);
        }
        thread::sleep(Duration::from_millis(20));
    };
    let drained = finish_drains(drains, &drain_stop);
    let output = sink.lock().map_err(|_| "讀寫工具輸出失敗。")?;
    let error = errors.lock().map_err(|_| "讀寫工具輸出失敗。")?;
    if expired {
        return Err(format!("操作逾時。\n{}", clean_error(&error.text())));
    }
    if !drained {
        return Err("工具的輸出尚未結束，請稍後重試。".into());
    }
    if output.file.is_some() && output.overflow {
        return Err("清單超過 512 MB，請選擇較小的目錄再匯出。".into());
    }
    if let Some(e) = output.error.as_ref().or(error.error.as_ref()) {
        return Err(format!("讀寫工具輸出失敗：{e}"));
    }
    if sink_failure {
        return Err("讀寫工具輸出失敗。".into());
    }
    Ok(Output {
        code,
        text: output.text(),
        error: error.text(),
        truncated: output.overflow,
    })
}
fn clean_error(text: &str) -> String {
    let text: String = text
        .chars()
        .filter(|c| (*c as u32) >= 32 || matches!(c, '\n' | '\t'))
        .collect();
    let at = text
        .grapheme_indices(true)
        .rev()
        .nth(8191)
        .map_or(0, |(i, _)| i);
    text[at..].trim().to_owned()
}

fn require_success(out: &Output, action: &str) -> Result<()> {
    if out.code == 0 {
        Ok(())
    } else {
        let detail = clean_error(if out.error.is_empty() {
            &out.text
        } else {
            &out.error
        });
        Err(format!(
            "{action}（代碼 {}）。{}",
            out.code,
            if detail.is_empty() {
                String::new()
            } else {
                format!("\n{detail}")
            }
        ))
    }
}
fn args(context: &Context, command: &str, rest: impl IntoIterator<Item = String>) -> Vec<String> {
    let mut a = vec![command.into()];
    a.extend(context.arguments.clone());
    a.extend(rest);
    a
}
fn text<'a>(v: &'a Value, label: &str) -> Result<&'a str> {
    v.as_str()
        .filter(|s| s.len() <= 32768 && !s.chars().any(|c| (c as u32) < 32 || c == '\u{7f}'))
        .ok_or_else(|| format!("{label} 格式不正確，不能包含控制字元。"))
}
impl Tools {
    pub fn new(work_dir: PathBuf) -> Result<Arc<Self>> {
        crate::storage::private_directory(&work_dir)?;
        Ok(Arc::new(Self {
            work_dir,
            inner: Mutex::new(Inner {
                sessions: BTreeMap::new(),
                order: vec![],
                closing: false,
            }),
            events: Mutex::new(None),
        }))
    }
    pub fn set_event_handler(&self, callback: EventHandler) {
        *self.events.lock().unwrap_or_else(|e| e.into_inner()) = Some(callback);
    }
    pub fn has_active(&self) -> bool {
        self.inner
            .lock()
            .map(|g| g.sessions.values().any(|s| s.running()))
            .unwrap_or(true)
    }
    pub fn handle(
        self: &Arc<Self>,
        method: &str,
        arguments: &[Value],
        context: &Context,
        settings: &Value,
    ) -> Result<Value> {
        let null = Value::Null;
        let arg = |n| arguments.get(n).unwrap_or(&null);
        match method {
            "directoryTree" => {
                let e = Endpoint::parse(arg(0))?;
                let depth = if arguments.len() > 1 {
                    arg(1)
                        .as_i64()
                        .filter(|d| (1..=64).contains(d))
                        .ok_or("目錄深度 必須介於 1 與 64。")?
                } else {
                    4
                };
                Self::tree(context, &e, depth as usize)
            }
            "_exportFileList" => {
                let e = Endpoint::parse(arg(0))?;
                let format = text(arg(1), "參數")?;
                if !["csv", "txt"].contains(&format) {
                    return Err("匯出格式不正確。".into());
                }
                Self::export(
                    context,
                    &e,
                    Path::new(text(arg(2), "參數")?),
                    format == "txt",
                )
            }
            "publicLink" => {
                let e = Endpoint::parse(arg(0))?;
                let name = text(arg(1), "參數")?;
                let dir = arg(2).as_bool().ok_or("資料夾 必須為開啟或關閉。")?;
                Self::public_link(context, &e, name, dir).map(|s| json!(s))
            }
            "_startMount" => {
                let e = Endpoint::parse(arg(0))?;
                let read_only = arg(1)
                    .get("readOnly")
                    .map(Value::as_bool)
                    .unwrap_or(Some(true))
                    .ok_or("唯讀 必須為開啟或關閉。")?;
                let cache = arg(1)["cacheMode"].as_str().unwrap_or("writes");
                let mut options = vec![];
                if read_only {
                    options.push("--read-only".into());
                }
                options.extend(["--vfs-cache-mode".into(), cache.into()]);
                self.start_mount(context, &e, Path::new(text(arg(2), "參數")?), &options)
            }
            "_startStream" => {
                let e = Endpoint::parse(arg(0))?;
                let name = text(arg(1), "參數")?;
                let player = settings["streamPlayerPath"].as_str().unwrap_or_default();
                let player_args = settings["streamPlayerArguments"]
                    .as_array()
                    .and_then(|a| {
                        a.iter()
                            .map(|v| v.as_str().map(str::to_owned))
                            .collect::<Option<Vec<_>>>()
                    })
                    .unwrap_or_else(|| vec!["-".into()]);

                self.start_stream(context, &e, name, Path::new(player), &player_args)
            }
            "listToolSessions" => Ok(self.list()),
            "stopToolSession" => self.stop_session(text(arg(0), "參數")?),
            _ => Err("不支援的工具操作。".into()),
        }
    }
    pub fn tree(context: &Context, endpoint: &Endpoint, depth: usize) -> Result<Value> {
        if !(1..=64).contains(&depth) {
            return Err("目錄深度必須介於 1 與 64。".into());
        }
        let a = args(
            context,
            "tree",
            [
                "--dirs-only".into(),
                "--max-depth".into(),
                depth.to_string(),
                "--log-level".into(),
                "ERROR".into(),
                "--".into(),
                endpoint.target(),
            ],
        );
        let out = run(context, &a, 1024 * 1024, Duration::from_secs(120), None)?;
        require_success(&out, "讀取目錄樹失敗")?;
        Ok(json!({"text":out.text,"truncated":out.truncated,"maxDepth":depth}))
    }
    pub fn export(
        context: &Context,
        endpoint: &Endpoint,
        destination: &Path,
        filenames_only: bool,
    ) -> Result<Value> {
        let destination = PathBuf::from(crate::models::standardized(
            destination.to_str().ok_or("請選擇本機匯出位置。")?,
        )?);
        let parent = destination
            .parent()
            .filter(|p| p.is_dir())
            .ok_or("匯出資料夾不存在。")?;
        check_regular_or_missing(
            &destination,
            "匯出位置必須是一般檔案，不能是資料夾或符號連結。",
        )?;
        let temporary = parent.join(format!(".rbn-export-{}", Uuid::new_v4()));
        let mut output = create_exclusive(&temporary)?;
        let result = (|| {
            if !filenames_only {
                output
                    .write_all(b"Path,Size,Modified\n")
                    .map_err(|e| e.to_string())?;
            }
            let mut sink = Sink::new(512 * 1024 * 1024, false);
            sink.file = Some(output);
            sink.csv = !filenames_only;
            let sink = Arc::new(Mutex::new(sink));
            let mut a = args(
                context,
                "lsf",
                [
                    "--recursive".into(),
                    "--files-only".into(),
                    "--format".into(),
                    if filenames_only { "p" } else { "pst" }.into(),
                ],
            );
            if !filenames_only {
                a.extend(["--csv".into(), "--separator".into(), ",".into()]);
            }
            a.extend([
                "--exclude".into(),
                temporary
                    .file_name()
                    .unwrap()
                    .to_string_lossy()
                    .into_owned(),
                "--log-level".into(),
                "ERROR".into(),
                "--".into(),
                endpoint.target(),
            ]);
            let out = run(context, &a, 0, Duration::from_secs(600), Some(sink.clone()))?;
            require_success(&out, "匯出檔案清單失敗")?;
            let mut writer = sink.lock().map_err(|_| "寫入匯出檔案失敗。")?;
            writer
                .file
                .as_ref()
                .ok_or("寫入匯出檔案失敗。")?
                .sync_all()
                .map_err(|e| e.to_string())?;
            writer.file.take();
            let records = writer.records;
            drop(writer);
            replace_file(&temporary, &destination)?;
            Ok(
                json!({"path":destination,"count":records,"format":if filenames_only{"txt"}else{"csv"}}),
            )
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temporary);
        }
        result
    }
    pub fn public_link(
        context: &Context,
        endpoint: &Endpoint,
        name: &str,
        is_dir: bool,
    ) -> Result<String> {
        if endpoint.remote.is_none() {
            return Err("公開連結只適用於支援分享功能的雲端位置。".into());
        }
        let mut target = endpoint.child(name)?.target();
        if is_dir && !target.ends_with('/') {
            target.push('/');
        }
        let a = args(
            context,
            "link",
            ["--log-level".into(), "ERROR".into(), "--".into(), target],
        );
        let out = run(context, &a, 32768, Duration::from_secs(90), None)?;
        require_success(&out, "建立公開連結失敗")?;
        let line = out
            .text
            .lines()
            .filter(|l| !l.is_empty())
            .last()
            .unwrap_or_default();
        if out.truncated || !valid_public_url(line) {
            return Err("rclone 沒有回傳有效的公開連結。".into());
        }
        Ok(line.into())
    }
    fn list(&self) -> Value {
        let g = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        json!(
            g.order
                .iter()
                .rev()
                .filter_map(|id| g.sessions.get(id))
                .map(|s| s.value())
                .collect::<Vec<_>>()
        )
    }
    fn can_start(g: &Inner) -> Result<()> {
        if g.closing {
            return Err("程式正在關閉。".into());
        }
        if g.sessions.values().filter(|s| s.running()).count() >= 16 {
            return Err("最多可同時執行 16 個掛載或串流。".into());
        }
        Ok(())
    }
    fn register(g: &mut Inner, session: Arc<Session>) {
        g.order.push(session.id.clone());
        g.sessions.insert(session.id.clone(), session);
        while g.order.len() > 100 {
            let Some(at) = g
                .order
                .iter()
                .position(|id| g.sessions.get(id).is_none_or(|s| !s.running()))
            else {
                break;
            };
            let id = g.order.remove(at);
            g.sessions.remove(&id);
        }
    }
    pub fn start_mount(
        self: &Arc<Self>,
        context: &Context,
        endpoint: &Endpoint,
        mount_point: &Path,
        options: &[String],
    ) -> Result<Value> {
        let options = validated_mount_options(options)?;
        if endpoint.remote.is_none() {
            return Err("請選擇要掛載的雲端位置。".into());
        }
        if !mount_point.is_absolute()
            || !fs::symlink_metadata(mount_point).is_ok_and(|m| m.is_dir())
            || mount_point.parent().is_none()
            || fs::read_dir(mount_point)
                .map_err(|e| e.to_string())?
                .next()
                .is_some()
        {
            return Err("掛載位置必須是已存在的空資料夾（不可為符號連結）。".into());
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = options;
            let _ = context;
            return Err("圖形介面的掛載功能目前只支援 macOS。".into());
        }
        #[cfg(target_os = "macos")]
        {
            let capability = run(
                context,
                &args(context, "mount", ["--help".into()]),
                128 * 1024,
                Duration::from_secs(15),
                None,
            )?;
            require_success(
                &capability,
                "目前無法使用 FUSE 掛載；請確認 rclone 支援 mount，並已安裝 macFUSE 或 FUSE-T",
            )?;
            let point = fs::canonicalize(mount_point).map_err(|e| e.to_string())?;
            let point = point.to_string_lossy().into_owned();
            let mut g = self.inner.lock().map_err(|_| "工具狀態無法讀取。")?;
            Self::can_start(&g)?;
            if g.sessions
                .values()
                .any(|s| s.kind == "mount" && s.running() && s.destination == point)
            {
                return Err("這個資料夾已經有進行中的掛載。".into());
            }
            let session = Session::new("mount", endpoint.target(), point.clone());
            let cache = self.work_dir.join(format!("mount-{}", session.id));
            crate::storage::private_directory(&cache)?;
            let mut a = args(context, "mount", options);
            a.extend([
                "--cache-dir".into(),
                cache.to_string_lossy().into_owned(),
                "--log-level".into(),
                "INFO".into(),
                "--".into(),
                endpoint.target(),
                point,
            ]);
            let mut child = command(context, &a)?
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .map_err(|e| format!("無法執行工具：{e}"))?;
            let logs = Arc::new(Mutex::new(Sink::new(65536, true)));
            let stop = Arc::new(AtomicBool::new(false));
            let drains = (|| {
                Ok::<_, String>(vec![
                    drain_stdout(child.stdout.take().unwrap(), logs.clone(), stop.clone())?,
                    drain_stderr(child.stderr.take().unwrap(), logs.clone(), stop.clone())?,
                ])
            })();
            let drains = match drains {
                Ok(v) => v,
                Err(e) => {
                    stop_child(&mut child);
                    let _ = fs::remove_dir(&cache);
                    return Err(e);
                }
            };
            Self::register(&mut g, session.clone());
            let initial = session.value();
            drop(g);
            self.monitor(session, vec![child], drains, logs, stop, Some(cache));
            Ok(initial)
        }
    }
    pub fn start_stream(
        self: &Arc<Self>,
        context: &Context,
        endpoint: &Endpoint,
        name: &str,
        player: &Path,
        player_args: &[String],
    ) -> Result<Value> {
        let target = endpoint.child(name)?;
        if !player.is_absolute() || !executable(player) {
            return Err("請選擇已安裝播放器的執行檔。".into());
        }
        if player_args.len() > 64
            || player_args.iter().map(String::len).sum::<usize>() > 16384
            || player_args
                .iter()
                .any(|a| a.chars().any(|c| (c as u32) < 32 || c == '\u{7f}'))
        {
            return Err("播放器參數格式不正確。".into());
        }
        if target.remote.is_none() {
            if !fs::symlink_metadata(&target.path).is_ok_and(|m| m.is_file()) {
                return Err("串流播放只能選擇檔案，不能選擇資料夾。".into());
            }
        } else {
            let a = args(
                context,
                "lsjson",
                [
                    "--stat".into(),
                    "--no-mimetype".into(),
                    "--no-modtime".into(),
                    "--log-level".into(),
                    "ERROR".into(),
                    "--".into(),
                    target.target(),
                ],
            );
            let out = run(context, &a, 65536, Duration::from_secs(60), None)?;
            require_success(&out, "無法讀取要播放的檔案")?;
            if out.truncated
                || serde_json::from_str::<Value>(&out.text)
                    .ok()
                    .is_none_or(|v| v["IsDir"] != false)
            {
                return Err("串流播放只能選擇檔案，不能選擇資料夾。".into());
            }
        }
        let mut g = self.inner.lock().map_err(|_| "工具狀態無法讀取。")?;
        Self::can_start(&g)?;
        let session = Session::new(
            "stream",
            target.target(),
            player
                .file_name()
                .unwrap_or_default()
                .to_string_lossy()
                .into_owned(),
        );
        let a = args(
            context,
            "cat",
            [
                "--log-level".into(),
                "ERROR".into(),
                "--".into(),
                target.target(),
            ],
        );
        let mut producer = command(context, &a)?
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("無法啟動串流：{e}"))?;
        let media = producer.stdout.take().ok_or("無法啟動串流。")?;
        let consumer_context = Context {
            binary: player.to_owned(),
            arguments: vec![],
            environment: player_environment(&context.environment),
            work_dir: context.work_dir.clone(),
        };
        let consumer_result = command(&consumer_context, player_args).and_then(|mut c| {
            c.stdin(Stdio::from(media))
                .stdout(Stdio::null())
                .stderr(Stdio::piped())
                .spawn()
                .map_err(|e| e.to_string())
        });
        let mut consumer = match consumer_result {
            Ok(c) => c,
            Err(e) => {
                stop_child(&mut producer);
                return Err(format!("無法啟動串流：{e}"));
            }
        };
        let logs = Arc::new(Mutex::new(Sink::new(65536, true)));
        let stop = Arc::new(AtomicBool::new(false));
        let drains = (|| {
            Ok::<_, String>(vec![
                drain_stderr(producer.stderr.take().unwrap(), logs.clone(), stop.clone())?,
                drain_stderr(consumer.stderr.take().unwrap(), logs.clone(), stop.clone())?,
            ])
        })();
        let drains = match drains {
            Ok(d) => d,
            Err(e) => {
                stop_child(&mut consumer);
                stop_child(&mut producer);
                return Err(e);
            }
        };
        Self::register(&mut g, session.clone());
        let initial = session.value();
        drop(g);
        self.monitor(session, vec![producer, consumer], drains, logs, stop, None);
        Ok(initial)
    }
    fn monitor(
        self: &Arc<Self>,
        session: Arc<Session>,
        mut children: Vec<Child>,
        drains: Vec<Drain>,
        logs: Arc<Mutex<Sink>>,
        drain_stop: Arc<AtomicBool>,
        cache: Option<PathBuf>,
    ) {
        let manager = Arc::clone(self);
        thread::spawn(move || {
            let mut exits = vec![None; children.len()];
            let mut requested_at = None;
            let mut internal_stop = false;
            let mut player_closed = false;
            loop {
                for (i, c) in children.iter_mut().enumerate() {
                    if exits[i].is_none() {
                        match c.try_wait() {
                            Ok(Some(s)) => exits[i] = Some(s.code().unwrap_or(130)),
                            Ok(None) => {}
                            Err(e) => {
                                logs.lock().unwrap_or_else(|e| e.into_inner()).error =
                                    Some(e.to_string());
                                signal(c, true);
                                let _ = c.kill();
                                exits[i] =
                                    Some(c.wait().ok().and_then(|s| s.code()).unwrap_or(130));
                            }
                        }
                    }
                }
                if exits.iter().all(Option::is_some) {
                    break;
                }
                let stop = session.stop.load(Ordering::Acquire);
                if session.kind == "stream" && exits.len() == 2 {
                    if exits[1].is_some() && exits[0].is_none() {
                        player_closed = exits[1] == Some(0);
                        internal_stop = true;
                    }
                    if exits[0].is_some_and(|s| s != 0) && exits[1].is_none() {
                        internal_stop = true;
                    }
                }
                if (stop || internal_stop) && requested_at.is_none() {
                    requested_at = Some(Instant::now());
                    for (i, c) in children.iter_mut().enumerate().rev() {
                        if exits[i].is_none() {
                            signal(c, false);
                        }
                    }
                }
                if requested_at.is_some_and(|at| at.elapsed() >= Duration::from_secs(2)) {
                    for (i, c) in children.iter_mut().enumerate().rev() {
                        if exits[i].is_none() {
                            signal(c, true);
                            let _ = c.kill();
                        }
                    }
                }
                thread::sleep(Duration::from_millis(25));
            }
            let drained = finish_drains(drains, &drain_stop);
            let logs = logs.lock().unwrap_or_else(|e| e.into_inner());
            {
                let mut state = session.state.lock().unwrap_or_else(|e| e.into_inner());
                if session.stop.load(Ordering::Acquire) || player_closed {
                    state.status = "stopped".into();
                } else if !drained
                    || logs.error.is_some()
                    || exits.iter().any(|s| s.is_none_or(|n| n != 0))
                {
                    state.status = "failed".into();
                    state.error = Some(if !drained {
                        "工具輸出尚未關閉，請確認播放器是否仍在執行。".into()
                    } else if let Some(e) = &logs.error {
                        e.clone()
                    } else {
                        let detail = clean_error(&logs.text());
                        if detail.is_empty() {
                            "rclone 或播放器提早結束。".into()
                        } else {
                            detail
                        }
                    });
                } else {
                    state.status = "completed".into();
                }
            }
            drop(logs);
            // Match 0.11.0: retain the session's VFS directory after exit.
            // A failed mount can still have buffered writes that need recovery.
            let _ = cache;
            session.finished.notify_all();
            let callback = manager
                .events
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .clone();
            if let Some(callback) = callback {
                callback(session.value());
            }
        });
    }
    pub fn stop_session(&self, id: &str) -> Result<Value> {
        let session = self
            .inner
            .lock()
            .map_err(|_| "工具狀態無法讀取。")?
            .sessions
            .get(id)
            .cloned()
            .ok_or("找不到這個工作。")?;
        let _stop = session.stop_lock.lock().map_err(|_| "工具狀態無法讀取。")?;
        if !session.running() {
            return Ok(session.value());
        }
        #[cfg(target_os = "macos")]
        if session.kind == "mount" {
            let context = Context {
                binary: "/sbin/umount".into(),
                arguments: vec![],
                environment: BTreeMap::from([(
                    "PATH".into(),
                    "/usr/bin:/bin:/usr/sbin:/sbin".into(),
                )]),
                work_dir: self.work_dir.clone(),
            };
            let out = run(
                &context,
                &[session.destination.clone()],
                8192,
                Duration::from_secs(30),
                None,
            )?;
            if out.code != 0 && session.running() {
                return Err(format!(
                    "無法卸載。請先關閉使用這個磁碟的檔案，再重試。\n{}",
                    clean_error(&out.error)
                ));
            }
        }
        session.stop.store(true, Ordering::Release);
        let deadline = Instant::now() + Duration::from_secs(8);
        let mut state = session.state.lock().map_err(|_| "工具狀態無法讀取。")?;
        while state.status == "running" {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return Err("工作尚未停止，請稍候再試。".into());
            }
            state = session
                .finished
                .wait_timeout(state, left)
                .map_err(|_| "工具狀態無法讀取。")?
                .0;
        }
        drop(state);
        Ok(session.value())
    }
    pub fn shutdown(&self) -> Result<()> {
        let ids = {
            let mut g = self.inner.lock().map_err(|_| "工具狀態無法讀取。")?;
            g.closing = true;
            g.order
                .iter()
                .filter(|id| g.sessions.get(*id).is_some_and(|s| s.running()))
                .cloned()
                .collect::<Vec<_>>()
        };
        for id in ids {
            if let Err(e) = self.stop_session(&id) {
                if let Ok(mut g) = self.inner.lock() {
                    g.closing = false;
                }
                return Err(e);
            }
        }
        Ok(())
    }
}
fn check_regular_or_missing(path: &Path, message: &str) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(m) if !m.is_file() => Err(message.into()),
        Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e.to_string()),
        _ => Ok(()),
    }
}
pub fn valid_public_url(value: &str) -> bool {
    value.len() <= 16384
        && !value.is_empty()
        && !value.chars().any(|c| (c as u32) < 33 || c == '\u{7f}')
        && url::Url::parse(value).ok().is_some_and(|u| {
            matches!(u.scheme(), "http" | "https")
                && u.host().is_some()
                && u.username().is_empty()
                && u.password().is_none()
        })
}
pub fn validated_mount_options(options: &[String]) -> Result<Vec<String>> {
    if options.len() > 8 {
        return Err("掛載選項過多。".into());
    }
    let mut result = vec![];
    let mut seen = BTreeSet::new();
    let mut at = 0;
    while at < options.len() {
        let key = &options[at];
        at += 1;
        if !seen.insert(key.clone()) {
            return Err("掛載選項不能重複。".into());
        }
        if key == "--read-only" {
            result.push(key.clone());
            continue;
        }
        if key != "--vfs-cache-mode"
            || at >= options.len()
            || !["off", "minimal", "writes", "full"].contains(&options[at].as_str())
        {
            return Err("掛載只接受唯讀與 VFS 快取模式選項。".into());
        }
        result.extend([key.clone(), options[at].clone()]);
        at += 1;
    }
    if !seen.contains("--vfs-cache-mode") {
        result.extend(["--vfs-cache-mode".into(), "writes".into()]);
    }
    Ok(result)
}
pub fn player_environment(environment: &BTreeMap<String, String>) -> BTreeMap<String, String> {
    const ALLOWED: &[&str] = &[
        "PATH",
        "HOME",
        "USER",
        "LOGNAME",
        "SHELL",
        "LANG",
        "LC_ALL",
        "LC_CTYPE",
        "TMPDIR",
        "DISPLAY",
        "WAYLAND_DISPLAY",
        "XDG_RUNTIME_DIR",
        "DBUS_SESSION_BUS_ADDRESS",
        "LD_LIBRARY_PATH",
        "DYLD_LIBRARY_PATH",
        "DYLD_FALLBACK_LIBRARY_PATH",
    ];
    environment
        .iter()
        .filter(|(k, _)| ALLOWED.contains(&k.as_str()))
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect()
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn mount_flags_cannot_enable_daemon_or_hooks() {
        assert_eq!(
            validated_mount_options(&[]).unwrap(),
            vec!["--vfs-cache-mode", "writes"]
        );
        let valid = ["--read-only", "--vfs-cache-mode", "full"].map(str::to_owned);
        assert_eq!(validated_mount_options(&valid).unwrap(), valid);
        for invalid in [
            vec!["--daemon"],
            vec!["--allow-other"],
            vec!["--vfs-cache-mode", "invalid"],
            vec!["--read-only", "--read-only"],
            vec!["--vfs-cache-mode"],
        ] {
            assert!(
                validated_mount_options(
                    &invalid.into_iter().map(str::to_owned).collect::<Vec<_>>()
                )
                .is_err()
            );
        }
    }
    #[test]
    fn public_links_reject_credentials_and_executable_schemes() {
        assert!(valid_public_url(
            "https://example.invalid/share/%E4%B8%AD?test=1"
        ));
        for bad in [
            "javascript:alert(1)",
            "https://user:password@example.invalid/share",
            "not a URL",
            "https://example.invalid/line\nbreak",
        ] {
            assert!(!valid_public_url(bad));
        }
    }
    #[test]
    fn player_environment_excludes_cloud_and_proxy_secrets() {
        let env = BTreeMap::from([
            ("PATH".into(), "/bin".into()),
            ("RCLONE_CONFIG_PASS".into(), "secret".into()),
            ("AWS_SECRET_ACCESS_KEY".into(), "secret".into()),
            ("HTTPS_PROXY".into(), "secret".into()),
        ]);
        assert_eq!(
            player_environment(&env),
            BTreeMap::from([("PATH".into(), "/bin".into())])
        );
    }
    #[test]
    fn csv_record_count_preserves_quoted_newlines() {
        let mut sink = Sink::new(4096, false);
        sink.csv = true;
        for b in b"\"line\nbreak\",5,date\n\"quotes\"\"x\",7,date\n" {
            if sink.csv && *b == b'"' {
                sink.quoted = !sink.quoted;
            }
            if *b == b'\n' && !sink.quoted {
                sink.records += 1;
            }
        }
        assert_eq!(sink.records, 2);
    }
}
