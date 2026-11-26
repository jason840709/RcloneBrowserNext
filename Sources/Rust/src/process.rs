//! Shell-free child execution. Both pipes are drained independently; a cancelled
//! operation is not finished until its child has exited and the pipes are closed.
use crate::Result;
use std::{
    collections::BTreeMap,
    io::{Read, Write},
    path::PathBuf,
    process::{Command, Stdio},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU32, AtomicUsize, Ordering},
        mpsc,
    },
    thread,
    time::{Duration, Instant},
};

#[derive(Clone, Debug)]
pub struct Context {
    pub binary: PathBuf,
    pub arguments: Vec<String>,
    pub environment: BTreeMap<String, String>,
    pub work_dir: PathBuf,
}
#[derive(Debug)]
pub struct Output {
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub exit_code: i32,
    pub forced: bool,
    pub last_signal: Option<i32>,
}
impl Output {
    pub fn checked(self) -> Result<Self> {
        if self.exit_code == 0 {
            Ok(self)
        } else {
            let raw = String::from_utf8_lossy(&self.stderr);
            let lines = raw
                .split('\n')
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>();
            let detail = lines
                .iter()
                .rev()
                .take(8)
                .rev()
                .map(|line| {
                    serde_json::from_str::<serde_json::Value>(line)
                        .ok()
                        .and_then(|row| {
                            row["msg"]
                                .as_str()
                                .or(row["error"].as_str())
                                .map(str::to_owned)
                        })
                        .unwrap_or_else(|| line.to_string())
                })
                .collect::<Vec<_>>()
                .join("\n");
            let detail =
                unicode_segmentation::UnicodeSegmentation::graphemes(detail.as_str(), true)
                    .rev()
                    .take(8000)
                    .collect::<Vec<_>>()
                    .into_iter()
                    .rev()
                    .collect::<String>();
            Err(format!(
                "rclone 執行失敗（代碼 {}）{}",
                self.exit_code,
                if detail.is_empty() {
                    "。".into()
                } else {
                    format!("：\n{detail}")
                }
            ))
        }
    }
    pub fn json(self) -> Result<serde_json::Value> {
        let value = self.checked()?;
        crate::storage::decode_json_bytes(&value.stdout)
            .map_err(|e| format!("rclone 回傳的資料格式不正確：{e}"))
    }
}
pub type LineHandler = Arc<dyn Fn(&str, bool, bool) -> Result<()> + Send + Sync>;
pub type StopHandler = Arc<dyn Fn(i32) + Send + Sync>;
const ENGINE_TIMEOUT: &str = "rclone 回應逾時，請檢查連線後重試。";
const UPDATER_TIMEOUT: &str = "rclone 作業逾時，原本的版本保持不變。";
const UPDATER_PIPE_TIMEOUT: &str = "rclone 已結束，但輸出尚未關閉，已停止更新。";
#[derive(Clone, Copy, PartialEq, Eq)]
enum Caller {
    Engine,
    Cooperative,
    Updater,
}
#[derive(Clone, Copy)]
struct RunPolicy {
    timeout: Option<Duration>,
    caller: Caller,
}

fn failure(slot: &Mutex<Option<String>>, message: String) {
    if let Ok(mut s) = slot.lock() {
        if s.is_none() {
            *s = Some(message);
        }
    }
}
fn drain(
    mut input: impl Read,
    stderr: bool,
    maximum: usize,
    total: Arc<AtomicUsize>,
    error: Arc<Mutex<Option<String>>>,
    handler: Option<LineHandler>,
    truncate: bool,
) -> Vec<u8> {
    let mut kept = Vec::new();
    let mut pending = Vec::new();
    let mut chunk = [0; 16384];
    loop {
        let length = match input.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) => {
                failure(&error, format!("無法讀取 rclone 輸出：{e}"));
                break;
            }
        };
        if truncate {
            let remaining = maximum.saturating_sub(kept.len());
            kept.extend_from_slice(&chunk[..length.min(remaining)]);
        } else if handler.is_none() {
            let before = total.fetch_add(length, Ordering::Relaxed);
            if before.saturating_add(length) > maximum {
                failure(
                    &error,
                    "目錄資料超過單次可載入大小，請進入較小的資料夾。".into(),
                );
            } else {
                kept.extend_from_slice(&chunk[..length]);
            }
        } else {
            kept.extend_from_slice(&chunk[..length]);
            if kept.len() > 65536 {
                kept.drain(..kept.len() - 65536);
            }
        }
        if let Some(ref callback) = handler {
            // Match the reference's chunk/newline consumption, then clear an
            // oversized unfinished fragment instead of delivering a truncated line.
            pending.extend_from_slice(&chunk[..length]);
            while let Some(newline) = pending.iter().position(|b| *b == b'\n') {
                if let Err(e) =
                    callback(&String::from_utf8_lossy(&pending[..newline]), stderr, true)
                {
                    failure(&error, e);
                }
                pending.drain(..=newline);
            }
            if pending.len() > 2 * 1024 * 1024 {
                failure(&error, "rclone 單行輸出過大，工作已停止。".into());
                pending.clear();
            }
        }
    }
    if !pending.is_empty() {
        if let Some(callback) = handler {
            if let Err(e) = callback(&String::from_utf8_lossy(&pending), stderr, false) {
                failure(&error, e);
            }
        }
    }
    kept
}

