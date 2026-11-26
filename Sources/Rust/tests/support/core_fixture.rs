//! Shell-free equivalents of original CoreTests' two process fixtures.
use serde_json::{Value, json};
use std::{
    fs,
    io::Write,
    path::Path,
    process::{Command, Stdio},
    thread,
    time::Duration,
};
pub fn run(args: &[String]) -> Option<i32> {
    let executable = std::env::current_exe().ok()?;
    let settings = executable.parent()?.join("core-fixture.json");
    if !settings.is_file() {
        return None;
    }
    let settings: Value = match fs::read(&settings)
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
    {
        Some(v) => v,
        None => return Some(90),
    };
    let mode = settings["mode"].as_str().unwrap_or("");
    if mode == "forced-stop" {
        if args.iter().any(|s| s == "version") {
            println!("rclone v1.75.2");
            return Some(0);
        }
        if args.iter().any(|s| s == "config" || s == "listremotes") {
            if args.iter().any(|s| s == "listremotes") {
                println!("[]");
            } else if args.iter().any(|s| s == "paths") {
                println!(
                    "{}",
                    json!({"config":settings["config"],"cache":"","temp":""})
                );
            }
            return Some(0);
        }
        if args
            .iter()
            .any(|s| ["copy", "sync", "move"].contains(&s.as_str()))
        {
            #[cfg(unix)]
            unsafe {
                libc::signal(libc::SIGINT, libc::SIG_IGN);
                libc::signal(libc::SIGTERM, libc::SIG_IGN);
            }
            #[cfg(windows)]
            unsafe {
                unsafe extern "system" fn ignore(_: u32) -> i32 {
                    1
                }
                windows_sys::Win32::System::Console::SetConsoleCtrlHandler(Some(ignore), 1);
            }
            eprintln!("{}", json!({"level":"info","msg":"signal fixture ready"}));
            loop {
                thread::sleep(Duration::from_secs(1));
            }
        }
        return Some(0);
    }
    if mode == "comparison-json" {
        if args.iter().any(|s| ["copy", "sync", "move"].contains(&s.as_str())) {
            println!("+ {{\"stats\":{{\"bytes\":999999999}}}}.txt");
            println!("{{\"stats\":{{\"bytes\":999999999,\"transfers\":999}}}}");
            return Some(0);
        }
        let output = match Command::new(settings["rclone"].as_str().unwrap())
            .args(args).stdin(Stdio::null()).output() {
            Ok(value) => value,
            Err(_) => return Some(91),
        };
        let _ = std::io::stdout().write_all(&output.stdout);
        let _ = std::io::stderr().write_all(&output.stderr);
        return Some(output.status.code().unwrap_or(92));
    }
    if mode == "temporary-retry" {
        let binary = Path::new(settings["rclone"].as_str().unwrap());
        let output = match Command::new(binary)
            .args(args)
            .stdin(Stdio::null())
            .output()
        {
            Ok(v) => v,
            Err(_) => return Some(91),
        };
        let _ = std::io::stdout().write_all(&output.stdout);
        let _ = std::io::stderr().write_all(&output.stderr);
        if args.iter().any(|s| s == "--combined=-")
            && !args.iter().any(|s| s.starts_with("--files-from-raw="))
        {
            eprintln!(
                "{}",
                json!({"level":"error","msg":"Failed to copy: read tcp 10.0.0.2:51234->10.0.0.9:443: i/o timeout","object":"big.bin","objectType":"*local.Object"})
            );
            return Some(1);
        }
        return Some(output.status.code().unwrap_or(92));
    }
    Some(93)
}
