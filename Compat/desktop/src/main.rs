#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use serde::Deserialize;
use serde_json::{json, Value};
use std::{collections::HashMap, fs, io::{BufRead, BufReader, Read, Write}, path::{Path, PathBuf},
    process::{Child, ChildStdin, Command, Stdio}, sync::{Arc, Mutex, atomic::{AtomicBool, AtomicU64, Ordering}, mpsc},
    thread, time::Duration};
use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindow, WebviewWindowBuilder};
use tauri::utils::config::Color;
use tauri_plugin_clipboard_manager::ClipboardExt;
use tauri_plugin_dialog::{DialogExt, MessageDialogButtons, MessageDialogKind, MessageDialogResult};

const METHODS: &[&str] = &[
    "bootstrap", "list", "mkdir", "rename", "remove", "size", "chooseFolder", "chooseFile", "previewTransfer",
    "startTransfer", "cancelJob", "retryJob", "listJobs", "clearFinishedJobs", "clearJobs", "saveTask", "deleteTask",
    "listTasks", "saveSettings", "unlockConfig", "configureRemotes", "accountConfig", "openAccountAuthorization", "openExternal", "exportLog", "getJobReport",
    "exportJobReport", "exportTasks", "importTasks", "checkForUpdates", "checkAppUpdates", "showAbout", "copyText",
    "directoryTree", "exportFileList", "publicLink", "startMount", "startStream", "listToolSessions", "stopToolSession",
];

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request { id: String, method: String, args: Vec<Value> }

struct Host {
    input: Mutex<Option<ChildStdin>>,
    child: Mutex<Child>,
    pending: Mutex<HashMap<String, mpsc::Sender<Value>>>,
    sequence: AtomicU64,
    settings: Mutex<Value>,
    alive: AtomicBool,
    quitting: AtomicBool,
    update_busy: AtomicBool,
    startup_checked: AtomicBool,
    state_path: PathBuf,
    runtime: PathBuf,
    smoke_path: Option<PathBuf>,
    smoke_finished: AtomicBool,
}

impl Host {
    fn start(app: &AppHandle, state_path: PathBuf, runtime: PathBuf, smoke_path: Option<PathBuf>) -> Result<Arc<Self>, String> {
        let name = if cfg!(windows) { "rbn-engine.exe" } else { "rbn-engine" };
        let helper = runtime.join(name);
        if !helper.is_file() { return Err(format!("Missing engine: {}", helper.display())); }
        fs::create_dir_all(state_path.join("tmp")).map_err(|e| e.to_string())?;
        let mut command = Command::new(&helper);
        command.args(["--state-dir", &state_path.to_string_lossy(), "--engine-dir", &state_path.join("rclone").to_string_lossy()]);
        command.current_dir(&runtime).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null());
        command.env("TMPDIR", state_path.join("tmp")).env("TMP", state_path.join("tmp")).env("TEMP", state_path.join("tmp"));
        #[cfg(unix)] {
            let old = std::env::var_os("LD_LIBRARY_PATH").unwrap_or_default();
            let mut paths = vec![runtime.join("lib")]; paths.extend(std::env::split_paths(&old));
            command.env("LD_LIBRARY_PATH", std::env::join_paths(paths).map_err(|e| e.to_string())?);
        }
        #[cfg(windows)] {
            use std::os::windows::process::CommandExt;
            command.creation_flags(0x08000000); // CREATE_NO_WINDOW; individual rclone jobs own their signal console.
        }
        let mut child = command.spawn().map_err(|e| format!("Cannot start the engine: {e}"))?;
        let output = child.stdout.take().ok_or("Missing engine output")?;
        let input = child.stdin.take();
        let host = Arc::new(Self { input: Mutex::new(input), child: Mutex::new(child), pending: Mutex::new(HashMap::new()),
            sequence: AtomicU64::new(1), settings: Mutex::new(Value::Null), alive: AtomicBool::new(true),
            quitting: AtomicBool::new(false), update_busy: AtomicBool::new(false), startup_checked: AtomicBool::new(false),
            state_path, runtime, smoke_path, smoke_finished: AtomicBool::new(false) });
        let weak = Arc::downgrade(&host); let app = app.clone();
        thread::spawn(move || {
            let mut reader = BufReader::new(output);
            loop {
                let mut bytes = Vec::new();
                match (&mut reader).take(32 * 1024 * 1024).read_until(b'\n', &mut bytes) {
                    Ok(0) | Err(_) => break,
                    Ok(_) if bytes.last() != Some(&b'\n') => break,
                    _ => {}
                }
                let Some(host) = weak.upgrade() else { break };
                let Ok(value) = serde_json::from_slice::<Value>(&bytes) else { break };
                if let Some(event) = value.get("event") { emit(&app, event); }
                else if let Some(id) = value["id"].as_str() {
                    if let Some(sender) = host.pending.lock().unwrap().remove(id) { let _ = sender.send(value); }
                }
            }
            if let Some(host) = weak.upgrade() {
                host.alive.store(false, Ordering::SeqCst);
                for (_, sender) in host.pending.lock().unwrap().drain() {
                    let _ = sender.send(json!({"error": "The engine stopped. Reopen Rclone Browser Next."}));
                }
            }
        });
        Ok(host)
    }

    fn call(&self, method: &str, args: Vec<Value>) -> Result<Value, String> {
        self.call_with_timeout(method, args, Duration::from_secs(960))
    }

    fn call_with_timeout(&self, method: &str, args: Vec<Value>, timeout: Duration) -> Result<Value, String> {
        if !self.alive.load(Ordering::SeqCst) { return Err(self.text("引擎已停止，請重新開啟程式。", "The engine stopped. Reopen the app.", "エンジンが停止しました。アプリを開き直してください。")); }
        let id = format!("host-{}", self.sequence.fetch_add(1, Ordering::Relaxed));
        let mut packet = serde_json::to_vec(&json!({"id": id, "method": method, "args": args})).map_err(|e| e.to_string())?;
        if packet.len() > 8 * 1024 * 1024 { return Err(self.text("這次選取的內容超過單次請求上限，請分批處理。", "This selection exceeds one request. Process it in smaller groups.", "選択項目が 1 回の要求の上限を超えています。分けて実行してください。")); }
        packet.push(b'\n');
        let (tx, rx) = mpsc::channel(); self.pending.lock().unwrap().insert(id.clone(), tx);
        let write = {
            let mut input = self.input.lock().unwrap();
            // Check under the pipe lock: a dialog opened before Quit must not
            // submit a new transfer after the quit snapshot has been taken.
            if self.quitting.load(Ordering::SeqCst) && !["_state", "_shutdown", "_endConfiguration"].contains(&method) {
                Err("The app is closing.")
            } else {
                input.as_mut().ok_or("The engine is closing.").and_then(|stdin| stdin.write_all(&packet).map_err(|_| "Cannot contact the engine."))
            }
        };
        if let Err(error) = write { self.pending.lock().unwrap().remove(&id); return Err(error.into()); }
        let reply = rx.recv_timeout(timeout);
        self.pending.lock().unwrap().remove(&id);
        let reply = reply.map_err(|_| if method == "_preferences" {
            self.text("讀取設定逾時。請重新開啟程式。", "Reading settings timed out. Reopen the app.", "設定の読み込みがタイムアウトしました。アプリを開き直してください。")
        } else { self.text("操作尚未回應，請查看工作狀態。", "The operation has not responded. Check its job status.", "操作の応答がありません。ジョブの状態を確認してください。") })?;
        if let Some(error) = reply.get("error") { return Err(error.as_str().unwrap_or("Operation failed").to_owned()); }
        Ok(reply.get("result").cloned().unwrap_or(Value::Null))
    }

    fn language(&self) -> String {
        self.settings.lock().unwrap().get("_resolvedLanguage").and_then(Value::as_str).unwrap_or("en").to_owned()
    }
    fn text(&self, zh: &str, en: &str, ja: &str) -> String {
        match self.language().as_str() { "zh-TW" => zh.into(), "ja" => ja.into(), _ => en.into() }
    }
    fn store_settings(&self, settings: &Value, language: Option<&str>) {
        if !settings.is_object() { return; }
        let mut value = settings.clone();
        if let Some(object) = value.as_object_mut() {
            let selected = object.get("language").and_then(Value::as_str).unwrap_or("system").to_owned();
            let resolved = language.map(str::to_owned).unwrap_or_else(|| {
                if selected != "system" { selected } else {
                    let locale = std::env::var("LANG").unwrap_or_default().to_lowercase();
                    if locale.starts_with("zh") { "zh-TW".into() } else if locale.starts_with("ja") { "ja".into() } else { "en".into() }
                }
            });
            object.insert("_resolvedLanguage".into(), json!(resolved));
        }
        let mut stored = self.settings.lock().unwrap();
        if value["settingsRevision"].as_u64().unwrap_or(0) >= stored["settingsRevision"].as_u64().unwrap_or(0) {
            *stored = value;
        }
    }
}

