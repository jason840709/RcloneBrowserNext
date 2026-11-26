use crate::{
    Result,
    accounts::Accounts,
    catalog, local,
    models::{self, Endpoint, TransferRequest},
    now,
    process::{self, Context},
    report::{self, Report},
    retry::{self, Decision, Failure},
    stats::{self, Throughput},
    storage,
    tools::Tools,
    updater::Updater,
};
use serde_json::{Value, json};
#[cfg(not(target_os = "macos"))]
use std::fs::OpenOptions;
use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{self},
    path::{Path, PathBuf},
    sync::{
        Arc, Condvar, Mutex, Weak,
        atomic::{AtomicBool, AtomicU32, Ordering},
    },
    thread,
    time::{Duration, Instant},
};
use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;

type EventHandler = Arc<dyn Fn(Value) + Send + Sync>;
struct Control {
    cancel: AtomicBool,
    stop: AtomicBool,
    failure: Mutex<Option<String>>,
    finished: Mutex<Option<(String, bool)>>,
}
impl Control {
    fn new() -> Self {
        Self {
            cancel: AtomicBool::new(false),
            stop: AtomicBool::new(false),
            failure: Mutex::new(None),
            finished: Mutex::new(None),
        }
    }
}
struct Listing {
    cancel: Arc<AtomicBool>,
    prepared: bool,
    claimed: bool,
    finished: bool,
    finished_at: Option<Instant>,
    deadline: Option<Instant>,
    child: Arc<AtomicU32>,
    timed_out: Arc<AtomicBool>,
}
impl Listing {
    fn new() -> Self {
        Self {
            cancel: Arc::new(AtomicBool::new(false)),
            prepared: false,
            claimed: false,
            finished: false,
            finished_at: None,
            deadline: None,
            child: Arc::new(AtomicU32::new(0)),
            timed_out: Arc::new(AtomicBool::new(false)),
        }
    }
}
struct State {
    settings: Value,
    environment: Value,
    jobs: Vec<Value>,
    tasks: Vec<Value>,
    controls: BTreeMap<String, Arc<Control>>,
    listings: BTreeMap<String, Listing>,
    types: BTreeMap<String, String>,
    operations: usize,
    scheduled: BTreeMap<String, u64>,
    notification_serial: u64,
    persist_scheduled: bool,
    maintenance: bool,
    account_maintenance: bool,
    configuration_changing: bool,
    configuring: bool,
    closing: bool,
    password: Option<String>,
}
pub struct Engine {
    self_weak: Weak<Engine>,
    event_sender: std::sync::mpsc::Sender<Value>,
    event_order: Mutex<()>,
    pub state_dir: PathBuf,
    default_dir: PathBuf,
    logs: PathBuf,
    filters: PathBuf,
    state: Mutex<State>,
    listing_changed: Condvar,
    job_changed: Condvar,
    shutdown_cancel: AtomicBool,
    listing_timeout: Duration,
    settings_gate: Mutex<()>,
    write_lock: Mutex<()>,
    event: Mutex<Option<EventHandler>>,
    captured_tasks: Mutex<BTreeMap<String, Vec<u8>>>,
    captured_logs: Mutex<BTreeMap<String, PathBuf>>,
    mac_locations: Mutex<Option<(String, Vec<Value>)>>,
    active_reports: Mutex<BTreeMap<String, Arc<Mutex<Report>>>>,
    active_logs: Mutex<BTreeMap<String, Arc<Mutex<crate::logging::Log>>>>,
    accounts: Arc<Accounts>,
    tools: Arc<Tools>,
    updater: Updater,
}
struct Operation {
    engine: Arc<Engine>,
}
impl Drop for Operation {
    fn drop(&mut self) {
        if let Ok(mut s) = self.engine.state.lock() {
            s.operations = s.operations.saturating_sub(1);
            self.engine.job_changed.notify_all();
        }
    }
}
struct SettingsChange {
    engine: Arc<Engine>,
    active: bool,
    reserved: bool,
}
impl Drop for SettingsChange {
    fn drop(&mut self) {
        if self.active {
            if let Ok(mut state) = self.engine.state.lock() {
                state.configuration_changing = false;
                if self.reserved {
                    state.operations = state.operations.saturating_sub(1);
                }
                self.engine.job_changed.notify_all();
            }
        }
        self.engine.pump();
    }
}
fn text(args: &[Value], index: usize, label: &str) -> Result<String> {
    models::text(arg(args, index), label, 32768).map(str::to_owned)
}
fn arg(args: &[Value], i: usize) -> &Value {
    args.get(i).unwrap_or(&Value::Null)
}
fn terminal(job: &Value) -> bool {
    ["completed", "failed", "cancelled", "interrupted"]
        .contains(&job["status"].as_str().unwrap_or(""))
}
fn id_valid(id: &str) -> Result<()> {
    if crate::valid_id(id) {
        Ok(())
    } else {
        Err("工作編號不正確。".into())
    }
}
fn blank_environment(config: &str) -> Value {
    json!({"version":"","rclonePath":"","configPath":config,"platform":if cfg!(target_os="macos"){"darwin"}else if cfg!(windows){"win32"}else{"linux"},"arch":if cfg!(target_arch="aarch64"){"arm64"}else{"x64"},"available":false})
}
impl Engine {
    pub fn new(state_dir: PathBuf, default_dir: PathBuf) -> Result<Arc<Self>> {
        Self::new_with_listing_timeout(state_dir, default_dir, Duration::from_secs(120))
    }
    pub fn new_with_listing_timeout(
        state_dir: PathBuf,
        default_dir: PathBuf,
        listing_timeout: Duration,
    ) -> Result<Arc<Self>> {
        if listing_timeout.is_zero() {
            return Err("目錄讀取逾時設定不正確。".into());
        }
        if !state_dir.is_absolute() || !default_dir.is_absolute() {
            return Err("程式資料位置必須是完整路徑。".into());
        }
        let logs = state_dir.join("logs");
        let filters = state_dir.join("filters");
        for p in [&state_dir, &logs, &filters] {
            storage::private_directory(p)?;
        }
        let defaults = models::default_settings(&default_dir);
        let saved = storage::read_json(&state_dir.join("settings.json"), defaults.clone())?;
        let settings = models::load_settings(&saved, &defaults).unwrap_or(defaults);
        let raw_jobs = storage::read_json(&state_dir.join("jobs.json"), json!([]))?;
        let mut jobs = vec![];
        let mut cleared = vec![];
        if let Some(rows) = raw_jobs
            .as_array()
            .filter(|a| a.iter().all(Value::is_object))
        {
            for raw in rows {
                if let Ok(job) = crate::history::job(raw) {
                    if jobs.iter().any(|j: &Value| j["id"] == job["id"]) {
                        continue;
                    }
                    if job["status"] == "completed" {
                        cleared.push(job["id"].as_str().unwrap().to_owned());
                        continue;
                    }
                    jobs.push(job);
                }
            }
        }
        let raw_tasks = storage::read_json(&state_dir.join("tasks.json"), json!([]))?;
        let mut tasks = vec![];
        if let Some(rows) = raw_tasks
            .as_array()
            .filter(|a| a.iter().all(Value::is_object))
        {
            for raw in rows.iter().take(1000) {
                if let Ok(task) = crate::history::task(raw) {
                    tasks.retain(|t: &Value| t["id"] != task["id"]);
                    tasks.push(task);
                }
            }
        }
        for entry in fs::read_dir(&filters).map_err(|e| e.to_string())? {
            let entry = entry.map_err(|e| e.to_string())?;
            let name = entry.file_name();
            let Some(name) = name.to_str() else {
                continue;
            };
            if name
                .strip_suffix(".filter")
                .is_some_and(|id| crate::valid_id(id))
            {
                let _ = fs::remove_file(entry.path());
            }
        }
        let accounts = Accounts::new(state_dir.join("tmp/accounts"))?;
        let tools = Tools::new(state_dir.join("tools"))?;
        let updater = Updater::new(state_dir.join("updates"))?;
        let (event_sender, event_receiver) = std::sync::mpsc::channel();
        let engine = Arc::new_cyclic(|weak| Self {
            self_weak: weak.clone(),
            event_sender,
            event_order: Mutex::new(()),
            state_dir,
            default_dir,
            logs,
            filters,
            state: Mutex::new(State {
                environment: blank_environment(settings["configPath"].as_str().unwrap_or("")),
                settings,
                jobs,
                tasks,
                controls: BTreeMap::new(),
                listings: BTreeMap::new(),
                types: BTreeMap::new(),
                operations: 0,
                scheduled: BTreeMap::new(),
                notification_serial: 0,
                persist_scheduled: false,
                maintenance: false,
                account_maintenance: false,
                configuration_changing: false,
                configuring: false,
                closing: false,
                password: None,
            }),
            listing_changed: Condvar::new(),
            job_changed: Condvar::new(),
            shutdown_cancel: AtomicBool::new(false),
            listing_timeout,
            settings_gate: Mutex::new(()),
            write_lock: Mutex::new(()),
            event: Mutex::new(None),
            captured_tasks: Mutex::new(BTreeMap::new()),
            captured_logs: Mutex::new(BTreeMap::new()),
            mac_locations: Mutex::new(None),
            active_reports: Mutex::new(BTreeMap::new()),
            active_logs: Mutex::new(BTreeMap::new()),
            accounts,
            tools,
            updater,
        });
        let weak = Arc::downgrade(&engine);
        thread::spawn(move || {
            while let Ok(event) = event_receiver.recv() {
                let Some(engine) = weak.upgrade() else {
                    break;
                };
                let handler = engine.event.lock().ok().and_then(|handler| handler.clone());
                drop(engine);
                if let Some(handler) = handler {
                    handler(event);
                }
            }
        });
        let weak = Arc::downgrade(&engine);
        engine.tools.set_event_handler(Arc::new(move |v| {
            if let Some(e) = weak.upgrade() {
                e.emit(json!({"type":"toolSessionUpdate","data":v}));
            }
        }));
        let weak = Arc::downgrade(&engine);
        engine.updater.set_event_handler(Arc::new(move |value| {
            if let Some(engine) = weak.upgrade() {
                engine.emit(json!({"type":"updateStatus","data":value}));
            }
        }));
        engine.persist()?;
        for id in cleared {
            if !engine.lock()?.jobs.iter().any(|j| j["id"] == id) {
                engine.remove_logs(&id);
            }
        }
        Ok(engine)
    }
    fn lock(&self) -> Result<std::sync::MutexGuard<'_, State>> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| "程式狀態無法讀取。".to_owned())?;
        if state.account_maintenance && !self.accounts.has_active() {
            state.account_maintenance = false;
            state.maintenance = false;
        }
        Ok(state)
    }
    pub fn set_event_handler(&self, handler: EventHandler) {
        if let Ok(mut h) = self.event.lock() {
            *h = Some(handler);
        }
    }
    fn emit(&self, event: Value) {
        let _ = self.event_sender.send(event);
    }
    fn enter(self: &Arc<Self>) -> Result<Operation> {
        self.enter_listing(None)
    }
    fn enter_listing(self: &Arc<Self>, cancel: Option<&AtomicBool>) -> Result<Operation> {
        let _gate = if cancel.is_some() {
            loop {
                match self.settings_gate.try_lock() {
                    Ok(gate) => break gate,
                    Err(std::sync::TryLockError::WouldBlock) => {
                        self.check_listing_cancel(cancel)?;
                        thread::sleep(Duration::from_millis(10));
                    }
                    Err(_) => return Err("程式狀態無法讀取。".into()),
                }
            }
        } else {
            self.settings_gate
                .lock()
                .map_err(|_| "程式狀態無法讀取。")?
        };
        self.check_listing_cancel(cancel)?;
        let mut state = self.lock()?;
        if state.closing {
            return Err("程式正在關閉。".into());
        }
        if state.maintenance {
            return Err("rclone 正在更新，請稍候。".into());
        }
        if state.configuration_changing {
            return Err("rclone 位置正在切換，請稍候。".into());
        }
        state.operations += 1;
        Ok(Operation {
            engine: self.clone(),
        })
    }
    fn persist(&self) -> Result<()> {
        let _write = self.write_lock.lock().map_err(|_| "無法保存程式狀態。")?;
        self.persist_locked(None)
    }
    fn persist_locked(&self, tasks_override: Option<&[Value]>) -> Result<()> {
        let (settings, jobs, tasks, expired) = {
            let mut state = self.lock()?;
            let mut ended = state
                .jobs
                .iter()
                .enumerate()
                .filter(|(_, j)| {
                    ["completed", "failed", "cancelled"]
                        .contains(&j["status"].as_str().unwrap_or(""))
                        && !state.controls.contains_key(j["id"].as_str().unwrap_or(""))
                })
                .map(|(index, j)| {
                    (
                        index,
                        j["endedAt"]
                            .as_str()
                            .or(j["createdAt"].as_str())
                            .unwrap_or("")
                            .to_owned(),
                        j["id"].as_str().unwrap_or("").to_owned(),
                    )
                })
                .collect::<Vec<_>>();
            ended.sort_by(|a, b| a.1.cmp(&b.1).then(a.0.cmp(&b.0)));
            let expired = ended
                .iter()
                .take(ended.len().saturating_sub(200))
                .map(|(_, _, id)| id.clone())
                .collect::<BTreeSet<_>>();
            state
                .jobs
                .retain(|j| !expired.contains(j["id"].as_str().unwrap_or("")));
            for id in &expired {
                state.scheduled.remove(id);
            }
            (
                state.settings.clone(),
                state.jobs.clone(),
                tasks_override.map_or_else(|| state.tasks.clone(), |t| t.to_vec()),
                expired,
            )
        };
        storage::atomic_json(&self.state_dir.join("settings.json"), &settings)?;
        storage::atomic_json(&self.state_dir.join("jobs.json"), &json!(jobs))?;
        storage::atomic_json(&self.state_dir.join("tasks.json"), &json!(tasks))?;
        for id in expired {
            self.remove_logs(&id);
        }
        Ok(())
    }
    pub fn set_maintenance(self: &Arc<Self>, enabled: bool) -> Result<()> {
        let _gate = self
            .settings_gate
            .lock()
            .map_err(|_| "程式狀態無法讀取。")?;
        let mut state = self.lock()?;
        if enabled {
            if state.closing {
                return Err("程式正在關閉。".into());
            }
            if state.maintenance || state.configuration_changing {
                return Err("rclone 更新或位置切換正在進行。".into());
            }
            if state.operations != 0 || state.jobs.iter().any(|j| !terminal(j)) {
                return Err("請等候目錄載入與工作結束，再更新 rclone。".into());
            }
            state.maintenance = true;
        } else {
            state.maintenance = false;
            state.account_maintenance = false;
        }
        Ok(())
    }
    pub fn commit_rclone_update(self: &Arc<Self>, path: &Path) -> Result<()> {
        let value = path.to_str().ok_or("更新後的 rclone 執行檔無法讀取。")?;
        models::text(&json!(value), "rclone 執行檔", 32768)?;
        if !path.is_absolute() || !executable(path) {
            return Err("更新後的 rclone 執行檔無法讀取。".into());
        }
        let path = Endpoint::parse(&json!({"remote":null,"path":value}))?.path;
        let _gate = self
            .settings_gate
            .lock()
            .map_err(|_| "程式狀態無法讀取。")?;
        let _write = self.write_lock.lock().map_err(|_| "無法保存程式狀態。")?;
        let mut changed = {
            let state = self.lock()?;
            if !state.maintenance
                || state.closing
                || state.operations != 0
                || state.jobs.iter().any(|j| !terminal(j))
            {
                return Err("無法保存 rclone 更新位置：更新程序尚未就緒。請重新檢查更新。".into());
            }
            state.settings.clone()
        };
        changed["rclonePath"] = json!(path);
        changed["rcloneDirectory"] = json!(
            Path::new(&path)
                .parent()
                .ok_or("更新後的 rclone 執行檔無法讀取。")?
                .to_string_lossy()
        );
        changed["skippedRcloneVersion"] = json!("");
        changed["settingsRevision"] = json!(changed["settingsRevision"].as_u64().unwrap_or(0) + 1);
        storage::atomic_json(&self.state_dir.join("settings.json"), &changed)?;
        let mut state = self.lock()?;
        state.environment = blank_environment(changed["configPath"].as_str().unwrap_or(""));
        state.environment["settingsRevision"] = changed["settingsRevision"].clone();
        state.settings = changed;
        Ok(())
    }
    pub fn auxiliary_context(&self) -> Result<Context> {
        {
            let state = self.lock()?;
            if state.closing || state.maintenance {
                return Err("rclone 目前無法使用，請稍後再試。".into());
            }
        }
        let flags = if cfg!(any(target_os = "macos", target_os = "linux")) {
            vec![local::SMB_ENCODING.to_owned()]
        } else {
            vec![]
        };
        let mut context = self.context(&flags)?;
        context.arguments.extend(flags);
        Ok(context)
    }
    pub fn with_auxiliary_operation<T>(
        self: &Arc<Self>,
        body: impl FnOnce() -> Result<T>,
    ) -> Result<T> {
        let _operation = self.enter()?;
        body()
    }
    fn settings(&self) -> Result<Value> {
        Ok(self.lock()?.settings.clone())
    }
    pub fn resolved_rclone_path(&self) -> Result<PathBuf> {
        self.binary()
    }
    fn binary(&self) -> Result<PathBuf> {
        let s = self.settings()?;
        let explicit = s["rclonePath"].as_str().unwrap_or("");
        let directory = s["rcloneDirectory"]
            .as_str()
            .filter(|s| !s.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| self.default_dir.clone());
        let executable = if cfg!(windows) {
            "rclone.exe"
        } else {
            "rclone"
        };
        let mut paths = if explicit.is_empty() {
            vec![directory.join(executable)]
        } else {
            vec![PathBuf::from(explicit)]
        };
        if explicit.is_empty() {
            if let Some(path) = std::env::var_os("PATH") {
                paths.extend(std::env::split_paths(&path).map(|p| p.join(executable)));
            }
            #[cfg(target_os = "macos")]
            paths.extend([
                PathBuf::from("/opt/homebrew/bin/rclone"),
                PathBuf::from("/usr/local/bin/rclone"),
            ]);
        }
        for p in paths {
            if !p.is_absolute() || !p.is_file() {
                continue;
            }
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                if p.metadata()
                    .map_err(|e| e.to_string())?
                    .permissions()
                    .mode()
                    & 0o111
                    == 0
                {
                    continue;
                }
            }
            return Ok(p);
        }
        Err(if explicit.is_empty() {
            "找不到 rclone。請在設定中下載，或選擇已有的執行檔。"
        } else {
            "無法執行指定的 rclone，請確認路徑與執行權限。"
        }
        .into())
    }
    fn context(&self, args: &[String]) -> Result<Context> {
        let s = self.settings()?;
        let binary = self.binary()?;
        let mut environment = std::env::vars()
            .filter(|(k, _)| !k.to_uppercase().starts_with("RCLONE_"))
            .collect::<BTreeMap<_, _>>();
        if s["proxyMode"] == "manual" {
            environment.retain(|k, _| {
                !["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"]
                    .contains(&k.to_uppercase().as_str())
            });
            for (key, var) in [
                ("httpProxy", "HTTP_PROXY"),
                ("httpsProxy", "HTTPS_PROXY"),
                ("noProxy", "NO_PROXY"),
            ] {
                if let Some(v) = s[key].as_str().filter(|v| !v.is_empty()) {
                    environment.insert(var.into(), v.into());
                }
            }
        }
        if let Some(password) = &self.lock()?.password {
            environment.insert("RCLONE_CONFIG_PASS".into(), password.clone());
        }
        let explicit = args
            .iter()
            .take_while(|s| s.as_str() != "--")
            .map(|s| s.split('=').next().unwrap_or("").to_owned())
            .collect::<BTreeSet<_>>();
        let mut arguments = vec![];
        if let Some(config) = s["configPath"].as_str().filter(|p| !p.is_empty()) {
            arguments.push(format!("--config={config}"));
        }
        let mut tuning = models::network_arguments(&s["networkOptions"])?;
        tuning.extend(
            s["defaultRcloneOptions"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .map(str::to_owned),
        );
        arguments.extend(
            tuning
                .into_iter()
                .filter(|s| !explicit.contains(s.split('=').next().unwrap_or(""))),
        );
        Ok(Context {
            binary,
            arguments,
            environment,
            work_dir: self.state_dir.clone(),
        })
    }
    fn run(
        &self,
        args: Vec<String>,
        maximum: usize,
        timeout: Duration,
        cancel: Option<&AtomicBool>,
    ) -> Result<process::Output> {
        let cancel = cancel.or(Some(&self.shutdown_cancel));
        let args = local::smb_arguments(args, &self.lock()?.types);
        let context = self.context(&args)?;
        let listing = if let Some(token) = cancel {
            self.lock()?
                .listings
                .values()
                .find(|l| std::ptr::eq(token, l.cancel.as_ref()))
                .map(|l| (l.deadline, l.child.clone(), l.timed_out.clone()))
        } else {
            None
        };
        if let Some((Some(deadline), child, timed_out)) = listing {
            process::capture_listing(
                &context,
                &args,
                maximum,
                deadline,
                cancel.expect("listing token"),
                &child,
                &timed_out,
            )
        } else {
            process::capture(&context, &args, maximum, timeout, cancel)
        }
    }
    fn check_listing_cancel(&self, cancel: Option<&AtomicBool>) -> Result<()> {
        if let Some(token) = cancel {
            let state = self.lock()?;
            if let Some(listing) = state
                .listings
                .values()
                .find(|l| std::ptr::eq(token, l.cancel.as_ref()))
            {
                if listing.timed_out.load(Ordering::Acquire) {
                    return Err("rclone 回應逾時，請檢查連線後重試。".into());
                }
                if token.load(Ordering::Acquire) {
                    return Err("目錄讀取已取消。".into());
                }
                if listing.deadline.is_some_and(|d| Instant::now() >= d) {
                    listing.timed_out.store(true, Ordering::Release);
                    return Err("rclone 回應逾時，請檢查連線後重試。".into());
                }
            }
        }
        Ok(())
    }
    fn detect(&self) -> Result<Value> {
        self.detect_listing(None)
    }
    fn detect_listing(&self, cancel: Option<&AtomicBool>) -> Result<Value> {
        self.check_listing_cancel(cancel)?;
        let settings = self.settings()?;
        let mut env = blank_environment(settings["configPath"].as_str().unwrap_or(""));
        let result = (|| -> Result<()> {
            let binary = self.binary()?;
            let out = self
                .run(
                    vec!["version".into(), "--ask-password=false".into()],
                    1024 * 1024,
                    Duration::from_secs(15),
                    cancel,
                )?
                .checked()?;
            let version = String::from_utf8_lossy(&out.stdout)
                .lines()
                .next()
                .unwrap_or("")
                .to_owned();
            if !regex::Regex::new(r"^rclone v[0-9]+\.[0-9]+")
                .map_err(|e| e.to_string())?
                .is_match(&version)
            {
                return Err("指定的執行檔不是 rclone。".into());
            }
            env["version"] = json!(version);
            env["rclonePath"] = json!(binary.to_string_lossy());
            env["available"] = json!(true);
            if env["configPath"] == "" {
                if let Ok(out) = self
                    .run(
                        vec![
                            "config".into(),
                            "file".into(),
                            "--ask-password=false".into(),
                        ],
                        1024 * 1024,
                        Duration::from_secs(15),
                        cancel,
                    )
                    .and_then(process::Output::checked)
                {
                    if let Some(path) = String::from_utf8_lossy(&out.stdout)
                        .lines()
                        .map(str::trim)
                        .filter(|p| Path::new(p).is_absolute())
                        .next_back()
                    {
                        env["configPath"] = json!(path);
                    }
                }
            }
            Ok(())
        })();
        if let Err(error) = result {
            self.check_listing_cancel(cancel)?;
            env["error"] = json!(error);
        }
        self.check_listing_cancel(cancel)?;
        let mut state = self.lock()?;
        env["settingsRevision"] = state.settings["settingsRevision"].clone();
        state.environment = env.clone();
        Ok(env)
    }
    fn require_available(&self, cancel: Option<&AtomicBool>) -> Result<PathBuf> {
        self.check_listing_cancel(cancel)?;
        if self.lock()?.environment["available"] != true {
            self.detect_listing(cancel)?;
        }
        let state = self.lock()?;
        if state.environment["available"] != true {
            return Err(state.environment["error"]
                .as_str()
                .unwrap_or("找不到 rclone。")
                .into());
        }
        drop(state);
        self.binary()
    }
    fn remotes(&self, cancel: Option<&AtomicBool>) -> Result<Vec<Value>> {
        let raw = self
            .run(
                vec![
                    "listremotes".into(),
                    "--json".into(),
                    "--ask-password=false".into(),
                    "--use-json-log".into(),
                ],
                64 * 1024 * 1024,
                Duration::from_secs(120),
                cancel,
            )?
            .json()?;
        let array = raw
            .as_array()
            .filter(|rows| rows.iter().all(Value::is_object))
            .ok_or("rclone 未回傳有效的遠端清單，請更新 rclone。")?;
        let mut out = vec![];
        let mut types = BTreeMap::new();
        for row in array {
            if let (Some(name), Some(kind)) = (row["name"].as_str(), row["type"].as_str()) {
                types.insert(name.nfc().collect::<String>(), kind.to_owned());
                out.push(json!({"name":name,"type":kind,"group":catalog::remote_group(kind)}));
            }
        }
        self.lock()?.types = types;
        Ok(out)
    }
    fn endpoints(&self, ends: &[&Endpoint], cancel: Option<&AtomicBool>) -> Result<()> {
        if ends.iter().all(|e| e.remote.is_none()) {
            return Ok(());
        }
        let names = self
            .remotes(cancel)?
            .iter()
            .filter_map(|r| {
                r["name"]
                    .as_str()
                    .map(|name| name.nfc().collect::<String>())
            })
            .collect::<BTreeSet<_>>();
        for endpoint in ends {
            if let Some(remote) = &endpoint.remote {
                if !names.contains(&remote.nfc().collect::<String>()) {
                    return Err(format!("找不到遠端連線「{remote}」，請重新整理。"));
                }
            }
        }
        Ok(())
    }
    fn bootstrap(self: &Arc<Self>) -> Result<Value> {
        let _operation = self.enter()?;
        let mut environment = self.detect()?;
        let remotes = if environment["available"] == true {
            match self.remotes(None) {
                Ok(r) => r,
                Err(e) => {
                    environment["error"] = json!(e);
                    vec![]
                }
            }
        } else {
            vec![]
        };
        let (settings, jobs, tasks) = {
            let s = self.lock()?;
            (
                s.settings.clone(),
                s.jobs.iter().rev().cloned().collect::<Vec<_>>(),
                crate::history::sorted_tasks(&s.tasks),
            )
        };
        let cached = self
            .mac_locations
            .lock()
            .map_err(|_| "位置資訊無法讀取。")?
            .clone();
        let (home, mut locations) =
            cached.unwrap_or_else(|| (catalog::home(), catalog::locations()));
        local::annotate_mounted_locations(&mut locations, cfg!(target_os = "macos"));
        let result = json!({"environment":environment,"resolvedLanguage":catalog::language(&settings),"settings":settings,"remotes":remotes,"localLocations":locations,"home":home,"jobs":jobs,"tasks":tasks});
        #[cfg(windows)]
        let result = crate::windows_local::bootstrap(result);
        Ok(result)
    }

    fn list_raw(
        &self,
        endpoint: &Endpoint,
        extra: Vec<String>,
        cancel: Option<&AtomicBool>,
        allow_missing: bool,
    ) -> Result<Vec<Value>> {
        let args = raw_listing_arguments(endpoint, extra);
        let out = self.run(args, 64 * 1024 * 1024, Duration::from_secs(120), cancel)?;
        if allow_missing && out.exit_code == 3 {
            return Ok(vec![]);
        }
        let raw = out.json()?;
        decoded_listing(raw)
    }
    fn list_entries(&self, endpoint: &Endpoint, cancel: &AtomicBool) -> Result<Vec<Value>> {
        let mut entries = vec![];
        let listing_deadline = self
            .lock()?
            .listings
            .values()
            .find(|l| std::ptr::eq(cancel, l.cancel.as_ref()))
            .and_then(|l| l.deadline);
        if endpoint.remote.is_none() {
            #[cfg(windows)]
            return crate::windows_local::list(endpoint);
            for entry in
                fs::read_dir(&endpoint.path).map_err(|e| format!("來源資料夾無法讀取：{e}"))?
            {
                if cancel.load(Ordering::Acquire) {
                    return Err("目錄讀取已取消。".into());
                }
                if listing_deadline.is_some_and(|d| Instant::now() >= d) {
                    return Err("rclone 回應逾時，請檢查連線後重試。".into());
                }
                let entry = entry.map_err(|e| e.to_string())?;
                let name = entry
                    .file_name()
                    .into_string()
                    .map_err(|_| "來源有無法辨識的檔名。")?;
                let meta = fs::symlink_metadata(entry.path())
                    .map_err(|e| format!("無法讀取 {name}：{e}"))?;
                let is_link = meta.file_type().is_symlink();
                let directory = if is_link {
                    entry.path().is_dir()
                } else {
                    meta.is_dir()
                };
                let modified = meta
                    .modified()
                    .ok()
                    .map(|t| {
                        chrono::DateTime::<chrono::Utc>::from(t)
                            .to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
                    })
                    .unwrap_or_default();
                entries.push(json!({"name":name,"path":name,"size":if directory{-1i64}else{meta.len().min(i64::MAX as u64) as i64},"modified":modified,"isDir":directory,"isLink":is_link}));
                if entries.len() > 250000 {
                    return Err("目錄超過 250,000 個項目，請選擇較小的資料夾。".into());
                }
            }
        } else {
            self.require_available(Some(cancel))?;
            for row in self.list_raw(endpoint, vec![], Some(cancel), false)? {
                let name = row["Name"].as_str().unwrap_or("");
                entries.push(json!({"name":name,"path":row["Path"].as_str().unwrap_or(name),"size":if row["Size"].is_number(){row["Size"].clone()}else{json!(-1)},"modified":row["ModTime"].as_str().unwrap_or(""),"isDir":row["IsDir"]==true}));
            }
        }
        let name_order = crate::platform_text::NameOrder::new()?;
        crate::platform_text::stable_sort_by(&mut entries, |a, b| {
            let dirs = (a["isDir"] == true, b["isDir"] == true);
            if dirs.0 != dirs.1 {
                return dirs.1.cmp(&dirs.0);
            }
            name_order.compare(
                a["name"].as_str().unwrap_or(""),
                b["name"].as_str().unwrap_or(""),
            )
        });
        Ok(entries)
    }
    fn listing_id(value: &Value) -> Result<String> {
        let id = models::text(value, "目錄讀取編號", 96)?;
        if id.is_empty() {
            return Err("目錄讀取編號不可空白。".into());
        }
        Ok(id.to_owned())
    }
    fn listing_options_id(options: &Value) -> Result<String> {
        let object = options
            .as_object()
            .filter(|o| o.len() == 1 && o.contains_key("requestId"))
            .ok_or("目錄讀取要求格式不正確。")?;
        Self::listing_id(&object["requestId"])
    }
    fn trim_listings(state: &mut State) {
        if state.listings.len() < 2048 {
            return;
        }
        let mut finished = state
            .listings
            .iter()
            .filter(|(_, l)| l.finished)
            .map(|(id, l)| (id.clone(), l.finished_at))
            .collect::<Vec<_>>();
        finished.sort_by_key(|(_, at)| *at);
        let remove = state.listings.len().saturating_sub(1024);
        for (id, _) in finished.into_iter().take(remove) {
            state.listings.remove(&id);
        }
    }
    pub fn prepare_listing(&self, options: &Value) -> Result<()> {
        if options.is_null() {
            return Ok(());
        }
        let id = Self::listing_options_id(options)?;
        let mut state = self.lock()?;
        Self::trim_listings(&mut state);
        if state
            .listings
            .get(&id)
            .is_some_and(|l| l.prepared || l.claimed)
        {
            return Err("目錄讀取編號已使用，請重新載入。".into());
        }
        if !state.listings.contains_key(&id) && state.listings.len() >= 4096 {
            return Err("目錄讀取要求過多，請稍後重試。".into());
        }
        let closing = state.closing || state.configuration_changing;
        let listing = state.listings.entry(id).or_insert_with(Listing::new);
        listing.prepared = true;
        if closing {
            listing.cancel.store(true, Ordering::Release);
        }
        Ok(())
    }
    fn list(self: &Arc<Self>, endpoint: &Endpoint, options: &Value) -> Result<Value> {
        self.list_with_adapter(endpoint, options, None)
    }
    pub fn list_directory_with_local_adapter(
        self: &Arc<Self>,
        endpoint: &Endpoint,
        options: &Value,
        adapter: &dyn Fn(&Endpoint) -> Result<Vec<Value>>,
    ) -> Result<Value> {
        self.list_with_adapter(endpoint, options, Some(adapter))
    }
    fn list_with_adapter(
        self: &Arc<Self>,
        endpoint: &Endpoint,
        options: &Value,
        adapter: Option<&dyn Fn(&Endpoint) -> Result<Vec<Value>>>,
    ) -> Result<Value> {
        let scoped = !options.is_null();
        let id = if scoped {
            Self::listing_options_id(options)?
        } else {
            uuid::Uuid::new_v4().to_string()
        };
        let token = {
            let mut state = self.lock()?;
            Self::trim_listings(&mut state);
            if state.listings.get(&id).is_some_and(|l| l.claimed) {
                return Err("目錄讀取編號已使用，請重新載入。".into());
            }
            if !state.listings.contains_key(&id) && state.listings.len() >= 4096 {
                return Err("目錄讀取要求過多，請稍後重試。".into());
            }
            let closing = state.closing || state.configuration_changing;
            let listing = state
                .listings
                .entry(id.clone())
                .or_insert_with(Listing::new);
            listing.claimed = true;
            listing.deadline = Some(Instant::now() + self.listing_timeout);
            if closing {
                listing.cancel.store(true, Ordering::Release);
            }
            listing.cancel.clone()
        };
        let result = (|| {
            if token.load(Ordering::Acquire) {
                return Err("目錄讀取已取消。".into());
            }
            let _op = if endpoint.remote.is_some() {
                Some(self.enter_listing(Some(&token))?)
            } else {
                None
            };
            if endpoint.remote.is_none() {
                if let Some(adapter) = adapter {
                    return adapter(endpoint);
                }
            }
            self.list_entries(endpoint, &token)
        })();
        let mut state = self.lock()?;
        let listing = state
            .listings
            .get_mut(&id)
            .ok_or("目錄讀取要求格式不正確。")?;
        if !listing.cancel.load(Ordering::Acquire)
            && listing.deadline.is_some_and(|at| Instant::now() >= at)
        {
            listing.timed_out.store(true, Ordering::Release);
        }
        let timed_out = listing.timed_out.load(Ordering::Acquire);
        let cancelled = listing.cancel.load(Ordering::Acquire);
        listing.finished = true;
        listing.finished_at = Some(Instant::now());
        listing.child.store(0, Ordering::Release);
        self.listing_changed.notify_all();
        self.job_changed.notify_all();
        drop(state);
        if timed_out {
            return Err("rclone 回應逾時，請檢查連線後重試。".into());
        }
        if cancelled {
            return if scoped {
                Ok(json!({"requestId":id,"status":"cancelled","entries":[]}))
            } else {
                Err("目錄讀取已取消。".into())
            };
        }
        result.map(|entries| {
            if scoped {
                json!({"requestId":id,"status":"completed","entries":entries})
            } else {
                json!(entries)
            }
        })
    }
    fn cancel_listing(&self, raw_id: &str) -> Result<Value> {
        let id = Self::listing_id(&json!(raw_id))?;
        let mut state = self.lock()?;
        Self::trim_listings(&mut state);
        if state.listings.get(&id).is_some_and(|l| l.finished) {
            return Ok(json!({"requestId":id,"cancelled":false}));
        }
        if !state.listings.contains_key(&id) && state.listings.len() >= 4096 {
            return Err("目錄讀取要求過多，請稍後重試。".into());
        }
        let listing = state
            .listings
            .entry(id.clone())
            .or_insert_with(Listing::new);
        listing.cancel.store(true, Ordering::Release);
        let claimed = listing.claimed;
        let until = Instant::now() + Duration::from_secs(5);
        while claimed && state.listings.get(&id).is_some_and(|l| !l.finished) {
            let remaining = until.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Err("目錄讀取尚未停止，請稍後再試。".into());
            }
            let (next, _) = self
                .listing_changed
                .wait_timeout(state, remaining)
                .map_err(|_| "程式狀態無法讀取。")?;
            state = next;
        }
        Ok(json!({"requestId":id,"cancelled":true}))
    }
    pub fn cancel_listings(&self) {
        if let Ok(state) = self.state.lock() {
            for listing in state.listings.values().filter(|l| !l.finished) {
                listing.cancel.store(true, Ordering::Release);
            }
        }
    }
    pub fn listing_process_identifier(&self, id: &str) -> Option<u32> {
        self.state
            .lock()
            .ok()?
            .listings
            .get(id)
            .map(|l| l.child.load(Ordering::Acquire))
            .filter(|pid| *pid != 0)
    }
    fn normalize(&self, raw: &Value) -> Result<TransferRequest> {
        let mut object = raw.as_object().ok_or("傳輸設定格式不正確。")?.clone();
        let supplied = raw["options"].as_object().ok_or("傳輸選項格式不正確。")?;
        let settings = self.settings()?;
        let mut options = settings["defaultTransferOptions"]
            .as_object()
            .ok_or("預設傳輸選項格式不正確。")?
            .clone();
        options.extend(supplied.clone());
        object.insert("options".into(), Value::Object(options));
        TransferRequest::parse(&Value::Object(object))
    }
    fn prepare(&self, raw: &Value) -> Result<TransferRequest> {
        self.require_available(None)?;
        let request = self.normalize(raw)?;
        models::validate_pair(&request)?;
        self.endpoints(&[&request.source, &request.destination], None)?;
        Ok(request)
    }
    fn preview(&self, request: &TransferRequest) -> Result<Value> {
        let settings = self.settings()?;
        let types = self.lock()?.types.clone();
        let (args, warnings) =
            local::preview_arguments(request, &types, settings["retryScope"] == "failed")?;
        let context = self.context(&args)?;
        let mut command = vec![context.binary.to_string_lossy().into_owned()];
        command.extend(context.arguments);
        command.extend(args);
        Ok(json!({"command":local::display_command(&command),"warnings":warnings}))
    }

    fn file_action(self: &Arc<Self>, method: &str, args: &[Value]) -> Result<Value> {
        let endpoint = Endpoint::parse(arg(args, 0))?;
        let name = if ["mkdir", "rename"].contains(&method) {
            Some(text(args, 1, "名稱")?)
        } else {
            None
        };
        let new_name = if method == "rename" {
            Some(text(args, 2, "新名稱")?)
        } else {
            None
        };
        let is_dir = if method == "rename" {
            Some(models::boolean(arg(args, 3), "項目類型")?)
        } else {
            None
        };
        let selection = if method == "remove" {
            let request = TransferRequest::parse(
                &json!({"source":endpoint.value(),"destination":endpoint.value(),"mode":"copy","options":models::default_options(),"selection":arg(args,1),"dryRun":false}),
            )?;
            if request.selection.is_empty() {
                return Err("請先選取要刪除的項目。".into());
            }
            Some(request.selection)
        } else {
            None
        };
        if endpoint.remote.is_none() {
            #[cfg(windows)]
            {
                match method {
                    "mkdir" => crate::windows_local::mkdir(&endpoint, name.as_deref().unwrap())?,
                    "rename" => crate::windows_local::rename(
                        &endpoint,
                        name.as_deref().unwrap(),
                        new_name.as_deref().unwrap(),
                        is_dir.unwrap(),
                    )?,
                    "remove" => {
                        crate::windows_local::remove(&endpoint, selection.as_ref().unwrap())?;
                        return Ok(json!(true));
                    }
                    "size" => return crate::windows_local::size(&endpoint),
                    _ => unreachable!(),
                };
                return Ok(Value::Null);
            }
            #[cfg(not(windows))]
            {
                if method == "size" {
                    return local_size(Path::new(&endpoint.path));
                }
                let child = if let Some(name) = &name {
                    Some(endpoint.child(name)?)
                } else {
                    None
                };
                if method == "mkdir" {
                    let child = child.unwrap();
                    if Path::new(&child.path).exists() {
                        return Err("同名項目已存在。".into());
                    }
                    fs::create_dir(&child.path).map_err(|e| e.to_string())?;
                    return Ok(Value::Null);
                }
                if method == "rename" {
                    let name = name.as_deref().unwrap();
                    let new_name = new_name.as_deref().unwrap();
                    let target = endpoint.child(new_name)?;
                    if same_text(name, new_name) {
                        return Ok(Value::Null);
                    }
                    let entries = self.list_entries(&endpoint, &AtomicBool::new(false))?;
                    validate_selection(
                        &[models::Selection {
                            name: name.into(),
                            is_dir: is_dir.unwrap(),
                        }],
                        &entries,
                    )?;
                    let collision = entries.iter().any(|entry| {
                        let existing = entry["name"].as_str().unwrap_or("");
                        if cfg!(target_os = "macos") {
                            same_text(&existing.to_lowercase(), &new_name.to_lowercase())
                        } else {
                            same_text(existing, new_name)
                        }
                    });
                    if collision {
                        return Err("新名稱已存在，請選擇其他名稱。".into());
                    }
                    rename_exclusive(Path::new(&child.unwrap().path), Path::new(&target.path))?;
                    return Ok(Value::Null);
                }
                let selection = selection.as_ref().unwrap();
                let entries = self.list_entries(&endpoint, &AtomicBool::new(false))?;
                validate_selection(selection, &entries)?;
                for item in selection {
                    let child = endpoint.child(&item.name)?;
                    let metadata = fs::symlink_metadata(&child.path).map_err(|e| e.to_string())?;
                    if metadata.is_dir() && !metadata.file_type().is_symlink() {
                        fs::remove_dir_all(&child.path).map_err(|e| e.to_string())?;
                    } else {
                        fs::remove_file(&child.path).map_err(|e| e.to_string())?;
                    }
                }
                return Ok(json!(true));
            }
        }
        let _op = self.enter()?;
        self.require_available(None)?;
        self.endpoints(&[&endpoint], None)?;
        if method == "size" {
            let raw = self
                .run(
                    vec![
                        "size".into(),
                        "--json".into(),
                        "--ask-password=false".into(),
                        "--use-json-log".into(),
                        "--".into(),
                        endpoint.target(),
                    ],
                    1024 * 1024,
                    Duration::from_secs(600),
                    None,
                )?
                .json()?;
            if !raw.is_object()
                || (!raw["count"].is_number() && !raw["count"].is_boolean())
                || (!raw["bytes"].is_number() && !raw["bytes"].is_boolean())
            {
                return Err("rclone 未回傳有效的容量資訊。".into());
            }
            return Ok(
                json!({"count":stats::number(&raw["count"]),"bytes":stats::number(&raw["bytes"])}),
            );
        }
        if method == "mkdir" {
            let name = name.as_deref().unwrap();
            let child = endpoint.child(name)?;
            if self
                .list_raw(&endpoint, vec![], None, false)?
                .iter()
                .any(|entry| entry["Name"].as_str().is_some_and(|n| same_text(n, name)))
            {
                return Err("同名項目已存在。".into());
            }
            self.run(
                vec![
                    "mkdir".into(),
                    "--ask-password=false".into(),
                    "--use-json-log".into(),
                    "--".into(),
                    child.target(),
                ],
                1024 * 1024,
                Duration::from_secs(120),
                None,
            )?
            .checked()?;
            return Ok(Value::Null);
        }
        if method == "rename" {
            let name = name.as_deref().unwrap();
            let new_name = new_name.as_deref().unwrap();
            let from = endpoint.child(name)?;
            let to = endpoint.child(new_name)?;
            if same_text(name, new_name) {
                return Ok(Value::Null);
            }
            let directory = is_dir.unwrap();
            let entries = self.list_raw(&endpoint, vec![], None, false)?;
            if !entries.iter().any(|entry| {
                entry["Name"].as_str().is_some_and(|n| same_text(n, name))
                    && (entry["IsDir"] == true) == directory
            }) {
                return Err("原項目已不存在或類型已改變。".into());
            }
            if entries.iter().any(|entry| {
                entry["Name"]
                    .as_str()
                    .is_some_and(|n| same_text(n, new_name))
            }) {
                return Err("新名稱已存在，請選擇其他名稱。".into());
            }
            let mut arguments = vec![if directory {
                "move".into()
            } else {
                "moveto".into()
            }];
            if directory {
                arguments.extend([
                    "--create-empty-src-dirs".into(),
                    "--delete-empty-src-dirs".into(),
                ]);
            }
            arguments.extend([
                "--ignore-existing".into(),
                "--ask-password=false".into(),
                "--use-json-log".into(),
                "--log-level=INFO".into(),
                "--".into(),
                from.target(),
                to.target(),
            ]);
            self.run(arguments, 4 * 1024 * 1024, Duration::from_secs(120), None)?
                .checked()?;
            if self
                .list_raw(&endpoint, vec![], None, false)?
                .iter()
                .any(|entry| entry["Name"].as_str().is_some_and(|n| same_text(n, name)))
            {
                if !directory {
                    return Err("來源項目仍存在，目標端可能已有同名項目，請重新整理確認。".into());
                }
                self.run(
                    vec![
                        "rmdir".into(),
                        "--ask-password=false".into(),
                        "--use-json-log".into(),
                        "--".into(),
                        from.target(),
                    ],
                    1024 * 1024,
                    Duration::from_secs(120),
                    None,
                )
                .and_then(process::Output::checked)
                .map_err(|_| "部分內容仍留在原資料夾，請一併檢查新舊兩個資料夾。")?;
            }
            return Ok(Value::Null);
        }
        let selection = selection.as_ref().unwrap();
        let entries = self
            .list_raw(&endpoint, vec![], None, false)?
            .iter()
            .map(
                |row| json!({"name":row["Name"].as_str().unwrap_or(""),"isDir":row["IsDir"]==true}),
            )
            .collect::<Vec<_>>();
        validate_selection(selection, &entries)?;
        for item in selection {
            let child = endpoint.child(&item.name)?;
            self.run(
                vec![
                    if item.is_dir {
                        "purge".into()
                    } else {
                        "deletefile".into()
                    },
                    "--ask-password=false".into(),
                    "--use-json-log".into(),
                    "--log-level=INFO".into(),
                    "--".into(),
                    child.target(),
                ],
                4 * 1024 * 1024,
                Duration::from_secs(120),
                None,
            )?
            .checked()?;
        }
        Ok(json!(true))
    }
    fn publish_job(&self, id: &str) {
        let Ok(_ordered) = self.event_order.lock() else {
            return;
        };
        let snapshot = self
            .lock()
            .ok()
            .and_then(|state| state.jobs.iter().find(|j| j["id"] == id).cloned());
        if let Some(job) = snapshot {
            self.emit(json!({"type":"jobUpdate","data":job}));
        }
    }
    fn notify(&self, id: &str, immediate: bool) {
        let queued = (|| -> Result<(Option<u64>, bool)> {
            let mut state = self.lock()?;
            let mut generation = None;
            if immediate {
                state.scheduled.remove(id);
            } else if !state.scheduled.contains_key(id) {
                state.notification_serial = state.notification_serial.wrapping_add(1);
                let serial = state.notification_serial;
                state.scheduled.insert(id.to_owned(), serial);
                generation = Some(serial);
            }
            let persist = !state.persist_scheduled && !state.closing;
            if persist {
                state.persist_scheduled = true;
            }
            Ok((generation, persist))
        })();
        let Ok((generation, persist)) = queued else {
            return;
        };
        if immediate {
            self.publish_job(id);
        }
        if let Some(generation) = generation {
            let weak = self.self_weak.clone();
            let id = id.to_owned();
            thread::spawn(move || {
                thread::sleep(Duration::from_millis(150));
                let Some(engine) = weak.upgrade() else {
                    return;
                };
                let Ok(_ordered) = engine.event_order.lock() else {
                    return;
                };
                let snapshot = engine.lock().ok().and_then(|mut state| {
                    if state.scheduled.get(&id) != Some(&generation) {
                        return None;
                    }
                    state.scheduled.remove(&id);
                    state.jobs.iter().find(|j| j["id"] == id).cloned()
                });
                if let Some(job) = snapshot {
                    engine.emit(json!({"type":"jobUpdate","data":job}));
                }
            });
        }
        if persist {
            let weak = self.self_weak.clone();
            thread::spawn(move || {
                thread::sleep(Duration::from_secs(1));
                let Some(engine) = weak.upgrade() else {
                    return;
                };
                if let Ok(mut state) = engine.lock() {
                    state.persist_scheduled = false;
                }
                if let Err(error) = engine.persist() {
                    let message = format!("無法儲存工作狀態：{error}");
                    let ids = (|| -> Result<Vec<String>> {
                        let mut state = engine.lock()?;
                        let controls = state
                            .controls
                            .iter()
                            .filter(|(id, _)| {
                                state.jobs.iter().any(|job| {
                                    job["id"] == id.as_str() && job["status"] != "queued"
                                })
                            })
                            .map(|(id, control)| (id.clone(), control.clone()))
                            .collect::<Vec<_>>();
                        let mut ids = vec![];
                        for (id, control) in controls {
                            if let Ok(mut failure) = control.failure.lock() {
                                if failure.is_none() {
                                    *failure = Some(message.clone());
                                }
                            }
                            control.stop.store(true, Ordering::Release);
                            if let Some(job) = state.jobs.iter_mut().find(|j| j["id"] == id) {
                                job["error"] = json!(message);
                                if !terminal(job) {
                                    job["status"] = json!("cancelling");
                                }
                                ids.push(id);
                            }
                        }
                        Ok(ids)
                    })();
                    let _ = ids;
                }
            });
        }
    }
    fn mutate_job(&self, id: &str, change: impl FnOnce(&mut Value)) -> Result<()> {
        let mut s = self.lock()?;
        let job = s
            .jobs
            .iter_mut()
            .find(|j| j["id"] == id)
            .ok_or("找不到工作。")?;
        change(job);
        Ok(())
    }
    fn start(self: &Arc<Self>, request: TransferRequest) -> Result<Value> {
        let id = uuid::Uuid::new_v4().to_string();
        let command = self.preview(&request)?["command"].clone();
        let job = json!({"id":id,"request":request.value(),"status":"queued","createdAt":now(),"stats":stats::empty(),"logs":[],"command":command});
        {
            let mut s = self.lock()?;
            if s.closing || s.maintenance || s.configuring || self.accounts.has_active() {
                return Err("程式正在更新或設定，請稍後重試。".into());
            }
            if s.jobs.iter().filter(|j| !terminal(j)).count() >= 1000 {
                return Err("工作數量過多，請先等候部分工作完成。".into());
            }
            s.jobs.push(job.clone());
            s.controls.insert(id.clone(), Arc::new(Control::new()));
        }
        if let Err(error) = self.persist() {
            let message = format!("無法儲存工作，未開始傳輸：{error}");
            {
                let mut state = self.lock()?;
                if let Some(job) = state.jobs.iter_mut().find(|j| j["id"] == id) {
                    job["status"] = json!("failed");
                    job["endedAt"] = json!(now());
                    job["error"] = json!(message);
                }
                state.controls.remove(&id);
            }
            self.notify(&id, true);
            return Err(message);
        }
        self.notify(&id, true);
        self.pump();
        self.lock()?
            .jobs
            .iter()
            .find(|job| job["id"] == id)
            .cloned()
            .ok_or_else(|| "找不到這項工作。".into())
    }
    fn pump(self: &Arc<Self>) {
        let ready = (|| -> Result<Vec<(String, Value, Arc<Control>)>> {
            let mut s = self.lock()?;
            if s.closing || s.maintenance || s.configuration_changing || s.configuring {
                return Ok(vec![]);
            }
            let max = s.settings["maxConcurrentJobs"].as_u64().unwrap_or(0) as usize;
            let active = s
                .jobs
                .iter()
                .filter(|j| j["status"] == "running" || j["status"] == "cancelling")
                .count();
            let slots = if max == 0 {
                usize::MAX
            } else {
                max.saturating_sub(active)
            };
            let ids = s
                .jobs
                .iter()
                .filter(|j| j["status"] == "queued")
                .take(slots)
                .filter_map(|j| j["id"].as_str().map(str::to_owned))
                .collect::<Vec<_>>();
            let mut ready = vec![];
            for id in ids {
                let Some(control) = s.controls.get(&id).cloned() else {
                    continue;
                };
                if let Some(job) = s.jobs.iter_mut().find(|j| j["id"] == id) {
                    job["status"] = json!("running");
                    job["startedAt"] = json!(now());
                    ready.push((id, job["request"].clone(), control));
                }
            }
            Ok(ready)
        })();
        if let Ok(ready) = ready {
            for (id, request, control) in ready {
                let engine = self.clone();
                self.notify(&id, true);
                thread::spawn(move || {
                    engine.worker(&id, request, control);
                });
            }
        }
    }
    fn write_filter(
        &self,
        id: &str,
        request: &TransferRequest,
        cancel: &AtomicBool,
    ) -> Result<Option<PathBuf>> {
        let mut rules = models::selection_filter_rules(request);
        if !request.selection.is_empty()
            && request.options["include"]
                .as_array()
                .is_some_and(|a| !a.is_empty())
        {
            if let Some(log) = self
                .active_logs
                .lock()
                .map_err(|_| "工作記錄無法讀取。")?
                .get(id)
                .cloned()
            {
                self.app_log(id, &log, "正在套用選取範圍與包含規則。")?;
            }
            let mut flags = vec!["--recursive".into(), "--no-modtime".into()];
            let types = self.lock()?.types.clone();
            flags.extend(local::listing_name_flags(request, &types));
            flags.extend(
                local::smb_filter_rules(
                    models::option_filter_rules(&request.options),
                    request,
                    &types,
                )
                .into_iter()
                .map(|s| format!("--filter={s}")),
            );
            let mut entries = self.list_raw(&request.source, flags.clone(), Some(cancel), false)?;
            selection_listing_limit(entries.len())?;
            if request.mode == "sync" {
                let destination = self.list_raw(&request.destination, flags, Some(cancel), true)?;
                selection_listing_limit(destination.len())?;
                entries.extend(destination);
            }
            rules = models::exact_filter_rules(request, &entries)?;
        }
        rules = local::smb_filter_rules(rules, request, &self.lock()?.types);
        if rules.is_empty() {
            return Ok(None);
        }
        let file = self.filters.join(format!("{id}.filter"));
        storage::atomic_data(&file, format!("{}\n", rules.join("\n")).as_bytes())?;
        Ok(Some(file))
    }
    fn worker(self: &Arc<Self>, id: &str, raw: Value, control: Arc<Control>) {
        let meter = Arc::new(Mutex::new(Throughput::default()));
        let report_slot: Arc<Mutex<Option<Arc<Mutex<Report>>>>> = Arc::new(Mutex::new(None));
        let log_slot: Arc<Mutex<Option<Arc<Mutex<crate::logging::Log>>>>> =
            Arc::new(Mutex::new(None));
        let filter_slot = Mutex::new(None::<PathBuf>);
        let outcome = (|| -> Result<i32> {
            let request = TransferRequest::parse(&raw)?;
            models::validate_pair(&request)?;
            self.endpoints(
                &[&request.source, &request.destination],
                Some(&control.stop),
            )?;
            let report = Arc::new(Mutex::new(Report::new(&self.logs, id)?));
            self.active_reports
                .lock()
                .map_err(|_| "報告無法開啟。")?
                .insert(id.to_owned(), report.clone());
            let log = Arc::new(Mutex::new(crate::logging::Log::new(&self.logs, id)?));
            self.active_logs
                .lock()
                .map_err(|_| "工作記錄無法開啟。")?
                .insert(id.to_owned(), log.clone());
            *report_slot.lock().map_err(|_| "報告無法開啟。")? = Some(report.clone());
            *log_slot.lock().map_err(|_| "記錄無法開啟。")? = Some(log.clone());
            if !request.selection.is_empty() {
                let flags = local::listing_name_flags(&request, &self.lock()?.types);
                let entries = self.list_raw(&request.source, flags, Some(&control.stop), false)?;
                for selection in &request.selection {
                    if !entries.iter().any(|e| {
                        e["Name"]
                            .as_str()
                            .is_some_and(|n| n.nfc().eq(selection.name.nfc()))
                            && (e["IsDir"] == true) == selection.is_dir
                    }) {
                        return Err("選取的來源項目已不存在或類型已改變，請重新整理。".into());
                    }
                }
            }
            let filter = self.write_filter(id, &request, &control.stop)?;
            *filter_slot.lock().map_err(|_| "篩選檔無法開啟。")? = filter.clone();
            let mut original = request.arguments(filter.as_deref())?;
            if let Some(i) = original.iter().position(|s| s == "--") {
                original.insert(i, "--combined=-".into());
            }
            original = local::smb_arguments(original, &self.lock()?.types);
            let settings = self.settings()?;
            let full = settings["retryScope"] == "full";
            let scope = if full { "full" } else { "failed" };
            let mut arguments = if full {
                original.clone()
            } else {
                retry::single_pass(&original)
            };
            let c = self.context(&arguments)?;
            let mut command = vec![c.binary.to_string_lossy().to_string()];
            command.extend(c.arguments);
            command.extend(arguments.clone());
            self.mutate_job(id, |j| {
                j["command"] = json!(local::display_command(&command))
            })?;
            let version = self.lock()?.environment["version"]
                .as_str()
                .map(str::to_owned);
            let window = original
                .iter()
                .find_map(|arg| arg.strip_prefix("--modify-window="));
            let local_pair =
                request.source.remote.is_none() && request.destination.remote.is_none();
            let copy_policy =
                (cfg!(target_os = "macos") && local_pair).then_some("streaming-no-clone");
            let name_policy = (cfg!(any(target_os = "macos", target_os = "linux")) && local_pair)
                .then_some("literal-unix-local-names");
            report
                .lock()
                .map_err(|_| "報告無法開啟。")?
                .configuration_details(
                    &raw,
                    version.as_deref(),
                    window,
                    copy_policy,
                    Some(scope),
                    name_policy,
                )?;
            if let Some(message) = local::precision_message(&request) {
                self.app_log(id, &log, &message)?;
            }
            if copy_policy.is_some() {
                self.app_log(id,&log,"macOS 本機互傳改用一般串流複製，避免繼承來源檔案的鎖定屬性；暫存檔驗證與完成後改名仍照常執行。")?;
            }
            self.app_log(
                id,
                &log,
                if request.dry_run {
                    "開始預演。"
                } else {
                    "開始傳輸。"
                },
            )?;
            meter.lock().map_err(|_| "進度無法讀取。")?.start();
            let limit = request.options["retries"].as_u64().unwrap_or(3).max(1) as usize;
            let mut attempt = 1;
            let mut scoped = false;
            let mut deferred = false;
            let mut first_failure = 0;
            let mut outstanding: Vec<Failure> = vec![];
            let mut base = Value::Null;
            let mut carried = 0usize;
            let final_exit = loop {
                if control.cancel.load(Ordering::Acquire) {
                    return Ok(130);
                }
                report
                    .lock()
                    .map_err(|_| "報告無法讀取。")?
                    .begin(attempt, limit);
                let report_callback = report.clone();
                let log_callback = log.clone();
                let engine = self.clone();
                let job_id = id.to_owned();
                let meter_callback = meter.clone();
                let base_callback = base.clone();
                let latest_callback = Arc::new(Mutex::new(Value::Null));
                let latest_out = latest_callback.clone();
                let control_callback = control.clone();
                let handler: process::LineHandler = Arc::new(move |line, stderr, terminated| {
                    if !stderr {
                        return report_callback
                            .lock()
                            .map_err(|_| "報告無法讀取。")?
                            .comparison_line(line, terminated)
                            .map_err(|error| {
                                engine.output_failure(
                                    &job_id,
                                    &control_callback,
                                    format!("無法完整保存逐檔紀錄：{error}"),
                                )
                            });
                    }
                    if line.trim().is_empty() {
                        return Ok(());
                    }
                    let parsed = serde_json::from_str::<Value>(line)
                        .ok()
                        .filter(Value::is_object);
                    let original_json = parsed.is_some();
                    let raw=parsed.unwrap_or_else(||json!({"time":now(),"level":"info","msg":line.graphemes(true).take(16000).collect::<String>(),"rawOutput":true}));
                    let encoded = if original_json {
                        line.to_owned()
                    } else {
                        serde_json::to_string(&raw).map_err(|e| e.to_string())?
                    };
                    log_callback
                        .lock()
                        .map_err(|_| "工作記錄無法讀取。")?
                        .append(&encoded)
                        .map_err(|error| {
                            engine.output_failure(
                                &job_id,
                                &control_callback,
                                format!("無法儲存記錄：{error}"),
                            )
                        })?;
                    let summary = {
                        let mut report = report_callback.lock().map_err(|_| "報告無法讀取。")?;
                        report.consume(&raw, request.dry_run).map_err(|error| {
                            engine.output_failure(
                                &job_id,
                                &control_callback,
                                format!("無法完整保存逐檔紀錄：{error}"),
                            )
                        })?;
                        if raw.get("stats").is_some() {
                            report.poll(false).map_err(|error| {
                                engine.output_failure(
                                    &job_id,
                                    &control_callback,
                                    format!("無法完整保存逐檔紀錄：{error}"),
                                )
                            })?;
                        }
                        report.summary()
                    };
                    if raw["stats"].is_object() {
                        let accumulated = retry::accumulate(&raw["stats"], &base_callback, carried);
                        *latest_out.lock().map_err(|_| "進度無法讀取。")? = accumulated.clone();
                        let previous = {
                            let state = engine.lock()?;
                            state
                                .jobs
                                .iter()
                                .find(|job| job["id"] == job_id)
                                .map(|job| job["stats"].clone())
                                .unwrap_or_else(stats::empty)
                        };
                        let statistics = meter_callback
                            .lock()
                            .map_err(|_| "進度無法讀取。")?
                            .update(&accumulated, &previous);
                        engine.mutate_job(&job_id, |job| {
                            job["stats"] = statistics;
                            if stats::number(&summary["eventCount"])
                                >= stats::number(&job["report"]["eventCount"])
                            {
                                job["report"] = summary;
                            }
                            if let Some(error) = accumulated["lastError"]
                                .as_str()
                                .filter(|error| !error.is_empty())
                            {
                                job["error"] =
                                    json!(error.graphemes(true).take(16000).collect::<String>());
                            }
                        })?;
                    } else {
                        let message = raw["msg"]
                            .as_str()
                            .or(raw["error"].as_str())
                            .unwrap_or("rclone 記錄")
                            .graphemes(true)
                            .take(16000)
                            .collect::<String>();
                        let level = raw["level"].as_str().unwrap_or("info");
                        let normalized = level.to_lowercase();
                        let mut entry = json!({"time":raw["time"].as_str().map(str::to_owned).unwrap_or_else(now),"level":level,"message":message});
                        if let Some(object) = raw["object"].as_str() {
                            entry["object"] =
                                json!(object.graphemes(true).take(16000).collect::<String>());
                        }
                        if raw["size"].is_number() || raw["size"].is_boolean() {
                            entry["size"] = raw["size"].clone();
                        }
                        engine.mutate_job(&job_id, |job| {
                            if let Some(logs) = job["logs"].as_array_mut() {
                                logs.push(entry);
                                if logs.len() > 250 {
                                    logs.drain(..logs.len() - 250);
                                }
                            }
                            if ["error", "fatal"].contains(&normalized.as_str()) {
                                job["error"] = json!(message);
                            }
                            if (raw.get("stats").is_some()
                                || ["error", "fatal", "alert", "emergency"]
                                    .contains(&normalized.as_str()))
                                && stats::number(&summary["eventCount"])
                                    >= stats::number(&job["report"]["eventCount"])
                            {
                                job["report"] = summary;
                            }
                        })?;
                    }
                    engine.notify(&job_id, false);
                    Ok(())
                });
                let context = self.context(&arguments)?;
                let signal_engine = self.clone();
                let signal_id = id.to_owned();
                let observer: process::StopHandler = Arc::new(move |signal| {
                    let _=signal_engine.mutate_job(&signal_id,|job|{if !job["cancellation"].is_object(){job["cancellation"]=json!({"requestedAt":now(),"forced":false,"processExited":false});}job["cancellation"]["lastSignal"]=json!(match signal{9=>"SIGKILL",15=>"SIGTERM",_=>"SIGINT"});job["cancellation"]["forced"]=json!(signal!=2);if signal!=2{job["error"]=json!("rclone 未回應停止要求，已強制終止。請檢查目標端是否留有未完成檔案或上傳資料。");}});
                    signal_engine.notify(&signal_id, true);
                });
                let output = process::run_with_stop_observer(
                    &context,
                    &arguments,
                    1024 * 1024,
                    None,
                    Some(&control.stop),
                    Some(handler),
                    observer,
                )?;
                if let Some(failure) = control.failure.lock().ok().and_then(|f| f.clone()) {
                    return Err(failure);
                }
                if control.cancel.load(Ordering::Acquire) {
                    self.mutate_job(id,|j|{j["cancellation"]["forced"]=json!(output.forced);j["cancellation"]["lastSignal"]=json!(match output.last_signal{Some(9)=>"SIGKILL",Some(15)=>"SIGTERM",_=>"SIGINT"});if output.forced{j["error"]=json!("rclone 未回應停止要求，已強制終止。請檢查目標端是否留有未完成檔案或上傳資料。");}})?;
                }
                let exit = output.exit_code;
                let latest = latest_callback
                    .lock()
                    .map_err(|_| "進度無法讀取。")?
                    .clone();
                if exit != 0 && first_failure == 0 {
                    first_failure = exit;
                }
                let (failures, overflow) =
                    report.lock().map_err(|_| "報告無法讀取。")?.take_failures();
                if full {
                    break exit;
                }
                let pass_errors = stats::number(&latest["errors"]) - carried as f64;
                let decision = retry::decide(retry::Pass {
                    failures: &failures,
                    overflow,
                    exit,
                    cancelled: control.cancel.load(Ordering::Acquire),
                    attempt,
                    limit,
                    request: &request,
                    fatal: latest["fatalError"] == true,
                    retryable: if pass_errors > 0. {
                        latest["retryError"].as_bool()
                    } else {
                        None
                    },
                    last_scoped: scoped,
                    deferred_earlier: deferred,
                    outstanding: outstanding.len(),
                });
                if scoped {
                    outstanding.extend(decision.permanent);
                } else {
                    outstanding = decision.permanent;
                }
                deferred = if scoped {
                    deferred || decision.deletion_deferred
                } else {
                    decision.deletion_deferred
                };
                let note = match decision.decision {
                    Decision::Finish(note) => {
                        if let Some(note) = note {
                            self.app_log(id, &log, &note)?;
                            report
                                .lock()
                                .map_err(|_| "報告無法讀取。")?
                                .retry_note(&note, attempt, None)?;
                        }
                        break if exit != 0 {
                            exit
                        } else if outstanding.is_empty() {
                            0
                        } else {
                            first_failure
                        };
                    }
                    Decision::Files(paths) => {
                        attempt += 1;
                        let path = self.filters.join(format!("{id}.retry"));
                        storage::atomic_data(&path, format!("{}\n", paths.join("\n")).as_bytes())?;
                        arguments = retry::scoped(&original, &path.to_string_lossy());
                        base = latest.clone();
                        carried = outstanding.len();
                        scoped = true;
                        let note = format!(
                            "第 {attempt} 輪：只重試上一輪失敗的 {} 個檔案，不重掃其他檔案。",
                            paths.len()
                        );
                        report.lock().map_err(|_| "報告無法讀取。")?.retry_note(
                            &note,
                            attempt,
                            Some(paths.len()),
                        )?;
                        note
                    }
                    Decision::Full(reason) => {
                        attempt += 1;
                        arguments = retry::single_pass(&original);
                        base = latest.clone();
                        carried = 0;
                        scoped = false;
                        let note = format!("第 {attempt} 輪：{reason}");
                        report
                            .lock()
                            .map_err(|_| "報告無法讀取。")?
                            .retry_note(&note, attempt, None)?;
                        note
                    }
                };
                self.app_log(id, &log, &note)?;
                if let Some(seconds) = request.options["retrySleep"]
                    .as_str()
                    .and_then(retry::seconds)
                {
                    let until = Instant::now() + Duration::from_secs_f64(seconds.min(3600.));
                    while Instant::now() < until {
                        if control.cancel.load(Ordering::Acquire) {
                            return Ok(130);
                        }
                        thread::sleep(Duration::from_millis(50));
                    }
                }
            };
            if final_exit != 0
                && cfg!(any(target_os = "macos", target_os = "linux"))
                && request.mode == "sync"
                && request.source.remote.is_none()
                && request.destination.remote.is_none()
                && !control.stop.load(Ordering::Acquire)
            {
                let cleanup = (|| -> Result<()> {
                    let mut flags = local::listing_name_flags(&request, &self.lock()?.types);
                    flags.extend([
                        "--recursive".into(),
                        "--dirs-only".into(),
                        "--no-modtime".into(),
                    ]);
                    if let Some(filter) = &filter {
                        flags.push(format!("--filter-from={}", filter.display()));
                    }
                    if let Some(depth) = request.options["maxDepth"].as_i64().filter(|n| *n >= 0) {
                        flags.push(format!("--max-depth={depth}"));
                    }
                    if request.options["oneFileSystem"] == true {
                        flags.push("--one-file-system".into());
                    }
                    let maximum = request.options["maxDelete"].as_i64().unwrap_or(-1);
                    let deleted = {
                        let s = self.lock()?;
                        s.jobs
                            .iter()
                            .find(|j| j["id"] == id)
                            .map(|j| stats::number(&j["stats"]["deletes"]) as i64)
                            .unwrap_or(0)
                    };
                    let remaining = if maximum < 0 {
                        -1
                    } else {
                        (maximum - deleted).max(0)
                    };
                    if remaining != 0 {
                        let candidates = self
                            .list_raw(&request.destination, flags, Some(&control.stop), false)?
                            .iter()
                            .map(|row| {
                                if row["IsDir"] != true {
                                    return Err("空資料夾清理清單格式不正確。".into());
                                }
                                row["Path"]
                                    .as_str()
                                    .map(str::to_owned)
                                    .ok_or_else(|| "空資料夾清理清單格式不正確。".into())
                            })
                            .collect::<Result<Vec<String>>>()?;
                        if control.stop.load(Ordering::Acquire) {
                            return Ok(());
                        }
                        self.app_log(id, &log, "正在清理來源已不存在的空資料夾。")?;
                        let removed = local::prune_empty_directories(
                            Path::new(&request.source.path),
                            Path::new(&request.destination.path),
                            &candidates,
                            remaining,
                            request.dry_run,
                            &control.stop,
                            &mut |path, dry| {
                                report
                                    .lock()
                                    .map_err(|_| "報告無法讀取。")?
                                    .directory_deleted(path, dry)
                            },
                        )?;
                        self.app_log(
                            id,
                            &log,
                            &if request.dry_run {
                                format!("預演：會清理 {removed} 個來源不存在的空資料夾。")
                            } else {
                                format!("已清理 {removed} 個來源不存在的空資料夾。")
                            },
                        )?;
                    }
                    Ok(())
                })();
                if let Err(error) = cleanup {
                    self.app_log_level(
                        id,
                        &log,
                        "warning",
                        &format!("空資料夾清理未完成：{error}"),
                    )?;
                }
            }
            if !outstanding.is_empty() {
                let message = if outstanding
                    .iter()
                    .all(|f| f.message.starts_with("error reading source directory:"))
                {
                    "來源資料夾無法讀取，該部分尚未同步。請查看逐檔紀錄。".into()
                } else {
                    outstanding[0].message.clone()
                };
                self.mutate_job(id, |j| j["error"] = json!(message))?;
            }
            Ok(final_exit)
        })();
        let cancelled = control.cancel.load(Ordering::Acquire);
        let failure = control.failure.lock().ok().and_then(|f| f.clone());
        let closing = self.lock().map(|s| s.closing).unwrap_or(false);
        let mut error = None;
        let has_exit = outcome.is_ok();
        let code = match outcome {
            Ok(c) => c,
            Err(e) => {
                if !cancelled {
                    error = Some(failure.clone().unwrap_or(e));
                }
                -1
            }
        };
        if let Some(failure) = failure {
            error = Some(failure);
        }
        if let Ok(slot) = report_slot.lock() {
            if let Some(report) = slot.as_ref() {
                match report.lock() {
                    Ok(mut report) => {
                        if let Err(e) = report.finish() {
                            error = Some(format!("無法完整保存逐檔紀錄：{e}"));
                        }
                        let summary = report.summary();
                        let _ = self.mutate_job(id, |j| j["report"] = summary);
                    }
                    Err(_) => {
                        error = Some("無法完整保存逐檔紀錄。".into());
                    }
                }
            }
        }
        let success = code == 0 && error.is_none() && !cancelled;
        let _ = self.mutate_job(id, |j| {
            j["status"] = json!(if cancelled {
                if closing { "interrupted" } else { "cancelled" }
            } else if success {
                "completed"
            } else {
                "failed"
            });
            j["endedAt"] = json!(now());
            if has_exit {
                j["exitCode"] = json!(code);
            }
            if let Ok(m) = meter.lock() {
                j["stats"] = m.finish(&j["stats"], success);
            }
            if success {
                if let Some(o) = j.as_object_mut() {
                    o.remove("error");
                }
            } else if let Some(e) = &error {
                j["error"] = json!(e);
            } else if !cancelled && j["error"].is_null() {
                j["error"] = json!(format!("rclone 結束代碼：{code}。請查看記錄。"));
            }
            if cancelled {
                j["cancellation"]["processExited"] = json!(true);
                if closing && j["cancellation"]["forced"] != true {
                    j["error"] = json!("程式關閉，工作已停止。");
                }
            }
        });
        let finished_log = (|| -> Result<()> {
            let slot = log_slot.lock().map_err(|_| "工作記錄無法讀取。")?;
            if let Some(log) = slot.as_ref() {
                let (message, level) = {
                    let state = self.lock()?;
                    let job = state
                        .jobs
                        .iter()
                        .find(|j| j["id"] == id)
                        .ok_or("找不到這項工作。")?;
                    let message = if job["status"] == "completed" {
                        if job["request"]["dryRun"] == true {
                            "預演完成，檔案未變更。"
                        } else {
                            "工作完成。"
                        }
                    } else if job["status"] == "cancelled" {
                        "工作已停止。"
                    } else {
                        job["error"].as_str().unwrap_or("工作已結束。")
                    };
                    (
                        message.to_owned(),
                        if job["status"] == "failed" {
                            "error"
                        } else {
                            "info"
                        },
                    )
                };
                self.app_log_level(id, log, level, &message)?;
                log.lock().map_err(|_| "工作記錄無法讀取。")?.flush()?;
            }
            Ok(())
        })();
        if let Err(error) = finished_log {
            let _ = self.mutate_job(id, |job| {
                job["error"] = json!(format!("記錄無法完整保存：{error}"));
                if job["status"] == "completed" {
                    job["status"] = json!("failed");
                }
            });
        }
        if let Ok(slot) = filter_slot.lock() {
            if let Some(path) = slot.as_ref() {
                let _ = fs::remove_file(path);
            }
        }
        let _ = fs::remove_file(self.filters.join(format!("{id}.retry")));
        if let Err(e) = self.persist() {
            let _ = self.mutate_job(id, |j| {
                if j["status"] == "completed" {
                    j["status"] = json!("failed");
                }
                j["error"] = json!(format!("工作狀態無法儲存：{e}"));
            });
        }
        if let Ok(mut s) = self.lock() {
            if let Some(job) = s.jobs.iter().find(|j| j["id"] == id) {
                if let Ok(mut finished) = control.finished.lock() {
                    *finished = Some((
                        job["status"].as_str().unwrap_or("").to_owned(),
                        job["cancellation"]["forced"] == true,
                    ));
                }
            }
            s.controls.remove(id);
            self.job_changed.notify_all();
        }
        if let Ok(mut r) = self.active_reports.lock() {
            r.remove(id);
        }
        if let Ok(mut l) = self.active_logs.lock() {
            l.remove(id);
        }
        self.notify(id, true);
        self.pump();
    }
    fn output_failure(&self, id: &str, control: &Control, message: String) -> String {
        let message = {
            match control.failure.lock() {
                Ok(mut failure) => {
                    if failure.is_none() {
                        *failure = Some(message);
                    }
                    failure.clone().unwrap_or_default()
                }
                Err(_) => message,
            }
        };
        control.stop.store(true, Ordering::Release);
        let _ = self.mutate_job(id, |job| {
            if !terminal(job) {
                job["status"] = json!("cancelling");
            }
        });
        message
    }
    fn app_log(
        &self,
        id: &str,
        log: &Arc<Mutex<crate::logging::Log>>,
        message: &str,
    ) -> Result<()> {
        self.app_log_level(id, log, "info", message)
    }
    fn app_log_level(
        &self,
        id: &str,
        log: &Arc<Mutex<crate::logging::Log>>,
        level: &str,
        message: &str,
    ) -> Result<()> {
        let time = now();
        self.mutate_job(id, |job| {
            if let Some(logs) = job["logs"].as_array_mut() {
                logs.push(json!({"time":time,"level":level,"message":message}));
                if logs.len() > 250 {
                    logs.remove(0);
                }
            }
        })?;
        let raw = json!({"time":time,"level":level,"msg":message,"app":true});
        log.lock()
            .map_err(|_| "工作記錄無法讀取。")?
            .append(&serde_json::to_string(&raw).map_err(|e| e.to_string())?)
    }
    fn mark_cancel(state: &mut State, id: &str) -> Result<bool> {
        let control = state.controls.get(id).cloned();
        let closing = state.closing;
        let job = state
            .jobs
            .iter_mut()
            .find(|j| j["id"] == id)
            .ok_or("找不到這項工作。")?;
        if terminal(job) {
            return Ok(false);
        }
        if job["status"] == "queued" {
            job["status"] = json!(if closing { "interrupted" } else { "cancelled" });
            job["endedAt"] = json!(now());
            job["stats"] = stats::finished(&job["stats"], false);
            if closing {
                job["error"] = json!("程式關閉，排隊工作未執行。");
            }
            if let Some(control) = control {
                control.cancel.store(true, Ordering::Release);
                control.stop.store(true, Ordering::Release);
                if let Ok(mut finished) = control.finished.lock() {
                    *finished = Some((job["status"].as_str().unwrap_or("").to_owned(), false));
                }
            }
            state.controls.remove(id);
            return Ok(false);
        }
        if let Some(control) = control {
            control.cancel.store(true, Ordering::Release);
            control.stop.store(true, Ordering::Release);
            job["status"] = json!("cancelling");
            if !job["cancellation"].is_object() {
                job["cancellation"] =
                    json!({"requestedAt":now(),"forced":false,"processExited":false});
            }
            return Ok(true);
        }
        Ok(false)
    }
    fn cancel_job(&self, id: &str) -> Result<Value> {
        let running = {
            let mut state = self.lock()?;
            Self::mark_cancel(&mut state, id)?
        };
        self.notify(id, true);
        if running {
            let until = Instant::now() + Duration::from_secs(15);
            let mut state = self.lock()?;
            while state.controls.contains_key(id) {
                let wait = until.saturating_duration_since(Instant::now());
                if wait.is_zero() {
                    drop(state);
                    self.persist()?;
                    return Err("rclone 尚未停止，已保留此工作。請查看工作狀態。".into());
                }
                state = self
                    .job_changed
                    .wait_timeout(state, wait)
                    .map_err(|_| "程式狀態無法讀取。")?
                    .0;
            }
        }
        self.persist()?;
        Ok(Value::Null)
    }
    fn save_settings(self: &Arc<Self>, patch: &Value) -> Result<Value> {
        let _gate = self.settings_gate.lock().map_err(|_| "無法儲存設定。")?;
        let previous = self.settings()?;
        if let Some(revision) = patch.get("settingsRevision") {
            let valid = revision
                .as_f64()
                .filter(|n| {
                    n.is_finite() && n.fract() == 0. && *n >= 0. && *n <= 9_007_199_254_740_990.
                })
                .ok_or("設定版本 必須介於 0 與 9007199254740990。")?;
            if valid != stats::number(&previous["settingsRevision"]) {
                return Err("設定已在其他操作中更新，請重新整理後再試。".into());
            }
        }
        let mut changed = models::validate_settings(patch, &previous)?;
        let connection = [
            "rclonePath",
            "rcloneDirectory",
            "configPath",
            "proxyMode",
            "httpProxy",
            "httpsProxy",
            "noProxy",
            "defaultRcloneOptions",
            "networkOptions",
        ]
        .iter()
        .any(|k| previous[*k] != changed[*k]);
        if let Some(config) = changed["configPath"].as_str().filter(|p| !p.is_empty()) {
            if !Path::new(config).is_file() {
                return Err("指定的設定檔不存在或不是檔案。".into());
            }
        }
        let mut switch = SettingsChange {
            engine: self.clone(),
            active: false,
            reserved: false,
        };
        {
            let mut state = self.lock()?;
            if state.closing {
                return Err("程式正在關閉。".into());
            }
            if connection {
                if state.configuring || self.tools.has_active() {
                    return Err("請先結束帳號設定或播放，再變更 rclone 位置與連線設定。".into());
                }
                if state.maintenance || state.jobs.iter().any(|j| !terminal(j)) {
                    return Err("請等候傳輸或更新結束，再切換 rclone、設定檔或網路設定。".into());
                }
                state.configuration_changing = true;
                switch.active = true;
            }
        }
        if connection {
            self.cancel_listings();
            let until = Instant::now() + Duration::from_secs(30);
            loop {
                let state = self.lock()?;
                if state.operations == 0 {
                    break;
                }
                if state.closing {
                    return Err("程式正在關閉。".into());
                }
                if Instant::now() >= until {
                    return Err("目前的目錄讀取尚未結束。請稍後再切換位置。".into());
                }
                drop(state);
                thread::sleep(Duration::from_millis(10));
            }
            let mut state = self.lock()?;
            if state.jobs.iter().any(|j| !terminal(j)) {
                return Err("傳輸已開始，請等候工作結束再切換位置。".into());
            }
            state.operations += 1;
            switch.reserved = true;
        }
        changed["settingsRevision"] = json!(previous["settingsRevision"].as_u64().unwrap_or(0) + 1);
        {
            let _write = self.write_lock.lock().map_err(|_| "無法儲存設定。")?;
            storage::atomic_json(&self.state_dir.join("settings.json"), &changed)?;
            let mut state = self.lock()?;
            if connection {
                if previous["configPath"] != changed["configPath"] {
                    state.password = None;
                }
                state.environment = blank_environment(changed["configPath"].as_str().unwrap_or(""));
            }
            state.settings = changed.clone();
            state.environment["settingsRevision"] = changed["settingsRevision"].clone();
        }
        if connection {
            self.detect()
        } else {
            Ok(self.lock()?.environment.clone())
        }
    }
    fn tasks_save(&self, name: &str, raw: &Value, id: Option<&str>) -> Result<Value> {
        let name = name.trim_matches(|c: char| c.is_whitespace() && c != '\n' && c != '\r');
        if name.is_empty()
            || unicode_segmentation::UnicodeSegmentation::graphemes(name, true).count() > 200
        {
            return Err("請輸入 1 至 200 字的作業名稱。".into());
        }
        models::text(&json!(name), "作業名稱", 800)?;
        let request = self.normalize(raw)?;
        let _write = self.write_lock.lock().map_err(|_| "無法保存程式狀態。")?;
        let mut tasks = self.lock()?.tasks.clone();
        if id.is_some_and(|id| !tasks.iter().any(|t| t["id"] == id)) {
            return Err("找不到要更新的作業。".into());
        }
        if id.is_none() && tasks.len() >= 1000 {
            return Err("最多可儲存 1,000 個作業。".into());
        }
        let id = id
            .map(str::to_owned)
            .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
        let created = tasks
            .iter()
            .find(|t| t["id"] == id)
            .map(|t| t["createdAt"].clone())
            .unwrap_or_else(|| json!(now()));
        let task = json!({"id":id,"name":name,"request":request.value(),"createdAt":created,"updatedAt":now()});
        tasks.retain(|t| t["id"] != id);
        tasks.push(task.clone());
        self.persist_locked(Some(&tasks))?;
        self.lock()?.tasks = tasks;
        Ok(task)
    }
    fn tasks_import(&self, raw: &Value) -> Result<Value> {
        let parsed = if let Some(text) = raw.as_str() {
            if text.len() > 8 * 1024 * 1024 {
                return Err("作業檔案過大。".into());
            }
            storage::decode_json_bytes(text.as_bytes())
                .map_err(|_| "The data couldn’t be read because it isn’t in the correct format.")?
        } else {
            raw.clone()
        };
        let incoming = parsed
            .as_array()
            .or(parsed["tasks"].as_array())
            .ok_or("請匯入有效的作業 JSON，最多 1,000 筆。")?;
        if incoming.len() > 1000 {
            return Err("請匯入有效的作業 JSON，最多 1,000 筆。".into());
        }
        let mut additions = incoming
            .iter()
            .map(crate::history::task)
            .collect::<Result<Vec<_>>>()?;
        let updated = now();
        for task in &mut additions {
            task["id"] = json!(uuid::Uuid::new_v4().to_string());
            task["updatedAt"] = json!(updated);
        }
        let _write = self.write_lock.lock().map_err(|_| "無法保存程式狀態。")?;
        let mut tasks = self.lock()?.tasks.clone();
        if tasks.len() + additions.len() > 1000 {
            return Err("儲存的作業總數不能超過 1,000 筆。".into());
        }
        tasks.extend(additions);
        self.persist_locked(Some(&tasks))?;
        let result = crate::history::sorted_tasks(&tasks);
        self.lock()?.tasks = tasks;
        Ok(json!(result))
    }
    fn clear_jobs(&self, request: &Value) -> Result<Value> {
        let raw = request.as_object().ok_or("工作清理設定格式不正確。")?;
        let invalid = "無法清除紀錄，傳輸清單或清除設定已失效。請重新整理後再試。";
        let values = raw
            .get("ids")
            .and_then(Value::as_array)
            .filter(|a| {
                a.len() <= 10000 && a.iter().all(|v| v.as_str().is_some_and(crate::valid_id))
            })
            .ok_or(invalid)?;
        let mode = raw
            .get("mode")
            .and_then(Value::as_str)
            .filter(|s| ["finished", "stop-and-clear"].contains(s))
            .ok_or(invalid)?;
        if raw
            .keys()
            .any(|key| !["ids", "mode"].contains(&key.as_str()))
        {
            return Err(invalid.into());
        }
        let mut seen = BTreeSet::new();
        let ids = values
            .iter()
            .filter_map(|v| {
                let id = v.as_str().unwrap().to_lowercase();
                if seen.insert(id.clone()) {
                    Some(id)
                } else {
                    None
                }
            })
            .collect::<Vec<_>>();
        let (mut stopped, mut wait_ids) = (Vec::new(), BTreeSet::new());
        {
            let mut state = self.lock()?;
            for id in &ids {
                let Some(job) = state.jobs.iter().find(|j| j["id"] == *id) else {
                    continue;
                };
                if !terminal(job) && mode == "stop-and-clear" {
                    let control = state.controls.get(id).cloned();
                    Self::mark_cancel(&mut state, id)?;
                    stopped.push((id.clone(), control));
                    wait_ids.insert(id.clone());
                } else if terminal(job) && state.controls.contains_key(id) {
                    wait_ids.insert(id.clone());
                }
            }
        }
        for (id, _) in &stopped {
            self.notify(id, true);
        }
        let until = Instant::now() + Duration::from_secs(15);
        let mut state = self.lock()?;
        while wait_ids.iter().any(|id| state.controls.contains_key(id)) {
            let wait = until.saturating_duration_since(Instant::now());
            if wait.is_zero() {
                break;
            }
            state = self
                .job_changed
                .wait_timeout(state, wait)
                .map_err(|_| "程式狀態無法讀取。")?
                .0;
        }
        drop(state);
        let result = {
            let _write = self.write_lock.lock().map_err(|_| "無法保存程式狀態。")?;
            let mut state = self.lock()?;
            let retained = ids
                .iter()
                .filter(|id| {
                    state
                        .jobs
                        .iter()
                        .find(|j| j["id"] == **id)
                        .is_some_and(|job| !terminal(job) || state.controls.contains_key(*id))
                })
                .cloned()
                .collect::<Vec<_>>();
            let retained_set = retained.iter().cloned().collect::<BTreeSet<_>>();
            let removed = ids
                .iter()
                .filter(|id| !retained_set.contains(id.as_str()))
                .cloned()
                .collect::<Vec<_>>();
            let removed_set = removed.iter().cloned().collect::<BTreeSet<_>>();
            let mut stopped_ids = vec![];
            let mut forced = vec![];
            for (id, control) in &stopped {
                let snapshot = control
                    .as_ref()
                    .and_then(|c| c.finished.lock().ok().and_then(|v| v.clone()));
                let job = state.jobs.iter().find(|j| j["id"] == *id);
                let ended = snapshot.as_ref().is_some_and(|(status, _)| {
                    ["completed", "failed", "cancelled", "interrupted"].contains(&status.as_str())
                }) || job.is_some_and(terminal);
                if ended {
                    stopped_ids.push(id.clone());
                }
                if snapshot.as_ref().is_some_and(|(_, forced)| *forced)
                    || job.is_some_and(|j| j["cancellation"]["forced"] == true)
                {
                    forced.push(id.clone());
                }
            }
            let kept = state
                .jobs
                .iter()
                .filter(|job| !removed_set.contains(job["id"].as_str().unwrap_or("")))
                .cloned()
                .collect::<Vec<_>>();
            storage::atomic_json(&self.state_dir.join("jobs.json"), &json!(kept))?;
            state.jobs = kept;
            for id in &removed {
                state.scheduled.remove(id);
            }
            json!({"removedIds":removed,"retainedIds":retained,"stoppedIds":stopped_ids,"forcedStopIds":forced})
        };
        for id in result["removedIds"].as_array().unwrap() {
            self.remove_logs(id.as_str().unwrap());
        }
        Ok(result)
    }
    fn remove_logs(&self, id: &str) {
        if !crate::valid_id(id) {
            return;
        }
        for suffix in [
            ".jsonl",
            ".jsonl.1",
            ".jsonl.2",
            ".jsonl.3",
            ".jsonl.4",
            ".export.jsonl",
        ] {
            let _ = fs::remove_file(self.logs.join(format!("{id}{suffix}")));
        }
        let _ = report::remove(&self.logs, id);
    }
    fn state_snapshot(&self) -> Result<Value> {
        let state = self.lock()?;
        let (mut active, mut failed, mut unfinished) = (0, 0, 0);
        for job in &state.jobs {
            if !terminal(job)
                || job["id"]
                    .as_str()
                    .is_some_and(|id| state.controls.contains_key(id))
            {
                active += 1;
            } else if job["status"] == "failed" {
                failed += 1;
            } else if job["status"] != "completed" {
                unfinished += 1;
            }
        }
        Ok(
            json!({"activeJobs":active>0,"activeTools":self.tools.has_active(),"quit":{"activeJobCount":active,"failedJobCount":failed,"unfinishedJobCount":unfinished,"requiresConfirmation":active>0||failed>0||unfinished>0},"configuring":state.configuring||self.accounts.has_active(),"settings":state.settings,"resolvedLanguage":catalog::language(&state.settings)}),
        )
    }
    fn begin_maintenance(&self) -> Result<()> {
        let _gate = self
            .settings_gate
            .lock()
            .map_err(|_| "程式狀態無法讀取。")?;
        let mut s = self.lock()?;
        if s.closing
            || s.maintenance
            || s.configuring
            || s.operations > 0
            || s.jobs.iter().any(|j| !terminal(j))
            || self.accounts.has_active()
            || self.tools.has_active()
        {
            return Err("請等候目錄載入、工作與帳號設定結束，再繼續。".into());
        }
        s.maintenance = true;
        Ok(())
    }
    fn shutdown(&self) -> Result<Value> {
        if self.lock()?.configuring {
            return Err("請先關閉帳號設定視窗，再結束程式。".into());
        }
        self.tools.shutdown()?;
        self.cancel_listings();
        self.accounts.cancel_all()?;
        let ids = {
            let mut state = self.lock()?;
            state.closing = true;
            state.scheduled.clear();
            self.shutdown_cancel.store(true, Ordering::Release);
            let ids = state
                .jobs
                .iter()
                .filter(|j| !terminal(j))
                .filter_map(|j| j["id"].as_str().map(str::to_owned))
                .collect::<Vec<_>>();
            for id in &ids {
                Self::mark_cancel(&mut state, id)?;
            }
            ids
        };
        for id in ids {
            self.notify(&id, true);
        }
        let mut state = self.lock()?;
        while !state.controls.is_empty()
            || state.operations != 0
            || state.listings.values().any(|l| l.claimed && !l.finished)
        {
            state = self
                .job_changed
                .wait(state)
                .map_err(|_| "程式狀態無法讀取。")?;
        }
        state.password = None;
        drop(state);
        let _ = self.persist();
        Ok(json!(true))
    }
    pub fn language(&self) -> String {
        self.settings()
            .map(|s| catalog::language(&s))
            .unwrap_or_else(|_| "en".into())
    }
    fn flush_report(&self, id: &str) -> Result<()> {
        let writer = self
            .active_reports
            .lock()
            .map_err(|_| "報告無法讀取。")?
            .get(id)
            .cloned();
        if let Some(writer) = writer {
            writer.lock().map_err(|_| "報告無法讀取。")?.flush()?;
        }
        Ok(())
    }
    fn log_path(&self, id: &str) -> Result<PathBuf> {
        if !crate::valid_id(id) || !self.lock()?.jobs.iter().any(|j| j["id"] == id) {
            return Err("找不到這項工作的記錄。".into());
        }
        let writer = self
            .active_logs
            .lock()
            .map_err(|_| "工作記錄無法讀取。")?
            .get(id)
            .cloned();
        if let Some(writer) = writer {
            writer.lock().map_err(|_| "工作記錄無法讀取。")?.flush()?;
        }
        crate::logging::export(&self.logs, id)
    }
    pub fn invoke(self: &Arc<Self>, method: &str, args: Vec<Value>) -> Result<Value> {
        match method {
            "bootstrap" => self.bootstrap(),
            "environment" => {
                let _op = self.enter()?;
                self.detect()
            }
            "list" => self.list(&Endpoint::parse(arg(&args, 0))?, arg(&args, 1)),
            "cancelList" => self.cancel_listing(&text(&args, 0, "目錄讀取編號")?),
            "mkdir" | "rename" | "remove" | "size" => self.file_action(method, &args),
            "_normalizeTransfer" => Ok(self.normalize(arg(&args, 0))?.value()),
            "previewTransfer" => {
                let _op = self.enter()?;
                self.preview(&self.prepare(arg(&args, 0))?)
            }
            "startTransfer" => {
                let _op = self.enter()?;
                let r = self.prepare(arg(&args, 0))?;
                self.start(r)
            }
            "cancelJob" => self.cancel_job(&text(&args, 0, "工作編號")?),
            "retryJob" => {
                let id = text(&args, 0, "工作編號")?;
                let raw = {
                    let s = self.lock()?;
                    let job = s
                        .jobs
                        .iter()
                        .find(|j| j["id"] == id)
                        .ok_or("找不到工作。")?;
                    if !terminal(job) || s.controls.contains_key(&id) {
                        return Err("請等候工作停止，再重試。".into());
                    }
                    job["request"].clone()
                };
                let _op = self.enter()?;
                self.start(self.prepare(&raw)?)
            }
            "listJobs" => Ok(json!(
                self.lock()?.jobs.iter().rev().cloned().collect::<Vec<_>>()
            )),
            "clearFinishedJobs" => {
                let ids = self
                    .lock()?
                    .jobs
                    .iter()
                    .filter(|j| terminal(j))
                    .map(|j| j["id"].clone())
                    .collect::<Vec<_>>();
                self.clear_jobs(&json!({"ids":ids,"mode":"finished"}))?;
                Ok(Value::Null)
            }
            "clearJobs" => self.clear_jobs(arg(&args, 0)),
            "saveTask" => self.tasks_save(
                &text(&args, 0, "作業名稱")?,
                arg(&args, 1),
                args.get(2).and_then(Value::as_str),
            ),
            "deleteTask" => {
                let id = text(&args, 0, "作業編號")?;
                let _write = self.write_lock.lock().map_err(|_| "無法保存程式狀態。")?;
                let mut tasks = self.lock()?.tasks.clone();
                tasks.retain(|t| t["id"] != id);
                self.persist_locked(Some(&tasks))?;
                self.lock()?.tasks = tasks;
                Ok(Value::Null)
            }
            "listTasks" => Ok(json!(crate::history::sorted_tasks(&self.lock()?.tasks))),
            "exportTasks" => Ok(
                json!({"format":"rclone-browser-next-tasks","version":1,"tasks":crate::history::sorted_tasks(&self.lock()?.tasks)}),
            ),
            "importTasks" => self.tasks_import(arg(&args, 0)),
            "_captureTasks" => {
                let token = uuid::Uuid::new_v4().to_string();
                let mut bytes = serde_json::to_vec_pretty(&self.invoke("exportTasks", vec![])?)
                    .map_err(|e| e.to_string())?;
                bytes.push(b'\n');
                self.captured_tasks
                    .lock()
                    .map_err(|_| "無法準備匯出作業。")?
                    .insert(token.clone(), bytes);
                Ok(json!(token))
            }
            "_discardTaskExport" => {
                let token = text(&args, 0, "匯出編號")?;
                id_valid(&token)?;
                self.captured_tasks
                    .lock()
                    .map_err(|_| "無法準備匯出作業。")?
                    .remove(&token);
                Ok(Value::Null)
            }
            "_exportTasks" => {
                let path = PathBuf::from(text(&args, 0, "匯出位置")?);
                if let Some(token) = args.get(1).and_then(Value::as_str) {
                    id_valid(token)?;
                    let bytes = self
                        .captured_tasks
                        .lock()
                        .map_err(|_| "無法準備匯出作業。")?
                        .remove(token)
                        .ok_or("匯出作業已結束，請重新匯出。")?;
                    storage::atomic_data(&path, &bytes)?;
                } else {
                    storage::atomic_json(&path, &self.invoke("exportTasks", vec![])?)?;
                }
                Ok(json!(path.to_string_lossy()))
            }
            "_importTasks" => {
                let path = PathBuf::from(text(&args, 0, "作業檔案")?);
                if fs::metadata(&path).map_err(|e| e.to_string())?.len() > 8 * 1024 * 1024 {
                    return Err("作業檔案過大。".into());
                }
                let bytes = fs::read(path).map_err(|e| e.to_string())?;
                if bytes.len() > 8 * 1024 * 1024 {
                    return Err("作業檔案過大。".into());
                }
                let raw = storage::decode_json_bytes(&bytes)?;
                if !raw.is_object() && !raw.is_array() {
                    return Err(
                        "The data couldn’t be read because it isn’t in the correct format.".into(),
                    );
                }
                self.tasks_import(&raw)
            }
            "saveSettings" => self.save_settings(arg(&args, 0)),
            "unlockConfig" => {
                let password = arg(&args, 0)
                    .as_str()
                    .filter(|s| s.len() <= 32768 && !s.contains('\0'))
                    .ok_or("密碼格式不正確。")?
                    .to_owned();
                let _op = self.enter()?;
                self.require_available(None)?;
                let previous = self.lock()?.password.replace(password);
                if let Err(error) = self.remotes(None) {
                    self.lock()?.password = previous;
                    return Err(error);
                }
                if let Some(environment) = self.lock()?.environment.as_object_mut() {
                    environment.remove("error");
                }
                Ok(Value::Null)
            }
            "getLogPath" | "exportLog" => {
                let id = text(&args, 0, "工作編號")?;
                Ok(json!(self.log_path(&id)?.to_string_lossy()))
            }
            "getJobReportPath" => {
                let id = text(&args, 0, "工作編號")?;
                self.flush_report(&id)?;
                if !self.lock()?.jobs.iter().any(|j| j["id"] == id) {
                    return Err("找不到這項工作的記錄。".into());
                }
                Ok(json!(
                    report::path(
                        &self.logs,
                        &id,
                        args.get(1).and_then(Value::as_str).unwrap_or("jsonl")
                    )?
                    .to_string_lossy()
                ))
            }
            "getJobReport" => {
                let id = text(&args, 0, "工作編號")?;
                self.flush_report(&id)?;
                let summary = {
                    let s = self.lock()?;
                    s.jobs
                        .iter()
                        .find(|j| j["id"] == id)
                        .ok_or("找不到這項工作的記錄。")?["report"]
                        .clone()
                };
                report::page(&self.logs, &id, arg(&args, 1), summary)
            }
            "_discardLogExport" => {
                let token = text(&args, 0, "匯出編號")?;
                id_valid(&token)?;
                self.captured_logs
                    .lock()
                    .map_err(|_| "工作記錄無法讀取。")?
                    .remove(&token);
                Ok(Value::Null)
            }
            "_exportTo" => {
                let kind = text(&args, 0, "參數")?;
                let id = text(&args, 1, "參數")?;
                let destination = PathBuf::from(text(&args, 2, "參數")?);
                let source = if kind == "report" {
                    let path = self.invoke(
                        "getJobReportPath",
                        vec![json!(id), args.get(3).cloned().unwrap_or(json!("jsonl"))],
                    )?;
                    PathBuf::from(path.as_str().ok_or("找不到工作記錄。")?)
                } else if kind == "log" {
                    if let Some(token) = args.get(4).and_then(Value::as_str) {
                        id_valid(token)?;
                        self.captured_logs
                            .lock()
                            .map_err(|_| "工作記錄無法讀取。")?
                            .remove(token)
                            .ok_or("找不到這項工作的記錄。")?
                    } else {
                        self.log_path(&id)?
                    }
                } else {
                    return Err("匯出格式不正確。".into());
                };
                let result = copy_export(&source, &destination);
                if kind == "report" {
                    let _ = fs::remove_file(&source);
                }
                result?;
                Ok(json!(destination.to_string_lossy()))
            }
            "accountConfig" => {
                {
                    let state = self.lock()?;
                    if state.configuring || state.closing || self.tools.has_active() {
                        return Err("請先結束終端機設定或串流播放，再開啟帳號設定。".into());
                    }
                }
                let action = arg(&args, 0)["action"].as_str().unwrap_or("");
                if action == "info" {
                    let _operation = if self.accounts.has_active() {
                        None
                    } else {
                        Some(self.enter()?)
                    };
                    let context = self.context(&[])?;
                    return self.accounts.handle(arg(&args, 0), &context);
                }
                let owns_reservation = action == "start";
                let result = if owns_reservation {
                    let context = self.auxiliary_context()?;
                    self.begin_maintenance()?;
                    self.accounts.handle(arg(&args, 0), &context)
                } else {
                    self.accounts.handle_session(arg(&args, 0))
                };
                if owns_reservation {
                    let active = self.accounts.has_active();
                    let mut state = self.lock()?;
                    state.account_maintenance = active;
                    if !active {
                        state.maintenance = false;
                    }
                } else {
                    let _state = self.lock()?;
                }
                result
            }
            "_accountAuthorization" => self.accounts.authorization_url().map(|u| json!(u)),
            "_beginConfiguration" => {
                let c = self.auxiliary_context()?;
                self.begin_maintenance()?;
                let mut s = self.lock()?;
                s.configuring = true;
                let mut result = json!({"binary":c.binary.to_string_lossy(),"arguments":c.arguments,"environment":c.environment});
                if arg(&args, 0) == "macTerminal" {
                    let manual = s.settings["proxyMode"] == "manual";
                    let mut vars = BTreeMap::new();
                    if manual {
                        for (key, name) in [
                            ("httpProxy", "HTTP_PROXY"),
                            ("httpsProxy", "HTTPS_PROXY"),
                            ("noProxy", "NO_PROXY"),
                        ] {
                            if let Some(value) = s.settings[key].as_str().filter(|s| !s.is_empty())
                            {
                                vars.insert(name, value);
                            }
                        }
                    }
                    result["terminalEnvironment"] = json!(vars);
                    result["clearProxyEnvironment"] = json!(manual);
                }
                Ok(result)
            }
            "_endConfiguration" => {
                let mut state = self.lock()?;
                if state.configuring {
                    state.configuring = false;
                    state.maintenance = false;
                }
                drop(state);
                self.emit(json!({"type":"configurationChanged","data":{}}));
                Ok(json!(true))
            }
            "_nativePrepare" => {
                let method = text(&args, 0, "操作")?;
                let parameters = arg(&args, 1).as_array().ok_or("參數格式不正確。")?;
                let (settings, jobs) = {
                    let state = self.lock()?;
                    (state.settings.clone(), state.jobs.clone())
                };
                let mut result = crate::native_requests::prepare(
                    &method, parameters, &settings, &jobs, &self.logs,
                )?;
                if method == "exportLog" {
                    let id = result["arguments"][0]
                        .as_str()
                        .ok_or("工作編號格式不正確。")?;
                    let source = self.log_path(id)?;
                    let token = uuid::Uuid::new_v4().to_string();
                    self.captured_logs
                        .lock()
                        .map_err(|_| "工作記錄無法讀取。")?
                        .insert(token.clone(), source);
                    result["exportToken"] = json!(token);
                }
                Ok(result)
            }
            "_finderDrop" => crate::native_requests::finder_drop(arg(&args, 0)),
            "_localLocations" => {
                let raw = arg(&args, 0);
                let locations = catalog::supplied_locations(raw)?;
                let home = raw["home"]["path"].as_str().unwrap_or("").to_owned();
                *self
                    .mac_locations
                    .lock()
                    .map_err(|_| "位置資訊無法讀取。")? = Some((home, locations.clone()));
                Ok(json!(locations))
            }
            "_preferences" => {
                let settings = self.settings()?;
                Ok(json!({"resolvedLanguage":catalog::language(&settings),"settings":settings}))
            }
            "_state" => self.state_snapshot(),
            "_cancelListings" => {
                self.cancel_listings();
                Ok(json!(true))
            }
            "_shutdown" => self.shutdown(),
            "directoryTree" | "_exportFileList" | "publicLink" | "_startMount" | "_startStream"
            | "listToolSessions" | "stopToolSession" => {
                let _op = self.enter()?;
                let settings = self.settings()?;
                let c = self.auxiliary_context()?;
                self.tools.handle(method, &args, &c, &settings)
            }
            "_checkRclone" | "_rcloneUpdateTarget" | "checkAppUpdates" => {
                let settings = self.settings()?;
                let context = self.update_context()?;
                self.updater.handle(method, &args, &context, &settings)
            }
            "_installRclone" => {
                self.begin_maintenance()?;
                let result = (|| {
                    let settings = self.settings()?;
                    if args.get(1) != Some(&settings["settingsRevision"]) {
                        return Err("設定已變更，請重新檢查更新。".into());
                    }
                    let context = self.update_context()?;
                    let result = self.updater.handle(method, &args, &context, &settings)?;
                    if let Some(path) = result["path"].as_str() {
                        self.commit_rclone_update(Path::new(path))?;
                    }
                    Ok(result)
                })();
                self.lock()?.maintenance = false;
                result
            }
            "_partialPreview" | "_partialApply" | "_partialCleanup" => {
                self.begin_maintenance()?;
                let result = (|| {
                    let first = PathBuf::from(text(&args, 0, "報告或計畫位置")?);
                    let second = PathBuf::from(text(&args, 1, "輸出位置")?);
                    match method {
                        "_partialPreview" => {
                            if let Some(parent) = second.parent() {
                                storage::private_directory(parent)?;
                            }
                            crate::partial::preview(&first, &second)
                        }
                        "_partialApply" => crate::partial::apply(&first, &second),
                        _ => crate::partial::cleanup(&first, &second),
                    }
                })();
                self.lock()?.maintenance = false;
                result
            }
            _ => Err(format!("不支援的操作：{method}")),
        }
    }
    fn update_context(&self) -> Result<Context> {
        match self.context(&[]) {
            Ok(c) => Ok(c),
            Err(_) => {
                let s = self.settings()?;
                let dir = s["rcloneDirectory"]
                    .as_str()
                    .filter(|p| !p.is_empty())
                    .map(PathBuf::from)
                    .unwrap_or_else(|| self.default_dir.clone());
                let mut arguments = vec![];
                if let Some(p) = s["configPath"].as_str().filter(|p| !p.is_empty()) {
                    arguments.push(format!("--config={p}"));
                }
                Ok(Context {
                    binary: dir.join(if cfg!(windows) {
                        "rclone.exe"
                    } else {
                        "rclone"
                    }),
                    arguments,
                    environment: std::env::vars()
                        .filter(|(k, _)| !k.to_uppercase().starts_with("RCLONE_"))
                        .collect(),
                    work_dir: self.state_dir.clone(),
                })
            }
        }
    }
}
fn raw_listing_arguments(endpoint: &Endpoint, extra: Vec<String>) -> Vec<String> {
    let mut args = vec![
        "lsjson".into(),
        "--no-mimetype".into(),
        "--ask-password=false".into(),
        "--use-json-log".into(),
    ];
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    args.push(local::SMB_ENCODING.into());
    args.extend(extra);
    args.extend(["--".into(), endpoint.target()]);
    args
}
fn decoded_listing(raw: Value) -> Result<Vec<Value>> {
    raw.as_array()
        .filter(|entries| entries.iter().all(Value::is_object))
        .cloned()
        .ok_or_else(|| "rclone 未回傳有效的目錄清單。".into())
}
fn selection_listing_limit(count: usize) -> Result<()> {
    if count > 250000 {
        Err("選取清單超過 250,000 個項目，請縮小來源範圍。".into())
    } else {
        Ok(())
    }
}
fn executable(path: &Path) -> bool {
    if !path.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        path.metadata()
            .is_ok_and(|m| m.permissions().mode() & 0o111 != 0)
    }
    #[cfg(not(unix))]
    {
        true
    }
}
fn same_text(a: &str, b: &str) -> bool {
    a.nfc().eq(b.nfc())
}
fn validate_selection(selection: &[models::Selection], entries: &[Value]) -> Result<()> {
    for item in selection {
        if !entries.iter().any(|row| {
            row["name"]
                .as_str()
                .is_some_and(|n| same_text(n, &item.name))
                && (row["isDir"] == true) == item.is_dir
        }) {
            return Err(format!(
                "「{}」已不存在或類型已改變，請重新整理。",
                item.name
            ));
        }
    }
    Ok(())
}
#[cfg(not(windows))]
fn local_size(path: &Path) -> Result<Value> {
    let mut stack = vec![path.to_path_buf()];
    let mut count = 0u64;
    let mut bytes = 0u64;
    while let Some(path) = stack.pop() {
        for item in fs::read_dir(path).map_err(|e| e.to_string())? {
            let item = item.map_err(|e| e.to_string())?;
            let metadata = fs::symlink_metadata(item.path()).map_err(|e| e.to_string())?;
            if metadata.file_type().is_symlink() {
                continue;
            }
            if metadata.is_dir() {
                stack.push(item.path());
            } else if metadata.is_file() {
                count += 1;
                bytes += metadata.len();
            }
        }
    }
    Ok(json!({"count":count,"bytes":bytes}))
}
fn copy_export(source: &Path, destination: &Path) -> Result<()> {
    #[cfg(target_os = "macos")]
    return crate::mac_exports::copy_export(source, destination);
    #[cfg(not(target_os = "macos"))]
    {
        if fs::symlink_metadata(destination).is_ok_and(|m| !m.file_type().is_file()) {
            return Err("請選擇一般檔案作為匯出位置。".into());
        }
        let parent = destination.parent().ok_or("匯出位置不正確。")?;
        let temporary = parent.join(format!(
            ".rbn-export-{}",
            uuid::Uuid::new_v4().to_string().to_uppercase()
        ));
        let result = (|| {
            let mut reader = fs::File::open(source).map_err(|e| e.to_string())?;
            let mut options = OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            let mut writer = options.open(&temporary).map_err(|e| e.to_string())?;
            std::io::copy(&mut reader, &mut writer).map_err(|e| e.to_string())?;
            writer.sync_all().map_err(|e| e.to_string())?;
            drop(writer);
            drop(reader);
            #[cfg(windows)]
            crate::accounts::replace_file(&temporary, destination)?;
            #[cfg(not(windows))]
            fs::rename(&temporary, destination).map_err(|e| e.to_string())?;
            Ok(())
        })();
        let _ = storage::remove_file_if_present(&temporary);
        result
    }
}
#[cfg(any(target_os = "macos", target_os = "linux"))]
fn rename_exclusive(from: &Path, to: &Path) -> Result<()> {
    use std::{ffi::CString, os::unix::ffi::OsStrExt};
    let a = CString::new(from.as_os_str().as_bytes()).map_err(|e| e.to_string())?;
    let b = CString::new(to.as_os_str().as_bytes()).map_err(|e| e.to_string())?;
    // SAFETY: both paths are live nul-terminated buffers, and the no-replace flag
    // prevents a concurrent destination from being overwritten.
    #[cfg(target_os = "macos")]
    let status = unsafe {
        libc::renameatx_np(
            libc::AT_FDCWD,
            a.as_ptr(),
            libc::AT_FDCWD,
            b.as_ptr(),
            libc::RENAME_EXCL,
        )
    };
    #[cfg(target_os = "linux")]
    let status = unsafe {
        libc::syscall(
            libc::SYS_renameat2,
            libc::AT_FDCWD,
            a.as_ptr(),
            libc::AT_FDCWD,
            b.as_ptr(),
            1,
        )
    };
    if status == 0 {
        Ok(())
    } else {
        Err(format!("無法重新命名：{}", std::io::Error::last_os_error()))
    }
}
#[cfg(windows)]
fn rename_exclusive(from: &Path, to: &Path) -> Result<()> {
    use std::os::windows::ffi::OsStrExt;
    let a = from
        .as_os_str()
        .encode_wide()
        .chain(Some(0))
        .collect::<Vec<_>>();
    let b = to
        .as_os_str()
        .encode_wide()
        .chain(Some(0))
        .collect::<Vec<_>>();
    // SAFETY: nul-terminated UTF-16 buffers stay alive for the synchronous call;
    // flags=0 refuses an existing destination.
    if unsafe { windows_sys::Win32::Storage::FileSystem::MoveFileExW(a.as_ptr(), b.as_ptr(), 0) }
        != 0
    {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error().to_string())
    }
}

