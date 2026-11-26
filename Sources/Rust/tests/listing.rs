//! Case-for-case port of 0.11.0 ListingTests.swift. These assertions observe
//! actual owned child exit, not merely the engine's cancellation flags.
use rbn_core::{
    Result,
    engine::Engine,
    models::{self, Endpoint},
    process::{self, Context},
    storage,
};
use serde_json::{Value, json};
use std::{
    cell::Cell,
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
    process::{Child, Stdio},
    sync::{Arc, Condvar, Mutex},
    thread,
    time::{Duration, Instant},
};
use uuid::Uuid;
fn wait_until(
    label: &str,
    seconds: f64,
    mut condition: impl FnMut() -> Result<bool>,
) -> Result<()> {
    let deadline = Instant::now() + Duration::from_secs_f64(seconds);
    while !condition()? {
        if Instant::now() >= deadline {
            return Err(format!("Timed out: {label}"));
        }
        thread::sleep(Duration::from_millis(10));
    }
    Ok(())
}
#[cfg(unix)]
fn process_alive(pid: u32) -> bool {
    // SAFETY: signal zero performs only an existence/permission check.
    let result = unsafe { libc::kill(pid as i32, 0) };
    result == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}
#[cfg(windows)]
fn process_alive(pid: u32) -> bool {
    use windows_sys::Win32::{
        Foundation::CloseHandle,
        System::Threading::{GetExitCodeProcess, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION},
    };
    // SAFETY: the handle is query-only and always closed; no process is changed.
    unsafe {
        let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if handle.is_null() {
            return false;
        }
        let mut code = 0;
        let ok = GetExitCodeProcess(handle, &mut code);
        CloseHandle(handle);
        ok != 0 && code == 259
    }
}
fn process_evidence(pid: u32) -> Value {
    #[cfg(unix)]
    {
        // SAFETY: signal zero only queries the recorded test child; it cannot stop it.
        let result = unsafe { libc::kill(pid as i32, 0) };
        let code = if result == 0 {
            0
        } else {
            std::io::Error::last_os_error().raw_os_error().unwrap_or(0)
        };
        let alive = if result == 0 || code == libc::EPERM {
            json!(true)
        } else if code == libc::ESRCH {
            json!(false)
        } else {
            Value::Null
        };
        json!({"pid":pid,"alive":alive,"signalZeroResult":result,"queryError":code})
    }
    #[cfg(windows)]
    {
        use windows_sys::Win32::{
            Foundation::{CloseHandle, GetLastError},
            System::Threading::{
                GetExitCodeProcess, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION,
            },
        };
        // SAFETY: this only queries the owned test PID and closes its handle.
        unsafe {
            let h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
            if h.is_null() {
                return json!({"pid":pid,"alive":null,"query":"OpenProcess","queryError":GetLastError()});
            }
            let mut code = 0;
            let ok = GetExitCodeProcess(h, &mut code);
            let error = if ok == 0 { Some(GetLastError()) } else { None };
            CloseHandle(h);
            if let Some(error) = error {
                json!({"pid":pid,"alive":null,"query":"GetExitCodeProcess","queryError":error})
            } else {
                json!({"pid":pid,"alive":code==259,"exitCode":code,"queryError":null})
            }
        }
    }
}
struct Worker {
    result: Mutex<Option<Result<Value>>>,
    changed: Condvar,
    thread: Mutex<Option<thread::JoinHandle<()>>>,
}
impl Worker {
    fn spawn(action: impl FnOnce() -> Result<Value> + Send + 'static) -> Arc<Self> {
        let worker = Arc::new(Self {
            result: Mutex::new(None),
            changed: Condvar::new(),
            thread: Mutex::new(None),
        });
        let owner = worker.clone();
        let handle = thread::spawn(move || {
            let value = action();
            *owner.result.lock().unwrap() = Some(value);
            owner.changed.notify_all();
        });
        *worker.thread.lock().unwrap() = Some(handle);
        worker
    }
    fn wait(&self) -> Result<Value> {
        self.wait_for(Duration::from_secs(10))
    }
    fn wait_for(&self, timeout: Duration) -> Result<Value> {
        let deadline = Instant::now() + timeout;
        let mut result = self.result.lock().unwrap();
        while result.is_none() {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return Err("Listing worker did not unwind".into());
            }
            result = self.changed.wait_timeout(result, left).unwrap().0;
        }
        let value = result.as_ref().unwrap().clone();
        drop(result);
        if let Some(worker) = self.thread.lock().unwrap().take() {
            worker
                .join()
                .map_err(|_| "Listing worker panicked".to_owned())?;
        }
        value
    }
    fn has_finished(&self) -> bool {
        self.result.lock().unwrap().is_some()
    }
}
struct Suite {
    root: PathBuf,
    rclone: Option<PathBuf>,
}
struct Fixture {
    engine: Arc<Engine>,
    area: PathBuf,
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = self.engine.invoke("_shutdown", vec![]);
    }
}
impl Suite {
    fn new() -> Self {
        let base = std::env::var_os("RBN_TEST_ROOT")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../.tmp/listing-tests")
            });
        let root = base.join(format!("listings-{}", Uuid::new_v4()));
        storage::private_directory(&root).unwrap();
        Self {
            root,
            rclone: std::env::var_os("RBN_TEST_RCLONE").map(PathBuf::from),
        }
    }
    fn area(&self, name: &str) -> PathBuf {
        let area = self.root.join(name);
        storage::private_directory(&area.join("events")).unwrap();
        area
    }
    fn make(
        &self,
        name: &str,
        real: bool,
        ready: bool,
        timeout: Duration,
        config: &str,
    ) -> Fixture {
        let area = self.area(name);
        let config_path = area.join("rclone.conf");
        fs::write(&config_path, config).unwrap();
        let binary = if real {
            self.rclone
                .as_ref()
                .expect("RBN_TEST_RCLONE must name the pinned test-only rclone")
                .clone()
        } else {
            PathBuf::from(env!("CARGO_BIN_EXE_rbn-service-fixture"))
        };
        let state = area.join("state");
        storage::private_directory(&state).unwrap();
        let mut settings = models::default_settings(&area);
        settings["rclonePath"] = json!(binary);
        settings["configPath"] = json!(config_path);
        settings["autoCheckUpdates"] = json!(false);
        storage::atomic_json(&state.join("settings.json"), &settings).unwrap();
        let engine = Engine::new_with_listing_timeout(state, area.clone(), timeout).unwrap();
        if ready {
            let environment = engine.invoke("environment", vec![]).unwrap();
            assert_eq!(
                environment["available"], true,
                "Fixture engine did not initialize: {environment}"
            );
        }
        Fixture { engine, area }
    }
    fn standard(&self, name: &str) -> Fixture {
        self.make(
            name,
            false,
            true,
            Duration::from_secs(120),
            "[fixture]\ntype = alias\nremote = .\n",
        )
    }
}
impl Drop for Suite {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}
fn endpoint(path: &str, remote: &str) -> Value {
    json!({"remote":remote,"path":path})
}
fn list(engine: &Arc<Engine>, path: &str, id: &str, remote: &str) -> Arc<Worker> {
    let engine = engine.clone();
    let path = path.to_owned();
    let id = id.to_owned();
    let remote = remote.to_owned();
    Worker::spawn(move || {
        engine.invoke(
            "list",
            vec![endpoint(&path, &remote), json!({"requestId":id})],
        )
    })
}
fn pid(engine: &Arc<Engine>, id: &str) -> u32 {
    let mut value = None;
    wait_until(&format!("listing child {id}"), 8., || {
        value = engine.listing_process_identifier(id);
        Ok(value.is_some())
    })
    .unwrap();
    value.unwrap()
}
fn cancel(engine: &Arc<Engine>, id: &str) -> Result<Value> {
    engine.invoke("cancelList", vec![json!(id)])
}
fn status(worker: &Worker, expected: &str) -> Value {
    let value = worker.wait().unwrap();
    assert_eq!(value["status"], expected, "Wrong listing status: {value}");
    if expected == "cancelled" {
        assert!(
            value["entries"].as_array().unwrap().is_empty(),
            "Cancelled listing returned rows"
        );
    }
    value
}
fn release(area: &Path, name: &str) {
    fs::write(area.join(format!("release-{name}")), b"").unwrap();
}
fn events(area: &Path) -> Result<Vec<Value>> {
    let directory = area.join("events");
    let expression =
        regex::Regex::new(r"^(version|lsjson|listremotes)-[1-9][0-9]*\.json$").unwrap();
    let mut names = fs::read_dir(&directory)
        .map_err(|e| {
            format!(
                "Fixture stage=event-enumeration, path={}, underlying={e}",
                directory.display()
            )
        })?
        .map(|entry| entry.map(|e| e.file_name()))
        .collect::<std::io::Result<Vec<_>>>()
        .map_err(|e| e.to_string())?;
    names.retain(|n| expression.is_match(&n.to_string_lossy()));
    names.sort();
    names
        .into_iter()
        .map(|name| {
            let path = directory.join(name);
            let bytes = fs::read(&path).map_err(|e| {
                format!(
                    "Fixture stage=event-read, path={}, underlying={e}",
                    path.display()
                )
            })?;
            let value: Value = serde_json::from_slice(&bytes).map_err(|e| {
                format!(
                    "Fixture stage=event-decode, path={}, underlying={e}",
                    path.display()
                )
            })?;
            if !value.is_object() {
                return Err("Fixture event is not a JSON object".into());
            }
            Ok(value)
        })
        .collect()
}