fn emit(app: &AppHandle, value: &Value) {
    if let Some(window) = app.get_webview_window("main") {
        if let Ok(encoded) = serde_json::to_string(value) { let _ = window.eval(format!("window.__rbnEvent?.({encoded})")); }
    }
}

fn bundled_url(url: &tauri::Url) -> bool {
    ((url.scheme() == "tauri" && url.host_str() == Some("localhost")) ||
     (["http", "https"].contains(&url.scheme()) && url.host_str() == Some("tauri.localhost"))) &&
        matches!(url.path(), "" | "/" | "/index.html") && url.query().is_none()
}

fn arg_text(args: &[Value], index: usize) -> Result<String, String> {
    args.get(index).and_then(Value::as_str).filter(|s| s.len() <= 32768 && !s.contains('\0')).map(str::to_owned).ok_or_else(|| "Invalid argument".into())
}

fn endpoint(value: &Value) -> String {
    let path = value["path"].as_str().unwrap_or_default();
    value["remote"].as_str().map(|name| format!("{name}:{path}")).unwrap_or_else(|| path.to_owned())
}

fn application_version(app: &AppHandle) -> String {
    // Windows revisions come from tauri.windows.conf.json. The Cargo package
    // keeps the shared base version and must not hide the installed revision.
    #[cfg(windows)] { app.package_info().version.to_string() }
    #[cfg(not(windows))] { let _ = app; env!("CARGO_PKG_VERSION").to_owned() }
}

fn confirmed(app: &AppHandle, host: &Host, title: String, detail: String, action: String) -> bool {
    let cancel = host.text("取消", "Cancel", "キャンセル");
    let result = app.dialog().message(detail).title(title).kind(MessageDialogKind::Warning)
        .buttons(MessageDialogButtons::OkCancelCustom(action.clone(), cancel)).blocking_show_with_result();
    matches!(result, MessageDialogResult::Custom(ref label) if label == &action)
}

