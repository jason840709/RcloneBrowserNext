//! End-to-end counterparts of 0.11.0 SyncDirectoryTests and SMBTests.
//! Every child receives a synthetic configuration and both transfer roots.
#![cfg(unix)]
use rbn_core::engine::Engine;
use serde_json::{Value, json};
use std::{
    collections::BTreeSet,
    fs,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    sync::Arc,
    thread,
    time::{Duration, Instant},
};
use unicode_normalization::UnicodeNormalization;
struct Fixture {
    root: PathBuf,
    source: PathBuf,
    target: PathBuf,
    engine: Arc<Engine>,
    binary: PathBuf,
    config: PathBuf,
}
fn write(base: &Path, name: &str, content: &[u8]) {
    let p = base.join(name);
    fs::create_dir_all(p.parent().unwrap()).unwrap();
    fs::write(p, content).unwrap();
}
fn quote(p: &Path) -> String {
    format!("'{}'", p.to_str().unwrap().replace('\'', "'\\''"))
}
impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!("rbn-local-suite-{}", uuid::Uuid::new_v4()));
        let (source, target, config) = (
            root.join("source"),
            root.join("target"),
            root.join("rclone.conf"),
        );
        fs::create_dir_all(&source).unwrap();
        fs::create_dir_all(&target).unwrap();
        fs::write(&config, "").unwrap();
        let binary = std::env::var_os("RBN_TEST_RCLONE")
            .map(PathBuf::from)
            .expect("RBN_TEST_RCLONE must identify the isolated test binary");
        let engine = Engine::new(root.join("state"), root.join("unused-tools")).unwrap();
        engine.invoke("saveSettings",vec![json!({"rclonePath":binary,"configPath":config,"autoCheckUpdates":false,"language":"zh-TW"})]).unwrap();
        Self {
            root,
            source,
            target,
            engine,
            binary,
            config,
        }
    }
    fn wrapper(&self, body: &str) {
        let path = self.root.join("rclone-wrapper");
        let vars = format!(
            "REAL={}\nFROM={}\nTO={}\nCONFIG={}",
            quote(&self.binary),
            quote(&self.source),
            quote(&self.target),
            quote(&self.config)
        );
        fs::write(&path, format!("#!/bin/sh\n{vars}\n{body}\n")).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
        self.engine
            .invoke("saveSettings", vec![json!({"rclonePath":path})])
            .unwrap();
    }
    fn source_error(&self) {
        self.wrapper(r#"case " $* " in
 *" --combined=- "*)
  case " $* " in *" --dry-run "*) ;; *) "$REAL" copy --config="$CONFIG" --local-no-clone --local-encoding=Raw --create-empty-src-dirs -- "$FROM" "$TO" || exit 1 ;; esac
  echo '{"level":"error","msg":"error reading source directory: directory not found","object":"kept/unreadable","objectType":"string"}' >&2
  echo '{"level":"error","msg":"not deleting directories as there were IO errors","object":"destination","objectType":"*local.Fs"}' >&2
  exit 1 ;;
 *) exec "$REAL" "$@" ;;