#[cfg(test)]
mod persistence_failure_tests {
    use super::*;
    #[test]
    fn failed_periodic_persistence_stops_active_worker_but_preserves_queued_request() {
        let root = std::env::var_os("RBN_TEST_ROOT")
            .map(PathBuf::from)
            .unwrap_or_else(std::env::temp_dir)
            .join(format!("persist-failure-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        let engine = Engine::new(root.join("state"), root.join("engine")).unwrap();
        let active_id = uuid::Uuid::new_v4().to_string();
        let queued_id = uuid::Uuid::new_v4().to_string();
        let active = Arc::new(Control::new());
        let queued = Arc::new(Control::new());
        {
            let mut state = engine.state.lock().unwrap();
            state.jobs = vec![
                json!({"id":active_id,"status":"running"}),
                json!({"id":queued_id,"status":"queued"}),
            ];
            state.controls.insert(active_id.clone(), active.clone());
            state.controls.insert(queued_id.clone(), queued.clone());
        }
        let blocked = engine.state_dir.join("settings.json");
        fs::remove_file(&blocked).unwrap();
        fs::create_dir(&blocked).unwrap();
        engine.notify(&active_id, false);
        let deadline = Instant::now() + Duration::from_secs(4);
        while active.failure.lock().unwrap().is_none() && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(20));
        }
        let failure = active.failure.lock().unwrap().clone();
        let states = {
            let state = engine.state.lock().unwrap();
            (
                state.jobs[0]["status"].clone(),
                state.jobs[1]["status"].clone(),
            )
        };
        let active_stopped = active.stop.load(Ordering::Acquire);
        let queued_stopped = queued.stop.load(Ordering::Acquire);
        let queued_failed = queued.failure.lock().unwrap().is_some();
        drop(engine);
        fs::remove_dir_all(&root).unwrap();
        assert!(failure.unwrap().starts_with("無法儲存工作狀態："));
        assert!(active_stopped);
        assert_eq!(states.0, "cancelling");
        assert_eq!(states.1, "queued");
        assert!(
            !queued_stopped && !queued_failed,
            "a queued request has no running worker to stop"
        );
    }
}