fn confirm_transfer(app: &AppHandle, host: &Host, request: &Value) -> bool {
    if request["dryRun"].as_bool() == Some(true) || request["mode"].as_str() == Some("copy") { return true; }
    let from = endpoint(&request["source"]); let to = endpoint(&request["destination"]);
    let mut locations = host.text(&format!("來源：{from}\n目標：{to}"), &format!("Source: {from}\nDestination: {to}"), &format!("転送元：{from}\n転送先：{to}"));
    let selection: Vec<&str> = request["selection"].as_array().map(|items| items.iter().filter_map(|item| item["name"].as_str()).collect()).unwrap_or_default();
    if selection.is_empty() {
        locations += &host.text("\n\n範圍：來源目前資料夾", "\n\nScope: the current source folder", "\n\n対象：転送元の現在のフォルダ");
    } else {
        let count = selection.len();
        locations += &host.text(&format!("\n\n範圍：已選取的 {count} 個來源項目"), &format!("\n\nScope: {count} selected source items"), &format!("\n\n対象：転送元で選択した {count} 件"));
        for name in selection.iter().take(6) {
            locations.push('\n'); locations += &name.chars().take(160).collect::<String>();
            if name.chars().count() > 160 { locations.push('…'); }
        }
        if count > 6 { locations += &host.text(&format!("\n…另有 {} 個項目", count - 6), &format!("\n…and {} more", count - 6), &format!("\n…ほか {} 件", count - 6)); }
    }
    if request["mode"].as_str() == Some("sync") {
        let explanation = host.text("\n\n以來源為準更新目標，套用本次篩選與刪除設定。同步範圍內只存在於目標的檔案會被刪除。", "\n\nUpdate the destination to match the source, applying this job's filters and deletion settings. Files found only at the destination within the sync scope will be deleted.", "\n\n今回の絞り込みと削除設定を適用し、転送元に合わせて転送先を更新します。同期待象内で転送先にしかないファイルを削除します。");
        let limit = request["options"]["maxDelete"].as_i64().unwrap_or(-1);
        let deletion = if limit < 0 { host.text("\n\n本次不限刪除數量。", "\n\nNo deletion-count limit is set.", "\n\n今回の削除数に上限はありません。") }
            else { host.text(&format!("\n\n本次最多刪除 {limit} 個檔案。"), &format!("\n\nDelete at most {limit} files."), &format!("\n\n今回の削除数の上限は {limit} ファイルです。")) };
        confirmed(app, host, host.text("同步到目標？", "Sync to destination?", "転送先を同期しますか？"), locations + &explanation + &deletion, host.text("開始同步", "Start sync", "同期を開始"))
    } else {
        let explanation = host.text("\n\n複製成功，或目標副本經比對無需更新時，會刪除來源檔案。", "\n\nSource files are deleted after a successful copy, or when comparison finds no update is needed at the destination.", "\n\nコピー成功時、または比較で転送先の更新が不要と判断された場合に、転送元ファイルを削除します。");
        confirmed(app, host, host.text("移動到目標？", "Move to destination?", "転送先へ移動しますか？"), locations + &explanation, host.text("開始移動", "Start move", "移動を開始"))
    }
}

fn choose_file(app: &AppHandle, title: &str, save: bool, name: Option<&str>) -> Result<Option<PathBuf>, String> {
    let mut dialog = app.dialog().file().set_title(title);
    if let Some(name) = name { dialog = dialog.set_file_name(name); }
    let selected = if save { dialog.blocking_save_file() } else { dialog.blocking_pick_file() };
    selected.map(|v| v.into_path().map_err(|e| e.to_string())).transpose()
}

fn choose_folder(app: &AppHandle, title: &str, current: Option<&str>) -> Result<Option<PathBuf>, String> {
    let mut dialog = app.dialog().file().set_title(title);
    if let Some(current) = current.filter(|p| Path::new(p).is_dir()) { dialog = dialog.set_directory(current); }
    dialog.blocking_pick_folder().map(|v| v.into_path().map_err(|e| e.to_string())).transpose()
}

fn external_url_allowed(value: &str) -> bool {
    let Ok(url) = tauri::Url::parse(value) else { return false };
    url.scheme() == "https" && url.username().is_empty() && url.password().is_none() && url.port().is_none() &&
        (matches!(url.host_str(), Some("rclone.org") | Some("downloads.rclone.org")) ||
         (url.host_str() == Some("github.com") && ["/jason840709/RcloneBrowserNext", "/kapitainsky/RcloneBrowser", "/mmozeiko/RcloneBrowser", "/rclone/rclone"]
             .iter().any(|path| url.path() == *path || url.path().starts_with(&format!("{path}/")))))
}

fn open_url(value: &str) -> Result<(), String> {
    #[cfg(windows)] let mut command = { let mut c = Command::new("rundll32.exe"); c.args(["url.dll,FileProtocolHandler", value]); c };
    #[cfg(not(windows))] let mut command = { let mut c = Command::new("xdg-open"); c.arg(value); c };
    command.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn().map_err(|e| e.to_string())?;
    Ok(())
}

fn interface_zoom(displayed_scale: u64) -> f64 {
    let scale = if [80, 90, 100, 110, 120, 125, 135].contains(&displayed_scale) { displayed_scale } else { 100 };
    (scale as f64 - 10.0) / 100.0
}

fn appearance_theme(settings: &Value) -> &str {
    match settings["theme"].as_str().unwrap_or("purple-dark") {
        "dark" => "blue-dark", "light" => "blue-light",
        theme @ ("purple-dark" | "purple-light" | "blue-dark" | "blue-light" | "green-dark" | "green-light") => theme,
        _ => "purple-dark",
    }
}

fn appearance_background(theme: &str) -> Color {
    let component = if theme.ends_with("-light") { 241 } else { 28 };
    Color(component, component, component, 255)
}

fn apply_preferences(app: &AppHandle, host: &Arc<Host>) {
    let handle = app.clone(); let host = host.clone();
    // Read the latest revision on the UI thread. A slow, older save reply must
    // never restore an old zoom or theme after a newer preference was applied.
    let _ = app.run_on_main_thread(move || {
        let settings = host.settings.lock().unwrap().clone();
        if let Some(window) = handle.get_webview_window("main") {
            let scale = settings["interfaceScale"].as_u64().unwrap_or(100);
            let _ = window.set_zoom(interface_zoom(scale));
            let theme = appearance_theme(&settings);
            let appearance = if theme.ends_with("light") { tauri::Theme::Light } else { tauri::Theme::Dark };
            let _ = window.set_theme(Some(appearance));
            let _ = window.set_background_color(Some(appearance_background(theme)));
            let color = if theme.starts_with("green") { "green" } else if theme.starts_with("blue") { "blue" } else { "purple" };
            if let Ok(icon) = tauri::image::Image::from_path(host.runtime.join(format!("icon-{color}.png"))) { let _ = window.set_icon(icon); }
        }
    });
}