pub fn capture(
    context: &Context,
    arguments: &[String],
    maximum: usize,
    timeout: Duration,
    cancelled: Option<&AtomicBool>,
) -> Result<Output> {
    run_inner(
        context,
        arguments,
        maximum,
        RunPolicy {
            timeout: Some(timeout),
            caller: Caller::Engine,
        },
        cancelled,
        None,
        None,
        None,
        None,
    )
}
/// The updater keeps each pipe's prefix and drains the remainder. Its timeout
/// uses the reference updater's TERM/2-second/KILL sequence, never job SIGINT.
pub fn capture_updater(
    context: &Context,
    arguments: &[String],
    maximum: usize,
    timeout: Duration,
) -> Result<Output> {
    run_inner(
        context,
        arguments,
        maximum,
        RunPolicy {
            timeout: Some(timeout),
            caller: Caller::Updater,
        },
        None,
        None,
        None,
        None,
        None,
    )
}
pub fn capture_input(
    context: &Context,
    arguments: &[String],
    input: &[u8],
    maximum: usize,
    timeout: Duration,
    cancelled: Option<&AtomicBool>,
) -> Result<Output> {
    if input.len() > 1024 * 1024 {
        return Err("程序輸入過大。".into());
    }
    run_inner(
        context,
        arguments,
        maximum,
        RunPolicy {
            timeout: Some(timeout),
            caller: Caller::Cooperative,
        },
        cancelled,
        None,
        Some(input),
        None,
        None,
    )
}
pub fn run(
    context: &Context,
    arguments: &[String],
    maximum: usize,
    timeout: Option<Duration>,
    cancelled: Option<&AtomicBool>,
    handler: Option<LineHandler>,
) -> Result<Output> {
    run_inner(
        context,
        arguments,
        maximum,
        RunPolicy {
            timeout,
            caller: Caller::Cooperative,
        },
        cancelled,
        handler,
        None,
        None,
        None,
    )
}
pub fn run_with_stop_observer(
    context: &Context,
    arguments: &[String],
    maximum: usize,
    timeout: Option<Duration>,
    cancelled: Option<&AtomicBool>,
    handler: Option<LineHandler>,
    observer: StopHandler,
) -> Result<Output> {
    run_inner(
        context,
        arguments,
        maximum,
        RunPolicy {
            timeout,
            caller: Caller::Cooperative,
        },
        cancelled,
        handler,
        None,
        None,
        Some(observer),
    )
}
pub fn capture_listing(
    context: &Context,
    arguments: &[String],
    maximum: usize,
    deadline: Instant,
    cancelled: &AtomicBool,
    pid: &AtomicU32,
    timed_out: &AtomicBool,
) -> Result<Output> {
    if cancelled.load(Ordering::Acquire) {
        return Err("目錄讀取已取消。".into());
    }
    let timeout = deadline.saturating_duration_since(Instant::now());
    if timeout.is_zero() {
        timed_out.store(true, Ordering::Release);
        return Err("rclone 回應逾時，請檢查連線後重試。".into());
    }
    run_inner(
        context,
        arguments,
        maximum,
        RunPolicy {
            timeout: Some(timeout),
            caller: Caller::Engine,
        },
        Some(cancelled),
        None,
        None,
        Some((pid, timed_out)),
        None,
    )
}
struct ChildRegistration<'a>(Option<&'a AtomicU32>);
impl Drop for ChildRegistration<'_> {
    fn drop(&mut self) {
        if let Some(pid) = self.0 {
            pid.store(0, Ordering::Release);
        }
    }
}
fn run_inner(
    context: &Context,
    arguments: &[String],
    maximum: usize,
    policy: RunPolicy,
    cancelled: Option<&AtomicBool>,
    handler: Option<LineHandler>,
    input: Option<&[u8]>,
    listing: Option<(&AtomicU32, &AtomicBool)>,
    observer: Option<StopHandler>,
) -> Result<Output> {
    if cancelled.is_some_and(|c| c.load(Ordering::Acquire)) {
        return Err("已取消。".into());
    }
    let mut command = command(context)?;
    command
        .args(arguments)
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = command.spawn().map_err(|e| {
        if policy.caller == Caller::Updater {
            let name = context
                .binary
                .file_name()
                .unwrap_or(context.binary.as_os_str())
                .to_string_lossy();
            format!("無法執行 {name}：{e}")
        } else {
            format!("無法啟動 rclone：{e}")
        }
    })?;
    let pid = child.id();
    let _registration = ChildRegistration(listing.map(|(pid, _)| pid));
    if let Some((child, _)) = listing {
        child.store(pid, Ordering::Release);
    }
    let stdin = child.stdin.take();
    let stdout = child.stdout.take().ok_or("無法讀取 rclone 輸出。")?;
    let stderr = child.stderr.take().ok_or("無法讀取 rclone 錯誤記錄。")?;
    let failure_slot = Arc::new(Mutex::new(None));
    let total = Arc::new(AtomicUsize::new(0));
    thread::scope(|scope| {
        let input_worker = scope.spawn(move || {
            if let (Some(mut pipe), Some(bytes)) = (stdin, input) {
                pipe.write_all(bytes).map_err(|e| e.to_string())
            } else {
                Ok(())
            }
        });
        let t = total.clone();
        let f = failure_slot.clone();
        let h = handler.clone();
        let truncate = policy.caller == Caller::Updater;
        let (out_sender, out_receiver) = mpsc::sync_channel(1);
        let out = thread::spawn(move || {
            let bytes = drain(stdout, false, maximum, t, f, h, truncate);
            let _ = out_sender.send(bytes);
        });
        let t = total.clone();
        let f = failure_slot.clone();
        let (err_sender, err_receiver) = mpsc::sync_channel(1);
        let err = thread::spawn(move || {
            let bytes = drain(stderr, true, maximum, t, f, handler, truncate);
            let _ = err_sender.send(bytes);
        });
        let began = Instant::now();
        let mut stopped: Option<Instant> = None;
        let mut stage = 0;
        let mut timed_out = false;
        let exit = loop {
            match child.try_wait() {
                Ok(Some(status)) => break status,
                Ok(None) => {}
                Err(e) => {
                    failure(&failure_slot, format!("無法確認 rclone 狀態：{e}"));
                }
            }
            let expired = policy.timeout.is_some_and(|t| began.elapsed() >= t);
            let io_failed = failure_slot.lock().map(|v| v.is_some()).unwrap_or(true);
            if stopped.is_none()
                && (expired || io_failed || cancelled.is_some_and(|c| c.load(Ordering::Acquire)))
            {
                timed_out = expired && !cancelled.is_some_and(|c| c.load(Ordering::Acquire));
                if timed_out {
                    if let Some((_, flag)) = listing {
                        flag.store(true, Ordering::Release);
                    }
                }
                stopped = Some(Instant::now());
                let first_signal =
                    if timed_out && listing.is_none() && policy.caller == Caller::Engine {
                        // The ordinary engine timer fails the output buffer and kills
                        // immediately; cancellation/IO failures retain cooperative stop.
                        failure(&failure_slot, ENGINE_TIMEOUT.into());
                        9
                    } else if timed_out && policy.caller == Caller::Updater {
                        15
                    } else {
                        2
                    };
                stage = match first_signal {
                    9 => 3,
                    15 => 2,
                    _ => 1,
                };
                let _ = signal(pid, first_signal);
                if let Some(observer) = &observer {
                    observer(first_signal);
                }
            }
            if let Some(at) = stopped {
                if stage == 1
                    && at.elapsed()
                        >= if listing.is_some() {
                            Duration::from_secs(1)
                        } else {
                            Duration::from_secs(10)
                        }
                {
                    let _ = signal(pid, 15);
                    stage = 2;
                    if let Some(observer) = &observer {
                        observer(15);
                    }
                }
                if stage == 2
                    && at.elapsed()
                        >= if listing.is_some() {
                            Duration::from_millis(1500)
                        } else if timed_out && policy.caller == Caller::Updater {
                            Duration::from_secs(2)
                        } else {
                            Duration::from_secs(12)
                        }
                {
                    let _ = signal(pid, 9);
                    stage = 3;
                    if let Some(observer) = &observer {
                        observer(9);
                    }
                }
            }
            thread::sleep(Duration::from_millis(20));
        };
        let input_result = input_worker.join();
        let (stdout, stderr) = if policy.caller == Caller::Updater {
            // A descendant can keep a pipe open after the owned child exits.
            // Readers own their buffers/handles; a failed bounded wait never reads
            // concurrently mutated state. Other callers still join to true EOF.
            let deadline = Instant::now() + Duration::from_secs(5);
            let message = if timed_out {
                UPDATER_TIMEOUT
            } else {
                UPDATER_PIPE_TIMEOUT
            };
            let stdout = out_receiver
                .recv_timeout(deadline.saturating_duration_since(Instant::now()))
                .map_err(|_| message)?;
            let stderr = err_receiver
                .recv_timeout(deadline.saturating_duration_since(Instant::now()))
                .map_err(|_| message)?;
            out.join().map_err(|_| "rclone 輸出讀取工作中斷。")?;
            err.join().map_err(|_| "rclone 錯誤記錄讀取工作中斷。")?;
            (stdout, stderr)
        } else {
            // Join both even if one handler panics: cooperative operations
            // still wait for their other owned pipe to reach true EOF.
            let out_result = out.join();
            let err_result = err.join();
            out_result.map_err(|_| "rclone 輸出讀取工作中斷。")?;
            err_result.map_err(|_| "rclone 錯誤記錄讀取工作中斷。")?;
            (
                out_receiver
                    .recv()
                    .map_err(|_| "rclone 輸出讀取工作中斷。")?,
                err_receiver
                    .recv()
                    .map_err(|_| "rclone 錯誤記錄讀取工作中斷。")?,
            )
        };
        let _ = input_result.map_err(|_| "rclone 輸入工作中斷。")?;
        if timed_out && policy.caller == Caller::Updater {
            return Err(UPDATER_TIMEOUT.into());
        }
        if let Some(e) = failure_slot
            .lock()
            .map_err(|_| "rclone 記錄狀態無法讀取。")?
            .take()
        {
            return Err(e);
        }
        if timed_out {
            return Err(ENGINE_TIMEOUT.into());
        }
        #[cfg(unix)]
        let exit_code = {
            use std::os::unix::process::ExitStatusExt;
            exit.code().or_else(|| exit.signal()).unwrap_or(130)
        };
        #[cfg(not(unix))]
        let exit_code = exit.code().unwrap_or(130);
        Ok(Output {
            stdout,
            stderr,
            exit_code,
            forced: stage >= 2,
            last_signal: match stage {
                0 => None,
                1 => Some(2),
                2 => Some(15),
                _ => Some(9),
            },
        })
    })
}
/// Construct the same platform-owned launcher used by the 0.11.0 engine.
pub fn command(context: &Context) -> Result<Command> {
    #[cfg(windows)]
    let mut command = {
        let launcher = std::env::current_exe()
            .map_err(|e| e.to_string())?
            .parent()
            .ok_or("缺少 Windows 程序啟動元件，請重新安裝。")?
            .join("rbn-process-launcher.exe");
        if !launcher.is_file() {
            return Err("缺少 Windows 程序啟動元件，請重新安裝。".into());
        }
        let mut c = Command::new(launcher);
        c.arg(&context.binary);
        use std::os::windows::process::CommandExt;
        c.creation_flags(0x08000000);
        c
    };
    #[cfg(not(windows))]
    let mut command = Command::new(&context.binary);
    command
        .args(&context.arguments)
        .current_dir(&context.work_dir)
        .env_clear()
        .envs(&context.environment);
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    Ok(command)
}
#[cfg(unix)]
pub fn signal(pid: u32, kind: i32) -> i32 {
    // SAFETY: callers hold the live Child and signal only its own PID, matching
    // Darwin/Glibc kill in the reference. The PID is not a user-supplied path.
    unsafe { libc::kill(pid as i32, kind) }
}
#[cfg(windows)]
pub fn signal(pid: u32, kind: i32) -> i32 {
    use windows_sys::Win32::{
        Foundation::CloseHandle,
        System::Threading::{
            OpenEventW, OpenProcess, PROCESS_TERMINATE, SetEvent, TerminateProcess,
        },
    };
    if kind == 2 || kind == 15 {
        let name = format!("Local\\RcloneBrowserNext.Stop.{pid}")
            .encode_utf16()
            .chain(Some(0))
            .collect::<Vec<_>>();
        for _ in 0..30 {
            // SAFETY: the buffer is terminated; each acquired handle is closed here.
            let event = unsafe { OpenEventW(0x0002, 0, name.as_ptr()) };
            if !event.is_null() {
                let ok = unsafe { SetEvent(event) };
                unsafe { CloseHandle(event) };
                return if ok != 0 { 0 } else { -1 };
            }
            thread::sleep(Duration::from_millis(10));
        }
        return -1;
    }
    // SAFETY: process access is restricted to termination of the owned child;
    // the private launcher's job object owns and reaps its descendants.
    let process = unsafe { OpenProcess(PROCESS_TERMINATE, 0, pid) };
    if process.is_null() {
        return -1;
    }
    let ok = unsafe { TerminateProcess(process, kind as u32) };
    unsafe { CloseHandle(process) };
    if ok != 0 { 0 } else { -1 }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(unix)]
    fn context() -> Context {
        Context {
            binary: "/bin/sh".into(),
            arguments: vec![],
            environment: std::env::vars().collect(),
            work_dir: std::env::current_dir().unwrap(),
        }
    }
    #[test]
    #[cfg(unix)]
    fn drains_both_pipes_without_deadlock() {
        let args = vec![
            "-c".into(),
            "i=0; while [ $i -lt 2000 ]; do printf 'out\\n'; printf 'err\\n' >&2; i=$((i+1)); done"
                .into(),
        ];
        let out = capture(
            &context(),
            &args,
            1024 * 1024,
            Duration::from_secs(10),
            None,
        )
        .unwrap();
        assert_eq!(out.exit_code, 0);
        assert_eq!(out.stdout.len(), 8000);
        assert_eq!(out.stderr.len(), 8000);
    }
    #[test]
    #[cfg(unix)]
    fn output_limit_is_an_error() {
        let out = capture(
            &context(),
            &["-c".into(), "printf 1234567890".into()],
            4,
            Duration::from_secs(2),
            None,
        );
        assert_eq!(
            out.unwrap_err(),
            "目錄資料超過單次可載入大小，請進入較小的資料夾。"
        );
    }
    #[test]
    #[cfg(unix)]
    fn arguments_are_not_shell_expanded() {
        let mut c = context();
        c.binary = "/usr/bin/printf".into();
        let out = capture(
            &c,
            &["%s".into(), "$(touch do-not-create) `echo hi` *".into()],
            4096,
            Duration::from_secs(2),
            None,
        )
        .unwrap();
        assert_eq!(
            String::from_utf8(out.stdout).unwrap(),
            "$(touch do-not-create) `echo hi` *"
        );
    }
}