#[cfg(test)]
mod listing_contract_tests {
    use super::*;
    #[test]
    fn raw_listing_has_backend_flag_before_extras_without_any_cached_remote() {
        let endpoint = Endpoint::parse(&json!({"remote":"unseen","path":"folder"})).unwrap();
        let actual = raw_listing_arguments(&endpoint, vec!["--recursive".into()]);
        let mut expected = vec![
            "lsjson",
            "--no-mimetype",
            "--ask-password=false",
            "--use-json-log",
        ];
        if cfg!(any(target_os = "macos", target_os = "linux")) {
            expected.push(local::SMB_ENCODING);
        }
        expected.extend(["--recursive", "--", "unseen:folder"]);
        assert_eq!(actual, expected);
    }
    #[test]
    fn nonobject_listing_entries_fail_before_mutation_can_use_partial_results() {
        for invalid in [
            Value::Null,
            json!(1),
            json!("file"),
            json!([]),
            json!(false),
        ] {
            assert!(decoded_listing(json!([{"Name":"valid.txt","IsDir":false},invalid])).is_err());
        }
        assert!(decoded_listing(json!({})).is_err());
    }
    #[test]
    fn remote_listing_count_is_not_limited_by_selected_scope_budget() {
        let entries = vec![json!({}); 250001];
        assert_eq!(decoded_listing(json!(entries)).unwrap().len(), 250001);
        assert!(selection_listing_limit(250000).is_ok());
        assert_eq!(
            selection_listing_limit(250001).unwrap_err(),
            "選取清單超過 250,000 個項目，請縮小來源範圍。"
        );
    }
}

