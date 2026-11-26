//! Original CoreTests engine assertions. Every transfer uses synthetic local
//! data and an explicit synthetic config; aliases never contact a cloud service.
#[path = "support/fixture_paths.rs"]
mod fixture_paths;
use rbn_core::{
    catalog,
    engine::Engine,
    models::{self, TransferRequest},
    storage,
};
use serde_json::{Value, json};
use std::{
    collections::BTreeSet,
    fs::{self, File},
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
struct Suite {
    root: PathBuf,
    engines: Mutex<Vec<Arc<Engine>>>,
}
impl Suite {
    fn new() -> Self {
        let base = std::env::var_os("RBN_TEST_ROOT")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../.tmp/services-tests")
            });
        let root = base.join(format!("core-parity-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        Self {
            root: fixture_paths::canonical(&root),
            engines: Mutex::new(vec![]),
        }
    }
    fn folder(&self, name: &str) -> PathBuf {
        let path = self.root.join(name);
        fs::create_dir_all(&path).unwrap();
        path
    }
    fn file(&self, folder: &Path, name: &str, data: impl AsRef<[u8]>) {
        let p = folder.join(name);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, data).unwrap();
    }
    fn modified(&self, folder: &Path, name: &str, seconds: f64) {
        let time = UNIX_EPOCH + Duration::from_secs_f64(seconds);
        File::options()
            .write(true)
            .open(folder.join(name))
            .unwrap()
            .set_times(fs::FileTimes::new().set_modified(time))
            .unwrap();
    }
    fn engine(&self, name: &str, real: bool, aliases: &[(&str, &Path)]) -> Arc<Engine> {
        let area = self.folder(name);
        let state = area.join("state");
        fs::create_dir_all(&state).unwrap();
        let config = area.join("rclone.conf");
        let mut sorted = aliases.to_vec();
        sorted.sort_by_key(|(name, _)| *name);
        let mut text = String::new();
        for (name, path) in sorted {
            text.push_str(&format!(
                "[{name}]\ntype = alias\nremote = {}\n\n",
                path.display()
            ));
        }
        fs::write(&config, text).unwrap();
        let settings = state.join("settings.json");
        let mut seed = if settings.exists() {
            read_json(&settings)
        } else {
            json!({"settingsSchemaVersion":7})
        };
        if seed["configPath"].as_str().is_none_or(str::is_empty) {
            seed["configPath"] = json!(config);
        }
        if seed["rclonePath"].as_str().is_none_or(str::is_empty) {
            seed["rclonePath"] = json!(area.join("unavailable-rclone"));
        }
        storage::atomic_json(&settings, &seed).unwrap();
        let engine = Engine::new(state, area.join("Tools/rclone")).unwrap();
        self.engines.lock().unwrap().push(engine.clone());
        engine.invoke("_localLocations",vec![json!({"home":{"path":self.root,"name":"Synthetic Home"},"folders":[],"volumes":[]})]).unwrap();
        if real {
            let binary = real_binary();
            let environment = engine
                .invoke(
                    "saveSettings",
                    vec![json!({"rclonePath":binary,"configPath":config})],
                )
                .unwrap();
            assert_eq!(
                environment["available"], true,
                "real rclone failed to start: {environment}"
            );
        }
        engine
    }
    fn settings(&self, e: &Arc<Engine>) -> Value {
        let reply = e.invoke("_preferences", vec![]).unwrap();
        assert!(
            reply["settings"].is_object(),
            "native preferences must contain settings"
        );
        reply["settings"].clone()
    }
    fn quit(&self, e: &Arc<Engine>) -> Value {
        e.invoke("_state", vec![]).unwrap()["quit"].clone()
    }
    fn jobs(&self, e: &Arc<Engine>) -> Vec<Value> {
        e.invoke("listJobs", vec![])
            .unwrap()
            .as_array()
            .unwrap()
            .clone()
    }
    fn job(&self, e: &Arc<Engine>, id: &str) -> Value {
        self.jobs(e)
            .into_iter()
            .find(|j| j["id"] == id)
            .unwrap_or_else(|| panic!("missing job {id}"))
    }
    fn submit(&self, e: &Arc<Engine>, request: Value) -> String {
        e.invoke("startTransfer", vec![request]).unwrap()["id"]
            .as_str()
            .unwrap()
            .to_owned()
    }
    fn wait(&self, e: &Arc<Engine>, id: &str, seconds: f64) -> Value {
        let deadline = Instant::now() + Duration::from_secs_f64(seconds);
        loop {
            let job = self.job(e, id);
            if ["completed", "failed", "cancelled", "interrupted"]
                .contains(&job["status"].as_str().unwrap())
            {
                return job;
            }
            assert!(Instant::now() < deadline, "job timeout: {job}");
            thread::sleep(Duration::from_millis(30));
        }
    }
    fn completed(&self, e: &Arc<Engine>, request: Value) -> Value {
        let id = self.submit(e, request);
        let job = self.wait(e, &id, 35.);
        assert_eq!(job["status"], "completed", "job did not complete: {job}");
        job
    }
    fn endpoint(&self, path: &Path, remote: Option<&str>) -> Value {
        json!({"remote":remote,"path":if remote.is_some(){"".to_owned()}else{fixture_paths::wire(path)}})
    }
    fn request(
        &self,
        from: &Path,
        to: &Path,
        mode: &str,
        dry: bool,
        selection: Value,
        options: Value,
        sr: Option<&str>,
        dr: Option<&str>,
    ) -> Value {
        let mut complete = models::default_options();
        for (k, v) in options.as_object().unwrap() {
            complete[k] = v.clone();
        }
        json!({"source":self.endpoint(from,sr),"destination":self.endpoint(to,dr),"mode":mode,"options":complete,"selection":selection,"dryRun":dry})
    }
    fn basic(&self, from: &Path, to: &Path) -> Value {
        self.request(from, to, "copy", false, json!([]), json!({}), None, None)
    }
    fn fake(&self, name: &str, mode: &str) -> PathBuf {
        let area = self.folder(name);
        let path = area.join(if cfg!(windows) {
            "rclone-fixture.exe"
        } else {
            "rclone-fixture"
        });
        fs::copy(env!("CARGO_BIN_EXE_rbn-service-fixture"), &path).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
        }
        fs::write(
            area.join("core-fixture.json"),
            serde_json::to_vec(
                &json!({"mode":mode,"rclone":real_binary(),"config":area.join("rclone.conf")}),
            )
            .unwrap(),
        )
        .unwrap();
        path
    }
}
impl Drop for Suite {
    fn drop(&mut self) {
        for e in self.engines.lock().unwrap().iter() {
            let _ = e.invoke("_shutdown", vec![]);
        }
        fs::remove_dir_all(&self.root).unwrap();
    }
}
fn real_binary() -> PathBuf {
    let p = PathBuf::from(
        std::env::var_os("RBN_TEST_RCLONE").expect("required pinned RBN_TEST_RCLONE"),
    );
    assert!(p.is_absolute() && p.is_file());
    PathBuf::from(fixture_paths::wire(&p))
}
fn read_json(path: &Path) -> Value {
    serde_json::from_slice(&fs::read(path).unwrap()).unwrap()
}
fn number(v: &Value) -> f64 {
    v.as_f64().unwrap_or(0.)
}
fn wait_until(seconds: f64, mut condition: impl FnMut() -> bool) {
    let end = Instant::now() + Duration::from_secs_f64(seconds);
    while !condition() {
        assert!(Instant::now() < end, "timed out after {seconds}s");
        thread::sleep(Duration::from_millis(30));
    }
}
fn job_fixture(request: &Value, status: &str, command: &str) -> Value {
    json!({"id":uuid::Uuid::new_v4().to_string(),"request":request,"status":status,"command":command,"createdAt":rbn_core::now(),"stats":{},"logs":[]})
}
#[test]
fn local_browsing_and_file_operations_without_rclone() {
    let s = Suite::new();
    let area = s.folder("local-files");
    let e = s.engine("local-engine", false, &[]);
    s.file(&area, "read me.txt", b"12345");
    s.file(&area, "keep.txt", b"123");
    let endpoint = s.endpoint(&area, None);
    e.invoke("mkdir", vec![endpoint.clone(), json!("資料夾")])
        .unwrap();
    let entries = e.invoke("list", vec![endpoint.clone()]).unwrap();
    assert_eq!(entries.as_array().unwrap().len(), 3);
    assert_eq!(entries[0]["isDir"], true);
    e.invoke(
        "rename",
        vec![
            endpoint.clone(),
            json!("read me.txt"),
            json!("重命名.txt"),
            json!(false),
        ],
    )
    .unwrap();
    assert!(
        e.invoke(
            "rename",
            vec![
                endpoint.clone(),
                json!("重命名.txt"),
                json!("keep.txt"),
                json!(false)
            ]
        )
        .is_err()
    );
    let size = e.invoke("size", vec![endpoint.clone()]).unwrap();
    assert_eq!(size["count"], 2);
    assert_eq!(size["bytes"], 8);
    e.invoke(
        "remove",
        vec![endpoint, json!([{"name":"重命名.txt","isDir":false}])],
    )
    .unwrap();
    assert!(!area.join("重命名.txt").exists());
    assert!(area.join("keep.txt").exists());
}
#[test]
fn system_language_matches_explicit_resolver_and_bootstrap() {
    let s = Suite::new();
    let e = s.engine("system-language", false, &[]);
    let settings = s.settings(&e);
    assert_eq!(settings["language"], "system");
    assert_eq!(settings["theme"], "purple-auto");
    assert_eq!(settings["maxConcurrentJobs"], 0);
    assert_eq!(
        e.invoke("bootstrap", vec![]).unwrap()["resolvedLanguage"],
        e.language()
    );
    e.invoke("saveSettings", vec![json!({"language":"ja"})])
        .unwrap();
    assert_eq!(
        e.invoke("bootstrap", vec![]).unwrap()["resolvedLanguage"],
        "ja"
    );
}
#[test]
fn location_catalog_uses_only_supplied_existing_folders_and_preserves_volume_metadata() {
    let s = Suite::new();
    let home = s.folder("locations/home");
    let downloads = s.folder("locations/downloads");
    let mount = s.folder("locations/Volumes/NAS");
    let missing = s.root.join("locations/missing");
    let nonfolder = home.join("not-a-folder");
    s.file(&home, "not-a-folder", b"fixture");
    let root = mount.parent().unwrap();
    let locations=catalog::supplied_locations(&json!({"home":{"path":home,"name":"Home"},"folders":[{"kind":"downloads","path":downloads,"name":"Downloads"},{"kind":"documents","path":missing},{"kind":"music","path":nonfolder},{"kind":"desktop","path":downloads}],"volumesRoot":{"path":root,"name":"Volumes"},"volumes":[{"path":mount,"name":"家の NAS","isLocal":false,"isRemovable":false}]})).unwrap();
    assert_eq!(locations.len(), 4);
    assert_eq!(locations[0]["kind"], "home");
    assert!(
        locations
            .iter()
            .any(|l| l["kind"] == "volumes" && l["path"] == fixture_paths::wire(root))
    );
    assert!(
        locations.iter().any(|l| l["name"] == "家の NAS"
            && l["group"] == "network"
            && l["isRemovable"] == false)
    );
    assert!(!missing.exists());
    for t in ["smb", "sftp", "ftp"] {
        assert_eq!(catalog::remote_group(t), "network");
    }
    for t in ["drive", "dropbox", "onedrive"] {
        assert_eq!(catalog::remote_group(t), "cloud");
    }
    for t in ["webdav", "http", "alias", "crypt", "union", "s3", "unknown"] {
        assert_eq!(catalog::remote_group(t), "other");
    }
}
#[test]
fn history_clear_is_id_scoped_repeatable_and_rolls_back_failed_disk_replacement() {
    let s = Suite::new();
    let from = s.folder("clear/source");
    let to = s.folder("clear/destination");
    let area = s.folder("clear-engine");
    let state = s.folder("clear-engine/state");
    let logs = s.folder("clear-engine/state/logs");
    let saved = ["failed", "cancelled", "interrupted"].map(|status| {
        let j = job_fixture(&s.basic(&from, &to), status, "clear fixture");
        s.file(
            &logs,
            &format!("{}.jsonl", j["id"].as_str().unwrap()),
            status,
        );
        j
    });
    storage::atomic_json(&state.join("jobs.json"), &json!(saved)).unwrap();
    let e = s.engine("clear-engine", false, &[]);
    e.invoke(
        "saveTask",
        vec![json!("keep saved task"), s.basic(&from, &to)],
    )
    .unwrap();
    for invalid in [
        json!({"ids":["../invalid"],"mode":"stop-and-clear"}),
        json!({"ids":[saved[0]["id"]],"mode":"all"}),
        json!({"ids":[saved[0]["id"]],"mode":"finished","cancelAll":true}),
    ] {
        assert!(e.invoke("clearJobs", vec![invalid]).is_err());
    }
    let path = state.join("jobs.json");
    let bytes = fs::read(&path).unwrap();
    fs::remove_file(&path).unwrap();
    fs::create_dir(&path).unwrap();
    assert!(
        e.invoke(
            "clearJobs",
            vec![json!({"ids":[saved[0]["id"]],"mode":"finished"})]
        )
        .is_err()
    );
    assert_eq!(
        s.job(&e, saved[0]["id"].as_str().unwrap())["status"],
        "failed"
    );
    assert!(
        logs.join(format!("{}.jsonl", saved[0]["id"].as_str().unwrap()))
            .exists()
    );
    fs::remove_dir(&path).unwrap();
    fs::write(&path, bytes).unwrap();
    let result = e
        .invoke(
            "clearJobs",
            vec![json!({"ids":[saved[0]["id"],saved[0]["id"]],"mode":"finished"})],
        )
        .unwrap();
    assert_eq!(result["removedIds"], json!([saved[0]["id"]]));
    assert!(result["stoppedIds"].as_array().unwrap().is_empty());
    assert_eq!(s.jobs(&e).len(), 2);
    e.invoke(
        "clearJobs",
        vec![json!({"ids":[saved[0]["id"]],"mode":"stop-and-clear"})],
    )
    .unwrap();
    e.invoke("clearFinishedJobs", vec![]).unwrap();
    assert!(s.jobs(&e).is_empty());
    assert_eq!(
        e.invoke("listTasks", vec![])
            .unwrap()
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert!(area.exists());
}
#[test]
fn concurrent_settings_serialize_and_failed_persistence_never_publishes_partial_change() {
    let s = Suite::new();
    let e = s.engine("settings-concurrent", false, &[]);
    let patches = [
        json!({"language":"ja"}),
        json!({"theme":"purple-dark"}),
        json!({"skippedRcloneVersion":"v99.9.0"}),
        json!({"paneColumnWidths":{"left":{"name":350,"size":85,"modified":170}}}),
        json!({"paneColumnWidths":{"right":{"name":240,"size":90,"modified":190}}}),
        json!({"showHiddenFiles":false}),
    ];
    let (tx, rx) = mpsc::channel();
    for patch in patches {
        let tx = tx.clone();
        let e = e.clone();
        thread::spawn(move || {
            tx.send(e.invoke("saveSettings", vec![patch])).unwrap();
        });
    }
    let end = Instant::now() + Duration::from_secs(10);
    for _ in 0..6 {
        rx.recv_timeout(end.saturating_duration_since(Instant::now()))
            .unwrap()
            .unwrap();
    }
    let snapshot = s.settings(&e);
    assert_eq!(snapshot["language"], "ja");
    assert_eq!(snapshot["theme"], "purple-dark");
    assert_eq!(snapshot["skippedRcloneVersion"], "v99.9.0");
    assert_eq!(snapshot["paneColumnWidths"].as_object().unwrap().len(), 2);
    assert_eq!(snapshot["showHiddenFiles"], false);
    assert_eq!(snapshot["settingsRevision"], 6);
    let path = e.state_dir.join("settings.json");
    let bytes = fs::read(&path).unwrap();
    assert_eq!(serde_json::from_slice::<Value>(&bytes).unwrap(), snapshot);
    fs::remove_file(&path).unwrap();
    fs::create_dir(&path).unwrap();
    assert!(
        e.invoke("saveSettings", vec![json!({"language":"en"})])
            .is_err()
    );
    assert_eq!(s.settings(&e), snapshot);
    fs::remove_dir(&path).unwrap();
    fs::write(path, bytes).unwrap();
}
#[test]
fn unresponsive_child_stays_cancelling_until_real_escalated_exit() {
    let s = Suite::new();
    let from = s.folder("forced/source");
    let to = s.folder("forced/destination");
    let fake = s.fake("forced/bin", "forced-stop");
    let e = s.engine("forced-engine", false, &[]);
    e.invoke("saveSettings", vec![json!({"rclonePath":fake})])
        .unwrap();
    let id = s.submit(&e, s.basic(&from, &to));
    wait_until(5., || {
        s.job(&e, &id)["logs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|l| l["message"] == "signal fixture ready")
    });
    let (tx, rx) = mpsc::channel();
    let worker = e.clone();
    let copy = id.clone();
    let start = Instant::now();
    thread::spawn(move || {
        let _ = tx.send(worker.invoke("cancelJob", vec![json!(copy)]));
    });
    wait_until(3., || {
        s.job(&e, &id)["cancellation"]["lastSignal"] == "SIGINT"
    });
    let stopping = s.job(&e, &id);
    assert_eq!(stopping["status"], "cancelling");
    assert!(stopping.get("endedAt").is_none());
    let quit = s.quit(&e);
    assert_eq!(quit["requiresConfirmation"], true);
    assert_eq!(quit["activeJobCount"], 1);
    assert_eq!(stopping["cancellation"]["forced"], false);
    assert_eq!(stopping["cancellation"]["processExited"], false);
    rx.recv_timeout(Duration::from_secs(18)).unwrap().unwrap();
    let stopped = s.job(&e, &id);
    assert!(start.elapsed() >= Duration::from_secs(10));
    assert_eq!(stopped["status"], "cancelled");
    assert_eq!(stopped["cancellation"]["lastSignal"], "SIGKILL");
    assert_eq!(
        stopped["exitCode"], 9,
        "Foundation records the actual terminating signal"
    );
    assert_eq!(stopped["cancellation"]["forced"], true);
    assert_eq!(stopped["cancellation"]["processExited"], true);
    assert!(
        stopped["error"]
            .as_str()
            .unwrap_or("")
            .contains("未完成檔案")
    );
    assert!(fs::read_dir(to).unwrap().next().is_none());
}
#[test]
fn maintenance_excludes_rclone_but_allows_local_browsing_and_commits_selected_path() {
    let s = Suite::new();
    let folder = s.folder("maintenance-local");
    let e = s.engine("maintenance-engine", false, &[]);
    let binary = real_binary();
    assert!(e.commit_rclone_update(&binary).is_err());
    e.set_maintenance(true).unwrap();
    assert!(e.set_maintenance(true).is_err());
    assert!(e.invoke("environment", vec![]).is_err());
    e.invoke("list", vec![s.endpoint(&folder, None)]).unwrap();
    let mut settings = s.settings(&e);
    settings["skippedRcloneVersion"] = json!("v1.75.2");
    e.invoke("saveSettings", vec![settings]).unwrap();
    e.commit_rclone_update(&binary).unwrap();
    assert_eq!(s.settings(&e)["rclonePath"], binary.to_str().unwrap());
    assert_eq!(e.resolved_rclone_path().unwrap(), binary);
    e.set_maintenance(false).unwrap();
    let settings = s.settings(&e);
    assert_eq!(settings["autoCheckUpdates"], true);
    assert_eq!(settings["skippedRcloneVersion"], "");
}
#[test]
fn saved_task_dry_run_preserves_saved_request_and_direction() {
    let s = Suite::new();
    let from = s.folder("task-dry/source");
    let to = s.folder("task-dry/destination");
    s.file(&from, "keep.bin", b"rclone browser test\n");
    let e = s.engine("task-dry-engine", true, &[("source", &from)]);
    let mut value = s.request(
        &from,
        &to,
        "copy",
        false,
        json!([{"name":"keep.bin","isDir":false}]),
        json!({"comparison":"size","localHashPolicy":"none"}),
        Some("source"),
        None,
    );
    value["direction"] = json!("rl");
    let task = e
        .invoke("saveTask", vec![json!("預演不改作業"), value])
        .unwrap();
    let mut trial = task["request"].clone();
    trial["dryRun"] = json!(true);
    let result = s.completed(&e, trial);
    assert_eq!(result["request"]["direction"], "rl");
    assert!(result["command"].as_str().unwrap().contains("--dry-run"));
    assert!(fs::read_dir(to).unwrap().next().is_none());
    assert_eq!(
        e.invoke("listTasks", vec![]).unwrap()[0]["request"],
        task["request"]
    );
}
#[test]
fn engine_selection_waits_for_inflight_operation_and_returns_fresh_environment() {
    let s = Suite::new();
    let e = s.engine("settings-wait", false, &[]);
    let (enter_tx, enter_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let (done_tx, done_rx) = mpsc::channel();
    let worker = e.clone();
    let (done_op_tx, done_op_rx) = mpsc::channel();
    thread::spawn(move || {
        let result = worker.with_auxiliary_operation(|| {
            enter_tx.send(()).unwrap();
            let _ = release_rx.recv_timeout(Duration::from_secs(5));
            Ok(())
        });
        let _ = done_op_tx.send(result);
    });
    enter_rx.recv_timeout(Duration::from_secs(3)).unwrap();
    let worker = e.clone();
    let binary = real_binary();
    thread::spawn(move || {
        let result = worker.invoke("saveSettings", vec![json!({"rclonePath":binary})]);
        let _ = done_tx.send(result);
    });
    assert!(done_rx.recv_timeout(Duration::from_millis(100)).is_err());
    release_tx.send(()).unwrap();
    let end = Instant::now() + Duration::from_secs(15);
    done_op_rx
        .recv_timeout(end.saturating_duration_since(Instant::now()))
        .unwrap()
        .unwrap();
    let environment = done_rx
        .recv_timeout(end.saturating_duration_since(Instant::now()))
        .unwrap()
        .unwrap();
    assert_eq!(environment["available"], true);
    assert_eq!(environment["rclonePath"], real_binary().to_str().unwrap());
}
#[test]
fn update_commit_and_appearance_patches_preserve_path_and_clear_skipped_version() {
    let s = Suite::new();
    let e = s.engine("settings-update", false, &[]);
    e.invoke(
        "saveSettings",
        vec![json!({"skippedRcloneVersion":"v99.0.0"})],
    )
    .unwrap();
    e.set_maintenance(true).unwrap();
    let (tx, rx) = mpsc::channel();
    let worker = e.clone();
    let send = tx.clone();
    thread::spawn(move || {
        let _ = send.send(worker.commit_rclone_update(&real_binary()));
    });
    for patch in [json!({"theme":"purple-dark"}), json!({"language":"ja"})] {
        let worker = e.clone();
        let send = tx.clone();
        thread::spawn(move || {
            let _ = send.send(worker.invoke("saveSettings", vec![patch]).map(|_| ()));
        });
    }
    let end = Instant::now() + Duration::from_secs(10);
    for _ in 0..3 {
        rx.recv_timeout(end.saturating_duration_since(Instant::now()))
            .unwrap()
            .unwrap();
    }
    e.set_maintenance(false).unwrap();
    let settings = s.settings(&e);
    assert_eq!(settings["rclonePath"], real_binary().to_str().unwrap());
    assert_eq!(settings["skippedRcloneVersion"], "");
    assert_eq!(settings["theme"], "purple-dark");
    assert_eq!(settings["language"], "ja");
}
#[test]
fn quit_after_success_keeps_original_failed_retry_history_until_explicit_clear() {
    let s = Suite::new();
    let from = s.folder("quit/source");
    let to = s.folder("quit/destination");
    s.file(&from, "take.txt", b"rclone browser test\n");
    let state = s.folder("quit-engine/state");
    let mut failed = job_fixture(&s.basic(&from, &to), "failed", "previous failed copy");
    failed["error"] = json!("Previous copy failed");
    failed["endedAt"] = json!(rbn_core::now());
    storage::atomic_json(&state.join("jobs.json"), &json!([failed])).unwrap();
    let e = s.engine("quit-engine", true, &[]);
    let quit = s.quit(&e);
    assert_eq!(quit["failedJobCount"], 1);
    assert_eq!(quit["requiresConfirmation"], true);
    let retried = e.invoke("retryJob", vec![failed["id"].clone()]).unwrap();
    let retry_id = retried["id"].as_str().unwrap();
    assert_ne!(retried["id"], failed["id"]);
    assert_eq!(s.wait(&e, retry_id, 35.)["status"], "completed");
    wait_until(3., || s.quit(&e)["activeJobCount"] == 0);
    let retained = s.quit(&e);
    assert_eq!(retained["activeJobCount"], 0);
    assert_eq!(retained["failedJobCount"], 1);
    assert_eq!(retained["requiresConfirmation"], true);
    e.invoke(
        "clearJobs",
        vec![json!({"ids":[failed["id"]],"mode":"finished"})],
    )
    .unwrap();
    let complete = s.quit(&e);
    for key in ["activeJobCount", "failedJobCount", "unfinishedJobCount"] {
        assert_eq!(complete[key], 0);
    }
    assert_eq!(complete["requiresConfirmation"], false);
    let rows = s.jobs(&e);
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["id"], retry_id);
    assert_eq!(
        fs::read(from.join("take.txt")).unwrap(),
        fs::read(to.join("take.txt")).unwrap()
    );
}
#[test]
fn only_failed_files_retry_and_full_scope_repeats_everything() {
    let s = Suite::new();
    let from = s.folder("retry/source");
    let to = s.root.join("retry/destination");
    for i in 0..20 {
        s.file(&from, &format!("ok/{i}.txt"), b"rclone browser test\n");
    }
    s.file(&from, "locked/secret.txt", b"rclone browser test\n");
    let locked = from.join("locked/secret.txt");
    let mut read_guard = ReadBlock::new(&locked);
    let e = s.engine("retry-engine", true, &[]);
    assert_eq!(s.settings(&e)["retryScope"], "failed");
    let request = s.request(
        &from,
        &to,
        "copy",
        false,
        json!([]),
        json!({"transfers":2,"checkers":2}),
        None,
        None,
    );
    let id = s.submit(&e, request.clone());
    let value = s.wait(&e, &id, 120.);
    assert_eq!(value["status"], "failed");
    assert!(number(&value["report"]["comparisonEvents"]) <= 30.);
    assert!(to.join("ok/19.txt").exists());
    assert!(number(&value["stats"]["errors"]) >= 1.);
    e.invoke("saveSettings", vec![json!({"retryScope":"full"})])
        .unwrap();
    fs::remove_dir_all(&to).unwrap();
    let id = s.submit(&e, request);
    let value = s.wait(&e, &id, 180.);
    assert_eq!(value["status"], "failed");
    assert_eq!(number(&value["report"]["lastAttempt"]), 3.);
    assert!(number(&value["report"]["comparisonEvents"]) >= 60.);
    read_guard.restore();
}
#[test]
fn temporary_file_error_retries_only_that_file_and_preserves_combined_statistics() {
    let s = Suite::new();
    let from = s.folder("temporary/source");
    let to = s.folder("temporary/destination");
    for i in 0..10 {
        s.file(&from, &format!("ok/{i}.txt"), b"rclone browser test\n");
    }
    s.file(&from, "big.bin", vec![0u8; 64 * 1024]);
    let fake = s.fake("temporary/bin", "temporary-retry");
    let e = s.engine("temporary-engine", true, &[]);
    let environment = e
        .invoke("saveSettings", vec![json!({"rclonePath":fake})])
        .unwrap();
    assert_eq!(environment["available"], true);
    let id = s.submit(
        &e,
        s.request(
            &from,
            &to,
            "copy",
            false,
            json!([]),
            json!({"transfers":2,"checkers":2}),
            None,
            None,
        ),
    );
    let value = s.wait(&e, &id, 120.);
    assert_eq!(value["status"], "completed", "{value}");
    assert_eq!(number(&value["report"]["lastAttempt"]), 2.);
    assert_eq!(number(&value["report"]["comparisonEvents"]), 12.);
    assert!(
        value["logs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|l| l["message"] == "第 2 輪：只重試上一輪失敗的 1 個檔案，不重掃其他檔案。")
    );
    assert_eq!(number(&value["stats"]["transfers"]), 11.);
    assert!(number(&value["stats"]["checks"]) >= 1.);
    assert!(to.join("big.bin").exists());
}
struct HttpRequest {
    at: Instant,
    agent: String,
    peer: String,
}
struct HttpBackend {
    port: u16,
    requests: Arc<Mutex<Vec<HttpRequest>>>,
    stop: Arc<AtomicBool>,
    worker: Option<thread::JoinHandle<()>>,
}
impl HttpBackend {
    fn new() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        listener.set_nonblocking(true).unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let requests = Arc::new(Mutex::new(vec![]));
        let flag = stop.clone();
        let rows = requests.clone();
        let worker = thread::spawn(move || {
            while !flag.load(Ordering::Acquire) {
                match listener.accept() {
                    Ok((mut stream, peer)) => {
                        stream
                            .set_read_timeout(Some(Duration::from_secs(2)))
                            .unwrap();
                        let mut bytes = vec![];
                        let mut buffer = [0u8; 4096];
                        while bytes.len() <= 16384 {
                            let Ok(n) = stream.read(&mut buffer) else {
                                break;
                            };
                            if n == 0 {
                                break;
                            }
                            bytes.extend_from_slice(&buffer[..n]);
                            if bytes.windows(4).any(|b| b == b"\r\n\r\n") {
                                break;
                            }
                        }
                        let text = String::from_utf8_lossy(&bytes);
                        let mut lines = text.split("\r\n");
                        let fields = lines
                            .next()
                            .unwrap_or("")
                            .split_whitespace()
                            .collect::<Vec<_>>();
                        if fields.len() < 2 {
                            continue;
                        }
                        let method = fields[0];
                        let path = fields[1].split('?').next().unwrap();
                        let agent = lines
                            .find_map(|l| {
                                let (k, v) = l.split_once(':')?;
                                k.eq_ignore_ascii_case("user-agent")
                                    .then(|| v.trim().to_owned())
                            })
                            .unwrap_or_default();
                        rows.lock().unwrap().push(HttpRequest {
                            at: Instant::now(),
                            agent,
                            peer: peer.ip().to_string(),
                        });
                        let body = if path == "/" {
                            "<html><body><a href=\"one.bin\">one.bin</a><a href=\"two.bin\">two.bin</a><a href=\"three.bin\">three.bin</a></body></html>"
                        } else {
                            "sample"
                        };
                        let header = format!(
                            "HTTP/1.1 200 OK\r\nContent-Type: {}\r\nContent-Length: {}\r\nLast-Modified: Tue, 14 Nov 2023 22:13:20 GMT\r\nConnection: close\r\n\r\n",
                            if path == "/" {
                                "text/html"
                            } else {
                                "application/octet-stream"
                            },
                            body.len()
                        );
                        let _ = stream.write_all(header.as_bytes());
                        if method != "HEAD" {
                            let _ = stream.write_all(body.as_bytes());
                        }
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(5))
                    }
                    Err(_) => break,
                }
            }
        });
        Self {
            port,
            requests,
            stop,
            worker: Some(worker),
        }
    }
}
impl Drop for HttpBackend {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        let _ = TcpStream::connect(("127.0.0.1", self.port));
        if let Some(worker) = self.worker.take() {
            worker.join().unwrap();
        }
    }
}
#[test]
fn real_http_network_honors_bind_literal_user_agent_pacing_and_task_overrides() {
    let s = Suite::new();
    let server = HttpBackend::new();
    let area = s.folder("network-real");
    let target = s.folder("network-real/destination");
    let config = area.join("rclone.conf");
    fs::write(
        &config,
        format!(
            "[httpfixture]\ntype = http\nurl = http://127.0.0.1:{}/\n",
            server.port
        ),
    )
    .unwrap();
    let e = s.engine("network-real-engine", true, &[]);
    let agent = "RBN/0.4 fixture \"literal\"";
    e.invoke("saveSettings",vec![json!({"configPath":config,"proxyMode":"manual","httpProxy":"","httpsProxy":"","noProxy":"127.0.0.1","networkOptions":{"bindMode":"address","bindAddress":"127.0.0.1","connectTimeout":"2s","ioTimeout":"3s","tpsLimit":2.0,"tpsBurst":1,"userAgent":agent,"disableHTTP2":true}})]).unwrap();
    let remote = json!({"remote":"httpfixture","path":""});
    let entries = e.invoke("list", vec![remote.clone()]).unwrap();
    assert_eq!(entries.as_array().unwrap().len(), 3);
    assert_eq!(
        entries
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v["name"].as_str().unwrap())
            .collect::<BTreeSet<_>>(),
        BTreeSet::from(["one.bin", "two.bin", "three.bin"])
    );
    {
        let requests = server.requests.lock().unwrap();
        assert!(requests.len() >= 4);
        assert!(
            requests
                .iter()
                .all(|r| r.agent == agent && r.peer == "127.0.0.1")
        );
        assert!(
            requests
                .last()
                .unwrap()
                .at
                .duration_since(requests.first().unwrap().at)
                >= Duration::from_millis(900)
        );
    }
    let context = e.auxiliary_context().unwrap();
    for flag in ["--contimeout=2s", "--timeout=3s", "--disable-http2=true"] {
        assert!(context.arguments.contains(&flag.into()));
    }
    let mut transfer=s.request(&area,&target,"copy",false,json!([{"name":"one.bin","isDir":false}]),json!({"connectTimeout":"7s","ioTimeout":"","extraArgs":["--tpslimit=0","--disable-http2=false"]}),None,None);
    transfer["source"] = remote;
    let copied = s.completed(&e, transfer);
    assert_eq!(
        fs::read_to_string(target.join("one.bin")).unwrap(),
        "sample"
    );
    let command = copied["command"].as_str().unwrap();
    for flag in [
        "--contimeout=7s",
        "--timeout=3s",
        "--tpslimit=0",
        "--disable-http2=false",
    ] {
        assert!(command.contains(flag), "{command}");
    }
    for flag in ["--contimeout=2s", "--tpslimit=2.0", "--disable-http2=true"] {
        assert!(!command.contains(flag), "{command}");
    }
}
#[test]
fn unlimited_scheduling_is_immediate_and_history_never_evicts_active_or_saved_work() {
    let s = Suite::new();
    let from = s.folder("history/source");
    let state = s.folder("history-engine/state");
    let destinations = (0..3)
        .map(|i| s.folder(&format!("history/target-{i}")))
        .collect::<Vec<_>>();
    s.file(&from, "large.bin", vec![0x6a; 4 * 1024 * 1024]);
    let options = json!({"bandwidth":"1K","extraArgs":["--local-no-clone"]});
    let request = s.request(
        &from,
        &destinations[0],
        "copy",
        false,
        json!([]),
        options.clone(),
        None,
        None,
    );
    let task = json!({"id":uuid::Uuid::new_v4().to_string(),"name":"不受歷史上限影響","request":request,"createdAt":"2023-01-01T00:00:00Z","updatedAt":"2023-01-01T00:00:00Z"});
    let old = (0..202)
        .map(|i| {
            let mut j = job_fixture(&request, "failed", "history fixture");
            j["endedAt"] = json!(
                chrono::DateTime::<chrono::Utc>::from_timestamp(1_600_000_000 + i, 0)
                    .unwrap()
                    .to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
            );
            j
        })
        .collect::<Vec<_>>();
    storage::atomic_json(&state.join("jobs.json"), &json!(old)).unwrap();
    storage::atomic_json(&state.join("tasks.json"), &json!([task])).unwrap();
    let e = s.engine("history-engine", true, &[]);
    e.invoke("saveSettings", vec![json!({"maxConcurrentJobs":1})])
        .unwrap();
    let retained = s.jobs(&e);
    assert_eq!(retained.len(), 200);
    assert!(
        !retained
            .iter()
            .any(|j| j["id"] == old[0]["id"] || j["id"] == old[1]["id"])
    );
    let ids = destinations
        .iter()
        .map(|to| {
            s.submit(
                &e,
                s.request(
                    &from,
                    to,
                    "copy",
                    false,
                    json!([]),
                    options.clone(),
                    None,
                    None,
                ),
            )
        })
        .collect::<Vec<_>>();
    let pending = s.jobs(&e);
    assert_eq!(pending.len(), 203);
    assert_eq!(
        pending.iter().filter(|j| j["status"] == "queued").count(),
        2
    );
    let quit = s.quit(&e);
    assert_eq!(quit["requiresConfirmation"], true);
    assert_eq!(quit["activeJobCount"], 3);
    assert_eq!(quit["failedJobCount"], 200);
    e.invoke("saveSettings", vec![json!({"maxConcurrentJobs":0})])
        .unwrap();
    for id in &ids {
        assert_eq!(s.job(&e, id)["status"], "running");
    }
    let tasks = e.invoke("listTasks", vec![]).unwrap();
    assert_eq!(tasks.as_array().unwrap().len(), 1);
    assert_eq!(tasks[0]["id"], task["id"]);
    e.invoke("_shutdown", vec![]).unwrap();
    let final_history = read_json(&state.join("jobs.json"));
    assert_eq!(final_history.as_array().unwrap().len(), 203);
    for id in ids {
        assert!(
            final_history
                .as_array()
                .unwrap()
                .iter()
                .any(|j| j["id"] == id)
        );
    }
}
#[test]
fn confirmed_request_keeps_delete_limit_and_filters_after_global_defaults_change() {
    let s = Suite::new();
    let from = s.folder("confirmation/source");
    let to = s.folder("confirmation/destination");
    for (path, name) in [
        (&from, "current.bin"),
        (&to, "obsolete.bin"),
        (&to, "protected.keep"),
    ] {
        s.file(path, name, b"rclone browser test\n");
    }
    let e = s.engine("confirmation-engine", true, &[]);
    e.invoke(
        "saveSettings",
        vec![json!({"defaultTransferOptions":{"maxDelete":-1,"exclude":["*.keep"]}})],
    )
    .unwrap();
    let mut partial = s.basic(&from, &to);
    partial["mode"] = json!("sync");
    partial["options"] = json!({"deleteMode":"before"});
    let confirmed = e
        .invoke("_normalizeTransfer", vec![partial.clone()])
        .unwrap();
    assert_eq!(confirmed["options"]["maxDelete"], -1);
    assert_eq!(confirmed["options"]["exclude"], json!(["*.keep"]));
    e.invoke(
        "saveSettings",
        vec![json!({"defaultTransferOptions":{"maxDelete":0,"exclude":[],"deleteMode":"after"}})],
    )
    .unwrap();
    assert_eq!(
        e.invoke("_normalizeTransfer", vec![partial]).unwrap()["options"]["maxDelete"],
        0
    );
    let preview = e
        .invoke("previewTransfer", vec![confirmed.clone()])
        .unwrap();
    assert!(
        preview["warnings"]
            .as_array()
            .unwrap()
            .iter()
            .any(|w| w.as_str().unwrap().contains("本次不限刪除數量"))
    );
    let result = s.completed(&e, confirmed.clone());
    assert_eq!(result["request"], confirmed);
    let command = result["command"].as_str().unwrap();
    assert!(command.contains("--max-delete=-1") && command.contains("--delete-before"));
    assert!(!to.join("obsolete.bin").exists());
    assert!(to.join("protected.keep").exists());
}
#[test]
fn real_comparison_choices_make_distinct_content_and_transfer_counter_decisions() {
    let s = Suite::new();
    for (i, (mode, source, target, same_date, copy)) in [
        ("default", "ABCDEF", "UVWXYZ", false, true),
        ("size", "ABCDEF", "UVWXYZ", false, false),
        ("modtime", "ABCDEF", "short", true, false),
        ("default", "ABCDEF", "short", true, true),
        ("checksum", "ABCDEF", "UVWXYZ", true, true),
        ("checksum-only", "ABCDEF", "UVWXYZ", true, true),
        ("none", "ABCDEF", "ABCDEF", true, true),
    ]
    .into_iter()
    .enumerate()
    {
        let from = s.folder(&format!("comparisons/{i}/source"));
        let to = s.folder(&format!("comparisons/{i}/destination"));
        s.file(&from, "sample.txt", source);
        s.file(&to, "sample.txt", target);
        s.modified(&from, "sample.txt", 1_700_000_000.);
        s.modified(
            &to,
            "sample.txt",
            if same_date {
                1_700_000_000.
            } else {
                1_600_000_000.
            },
        );
        let e = s.engine(&format!("comparison-engine-{i}"), true, &[("target", &to)]);
        let job = s.completed(
            &e,
            s.request(
                &from,
                &to,
                "copy",
                false,
                json!([]),
                json!({"comparison":mode,"localHashPolicy":"default"}),
                None,
                Some("target"),
            ),
        );
        assert_eq!(
            fs::read_to_string(to.join("sample.txt")).unwrap(),
            if copy { source } else { target }
        );
        assert_eq!(number(&job["stats"]["transfers"]) > 0., copy);
    }
}
#[test]
fn nas_hash_policy_detects_same_size_newer_content_and_skips_unchanged_repeat() {
    let s = Suite::new();
    let from = s.folder("nas/source");
    let to = s.folder("nas/destination");
    let current = vec![0x41; 4096];
    s.file(&from, "backup.bin", &current);
    s.file(&to, "backup.bin", vec![0x42; 4096]);
    s.modified(&from, "backup.bin", 1_700_000_000.);
    s.modified(&to, "backup.bin", 1_600_000_000.);
    let e = s.engine("nas-engine", true, &[("target", &to)]);
    let request = s.request(
        &from,
        &to,
        "copy",
        false,
        json!([]),
        json!({"comparison":"default","localHashPolicy":"none"}),
        None,
        Some("target"),
    );
    let copied = s.completed(&e, request.clone());
    assert_eq!(fs::read(to.join("backup.bin")).unwrap(), current);
    let command = copied["command"].as_str().unwrap();
    assert!(command.contains("--local-hashes=none"));
    assert!(!command.contains("--size-only") && !command.contains("--local-no-check-updated"));
    let repeated = s.completed(&e, request);
    assert_eq!(number(&repeated["stats"]["transfers"]), 0.);
}
#[cfg(target_os = "linux")]
#[test]
fn nas_kernel_reads_distinguish_hash_policy_from_ignore_checksum() {
    let s = Suite::new();
    for (i, (options, read, transfer)) in [
        (json!({"localHashPolicy":"default"}), true, true),
        (
            json!({"ignoreChecksum":true,"localHashPolicy":"default"}),
            true,
            true,
        ),
        (json!({"localHashPolicy":"none"}), false, true),
        (json!({"comparison":"size"}), false, false),
    ]
    .into_iter()
    .enumerate()
    {
        let from = s.folder(&format!("nas-read/{i}/source"));
        let to = s.folder(&format!("nas-read/{i}/destination"));
        s.file(&from, "sample.bin", vec![0x41; 1024 * 1024]);
        s.file(&to, "sample.bin", vec![0x42; 1024 * 1024]);
        s.modified(&from, "sample.bin", 1_700_000_000.);
        s.modified(&to, "sample.bin", 1_600_000_000.);
        let e = s.engine(&format!("nas-read-engine-{i}"), true, &[("target", &to)]);
        use std::os::unix::ffi::OsStrExt;
        let name = std::ffi::CString::new(to.join("sample.bin").as_os_str().as_bytes()).unwrap();
        let fd = unsafe { libc::inotify_init1(libc::IN_NONBLOCK | libc::IN_CLOEXEC) };
        assert!(fd >= 0);
        assert!(
            unsafe { libc::inotify_add_watch(fd, name.as_ptr(), libc::IN_OPEN | libc::IN_ACCESS) }
                >= 0
        );
        let job = s.completed(
            &e,
            s.request(
                &from,
                &to,
                "copy",
                true,
                json!([]),
                options.clone(),
                None,
                Some("target"),
            ),
        );
        let mut masks = 0u32;
        let mut bytes = [0u8; 8192];
        loop {
            let n = unsafe { libc::read(fd, bytes.as_mut_ptr().cast(), bytes.len()) };
            if n <= 0 {
                break;
            }
            let mut offset = 0;
            while offset + 16 <= n as usize {
                let mask = u32::from_ne_bytes(bytes[offset + 4..offset + 8].try_into().unwrap());
                let len = u32::from_ne_bytes(bytes[offset + 12..offset + 16].try_into().unwrap());
                masks |= mask;
                offset += 16 + len as usize;
            }
        }
        unsafe {
            libc::close(fd);
        };
        assert_eq!(masks & libc::IN_ACCESS != 0, read, "{options}");
        if !read {
            assert_eq!(masks & libc::IN_OPEN, 0);
        }
        assert_eq!(number(&job["stats"]["transfers"]) > 0., transfer);
    }
}
#[test]
fn sync_deletion_before_during_after_preserves_excluded_files_until_explicit_permission() {
    let s = Suite::new();
    for timing in ["before", "during", "after"] {
        let from = s.folder(&format!("delete/{timing}/source"));
        let to = s.folder(&format!("delete/{timing}/destination"));
        s.file(&from, "current.txt", b"rclone browser test\n");
        s.file(&to, "obsolete.txt", b"rclone browser test\n");
        s.file(&to, "excluded.tmp", b"rclone browser test\n");
        let e = s.engine(&format!("delete-engine-{timing}"), true, &[("target", &to)]);
        let mut request = s.request(
            &from,
            &to,
            "sync",
            false,
            json!([]),
            json!({"deleteMode":timing,"exclude":["*.tmp"]}),
            None,
            Some("target"),
        );
        s.completed(&e, request.clone());
        assert!(to.join("current.txt").exists());
        assert!(!to.join("obsolete.txt").exists());
        assert!(to.join("excluded.tmp").exists());
        request["options"]["deleteExcluded"] = json!(true);
        s.completed(&e, request);
        assert!(!to.join("excluded.tmp").exists());
    }
}
#[test]
fn real_size_age_and_depth_filters_restrict_alias_transfer_to_exact_file() {
    let s = Suite::new();
    let from = s.folder("ranges/source");
    let to = s.folder("ranges/destination");
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs_f64();
    for (name, bytes, age) in [
        ("take.bin", 12, 7200.),
        ("small.bin", 2, 7200.),
        ("large.bin", 30, 7200.),
        ("too-new.bin", 12, 30.),
        ("too-old.bin", 12, 900000.),
        ("sub/deep.bin", 12, 7200.),
    ] {
        s.file(&from, name, vec![0x33; bytes]);
        s.modified(&from, name, now - age);
    }
    let e = s.engine("ranges-engine", true, &[("source", &from)]);
    s.completed(&e,s.request(&from,&to,"copy",false,json!([]),json!({"minSize":"8B","maxSize":"20B","minAge":"1h","maxAge":"2d","maxDepth":1,"createEmptyDirs":false,"checkFirst":true,"fastList":true,"noTraverse":true,"oneFileSystem":true,"extraArgs":["--buffer-size=1M"]}),Some("source"),None));
    assert_eq!(
        fs::read_dir(to)
            .unwrap()
            .map(|e| e.unwrap().file_name().into_string().unwrap())
            .collect::<Vec<_>>(),
        ["take.bin"]
    );
}
#[test]
fn skip_existing_preserves_move_source_and_no_update_modtime_keeps_original_timestamp() {
    let s = Suite::new();
    let from = s.folder("skip/source");
    let to = s.folder("skip/destination");
    for name in ["existing.txt", "newer.txt"] {
        s.file(&from, name, b"source");
        s.file(&to, name, b"target");
    }
    s.modified(&from, "newer.txt", 1_600_000_000.);
    s.modified(&to, "newer.txt", 1_700_000_000.);
    let e = s.engine("skip-engine", true, &[]);
    s.completed(
        &e,
        s.request(
            &from,
            &to,
            "move",
            false,
            json!([{"name":"existing.txt","isDir":false}]),
            json!({"skipExisting":true}),
            None,
            None,
        ),
    );
    assert!(
        e.invoke(
            "startTransfer",
            vec![s.request(
                &from,
                &to,
                "move",
                false,
                json!([{"name":"newer.txt","isDir":false}]),
                json!({"updateOnly":true}),
                None,
                None
            )]
        )
        .is_err()
    );
    s.completed(
        &e,
        s.request(
            &from,
            &to,
            "copy",
            false,
            json!([{"name":"newer.txt","isDir":false}]),
            json!({"updateOnly":true}),
            None,
            None,
        ),
    );
    for name in ["existing.txt", "newer.txt"] {
        assert!(from.join(name).exists());
        assert_eq!(fs::read_to_string(to.join(name)).unwrap(), "target");
    }
    s.file(&from, "same.txt", b"same");
    s.file(&to, "same.txt", b"same");
    s.modified(&from, "same.txt", 1_700_000_000.);
    s.modified(&to, "same.txt", 1_600_000_000.);
    s.completed(
        &e,
        s.request(
            &from,
            &to,
            "copy",
            false,
            json!([{"name":"same.txt","isDir":false}]),
            json!({"noUpdateModtime":true,"localHashPolicy":"default"}),
            None,
            None,
        ),
    );
    let retained = fs::metadata(to.join("same.txt"))
        .unwrap()
        .modified()
        .unwrap()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs_f64();
    assert!((retained - 1_600_000_000.).abs() < 1.);
    let job = s.completed(
        &e,
        s.request(
            &from,
            &to,
            "copy",
            false,
            json!([{"name":"same.txt","isDir":false}]),
            json!({"noUpdateModtime":true}),
            None,
            None,
        ),
    );
    assert_eq!(number(&job["stats"]["transfers"]), 1.);
}
#[test]
fn proxy_context_global_options_and_persisted_defaults_drive_real_operations() {
    let s = Suite::new();
    let from = s.folder("defaults/source");
    let to = s.folder("defaults/destination");
    s.file(&from, "take.txt", b"AAAA");
    s.file(&to, "take.txt", b"BBBB");
    let e = s.engine("defaults-engine", true, &[("source", &from)]);
    e.invoke("saveSettings",vec![json!({"proxyMode":"manual","httpProxy":"http://127.0.0.1:7890","httpsProxy":"socks5://127.0.0.1:7891","noProxy":"localhost,127.0.0.1","defaultRcloneOptions":["--buffer-size=2M","--multi-thread-streams=0"],"defaultTransferOptions":{"comparison":"size"}})]).unwrap();
    let context = e.auxiliary_context().unwrap();
    assert_eq!(context.binary, real_binary());
    assert_eq!(context.environment["HTTP_PROXY"], "http://127.0.0.1:7890");
    assert_eq!(
        context.environment["HTTPS_PROXY"],
        "socks5://127.0.0.1:7891"
    );
    assert!(context.arguments.contains(&"--buffer-size=2M".into()));
    assert!(!context.arguments.join("").contains("7890"));
    let mut request = s.basic(&from, &to);
    request["options"] = json!({"extraArgs":["--buffer-size=1M"]});
    let job = s.completed(&e, request);
    assert_eq!(fs::read_to_string(to.join("take.txt")).unwrap(), "BBBB");
    let command = job["command"].as_str().unwrap();
    assert!(
        command.contains("--buffer-size=1M")
            && !command.contains("--buffer-size=2M")
            && command.contains("--size-only")
            && !command.contains("7890")
    );
    assert_eq!(
        number(
            &e.invoke("size", vec![s.endpoint(&from, Some("source"))])
                .unwrap()["bytes"]
        ),
        4.
    );
}
#[test]
fn real_local_and_alias_endpoint_matrix_preserves_exact_content_and_selection() {
    let s = Suite::new();
    let name = "照片與文件 [1].txt";
    let bytes = "endpoint matrix — exact bytes\n".as_bytes();
    for (i, (sr, dr)) in [
        (None, None),
        (None, Some("target")),
        (Some("source"), None),
        (Some("source"), Some("target")),
    ]
    .into_iter()
    .enumerate()
    {
        let from = s.folder(&format!("matrix/{i}/source"));
        let to = s.folder(&format!("matrix/{i}/destination"));
        s.file(&from, name, bytes);
        s.file(&from, "not-selected.txt", b"rclone browser test\n");
        let e = s.engine(
            &format!("matrix-engine-{i}"),
            true,
            &[("source", &from), ("target", &to)],
        );
        let job = s.completed(
            &e,
            s.request(
                &from,
                &to,
                "copy",
                false,
                json!([{"name":name,"isDir":false}]),
                json!({}),
                sr,
                dr,
            ),
        );
        assert!(number(&job["stats"]["speed"]) > 0.);
        assert_eq!(job["stats"]["speedKind"], "overall");
        assert_eq!(fs::read(to.join(name)).unwrap(), bytes);
        assert!(!to.join("not-selected.txt").exists());
        assert!(from.join(name).exists());
    }
}
#[test]
fn dry_run_does_not_mutate_and_literal_metacharacter_selections_copy_precisely() {
    let s = Suite::new();
    let from = s.folder("literal/source");
    let to = s.folder("literal/destination");
    let names = [
        "report[1]*?{a}.txt",
        " leading and trailing ",
        "literal\\name.txt",
    ];
    for name in names {
        s.file(&from, name, b"rclone browser test\n");
    }
    for name in ["report1other.txt", "unselected.txt", ".DS_Store"] {
        s.file(&from, name, b"rclone browser test\n");
    }
    fs::create_dir_all(from.join("empty[1]")).unwrap();
    let e = s.engine("literal-engine", true, &[]);
    let mut selected = names.map(|n| json!({"name":n,"isDir":false})).to_vec();
    selected.push(json!({"name":"empty[1]","isDir":true}));
    let mut request = s.request(
        &from,
        &to,
        "copy",
        true,
        json!(selected),
        json!({}),
        None,
        None,
    );
    let dry = s.completed(&e, request.clone());
    assert!(fs::read_dir(&to).unwrap().next().is_none());
    assert_eq!(number(&dry["report"]["successEvents"]), 0.);
    assert!(number(&dry["report"]["plannedEvents"]) > 0.);
    request["dryRun"] = json!(false);
    let job = s.completed(&e, request);
    for name in names.into_iter().chain(["empty[1]"]) {
        assert!(to.join(name).exists(), "literal missing {name}");
    }
    assert!(!to.join("unselected.txt").exists() && !to.join("report1other.txt").exists());
    let path = e.invoke("getLogPath", vec![job["id"].clone()]).unwrap();
    let text = fs::read_to_string(path.as_str().unwrap()).unwrap();
    assert!(text.contains("\"stats\"") && text.contains("Copied"));
}
#[test]
fn selected_folders_intersect_include_and_exclude_without_widening() {
    let s = Suite::new();
    let from = s.folder("intersection/source");
    let to = s.folder("intersection/destination");
    for name in [
        "take[1]/keep.txt",
        "take[1]/skip.bin",
        "take[1]/excluded.txt",
        "take1/other.txt",
        "outside.txt",
    ] {
        s.file(&from, name, b"rclone browser test\n");
    }
    let e = s.engine("intersection-engine", true, &[]);
    s.completed(
        &e,
        s.request(
            &from,
            &to,
            "copy",
            false,
            json!([{"name":"take[1]","isDir":true}]),
            json!({"include":["*.txt"],"exclude":["excluded.txt"]}),
            None,
            None,
        ),
    );
    assert!(to.join("take[1]/keep.txt").exists());
    for name in [
        "take[1]/skip.bin",
        "take[1]/excluded.txt",
        "take1/other.txt",
        "outside.txt",
    ] {
        assert!(!to.join(name).exists(), "scope widened to {name}");
    }
}
#[test]
fn selected_sync_preserves_unselected_scopes_excluded_bytes_and_empty_folder_boundaries() {
    let s = Suite::new();
    for timing in ["before", "during", "after"] {
        let from = s.folder(&format!("scoped/{timing}/source"));
        let to = s.folder(&format!("scoped/{timing}/destination"));
        let selected = ["take[1]*?{a}", "資料夾 B"];
        for name in selected {
            s.file(
                &from,
                &format!("{name}/nested/current.txt"),
                format!("new source {name}"),
            );
            s.file(
                &from,
                &format!("{name}/.DS_Store"),
                b"rclone browser test\n",
            );
            s.file(
                &to,
                &format!("{name}/stale/nested/obsolete.txt"),
                b"obsolete",
            );
            s.file(&to, &format!("{name}/.DS_Store"), b"excluded destination");
        }
        let protected = [
            "other/keep.txt",
            "take1other/keep.txt",
            "root-only.txt",
            "outside-new.txt",
        ];
        for name in protected {
            s.file(&to, name, format!("unchanged {name}"));
        }
        s.file(
            &from,
            "other/keep.txt",
            b"must not replace outside selection",
        );
        s.file(&from, "outside-new.txt", b"must not replace root file");
        let e = s.engine(&format!("scoped-engine-{timing}"), true, &[("target", &to)]);
        let mut request = s.request(
            &from,
            &to,
            "sync",
            true,
            json!(selected.map(|n| json!({"name":n,"isDir":true}))),
            json!({"deleteMode":timing,"fastList":true}),
            None,
            Some("target"),
        );
        s.completed(&e, request.clone());
        for name in selected {
            assert!(
                to.join(format!("{name}/stale/nested/obsolete.txt"))
                    .exists()
            );
            assert!(!to.join(format!("{name}/nested/current.txt")).exists());
        }
        request["dryRun"] = json!(false);
        s.completed(&e, request);
        for name in selected {
            assert_eq!(
                fs::read_to_string(to.join(format!("{name}/nested/current.txt"))).unwrap(),
                format!("new source {name}")
            );
            assert!(!to.join(format!("{name}/stale")).exists());
            assert_eq!(
                fs::read_to_string(to.join(format!("{name}/.DS_Store"))).unwrap(),
                "excluded destination"
            );
        }
        for name in protected {
            assert_eq!(
                fs::read_to_string(to.join(name)).unwrap(),
                format!("unchanged {name}")
            );
        }
    }
}
#[test]
fn selected_sync_include_scope_uses_source_and_destination_and_deletes_stale_matches() {
    let s = Suite::new();
    let from = s.folder("scoped-includes/source");
    let to = s.folder("scoped-includes/destination");
    for name in [
        "take[1]/current.txt",
        "take[1]/nested/current.txt",
        "take[1]/excluded.txt",
        "take[1]/skip.jpg",
        "other/only-here.dat",
        "other/not-included.txt",
        "outside.txt",
        "unselected/new.txt",
    ] {
        s.file(&from, name, b"rclone browser test\n");
    }
    let stale = [
        "take[1]/stale.txt",
        "take[1]/deep/stale.txt",
        "other/obsolete.dat",
    ];
    for name in stale {
        s.file(&to, name, b"rclone browser test\n");
    }
    let protected = [
        "take[1]/keep.jpg",
        "take[1]/excluded.txt",
        "take[1]/.DS_Store",
        "take[1]/deep/keep.jpg",
        "other/not-included.txt",
        "unselected/stale.txt",
        "outside.txt",
    ];
    for name in protected {
        s.file(&to, name, format!("protected {name}"));
    }
    let e = s.engine("scoped-includes-engine", true, &[("target", &to)]);
    s.completed(&e,s.request(&from,&to,"sync",false,json!([{"name":"take[1]","isDir":true},{"name":"other","isDir":true}]),json!({"include":["/take\\[1\\]/*.txt","/take\\[1\\]/**/*.txt","/other/*.dat"],"exclude":["excluded.txt",".DS_Store"],"fastList":true}),None,Some("target")));
    for name in [
        "take[1]/current.txt",
        "take[1]/nested/current.txt",
        "other/only-here.dat",
    ] {
        assert!(to.join(name).exists());
    }
    for name in stale {
        assert!(!to.join(name).exists());
    }
    for name in protected {
        assert_eq!(
            fs::read_to_string(to.join(name)).unwrap(),
            format!("protected {name}")
        );
    }
    for name in ["take[1]/skip.jpg", "unselected/new.txt"] {
        assert!(!to.join(name).exists());
    }
}
#[test]
fn selected_sync_creates_missing_target_and_never_treats_failed_listing_as_empty() {
    let s = Suite::new();
    let from = s.folder("scoped-missing/source");
    let parent = s.folder("scoped-missing/targets");
    for name in ["take/current.txt", "other/outside.txt"] {
        s.file(&from, name, b"rclone browser test\n");
    }
    for remote in [false, true] {
        let to = parent.join(if remote { "remote-new" } else { "local-new" });
        let e = s.engine(
            &format!("scoped-missing-engine-{remote}"),
            true,
            &[("target", &to)],
        );
        s.completed(
            &e,
            s.request(
                &from,
                &to,
                "sync",
                false,
                json!([{"name":"take","isDir":true}]),
                json!({"include":["*.txt"]}),
                None,
                remote.then_some("target"),
            ),
        );
        assert!(to.join("take/current.txt").exists());
        assert!(!to.join("other").exists());
    }
    let to = s.folder("scoped-missing/filter-error-target");
    s.file(&to, "take/protected.txt", b"leave unchanged");
    let e = s.engine("scoped-invalid-engine", true, &[]);
    let id = s.submit(
        &e,
        s.request(
            &from,
            &to,
            "sync",
            false,
            json!([{"name":"take","isDir":true}]),
            json!({"include":["{{("]}),
            None,
            None,
        ),
    );
    assert_eq!(s.wait(&e, &id, 35.)["status"], "failed");
    assert_eq!(
        fs::read_to_string(to.join("take/protected.txt")).unwrap(),
        "leave unchanged"
    );
}
#[test]
fn repeated_sync_transfers_zero_unchanged_bytes_and_honors_timestamp_precision() {
    let s = Suite::new();
    let from = s.folder("repeat/source");
    let to = s.folder("repeat/destination");
    let e = s.engine("repeat-engine", true, &[]);
    let initial = vec![0x41; 8192];
    let changed = vec![0x42; 8192];
    let time = 1_700_000_000.123456;
    s.file(&from, "sample.bin", initial);
    s.modified(&from, "sample.bin", time);
    let request = s.request(&from, &to, "sync", false, json!([]), json!({}), None, None);
    s.completed(&e, request.clone());
    let repeated = s.completed(&e, request.clone());
    assert_eq!(number(&repeated["stats"]["bytes"]), 0.);
    assert_eq!(number(&repeated["stats"]["transfers"]), 0.);
    assert_eq!(number(&repeated["report"]["matchedEvents"]), 1.);
    assert!(repeated["report"]["skippedFiles"].is_null());
    let skipped = e
        .invoke(
            "getJobReport",
            vec![repeated["id"].clone(), json!({"category":"skipped"})],
        )
        .unwrap();
    assert_eq!(skipped["items"].as_array().unwrap().len(), 1);
    assert_eq!(skipped["items"][0]["path"], "sample.bin");
    assert_eq!(skipped["items"][0]["status"], "matched");
    s.modified(&to, "sample.bin", 1_700_000_000.12);
    let mut request = request;
    request["options"]["modifyWindow"] = json!("10ms");
    let quantized = s.completed(&e, request.clone());
    assert_eq!(number(&quantized["stats"]["bytes"]), 0.);
    assert_eq!(number(&quantized["stats"]["transfers"]), 0.);
    s.file(&from, "sample.bin", &changed);
    s.modified(&from, "sample.bin", time + 5.);
    let updated = s.completed(&e, request.clone());
    assert_eq!(number(&updated["stats"]["transfers"]), 1.);
    assert_eq!(fs::read(to.join("sample.bin")).unwrap(), changed);
    let command = updated["command"].as_str().unwrap();
    assert!(
        command.contains("--local-hashes=none")
            && command.contains("--modify-window=10ms")
            && !command.contains("--size-only")
            && !command.contains("--ignore-times")
    );
    assert_eq!(
        command.contains("--local-no-clone"),
        cfg!(target_os = "macos")
    );
    assert_eq!(number(&s.completed(&e, request)["stats"]["bytes"]), 0.);
}