esac"#);
    }
    fn alias_smb(&self) {
        fs::write(
            &self.config,
            format!(
                "[nas]\ntype = alias\nremote = {}\n\n[cloud]\ntype = alias\nremote = {}\n",
                self.source.display(),
                self.source.display()
            ),
        )
        .unwrap();
        self.wrapper(r#"literal=
for arg do
 if [ "$arg" = "--smb-encoding=Slash,Ctl,Del,Dot" ]; then literal=--local-encoding=Slash,Ctl,Del,Dot; fi
 if [ "$arg" = listremotes ]; then echo '[{"name":"nas","type":"smb"},{"name":"cloud","type":"drive"}]'; exit 0; fi
done
if [ -n "$literal" ]; then exec "$REAL" "$literal" "$@"; fi
exec "$REAL" "$@""#);
    }
    fn request(&self) -> Value {
        json!({"source":{"remote":null,"path":self.source},"destination":{"remote":null,"path":self.target},"mode":"sync","options":{"retries":1,"lowLevelRetries":1},"selection":[],"dryRun":false})
    }
    fn run(&self, request: Value) -> Value {
        let submitted = self.engine.invoke("startTransfer", vec![request]).unwrap();
        let until = Instant::now() + Duration::from_secs(50);
        loop {
            let jobs = self.engine.invoke("listJobs", vec![]).unwrap();
            let job = jobs
                .as_array()
                .unwrap()
                .iter()
                .find(|j| j["id"] == submitted["id"])
                .unwrap();
            if matches!(
                job["status"].as_str(),
                Some("failed" | "completed" | "cancelled" | "interrupted")
            ) {
                return job.clone();
            }
            assert!(Instant::now() < until, "transfer timeout: {job}");
            thread::sleep(Duration::from_millis(30));
        }
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = self.engine.invoke("_shutdown", vec![]);
        let _ = fs::remove_dir_all(&self.root);
    }
}
#[test]
fn literal_local_names() {
    let f = Fixture::new();
    let names = [
        "quote‛？",
        "quote‛‛：",
        "slash／",
        "fullwidth：？｜＊",
        "kanaか\u{3099}",
        "é",
        "space end ",
    ];
    for name in names {
        write(&f.source, &format!("{name}/file‛？.txt"), name.as_bytes());
    }
    fs::create_dir(f.source.join("legitimate-empty")).unwrap();
    let job = f.run(f.request());
    assert_eq!(job["status"], "completed", "{job}");
    let children = |p: &Path| {
        fs::read_dir(p)
            .unwrap()
            .map(|i| i.unwrap().file_name())
            .collect::<BTreeSet<_>>()
    };
    assert_eq!(children(&f.source), children(&f.target));
    for name in names {
        let path = format!("{name}/file‛？.txt");
        assert_eq!(
            fs::read(f.source.join(&path)).unwrap(),
            fs::read(f.target.join(path)).unwrap()
        );
    }
}
#[test]
fn selected_literal_name_with_includes() {
    let f = Fixture::new();
    write(&f.source, "chosen‛？/photo.txt", b"photo");
    write(&f.source, "chosen‛？/skip.bin", b"skip");
    write(&f.target, "not-selected/keep.txt", b"keep");
    let mut r = f.request();
    r["options"]["include"] = json!(["*.txt"]);
    r["selection"] = json!([{"name":"chosen‛？","isDir":true}]);
    let job = f.run(r);
    assert_eq!(job["status"], "completed", "{job}");
    assert!(
        f.target.join("chosen‛？/photo.txt").is_file()
            && !f.target.join("chosen‛？/skip.bin").exists()
            && f.target.join("not-selected/keep.txt").is_file()
    );
}
#[test]
fn prune_only_orphan_empty_directories_after_error() {
    let f = Fixture::new();
    f.source_error();
    for d in ["kept/unreadable", "legitimate-empty"] {
        fs::create_dir_all(f.source.join(d)).unwrap();
    }
    for p in [
        "kept/unreadable/protected.txt",
        "nonempty/not-forced-away.txt",
    ] {
        write(&f.target, p, b"keep");
    }
    for d in ["obsolete/deep/empty", "old-empty", "old‛？"] {
        fs::create_dir_all(f.target.join(d)).unwrap();
    }
    let job = f.run(f.request());
    assert_eq!(job["status"], "failed", "{job}");
    assert!(
        job["error"]
            .as_str()
            .is_some_and(|e| e.contains("來源資料夾")),
        "{job}"
    );
    for p in ["obsolete", "old-empty", "old‛？"] {
        assert!(!f.target.join(p).exists(), "{p}");
    }
    for p in [
        "legitimate-empty",
        "kept/unreadable/protected.txt",
        "nonempty/not-forced-away.txt",
    ] {
        assert!(f.target.join(p).exists(), "{p}");
    }
    assert_eq!(job["report"]["directoryDeletedEvents"], 5);
    assert_eq!(job["report"]["deletedEvents"], 0);
}
#[test]
fn pruning_respects_exclusions_and_selected_folders() {
    for selected in [false, true] {
        let f = Fixture::new();
        f.source_error();
        let mut r = f.request();
        let (remove, keep) = if selected {
            r["selection"] = json!([{"name":"selected","isDir":true}]);
            fs::create_dir_all(f.source.join("selected/kept/unreadable")).unwrap();
            ("selected/obsolete", "unselected")
        } else {
            r["options"]["exclude"] = json!(["/protected/**"]);
            fs::create_dir_all(f.source.join("kept/unreadable")).unwrap();
            ("obsolete", "protected")
        };
        fs::create_dir_all(f.target.join(remove)).unwrap();
        fs::create_dir_all(f.target.join(keep)).unwrap();
        let job = f.run(r);
        assert_eq!(job["status"], "failed", "{job}");
        assert!(
            !f.target.join(remove).exists() && f.target.join(keep).is_dir(),
            "{job}"
        );
    }
}
#[test]
fn pruning_never_mutates_for_copy_dry_run_or_zero_limit() {
    for (mode, dry, max) in [("copy", false, -1), ("sync", true, -1), ("sync", false, 0)] {
        let f = Fixture::new();
        f.source_error();
        fs::create_dir_all(f.source.join("kept/unreadable")).unwrap();
        fs::create_dir_all(f.target.join("obsolete")).unwrap();
        let mut r = f.request();
        r["mode"] = json!(mode);
        r["dryRun"] = json!(dry);
        r["options"]["maxDelete"] = json!(max);
        f.run(r);
        assert!(f.target.join("obsolete").is_dir());
    }
}
#[test]
fn smb_preview_browsing_and_raw_copy() {
    let f = Fixture::new();
    f.alias_smb();
    let names = [
        "引用‛？/か\u{3099}.txt",
        "全形／記号/空白 .txt",
        "か\u{3099}/kept.txt",
        "plain.txt",
    ];
    for n in names {
        write(&f.source, n, n.as_bytes());
    }
    let mut r = f.request();
    r["mode"] = json!("copy");
    r["source"] = json!({"remote":"nas","path":""});
    let preview = f.engine.invoke("previewTransfer", vec![r.clone()]).unwrap();
    for flag in [
        "--smb-encoding=Slash,Ctl,Del,Dot",
        "--local-encoding=Slash,Ctl,Del,Dot",
    ] {
        assert!(preview["command"].as_str().unwrap().contains(flag));
    }
    let list = f.engine.invoke("list", vec![r["source"].clone()]).unwrap();
    let found = list
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v["name"].as_str().unwrap().nfc().collect::<String>())
        .collect::<BTreeSet<_>>();
    assert_eq!(
        found,
        ["引用‛？", "全形／記号", "が", "plain.txt"]
            .map(str::to_owned)
            .into_iter()
            .collect()
    );
    let job = f.run(r.clone());
    assert_eq!(job["status"], "completed", "{job}");
    for n in names {
        assert_eq!(
            fs::read(f.source.join(n)).unwrap(),
            fs::read(f.target.join(n)).unwrap()
        );
    }
    r["source"]["remote"] = json!("cloud");
    let p = f.engine.invoke("previewTransfer", vec![r]).unwrap();
    let cmd = p["command"].as_str().unwrap();
    assert!(!cmd.contains("--smb-encoding") && !cmd.contains("--local-encoding"));
}
#[cfg(target_os = "macos")]
#[test]
fn smb_selected_sync_respects_canonical_names_with_and_without_includes() {
    for included in [false, true] {
        let f = Fixture::new();
        f.alias_smb();
        write(&f.source, "か\u{3099}/kept.txt", b"keep");
        write(&f.target, "か\u{3099}/stale.txt", b"old");
        fs::create_dir_all(f.target.join("か\u{3099}/empty")).unwrap();
        write(&f.target, "unselected.txt", b"unselected");
        let mut r = f.request();
        r["source"] = json!({"remote":"nas","path":""});
        r["selection"] = json!([{"name":"が","isDir":true}]);
        if included {
            r["options"]["include"] = json!(["*.txt"]);
        }
        let job = f.run(r);
        assert_eq!(job["status"], "completed", "{job}");
        assert!(f.target.join("か\u{3099}/kept.txt").is_file());
        assert!(
            !f.target.join("か\u{3099}/stale.txt").exists()
                && !f.target.join("か\u{3099}/empty").exists()
        );
        assert_eq!(
            fs::read(f.target.join("unselected.txt")).unwrap(),
            b"unselected"
        );
    }
}