#[cfg(all(test, unix))]
mod signal_exit_tests {
    use super::*;
    #[test]
    fn signaled_children_keep_foundation_termination_status_without_rewriting_normal_130() {
        let context = Context {
            binary: "/bin/sh".into(),
            arguments: vec![],
            environment: std::env::vars().collect(),
            work_dir: std::env::current_dir().unwrap(),
        };
        for (script, expected) in [
            ("kill -TERM $$", 15),
            ("kill -KILL $$", 9),
            ("exit 130", 130),
        ] {
            let output = capture(
                &context,
                &["-c".into(), script.into()],
                1024,
                Duration::from_secs(5),
                None,
            )
            .unwrap();
            assert_eq!(output.exit_code, expected, "{script}");
        }
    }
}

#[cfg(test)]
mod caller_parity_regressions {
    use super::*;
    use std::io::{self, Cursor};
    #[test]
    fn captured_output_limit_returns_original_swift_message_and_translations() {
        let error = Arc::new(Mutex::new(None));
        let bytes = drain(
            Cursor::new(b"12345"),
            false,
            4,
            Arc::new(AtomicUsize::new(0)),
            error.clone(),
            None,
            false,
        );
        assert!(bytes.len() <= 4);
        let actual = error.lock().unwrap().clone().unwrap();
        assert_eq!(actual, "目錄資料超過單次可載入大小，請進入較小的資料夾。");
        assert_eq!(
            crate::native::translate(&actual, "en"),
            "The directory listing is too large to load at once. Open a smaller folder."
        );
        assert_eq!(
            crate::native::translate(&actual, "ja"),
            "ディレクトリの一覧が大きすぎて一度に読み込めません。小さいフォルダを開いてください。"
        );
    }
    #[test]
    fn read_failure_keeps_original_prefix_and_native_template() {
        struct Broken;
        impl Read for Broken {
            fn read(&mut self, _: &mut [u8]) -> io::Result<usize> {
                Err(io::Error::other("synthetic pipe read"))
            }
        }
        let error = Arc::new(Mutex::new(None));
        let _ = drain(
            Broken,
            false,
            4096,
            Arc::new(AtomicUsize::new(0)),
            error.clone(),
            None,
            false,
        );
        let actual = error.lock().unwrap().clone().unwrap();
        assert_eq!(actual, "無法讀取 rclone 輸出：synthetic pipe read");
        assert_eq!(
            crate::native::translate(&actual, "en"),
            "Could not read rclone output: synthetic pipe read"
        );
        assert_eq!(
            crate::native::translate(&actual, "ja"),
            "rclone の出力を読み取れません：synthetic pipe read"
        );
    }
    #[test]
    fn oversized_streamed_line_keeps_original_error_and_discards_overflow_fragment() {
        let mut input = vec![b'x'; 2 * 1024 * 1024 + 16384];
        input.extend_from_slice(b"tail\n");
        let lines = Arc::new(Mutex::new(Vec::new()));
        let result = lines.clone();
        let handler: LineHandler = Arc::new(move |line, _, ended| {
            result.lock().unwrap().push((line.to_owned(), ended));
            Ok(())
        });
        let error = Arc::new(Mutex::new(None));
        let _ = drain(
            Cursor::new(input),
            false,
            4096,
            Arc::new(AtomicUsize::new(0)),
            error.clone(),
            Some(handler),
            false,
        );
        let actual = error.lock().unwrap().clone().unwrap();
        assert_eq!(actual, "rclone 單行輸出過大，工作已停止。");
        let lines = lines.lock().unwrap();
        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0].0.len(), 4);
        assert_eq!(lines[0], ("tail".to_owned(), true));
        assert_eq!(
            crate::native::translate(&actual, "en"),
            "A rclone output line was too large. The job was stopped."
        );
        assert_eq!(
            crate::native::translate(&actual, "ja"),
            "rclone の出力行が大きすぎるため、処理を停止しました。"
        );
    }
    #[cfg(unix)]
    struct Fixture(PathBuf);
    #[cfg(unix)]
    impl Fixture {
        fn new() -> Self {
            let base = std::env::var_os("RBN_TEST_ROOT")
                .map(PathBuf::from)
                .unwrap_or_else(|| {
                    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                        .join("../../../.tmp/process-caller-tests")
                });
            let root = base.join(uuid::Uuid::new_v4().to_string());
            std::fs::create_dir_all(&root).unwrap();
            Self(root)
        }
        fn context(&self) -> Context {
            Context {
                binary: "/bin/sh".into(),
                arguments: vec![],
                environment: BTreeMap::from([("PATH".into(), "/usr/bin:/bin".into())]),
                work_dir: self.0.clone(),
            }
        }
    }
    #[cfg(unix)]
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    #[test]
    #[cfg(unix)]
    fn engine_timeout_sigkills_without_cooperative_signals_and_reaps_child() {
        let fixture = Fixture::new();
        let fifo = fixture.0.join("wait.fifo");
        let c = std::ffi::CString::new(fifo.as_os_str().as_encoded_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
        let script = "echo $$ > trace; trap 'echo INT >> trace; exit 0' INT; trap 'echo TERM >> trace; exit 0' TERM; echo READY >> trace; exec 3<> wait.fifo; while IFS= read -r ignored <&3; do :; done";
        let began = Instant::now();
        let result = capture(
            &fixture.context(),
            &["-c".into(), script.into()],
            4096,
            Duration::from_secs(1),
            None,
        );
        assert_eq!(result.unwrap_err(), "rclone 回應逾時，請檢查連線後重試。");
        assert!(
            began.elapsed() < Duration::from_secs(5),
            "ordinary timeout must not enter10/12s cancellation escalation"
        );
        let trace = std::fs::read_to_string(fixture.0.join("trace")).unwrap();
        let mut lines = trace.lines();
        let pid = lines.next().unwrap().parse::<i32>().unwrap();
        assert_eq!(lines.collect::<Vec<_>>(), ["READY"]);
        assert_eq!(
            unsafe { libc::kill(pid, 0) },
            -1,
            "owned child must have been reaped before returning"
        );
        assert_eq!(
            std::io::Error::last_os_error().raw_os_error(),
            Some(libc::ESRCH)
        );
    }
}