#[test]
fn browse_preserves_legacy_arrays_and_one_lsjson_per_ready_remote_listing() {
    let suite = Suite::new();
    let f = suite.standard("one-command");
    let old = f
        .engine
        .invoke("list", vec![endpoint("fast", "fixture")])
        .unwrap();
    let value = status(
        &list(&f.engine, "fast", &Uuid::new_v4().to_string(), "fixture"),
        "completed",
    );
    assert_eq!(old.as_array().unwrap().len(), 1);
    assert_eq!(
        old[0]["modified"], "2026-01-02T03:04:05Z",
        "Legacy metadata changed"
    );
    assert_eq!(
        value["entries"].as_array().unwrap().len(),
        1,
        "Scoped result lost entries"
    );
    let calls = events(&f.area).unwrap();
    assert_eq!(
        calls.iter().filter(|e| e["command"] == "lsjson").count(),
        2,
        "Listing spawned extra lsjson processes"
    );
    assert!(
        !calls.iter().any(|e| e["command"] == "listremotes"),
        "Browsing still spawned listremotes"
    );
}
#[test]
fn pre_dispatch_cancellation_prevents_spawn_and_rejects_reused_active_request_ids() {
    let suite = Suite::new();
    let f = suite.standard("pre-cancel");
    let id = Uuid::new_v4().to_string();
    let count = events(&f.area).unwrap().len();
    assert_eq!(
        cancel(&f.engine, &id).unwrap()["cancelled"],
        true,
        "Pre-cancel was not acknowledged"
    );
    f.engine.prepare_listing(&json!({"requestId":id})).unwrap();
    status(&list(&f.engine, "wait-never", &id, "fixture"), "cancelled");
    assert_eq!(
        events(&f.area).unwrap().len(),
        count,
        "Pre-cancel still started a child"
    );
    assert!(
        f.engine
            .invoke(
                "list",
                vec![endpoint("fast", "fixture"), json!({"requestId":id})]
            )
            .is_err(),
        "Reused ID was accepted"
    );
}
#[test]
fn context_reset_cancels_a_reserved_worker_before_it_starts() {
    let suite = Suite::new();
    let f = suite.standard("queued-reset");
    let id = Uuid::new_v4().to_string();
    let count = events(&f.area).unwrap().len();
    f.engine.prepare_listing(&json!({"requestId":id})).unwrap();
    f.engine.cancel_listings();
    status(&list(&f.engine, "wait-never", &id, "fixture"), "cancelled");
    assert_eq!(
        events(&f.area).unwrap().len(),
        count,
        "Reset queued child spawned later"
    );
    status(
        &list(&f.engine, "fast", &Uuid::new_v4().to_string(), "fixture"),
        "completed",
    );
}