fn check_rclone(app: &AppHandle, host: &Arc<Host>, manual: bool) -> Result<Value, String> {
    if host.update_busy.swap(true, Ordering::SeqCst) { return Ok(json!({"status":"busy"})); }
    struct Reset<'a>(&'a AtomicBool); impl Drop for Reset<'_> { fn drop(&mut self) { self.0.store(false, Ordering::SeqCst); } }
    let _reset = Reset(&host.update_busy);
    let mut result = host.call("_checkRclone", vec![json!(manual)])?;
    let status = result["status"].as_str().unwrap_or("");
    if !["available", "notInstalled"].contains(&status) || (status == "notInstalled" && !manual) { return Ok(result); }
    let new = result["latestVersion"].as_str().unwrap_or_default().to_owned();
    let old = result["currentVersion"].as_str().filter(|value| !value.is_empty()).map(str::to_owned).unwrap_or_else(||
        if status == "notInstalled" { host.text("尚未安裝", "Not installed", "未インストール") }
        else { host.text("未能讀取版本", "Version unavailable", "バージョンを取得できません") });
    let target = result["targetPath"].as_str().unwrap_or_default();
    let title = host.text("下載或更新 rclone", "Download or update rclone", "rclone のダウンロード・更新");
    let message = host.text(&format!("目前：{old}\n新版：{new}\n\n安裝位置：{target}"), &format!("Current: {old}\nLatest: {new}\n\nInstall location: {target}"), &format!("現在：{old}\n最新版：{new}\n\nインストール先：{target}"));
    let install = host.text("安裝", "Install", "インストール"); let skip = host.text("跳過此版本", "Skip this version", "このバージョンをスキップ");
    let later = host.text("稍後", "Later", "後で");
    let choice = app.dialog().message(message).title(title)
        .buttons(MessageDialogButtons::YesNoCancelCustom(install.clone(), skip.clone(), later)).blocking_show_with_result();
    if matches!(choice, MessageDialogResult::Custom(ref s) if s == &skip) {
        host.call("saveSettings", vec![json!({"skippedRcloneVersion":new})])?;
        result["status"] = json!("skipped"); return Ok(result);
    }
    if !matches!(choice, MessageDialogResult::Custom(ref s) if s == &install) { result["status"] = json!("later"); return Ok(result); }
    let updated = host.call("_installRclone", vec![json!(new), result["settingsRevision"].clone()])?;
    emit(app, &json!({"type":"configurationChanged","data":{}}));
    emit(app, &json!({"type":"updateStatus","data":{"phase":"updated","status":"updated","message":host.text(&format!("rclone 已更新為 {new}。"),&format!("rclone updated to {new}."),&format!("rclone を {new} に更新しました。"))}}));
    Ok(updated)
}

fn configure(app: &AppHandle, host: &Arc<Host>) -> Result<Value, String> {
    let context = host.call("_beginConfiguration", vec![])?;
    let result = start_terminal(host, &context);
    match result {
        Ok(mut child) => {
            let host = host.clone(); let app = app.clone();
            thread::spawn(move || { let _ = child.wait(); let _ = host.call("_endConfiguration", vec![]); emit(&app, &json!({"type":"configurationChanged","data":{}})); });
            Ok(Value::Null)
        }
        Err(error) => { let _ = host.call("_endConfiguration", vec![]); Err(error) }
    }
}

fn start_terminal(host: &Host, context: &Value) -> Result<Child, String> {
    let binary = context["binary"].as_str().ok_or("Missing rclone path")?;
    let mut args: Vec<String> = context["arguments"].as_array().ok_or("Missing rclone arguments")?.iter().map(|x| x.as_str().unwrap_or_default().to_owned()).collect();
    args.push("config".into());
    #[cfg(windows)] let mut command = {
        use std::os::windows::process::CommandExt;
        let launcher = host.runtime.join("rbn-process-launcher.exe");
        if !launcher.is_file() { return Err(host.text("帳號設定元件遺失，請重新安裝程式。", "The account setup component is missing. Reinstall the app.", "アカウント設定のコンポーネントがありません。アプリを再インストールしてください。")); }
        let mut command = Command::new(launcher);
        command.arg("--interactive").arg(binary).args(&args);
        // The launcher opens CONIN$/CONOUT$ for this new console. It executes
        // rclone directly, preserving paths and arguments without a shell.
        command.creation_flags(0x00000010); command // CREATE_NEW_CONSOLE
    };
    #[cfg(not(windows))] let mut command = {
        let terminals: &[(&str, &[&str])] = &[("gnome-terminal", &["--wait", "--"]), ("konsole", &["--nofork", "-e"]), ("xfce4-terminal", &["--disable-server", "--execute"]), ("xterm", &["-e"])];
        let found = terminals.iter().find_map(|(name, switches)| find_executable(name).map(|path| (path, *switches)))
            .ok_or_else(|| host.text("請先安裝終端機程式（例如 xterm），再開啟帳號設定。", "Install a terminal such as xterm, then open account setup.", "xterm などの端末をインストールしてから、アカウント設定を開いてください。"))?;
        let mut command = Command::new(found.0); command.args(found.1).arg(binary).args(&args); command
    };
    command.env_clear();
    if let Some(environment) = context["environment"].as_object() { for (key, value) in environment { if let Some(value) = value.as_str() { command.env(key, value); } } }
    command.current_dir(&host.state_path).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    command.spawn().map_err(|e| e.to_string())
}

#[cfg(not(windows))]
fn find_executable(name: &str) -> Option<PathBuf> {
    std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default()).map(|p| p.join(name)).find(|p| p.is_file())
}