struct ReadBlock {
    path: PathBuf,
    active: bool,
    permissions: fs::Permissions,
    #[cfg(windows)]
    principal: String,
}
impl ReadBlock {
    fn new(path: &Path) -> Self {
        let permissions = fs::metadata(path).unwrap().permissions();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(path, fs::Permissions::from_mode(0o0)).unwrap();
        }
        #[cfg(windows)]
        let principal = {
            let user = std::env::var("USERNAME").expect("Windows fixture user");
            let domain = std::env::var("USERDOMAIN").unwrap_or_default();
            let user = if domain.is_empty() {
                user
            } else {
                format!("{domain}\\{user}")
            };
            let executable =
                PathBuf::from(std::env::var_os("SystemRoot").expect("Windows system root"))
                    .join("System32/icacls.exe");
            let result = Command::new(executable)
                .arg(path)
                .arg("/deny")
                .arg(format!("{user}:(R)"))
                .output()
                .unwrap();
            assert!(result.status.success(), "isolated fixture read deny failed");
            user
        };
        Self {
            path: path.to_owned(),
            active: true,
            permissions,
            #[cfg(windows)]
            principal,
        }
    }
    fn restore(&mut self) {
        if !self.active {
            return;
        }
        #[cfg(windows)]
        {
            let executable =
                PathBuf::from(std::env::var_os("SystemRoot").unwrap()).join("System32/icacls.exe");
            let result = Command::new(executable)
                .arg(&self.path)
                .arg("/remove:d")
                .arg(&self.principal)
                .output()
                .unwrap();
            assert!(
                result.status.success(),
                "isolated fixture ACL restoration failed"
            );
        }
        fs::set_permissions(&self.path, self.permissions.clone()).unwrap();
        self.active = false;
    }
}
impl Drop for ReadBlock {
    fn drop(&mut self) {
        self.restore();
    }
}
#[test]
fn empty_session_and_saved_tasks_never_request_quit_confirmation() {
    let s = Suite::new();
    let from = s.folder("quit-empty/source");
    let to = s.folder("quit-empty/destination");
    let e = s.engine("quit-empty-engine", false, &[]);
    assert_eq!(s.quit(&e)["requiresConfirmation"], false);
    e.invoke(
        "saveTask",
        vec![json!("尚未執行的作業"), s.basic(&from, &to)],
    )
    .unwrap();
    let quit = s.quit(&e);
    assert_eq!(quit["requiresConfirmation"], false);
    for key in ["activeJobCount", "failedJobCount", "unfinishedJobCount"] {
        assert_eq!(quit[key], 0);
    }
}
#[test]
fn startup_clears_only_successful_history_and_preserves_unfinished_requests_logs_and_errors() {
    let s = Suite::new();
    let from = s.folder("restart/source");
    let to = s.folder("restart/destination");
    let state = s.folder("restart-engine/state");
    let logs = s.folder("restart-engine/state/logs");
    let statuses = [
        "completed",
        "failed",
        "cancelled",
        "interrupted",
        "queued",
        "running",
        "cancelling",
        "paused",
    ];
    let saved = statuses.map(|status| {
        let mut j = job_fixture(&s.basic(&from, &to), status, "restart fixture");
        if status == "failed" {
            j["error"] = json!("fixture transfer failed");
        }
        s.file(
            &logs,
            &format!("{}.jsonl", j["id"].as_str().unwrap()),
            status,
        );
        j
    });
    storage::atomic_json(&state.join("jobs.json"), &json!(saved)).unwrap();
    let e = s.engine("restart-engine", false, &[]);
    let jobs = s.jobs(&e);
    assert_eq!(jobs.len(), 7);
    let quit = s.quit(&e);
    assert_eq!(quit["activeJobCount"], 0);
    assert_eq!(quit["requiresConfirmation"], true);
    assert_eq!(quit["failedJobCount"], 1);
    assert_eq!(quit["unfinishedJobCount"], 6);
    assert!(!jobs.iter().any(|j| j["id"] == saved[0]["id"]));
    for (i, old) in saved.iter().enumerate().skip(1) {
        let current = s.job(&e, old["id"].as_str().unwrap());
        assert_eq!(
            current["status"],
            if ["failed", "cancelled", "interrupted"].contains(&statuses[i]) {
                statuses[i]
            } else {
                "interrupted"
            }
        );
        assert!(
            logs.join(format!("{}.jsonl", old["id"].as_str().unwrap()))
                .exists()
        );
    }
    assert_eq!(
        s.job(&e, saved[1]["id"].as_str().unwrap())["error"],
        "fixture transfer failed"
    );
    assert!(
        !logs
            .join(format!("{}.jsonl", saved[0]["id"].as_str().unwrap()))
            .exists()
    );
    let persisted = read_json(&state.join("jobs.json"));
    assert_eq!(persisted.as_array().unwrap().len(), 7);
    assert!(
        !persisted
            .as_array()
            .unwrap()
            .iter()
            .any(|j| j["status"] == "completed")
    );
}
#[test]
fn more_than_200_interrupted_requests_survive_startup_and_shutdown_beside_terminal_retention() {
    let s = Suite::new();
    let from = s.folder("unfinished/source");
    let to = s.folder("unfinished/destination");
    let state = s.folder("unfinished-engine/state");
    let statuses = ["interrupted", "queued", "running", "cancelling", "paused"];
    let unfinished = (0..205)
        .map(|i| {
            job_fixture(
                &s.basic(&from, &to),
                statuses[i % 5],
                "unfinished request fixture",
            )
        })
        .collect::<Vec<_>>();
    let ended = (0..202)
        .map(|i| {
            let mut j = job_fixture(
                &s.basic(&from, &to),
                if i % 2 == 0 { "failed" } else { "cancelled" },
                "ended request fixture",
            );
            j["endedAt"] = json!(
                chrono::DateTime::<chrono::Utc>::from_timestamp(1_600_000_000 + i, 0)
                    .unwrap()
                    .to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
            );
            j
        })
        .collect::<Vec<_>>();
    let all = unfinished.iter().chain(&ended).cloned().collect::<Vec<_>>();
    storage::atomic_json(&state.join("jobs.json"), &json!(all)).unwrap();
    let e = s.engine("unfinished-engine", false, &[]);
    let rows = s.jobs(&e);
    assert_eq!(rows.len(), 405);
    assert_eq!(
        rows.iter().filter(|j| j["status"] == "interrupted").count(),
        205
    );
    assert_eq!(s.quit(&e)["activeJobCount"], 0);
    for old in &unfinished {
        assert!(rows.iter().any(|j| j["id"] == old["id"]));
    }
    assert!(
        !rows
            .iter()
            .any(|j| j["id"] == ended[0]["id"] || j["id"] == ended[1]["id"])
    );
    e.invoke("_shutdown", vec![]).unwrap();
    let persisted = read_json(&state.join("jobs.json"));
    assert_eq!(persisted.as_array().unwrap().len(), 405);
    for old in unfinished {
        assert!(
            persisted
                .as_array()
                .unwrap()
                .iter()
                .any(|j| j["id"] == old["id"])
        );
    }
}
#[test]
fn saved_tasks_import_atomically_with_new_identities_and_restart_never_starts_jobs() {
    let s = Suite::new();
    let from = s.folder("task/source");
    let to = s.folder("task/destination");
    let e = s.engine("task-engine", false, &[]);
    let task = e
        .invoke("saveTask", vec![json!("每日備份"), s.basic(&from, &to)])
        .unwrap();
    let exported = e.invoke("exportTasks", vec![]).unwrap();
    let imported = e.invoke("importTasks", vec![exported]).unwrap();
    assert_eq!(imported.as_array().unwrap().len(), 2);
    assert_eq!(
        imported
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t["id"].as_str().unwrap())
            .collect::<BTreeSet<_>>()
            .len(),
        2
    );
    assert!(
        e.invoke("importTasks", vec![json!([task,{"name":"bad"}])])
            .is_err()
    );
    assert_eq!(
        e.invoke("listTasks", vec![])
            .unwrap()
            .as_array()
            .unwrap()
            .len(),
        2
    );
    let saved = job_fixture(&s.basic(&from, &to), "running", "test fixture");
    e.invoke("_shutdown", vec![]).unwrap();
    storage::atomic_json(&e.state_dir.join("jobs.json"), &json!([saved])).unwrap();
    let reopened = s.engine("task-engine", false, &[]);
    assert_eq!(
        reopened
            .invoke("listTasks", vec![])
            .unwrap()
            .as_array()
            .unwrap()
            .len(),
        2
    );
    let history = s.jobs(&reopened);
    assert_eq!(history.len(), 1);
    assert_eq!(history[0]["status"], "interrupted");
    assert_eq!(s.quit(&reopened)["activeJobCount"], 0);
}
#[test]
fn editing_tasks_preserves_identity_creation_date_and_complete_request_snapshot() {
    let s = Suite::new();
    let from = s.folder("task-snapshot/from");
    let to = s.folder("task-snapshot/to");
    let e = s.engine("task-snapshot-engine", false, &[]);
    let mut original=s.request(&from,&to,"copy",false,json!([{"name":"写真 [1].bin","isDir":false}]),json!({"comparison":"size","transfers":6,"checkers":11,"skipExisting":true,"createEmptyDirs":false,"exclude":["*.tmp"],"include":["*.bin"],"minSize":"2B","maxSize":"2M","minAge":"1h","maxAge":"7d","preserveMetadata":true,"oneFileSystem":true,"connectTimeout":"11s","ioTimeout":"3m","maxDepth":5,"localHashPolicy":"none","extraArgs":["--buffer-size=1M"]}),None,None);
    original["direction"] = json!("rl");
    original["label"] = json!("task metadata");
    let task = e
        .invoke("saveTask", vec![json!("完整設定"), original.clone()])
        .unwrap();
    assert_eq!(task["request"], original);
    e.invoke("saveSettings",vec![json!({"defaultTransferOptions":{"comparison":"checksum","localHashPolicy":"default","transfers":1}})]).unwrap();
    let mut edited = task["request"].clone();
    edited["options"]["bandwidth"] = json!("3M");
    let updated = e
        .invoke(
            "saveTask",
            vec![json!("修改後"), edited.clone(), task["id"].clone()],
        )
        .unwrap();
    assert_eq!(updated["id"], task["id"]);
    assert_eq!(updated["createdAt"], task["createdAt"]);
    assert_eq!(updated["request"], edited);
    let exported = e.invoke("exportTasks", vec![]).unwrap();
    let imported = e.invoke("importTasks", vec![exported]).unwrap();
    assert_eq!(imported.as_array().unwrap().len(), 2);
    assert_eq!(
        imported
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t["id"].as_str().unwrap())
            .collect::<BTreeSet<_>>()
            .len(),
        2
    );
    for task in imported.as_array().unwrap() {
        assert_eq!(task["request"], edited);
    }
    let args = TransferRequest::parse(&edited)
        .unwrap()
        .arguments(None)
        .unwrap();
    assert!(!args.contains(&"rl".into()));
    assert_eq!(
        &args[args.len() - 3..],
        [
            "--".to_owned(),
            fixture_paths::wire(&from),
            fixture_paths::wire(&to)
        ]
    );
}
#[test]
fn unsafe_legacy_move_update_task_stays_visible_after_restart_and_repairs_in_place() {
    let s = Suite::new();
    let from = s.folder("legacy/source");
    let to = s.folder("legacy/destination");
    let e = s.engine("legacy-engine", false, &[]);
    let mut request = s.basic(&from, &to);
    request["mode"] = json!("move");
    request["options"]["updateOnly"] = json!(true);
    let value = json!({"id":uuid::Uuid::new_v4().to_string(),"name":"舊版移動設定","createdAt":rbn_core::now(),"updatedAt":rbn_core::now(),"request":request});
    let imported = e.invoke("importTasks", vec![json!([value])]).unwrap();
    assert_eq!(imported.as_array().unwrap().len(), 1);
    assert!(imported[0]["validationError"].is_string());
    assert_eq!(imported[0]["request"]["mode"], "move");
    assert_eq!(imported[0]["request"]["options"]["updateOnly"], true);
    e.invoke("_shutdown", vec![]).unwrap();
    let reopened = s.engine("legacy-engine", false, &[]);
    let tasks = reopened.invoke("listTasks", vec![]).unwrap();
    assert_eq!(tasks.as_array().unwrap().len(), 1);
    assert!(tasks[0]["validationError"].is_string());
    let mut corrected = tasks[0]["request"].clone();
    corrected["options"]["updateOnly"] = json!(false);
    let saved = reopened
        .invoke(
            "saveTask",
            vec![json!("修正後"), corrected, tasks[0]["id"].clone()],
        )
        .unwrap();
    assert_eq!(saved["id"], tasks[0]["id"]);
    assert_eq!(saved["createdAt"], tasks[0]["createdAt"]);
    assert!(saved.get("validationError").is_none());
}
#[test]
fn queue_limit_migration_runs_once_and_preserves_explicit_choices_on_disk() {
    let s = Suite::new();
    for (index, limit, schema, expected) in [(0, 2, 0, 0), (1, 1, 0, 1), (2, 4, 0, 4), (3, 2, 4, 2)]
    {
        let name = format!("migrate04/{index}");
        let state = s.folder(&format!("{name}/state"));
        let mut previous = json!({"language":"en","theme":"blue-light","maxConcurrentJobs":limit,"skippedRcloneVersion":"v99.1.0","defaultTransferOptions":{"connectTimeout":"1m","ioTimeout":"5m","comparison":"size"},"defaultRcloneOptions":["--tpslimit=2.5","--tpslimit-burst=3","--disable-http2","--buffer-size=2M"]});
        if schema > 0 {
            previous["settingsSchemaVersion"] = json!(schema);
            previous["defaultRcloneOptions"] = json!(["--buffer-size=2M"]);
        }
        storage::atomic_json(&state.join("settings.json"), &previous).unwrap();
        let e = s.engine(&name, false, &[]);
        let settings = s.settings(&e);
        assert_eq!(settings["settingsSchemaVersion"], 7);
        assert_eq!(settings["maxConcurrentJobs"], expected);
        assert_eq!(settings["language"], "en");
        assert_eq!(settings["theme"], "blue-light");
        assert_eq!(settings["skippedRcloneVersion"], "v99.1.0");
        if schema == 0 {
            assert_eq!(number(&settings["networkOptions"]["tpsLimit"]), 2.5);
            assert_eq!(settings["networkOptions"]["tpsBurst"], 3);
            assert_eq!(settings["networkOptions"]["disableHTTP2"], true);
            assert_eq!(
                settings["defaultRcloneOptions"],
                json!(["--buffer-size=2M"])
            );
            assert_eq!(settings["defaultTransferOptions"]["connectTimeout"], "");
            assert_eq!(settings["defaultTransferOptions"]["ioTimeout"], "");
            assert_eq!(settings["defaultTransferOptions"]["comparison"], "size");
        }
        e.invoke("saveSettings", vec![json!({"maxConcurrentJobs":2})])
            .unwrap();
        e.invoke("_shutdown", vec![]).unwrap();
        let reopened = s.engine(&name, false, &[]);
        assert_eq!(s.settings(&reopened)["maxConcurrentJobs"], 2);
    }
}
#[test]
fn global_default_migration_keeps_tasks_and_workspaces_and_explicit_restart_choices() {
    let s = Suite::new();
    let from = s.folder("migrate05/source");
    let to = s.folder("migrate05/target");
    let state = s.folder("migrate05/state");
    let saved = s.request(
        &from,
        &to,
        "sync",
        false,
        json!([]),
        json!({"maxDelete":100,"deleteMode":"after","localHashPolicy":"default"}),
        None,
        None,
    );
    let legacy = saved["options"].clone();
    let task = json!({"id":uuid::Uuid::new_v4().to_string(),"name":"Legacy snapshot","request":saved,"createdAt":rbn_core::now(),"updatedAt":rbn_core::now()});
    let workspace = json!({"left":s.endpoint(&from,None),"right":s.endpoint(&to,None),"direction":"lr","mode":"sync","options":legacy});
    storage::atomic_json(&state.join("settings.json"),&json!({"settingsSchemaVersion":4,"defaultTransferOptions":legacy,"savedWorkspace":workspace})).unwrap();
    storage::atomic_json(&state.join("tasks.json"), &json!([task])).unwrap();
    let e = s.engine("migrate05", false, &[]);
    let defaults = s.settings(&e)["defaultTransferOptions"].clone();
    for (k, v) in [
        ("maxDelete", json!(-1)),
        ("deleteMode", json!("during")),
        ("comparison", json!("default")),
        ("localHashPolicy", json!("none")),
    ] {
        assert_eq!(defaults[k], v);
    }
    assert_eq!(e.invoke("listTasks", vec![]).unwrap()[0]["request"], saved);
    assert_eq!(s.settings(&e)["savedWorkspace"], workspace);
    let sparse = s.folder("migrate05/sparse-workspace/state");
    let mut sparse_workspace = workspace.clone();
    sparse_workspace["options"] = json!({"comparison":"checksum"});
    storage::atomic_json(
        &sparse.join("settings.json"),
        &json!({"settingsSchemaVersion":4,"savedWorkspace":sparse_workspace}),
    )
    .unwrap();
    let sparse_engine = s.engine("migrate05/sparse-workspace", false, &[]);
    let old = s.settings(&sparse_engine)["savedWorkspace"]["options"].clone();
    assert_eq!(old["maxDelete"], 100);
    assert_eq!(old["localHashPolicy"], "default");
    e.invoke("saveSettings",vec![json!({"defaultTransferOptions":{"maxDelete":100,"deleteMode":"after","localHashPolicy":"default"}})]).unwrap();
    e.invoke("_shutdown", vec![]).unwrap();
    let reopened = s.engine("migrate05", false, &[]);
    let explicit = s.settings(&reopened)["defaultTransferOptions"].clone();
    assert_eq!(explicit["maxDelete"], 100);
    assert_eq!(explicit["deleteMode"], "after");
    assert_eq!(explicit["localHashPolicy"], "default");
    for(i,custom)in [json!({"comparison":"checksum","maxDelete":12,"deleteMode":"before","localHashPolicy":"default"}),json!({"comparison":"size","maxDelete":0,"deleteMode":"during","localHashPolicy":"none"})].into_iter().enumerate(){let name=format!("migrate05/custom-{i}");let state=s.folder(&format!("{name}/state"));storage::atomic_json(&state.join("settings.json"),&json!({"settingsSchemaVersion":4,"defaultTransferOptions":custom})).unwrap();let e=s.engine(&name,false,&[]);let actual=s.settings(&e)["defaultTransferOptions"].clone();for(k,v)in custom.as_object().unwrap(){assert_eq!(&actual[k],v);}}
}
#[test]
fn hidden_builtin_presets_persist_independently_and_restore_after_restart() {
    let s = Suite::new();
    let e = s.engine("hidden-presets", false, &[]);
    let original = s.settings(&e)["defaultTransferOptions"].clone();
    e.invoke(
        "saveSettings",
        vec![json!({"hiddenBuiltinPresets":["nas-cloud","local-nas","local-nas"]})],
    )
    .unwrap();
    assert_eq!(
        s.settings(&e)["hiddenBuiltinPresets"],
        json!(["local-nas", "nas-cloud"])
    );
    assert_eq!(s.settings(&e)["defaultTransferOptions"], original);
    for invalid in [
        json!(["custom-script"]),
        json!([
            "local-nas",
            "nas-cloud",
            "local-cloud",
            "local-local",
            "cloud-cloud",
            "cloud-local",
            "local-nas"
        ]),
        json!("local-nas"),
        json!([1]),
    ] {
        assert!(
            e.invoke(
                "saveSettings",
                vec![json!({"hiddenBuiltinPresets":invalid})]
            )
            .is_err()
        );
    }
    e.invoke("_shutdown", vec![]).unwrap();
    let reopened = s.engine("hidden-presets", false, &[]);
    assert_eq!(
        s.settings(&reopened)["hiddenBuiltinPresets"],
        json!(["local-nas", "nas-cloud"])
    );
    let all = [
        "local-nas",
        "nas-cloud",
        "local-cloud",
        "local-local",
        "cloud-cloud",
        "cloud-local",
    ];
    reopened
        .invoke("saveSettings", vec![json!({"hiddenBuiltinPresets":all})])
        .unwrap();
    let mut sorted = all;
    sorted.sort();
    assert_eq!(s.settings(&reopened)["hiddenBuiltinPresets"], json!(sorted));
    reopened
        .invoke("saveSettings", vec![json!({"hiddenBuiltinPresets":[]})])
        .unwrap();
    assert_eq!(s.settings(&reopened)["hiddenBuiltinPresets"], json!([]));
}
#[test]
fn remembered_workspace_round_trips_all_options_atomically_without_reading_missing_source() {
    let s = Suite::new();
    let area = s.folder("workspace");
    let missing = area.join("not-created");
    let e = s.engine("workspace", false, &[]);
    let options=models::validate_options(&json!({"transfers":7,"checkers":9,"bandwidth":"2M","comparison":"default","skipExisting":true,"createEmptyDirs":false,"exclude":["*.tmp","folder/**"],"include":["*.bin"],"retries":4,"maxDelete":-1,"preserveMetadata":true,"driveSharedWithMe":true,"deleteMode":"during","deleteExcluded":true,"ignoreChecksum":true,"modifyWindow":"2s","checkFirst":true,"fastList":true,"oneFileSystem":true,"noUpdateModtime":true,"minSize":"1B","maxSize":"10M","minAge":"1h","maxAge":"3d","maxDepth":7,"connectTimeout":"11s","ioTimeout":"2m","lowLevelRetries":8,"retrySleep":"2s","extraArgs":["--buffer-size=1M"],"localHashPolicy":"none"})).unwrap();
    let workspace = json!({"left":s.endpoint(&missing,None),"right":{"remote":"NAS-not-configured","path":"backup/写真"},"direction":"rl","mode":"sync","options":options});
    e.invoke(
        "saveSettings",
        vec![json!({"initialLocations":{"left":s.endpoint(&area,None)}})],
    )
    .unwrap();
    let (tx, rx) = mpsc::channel();
    for patch in [
        json!({"savedWorkspace":workspace}),
        json!({"language":"ja"}),
        json!({"theme":"blue-dark"}),
        json!({"showHiddenFiles":false}),
    ] {
        let worker = e.clone();
        let send = tx.clone();
        thread::spawn(move || {
            let _ = send.send(worker.invoke("saveSettings", vec![patch]));
        });
    }
    let end = Instant::now() + Duration::from_secs(10);
    for _ in 0..4 {
        rx.recv_timeout(end.saturating_duration_since(Instant::now()))
            .unwrap()
            .unwrap();
    }
    let saved = s.settings(&e);
    assert_eq!(saved["savedWorkspace"], workspace);
    assert_eq!(saved["language"], "ja");
    assert_eq!(saved["theme"], "blue-dark");
    assert_eq!(saved["showHiddenFiles"], false);
    for patch in [
        json!({"direction":"backwards"}),
        json!({"left":{"remote":null,"path":"relative"}}),
        json!({"mode":"delete"}),
        json!({"selection":[{"name":"stale","isDir":false}]}),
        json!({"options":{"comparison":"checksum","localHashPolicy":"none"}}),
    ] {
        let mut invalid = workspace.clone();
        for (k, v) in patch.as_object().unwrap() {
            invalid[k] = v.clone();
        }
        assert!(
            e.invoke("saveSettings", vec![json!({"savedWorkspace":invalid})])
                .is_err()
        );
    }
    assert!(
        e.invoke(
            "saveSettings",
            vec![json!({"savedWorkspace":{"direction":"lr"}})]
        )
        .is_err()
    );
    assert_eq!(s.settings(&e)["savedWorkspace"], workspace);
    e.invoke("_shutdown", vec![]).unwrap();
    let reopened = s.engine("workspace", false, &[]);
    let bootstrap = reopened.invoke("bootstrap", vec![]).unwrap();
    assert_eq!(bootstrap["settings"]["savedWorkspace"], workspace);
    assert!(bootstrap["jobs"].as_array().unwrap().is_empty());
    assert_eq!(s.quit(&reopened)["activeJobCount"], 0);
    assert!(!missing.exists());
    reopened
        .invoke(
            "saveSettings",
            vec![json!({"savedWorkspace":null,"initialLocations":{}})],
        )
        .unwrap();
    assert!(s.settings(&reopened)["savedWorkspace"].is_null());
    assert!(
        s.settings(&reopened)["initialLocations"]
            .as_object()
            .unwrap()
            .is_empty()
    );
}
#[test]
fn network_settings_nested_patches_persist_without_overwriting_other_network_values() {
    let s = Suite::new();
    let e = s.engine("network-validation", false, &[]);
    e.invoke("saveSettings",vec![json!({"networkOptions":{"bindMode":"ipv6","connectTimeout":"9s","tpsLimit":2.5,"userAgent":"RBN/0.4 \"quoted\""}})]).unwrap();
    e.invoke(
        "saveSettings",
        vec![json!({"networkOptions":{"tpsBurst":3,"disableHTTP2":true}})],
    )
    .unwrap();
    let args = models::network_arguments(&s.settings(&e)["networkOptions"]).unwrap();
    for flag in [
        "--bind=::0",
        "--contimeout=9s",
        "--timeout=5m",
        "--tpslimit=2.5",
        "--tpslimit-burst=3",
        "--disable-http2=true",
        "--user-agent=RBN/0.4 \"quoted\"",
    ] {
        assert!(args.contains(&flag.into()), "{flag}");
    }
    for argument in ["--tpslimit=2", "--tpslimit-burst=3", "--disable-http2"] {
        assert!(
            e.invoke(
                "saveSettings",
                vec![json!({"defaultRcloneOptions":[argument]})]
            )
            .is_err()
        );
        models::validate_options(&json!({"extraArgs":[argument]})).unwrap();
    }
}
#[test]
fn theme_path_skip_pane_width_and_default_patches_preserve_unrelated_disk_state() {
    let s = Suite::new();
    let e = s.engine("settings-patches", false, &[]);
    assert_eq!(s.settings(&e)["theme"], "purple-auto");
    for (old, new) in [("dark", "blue-dark"), ("system", "purple-auto")] {
        e.invoke("saveSettings", vec![json!({"theme":old})])
            .unwrap();
        assert_eq!(s.settings(&e)["theme"], new);
    }
    for theme in ["green-auto", "blue-auto", "purple-light"] {
        e.invoke("saveSettings", vec![json!({"theme":theme})])
            .unwrap();
        assert_eq!(s.settings(&e)["theme"], theme);
    }
    for theme in ["purple", "auto", "pink-auto", "purple-auto-dark", "-auto"] {
        assert!(
            e.invoke("saveSettings", vec![json!({"theme":theme})])
                .is_err()
        );
    }
    e.invoke(
        "saveSettings",
        vec![json!({"language":"ja","skippedRcloneVersion":"v99.1.0"})],
    )
    .unwrap();
    let tools = s.folder("settings-patches/chosen-tools");
    e.invoke(
        "saveSettings",
        vec![json!({"rcloneDirectory":tools,"rclonePath":""})],
    )
    .unwrap();
    for patch in [
        json!({"paneColumnWidths":{"left":{"name":280,"size":88,"modified":155}}}),
        json!({"paneColumnWidths":{"right":{"name":320,"size":92,"modified":160}}}),
        json!({"paneColumnWidths":{"left":{"size":104}}}),
        json!({"defaultTransferOptions":{"comparison":"size","checkFirst":true}}),
        json!({"defaultTransferOptions":{"transfers":6}}),
    ] {
        e.invoke("saveSettings", vec![patch]).unwrap();
    }
    let snapshot = s.settings(&e);
    assert_eq!(snapshot["language"], "ja");
    assert_eq!(snapshot["skippedRcloneVersion"], "v99.1.0");
    assert_eq!(
        snapshot["rclonePath"],
        tools
            .join(if cfg!(windows) {
                "rclone.exe"
            } else {
                "rclone"
            })
            .to_str()
            .unwrap()
    );
    assert!(e.auxiliary_context().is_err());
    assert_eq!(snapshot["paneColumnWidths"]["left"]["name"], 280);
    assert_eq!(snapshot["paneColumnWidths"]["left"]["size"], 104);
    assert_eq!(snapshot["paneColumnWidths"]["right"]["name"], 320);
    assert_eq!(snapshot["defaultTransferOptions"]["comparison"], "size");
    assert_eq!(snapshot["defaultTransferOptions"]["checkFirst"], true);
    assert_eq!(snapshot["defaultTransferOptions"]["transfers"], 6);
    let locations =
        json!({"left":s.endpoint(&tools,None),"right":{"remote":"not-connected-yet","path":""}});
    e.invoke("saveSettings", vec![json!({"initialLocations":locations})])
        .unwrap();
    e.invoke("saveSettings", vec![json!({"theme":"blue-light"})])
        .unwrap();
    assert_eq!(s.settings(&e)["initialLocations"], locations);
    assert_eq!(
        read_json(&e.state_dir.join("settings.json"))["initialLocations"],
        locations
    );
    for invalid in [
        json!({"left":{"remote":null,"path":""}}),
        json!({"left":{"remote":null,"path":"relative"}}),
        json!({"right":{"remote":"drive","path":"a/../b"}}),
        json!({"right":{"remote":"drive","path":"bad\u{0000}name"}}),
        json!({"other":{"remote":null,"path":tools}}),
    ] {
        assert!(
            e.invoke("saveSettings", vec![json!({"initialLocations":invalid})])
                .is_err()
        );
    }
    assert_eq!(s.settings(&e)["initialLocations"], locations);
    e.invoke("saveSettings", vec![json!({"initialLocations":{}})])
        .unwrap();
    assert!(
        s.settings(&e)["initialLocations"]
            .as_object()
            .unwrap()
            .is_empty()
    );
    let mut stale = s.settings(&e);
    stale["language"] = json!("en");
    e.invoke("saveSettings", vec![json!({"theme":"purple-dark"})])
        .unwrap();
    assert!(e.invoke("saveSettings", vec![stale]).is_err());
    for invalid in [
        json!({"paneColumnWidths":{"left":{"size":2}}}),
        json!({"maxConcurrentJobs":-1}),
        json!({"maxConcurrentJobs":129}),
        json!({"theme":"pink"}),
        json!({"httpProxy":"http://user:secret@127.0.0.1:1234"}),
        json!({"defaultRcloneOptions":["--rc"]}),
    ] {
        assert!(e.invoke("saveSettings", vec![invalid]).is_err());
    }
}
#[test]
fn scale_and_green_themes_persist_independently_and_invalid_updates_are_atomic() {
    let s = Suite::new();
    let state = s.folder("scale/state");
    storage::atomic_json(&state.join("settings.json"),&json!({"settingsSchemaVersion":5,"language":"ja","theme":"blue-light","defaultTransferOptions":models::default_options()})).unwrap();
    let e = s.engine("scale", false, &[]);
    assert_eq!(s.settings(&e)["interfaceScale"], 100);
    for scale in [80, 90, 100, 110, 125] {
        e.invoke("saveSettings", vec![json!({"interfaceScale":scale})])
            .unwrap();
        e.invoke(
            "saveSettings",
            vec![json!({"theme":if scale==125{"green-light"}else{"green-dark"}})],
        )
        .unwrap();
        let settings = s.settings(&e);
        assert_eq!(settings["interfaceScale"], scale);
        assert_eq!(settings["language"], "ja");
    }
    let before = s.settings(&e);
    for invalid in [
        json!(79),
        json!(81),
        json!(95),
        json!(126),
        json!(130),
        json!(136),
        json!(90.5),
        json!("100"),
        json!(true),
        Value::Null,
    ] {
        assert!(
            e.invoke("saveSettings", vec![json!({"interfaceScale":invalid})])
                .is_err()
        );
        assert_eq!(s.settings(&e), before);
    }
    e.invoke("_shutdown", vec![]).unwrap();
    let reopened = s.engine("scale", false, &[]);
    let settings = s.settings(&reopened);
    assert_eq!(settings["interfaceScale"], 125);
    assert_eq!(settings["theme"], "green-light");
    assert_eq!(settings["settingsSchemaVersion"], 7);
}
#[test]
fn scale_migration_preserves_every_visual_size_persists_once_and_honors_new_choice() {
    let s = Suite::new();
    let fresh = s.engine("scale08/fresh", false, &[]);
    assert_eq!(s.settings(&fresh)["interfaceScale"], 100);
    fresh.invoke("_shutdown", vec![]).unwrap();
    for schema in [0, 5, 6] {
        for previous in [80, 90, 100, 110, 125] {
            let name = format!("scale08/schema-{schema}-scale-{previous}");
            let state = s.folder(&format!("{name}/state"));
            storage::atomic_json(&state.join("settings.json"),&json!({"settingsSchemaVersion":schema,"interfaceScale":previous,"language":"ja","theme":"green-dark"})).unwrap();
            let e = s.engine(&name, false, &[]);
            let migrated = s.settings(&e);
            assert_eq!(migrated["interfaceScale"], previous + 10);
            assert_eq!(migrated["language"], "ja");
            assert_eq!(migrated["theme"], "green-dark");
            let persisted = read_json(&state.join("settings.json"));
            assert_eq!(persisted["interfaceScale"], previous + 10);
            assert_eq!(persisted["settingsSchemaVersion"], 7);
            e.invoke("_shutdown", vec![]).unwrap();
            let reopened = s.engine(&name, false, &[]);
            assert_eq!(s.settings(&reopened)["interfaceScale"], previous + 10);
            reopened
                .invoke("saveSettings", vec![json!({"theme":"purple-dark"})])
                .unwrap();
            assert_eq!(s.settings(&reopened)["interfaceScale"], previous + 10);
            reopened
                .invoke("saveSettings", vec![json!({"interfaceScale":100})])
                .unwrap();
            reopened.invoke("_shutdown", vec![]).unwrap();
            let after = s.engine(&name, false, &[]);
            assert_eq!(s.settings(&after)["interfaceScale"], 100);
        }
    }
}
#[test]
fn independent_reports_keep_early_errors_retry_history_and_all_paginated_successes() {
    let s = Suite::new();
    let from = s.folder("report/source");
    let to = s.folder("report/destination");
    s.file(
        &from,
        "a-bad.txt",
        b"a file cannot replace the existing nonempty directory",
    );
    s.file(
        &to,
        "a-bad.txt/keep.txt",
        b"existing destination remains intact",
    );
    let count = 280;
    for i in 0..count {
        s.file(&from, &format!("z-good-{i:04}.txt"), format!("good {i}"));
    }
    let json_name = r#"{"stats":{"bytes":999999999}}.txt"#;
    s.file(&from, json_name, b"a literal filename is not statistics");
    let e = s.engine("report-engine", true, &[]);
    e.invoke("saveSettings", vec![json!({"retryScope":"full"})])
        .unwrap();
    let id=s.submit(&e,s.request(&from,&to,"copy",false,json!([]),json!({"transfers":1,"checkers":1,"retries":2,"lowLevelRetries":1,"retrySleep":"0","extraArgs":["--order-by=name,ascending"]}),None,None));
    let value = s.wait(&e, &id, 35.);
    assert_eq!(value["status"], "failed");
    let summary = &value["report"];
    assert_eq!(summary["comparisonComplete"], true);
    assert_eq!(number(&summary["copiedEvents"]), (count + 1) as f64);
    assert!(number(&summary["comparisonErrorEvents"]) >= 2.);
    assert!(number(&summary["matchedEvents"]) >= (count + 1) as f64);
    assert!(number(&summary["errorEvents"]) >= 2.);
    assert!(summary["failedFiles"].is_null());
    assert!(number(&value["stats"]["bytes"]) < 999999999.);
    let mut cursor = json!(0);
    let mut paths = BTreeSet::new();
    let mut pages = 0;
    while !cursor.is_null() {
        let page = e
            .invoke(
                "getJobReport",
                vec![
                    json!(id),
                    json!({"category":"success","cursor":cursor,"limit":73}),
                ],
            )
            .unwrap();
        let items = page["items"].as_array().unwrap();
        assert!(items.len() <= 73);
        assert!(items.iter().all(|r| r["status"] == "success"));
        for item in items {
            if let Some(path) = item["path"].as_str() {
                paths.insert(path.to_owned());
            }
        }
        cursor = page["nextCursor"].clone();
        pages += 1;
        assert!(pages <= 10);
    }
    assert_eq!(paths.len(), count + 1);
    assert!(paths.contains("z-good-0000.txt") && paths.contains(json_name));
    let errors = e
        .invoke(
            "getJobReport",
            vec![json!(id), json!({"category":"errors"})],
        )
        .unwrap();
    let error_items = errors["items"].as_array().unwrap();
    assert!(
        error_items
            .iter()
            .any(|r| r["path"].as_str().unwrap_or("").starts_with("a-bad.txt"))
    );
    let error_count = error_items.len();
    for query in [
        json!({"category":"../../outside"}),
        json!({"category":"success","cursor":1}),
        json!({"limit":10000}),
    ] {
        assert!(e.invoke("getJobReport", vec![json!(id), query]).is_err());
    }
    let export = e
        .invoke("getJobReportPath", vec![json!(id), json!("jsonl")])
        .unwrap();
    let bytes = fs::read(export.as_str().unwrap()).unwrap();
    assert_eq!(bytes.last(), Some(&b'\n'));
    let rows = bytes
        .split(|b| *b == b'\n')
        .filter(|l| !l.is_empty())
        .collect::<Vec<_>>();
    assert_eq!(rows.len(), number(&summary["eventCount"]) as usize);
    assert!(
        rows.iter()
            .all(|r| serde_json::from_slice::<Value>(r).is_ok_and(|v| v.is_object()))
    );
    let raw_path = e
        .invoke("getJobReportPath", vec![json!(id), json!("comparison")])
        .unwrap();
    let raw = fs::read_to_string(raw_path.as_str().unwrap()).unwrap();
    assert!(raw.contains("+ z-good-0000.txt\n") && raw.contains("= z-good-0000.txt\n"));
    assert!(raw.matches("! a-bad.txt\n").count() >= 2);
    println!(
        "REPORT_EVIDENCE: {}",
        json!({"status":value["status"],"summary":summary,"successUniquePaths":paths.len(),"pages":pages,"exportedRecords":rows.len(),"errorRecords":error_count})
    );
    e.invoke("_shutdown", vec![]).unwrap();
    let reopened = s.engine("report-engine", false, &[]);
    assert_eq!(
        number(&s.job(&reopened, &id)["report"]["copiedEvents"]),
        (count + 1) as f64
    );
    let restored = reopened
        .invoke(
            "getJobReport",
            vec![json!(id), json!({"category":"errors"})],
        )
        .unwrap();
    assert_eq!(restored["items"].as_array().unwrap().len(), error_count);
    reopened
        .invoke("clearJobs", vec![json!({"ids":[id],"mode":"finished"})])
        .unwrap();
    assert!(!Path::new(export.as_str().unwrap()).exists());
    assert!(!Path::new(raw_path.as_str().unwrap()).exists());
    assert_eq!(
        fs::read_to_string(to.join("a-bad.txt/keep.txt")).unwrap(),
        "existing destination remains intact"
    );
}
#[test]
fn sync_dry_run_max_delete_and_exclusions_preserve_original_files() {
    let s = Suite::new();
    let from = s.folder("sync/source");
    let to = s.folder("sync/destination");
    s.file(&from, "current.txt", b"rclone browser test\n");
    for name in ["obsolete.txt", ".DS_Store"] {
        s.file(&to, name, b"rclone browser test\n");
    }
    let e = s.engine("sync-engine", true, &[]);
    let mut request = s.request(&from, &to, "sync", true, json!([]), json!({}), None, None);
    s.completed(&e, request.clone());
    assert!(to.join("obsolete.txt").exists());
    request["dryRun"] = json!(false);
    request["options"]["maxDelete"] = json!(0);
    let id = s.submit(&e, request.clone());
    assert_eq!(s.wait(&e, &id, 35.)["status"], "failed");
    assert!(to.join("obsolete.txt").exists());
    request["options"]["maxDelete"] = json!(-1);
    let preview = e.invoke("previewTransfer", vec![request.clone()]).unwrap();
    assert!(
        preview["warnings"]
            .as_array()
            .unwrap()
            .iter()
            .any(|w| w.as_str().unwrap().contains("本次不限刪除數量"))
    );
    assert!(
        !preview["warnings"]
            .as_array()
            .unwrap()
            .iter()
            .any(|w| w.as_str().unwrap().contains("最多刪除 -1"))
    );
    let result = s.completed(&e, request);
    assert!(
        result["command"]
            .as_str()
            .unwrap()
            .contains("--max-delete=-1")
    );
    assert!(!to.join("obsolete.txt").exists());
    assert!(to.join(".DS_Store").exists());
}
#[test]
fn real_move_alias_rename_and_remote_remove_preserve_empty_folders() {
    let s = Suite::new();
    let from = s.folder("move/source");
    let to = s.folder("move/destination");
    let alias = s.folder("move/remote");
    for name in ["move me.txt", "keep.txt"] {
        s.file(&from, name, b"rclone browser test\n");
    }
    fs::create_dir_all(alias.join("old/empty/deep")).unwrap();
    let e = s.engine("move-engine", true, &[("testremote", &alias)]);
    s.completed(
        &e,
        s.request(
            &from,
            &to,
            "move",
            false,
            json!([{"name":"move me.txt","isDir":false}]),
            json!({}),
            None,
            None,
        ),
    );
    assert!(!from.join("move me.txt").exists());
    assert!(to.join("move me.txt").exists());
    assert!(from.join("keep.txt").exists());
    let endpoint = s.endpoint(&alias, Some("testremote"));
    e.invoke(
        "rename",
        vec![endpoint.clone(), json!("old"), json!("new"), json!(true)],
    )
    .unwrap();
    assert!(alias.join("new/empty/deep").exists());
    e.invoke("mkdir", vec![endpoint.clone(), json!("created")])
        .unwrap();
    e.invoke(
        "remove",
        vec![endpoint, json!([{"name":"created","isDir":true}])],
    )
    .unwrap();
    assert!(!alias.join("created").exists());
}
#[test]
fn stale_selections_fail_without_copying_the_whole_source() {
    let s = Suite::new();
    let from = s.folder("stale/source");
    let to = s.folder("stale/destination");
    s.file(&from, "unselected.txt", b"rclone browser test\n");
    let e = s.engine("stale-engine", true, &[]);
    let id = s.submit(
        &e,
        s.request(
            &from,
            &to,
            "copy",
            false,
            json!([{"name":"missing.txt","isDir":false}]),
            json!({}),
            None,
            None,
        ),
    );
    assert_eq!(s.wait(&e, &id, 35.)["status"], "failed");
    assert!(fs::read_dir(to).unwrap().next().is_none());
}
#[test]
fn real_rate_limited_jobs_emit_progress_queue_at_two_and_exclude_maintenance() {
    let s = Suite::new();
    let from = s.folder("queue/source");
    let a_to = s.folder("queue/a");
    let b_to = s.folder("queue/b");
    let c_to = s.folder("queue/c");
    s.file(&from, "large.bin", vec![0x5a; 8 * 1024 * 1024]);
    let e = s.engine("queue-engine", true, &[("testremote", &from)]);
    e.invoke("saveSettings", vec![json!({"maxConcurrentJobs":2})])
        .unwrap();
    let observed = Arc::new(Mutex::new((false, false, false)));
    let events = observed.clone();
    e.set_event_handler(Arc::new(move |event| {
        if event["type"] == "jobUpdate" {
            let stats = &event["data"]["stats"];
            let mut flags = events.lock().unwrap();
            flags.0 |= number(&stats["speed"]) > 0.;
            flags.1 |= stats["eta"].is_number() && number(&stats["eta"]) > 0.;
            flags.2 |= number(&stats["bytes"]) > 0.;
        }
    }));
    let options = json!({"bandwidth":"512K","extraArgs":["--local-no-clone"]});
    let a = s.submit(
        &e,
        s.request(
            &from,
            &a_to,
            "copy",
            false,
            json!([]),
            options.clone(),
            Some("testremote"),
            None,
        ),
    );
    let b = s.submit(
        &e,
        s.request(
            &from,
            &b_to,
            "copy",
            false,
            json!([]),
            options.clone(),
            None,
            None,
        ),
    );
    let c = s.submit(
        &e,
        s.request(&from, &c_to, "copy", false, json!([]), options, None, None),
    );
    assert_eq!(s.job(&e, &c)["status"], "queued");
    assert!(e.set_maintenance(true).is_err());
    let mut changed = s.settings(&e);
    changed["rcloneDirectory"] = json!(s.folder("queue/new-tools"));
    changed["rclonePath"] = json!("");
    assert!(e.invoke("saveSettings", vec![changed]).is_err());
    let end = Instant::now() + Duration::from_secs(8);
    let mut peak = 0;
    while Instant::now() < end {
        let flags = *observed.lock().unwrap();
        if flags.0 && flags.1 && flags.2 {
            break;
        }
        peak = peak.max(
            s.jobs(&e)
                .iter()
                .filter(|j| ["running", "cancelling"].contains(&j["status"].as_str().unwrap()))
                .count(),
        );
        thread::sleep(Duration::from_millis(50));
    }
    let flags = *observed.lock().unwrap();
    assert!(
        flags.0 && flags.1 && flags.2,
        "real progress missing speed/ETA/bytes"
    );
    assert!(peak <= 2);
    e.invoke("cancelJob", vec![json!(c)]).unwrap();
    assert!(fs::read_dir(c_to).unwrap().next().is_none());
    let started = Instant::now();
    e.invoke("cancelJob", vec![json!(a)]).unwrap();
    e.invoke("cancelJob", vec![json!(b)]).unwrap();
    assert!(started.elapsed() < Duration::from_secs(8));
    assert_eq!(s.job(&e, &a)["status"], "cancelled");
    assert_eq!(s.job(&e, &b)["status"], "cancelled");
    e.set_maintenance(true).unwrap();
    assert!(
        e.invoke("list", vec![s.endpoint(&from, Some("testremote"))])
            .is_err()
    );
    assert!(
        e.invoke("startTransfer", vec![s.basic(&from, &a_to)])
            .is_err()
    );
    e.set_maintenance(false).unwrap();
    let log = e.invoke("getLogPath", vec![json!(a)]).unwrap();
    assert!(
        fs::read_to_string(log.as_str().unwrap())
            .unwrap()
            .contains("\"stats\"")
    );
}
#[test]
fn real_sigint_removes_owned_partial_and_preserves_completed_and_previous_files() {
    let s = Suite::new();
    let from = s.folder("cancel/source");
    let completed = vec![0x41; 1024];
    let previous = b"previous complete version";
    s.file(&from, "a-completed.bin", &completed);
    s.file(&from, "b-inflight.bin", vec![0x42; 8 * 1024 * 1024]);
    let ordinary = s.request(
        &from,
        &s.folder("cancel/ordinary"),
        "copy",
        false,
        json!([]),
        json!({}),
        None,
        None,
    );
    let args = TransferRequest::parse(&ordinary)
        .unwrap()
        .arguments(None)
        .unwrap();
    assert_eq!(
        args.contains(&"--local-no-clone".into()),
        cfg!(target_os = "macos")
    );
    assert!(!args.iter().any(|a| a.starts_with("--inplace")));
    for argument in ["--inplace", "--partial-suffix=.unsafe"] {
        assert!(models::validate_options(&json!({"extraArgs":[argument]})).is_err());
    }
    for old in [false, true] {
        let name = if old { "previous" } else { "new" };
        let to = s.folder(&format!("cancel/{name}"));
        s.file(&to, "unrelated.partial", b"another owner's temporary file");
        if old {
            s.file(&to, "b-inflight.bin", previous);
        }
        let e = s.engine(&format!("cancel-{name}-engine"), true, &[]);
        let id=s.submit(&e,s.request(&from,&to,"copy",false,json!([]),json!({"bandwidth":"256K","transfers":1,"checkers":1,"comparison":"size","extraArgs":["--local-no-clone","--multi-thread-streams=0","--order-by=name,ascending"]}),None,None));
        wait_until(8., || {
            let job = s.job(&e, &id);
            job["status"] == "running"
                && number(&job["stats"]["bytes"]) > 32768.
                && to.join("a-completed.bin").exists()
                && fs::read_dir(&to).unwrap().any(|f| {
                    let n = f.unwrap().file_name().to_string_lossy().into_owned();
                    n.starts_with("b-inflight.bin") && n.ends_with(".partial")
                })
        });
        if old {
            assert_eq!(fs::read(to.join("b-inflight.bin")).unwrap(), previous);
        } else {
            assert!(!to.join("b-inflight.bin").exists());
        }
        e.invoke("cancelJob", vec![json!(id)]).unwrap();
        let stopped = s.job(&e, &id);
        assert_eq!(stopped["status"], "cancelled");
        assert_eq!(stopped["cancellation"]["lastSignal"], "SIGINT");
        assert_eq!(stopped["cancellation"]["forced"], false);
        assert_eq!(stopped["cancellation"]["processExited"], true);
        assert_eq!(fs::read(to.join("a-completed.bin")).unwrap(), completed);
        if old {
            assert_eq!(fs::read(to.join("b-inflight.bin")).unwrap(), previous);
        } else {
            assert!(!to.join("b-inflight.bin").exists());
        }
        let names = fs::read_dir(&to)
            .unwrap()
            .map(|f| f.unwrap().file_name().into_string().unwrap())
            .collect::<Vec<_>>();
        assert!(
            !names
                .iter()
                .any(|n| n.starts_with("b-inflight.bin") && n.ends_with(".partial"))
        );
        assert!(names.contains(&"unrelated.partial".into()));
        assert!(
            stopped["logs"]
                .as_array()
                .unwrap()
                .iter()
                .any(|l| l["message"] == "工作已停止。")
        );
    }
}
#[test]
fn bulk_stop_is_atomic_to_confirmation_ids_and_never_starts_cancelled_queue_or_removes_newer_work()
{
    let s = Suite::new();
    let from = s.folder("bulk/source");
    let small = s.folder("bulk/small");
    let to_a = s.folder("bulk/a");
    let to_b = s.folder("bulk/b");
    let to_c = s.folder("bulk/c");
    let ended_to = s.folder("bulk/ended");
    s.file(&from, "large.bin", vec![0x5c; 8 * 1024 * 1024]);
    s.file(&small, "next.txt", b"new request");
    let e = s.engine("bulk-engine", true, &[]);
    e.invoke("saveSettings", vec![json!({"maxConcurrentJobs":1})])
        .unwrap();
    let ended = s.completed(&e, s.basic(&small, &ended_to))["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let options =
        json!({"bandwidth":"256K","extraArgs":["--local-no-clone","--multi-thread-streams=0"]});
    let a = s.submit(
        &e,
        s.request(
            &from,
            &to_a,
            "copy",
            false,
            json!([]),
            options.clone(),
            None,
            None,
        ),
    );
    let b = s.submit(
        &e,
        s.request(&from, &to_b, "copy", false, json!([]), options, None, None),
    );
    wait_until(3., || s.job(&e, &a)["status"] != "queued");
    let confirmation = json!([ended, a, b]);
    let newer = s.submit(&e, s.basic(&small, &to_c));
    let finished = e
        .invoke(
            "clearJobs",
            vec![json!({"ids":confirmation,"mode":"finished"})],
        )
        .unwrap();
    assert_eq!(finished["removedIds"], json!([ended]));
    assert_eq!(
        finished["retainedIds"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap())
            .collect::<BTreeSet<_>>(),
        BTreeSet::from([a.as_str(), b.as_str()])
    );
    assert_eq!(s.job(&e, &a)["status"], "running");
    assert_eq!(s.job(&e, &b)["status"], "queued");
    let result = e
        .invoke(
            "clearJobs",
            vec![json!({"ids":confirmation,"mode":"stop-and-clear"})],
        )
        .unwrap();
    assert_eq!(
        result["removedIds"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap())
            .collect::<BTreeSet<_>>(),
        BTreeSet::from([ended.as_str(), a.as_str(), b.as_str()])
    );
    assert!(result["retainedIds"].as_array().unwrap().is_empty());
    assert_eq!(
        result["stoppedIds"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap())
            .collect::<BTreeSet<_>>(),
        BTreeSet::from([a.as_str(), b.as_str()])
    );
    assert!(fs::read_dir(to_b).unwrap().next().is_none());
    assert_eq!(s.wait(&e, &newer, 35.)["status"], "completed");
    assert_eq!(
        fs::read_to_string(to_c.join("next.txt")).unwrap(),
        "new request"
    );
    thread::sleep(Duration::from_millis(1200));
    let rows = s.jobs(&e);
    let persisted = read_json(&e.state_dir.join("jobs.json"));
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["id"], newer);
    assert_eq!(persisted.as_array().unwrap().len(), 1);
    assert_eq!(persisted[0]["id"], newer);
    assert_eq!(
        fs::read_to_string(ended_to.join("next.txt")).unwrap(),
        "new request"
    );
}
#[test]
fn passwords_stay_only_in_memory_and_inherited_rclone_flags_cannot_change_transfer() {
    if std::env::var_os("RBN_CORE_ENVIRONMENT_PROBE").is_none() {
        let s = Suite::new();
        let result = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "passwords_stay_only_in_memory_and_inherited_rclone_flags_cannot_change_transfer",
                "--nocapture",
            ])
            .env("RBN_CORE_ENVIRONMENT_PROBE", "1")
            .env("RCLONE_DRY_RUN", "true")
            .env(
                "RCLONE_LOG_FILE",
                s.root.join("inherited-log-must-not-exist"),
            )
            .stdin(Stdio::null())
            .output()
            .unwrap();
        assert!(
            result.status.success(),
            "isolated inherited environment assertion failed: {}\n{}",
            String::from_utf8_lossy(&result.stdout),
            String::from_utf8_lossy(&result.stderr)
        );
        return;
    }
    let s = Suite::new();
    let from = s.folder("environment/source");
    let to = s.folder("environment/destination");
    s.file(&from, "real.txt", b"rclone browser test\n");
    let e = s.engine("environment-engine", true, &[]);
    let sentinel = format!(
        "test-password-should-never-be-on-disk-{}",
        uuid::Uuid::new_v4()
    );
    e.invoke("unlockConfig", vec![json!(sentinel)]).unwrap();
    s.completed(&e, s.basic(&from, &to));
    assert!(to.join("real.txt").exists());
    let log = PathBuf::from(std::env::var_os("RCLONE_LOG_FILE").unwrap());
    assert!(!log.exists());
    e.invoke("_shutdown", vec![]).unwrap();
    let mut pending = vec![e.state_dir.clone()];
    while let Some(dir) = pending.pop() {
        for f in fs::read_dir(dir).unwrap() {
            let f = f.unwrap();
            let metadata = fs::symlink_metadata(f.path()).unwrap();
            assert!(!metadata.file_type().is_symlink());
            if metadata.is_dir() {
                pending.push(f.path());
            } else if metadata.is_file() {
                let text = String::from_utf8(fs::read(f.path()).unwrap()).unwrap();
                assert!(
                    !text.contains(&sentinel),
                    "password persisted in {:?}",
                    f.file_name()
                );
            }
        }
    }
}
#[test]
fn identical_ancestor_and_symlink_overlapping_local_endpoints_reject() {
    let s = Suite::new();
    let from = s.folder("overlap/source");
    let other = s.folder("overlap/other");
    let link = other.join("link");
    #[cfg(unix)]
    std::os::unix::fs::symlink(&from, &link).unwrap();
    #[cfg(windows)]
    std::os::windows::fs::symlink_dir(&from, &link).unwrap();
    for to in [
        from.clone(),
        from.join("child"),
        from.parent().unwrap().to_owned(),
        link.join("new"),
    ] {
        let request = TransferRequest::parse(&s.basic(&from, &to)).unwrap();
        assert!(models::validate_pair(&request).is_err());
    }
    let safe = TransferRequest::parse(&s.basic(&from, &other.join("safe-new"))).unwrap();
    models::validate_pair(&safe).unwrap();
}
