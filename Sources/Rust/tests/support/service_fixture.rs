//! Synthetic rclone/player child used by service integration tests on every OS.
//! It has no cloud backend and performs no network or configuration discovery.
mod core_fixture;
mod listing_fixture;
use serde_json::json;
use std::{
    io::{Read, Write},
    path::Path,
    process, thread,
    time::Duration,
};
fn emit(bytes: &[u8]) {
    if std::io::stdout().write_all(bytes).is_err() {
        process::exit(1);
    }
}
fn main() {
    let args: Vec<_> = std::env::args().skip(1).collect();
    if let Some(code) = core_fixture::run(&args) {
        process::exit(code);
    }
    if args
        .first()
        .is_some_and(|s| s.starts_with("--fixture-player"))
    {
        if args[0] == "--fixture-player-fail" {
            let _ = std::io::stderr().write_all(b"player refused\n");
            process::exit(7);
        }
        let mut bytes = Vec::new();
        if std::io::stdin().read_to_end(&mut bytes).is_err() {
            process::exit(9);
        }
        if args[0] == "--fixture-player" {
            let Some(path) = args.get(1) else {
                process::exit(9)
            };
            if std::fs::write(path, bytes).is_err() {
                process::exit(9);
            }
            let leaked = std::env::vars_os().any(|(key, _)| {
                let key = key.to_string_lossy().to_uppercase();
                key.starts_with("RCLONE_")
                    || matches!(key.as_str(), "AWS_SECRET_ACCESS_KEY" | "HTTPS_PROXY")
            });
            let credential_check = Path::new(path).with_extension("bin.credential-check");
            if std::fs::write(
                credential_check,
                if leaked {
                    b"leaked".as_slice()
                } else {
                    b"clean".as_slice()
                },
            )
            .is_err()
            {
                process::exit(9);
            }
        }
        return;
    }
    let mode = std::env::var("RBN_SERVICE_FIXTURE").unwrap_or_else(|_| {
        std::env::current_exe()
            .ok()
            .and_then(|p| p.file_stem().map(|s| s.to_string_lossy().into_owned()))
            .filter(|s| s == "custom-version")
            .unwrap_or_default()
    });
    if mode.is_empty() {
        if let Some(command) = args
            .iter()
            .find(|a| ["version", "lsjson", "listremotes"].contains(&a.as_str()))
        {
            if let Err(error) = listing_fixture::run(command, &args) {
                eprintln!("{error}");
                process::exit(1);
            }
        }
        return;
    }
    if mode == "repeated-questionnaire" {
        if args.iter().any(|s| s == "config/paths") {
            emit(
                serde_json::to_string(&json!({"config":std::env::var("RBN_TEST_CONFIG").unwrap()}))
                    .unwrap()
                    .as_bytes(),
            );
            return;
        }
        if args.iter().any(|s| s == "listremotes") {
            emit(b"[]\n");
            return;
        }
        if args.iter().any(|s| s == "providers") {
            emit(br#"[{"Name":"alias","Prefix":"alias","Options":[{"Name":"remote","Required":true,"Type":"string"},{"Name":"remote","Type":"bool"}]}]"#);
            return;
        }
        if args
            .iter()
            .any(|s| matches!(s.as_str(), "create" | "update"))
        {
            emit(br#"{"State":"opaque-state","Option":{"Name":"remote","Required":true,"DefaultStr":"/synthetic","Type":"string"}}"#);
            return;
        }
        process::exit(5);
    }
    if mode.starts_with("stream") && args.iter().any(|s| s == "lsjson") {
        emit(b"{\"IsDir\":false}\n");
        return;
    }
    match mode.as_str() {
        "failure" => {
            emit(b"partial,data\n");
            let _ = std::io::stderr().write_all(b"fixture declined operation\n");
            process::exit(12);
        }
        "tree-large" => emit(&vec![b'A'; 1024 * 1024 + 65536]),
        "csv-multiline" => emit(
            b"\"line\nbreak.txt\",5,2026-10-20 00:00:00\n\"quotes\"\"x\",7,2026-10-20 00:00:00\n",
        ),
        "link-valid" => emit(b"status\nhttps://example.invalid/share/%E4%B8%AD?test=1\n"),
        "link-script" => emit(b"javascript:alert(1)\n"),
        "link-credentials" => emit(b"https://user:password@example.invalid/share\n"),
        "link-bad" => emit(b"not a URL\n"),
        "custom-version" => emit(b"rclone v1.99.0-beta\n"),
        "stdin-check" => {
            let mut bytes = Vec::new();
            if std::io::stdin().read_to_end(&mut bytes).is_err() {
                process::exit(9);
            }
            emit(if bytes.is_empty() {
                b"closed\n"
            } else {
                b"leaked\n"
            });
        }
        "stream-fail" => {
            let _ = std::io::stderr().write_all(b"producer failed\n");
            process::exit(8);
        }
        "stream" => {
            let data = vec![b'0'; 32768];
            for _ in 0..10000 {
                emit(&data);
                thread::sleep(Duration::from_millis(2));
            }
        }
        _ => process::exit(13),
    }
}