#[cfg(target_os = "macos")]
#[test]
fn preview_command_and_warnings_match_swift() {
    let f = Fixture::new();
    let destination = f.root.join("destination");
    fs::create_dir(&destination).unwrap();
    fs::create_dir(f.source.join("選擇 [folder]")).unwrap();
    write(&f.source, "表.txt", b"synthetic");
    fs::write(
        &f.config,
        format!(
            "[source]\ntype = alias\nremote = {}\n\n[target]\ntype = alias\nremote = {}\n",
            f.source.display(),
            destination.display()
        ),
    )
    .unwrap();
    let raw = include_str!("fixtures/preview-0.11.0.json")
        .replace("RBN_TEST_BINARY", f.binary.to_str().unwrap())
        .replace("RBN_TEST_AREA", f.root.to_str().unwrap());
    let cases: Vec<Value> = serde_json::from_str(&raw).unwrap();
    let mut differences = Vec::new();
    for case in cases {
        if let Some(patch) = case.get("settings") {
            f.engine
                .invoke("saveSettings", vec![patch.clone()])
                .unwrap();
        }
        let actual = f
            .engine
            .invoke("previewTransfer", vec![case["request"].clone()]);
        let expected = if case["expected"].is_null() {
            Err(case["error"].as_str().unwrap().to_owned())
        } else {
            Ok(case["expected"].clone())
        };
        if expected != actual {
            differences.push(format!(
                "{}\nSwift {expected:?}\nRust {actual:?}",
                case["name"]
            ));
        }
    }
    assert!(differences.is_empty(), "{}", differences.join("\n\n"));
}