#[cfg(test)]
mod encoded_task_import_tests {
    use super::*;
    #[test]
    fn native_file_import_accepts_legacy_encodings_and_preserves_source_bytes() {
        let root = std::env::var_os("RBN_TEST_ROOT")
            .map(PathBuf::from)
            .unwrap_or_else(std::env::temp_dir)
            .join(format!("encoded-import-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        let engine = Engine::new(root.join("state"), root.join("engine")).unwrap();
        assert!(!engine.state_dir.join("tmp").exists());
        let document = json!({"tasks":[{"id":"9b8525d7-5d34-41d6-a633-62ec018e75b1","name":"保留 🤍","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","request":{"source":{"remote":"source","path":"資料"},"destination":{"remote":"target","path":"備份"},"mode":"copy","selection":[],"dryRun":false,"options":{}}}]});
        let text = serde_json::to_string(&document).unwrap();
        let variants = vec![
            [vec![0xef, 0xbb, 0xbf], text.as_bytes().to_vec()].concat(),
            [
                vec![0xff, 0xfe],
                text.encode_utf16().flat_map(u16::to_le_bytes).collect(),
            ]
            .concat(),
            [
                vec![0xfe, 0xff],
                text.encode_utf16().flat_map(u16::to_be_bytes).collect(),
            ]
            .concat(),
            [
                vec![0, 0, 0xfe, 0xff],
                text.chars()
                    .flat_map(|c| (c as u32).to_be_bytes())
                    .collect(),
            ]
            .concat(),
            text.chars()
                .flat_map(|c| (c as u32).to_le_bytes())
                .collect(),
        ];
        let mut expected = 0;
        for (index, bytes) in variants.iter().enumerate() {
            let file = root.join(format!("tasks-{index}.json"));
            fs::write(&file, bytes).unwrap();
            let actual = engine
                .invoke("_importTasks", vec![json!(file.to_string_lossy())])
                .unwrap();
            expected += 1;
            assert_eq!(actual.as_array().unwrap().len(), expected);
            assert!(
                actual
                    .as_array()
                    .unwrap()
                    .iter()
                    .all(|task| task["name"] == "保留 🤍")
            );
            assert_eq!(&fs::read(&file).unwrap(), bytes);
        }
        let imported = engine
            .invoke("importTasks", vec![json!(format!("\u{feff}{text}"))])
            .unwrap();
        assert_eq!(imported.as_array().unwrap().len(), expected + 1);
        engine.shutdown().unwrap();
        drop(engine);
        fs::remove_dir_all(root).unwrap();
    }
}