fn handle(app: &AppHandle, host: &Arc<Host>, request: Request) -> Result<Value, String> {
    let args = request.args;
    if host.quitting.load(Ordering::SeqCst) { return Err(host.text("程式正在關閉。", "The app is closing.", "アプリを終了しています。")); }
    match request.method.as_str() {
        "bootstrap" => {
            let result = host.call("bootstrap", args)?;
            host.store_settings(&result["settings"], result["resolvedLanguage"].as_str());
            apply_preferences(app, host);
            if host.smoke_path.is_none() && !host.startup_checked.swap(true, Ordering::SeqCst) {
                let app = app.clone(); let host = host.clone();
                thread::spawn(move || { thread::sleep(Duration::from_secs(2)); let _ = check_rclone(&app, &host, false); });
            }
            Ok(result)
        }
        "chooseFolder" => Ok(choose_folder(app, &host.text("選擇資料夾", "Choose folder", "フォルダを選択"), args.first().and_then(Value::as_str))?.map(|p| json!(p.to_string_lossy())).unwrap_or(Value::Null)),
        "chooseFile" => {
            let kind = arg_text(&args, 0)?;
            let title = match kind.as_str() {
                "rclone" => host.text("選擇 rclone 執行檔", "Choose rclone executable", "rclone 実行ファイルを選択"),
                "credential" => host.text("選擇憑證檔案", "Choose credential file", "認証ファイルを選択"),
                "config" => host.text("選擇 rclone 設定檔", "Choose rclone configuration file", "rclone 設定ファイルを選択"),
                "player" => host.text("選擇播放器執行檔", "Choose player executable", "プレーヤーの実行ファイルを選択"),
                _ => return Err(host.text("不支援這種檔案類型。", "This file type is not supported.", "このファイル形式には対応していません。")),
            };
            Ok(choose_file(app, &title, false, None)?.map(|p| json!(p.to_string_lossy())).unwrap_or(Value::Null))
        }
        "startTransfer" => {
            let normalized = host.call("_normalizeTransfer", args)?;
            if !confirm_transfer(app, host, &normalized) { return Ok(Value::Null); }
            host.call("startTransfer", vec![normalized])
        }
        "retryJob" => {
            let id = arg_text(&args, 0)?; let jobs = host.call("listJobs", vec![])?;
            let job = jobs.as_array().and_then(|a| a.iter().find(|x| x["id"] == id)).ok_or_else(|| host.text("找不到這個工作。", "This job was not found.", "このジョブが見つかりません。"))?;
            if !confirm_transfer(app, host, &job["request"]) { return Ok(Value::Null); }
            host.call("retryJob", vec![json!(id)])
        }
        "remove" => {
            let names = args.get(1).and_then(Value::as_array).ok_or_else(|| host.text("請選取要刪除的檔案。", "Select files to delete.", "削除するファイルを選択してください。"))?;
            if names.is_empty() { return Ok(json!(false)); }
            let paths = names.iter().take(8).filter_map(|v| v["name"].as_str()).collect::<Vec<_>>().join("\n");
            let message = host.text(&format!("{}\n\n{paths}\n\n永久刪除 {} 個項目。", endpoint(&args[0]), names.len()), &format!("{}\n\n{paths}\n\nPermanently delete {} items.", endpoint(&args[0]), names.len()), &format!("{}\n\n{paths}\n\n{} 件を完全に削除します。", endpoint(&args[0]), names.len()));
            if !confirmed(app, host, host.text("刪除選取項目？", "Delete selected items?", "選択項目を削除しますか？"), message, host.text("刪除", "Delete", "削除")) { return Ok(json!(false)); }
            host.call("remove", args)
        }
        "saveSettings" => {
            let result = host.call("saveSettings", args)?;
            let state = host.call("_preferences", vec![])?;
            host.store_settings(&state["settings"], state["resolvedLanguage"].as_str()); apply_preferences(app, host);
            Ok(result)
        }
        "exportLog" | "exportJobReport" => {
            let id = arg_text(&args, 0)?;
            let report = request.method == "exportJobReport";
            let format = args.get(1).and_then(Value::as_str).unwrap_or("jsonl");
            if !["comparison", "jsonl"].contains(&format) { return Err(host.text("不支援這個紀錄匯出格式。", "This report export format is not supported.", "このログの書き出し形式には対応していません。")); }
            let suffix = if report { if format == "comparison" { "comparison.txt" } else { "report.jsonl" } } else { "raw.jsonl" };
            let Some(path) = choose_file(app, &host.text("匯出紀錄", "Export report", "ログをエクスポート"), true, Some(&format!("rclone-{id}-{suffix}")))? else { return Ok(Value::Null); };
            host.call("_exportTo", vec![json!(if report { "report" } else { "log" }), json!(id), json!(path.to_string_lossy()), json!(format)])
        }
        "exportTasks" | "importTasks" => {
            let exporting = request.method == "exportTasks";
            let title = if exporting { host.text("匯出作業", "Export tasks", "タスクをエクスポート") } else { host.text("匯入作業", "Import tasks", "タスクをインポート") };
            let Some(path) = choose_file(app, &title, exporting, if exporting { Some("Rclone_Browser_Tasks.json") } else { None })? else { return Ok(Value::Null); };
            host.call(if exporting { "_exportTasks" } else { "_importTasks" }, vec![json!(path.to_string_lossy())])
        }
        "accountConfig" => host.call("accountConfig", args),
        "openAccountAuthorization" => {
            let value = host.call("_accountAuthorization", vec![])?;
            let url = value.as_str().ok_or("No authorization is pending")?;
            open_url(url)?; Ok(Value::Null)
        }
        "configureRemotes" => configure(app, host),
        "openExternal" => {
            let url = arg_text(&args, 0)?;
            if !external_url_allowed(&url) { return Err(host.text("請從瀏覽器開啟這個網址。", "Open this address in your browser.", "このアドレスはブラウザで開いてください。")); }
            open_url(&url)?; Ok(Value::Null)
        }
        "checkForUpdates" => check_rclone(app, host, args.first().and_then(Value::as_bool).unwrap_or(true)),
        "showAbout" => {
            let version = application_version(app);
            #[cfg(windows)]
            let version = match version.split_once('+') {
                Some((base, revision)) => host.text(&format!("{base}（Windows 修正版 {revision}）"), &format!("{base} (Windows revision {revision})"), &format!("{base}（Windows 修正版 {revision}）")),
                None => version,
            };
            app.dialog().message(format!("Rclone Browser Next {version}\n\nJason Chen\n\n{}\n\nhttps://github.com/jason840709/RcloneBrowserNext", host.text("延續 Rclone Browser 的設計，使用 rclone 傳輸檔案。", "Builds on the design of Rclone Browser, using rclone for file transfers.", "Rclone Browser の設計を引き継ぎ、rclone でファイルを転送します。"))).title(host.text("關於", "About", "このアプリについて")).blocking_show();
            Ok(Value::Null)
        }
        "copyText" => { let value = args.first().and_then(Value::as_str).filter(|s| s.len() <= 1024 * 1024 && !s.contains('\0')).ok_or_else(|| host.text("請選取 1 MiB 以內的文字。", "Choose text no larger than 1 MiB.", "1 MiB 以下のテキストを選択してください。"))?; app.clipboard().write_text(value).map_err(|e| e.to_string())?; Ok(Value::Null) }
        "exportFileList" => {
            let format = args.get(1).and_then(Value::as_str).unwrap_or("csv");
            if !["csv", "txt"].contains(&format) { return Err(host.text("不支援這個匯出格式。", "This export format is not supported.", "この書き出し形式には対応していません。")); }
            let Some(path) = choose_file(app, &host.text("匯出檔案清單", "Export file list", "ファイル一覧をエクスポート"), true, Some(&format!("Rclone_File_List.{format}")))? else { return Ok(Value::Null); };
            host.call("_exportFileList", vec![args.first().cloned().unwrap_or(Value::Null), json!(format), json!(path.to_string_lossy())]).map(|_| json!(path.to_string_lossy()))
        }
        "publicLink" => {
            let name = arg_text(&args, 1)?;
            let base = args.first().ok_or("Missing location")?;
            let path = base["path"].as_str().unwrap_or_default();
            let separator = if path.is_empty() || path.ends_with('/') || (base["remote"].is_null() && path.ends_with('\\')) { "" } else { "/" };
            let target = format!("{}{separator}{name}", endpoint(base));
            let detail = target + &host.text("\n\n取得連結的人可能不需登入就能讀取內容。連結的期限與權限由雲端服務決定。", "\n\nPeople with the link may be able to read the content without signing in. The provider controls the link's permissions and expiry.", "\n\nリンクを知っている人が、ログインせずに内容を読める場合があります。有効期限と権限はクラウドサービスが決定します。");
            if !confirmed(app, host, host.text("建立公開連結？", "Create a public link?", "公開リンクを作成しますか？"), detail, host.text("建立連結", "Create link", "リンクを作成")) { return Ok(Value::Null); }
            host.call("publicLink", args)
        }
        "startMount" => {
            let Some(point) = choose_folder(app, &host.text("選擇空資料夾作為掛載位置", "Choose an empty mount folder", "マウント先の空フォルダを選択"), None)? else { return Ok(Value::Null); };
            host.call("_startMount", vec![args.first().cloned().unwrap_or(Value::Null), args.get(1).cloned().unwrap_or(json!({})), json!(point.to_string_lossy())])
        }
        "startStream" => {
            let settings = host.call("_state", vec![])?;
            if !settings["settings"]["streamPlayerPath"].as_str().map(|p| Path::new(p).is_file()).unwrap_or(false) {
                let Some(player) = choose_file(app, &host.text("選擇播放器執行檔", "Choose the media player executable", "プレーヤーの実行ファイルを選択"), false, None)? else { return Ok(Value::Null); };
                host.call("saveSettings", vec![json!({"streamPlayerPath":player.to_string_lossy()})])?;
                emit(app, &json!({"type":"configurationChanged","data":{}}));
            }
            host.call("_startStream", args)
        }
        method => host.call(method, args),
    }
}

