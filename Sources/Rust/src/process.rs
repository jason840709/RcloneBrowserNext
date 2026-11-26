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
) -> Vec<u8> {
    let mut kept = Vec::new();
    let mut pending = Vec::new();
    let mut chunk = [0; 16384];
    loop {
        let length = match input.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) => {
                failure(&error, format!("讀取 rclone 記錄失敗：{e}"));
                break;
            }
        };
        if handler.is_none() {
            let before = total.fetch_add(length, Ordering::Relaxed);
            if before.saturating_add(length) > maximum {
                failure(&error, "rclone 回傳資料過大，已停止操作。".into());
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
            for byte in &chunk[..length] {
                if *byte == b'\n' {
                    let line = String::from_utf8_lossy(&pending);
                    if let Err(e) = callback(&line, stderr, true) {
                        failure(&error, e);
                    }
                    pending.clear();
                } else if pending.len() < 2 * 1024 * 1024 {
                    pending.push(*byte);
                } else {
                    failure(&error, "rclone 單筆記錄過大，已停止操作。".into());
                }
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
    run(context, arguments, maximum, Some(timeout), cancelled, None)
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
        Some(timeout),
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
        context, arguments, maximum, timeout, cancelled, handler, None, None, None,
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
        timeout,
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
        Some(timeout),
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
    timeout: Option<Duration>,
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
    let mut child = command
        .spawn()
        .map_err(|e| format!("無法啟動 rclone：{e}"))?;
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
        let out = scope.spawn(move || drain(stdout, false, maximum, t, f, h));
        let t = total.clone();
        let f = failure_slot.clone();
        let err = scope.spawn(move || drain(stderr, true, maximum, t, f, handler));
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
            let expired = timeout.is_some_and(|t| began.elapsed() >= t);
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
                stage = 1;
                let _ = signal(pid, 2);
                if let Some(observer) = &observer {
                    observer(2);
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
        let _ = input_worker.join().map_err(|_| "rclone 輸入工作中斷。")?;
        let stdout = out.join().map_err(|_| "rclone 輸出讀取工作中斷。")?;
        let stderr = err.join().map_err(|_| "rclone 錯誤記錄讀取工作中斷。")?;
        if let Some(e) = failure_slot
            .lock()
            .map_err(|_| "rclone 記錄狀態無法讀取。")?
            .take()
        {
            return Err(e);
        }
        if timed_out {
            return Err("操作逾時，rclone 已停止。".into());
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
        assert!(out.unwrap_err().contains("過大"));
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