#[cfg(all(test, unix))]
mod updater_process_regressions {
    use super::*;
    use std::{ffi::CString, fs};
    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let base = std::env::var_os("RBN_TEST_ROOT")
                .map(PathBuf::from)
                .unwrap_or_else(|| {
                    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                        .join("../../../.tmp/process-caller-tests")
                });
            let root = base.join(uuid::Uuid::new_v4().to_string());
            fs::create_dir_all(&root).unwrap();
            Self(root)
        }
        fn context(&self) -> Context {
            Context {
                binary: "/bin/sh".into(),
                arguments: vec![],
                environment: BTreeMap::from([("PATH".into(), "/usr/bin:/bin".into())]),
                work_dir: self.0.clone(),
            }
        }
        fn fifo(&self) {
            let p = self.0.join("wait.fifo");
            let p = CString::new(p.as_os_str().as_encoded_bytes()).unwrap();
            assert_eq!(unsafe { libc::mkfifo(p.as_ptr(), 0o600) }, 0);
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    #[test]
    fn updater_keeps_exact_four_mib_per_pipe_and_drains_child_to_completion() {
        let f = Fixture::new();
        let script = "printf OUT; dd if=/dev/zero bs=65536 count=80 2>/dev/null; printf ERR >&2; dd if=/dev/zero bs=65536 count=80 >&2 2>/dev/null; echo DONE > completed";
        let out = capture_updater(
            &f.context(),
            &["-c".into(), script.into()],
            4 * 1024 * 1024,
            Duration::from_secs(8),
        )
        .unwrap();
        assert_eq!(out.exit_code, 0);
        assert_eq!(out.stdout.len(), 4 * 1024 * 1024);
        assert_eq!(out.stderr.len(), 4 * 1024 * 1024);
        assert_eq!(&out.stdout[..3], b"OUT");
        assert_eq!(&out.stderr[..3], b"ERR");
        assert!(out.stdout[3..].iter().all(|b| *b == 0));
        assert!(out.stderr[3..].iter().all(|b| *b == 0));
        assert_eq!(fs::read_to_string(f.0.join("completed")).unwrap(), "DONE\n");
    }
    #[test]
    fn updater_timeout_term_then_two_second_kill_and_original_translations() {
        let f = Fixture::new();
        f.fifo();
        let script = "echo $$ > trace; trap 'echo INT >> trace' INT; trap 'echo TERM >> trace' TERM; echo READY >> trace; exec 3<> wait.fifo; while :; do IFS= read -r ignored <&3 || :; done";
        let signals = Arc::new(Mutex::new(Vec::new()));
        let seen = signals.clone();
        let observer: StopHandler =
            Arc::new(move |signal| seen.lock().unwrap().push((signal, Instant::now())));
        let began = Instant::now();
        let actual = run_inner(
            &f.context(),
            &["-c".into(), script.into()],
            4096,
            RunPolicy {
                timeout: Some(Duration::from_secs(1)),
                caller: Caller::Updater,
            },
            None,
            None,
            None,
            None,
            Some(observer),
        )
        .unwrap_err();
        assert_eq!(actual, "rclone 作業逾時，原本的版本保持不變。");
        assert_eq!(
            crate::native::translate(&actual, "en"),
            "The rclone operation timed out. Your existing version is unchanged."
        );
        assert_eq!(
            crate::native::translate(&actual, "ja"),
            "rclone の操作がタイムアウトしました。既存のバージョンは変更していません。"
        );
        let signals = signals.lock().unwrap();
        assert_eq!(signals.iter().map(|x| x.0).collect::<Vec<_>>(), [15, 9]);
        assert!(signals[1].1.duration_since(signals[0].1) >= Duration::from_millis(1900));
        assert!(began.elapsed() < Duration::from_secs(7));
        let trace = fs::read_to_string(f.0.join("trace")).unwrap();
        let mut lines = trace.lines();
        let pid = lines.next().unwrap().parse::<i32>().unwrap();
        assert_eq!(lines.collect::<Vec<_>>(), ["READY", "TERM"]);
        assert_eq!(unsafe { libc::kill(pid, 0) }, -1);
        assert_eq!(
            std::io::Error::last_os_error().raw_os_error(),
            Some(libc::ESRCH)
        );
    }
    #[test]
    fn updater_waits_for_real_late_eof_before_success() {
        let f = Fixture::new();
        let began = Instant::now();
        let out = capture_updater(
            &f.context(),
            &[
                "-c".into(),
                "(sleep 0.25; printf late-out; printf late-err >&2) & exit 0".into(),
            ],
            4096,
            Duration::from_secs(4),
        )
        .unwrap();
        assert_eq!(out.exit_code, 0);
        assert_eq!(out.stdout, b"late-out");
        assert_eq!(out.stderr, b"late-err");
        assert!(began.elapsed() >= Duration::from_millis(200));
    }
    #[test]
    fn updater_rejects_unclosed_descendant_pipe_after_original_five_second_bound() {
        let f = Fixture::new();
        let began = Instant::now();
        let error=capture_updater(&f.context(),&["-c".into(),"(sleep 6; printf late-out; printf late-err >&2; echo DONE > descendant-done) & exit 0".into()],4096,Duration::from_secs(3)).unwrap_err();
        let elapsed = began.elapsed();
        assert_eq!(error, "rclone 已結束，但輸出尚未關閉，已停止更新。");
        assert!(
            elapsed >= Duration::from_millis(4900) && elapsed < Duration::from_millis(5900),
            "observed {elapsed:?}"
        );
        // Wait for this synthetic descendant to finish and close both pipes,
        // without signalling any re-used PID or leaving a background fixture.
        let until = Instant::now() + Duration::from_secs(4);
        while !f.0.join("descendant-done").is_file() && Instant::now() < until {
            thread::sleep(Duration::from_millis(20));
        }
        assert!(f.0.join("descendant-done").is_file());
        thread::sleep(Duration::from_millis(50));
    }
    #[test]
    fn ordinary_cancellation_keeps_sigint_and_waits_for_child_exit() {
        let f = Fixture::new();
        f.fifo();
        let script = "echo $$ > trace; trap 'echo INT >> trace; exit 0' INT; echo READY >> trace; exec 3<> wait.fifo; while :; do IFS= read -r ignored <&3 || :; done";
        let cancel = AtomicBool::new(false);
        thread::scope(|scope| {
            let root = f.0.clone();
            let flag = &cancel;
            let control = scope.spawn(move || {
                let until = Instant::now() + Duration::from_secs(3);
                while Instant::now() < until {
                    if fs::read_to_string(root.join("trace")).is_ok_and(|s| s.contains("READY")) {
                        flag.store(true, Ordering::Release);
                        return;
                    }
                    thread::sleep(Duration::from_millis(10));
                }
                panic!("child never became ready");
            });
            let out = capture(
                &f.context(),
                &["-c".into(), script.into()],
                4096,
                Duration::from_secs(5),
                Some(&cancel),
            )
            .unwrap();
            control.join().unwrap();
            assert_eq!(out.exit_code, 0);
            assert_eq!(out.last_signal, Some(2));
            assert!(!out.forced);
            let trace = fs::read_to_string(f.0.join("trace")).unwrap();
            assert!(trace.ends_with("READY\nINT\n"));
        });
    }
}

#[cfg(all(test, unix))]
mod updater_startup_regression {
    use super::*;
    #[test]
    fn missing_updater_executable_preserves_basename_and_native_error_template() {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../../.tmp/process-caller-tests")
            .join(uuid::Uuid::new_v4().to_string());
        std::fs::create_dir_all(&root).unwrap();
        let missing = root.join("missing-rclone");
        let os_error = Command::new(&missing).spawn().unwrap_err().to_string();
        let context = Context {
            binary: missing,
            arguments: vec![],
            environment: BTreeMap::new(),
            work_dir: root.clone(),
        };
        let error = capture_updater(&context, &[], 4096, Duration::from_secs(1)).unwrap_err();
        std::fs::remove_dir_all(root).unwrap();
        assert_eq!(error, format!("無法執行 missing-rclone：{os_error}"));
        assert_eq!(
            crate::native::translate(&error, "en"),
            format!("Could not run missing-rclone: {os_error}")
        );
        assert_eq!(
            crate::native::translate(&error, "ja"),
            format!("missing-rclone を実行できません：{os_error}")
        );
    }
}