#[tauri::command]
async fn dispatch(app: AppHandle, window: WebviewWindow, host: tauri::State<'_, Arc<Host>>, request: Request) -> Result<Value, String> {
    let id = request.id.clone();
    if window.label() != "main" || !window.url().map(|u| bundled_url(&u)).unwrap_or(false) || id.is_empty() || id.len() > 96 ||
        request.args.len() > 8 || !METHODS.contains(&request.method.as_str()) {
        return Ok(json!({"id":id,"error":"Request rejected"}));
    }
    let host = host.inner().clone();
    Ok(match tauri::async_runtime::spawn_blocking(move || handle(&app, &host, request)).await {
        Ok(Ok(result)) => json!({"id":id,"result":result}),
        Ok(Err(error)) => json!({"id":id,"error":error}),
        Err(_) => json!({"id":id,"error":window.state::<Arc<Host>>().text("操作意外停止。請查看工作狀態。", "The operation stopped unexpectedly. Check its job status.", "操作が予期せず停止しました。ジョブの状態を確認してください。")}),
    })
}

fn quit_needs_confirmation(state: &Value) -> bool {
    state["activeJobs"].as_bool() == Some(true) || state["activeTools"].as_bool() == Some(true) ||
        state["quit"]["requiresConfirmation"].as_bool() == Some(true)
}