struct RequestEvidence {
    name: &'static str,
    id: String,
    launcher: u32,
    worker: Arc<Worker>,
}
fn cancel_with_evidence(
    engine: &Arc<Engine>,
    area: &Path,
    id: &str,
    stage: &str,
    children: &[u32],
    requests: &[RequestEvidence],
) -> Result<Value> {
    let started = Instant::now();
    match cancel(engine, id) {
        Ok(value) => Ok(value),
        Err(error) => {
            let mut evidence = json!({"stage":stage,"requestId":id,"elapsedSeconds":started.elapsed().as_secs_f64(),"originalError":error,"fixtureArea":area,"actualChildren":children.iter().map(|p|process_evidence(*p)).collect::<Vec<_>>(),"requests":requests.iter().map(|r|json!({"name":r.name,"requestId":r.id,"workerFinished":r.worker.has_finished(),"launcher":process_evidence(r.launcher),"registryRunningPID":engine.listing_process_identifier(&r.id)})).collect::<Vec<_>>()});
            match events(area) {
                Ok(e) => evidence["fixtureEvents"] = json!(e),
                Err(e) => evidence["fixtureEventsReadError"] = json!(e),
            }
            eprintln!("LISTING_CANCEL_FAILURE {evidence}");
            Err(error)
        }
    }
}
#[test]
fn cancel_reaps_only_its_child_while_other_pane_and_newer_request_continue() {
    let suite = Suite::new();
    let f = suite.standard("pane-scope");
    let a = Uuid::new_v4().to_string();
    let b = Uuid::new_v4().to_string();
    let left = list(&f.engine, "wait-shared", &a, "fixture");
    let right = list(&f.engine, "wait-shared", &b, "fixture");
    let lp = pid(&f.engine, &a);
    let rp = pid(&f.engine, &b);
    let mut children = vec![];
    wait_until("both actual fixture children", 8., || {
        children = events(&f.area)?
            .iter()
            .filter(|v| v["command"] == "lsjson")
            .filter_map(|v| v["pid"].as_u64().map(|p| p as u32))
            .collect();
        Ok(children.len() == 2)
    })
    .unwrap();
    let mut requests = vec![
        RequestEvidence {
            name: "left",
            id: a.clone(),
            launcher: lp,
            worker: left.clone(),
        },
        RequestEvidence {
            name: "right",
            id: b.clone(),
            launcher: rp,
            worker: right.clone(),
        },
    ];
    let started = Instant::now();
    cancel_with_evidence(
        &f.engine,
        &f.area,
        &a,
        "cancel-left-with-right-active",
        &children,
        &requests,
    )
    .unwrap();
    assert!(
        !process_alive(lp),
        "Cancel acknowledged while its child was still alive"
    );
    assert!(process_alive(rp), "Cancel killed the other pane");
    assert_eq!(
        children.iter().filter(|p| process_alive(**p)).count(),
        1,
        "Cancellation did not stop exactly one actual listing child"
    );
    status(&left, "cancelled");
    let newer_id = Uuid::new_v4().to_string();
    let newer = list(&f.engine, "wait-shared", &newer_id, "fixture");
    let newer_pid = pid(&f.engine, &newer_id);
    requests.push(RequestEvidence {
        name: "newer",
        id: newer_id,
        launcher: newer_pid,
        worker: newer.clone(),
    });
    assert_eq!(
        cancel_with_evidence(
            &f.engine,
            &f.area,
            &a,
            "repeat-completed-cancel-with-newer-active",
            &children,
            &requests
        )
        .unwrap()["cancelled"],
        false,
        "Completed cancellation changed state"
    );
    assert!(
        process_alive(newer_pid) && process_alive(rp),
        "Late cancellation affected a newer request"
    );
    release(&f.area, "wait-shared");
    status(&right, "completed");
    status(&newer, "completed");
    eprintln!(
        "LISTING_CANCEL_EVIDENCE {}",
        json!({"pid":lp,"aliveAfterAck":false,"otherPID":rp,"actualChildPIDs":children,"actualChildrenAliveAfterAck":1,"elapsedSeconds":started.elapsed().as_secs_f64()})
    );
}
#[test]
#[cfg(not(windows))]
fn successful_output_after_cancellation_never_becomes_completed_listing() {
    let suite = Suite::new();
    let f = suite.standard("late-output");
    let id = Uuid::new_v4().to_string();
    let worker = list(&f.engine, "late-success", &id, "fixture");
    let child = pid(&f.engine, &id);
    wait_until("installed fixture signal handlers", 8., || {
        Ok(events(&f.area)?.iter().any(|v| v["command"] == "lsjson"))
    })
    .unwrap();
    let engine = f.engine.clone();
    let cancellation = Worker::spawn(move || cancel(&engine, &id));
    thread::sleep(Duration::from_millis(50));
    release(&f.area, "late-success");
    cancellation.wait().unwrap();
    status(&worker, "cancelled");
    assert!(
        !process_alive(child),
        "Late successful child was not reaped"
    );
}
#[test]
#[cfg(not(windows))]
fn unresponsive_read_only_child_is_force_stopped_without_transfer_grace() {
    let suite = Suite::new();
    let f = suite.standard("forced-stop");
    let id = Uuid::new_v4().to_string();
    let worker = list(&f.engine, "stubborn-read", &id, "fixture");
    let child = pid(&f.engine, &id);
    wait_until("installed stubborn signal handlers", 8., || {
        Ok(events(&f.area)?.iter().any(|v| v["command"] == "lsjson"))
    })
    .unwrap();
    let started = Instant::now();
    cancel(&f.engine, &id).unwrap();
    assert!(
        started.elapsed() < Duration::from_secs(4) && !process_alive(child),
        "Read-only escalation did not reap the child promptly"
    );
    status(&worker, "cancelled");
}
#[test]
fn cancellation_covers_environment_discovery_and_allows_clean_retry() {
    let suite = Suite::new();
    let f = suite.make(
        "initial-discovery",
        false,
        false,
        Duration::from_secs(120),
        "[fixture]\ntype = alias\nremote = .\n",
    );
    fs::write(f.area.join("block-version"), b"").unwrap();
    let id = Uuid::new_v4().to_string();
    let worker = list(&f.engine, "fast", &id, "fixture");
    let child = pid(&f.engine, &id);
    wait_until("version discovery started", 8., || {
        Ok(events(&f.area)?.iter().any(|v| v["command"] == "version"))
    })
    .unwrap();
    cancel(&f.engine, &id).unwrap();
    status(&worker, "cancelled");
    assert!(
        !process_alive(child),
        "Discovery child survived cancellation"
    );
    fs::remove_file(f.area.join("block-version")).unwrap();
    status(
        &list(&f.engine, "fast", &Uuid::new_v4().to_string(), "fixture"),
        "completed",
    );
}
#[test]
fn native_deadline_stops_process_and_reports_error_instead_of_empty_success() {
    let suite = Suite::new();
    let f = suite.make(
        "timeout",
        false,
        true,
        Duration::from_secs_f64(1.5),
        "[fixture]\ntype = alias\nremote = .\n",
    );
    let id = Uuid::new_v4().to_string();
    let worker = list(&f.engine, "wait-timeout", &id, "fixture");
    let child = pid(&f.engine, &id);
    let error = worker.wait().expect_err("Timeout returned success");
    assert!(error.contains("逾時"), "Timeout was not reported: {error}");
    assert!(!process_alive(child), "Timed-out child remained alive");
    status(
        &list(&f.engine, "fast", &Uuid::new_v4().to_string(), "fixture"),
        "completed",
    );
}
#[test]
fn connection_change_cancels_old_reading_and_queued_before_publishing_settings() {
    let suite = Suite::new();
    let f = suite.standard("old-config");
    let id = Uuid::new_v4().to_string();
    let worker = list(&f.engine, "wait-old", &id, "fixture");
    let child = pid(&f.engine, &id);
    let queued = Uuid::new_v4().to_string();
    f.engine
        .prepare_listing(&json!({"requestId":queued}))
        .unwrap();
    let next = suite.area("new-config");
    let config = next.join("rclone.conf");
    fs::write(&config, "[fixture]\ntype = alias\nremote = .\n").unwrap();
    let saved = f
        .engine
        .invoke("saveSettings", vec![json!({"configPath":config})])
        .unwrap();
    assert!(
        saved["available"] == true && !process_alive(child),
        "Settings changed before old child was reaped"
    );
    status(&worker, "cancelled");
    status(
        &list(&f.engine, "wait-obsolete", &queued, "fixture"),
        "cancelled",
    );
    status(
        &list(&f.engine, "fast", &Uuid::new_v4().to_string(), "fixture"),
        "completed",
    );
    assert!(
        events(&next)
            .unwrap()
            .iter()
            .any(|v| v["command"] == "lsjson"),
        "New listing used previous configuration"
    );
}
struct ProbeCleanup {
    area: PathBuf,
    worker: Arc<Worker>,
}
impl Drop for ProbeCleanup {
    fn drop(&mut self) {
        let _ = fs::write(self.area.join("release-version"), b"");
        let _ = self.worker.wait();
    }
}
#[test]
fn cancellation_during_replacement_probe_does_not_wait_or_stop_unrelated_probe() {
    let suite = Suite::new();
    let f = suite.standard("settings-gate");
    let next = suite.area("blocked-new-config");
    let config = next.join("rclone.conf");
    fs::write(&config, "[fixture]\ntype = alias\nremote = .\n").unwrap();
    fs::write(next.join("block-version"), b"").unwrap();
    let engine = f.engine.clone();
    let saving =
        Worker::spawn(move || engine.invoke("saveSettings", vec![json!({"configPath":config})]));
    let _cleanup = ProbeCleanup {
        area: next.clone(),
        worker: saving.clone(),
    };
    wait_until("replacement probe owns settings gate", 8., || {
        Ok(events(&next)?.iter().any(|v| v["command"] == "version"))
    })
    .unwrap();
    let probe = events(&next)
        .unwrap()
        .iter()
        .find(|v| v["command"] == "version")
        .unwrap()["pid"]
        .as_u64()
        .unwrap() as u32;
    let id = Uuid::new_v4().to_string();
    let worker = list(&f.engine, "wait-obsolete", &id, "fixture");
    let started = Instant::now();
    cancel(&f.engine, &id).unwrap();
    status(&worker, "cancelled");
    assert!(
        started.elapsed() < Duration::from_secs(1) && process_alive(probe),
        "Cancellation waited for or stopped different environment probe"
    );
    assert!(
        !events(&next)
            .unwrap()
            .iter()
            .any(|v| v["command"] == "lsjson"),
        "Obsolete listing spawned under replacement context"
    );
    release(&next, "version");
    assert_eq!(
        saving.wait().unwrap()["available"],
        true,
        "Replacement settings did not finish"
    );
    status(
        &list(&f.engine, "fast", &Uuid::new_v4().to_string(), "fixture"),
        "completed",
    );
}
#[test]
fn shutdown_reaps_both_listing_children_and_prevents_reserved_late_workers() {
    let suite = Suite::new();
    let f = suite.standard("shutdown");
    let a = Uuid::new_v4().to_string();
    let b = Uuid::new_v4().to_string();
    let queued = Uuid::new_v4().to_string();
    let left = list(&f.engine, "wait-left", &a, "fixture");
    let right = list(&f.engine, "wait-right", &b, "fixture");
    let first = pid(&f.engine, &a);
    let second = pid(&f.engine, &b);
    f.engine
        .prepare_listing(&json!({"requestId":queued}))
        .unwrap();
    f.engine.invoke("_shutdown", vec![]).unwrap();
    assert!(
        !process_alive(first) && !process_alive(second),
        "Shutdown left directory children running"
    );
    status(&left, "cancelled");
    status(&right, "cancelled");
    status(
        &list(&f.engine, "wait-late", &queued, "fixture"),
        "cancelled",
    );
}
#[test]
fn local_adapter_preserves_errors_and_pre_cancel_performs_no_filesystem_read() {
    let suite = Suite::new();
    let f = suite.standard("local-adapter");
    let endpoint = Endpoint {
        remote: None,
        path: suite.root.to_string_lossy().into_owned(),
    };
    let id = Uuid::new_v4().to_string();
    cancel(&f.engine, &id).unwrap();
    let calls = Cell::new(0usize);
    let result = f
        .engine
        .list_directory_with_local_adapter(&endpoint, &json!({"requestId":id}), &|_| {
            calls.set(calls.get() + 1);
            Ok(vec![])
        })
        .unwrap();
    assert!(
        calls.get() == 0 && result["status"] == "cancelled",
        "Pre-cancel invoked filesystem adapter"
    );
    let result = f.engine.list_directory_with_local_adapter(
        &endpoint,
        &json!({"requestId":Uuid::new_v4().to_string()}),
        &|_| Err("original permission failure".into()),
    );
    assert_eq!(
        result.unwrap_err(),
        "original permission failure",
        "Filesystem permissions/error semantics changed"
    );
}
#[test]
#[ignore = "requires pinned RBN_TEST_RCLONE"]
fn real_rclone_preserves_unicode_sizes_times_order_and_missing_remote_error() {
    let suite = Suite::new();
    let files = suite.area("real-files");
    fs::write(files.join("測試-日本語.txt"), b"1234567").unwrap();
    storage::private_directory(&files.join("folder")).unwrap();
    let f = suite.make(
        "real-alias",
        true,
        true,
        Duration::from_secs(120),
        &format!("[fixture]\ntype = alias\nremote = {}\n", files.display()),
    );
    let legacy = f
        .engine
        .invoke("list", vec![endpoint("", "fixture")])
        .unwrap();
    let scoped = status(
        &list(&f.engine, "", &Uuid::new_v4().to_string(), "fixture"),
        "completed",
    );
    let entries = scoped["entries"].as_array().unwrap();
    let file = entries
        .iter()
        .find(|v| v["name"] == "測試-日本語.txt")
        .unwrap();
    assert!(
        entries.len() == legacy.as_array().unwrap().len() && entries[0]["isDir"] == true,
        "Real directory shape/order changed"
    );
    assert!(
        file["size"] == 7 && !file["modified"].as_str().unwrap_or_default().is_empty(),
        "Real metadata omitted"
    );
    let error = list(&f.engine, "", &Uuid::new_v4().to_string(), "missing-remote")
        .wait()
        .expect_err("Missing remote returned success");
    assert!(
        error.contains("rclone 執行失敗"),
        "Missing remote did not preserve rclone error: {error}"
    );
}
struct Server(Child);
impl Drop for Server {
    fn drop(&mut self) {
        if self.0.try_wait().ok().flatten().is_none() {
            process::signal(self.0.id(), 2);
            let deadline = Instant::now() + Duration::from_secs(2);
            while self.0.try_wait().ok().flatten().is_none() && Instant::now() < deadline {
                thread::sleep(Duration::from_millis(10));
            }
            if self.0.try_wait().ok().flatten().is_none() {
                process::signal(self.0.id(), 9);
                let _ = self.0.kill();
            }
            let _ = self.0.wait();
        }
    }
}
#[test]
#[ignore = "requires pinned RBN_TEST_RCLONE"]
fn real_throttled_http_cancellation_reaps_rclone_and_preserves_running_transfer() {
    let suite = Suite::new();
    let files = suite.area("http-root");
    for index in 0..12 {
        fs::write(files.join(format!("item-{index}.txt")), b"metadata").unwrap();
    }
    let log = suite.root.join("http-server.log");
    let config = suite.root.join("server.conf");
    fs::write(&config, b"").unwrap();
    let binary = suite
        .rclone
        .as_ref()
        .expect("RBN_TEST_RCLONE must be pinned");
    let context = Context {
        binary: binary.clone(),
        arguments: vec![],
        environment: std::env::vars()
            .filter(|(k, _)| !k.to_uppercase().starts_with("RCLONE_"))
            .collect::<BTreeMap<_, _>>(),
        work_dir: suite.root.clone(),
    };
    let child = process::command(&context)
        .unwrap()
        .args([
            "--config",
            config.to_str().unwrap(),
            "serve",
            "http",
            files.to_str().unwrap(),
            "--addr",
            "127.0.0.1:0",
            "--log-level",
            "INFO",
            "--log-file",
            log.to_str().unwrap(),
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let _server = Server(child);
    let expression = regex::Regex::new(r"http://127\.0\.0\.1:[0-9]+/").unwrap();
    let mut url = String::new();
    wait_until("real HTTP backend", 8., || {
        let text = fs::read_to_string(&log).unwrap_or_default();
        if let Some(found) = expression.find(&text) {
            url = found.as_str().to_owned();
        }
        Ok(!url.is_empty())
    })
    .unwrap();
    let f = suite.make(
        "real-http",
        true,
        true,
        Duration::from_secs(120),
        &format!("[fixture]\ntype = http\nurl = {url}\n"),
    );
    f.engine
        .invoke(
            "saveSettings",
            vec![json!({"networkOptions":{"tpsLimit":1,"tpsBurst":1}})],
        )
        .unwrap();
    let source = suite.area("copy-source");
    let destination = suite.area("copy-destination");
    fs::write(source.join("owned.bin"), vec![0x5a; 2 * 1024 * 1024]).unwrap();
    let mut options = models::default_options();
    options["bandwidth"] = json!("64K");
    options["extraArgs"] = json!(["--local-no-clone", "--multi-thread-streams=0"]);
    let request = json!({"source":{"remote":null,"path":source},"destination":{"remote":null,"path":destination},"mode":"copy","dryRun":false,"selection":[],"options":options});
    let transfer = f.engine.invoke("startTransfer", vec![request]).unwrap();
    let transfer_id = transfer["id"].as_str().unwrap().to_owned();
    let transfer_status = || -> Result<String> {
        let jobs = f.engine.invoke("listJobs", vec![])?;
        Ok(jobs
            .as_array()
            .unwrap()
            .iter()
            .find(|v| v["id"] == transfer_id)
            .and_then(|v| v["status"].as_str())
            .unwrap_or_default()
            .to_owned())
    };
    wait_until("real transfer running", 8., || {
        Ok(transfer_status()? == "running")
    })
    .unwrap();
    let id = Uuid::new_v4().to_string();
    let worker = list(&f.engine, "", &id, "fixture");
    let child = pid(&f.engine, &id);
    thread::sleep(Duration::from_millis(150));
    assert!(
        process_alive(child),
        "HTTP fixture did not hold real listing"
    );
    let started = Instant::now();
    cancel(&f.engine, &id).unwrap();
    let elapsed = started.elapsed();
    status(&worker, "cancelled");
    assert!(
        !process_alive(child),
        "Actual rclone child survived cancellation acknowledgement"
    );
    assert_eq!(
        transfer_status().unwrap(),
        "running",
        "Directory cancellation changed transfer status"
    );
    assert!(
        elapsed < Duration::from_secs(5),
        "Real rclone directory cancellation exceeded bound"
    );
    eprintln!(
        "REAL_LISTING_CANCEL_EVIDENCE {}",
        json!({"pid":child,"aliveAfterAck":false,"elapsedSeconds":elapsed.as_secs_f64(),"transferStillRunning":true,"loopbackOnly":true})
    );
    f.engine
        .invoke("cancelJob", vec![json!(transfer_id)])
        .unwrap();
    assert_eq!(
        transfer_status().unwrap(),
        "cancelled",
        "Fixture transfer did not stop during explicit cleanup"
    );
}
