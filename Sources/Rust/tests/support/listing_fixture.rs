//! rclone-shaped, shell-free directory child for the 0.11.0 ListingTests port.
use serde_json::json;
use std::{
    fs::{self, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
    thread,
    time::{Duration, Instant},
};
fn stage<T>(label: &str, path: &Path, result: std::io::Result<T>) -> Result<T, String> {
    result.map_err(|e| {
        format!(
            "Fixture stage={label}, path={}, underlying={e}",
            path.display()
        )
    })
}
pub fn run(command: &str, args: &[String]) -> Result<(), String> {
    let config = args
        .iter()
        .find_map(|a| a.strip_prefix("--config="))
        .ok_or("Missing fixture config")?;
    let area = PathBuf::from(config)
        .parent()
        .ok_or("Missing fixture area")?
        .to_owned();
    let endpoint = args.last().cloned().unwrap_or_default();
    let name = endpoint
        .rsplit(':')
        .next()
        .unwrap_or_default()
        .replace('/', "_");
    #[cfg(unix)]
    if command == "lsjson" && (name.starts_with("late") || name.starts_with("stubborn")) {
        // SAFETY: this fixture is a single-threaded, owned child; only its own
        // signal dispositions are changed before publishing the ready event.
        unsafe {
            libc::signal(libc::SIGINT, libc::SIG_IGN);
            libc::signal(libc::SIGTERM, libc::SIG_IGN);
        }
    }
    let events = area.join("events");
    let event = events.join(format!("{command}-{}.json", std::process::id()));
    let pending = events.join(format!("{command}-{}.pending", uuid::Uuid::new_v4()));
    let bytes = serde_json::to_vec(
        &json!({"command":command,"endpoint":endpoint,"pid":std::process::id(),"arguments":args}),
    )
    .map_err(|e| {
        format!(
            "Fixture stage=event-encode, path={}, underlying={e}",
            event.display()
        )
    })?;
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
    }
    let mut file = stage("event-create", &pending, options.open(&pending))?;
    stage("event-write", &pending, file.write_all(&bytes))?;
    drop(file);
    // Every owned child has a distinct live PID. Refuse an already-published
    // event rather than ever modifying it, and publish only after closing it.
    if event.exists() {
        return Err(format!("Fixture event already exists: {}", event.display()));
    }
    stage("event-publish", &event, fs::rename(&pending, &event))?;
    let gate = |name: &str| -> Result<(), String> {
        let path = area.join(name);
        let deadline = Instant::now() + Duration::from_secs(20);
        while !path.exists() {
            if Instant::now() >= deadline {
                return Err(format!("Timed out: fixture gate {name}"));
            }
            thread::sleep(Duration::from_millis(10));
        }
        Ok(())
    };
    let output = match command {
        "version" => {
            if area.join("block-version").exists() {
                gate("release-version")?;
            }
            b"rclone v1.75.2 listing-test-fixture\n".to_vec()
        }
        "listremotes" => b"[{\"name\":\"fixture\",\"type\":\"alias\"}]\n".to_vec(),
        "lsjson" => {
            if name.starts_with("wait") || name.starts_with("late") || name.starts_with("stubborn")
            {
                gate(&format!("release-{name}"))?;
            }
            serde_json::to_vec(&json!([{"Name":format!("fixture-{name}"),"Path":format!("fixture-{name}"),"Size":7,"ModTime":"2026-01-02T03:04:05Z","IsDir":false}])).map_err(|e|e.to_string())?
        }
        _ => return Err("Unexpected fixture command".into()),
    };
    stage("stdout", &event, std::io::stdout().write_all(&output))
}