fn start_quit(app: AppHandle, host: Arc<Host>) {
    if host.quitting.swap(true, Ordering::SeqCst) { return; }
    thread::spawn(move || {
        let result = (|| -> Result<bool, String> {
            if host.alive.load(Ordering::SeqCst) && host.update_busy.load(Ordering::SeqCst) { return Err(host.text("請等更新完成，再結束程式。", "Wait for the update to finish before quitting.", "更新が完了してからアプリを終了してください。")); }
            let state = if host.alive.load(Ordering::SeqCst) {
                match host.call("_state", vec![]) {
                    Ok(state) => state,
                    Err(_) if !host.alive.load(Ordering::SeqCst) => Value::Null,
                    Err(error) => return Err(error),
                }
            } else { Value::Null };
            if state["configuring"].as_bool() == Some(true) { return Err(host.text("請先關閉帳號設定視窗。", "Close the account setup terminal first.", "先にアカウント設定の端末を閉じてください。")); }
            let active = state["activeJobs"].as_bool() == Some(true) || state["activeTools"].as_bool() == Some(true);
            let detail = if active { host.text("結束會停止傳輸與播放。已完成的檔案變更會保留；未完成的傳輸工作會留在紀錄中，下次可重新執行。", "Quitting stops transfers and streams. Completed file changes are kept. Unfinished transfer jobs remain in history so you can run them again next time.", "終了すると転送と再生を停止します。完了したファイルの変更は保持します。未完了の転送ジョブは履歴に残り、次回もう一度実行できます。") }
                else { host.text("還有失敗或未完成的工作。工作紀錄會保留，下次可重試。", "Some jobs failed or are unfinished. Their history is kept so you can retry them next time.", "失敗または未完了のジョブがあります。履歴は保持され、次回再試行できます。") };
            if quit_needs_confirmation(&state) && !confirmed(&app, &host, host.text("確定結束 Rclone Browser Next？", "Quit Rclone Browser Next?", "Rclone Browser Next を終了しますか？"), detail, host.text("結束", "Quit", "終了")) { return Ok(false); }
            if host.alive.load(Ordering::SeqCst) {
                if let Err(error) = host.call("_shutdown", vec![]) {
                    if host.alive.load(Ordering::SeqCst) { return Err(error); }
                }
            }
            host.input.lock().unwrap().take();
            let _ = host.child.lock().unwrap().wait();
            Ok(true)
        })();
        match result {
            Ok(true) => app.exit(0),
            Ok(false) => host.quitting.store(false, Ordering::SeqCst),
            Err(error) => { host.quitting.store(false, Ordering::SeqCst); app.dialog().message(error).kind(MessageDialogKind::Error).blocking_show(); }
        }
    });
}

#[tauri::command]
fn request_quit(app: AppHandle, window: WebviewWindow, host: tauri::State<'_, Arc<Host>>) {
    if window.label() == "main" && window.url().map(|u| bundled_url(&u)).unwrap_or(false) { start_quit(app, host.inner().clone()); }
}

// Enabled only by the explicit --smoke-ui command-line argument. The normal
// application never accepts a result or exits through this test entry point.
#[tauri::command]
fn smoke_result(app: AppHandle, window: WebviewWindow, host: tauri::State<'_, Arc<Host>>, payload: Value) -> Result<(), String> {
    if window.label() != "main" || !window.url().map(|u| bundled_url(&u)).unwrap_or(false) || host.smoke_path.is_none() {
        return Err("UI smoke mode is not enabled".into());
    }
    let before = payload["widthBefore"].as_f64().unwrap_or(0.0);
    let zoomed = payload["widthZoomed"].as_f64().unwrap_or(0.0);
    let restored = payload["widthRestored"].as_f64().unwrap_or(0.0);
    let passed = payload["panes"].as_u64() == Some(2) && payload["buttons"].as_u64().unwrap_or(0) >= 10 &&
        payload["platform"].as_str() == Some(if cfg!(windows) { "win32" } else { "linux" }) &&
        zoomed > 0.0 && before > zoomed + 80.0 &&
        (before / zoomed - interface_zoom(125) / interface_zoom(100)).abs() < 0.02 &&
        (restored - before).abs() <= 2.0 && payload["scaleBefore"].as_u64() == Some(100) &&
        payload["initialTheme"].as_str() == Some("green-dark") && payload["themeBefore"].as_str() == Some("green-dark") &&
        payload["language"].as_str() == Some("en") && payload["progressMotion"]["passed"].as_bool() == Some(true) && payload["error"].is_null();
    let host = host.inner().clone();
    if host.smoke_finished.swap(true, Ordering::SeqCst) { return Ok(()); }
    let path = host.smoke_path.as_ref().unwrap();
    fs::write(path, serde_json::to_vec_pretty(&json!({"passed":passed,"version":application_version(&app),"result":payload})).unwrap()).map_err(|e| e.to_string())?;
    thread::spawn(move || { let _ = host.call("_shutdown", vec![]); host.input.lock().unwrap().take(); let _ = host.child.lock().unwrap().wait(); app.exit(if passed { 0 } else { 2 }); });
    Ok(())
}

fn open_main_window(app: &AppHandle, host: &Arc<Host>) -> Result<(), String> {
    let startup_timeout = Duration::from_secs(30);
    if host.smoke_path.is_some() {
        let config = host.state_path.join("empty.conf"); fs::write(&config, "").map_err(|e| e.to_string())?;
        host.call_with_timeout("saveSettings", vec![json!({"language":"en","theme":"green-dark","autoCheckUpdates":false,"configPath":config.to_string_lossy(),"initialLocations":{"left":{"remote":null,"path":host.state_path.to_string_lossy()},"right":{"remote":null,"path":host.state_path.to_string_lossy()}}})], startup_timeout)?;
    }
    // This runs off the event-loop thread. The helper's one stdout reader
    // matches replies by ID, including preferences; it has no second consumer.
    // Reading migrated settings does not run rclone or wait for discovery.
    let preferences = host.call_with_timeout("_preferences", vec![], startup_timeout)?;
    host.store_settings(&preferences["settings"], preferences["resolvedLanguage"].as_str());
    let initial_theme = appearance_theme(&preferences["settings"]);
    let initial_script = format!("window.__rbnInitialAppearance = {};", json!({"theme":initial_theme}));
    let window = WebviewWindowBuilder::new(app, "main", WebviewUrl::App("index.html".into()))
        .title("Rclone Browser Next").inner_size(1280.0, 800.0).min_inner_size(880.0, 600.0)
        .visible(false).background_color(appearance_background(initial_theme))
        .theme(Some(if initial_theme.ends_with("-light") { tauri::Theme::Light } else { tauri::Theme::Dark }))
        .initialization_script(initial_script).initialization_script(include_str!("bridge.js")).on_navigation(bundled_url)
        .on_page_load(|window, payload| {
            if payload.event() == tauri::webview::PageLoadEvent::Finished {
                let state = window.state::<Arc<Host>>();
                if state.smoke_path.is_some() { let _ = window.eval(include_str!("smoke.js")); }
            }
        }).build().map_err(|e| e.to_string())?;
    let handle = app.clone();
    window.on_window_event(move |event| {
        if let tauri::WindowEvent::CloseRequested { api, .. } = event {
            api.prevent_close();
            let host = handle.state::<Arc<Host>>().inner().clone();
            start_quit(handle.clone(), host);
        }
    });
    window.set_zoom(interface_zoom(preferences["settings"]["interfaceScale"].as_u64().unwrap_or(100))).map_err(|e| e.to_string())?;
    // Windows/Linux apply the builder's background to both window and webview.
    // Show once after preparation, even when document loading later fails;
    // page-load callbacks must not keep reopening or raising this window.
    window.show().map_err(|e| e.to_string())?;
    Ok(())
}

fn main() {
    let arguments: Vec<String> = std::env::args().collect();
    let smoke_path = if arguments.len() == 3 && arguments[1] == "--smoke-ui" { Some(PathBuf::from(&arguments[2])) } else { None };
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_clipboard_manager::init())
        .invoke_handler(tauri::generate_handler![dispatch, request_quit, smoke_result])
        .setup(move |app| {
            let state_path = if let Some(path) = &smoke_path {
                let parent = path.parent().ok_or_else(|| std::io::Error::other("Choose a smoke result path with a parent directory"))?;
                fs::create_dir_all(parent)?;
                parent.join(format!("ui-smoke-state-{}", std::process::id()))
            } else { app.path().app_data_dir()? };
            let runtime = app.path().resource_dir()?.join("runtime");
            let host = Host::start(app.handle(), state_path, runtime, smoke_path.clone()).map_err(std::io::Error::other)?;
            app.manage(host.clone());
            let handle = app.handle().clone(); let startup_host = host.clone();
            thread::spawn(move || {
                if let Err(error) = open_main_window(&handle, &startup_host) {
                    startup_host.quitting.store(true, Ordering::SeqCst);
                    startup_host.input.lock().unwrap().take();
                    { let mut child = startup_host.child.lock().unwrap(); let _ = child.kill(); let _ = child.wait(); }
                    if let Some(path) = &startup_host.smoke_path {
                        if !startup_host.smoke_finished.swap(true, Ordering::SeqCst) {
                            let _ = fs::write(path, serde_json::to_vec_pretty(&json!({"passed":false,"error":error})).unwrap());
                        }
                    } else {
                        handle.dialog().message(error).title(startup_host.text("無法開啟 Rclone Browser Next", "Could not open Rclone Browser Next", "Rclone Browser Next を開けません"))
                            .kind(MessageDialogKind::Error).blocking_show();
                    }
                    handle.exit(2);
                }
            });
            if let Some(path) = smoke_path.clone() {
                let app = app.handle().clone();
                thread::spawn(move || {
                    thread::sleep(Duration::from_secs(45));
                    if !host.smoke_finished.swap(true, Ordering::SeqCst) {
                        let _ = fs::write(path, b"{\"passed\":false,\"error\":\"The native UI did not finish its smoke test within 45 seconds\"}\n");
                        let _ = host.call("_shutdown", vec![]); host.input.lock().unwrap().take(); app.exit(2);
                    }
                });
            }
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("Rclone Browser Next could not start")
        .run(|app, event| {
            if let tauri::RunEvent::ExitRequested { code: None, api, .. } = event {
                api.prevent_exit();
                if let Some(host) = app.try_state::<Arc<Host>>() { start_quit(app.clone(), host.inner().clone()); }
            }
        });
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn bundled_origin_is_exact() {
        for url in ["tauri://localhost", "tauri://localhost/", "tauri://localhost/index.html", "http://tauri.localhost/"] { assert!(bundled_url(&tauri::Url::parse(url).unwrap())); }
        for url in ["https://example.com/", "http://tauri.localhost.evil/", "tauri://localhost/other.html", "file:///tmp/index.html"] { assert!(!bundled_url(&tauri::Url::parse(url).unwrap())); }
    }
    #[test] fn external_sites_are_scoped() {
        assert!(external_url_allowed("https://rclone.org/downloads/"));
        assert!(external_url_allowed("https://github.com/jason840709/RcloneBrowserNext/releases"));
        for url in ["file:///etc/passwd", "https://github.com/another/repo", "https://evil.test/", "https://github.com/jason840709/RcloneBrowserNext-evil", "https://user@rclone.org/"] { assert!(!external_url_allowed(url)); }
    }
    #[test] fn native_only_methods_are_not_exposed() {
        for name in ["_shutdown", "_beginConfiguration", "_installRclone", "_exportTo", "getLogPath", "getJobReportPath"] { assert!(!METHODS.contains(&name)); }
    }
    #[test] fn displayed_scale_maps_to_the_retained_visual_sizes() {
        for (displayed, expected) in [(80, 0.7), (90, 0.8), (100, 0.9), (110, 1.0), (120, 1.1), (125, 1.15), (135, 1.25)] {
            assert!((interface_zoom(displayed) - expected).abs() < 0.000001);
        }
    }
    #[test] fn quit_is_silent_only_without_unfinished_or_failed_work() {
        let successful = json!({"activeJobs": false, "activeTools": false,
            "quit": {"activeJobCount": 0, "failedJobCount": 0, "unfinishedJobCount": 0, "requiresConfirmation": false}});
        assert!(!quit_needs_confirmation(&successful));
        for state in [
            json!({"activeJobs": true, "quit": {"requiresConfirmation": true}}),
            json!({"activeJobs": false, "quit": {"failedJobCount": 1, "requiresConfirmation": true}}),
            json!({"activeJobs": false, "quit": {"unfinishedJobCount": 1, "requiresConfirmation": true}}),
            json!({"activeTools": true, "quit": {"requiresConfirmation": false}}),
        ] { assert!(quit_needs_confirmation(&state)); }
        // A helper that has already exited has no running work to interrupt.
        assert!(!quit_needs_confirmation(&Value::Null));
    }
}
