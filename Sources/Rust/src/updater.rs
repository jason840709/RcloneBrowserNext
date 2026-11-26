//! Official release checks and a same-volume, checksum-verified rclone installer.
//! All replacement paths are validated before any candidate is executed.
use crate::{
    Result,
    accounts::{create_exclusive, read_regular, replace_file},
    process::{self, Context},
};
use regex::Regex;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    fs::{self, OpenOptions},
    io::{Cursor, Read, Write},
    path::{Component, Path, PathBuf},
    sync::{Arc, Mutex},
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;
use uuid::Uuid;

pub const APP_REPOSITORY: &str = "jason840709/RcloneBrowserNext";
pub const APP_RESPONSE_LIMIT: usize = 512 * 1024;
pub const PROXY_TLS_MESSAGE: &str = "App 更新檢查目前不支援 https:// 代理伺服器，請改用 http:// 或 socks5://（rclone 傳輸仍可使用 https:// 代理）。";
const BINARY_LIMIT: usize = 512 * 1024 * 1024;
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Release {
    pub major: u32,
    pub minor: u32,
    pub patch: u32,
}
impl Release {
    pub fn parse(text: &str) -> Option<Self> {
        let text = text.trim().replace("rclone ", "");
        let c = Regex::new(r"^v?([0-9]{1,5})\.([0-9]{1,5})\.([0-9]{1,5})$")
            .ok()?
            .captures(&text)?;
        Some(Self {
            major: c[1].parse().ok()?,
            minor: c[2].parse().ok()?,
            patch: c[3].parse().ok()?,
        })
    }
    pub fn stable_app(text: &str) -> Option<Self> {
        if !Regex::new(r"^v?(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})$")
            .ok()?
            .is_match(text)
        {
            return None;
        }
        Self::parse(text)
    }
    pub fn version(self) -> String {
        format!("v{}.{}.{}", self.major, self.minor, self.patch)
    }
}
#[derive(Debug, Clone)]
pub struct DownloadError {
    pub message: String,
    pub retryable: bool,
}
impl From<String> for DownloadError {
    fn from(message: String) -> Self {
        Self {
            message,
            retryable: false,
        }
    }
}
type DownloadResult<T> = std::result::Result<T, DownloadError>;
#[derive(Clone)]
pub struct Reply {
    pub data: Vec<u8>,
    pub status: u16,
    pub url: String,
    pub declared_size: Option<u64>,
}
pub type Fetcher = Arc<dyn Fn(&str, usize, &Value) -> DownloadResult<Reply> + Send + Sync>;
type EventHandler = Arc<dyn Fn(Value) + Send + Sync>;
pub struct Updater {
    work_dir: PathBuf,
    fetcher: Option<Fetcher>,
    events: Mutex<Option<EventHandler>>,
}
impl Updater {
    pub fn new(work_dir: PathBuf) -> Result<Self> {
        crate::storage::private_directory(&work_dir)?;
        Ok(Self {
            work_dir,
            fetcher: None,
            events: Mutex::new(None),
        })
    }
    pub fn with_fetcher(work_dir: PathBuf, fetcher: Fetcher) -> Result<Self> {
        let mut s = Self::new(work_dir)?;
        s.fetcher = Some(fetcher);
        Ok(s)
    }
    pub fn set_event_handler(&self, handler: EventHandler) {
        *self.events.lock().unwrap_or_else(|e| e.into_inner()) = Some(handler);
    }
    fn status(&self, phase: &str, message: &str) {
        let callback = self
            .events
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone();
        if let Some(cb) = callback {
            cb(json!({"phase":phase,"message":message}));
        }
    }
    pub fn handle(
        &self,
        method: &str,
        arguments: &[Value],
        context: &Context,
        settings: &Value,
    ) -> Result<Value> {
        match method {
            "_checkRclone" => {
                let manual = if let Some(v) = arguments.first() {
                    v.as_bool().ok_or("更新檢查方式 必須為開啟或關閉。")?
                } else {
                    true
                };
                if !manual && settings["autoCheckUpdates"] == false {
                    return Ok(json!({"status":"disabled"}));
                }
                let target = default_target(settings, context.binary.to_str())?;
                let app_parent = std::env::var("RBN_APP_BUNDLE_PARENT").ok();
                let current =
                    if !manual && (app_parent.is_some() || !executable(Path::new(&target))) {
                        executable(&context.binary).then_some(context.binary.as_path())
                    } else {
                        executable(Path::new(&target)).then_some(Path::new(&target))
                    };
                if !manual && current.is_none() {
                    return Ok(json!({"status":"notInstalled"}));
                }
                let mut result = self.check(
                    current,
                    settings["skippedRcloneVersion"]
                        .as_str()
                        .unwrap_or_default(),
                    manual,
                    settings,
                )?;
                let requires_choice = requires_directory_choice(
                    settings,
                    &target,
                    current.is_some(),
                    app_parent.as_deref(),
                );
                if app_parent.is_some()
                    && !requires_choice
                    && (result["status"] == "available"
                        || result["status"] == "notInstalled" && manual)
                {
                    validated_target(Path::new(&target))?;
                }
                if app_parent.is_some() {
                    result["requiresDirectoryChoice"] = json!(requires_choice);
                }
                result["targetPath"] = json!(target);
                result["settingsRevision"] = settings
                    .get("settingsRevision")
                    .cloned()
                    .unwrap_or(json!(0));
                Ok(result)
            }
            "_rcloneUpdateTarget" => {
                if !arguments.is_empty() {
                    return Err("更新檢查不需要額外參數。".into());
                }
                let target = default_target(settings, context.binary.to_str())?;
                validated_target(Path::new(&target))?;
                Ok(
                    json!({"targetPath":target,"settingsRevision":settings.get("settingsRevision").cloned().unwrap_or(json!(0))}),
                )
            }
            "_installRclone" => {
                let version = arguments
                    .first()
                    .and_then(Value::as_str)
                    .filter(|s| {
                        s.len() <= 32768 && !s.chars().any(|c| (c as u32) < 32 || c == '\u{7f}')
                    })
                    .ok_or("版本 格式不正確，不能包含控制字元。")?;
                let revision = arguments
                    .get(1)
                    .and_then(Value::as_u64)
                    .filter(|n| *n <= i64::MAX as u64)
                    .ok_or("設定版本 必須介於 0 與 9223372036854775807。")?;
                if revision != settings["settingsRevision"].as_u64().unwrap_or(0) {
                    return Err("設定已變更，請重新檢查更新。".into());
                }
                let target = default_target(settings, context.binary.to_str())?;
                let current = if executable(Path::new(&target)) {
                    Some(Path::new(&target))
                } else {
                    None
                };
                self.install(version, Path::new(&target), current, settings)
            }
            "checkAppUpdates" => {
                if !arguments.is_empty() {
                    return Err("更新檢查不需要額外參數。".into());
                }
                self.check_app(crate::VERSION, APP_REPOSITORY, settings)
            }
            _ => Err("不支援的更新操作。".into()),
        }
    }
    fn fetch(&self, url: &str, maximum: usize, settings: &Value, app: bool) -> Result<Reply> {
        for attempt in 0..3 {
            let result = if let Some(fetcher) = &self.fetcher {
                fetcher(url, maximum, settings)
            } else {
                fetch_http(url, maximum, settings, app)
            };
            match result {
                Ok(reply) => {
                    if app {
                        validate_app_reply(&reply, url, maximum)?;
                    } else {
                        validate_download_reply(&reply, maximum).map_err(|e| e.message)?;
                    }
                    return Ok(reply);
                }
                Err(e) if !app && attempt < 2 && e.retryable => {
                    self.status(
                        "retrying",
                        &format!("連線暫時失敗，正在重試（{}/2）…", attempt + 1),
                    );
                    thread::sleep(Duration::from_secs(attempt + 1));
                }
                Err(e) => return Err(e.message),
            }
        }
        Err("更新檢查未完成，請重試。".into())
    }
    pub fn check(
        &self,
        current_path: Option<&Path>,
        skipped: &str,
        manual: bool,
        settings: &Value,
    ) -> Result<Value> {
        self.status("checking", "正在檢查 rclone 版本…");
        let data = self
            .fetch(
                "https://downloads.rclone.org/version.txt",
                1024,
                settings,
                false,
            )?
            .data;
        let latest = std::str::from_utf8(&data)
            .ok()
            .and_then(Release::parse)
            .ok_or("rclone 官網回傳的版本資訊無法辨識，請稍後再試。")?;
        let local = if let Some(path) = current_path {
            self.version_of(path)?
        } else {
            String::new()
        };
        let current = Release::parse(&local);
        let status = if current_path.is_none() {
            "notInstalled"
        } else if current.is_none() {
            "unavailable"
        } else if current.is_some_and(|c| c >= latest) {
            "current"
        } else if !manual && Release::parse(skipped) == Some(latest) {
            "skipped"
        } else {
            "available"
        };
        self.status(
            "idle",
            if status == "current" {
                "rclone 已是最新版本。"
            } else {
                "版本檢查完成。"
            },
        );
        Ok(
            json!({"status":status,"currentVersion":local,"latestVersion":latest.version(),"path":current_path.map(|p|p.to_string_lossy().into_owned()).unwrap_or_default(),"message":if status=="unavailable"{"目前使用的是自訂或測試版 rclone；若要更換，請手動選擇要使用的穩定版。"}else{""}}),
        )
    }
    pub fn version_of(&self, path: &Path) -> Result<String> {
        let context = update_context(path, &self.work_dir, &json!({}));
        let args = vec![
            "version".into(),
            format!(
                "--config={}",
                self.work_dir.join(".version-probe.conf").display()
            ),
            "--ask-password=false".into(),
        ];
        let out = process::capture(
            &context,
            &args,
            4 * 1024 * 1024,
            Duration::from_secs(12),
            None,
        )?;
        if out.exit_code != 0 {
            return Err(format!(
                "無法執行這個 rclone：\n{}",
                String::from_utf8_lossy(&out.stderr)
                    .graphemes(true)
                    .take(800)
                    .collect::<String>()
            ));
        }
        let text = String::from_utf8_lossy(&out.stdout);
        let first = text.lines().next().unwrap_or_default();
        if !first.starts_with("rclone v") || first.graphemes(true).count() >= 120 {
            return Err("所選檔案沒有回傳有效的 rclone 版本。".into());
        }
        Ok(first.replacen("rclone ", "", 1))
    }
    pub fn install(
        &self,
        version: &str,
        target: &Path,
        current: Option<&Path>,
        settings: &Value,
    ) -> Result<Value> {
        let release = Release::parse(version).ok_or("更新版本格式不正確。")?;
        let target = validated_target(target)?;
        let parent = target
            .parent()
            .ok_or("請選擇有效的 rclone 執行檔或資料夾。")?;
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        if target.exists() {
            self.version_of(&target)?;
        }
        let architecture = hardware_architecture();
        let system = system_version()?;
        let stage = parent.join(format!(".rbn-update-{}", Uuid::new_v4()));
        let mut builder = fs::DirBuilder::new();
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            builder.mode(0o700);
        }
        builder.create(&stage).map_err(|e| e.to_string())?;
        let result = (|| {
            let candidate = stage.join(rclone_name());
            let mut verification = "HTTPS + SHA-256";
            self.status(
                "downloading",
                &format!("正在下載 rclone {}…", release.version()),
            );
            let use_selfupdate = current.filter(|p| executable(p)).is_some_and(|p| {
                self.version_of(p)
                    .ok()
                    .and_then(|s| Release::parse(&s))
                    .is_some_and(|r| {
                        r >= Release {
                            major: 1,
                            minor: 55,
                            patch: 0,
                        }
                    })
                    && verify_native(p, &architecture, system).is_ok()
            });
            if use_selfupdate {
                let context = update_context(current.unwrap(), &stage, settings);
                let arguments = vec![
                    "selfupdate".into(),
                    "--stable".into(),
                    "--version".into(),
                    release.version(),
                    "--output".into(),
                    candidate.to_string_lossy().into_owned(),
                    "--log-level".into(),
                    "INFO".into(),
                    format!("--config={}", stage.join(".selfupdate.conf").display()),
                    "--ask-password=false".into(),
                ];
                let out = process::capture(
                    &context,
                    &arguments,
                    4 * 1024 * 1024,
                    Duration::from_secs(300),
                    None,
                )?;
                if out.exit_code != 0 {
                    return Err(format!(
                        "下載未完成，原有的 rclone 維持不變。\n{}",
                        grapheme_suffix(&String::from_utf8_lossy(&out.stderr), 1600)
                    ));
                }
                verification = "rclone selfupdate: signed release checksum";
            } else {
                let archive_name = format!(
                    "rclone-{}-{}-{architecture}.zip",
                    release.version(),
                    archive_system()
                );
                let root = format!("https://downloads.rclone.org/{}/", release.version());
                let sums = self
                    .fetch(&(root.clone() + "SHA256SUMS"), 1024 * 1024, settings, false)?
                    .data;
                let expected = checksum(&archive_name, &sums)?;
                let archive = self
                    .fetch(&(root + &archive_name), 128 * 1024 * 1024, settings, false)?
                    .data;
                if sha256(&archive) != expected {
                    return Err("下載檔的 SHA-256 不符，已停止安裝。".into());
                }
                let member = format!(
                    "rclone-{}-{}-{architecture}/{}",
                    release.version(),
                    archive_system(),
                    rclone_name()
                );
                extract_candidate(archive, &member, &candidate)?;
            }
            let meta =
                fs::symlink_metadata(&candidate).map_err(|_| "下載的 rclone 執行檔不完整。")?;
            if !meta.is_file() || meta.len() <= 1024 || meta.len() >= BINARY_LIMIT as u64 {
                return Err("下載的 rclone 執行檔不完整。".into());
            }
            self.status("verifying", "正在檢查執行檔架構與版本…");
            let minimum = verify_native(&candidate, &architecture, system)?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                fs::set_permissions(&candidate, fs::Permissions::from_mode(0o755))
                    .map_err(|e| e.to_string())?;
            }
            if Release::parse(&self.version_of(&candidate)?) != Some(release) {
                return Err("下載檔回報的版本與選定版本不符，已停止更新。".into());
            }
            self.status("installing", "正在備份並替換 rclone…");
            let backup = commit(&candidate, &target, |p| {
                if Release::parse(&self.version_of(p)?) == Some(release) {
                    Ok(())
                } else {
                    Err("更新後的版本檢查失敗。".into())
                }
            })?;
            self.status(
                "complete",
                &format!("已更新至 rclone {}。", release.version()),
            );
            Ok(
                json!({"status":"updated","version":release.version(),"latestVersion":release.version(),"currentVersion":release.version(),"path":target,"backupPath":backup.unwrap_or_default(),"verification":verification,"minimumOS":minimum}),
            )
        })();
        let _ = fs::remove_dir_all(&stage);
        result
    }

    pub fn check_app(&self, current: &str, repository: &str, settings: &Value) -> Result<Value> {
        validate_repository(repository)?;
        let current = Release::stable_app(current).ok_or("App 版本格式不正確。")?;
        let endpoint = format!("https://api.github.com/repos/{repository}/releases/latest");
        let reply = self.fetch(&endpoint, APP_RESPONSE_LIMIT, settings, true)?;
        decode_app_reply(&reply, current, repository)
    }
}
fn requires_directory_choice(
    settings: &Value,
    target: &str,
    current_exists: bool,
    app_parent: Option<&str>,
) -> bool {
    !current_exists
        && settings["rclonePath"]
            .as_str()
            .unwrap_or_default()
            .is_empty()
        && app_parent.is_some_and(|parent| {
            Path::new(parent).join("Tools/rclone/rclone").to_str() == Some(target)
        })
        && target.starts_with("/Applications/")
}

pub fn default_target(settings: &Value, resolved: Option<&str>) -> Result<String> {
    if let Some(path) = settings["rclonePath"].as_str().filter(|s| !s.is_empty()) {
        return Ok(path.into());
    }
    if let Some(dir) = settings["rcloneDirectory"]
        .as_str()
        .filter(|s| !s.is_empty())
    {
        return Ok(Path::new(dir)
            .join(rclone_name())
            .to_string_lossy()
            .into_owned());
    }
    resolved
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
        .ok_or_else(|| "請先選擇存放 rclone 的資料夾。".into())
}
fn grapheme_suffix(text: &str, count: usize) -> String {
    if count == 0 {
        return String::new();
    }
    let at = text
        .grapheme_indices(true)
        .rev()
        .nth(count - 1)
        .map_or(0, |(i, _)| i);
    text[at..].to_owned()
}

fn rclone_name() -> &'static str {
    if cfg!(windows) {
        "rclone.exe"
    } else {
        "rclone"
    }
}
fn archive_system() -> &'static str {
    if cfg!(target_os = "macos") {
        "osx"
    } else if cfg!(windows) {
        "windows"
    } else {
        "linux"
    }
}
fn executable(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        path.metadata()
            .is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
    }
    #[cfg(not(unix))]
    {
        path.is_file()
    }
}
pub fn sha256(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
pub fn checksum(name: &str, data: &[u8]) -> Result<String> {
    let text = std::str::from_utf8(data).map_err(|_| "無法讀取官方校驗資訊。")?;
    let matches: Vec<_> = text
        .lines()
        .filter_map(|line| {
            let fields: Vec<_> = line.split([' ', '\t']).filter(|s| !s.is_empty()).collect();
            if fields.len() == 2
                && fields[1].trim_matches('*') == name
                && fields[0].len() == 64
                && fields[0].bytes().all(|b| b.is_ascii_hexdigit())
            {
                Some(fields[0].to_lowercase())
            } else {
                None
            }
        })
        .collect();
    if matches.len() != 1 {
        return Err("官方校驗表找不到唯一的對應檔案，已停止安裝。".into());
    }
    Ok(matches[0].clone())
}
pub fn validate_download_reply(reply: &Reply, maximum: usize) -> DownloadResult<()> {
    let url = url::Url::parse(&reply.url).map_err(|_| DownloadError {
        message: "更新回應並非來自 rclone 官方下載站。".into(),
        retryable: false,
    })?;
    if !official_download_url(&url) {
        return Err(DownloadError {
            message: "更新回應並非來自 rclone 官方下載站。".into(),
            retryable: false,
        });
    }
    if reply.status != 200 {
        return Err(DownloadError {
            message: format!(
                "rclone 官方下載站回傳 HTTP {}（{}）。請稍後重試。",
                reply.status,
                url.path_segments()
                    .and_then(|mut p| p.next_back())
                    .unwrap_or_default()
            ),
            retryable: matches!(reply.status, 408 | 429 | 500 | 502 | 503 | 504),
        });
    }
    if reply.declared_size.is_some_and(|n| n > maximum as u64) {
        return Err(DownloadError {
            message: format!(
                "下載大小超過上限（{} bytes，上限 {maximum} bytes），已停止下載。",
                reply.declared_size.unwrap()
            ),
            retryable: false,
        });
    }
    if reply.data.len() > maximum {
        return Err(DownloadError {
            message: "下載檔超過允許大小，已停止下載。".into(),
            retryable: false,
        });
    }
    Ok(())
}
fn official_download_url(url: &url::Url) -> bool {
    url.scheme() == "https"
        && url.host_str() == Some("downloads.rclone.org")
        && url.username().is_empty()
        && url.password().is_none()
        && url.port_or_known_default() == Some(443)
}
pub fn validate_app_reply(reply: &Reply, expected: &str, maximum: usize) -> Result<()> {
    if reply.url != expected {
        return Err("更新資訊轉址到其他位置，已停止檢查。".into());
    }
    match reply.status {
        200 | 404 => {}
        403 | 429 => return Err("GitHub 暫時限制更新檢查，請稍後再試。".into()),
        s => return Err(format!("GitHub 更新檢查失敗（HTTP {s}）。")),
    }
    if reply.declared_size.is_some_and(|n| n > maximum as u64) || reply.data.len() > maximum {
        return Err("GitHub 更新資訊超過允許大小。".into());
    }
    Ok(())
}
pub fn validate_repository(repository: &str) -> Result<()> {
    if Regex::new(r"^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9][A-Za-z0-9._-]{0,99}$")
        .unwrap()
        .is_match(repository)
    {
        Ok(())
    } else {
        Err("GitHub 專案位置不正確。".into())
    }
}
fn valid_published_date(value: &str) -> bool {
    // Foundation ISO8601DateFormatter's default parser differs from RFC3339:
    // no fractional seconds, lenient day overflow, and a parsed timezone prefix
    // can be followed by extra text. The Swift-recorded date matrix pins these
    // behaviors; release ownership/tag/bool/HTTPS validation remains separate.
    static PATTERN: std::sync::LazyLock<Regex> = std::sync::LazyLock::new(|| {
        Regex::new(r"^\s*([0-9]{4,})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:Z|[+-][0-9]{2})").expect("Foundation date grammar")
    });
    let Some(c) = PATTERN.captures(value) else {
        return false;
    };
    let component = |index: usize| c[index].parse::<u32>().ok();
    component(2).is_some_and(|n| (1..=12).contains(&n))
        && component(3).is_some_and(|n| (1..=31).contains(&n))
        && component(4).is_some_and(|n| n <= 24)
        && component(5).is_some_and(|n| n <= 59)
        && component(6).is_some_and(|n| n <= 59)
}

pub fn decode_app_reply(reply: &Reply, current: Release, repository: &str) -> Result<Value> {
    validate_repository(repository)?;
    validate_app_reply(
        reply,
        &format!("https://api.github.com/repos/{repository}/releases/latest"),
        APP_RESPONSE_LIMIT,
    )?;
    let installed = current.version().trim_start_matches('v').to_owned();
    if reply.status == 404 {
        return Ok(
            json!({"status":"unpublished","current":installed,"releaseURL":format!("https://github.com/{repository}/releases")}),
        );
    }
    let object: Value =
        serde_json::from_slice(&reply.data).map_err(|_| "GitHub 回傳的正式版本資訊不完整。")?;
    let tag = object["tag_name"]
        .as_str()
        .ok_or("GitHub 回傳的正式版本資訊不完整。")?;
    let latest = Release::stable_app(tag).ok_or("GitHub 回傳的正式版本資訊不完整。")?;
    let expected = format!("https://github.com/{repository}/releases/tag/{tag}");
    if object["draft"] != false
        || object["prerelease"] != false
        || object["published_at"]
            .as_str()
            .is_none_or(|s| !valid_published_date(s))
        || object["html_url"].as_str() != Some(&expected)
    {
        return Err("GitHub 回傳的正式版本資訊不完整。".into());
    }
    Ok(
        json!({"status":if current<latest{"available"}else{"current"},"current":installed,"latest":latest.version().trim_start_matches('v'),"releaseURL":expected}),
    )
}
pub fn validate_native_proxy(settings: &Value) -> Result<()> {
    if settings["proxyMode"] == "manual"
        && settings["httpsProxy"]
            .as_str()
            .and_then(|s| url::Url::parse(s).ok())
            .is_some_and(|u| u.scheme() == "https")
    {
        Err(PROXY_TLS_MESSAGE.into())
    } else {
        Ok(())
    }
}
pub fn proxy_environment(
    settings: &Value,
    source: BTreeMap<String, String>,
) -> BTreeMap<String, String> {
    let mut environment: BTreeMap<_, _> = source
        .into_iter()
        .filter(|(k, _)| !k.to_uppercase().starts_with("RCLONE_"))
        .collect();
    if settings["proxyMode"] == "manual" {
        environment.retain(|k, _| {
            !["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"]
                .contains(&k.to_uppercase().as_str())
        });
        for (key, var) in [
            ("httpProxy", "HTTP_PROXY"),
            ("httpsProxy", "HTTPS_PROXY"),
            ("noProxy", "NO_PROXY"),
        ] {
            if let Some(value) = settings[key].as_str().filter(|v| !v.is_empty()) {
                environment.insert(var.into(), value.into());
            }
        }
    }
    environment
}
fn update_context(binary: &Path, directory: &Path, settings: &Value) -> Context {
    let mut environment = proxy_environment(settings, std::env::vars().collect());
    for key in ["TMPDIR", "TMP", "TEMP"] {
        environment.insert(key.into(), directory.to_string_lossy().into_owned());
    }
    Context {
        binary: binary.to_owned(),
        arguments: vec![],
        environment,
        work_dir: directory.to_owned(),
    }
}
fn manual_proxy(settings: &Value) -> Result<Option<ureq::Proxy>> {
    validate_native_proxy(settings)?;
    let Some(value) = settings["httpsProxy"].as_str().filter(|s| !s.is_empty()) else {
        return Ok(None);
    };
    let u = url::Url::parse(value).map_err(|_| "代理伺服器格式不正確。")?;
    if !u.username().is_empty()
        || u.password().is_some()
        || u.query().is_some()
        || u.fragment().is_some()
        || u.host_str().is_none()
        || !matches!(u.path(), "" | "/")
    {
        return Err("代理伺服器格式不正確。".into());
    }
    let proto = match u.scheme() {
        "http" => ureq::ProxyProtocol::Http,
        "socks5" => ureq::ProxyProtocol::Socks5,
        "socks5h" => ureq::ProxyProtocol::Socks5h,
        _ => return Err("代理伺服器格式不正確。".into()),
    };
    let mut b = ureq::Proxy::builder(proto)
        .host(u.host_str().unwrap())
        .port(
            u.port()
                .unwrap_or(if u.scheme() == "http" { 80 } else { 1080 }),
        );
    for pattern in settings["noProxy"]
        .as_str()
        .unwrap_or_default()
        .split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        b = b.no_proxy(pattern);
    }
    b.build()
        .map(Some)
        .map_err(|_| "代理伺服器格式不正確。".into())
}
fn network_error(error: ureq::Error) -> DownloadError {
    let retryable = match &error {
        ureq::Error::Timeout(_) | ureq::Error::HostNotFound | ureq::Error::ConnectionFailed => true,
        ureq::Error::Io(e) => matches!(
            e.kind(),
            std::io::ErrorKind::TimedOut
                | std::io::ErrorKind::ConnectionRefused
                | std::io::ErrorKind::ConnectionReset
                | std::io::ErrorKind::ConnectionAborted
                | std::io::ErrorKind::NotConnected
                | std::io::ErrorKind::UnexpectedEof
        ),
        _ => false,
    };
    DownloadError {
        message: format!("更新連線失敗：{error}"),
        retryable,
    }
}
fn fetch_http(initial: &str, maximum: usize, settings: &Value, app: bool) -> DownloadResult<Reply> {
    validate_native_proxy(settings).map_err(DownloadError::from)?;
    let mut current =
        url::Url::parse(initial).map_err(|_| DownloadError::from("更新網址不正確。".to_owned()))?;
    for redirects in 0..=8 {
        if (!app && !official_download_url(&current)) || (app && current.as_str() != initial) {
            return Err(DownloadError::from(
                if app {
                    "更新資訊轉址到其他位置，已停止檢查。"
                } else {
                    "更新網址不在 rclone 官方下載站。"
                }
                .to_owned(),
            ));
        }
        let proxies = if settings["proxyMode"] == "manual" {
            vec![manual_proxy(settings).map_err(DownloadError::from)?]
        } else {
            system_proxies(&current).map_err(DownloadError::from)?
        };
        let mut final_error = None;
        let mut response = None;
        for proxy in proxies {
            let config = ureq::Agent::config_builder()
                .proxy(proxy)
                .http_status_as_error(false)
                .max_redirects(0)
                .max_redirects_will_error(false)
                .timeout_connect(Some(Duration::from_secs(20)))
                .timeout_global(Some(Duration::from_secs(if app {
                    35
                } else if maximum > 1024 * 1024 {
                    240
                } else {
                    45
                })))
                .build();
            let agent = ureq::Agent::new_with_config(config);
            let mut request = agent
                .get(current.as_str())
                .header(
                    "User-Agent",
                    format!("RcloneBrowserNext/{}", crate::VERSION),
                )
                .header("Accept-Encoding", "identity");
            if app {
                request = request
                    .header("Accept", "application/vnd.github+json")
                    .header("X-GitHub-Api-Version", "2026-03-10");
            }
            match request.call() {
                Ok(r) => {
                    response = Some(r);
                    break;
                }
                Err(e) => final_error = Some(network_error(e)),
            }
        }
        let mut response = response.ok_or_else(|| {
            final_error.unwrap_or(DownloadError {
                message: "無法取得系統代理伺服器設定。".into(),
                retryable: false,
            })
        })?;
        let status = response.status().as_u16();
        if matches!(status, 301 | 302 | 303 | 307 | 308) {
            if app {
                return Err(DownloadError::from(
                    "更新資訊轉址到其他位置，已停止檢查。".to_owned(),
                ));
            }
            if redirects == 8 {
                return Err(DownloadError::from(
                    "官方下載站轉址過多，已停止下載。".to_owned(),
                ));
            }
            let location = response
                .headers()
                .get("location")
                .and_then(|h| h.to_str().ok())
                .ok_or_else(|| DownloadError::from("官方下載站回傳無效轉址。".to_owned()))?;
            let next = current
                .join(location)
                .map_err(|_| DownloadError::from("官方下載站回傳無效轉址。".to_owned()))?;
            if !official_download_url(&next) {
                return Err(DownloadError::from(
                    "官方下載站轉址到未允許的位置，已停止下載。".to_owned(),
                ));
            }
            current = next;
            continue;
        }
        let declared_size = response
            .headers()
            .get("content-length")
            .and_then(|h| h.to_str().ok())
            .and_then(|s| s.parse().ok());
        let mut reply = Reply {
            data: vec![],
            status,
            url: current.to_string(),
            declared_size,
        };
        if app {
            validate_app_reply(&reply, initial, maximum).map_err(DownloadError::from)?;
        } else {
            validate_download_reply(&reply, maximum)?;
        }
        response
            .body_mut()
            .as_reader()
            .take(maximum as u64 + 1)
            .read_to_end(&mut reply.data)
            .map_err(|e| DownloadError {
                message: format!("下載未完成：{e}"),
                retryable: matches!(
                    e.kind(),
                    std::io::ErrorKind::TimedOut
                        | std::io::ErrorKind::ConnectionReset
                        | std::io::ErrorKind::UnexpectedEof
                ),
            })?;
        if reply.data.len() > maximum {
            return Err(DownloadError::from(
                if app {
                    "GitHub 更新資訊超過允許大小。"
                } else {
                    "下載檔超過允許大小，已停止下載。"
                }
                .to_owned(),
            ));
        }
        return Ok(reply);
    }
    Err(DownloadError::from("更新檢查未完成，請重試。".to_owned()))
}
#[cfg(not(target_os = "macos"))]
fn system_proxies(url: &url::Url) -> Result<Vec<Option<ureq::Proxy>>> {
    Ok(vec![environment_proxy(url, &std::env::vars().collect())?])
}
#[cfg(target_os = "macos")]
fn system_proxies(url: &url::Url) -> Result<Vec<Option<ureq::Proxy>>> {
    mac_proxy::resolve(url.as_str())
}

/// FoundationNetworking delegates proxy selection to libcurl on non-Apple
/// platforms. Its scheme-specific proxy overrides ALL_PROXY; lower-case keys
/// override upper-case keys, and Windows registry settings are not consulted.
#[cfg(any(test, not(target_os = "macos")))]
fn environment_proxy(
    url: &url::Url,
    environment: &BTreeMap<String, String>,
) -> Result<Option<ureq::Proxy>> {
    let lookup = |names: &[&str]| {
        names
            .iter()
            .find_map(|name| environment.get(*name).filter(|v| !v.is_empty()))
    };
    let Some(value) = lookup(&["https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY"]) else {
        return Ok(None);
    };
    if let Some(exceptions) = lookup(&["no_proxy", "NO_PROXY"]) {
        let host = url
            .host_str()
            .unwrap_or_default()
            .trim_matches(['[', ']'])
            .to_lowercase();
        if exceptions.split(',').map(str::trim).any(|pattern| {
            let pattern = pattern.trim_start_matches('.').to_lowercase();
            pattern == "*"
                || !pattern.is_empty()
                    && (host == pattern || host.ends_with(&(".".to_owned() + &pattern)))
        }) {
            return Ok(None);
        }
    }
    let normalized = if value.contains("://") {
        value.clone()
    } else {
        format!("http://{value}")
    };
    // Parse protocol exactly as the HTTP library does, then attach explicit
    // no-proxy handling above without mutating process-wide environment.
    ureq::Proxy::new(&normalized)
        .map(Some)
        .map_err(|_| "代理伺服器格式不正確。".into())
}

pub fn validated_target(path: &Path) -> Result<PathBuf> {
    validated_target_with_protected(path, &protected_directories())
}
fn validated_target_with_protected(path: &Path, protected: &[String]) -> Result<PathBuf> {
    let raw = path
        .to_str()
        .ok_or("請選擇有效的 rclone 執行檔或資料夾。")?;
    if !crate::models::absolute_local(raw) || raw.ends_with('/') || path.file_name().is_none() {
        return Err("請選擇有效的 rclone 執行檔或資料夾。".into());
    }
    let initial = PathBuf::from(crate::models::standardized(raw)?);
    let parent = initial
        .parent()
        .ok_or("請選擇有效的 rclone 執行檔或資料夾。")?;
    let resolved = public_io_path(resolve_parent(parent)?.join(initial.file_name().unwrap()))?;
    let managed = protected_target_name(
        resolved.to_str().ok_or("無法辨識本機路徑。")?,
        protected,
        cfg!(windows),
    )?;
    if resolved.components().any(|c|matches!(c,Component::Normal(n) if n.to_string_lossy().to_lowercase().ends_with(".app"))) || managed {
        return Err("此位置由 App 或套件管理工具管理。請另外選擇自己管理的資料夾來存放並更新 rclone。".into());
    }
    match fs::symlink_metadata(&initial) {
        Ok(m) if !m.is_file() => {
            return Err("不能直接替換符號連結或資料夾。請選擇獨立的 rclone 執行檔。".into());
        }
        Err(e) if e.kind() != std::io::ErrorKind::NotFound => return Err(e.to_string()),
        _ => {}
    }
    Ok(resolved)
}
// Windows canonicalize returns verbatim paths. Only remove that API prefix
// and normalize separators: casing and Unicode spelling remain filesystem data.
fn windows_path_spelling(raw: &str) -> Result<String> {
    let normalized = raw.replace('\\', "/");
    let Some(rest) = normalized.strip_prefix("//?/") else {
        return Ok(normalized);
    };
    if rest
        .get(..4)
        .is_some_and(|s| s.eq_ignore_ascii_case("UNC/"))
    {
        return Ok(format!("//{}", &rest[4..]));
    }
    let b = rest.as_bytes();
    if b.len() >= 3 && b[0].is_ascii_alphabetic() && b[1] == b':' && b[2] == b'/' {
        return Ok(rest.to_owned());
    }
    Err("請選擇有效的 rclone 執行檔或資料夾。".into())
}
fn public_io_path(path: PathBuf) -> Result<PathBuf> {
    #[cfg(windows)]
    {
        return windows_path_spelling(path.to_str().ok_or("無法辨識本機路徑。")?)
            .map(PathBuf::from);
    }
    #[cfg(not(windows))]
    {
        Ok(path)
    }
}
fn protected_target_name(target: &str, roots: &[String], windows: bool) -> Result<bool> {
    let key = |raw: &str| -> Result<String> {
        let path = if windows {
            windows_path_spelling(raw)?
        } else {
            raw.replace('\\', "/")
        };
        let lowered = path.trim_end_matches('/').to_lowercase();
        Ok(if windows {
            lowered.nfc().collect()
        } else {
            lowered
        })
    };
    let target = key(target)?;
    for root in roots {
        let root = key(root)?;
        if target == root || target.starts_with(&(root + "/")) {
            return Ok(true);
        }
    }
    Ok(false)
}
fn resolve_parent(path: &Path) -> Result<PathBuf> {
    let mut current = path;
    let mut missing = vec![];
    let mut resolved = loop {
        match fs::canonicalize(current) {
            Ok(p) => break p,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                if fs::symlink_metadata(current).is_ok() {
                    return Err("無法解析本機符號連結。".into());
                }
                missing.push(current.file_name().ok_or("無法解析本機路徑。")?.to_owned());
                current = current.parent().ok_or("無法解析本機路徑。")?;
            }
            Err(e) => return Err(e.to_string()),
        }
    };
    for p in missing.iter().rev() {
        resolved.push(p);
    }
    public_io_path(resolved)
}
fn protected_directories() -> Vec<String> {
    #[cfg(windows)]
    {
        std::env::vars()
            .filter(|(k, _)| {
                ["SYSTEMROOT", "PROGRAMFILES", "PROGRAMFILES(X86)"]
                    .contains(&k.to_uppercase().as_str())
            })
            .map(|(_, v)| v)
            .collect()
    }
    #[cfg(not(windows))]
    {
        [
            "/System",
            "/Library",
            "/usr",
            "/bin",
            "/sbin",
            "/opt/homebrew",
            "/opt/local",
        ]
        .map(str::to_owned)
        .to_vec()
    }
}
fn extract_candidate(archive: Vec<u8>, member: &str, candidate: &Path) -> Result<()> {
    let mut zip = zip::ZipArchive::new(Cursor::new(archive))
        .map_err(|_| "rclone 解壓縮失敗，原本的版本保持不變。")?;
    let mut matching = vec![];
    for i in 0..zip.len() {
        let file = zip
            .by_index(i)
            .map_err(|_| "rclone 解壓縮失敗，原本的版本保持不變。")?;
        if file.name() == member {
            matching.push(i);
        }
    }
    if matching.len() != 1 {
        return Err("下載檔裡沒有唯一的 rclone 執行檔。".into());
    }
    let mut input = zip
        .by_index(matching[0])
        .map_err(|_| "rclone 解壓縮失敗，原本的版本保持不變。")?;
    if !input.is_file()
        || input.size() <= 1024
        || input.size() >= BINARY_LIMIT as u64
        || input
            .unix_mode()
            .is_some_and(|m| m & 0o170000 != 0 && m & 0o170000 != 0o100000)
    {
        return Err("下載的 rclone 執行檔不完整。".into());
    }
    let expected = input.size();
    let mut output = create_exclusive(candidate)?;
    let copied = std::io::copy(&mut input.by_ref().take(BINARY_LIMIT as u64), &mut output)
        .map_err(|_| "rclone 解壓縮失敗，原本的版本保持不變。")?;
    if copied != expected {
        return Err("下載的 rclone 執行檔不完整。".into());
    }
    output.sync_all().map_err(|e| e.to_string())
}
/// Same-volume replacement, SHA-256 checked backup, conflict check, and verified
/// rollback. No hard-link based locking or temporary-name promotion is used.
pub fn commit(
    candidate: &Path,
    target: &Path,
    validate: impl FnOnce(&Path) -> Result<()>,
) -> Result<Option<String>> {
    let target = validated_target(target)?;
    let parent = target
        .parent()
        .ok_or("更新暫存檔不在所選 rclone 資料夾內。")?;
    if candidate
        .parent()
        .and_then(Path::parent)
        .map(resolve_parent)
        .transpose()?
        .as_deref()
        != Some(parent)
    {
        return Err("更新暫存檔不在所選 rclone 資料夾內。".into());
    }
    let original = read_regular(&target, BINARY_LIMIT)?;
    let original_hash = original.as_deref().map(sha256);
    let mut backup = None;
    if let Some(prior) = &original {
        let folder = parent.join("Backups");
        match fs::symlink_metadata(&folder) {
            Ok(m) if !m.is_dir() => return Err("備份位置不是一般資料夾，已停止更新。".into()),
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => return Err(e.to_string()),
            _ => {}
        }
        crate::storage::private_directory(&folder)?;
        let created = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs_f64();
        let backup_folder = folder.join(format!("rbn-{}-{}", created as u64, Uuid::new_v4()));
        crate::storage::private_directory(&backup_folder)?;
        let copy = backup_folder.join(rclone_name());
        let mut writer = create_exclusive(&copy)?;
        writer.write_all(prior).map_err(|e| e.to_string())?;
        writer.sync_all().map_err(|e| e.to_string())?;
        drop(writer);
        let permissions = fs::metadata(&target)
            .map_err(|e| e.to_string())?
            .permissions();
        fs::set_permissions(&copy, permissions).map_err(|e| e.to_string())?;
        if read_regular(&copy, BINARY_LIMIT)?.as_deref().map(sha256) != original_hash {
            return Err("舊版備份驗證失敗，已停止更新。".into());
        }
        crate::storage::atomic_json(
            &backup_folder.join("backup.json"),
            &json!({"owner":"Rclone Browser Next","target":target,"created":created,"sha256":original_hash.as_ref().unwrap()}),
        )?;
        backup = Some(copy);
    }
    validated_target(&target)?;
    if read_regular(&target, BINARY_LIMIT)?.as_deref().map(sha256) != original_hash {
        return Err(if original.is_some() {
            "rclone 在更新期間被其他程式更動，已停止替換。"
        } else {
            "這個位置剛出現另一個檔案，已停止替換。"
        }
        .into());
    }
    if !fs::symlink_metadata(candidate).is_ok_and(|m| m.is_file()) {
        return Err("下載的 rclone 執行檔不完整。".into());
    }
    OpenOptions::new()
        .write(true)
        .open(candidate)
        .and_then(|f| f.sync_all())
        .map_err(|e| e.to_string())?;
    replace_file(candidate, &target)?;
    if let Err(validation) = validate(&target) {
        if let Some(backup) = &backup {
            let restore = candidate.parent().unwrap().join("restore");
            let result = (|| {
                let bytes = read_regular(backup, BINARY_LIMIT)?.ok_or("舊版備份已不存在。")?;
                let mut writer = create_exclusive(&restore)?;
                writer.write_all(&bytes).map_err(|e| e.to_string())?;
                writer.sync_all().map_err(|e| e.to_string())?;
                drop(writer);
                fs::set_permissions(
                    &restore,
                    fs::metadata(backup)
                        .map_err(|e| e.to_string())?
                        .permissions(),
                )
                .map_err(|e| e.to_string())?;
                replace_file(&restore, &target)?;
                Ok::<_, String>(())
            })();
            if let Err(e) = result {
                return Err(format!(
                    "新版驗證未通過，且自動還原失敗。\n舊版備份位置：{}\n{e}",
                    backup.display()
                ));
            }
            return Err(format!(
                "新版驗證未通過，已自動還原原有的 rclone。\n{validation}"
            ));
        }
        if let Err(e) = fs::remove_file(&target) {
            return Err(format!(
                "新安裝的 rclone 驗證失敗，且無法移除。\n檔案位置：{}\n{e}",
                target.display()
            ));
        }
        return Err(format!("新安裝的 rclone 驗證失敗，已移除。\n{validation}"));
    }
    prune_backups(parent, &target);
    Ok(backup.map(|p| p.to_string_lossy().into_owned()))
}
fn prune_backups(parent: &Path, target: &Path) {
    let folder = parent.join("Backups");
    let Ok(entries) = fs::read_dir(&folder) else {
        return;
    };
    let mut owned = vec![];
    for entry in entries.flatten() {
        let path = entry.path();
        if !entry.file_name().to_string_lossy().starts_with("rbn-")
            || !fs::symlink_metadata(&path).is_ok_and(|m| m.is_dir())
        {
            continue;
        }
        let Some(manifest) = read_regular(&path.join("backup.json"), 65536)
            .ok()
            .flatten()
            .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
        else {
            continue;
        };
        if manifest["owner"] != "Rclone Browser Next"
            || manifest["target"].as_str() != target.to_str()
        {
            continue;
        }
        if let Some(time) = manifest["created"].as_f64().filter(|t| t.is_finite()) {
            owned.push((path, time));
        }
    }
    owned.sort_by(|a, b| b.1.total_cmp(&a.1));
    for (path, _) in owned.into_iter().skip(2) {
        let _ = fs::remove_dir_all(path);
    }
}
pub fn hardware_architecture() -> String {
    #[cfg(target_os = "macos")]
    {
        let mut arm = 0i32;
        let mut size = std::mem::size_of::<i32>();
        let name = c"hw.optional.arm64";
        let ok = unsafe {
            libc::sysctlbyname(
                name.as_ptr(),
                &mut arm as *mut _ as _,
                &mut size,
                std::ptr::null_mut(),
                0,
            )
        };
        if ok == 0 && arm == 1 {
            return "arm64".into();
        }
    }
    if cfg!(target_arch = "aarch64") {
        "arm64".into()
    } else {
        "amd64".into()
    }
}
fn system_version() -> Result<[u32; 3]> {
    #[cfg(target_os = "macos")]
    {
        let mut buffer = [0u8; 128];
        let mut length = buffer.len();
        let ok = unsafe {
            libc::sysctlbyname(
                c"kern.osproductversion".as_ptr(),
                buffer.as_mut_ptr() as _,
                &mut length,
                std::ptr::null_mut(),
                0,
            )
        };
        if ok != 0 {
            return Err("無法確認目前的 macOS 版本，已停止更新。".into());
        }
        let text = std::str::from_utf8(&buffer[..length.min(buffer.len())])
            .map_err(|_| "無法確認目前的 macOS 版本，已停止更新。")?
            .trim_matches('\0');
        let mut version = [0; 3];
        for (i, p) in text.split('.').take(3).enumerate() {
            version[i] = p
                .parse()
                .map_err(|_| "無法確認目前的 macOS 版本，已停止更新。")?;
        }
        Ok(version)
    }
    #[cfg(not(target_os = "macos"))]
    {
        Ok([0, 0, 0])
    }
}
pub fn verify_native(path: &Path, architecture: &str, system: [u32; 3]) -> Result<String> {
    let bytes = read_regular(path, BINARY_LIMIT)?.ok_or("找不到下載的 rclone 執行檔。")?;
    #[cfg(target_os = "macos")]
    {
        verify_macho(&bytes, architecture, system)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = system;
        if bytes.len() < 64 {
            return Err("下載的 rclone 執行檔不完整。".into());
        }
        #[cfg(windows)]
        {
            if &bytes[..2] != b"MZ" {
                return Err("下載檔不是 Windows 執行檔。".into());
            }
            let offset = u32le(&bytes, 60).ok_or("Windows 執行檔標頭不完整。")? as usize;
            if !(64..=1024 * 1024).contains(&offset)
                || offset + 26 > bytes.len()
                || &bytes[offset..offset + 4] != b"PE\0\0"
                || &bytes[offset + 24..offset + 26] != [0x0b, 0x02]
            {
                return Err("下載檔不是有效的 64 位元 Windows 執行檔。".into());
            }
            let machine = u16::from_le_bytes([bytes[offset + 4], bytes[offset + 5]]);
            if machine
                != if architecture == "arm64" {
                    0xaa64
                } else {
                    0x8664
                }
            {
                return Err("rclone 執行檔架構與這台電腦不符。".into());
            }
        }
        #[cfg(not(windows))]
        {
            if &bytes[..4] != b"\x7fELF" || bytes[4] != 2 || bytes[5] != 1 {
                return Err("下載檔不是有效的 64 位元 Linux 執行檔。".into());
            }
            let machine = u16::from_le_bytes([bytes[18], bytes[19]]);
            if machine != if architecture == "arm64" { 183 } else { 62 } {
                return Err("rclone 執行檔架構與這台電腦不符。".into());
            }
        }
        Ok(String::new())
    }
}
fn u32le(data: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_le_bytes(
        data.get(at..at.checked_add(4)?)?.try_into().ok()?,
    ))
}
fn u32be(data: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_be_bytes(
        data.get(at..at.checked_add(4)?)?.try_into().ok()?,
    ))
}
fn u64be(data: &[u8], at: usize) -> Option<u64> {
    Some(u64::from_be_bytes(
        data.get(at..at.checked_add(8)?)?.try_into().ok()?,
    ))
}
pub fn verify_macho(bytes: &[u8], architecture: &str, system: [u32; 3]) -> Result<String> {
    if bytes.len() < 32 {
        return Err("rclone 不是有效的 Mac 執行檔。".into());
    }
    let cpu = if architecture == "arm64" {
        0x0100000c
    } else {
        0x01000007
    };
    let mut offset = 0usize;
    let mut size = bytes.len();
    let magic = u32be(bytes, 0).unwrap();
    if matches!(magic, 0xcafebabe | 0xcafebabf) {
        let count = u32be(bytes, 4).unwrap_or(0) as usize;
        let stride = if magic == 0xcafebabf { 32 } else { 20 };
        if count == 0 || count > 32 || bytes.len() < 8 + count * stride {
            return Err("Mac 執行檔的架構表不完整。".into());
        }
        let mut found = false;
        for i in 0..count {
            let at = 8 + i * stride;
            if u32be(bytes, at) == Some(cpu) {
                let (o, s) = if stride == 32 {
                    (
                        u64be(bytes, at + 8).unwrap(),
                        u64be(bytes, at + 16).unwrap(),
                    )
                } else {
                    (
                        u32be(bytes, at + 8).unwrap() as u64,
                        u32be(bytes, at + 12).unwrap() as u64,
                    )
                };
                offset = usize::try_from(o).map_err(|_| "Mac 執行檔的架構範圍不正確。")?;
                size = usize::try_from(s).map_err(|_| "Mac 執行檔的架構範圍不正確。")?;
                found = true;
                break;
            }
        }
        if !found {
            return Err("新版 rclone 不包含這台 Mac 的處理器架構。".into());
        }
    }
    if offset > bytes.len() || size > bytes.len() - offset || size < 32 {
        return Err("Mac 執行檔的架構範圍不正確。".into());
    }
    let data = &bytes[offset..offset + size];
    if u32le(data, 0) != Some(0xfeedfacf)
        || u32le(data, 4) != Some(cpu)
        || u32le(data, 12) != Some(2)
    {
        return Err("新版 rclone 的執行檔格式或架構不符。".into());
    }
    let count = u32le(data, 16).unwrap_or(0) as usize;
    let length = u32le(data, 20).unwrap_or(0) as usize;
    if count == 0 || count > 4096 || !(8..=16 * 1024 * 1024).contains(&length) || length > size - 32
    {
        return Err("Mac 執行檔的載入資訊不完整。".into());
    }
    let commands = &data[32..32 + length];
    let mut at = 0usize;
    let mut minimum: Option<[u32; 3]> = None;
    for _ in 0..count {
        let command = u32le(commands, at).ok_or("Mac 執行檔的載入資訊已截斷。")?;
        let len = u32le(commands, at + 4).ok_or("Mac 執行檔的載入資訊已截斷。")? as usize;
        if len < 8 || len % 4 != 0 || len > commands.len() - at {
            return Err("Mac 執行檔包含無效載入指令。".into());
        }
        let packed = if command == 0x32 {
            if len < 24 || u32le(commands, at + 8) != Some(1) {
                return Err("新版 rclone 的目標平台不是 macOS。".into());
            }
            u32le(commands, at + 12)
        } else if command == 0x24 {
            if len < 16 {
                return Err("macOS 最低版本資訊不完整。".into());
            }
            u32le(commands, at + 8)
        } else {
            None
        };
        if let Some(v) = packed {
            let v = [v >> 16, (v >> 8) & 255, v & 255];
            minimum = Some(minimum.map_or(v, |m| m.max(v)));
        }
        at += len;
    }
    if at != commands.len() || minimum.is_none() {
        return Err("無法確認新版 rclone 的 macOS 需求，已保留原版。".into());
    }
    let minimum = minimum.unwrap();
    let label = format!("{}.{}.{}", minimum[0], minimum[1], minimum[2]);
    if minimum > system {
        return Err(format!(
            "這份官方 rclone 需要 macOS {label} 以上（高於目前系統版本）。已保留原有的 rclone，請改選其他相容版本。"
        ));
    }
    Ok(label)
}

/// Read Apple's per-URL proxy decision, including PAC, without changing global
/// settings or consulting credential stores. The returned alternatives preserve
/// the system's order and include direct access only when explicitly advertised.
#[cfg(target_os = "macos")]
mod mac_proxy {
    use super::*;
    use std::{
        ffi::{CString, c_char, c_void},
        ptr,
        time::Instant,
    };
    type CF = *const c_void;
    #[repr(C)]
    struct StreamContext {
        version: isize,
        info: *mut c_void,
        retain: Option<unsafe extern "C" fn(*const c_void) -> *const c_void>,
        release: Option<unsafe extern "C" fn(*const c_void)>,
        description: Option<unsafe extern "C" fn(*const c_void) -> CF>,
    }
    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFRelease(value: CF);
        fn CFRetain(value: CF) -> CF;
        fn CFEqual(a: CF, b: CF) -> u8;
        fn CFStringCreateWithCString(allocator: CF, text: *const c_char, encoding: u32) -> CF;
        fn CFStringGetCString(value: CF, buffer: *mut c_char, size: isize, encoding: u32) -> u8;
        fn CFURLCreateWithString(allocator: CF, text: CF, base: CF) -> CF;
        fn CFArrayGetCount(value: CF) -> isize;
        fn CFArrayGetValueAtIndex(value: CF, index: isize) -> CF;
        fn CFDictionaryGetValue(value: CF, key: CF) -> CF;
        fn CFNumberGetValue(value: CF, kind: isize, result: *mut c_void) -> u8;
        fn CFRunLoopGetCurrent() -> CF;
        fn CFRunLoopAddSource(run_loop: CF, source: CF, mode: CF);
        fn CFRunLoopRunInMode(mode: CF, seconds: f64, return_after_source: u8) -> i32;
        fn CFRunLoopSourceInvalidate(source: CF);
        static kCFRunLoopDefaultMode: CF;
    }
    #[link(name = "CFNetwork", kind = "framework")]
    unsafe extern "C" {
        fn CFNetworkCopySystemProxySettings() -> CF;
        fn CFNetworkCopyProxiesForURL(url: CF, settings: CF) -> CF;
        fn CFNetworkCopyProxiesForAutoConfigurationScript(
            script: CF,
            target: CF,
            error: *mut CF,
        ) -> CF;
        fn CFNetworkExecuteProxyAutoConfigurationURL(
            pac: CF,
            target: CF,
            callback: unsafe extern "C" fn(*mut c_void, CF, CF),
            context: *mut StreamContext,
        ) -> CF;
        static kCFProxyTypeKey: CF;
        static kCFProxyHostNameKey: CF;
        static kCFProxyPortNumberKey: CF;
        static kCFProxyAutoConfigurationURLKey: CF;
        static kCFProxyAutoConfigurationJavaScriptKey: CF;
        static kCFProxyUsernameKey: CF;
        static kCFProxyPasswordKey: CF;
        static kCFProxyTypeNone: CF;
        static kCFProxyTypeHTTP: CF;
        static kCFProxyTypeHTTPS: CF;
        static kCFProxyTypeSOCKS: CF;
        static kCFProxyTypeAutoConfigurationURL: CF;
        static kCFProxyTypeAutoConfigurationJavaScript: CF;
    }
    struct Owned(CF);
    impl Drop for Owned {
        fn drop(&mut self) {
            if !self.0.is_null() {
                unsafe {
                    CFRelease(self.0);
                }
            }
        }
    }
    unsafe fn text(value: CF) -> Result<String> {
        if value.is_null() {
            return Err("無法取得系統代理伺服器設定。".into());
        }
        let mut buffer = vec![0u8; 16384];
        if unsafe {
            CFStringGetCString(
                value,
                buffer.as_mut_ptr() as _,
                buffer.len() as isize,
                0x08000100,
            )
        } == 0
        {
            return Err("無法取得系統代理伺服器設定。".into());
        }
        let length = buffer.iter().position(|c| *c == 0).unwrap_or(buffer.len());
        String::from_utf8(buffer[..length].to_vec())
            .map_err(|_| "無法取得系統代理伺服器設定。".into())
    }
    struct Pac {
        done: bool,
        list: CF,
        failed: bool,
    }
    unsafe extern "C" fn pac_result(client: *mut c_void, list: CF, error: CF) {
        // SAFETY: the context points to a pinned Box<Pac> until its source is
        // invalidated, and this callback runs only on the caller's run loop.
        let context = unsafe { &mut *(client as *mut Pac) };
        context.done = true;
        context.failed = !error.is_null() || list.is_null();
        if !list.is_null() {
            context.list = unsafe { CFRetain(list) };
        }
    }
    unsafe fn decode(list: CF, target: CF, depth: usize) -> Result<Vec<Option<ureq::Proxy>>> {
        if list.is_null() || depth > 2 {
            return Err("系統代理自動設定未完成，請稍後重試。".into());
        }
        let count = unsafe { CFArrayGetCount(list) };
        if count <= 0 || count > 128 {
            return Err("無法取得系統代理伺服器設定。".into());
        }
        let mut result = vec![];
        for i in 0..count {
            let dict = unsafe { CFArrayGetValueAtIndex(list, i) };
            let kind = unsafe { CFDictionaryGetValue(dict, kCFProxyTypeKey) };
            if kind.is_null() {
                return Err("無法取得系統代理伺服器設定。".into());
            }
            if unsafe { CFEqual(kind, kCFProxyTypeNone) } != 0 {
                result.push(None);
                continue;
            }
            if unsafe { CFEqual(kind, kCFProxyTypeAutoConfigurationURL) } != 0 {
                let pac = unsafe { CFDictionaryGetValue(dict, kCFProxyAutoConfigurationURLKey) };
                if pac.is_null() {
                    return Err("系統代理自動設定未完成，請稍後重試。".into());
                }
                let mut data = Box::new(Pac {
                    done: false,
                    list: ptr::null(),
                    failed: false,
                });
                let mut context = StreamContext {
                    version: 0,
                    info: &mut *data as *mut _ as _,
                    retain: None,
                    release: None,
                    description: None,
                };
                let source = Owned(unsafe {
                    CFNetworkExecuteProxyAutoConfigurationURL(pac, target, pac_result, &mut context)
                });
                if source.0.is_null() {
                    return Err("系統代理自動設定未完成，請稍後重試。".into());
                }
                unsafe {
                    CFRunLoopAddSource(CFRunLoopGetCurrent(), source.0, kCFRunLoopDefaultMode);
                }
                let deadline = Instant::now() + Duration::from_secs(20);
                while !data.done && Instant::now() < deadline {
                    unsafe {
                        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, 1);
                    }
                }
                unsafe {
                    CFRunLoopSourceInvalidate(source.0);
                }
                let resolved = Owned(data.list);
                if !data.done || data.failed {
                    return Err("系統代理自動設定未完成，請稍後重試。".into());
                }
                result.extend(unsafe { decode(resolved.0, target, depth + 1) }?);
                continue;
            }
            if unsafe { CFEqual(kind, kCFProxyTypeAutoConfigurationJavaScript) } != 0 {
                let script =
                    unsafe { CFDictionaryGetValue(dict, kCFProxyAutoConfigurationJavaScriptKey) };
                let mut error = ptr::null();
                let resolved = Owned(unsafe {
                    CFNetworkCopyProxiesForAutoConfigurationScript(script, target, &mut error)
                });
                let _error = Owned(error);
                if !error.is_null() {
                    return Err("系統代理自動設定未完成，請稍後重試。".into());
                }
                result.extend(unsafe { decode(resolved.0, target, depth + 1) }?);
                continue;
            }
            let protocol = if unsafe { CFEqual(kind, kCFProxyTypeHTTP) } != 0
                || unsafe { CFEqual(kind, kCFProxyTypeHTTPS) } != 0
            {
                ureq::ProxyProtocol::Http
            } else if unsafe { CFEqual(kind, kCFProxyTypeSOCKS) } != 0 {
                ureq::ProxyProtocol::Socks5
            } else {
                return Err("系統代理伺服器類型不受支援。".into());
            };
            let host = unsafe { text(CFDictionaryGetValue(dict, kCFProxyHostNameKey)) }?;
            let number = unsafe { CFDictionaryGetValue(dict, kCFProxyPortNumberKey) };
            let mut port = 0i32;
            if number.is_null()
                || unsafe { CFNumberGetValue(number, 3, &mut port as *mut _ as _) } == 0
                || !(1..=65535).contains(&port)
            {
                return Err("系統代理伺服器連接埠不正確。".into());
            }
            let mut builder = ureq::Proxy::builder(protocol).host(&host).port(port as u16);
            let username = unsafe { CFDictionaryGetValue(dict, kCFProxyUsernameKey) };
            let password = unsafe { CFDictionaryGetValue(dict, kCFProxyPasswordKey) };
            if !username.is_null() {
                builder = builder.username(&unsafe { text(username) }?);
            }
            if !password.is_null() {
                builder = builder.password(&unsafe { text(password) }?);
            }
            result.push(Some(
                builder
                    .build()
                    .map_err(|_| "無法取得系統代理伺服器設定。")?,
            ));
        }
        Ok(result)
    }
    pub fn resolve(url: &str) -> Result<Vec<Option<ureq::Proxy>>> {
        let input = CString::new(url).map_err(|_| "更新網址不正確。")?;
        // SAFETY: CoreFoundation objects are created, consumed and released on
        // this thread. Copy/Create results have scoped ownership; borrowed
        // dictionary and array entries never outlive their owning collections.
        unsafe {
            let string = Owned(CFStringCreateWithCString(
                ptr::null(),
                input.as_ptr(),
                0x08000100,
            ));
            if string.0.is_null() {
                return Err("更新網址不正確。".into());
            }
            let target = Owned(CFURLCreateWithString(ptr::null(), string.0, ptr::null()));
            if target.0.is_null() {
                return Err("更新網址不正確。".into());
            }
            let settings = Owned(CFNetworkCopySystemProxySettings());
            if settings.0.is_null() {
                return Ok(vec![None]);
            }
            let list = Owned(CFNetworkCopyProxiesForURL(target.0, settings.0));
            decode(list.0, target.0, 0)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn dir(name: &str) -> PathBuf {
        let base = std::env::var_os("RBN_TEST_ROOT")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../.tmp/services-tests")
            });
        let d = base.join(format!("{name}-{}", Uuid::new_v4()));
        crate::storage::private_directory(&d).unwrap();
        d
    }
    fn macho(cpu: u32, minimum: u32, platform: u32) -> Vec<u8> {
        [
            0xfeedfacf, cpu, 0, 2, 1, 24, 0, 0, 0x32, 24, platform, minimum, minimum, 0,
        ]
        .into_iter()
        .flat_map(u32::to_le_bytes)
        .collect()
    }
    fn reply(tag: &str) -> Reply {
        Reply{data:serde_json::to_vec(&json!({"tag_name":tag,"draft":false,"prerelease":false,"published_at":"2026-10-20T10:00:00Z","html_url":format!("https://github.com/example-owner/example-app/releases/tag/{tag}")})).unwrap(),status:200,url:"https://api.github.com/repos/example-owner/example-app/releases/latest".into(),declared_size:None}
    }
    #[test]
    fn stable_versions_compare_numerically_and_reject_suffixes() {
        assert!(Release::parse("rclone v1.9.10") < Release::parse("1.10.0"));
        for bad in [
            "",
            "1.2",
            "1.2.3-beta",
            "1.2.3; rm",
            "https://evil",
            "1.2.3\n9.9.9",
        ] {
            assert!(Release::parse(bad).is_none());
        }
        for bad in [
            "01.2.3",
            "0.4",
            "0.4.0-beta",
            "0.4.0+build",
            "rclone v0.4.0",
            "0.4.0\n",
            " 0.4.0",
            "0.4.0; echo x",
            "1.2.100000",
        ] {
            assert!(Release::stable_app(bad).is_none());
        }
    }
    #[test]
    fn sha256_matches_published_vectors() {
        assert_eq!(
            sha256(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(
            sha256(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(
            sha256(&vec![b'a'; 1_000_000]),
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        );
    }
    #[test]
    fn checksums_match_exact_archive_once() {
        let hash = sha256(b"archive");
        let name = "rclone-v1.75.2-osx-arm64.zip";
        let line = format!("{hash}  {name}\n");
        assert_eq!(checksum(name,format!("-----BEGIN PGP SIGNED MESSAGE-----\nHash: SHA256\n\n{line}-----BEGIN PGP SIGNATURE-----\n").as_bytes()).unwrap(),hash);
        assert!(checksum("wrong.zip", line.as_bytes()).is_err());
        assert!(checksum(name, (line.clone() + &line).as_bytes()).is_err());
    }
    #[test]
    fn http_errors_and_bounds_remain_distinct() {
        for status in [403, 404, 429, 503] {
            let r = Reply {
                data: vec![],
                status,
                url: "https://downloads.rclone.org/version.txt".into(),
                declared_size: None,
            };
            let e = validate_download_reply(&r, 1024).unwrap_err();
            assert!(
                e.message.contains(&format!("HTTP {status}")) && e.message.contains("version.txt")
            );
            assert_eq!(e.retryable, matches!(status, 429 | 503));
        }
        let r = Reply {
            data: vec![],
            status: 200,
            url: "https://downloads.rclone.org/version.txt".into(),
            declared_size: Some(2048),
        };
        assert!(validate_download_reply(&r, 1024).is_err());
        let r = Reply {
            declared_size: None,
            url: "https://example.invalid/version.txt".into(),
            ..r
        };
        assert!(validate_download_reply(&r, 1024).is_err());
    }
    #[test]
    fn manual_proxy_policy_keeps_rclone_support_and_rejects_native_tls_proxy() {
        let s = json!({"proxyMode":"manual","httpsProxy":"https://127.0.0.1:443"});
        assert_eq!(validate_native_proxy(&s).unwrap_err(), PROXY_TLS_MESSAGE);
        let environment = proxy_environment(
            &s,
            BTreeMap::from([
                ("RCLONE_CONFIG_PASS".into(), "secret".into()),
                ("https_proxy".into(), "old".into()),
            ]),
        );
        assert_eq!(
            environment.get("HTTPS_PROXY").unwrap(),
            "https://127.0.0.1:443"
        );
        assert_eq!(environment.len(), 1);
        for (scheme, protocol, port) in [
            ("http", ureq::ProxyProtocol::Http, 8119),
            ("socks5", ureq::ProxyProtocol::Socks5, 1088),
            ("socks5h", ureq::ProxyProtocol::Socks5h, 1088),
        ] {
            let proxy=manual_proxy(&json!({"proxyMode":"manual","httpsProxy":format!("{scheme}://127.0.0.1:{port}"),"noProxy":"localhost,.lan"})).unwrap().unwrap();
            assert_eq!(proxy.protocol(), protocol);
            assert_eq!(proxy.host(), "127.0.0.1");
            assert_eq!(proxy.port(), port);
            assert!(proxy.is_no_proxy(&"https://localhost/".parse().unwrap()));
            assert!(proxy.is_no_proxy(&"https://server.lan/".parse().unwrap()));
            assert!(!proxy.is_no_proxy(&"https://outside.invalid/".parse().unwrap()));
        }
        for address in ["https://127.0.0.1:443", "HTTPS://proxy.example:8443"] {
            let settings = json!({"proxyMode":"manual","httpsProxy":address});
            let error = validate_native_proxy(&settings).unwrap_err();
            assert_eq!(error, PROXY_TLS_MESSAGE);
            assert!(!DownloadError::from(error).retryable);
            assert!(manual_proxy(&settings).is_err());
            assert_eq!(
                proxy_environment(&settings, BTreeMap::new())["HTTPS_PROXY"],
                address
            );
        }
        for settings in [
            json!({}),
            json!({"proxyMode":"system","httpsProxy":"https://127.0.0.1:443"}),
            json!({"proxyMode":"manual","httpsProxy":""}),
            json!({"proxyMode":"manual","httpsProxy":"http://127.0.0.1:443"}),
            json!({"proxyMode":"manual","httpsProxy":"socks5://127.0.0.1:1080"}),
            json!({"proxyMode":"manual","httpsProxy":"socks5h://127.0.0.1:1080"}),
            json!({"proxyMode":"manual","httpProxy":"https://127.0.0.1:443","httpsProxy":"http://127.0.0.1:8080"}),
        ] {
            validate_native_proxy(&settings).unwrap();
        }
    }
    #[test]
    fn mac_architecture_and_minimum_os_gate() {
        let data = macho(0x0100000c, 0x000d0000, 1);
        assert_eq!(verify_macho(&data, "arm64", [13, 0, 0]).unwrap(), "13.0.0");
        assert!(verify_macho(&data, "amd64", [26, 0, 0]).is_err());
        assert!(verify_macho(&macho(0x0100000c, 0x001a0000, 1), "arm64", [13, 0, 0]).is_err());
        assert!(verify_macho(&macho(0x0100000c, 0x000d0000, 2), "arm64", [26, 0, 0]).is_err());
    }
    #[test]
    fn universal_macho_slice_bounds_are_checked() {
        let mut data: Vec<_> = [
            0xcafebabe, 2, 0x01000007, 0, 64, 56, 0, 0x0100000c, 0, 128, 56, 0,
        ]
        .into_iter()
        .flat_map(u32::to_be_bytes)
        .collect();
        data.resize(64, 0);
        data.extend(macho(0x01000007, 0x000d0000, 1));
        data.resize(128, 0);
        data.extend(macho(0x0100000c, 0x000d0000, 1));
        for arch in ["arm64", "amd64"] {
            assert_eq!(verify_macho(&data, arch, [13, 0, 0]).unwrap(), "13.0.0");
        }
        assert!(verify_macho(&data[..140], "arm64", [13, 0, 0]).is_err());
    }
    #[test]
    fn managed_paths_and_symlinks_cannot_be_updated() {
        for p in [
            "relative/rclone",
            "/usr/local/bin/rclone",
            "/opt/homebrew/bin/rclone",
            "/Applications/Example.app/Contents/Resources/rclone",
            "/tmp/a\nrclone",
        ] {
            assert!(validated_target(Path::new(p)).is_err());
        }
        #[cfg(unix)]
        {
            let d = dir("target-links");
            fs::write(d.join("real"), b"old").unwrap();
            std::os::unix::fs::symlink(d.join("real"), d.join("rclone")).unwrap();
            assert!(validated_target(&d.join("rclone")).is_err());
            fs::remove_dir_all(d).unwrap();
        }
    }
    #[test]
    fn atomic_commit_keeps_exact_previous_bytes_and_rolls_back() {
        let d = dir("commit");
        let target = d.join(rclone_name());
        fs::write(&target, b"old bytes").unwrap();
        let stage = d.join(".rbn-update-test");
        fs::create_dir(&stage).unwrap();
        let candidate = stage.join(rclone_name());
        fs::write(&candidate, b"new bytes").unwrap();
        let backup = commit(&candidate, &target, |p| {
            assert_eq!(fs::read(p).unwrap(), b"new bytes");
            Ok(())
        })
        .unwrap()
        .unwrap();
        assert_eq!(fs::read(backup).unwrap(), b"old bytes");
        fs::write(&candidate, b"broken bytes").unwrap();
        assert!(
            commit(&candidate, &target, |_| Err("probe failed".into()))
                .unwrap_err()
                .contains("已自動還原")
        );
        assert_eq!(fs::read(&target).unwrap(), b"new bytes");
        fs::remove_dir_all(d).unwrap();
    }
    #[test]
    fn failed_first_install_removes_candidate_and_retention_keeps_two() {
        let d = dir("retention");
        let target = d.join(rclone_name());
        let stage = d.join(".rbn-update-test");
        fs::create_dir(&stage).unwrap();
        let candidate = stage.join(rclone_name());
        fs::write(&candidate, b"broken").unwrap();
        assert!(commit(&candidate, &target, |_| Err("probe".into())).is_err());
        assert!(!target.exists());
        fs::write(&target, b"0").unwrap();
        fs::create_dir_all(d.join("Backups")).unwrap();
        fs::write(d.join("Backups/notes.txt"), b"keep").unwrap();
        for i in 1..=4 {
            fs::write(&candidate, i.to_string()).unwrap();
            commit(&candidate, &target, |_| Ok(())).unwrap();
        }
        assert_eq!(
            fs::read_dir(d.join("Backups"))
                .unwrap()
                .flatten()
                .filter(|e| e.file_name().to_string_lossy().starts_with("rbn-"))
                .count(),
            2
        );
        assert_eq!(fs::read(d.join("Backups/notes.txt")).unwrap(), b"keep");
        fs::remove_dir_all(d).unwrap();
    }
    #[test]
    #[cfg(unix)]
    fn backup_symlink_cannot_redirect_writes() {
        let d = dir("backup-link");
        let outside = dir("outside");
        let target = d.join(rclone_name());
        fs::write(&target, b"old").unwrap();
        std::os::unix::fs::symlink(&outside, d.join("Backups")).unwrap();
        let stage = d.join(".rbn-update-test");
        fs::create_dir(&stage).unwrap();
        let candidate = stage.join(rclone_name());
        fs::write(&candidate, b"new").unwrap();
        assert!(commit(&candidate, &target, |_| Ok(())).is_err());
        assert_eq!(fs::read(target).unwrap(), b"old");
        assert!(fs::read_dir(&outside).unwrap().next().is_none());
        fs::remove_dir_all(d).unwrap();
        fs::remove_dir_all(outside).unwrap();
    }
    #[test]
    fn app_checks_require_full_stable_release_and_exact_project_link() {
        let current = Release::parse("0.9.9").unwrap();
        let good = reply("v0.10.0");
        let result = decode_app_reply(&good, current, "example-owner/example-app").unwrap();
        assert_eq!(result["status"], "available");
        let mut object: Value = serde_json::from_slice(&good.data).unwrap();
        for patch in [
            json!({"draft":true}),
            json!({"draft":0}),
            json!({"prerelease":true}),
            json!({"published_at":null}),
            json!({"published_at":"not a date"}),
            json!({"tag_name":"v0.5.0-beta"}),
            json!({"html_url":"https://github.com/another/app/releases/tag/v0.10.0"}),
        ] {
            let mut v = object.clone();
            v.as_object_mut()
                .unwrap()
                .extend(patch.as_object().unwrap().clone());
            let r = Reply {
                data: serde_json::to_vec(&v).unwrap(),
                ..good.clone()
            };
            assert!(decode_app_reply(&r, current, "example-owner/example-app").is_err());
        }
        object["html_url"] =
            json!("https://github.com/example-owner/example-app/releases/tag/v0.10.0?next=x");
        assert!(
            decode_app_reply(
                &Reply {
                    data: serde_json::to_vec(&object).unwrap(),
                    ..good
                },
                current,
                "example-owner/example-app"
            )
            .is_err()
        );
    }
    #[test]
    fn unpublished_and_http_limits_are_actionable() {
        let current = Release::parse("0.4.0").unwrap();
        let mut r = reply("v0.5.0");
        r.status = 404;
        r.data = b"{}".to_vec();
        let v = decode_app_reply(&r, current, "example-owner/example-app").unwrap();
        assert_eq!(v["status"], "unpublished");
        assert!(v.get("latest").is_none());
        for status in [403, 429, 500] {
            r.status = status;
            assert!(decode_app_reply(&r, current, "example-owner/example-app").is_err());
        }
        for repo in [
            "",
            "a/b/c",
            "name/repo\n",
            "name/repo?token=x",
            "name/../repo",
            "https://github.com/name/repo",
        ] {
            assert!(validate_repository(repo).is_err());
        }
    }
    #[test]
    fn failed_fetch_does_not_poison_next_check() {
        let d = dir("retry");
        let count = Arc::new(Mutex::new(0));
        let attempts = count.clone();
        let up = Updater::with_fetcher(
            d.clone(),
            Arc::new(move |url, max, settings| {
                assert_eq!(url, "https://downloads.rclone.org/version.txt");
                assert_eq!(max, 1024);
                assert_eq!(settings["httpsProxy"], "http://127.0.0.1:1");
                let mut n = attempts.lock().unwrap();
                *n += 1;
                if *n == 1 {
                    return Err(DownloadError {
                        message: "HTTP 403".into(),
                        retryable: false,
                    });
                }
                Ok(Reply {
                    data: b"rclone v9.8.7\n".to_vec(),
                    status: 200,
                    url: url.into(),
                    declared_size: None,
                })
            }),
        )
        .unwrap();
        let settings = json!({"httpsProxy":"http://127.0.0.1:1"});
        assert!(up.check(None, "", true, &settings).is_err());
        assert_eq!(
            up.check(None, "", true, &settings).unwrap()["status"],
            "notInstalled"
        );
        assert_eq!(*count.lock().unwrap(), 2);
        fs::remove_dir_all(d).unwrap();
    }
    #[test]
    fn transient_fetch_failure_retries_but_verification_does_not() {
        let d = dir("retry-transient");
        let count = Arc::new(Mutex::new(0));
        let attempts = count.clone();
        let up = Updater::with_fetcher(
            d.clone(),
            Arc::new(move |url, _, _| {
                let mut n = attempts.lock().unwrap();
                *n += 1;
                if *n == 1 {
                    return Err(DownloadError {
                        message: "HTTP 503".into(),
                        retryable: true,
                    });
                }
                Ok(Reply {
                    data: b"rclone v9.8.7\n".to_vec(),
                    status: 200,
                    url: url.into(),
                    declared_size: None,
                })
            }),
        )
        .unwrap();
        assert_eq!(
            up.check(None, "", true, &json!({})).unwrap()["status"],
            "notInstalled"
        );
        assert_eq!(*count.lock().unwrap(), 2);
        fs::remove_dir_all(d).unwrap();
    }
}

#[cfg(test)]
mod additional_parity_tests {
    use super::*;
    fn directory(name: &str) -> PathBuf {
        let base = std::env::var_os("RBN_TEST_ROOT")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../.tmp/services-tests")
            });
        let d = base.join(format!("{name}-{}", Uuid::new_v4()));
        crate::storage::private_directory(&d).unwrap();
        d
    }
    #[test]
    fn selected_executable_and_folder_define_one_destination() {
        assert_eq!(
            default_target(
                &json!({"rclonePath":"/Applications/rclone/rclone","rcloneDirectory":"/different"}),
                Some("/opt/homebrew/bin/rclone")
            )
            .unwrap(),
            "/Applications/rclone/rclone"
        );
        assert_eq!(
            default_target(
                &json!({"rclonePath":"","rcloneDirectory":"/new-folder"}),
                Some("/opt/homebrew/bin/rclone")
            )
            .unwrap(),
            Path::new("/new-folder")
                .join(rclone_name())
                .to_string_lossy()
        );
        assert!(default_target(&json!({}), None).is_err());
        #[cfg(not(windows))]
        assert_eq!(
            validated_target(Path::new("/Applications/rclone/rclone")).unwrap(),
            PathBuf::from("/Applications/rclone/rclone")
        );
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn mac_default_chooser_follows_original_policy() {
        let settings = json!({"rclonePath":""});
        let target = "/Applications/Tools/rclone/rclone";
        assert!(requires_directory_choice(
            &settings,
            target,
            false,
            Some("/Applications")
        ));
        assert!(!requires_directory_choice(
            &settings,
            target,
            true,
            Some("/Applications")
        ));
        assert!(!requires_directory_choice(
            &json!({"rclonePath":target}),
            target,
            false,
            Some("/Applications")
        ));
        assert!(!requires_directory_choice(
            &settings,
            "/Applications/rclone/rclone",
            false,
            Some("/Applications")
        ));
        assert!(!requires_directory_choice(
            &settings,
            "/custom/Tools/rclone/rclone",
            false,
            Some("/custom")
        ));
    }

    #[test]
    fn target_refresh_returns_exact_selected_path_and_settings_revision() {
        let d = directory("update-target");
        let up = Updater::with_fetcher(
            d.join("work"),
            Arc::new(|_, _, _| panic!("target refresh must not fetch")),
        )
        .unwrap();
        let context = update_context(Path::new("/missing-rclone"), &d, &json!({}));
        let target = d.join(rclone_name());
        let v = up
            .handle(
                "_rcloneUpdateTarget",
                &[],
                &context,
                &json!({"rclonePath":target,"settingsRevision":7}),
            )
            .unwrap();
        assert_eq!(v, json!({"targetPath":target,"settingsRevision":7}));
        fs::remove_dir_all(d).unwrap();
    }
    #[test]
    fn proxy_environment_drops_inherited_secrets_and_manual_empty_values() {
        let source = BTreeMap::from([
            ("PATH".into(), "/bin".into()),
            ("RCLONE_CONFIG_PASS".into(), "secret".into()),
            ("https_proxy".into(), "old".into()),
            ("ALL_PROXY".into(), "old".into()),
        ]);
        let settings = json!({"proxyMode":"manual","httpProxy":"http://127.0.0.1:8118","httpsProxy":"http://127.0.0.1:8119","noProxy":"localhost,.lan"});
        let env = proxy_environment(&settings, source.clone());
        assert_eq!(env.get("HTTP_PROXY").unwrap(), "http://127.0.0.1:8118");
        assert_eq!(env.get("HTTPS_PROXY").unwrap(), "http://127.0.0.1:8119");
        assert_eq!(env.get("NO_PROXY").unwrap(), "localhost,.lan");
        assert!(!env.keys().any(|k| k.to_uppercase().starts_with("RCLONE_")));
        let direct = proxy_environment(
            &json!({"proxyMode":"manual","httpProxy":"","httpsProxy":"","noProxy":""}),
            source,
        );
        assert_eq!(direct, BTreeMap::from([("PATH".into(), "/bin".into())]));
    }
    #[test]
    fn update_subprocess_uses_selected_proxy_and_private_temp() {
        // Re-execute this one test as the native child on every target OS. The
        // parent still uses the production updater context and process runner.
        if std::env::var("RBN_UPDATER_ENV_PROBE").as_deref() == Ok("selected-private-temp-v1") {
            println!("HTTPS_PROXY={}", std::env::var("HTTPS_PROXY").unwrap());
            println!("TMPDIR={}", std::env::var("TMPDIR").unwrap());
            assert!(
                !std::env::vars_os()
                    .any(|(k, _)| k.to_string_lossy().to_uppercase().starts_with("RCLONE_"))
            );
            return;
        }
        let d = directory("proxy-child");
        let settings = json!({"proxyMode":"manual","httpsProxy":"http://127.0.0.1:8119"});
        let mut context = update_context(&std::env::current_exe().unwrap(), &d, &settings);
        context.environment.insert(
            "RBN_UPDATER_ENV_PROBE".into(),
            "selected-private-temp-v1".into(),
        );
        let args=["--exact","updater::additional_parity_tests::update_subprocess_uses_selected_proxy_and_private_temp","--nocapture"].map(str::to_owned);
        let output = process::capture(&context, &args, 1024 * 1024, Duration::from_secs(10), None)
            .unwrap()
            .checked()
            .unwrap();
        let text = String::from_utf8(output.stdout).unwrap();
        assert!(text.contains("HTTPS_PROXY=http://127.0.0.1:8119"));
        assert!(text.contains(&format!("TMPDIR={}", d.display())));
        assert!(text.contains("1 passed; 0 failed"));
        fs::remove_dir_all(d).unwrap();
    }
    #[test]
    fn native_fetch_rejects_https_proxy_before_any_connection() {
        let d = directory("native-proxy");
        let up = Updater::new(d.clone()).unwrap();
        let settings = json!({"proxyMode":"manual","httpsProxy":"https://127.0.0.1:1"});
        assert_eq!(
            up.check(None, "", true, &settings).unwrap_err(),
            PROXY_TLS_MESSAGE
        );
        assert_eq!(
            up.check_app("0.12.0", APP_REPOSITORY, &settings)
                .unwrap_err(),
            PROXY_TLS_MESSAGE
        );
        fs::remove_dir_all(d).unwrap();
    }
    #[test]
    fn transient_status_progress_reaches_idle_and_tls_errors_never_retry() {
        let d = directory("retry-status");
        let count = Arc::new(Mutex::new(0));
        let attempt = count.clone();
        let statuses = Arc::new(Mutex::new(Vec::<String>::new()));
        let events = statuses.clone();
        let up = Updater::with_fetcher(
            d.clone(),
            Arc::new(move |url, _, _| {
                let mut n = attempt.lock().unwrap();
                *n += 1;
                if *n == 1 {
                    return Err(DownloadError {
                        message: "HTTP 503".into(),
                        retryable: true,
                    });
                }
                Ok(Reply {
                    data: b"rclone v9.8.7\n".to_vec(),
                    status: 200,
                    url: url.into(),
                    declared_size: None,
                })
            }),
        )
        .unwrap();
        up.set_event_handler(Arc::new(move |v| {
            events
                .lock()
                .unwrap()
                .push(v["phase"].as_str().unwrap().into())
        }));
        up.check(None, "", true, &json!({})).unwrap();
        assert_eq!(*count.lock().unwrap(), 2);
        let statuses = statuses.lock().unwrap();
        assert!(statuses.contains(&"retrying".into()));
        assert_eq!(statuses.last().unwrap(), "idle");
        assert!(
            network_error(ureq::Error::Io(std::io::ErrorKind::ConnectionReset.into())).retryable
        );
        assert!(!network_error(ureq::Error::Tls("untrusted certificate")).retryable);
        fs::remove_dir_all(d).unwrap();
    }
    #[test]
    fn rollback_failure_reports_backup_path_without_claiming_restoration() {
        let d = directory("rollback-failure");
        let target = d.join(rclone_name());
        fs::write(&target, b"old").unwrap();
        let stage = d.join(".rbn-update-test");
        fs::create_dir(&stage).unwrap();
        let candidate = stage.join(rclone_name());
        fs::write(&candidate, b"new").unwrap();
        let mut removed_backup = None;
        let error = commit(&candidate, &target, |_| {
            let backup = fs::read_dir(d.join("Backups"))
                .unwrap()
                .next()
                .unwrap()
                .unwrap()
                .path()
                .join(rclone_name());
            removed_backup = Some(fs::canonicalize(&backup).unwrap());
            fs::remove_file(backup).unwrap();
            Err("post-install probe failed".into())
        })
        .unwrap_err();
        let expected = removed_backup.unwrap_or_else(|| panic!("validation never ran: {error}"));
        assert!(error.contains("自動還原失敗"), "{error}");
        let reported = error
            .lines()
            .find_map(|line| line.strip_prefix("舊版備份位置："))
            .map(Path::new)
            .unwrap_or_else(|| panic!("missing backup location: {error}"));
        assert!(reported.is_absolute(), "{error}");
        // The injected failure removed the file. Resolve its surviving parent,
        // then compare the complete location, including the executable name.
        let actual = fs::canonicalize(reported.parent().unwrap())
            .unwrap()
            .join(reported.file_name().unwrap());
        assert_eq!(actual, expected);
        assert_eq!(fs::read(&target).unwrap(), b"new");
        fs::remove_dir_all(d).unwrap();
    }
    #[test]
    fn app_http_limits_proxy_forwarding_and_manual_retry_are_distinct() {
        let d = directory("app-retry");
        let attempts = Arc::new(Mutex::new(0));
        let count = attempts.clone();
        let repository = "example-owner/example-app";
        let endpoint = format!("https://api.github.com/repos/{repository}/releases/latest");
        let expected = endpoint.clone();
        let up=Updater::with_fetcher(d.clone(),Arc::new(move |url,max,settings|{assert_eq!(url,expected);assert_eq!(max,APP_RESPONSE_LIMIT);assert_eq!(settings["httpsProxy"],"socks5://127.0.0.1:1080");let mut n=count.lock().unwrap();*n+=1;if *n==1{return Err(DownloadError{message:"timed out".into(),retryable:true});}Ok(Reply{data:serde_json::to_vec(&json!({"tag_name":"v0.5.0","draft":false,"prerelease":false,"published_at":"2026-10-20T10:00:00Z","html_url":"https://github.com/example-owner/example-app/releases/tag/v0.5.0"})).unwrap(),status:200,url:url.into(),declared_size:None})})).unwrap();
        let settings = json!({"proxyMode":"manual","httpsProxy":"socks5://127.0.0.1:1080"});
        assert!(up.check_app("0.4.0", repository, &settings).is_err());
        assert_eq!(*attempts.lock().unwrap(), 1);
        assert_eq!(
            up.check_app("0.4.0", repository, &settings).unwrap()["status"],
            "available"
        );
        assert_eq!(*attempts.lock().unwrap(), 2);
        let current = Release::parse("0.4.0").unwrap();
        let response = Reply {
            data: vec![0; APP_RESPONSE_LIMIT + 1],
            status: 200,
            url: endpoint.clone(),
            declared_size: None,
        };
        assert_eq!(
            decode_app_reply(&response, current, repository).unwrap_err(),
            "GitHub 更新資訊超過允許大小。"
        );
        let response = Reply {
            data: vec![],
            declared_size: Some(APP_RESPONSE_LIMIT as u64 + 1),
            ..response
        };
        assert_eq!(
            decode_app_reply(&response, current, repository).unwrap_err(),
            "GitHub 更新資訊超過允許大小。"
        );
        fs::remove_dir_all(d).unwrap();
    }
    #[test]
    fn published_multi_block_sha_and_current_macos_requirement_are_verified() {
        assert_eq!(
            sha256(b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        );
        let bytes: Vec<_> = [
            0xfeedfacf, 0x0100000c, 0, 2, 1, 24, 0, 0, 0x32, 24, 1, 0x001a0000, 0x001a0000, 0,
        ]
        .into_iter()
        .flat_map(u32::to_le_bytes)
        .collect();
        assert_eq!(verify_macho(&bytes, "arm64", [26, 0, 0]).unwrap(), "26.0.0");
        assert!(verify_macho(&[0u8; 256], "arm64", [26, 0, 0]).is_err());
    }
    #[test]
    fn system_https_proxy_uses_curl_environment_precedence_and_exclusions() {
        let url = url::Url::parse("https://downloads.rclone.org/version.txt").unwrap();
        let env = BTreeMap::from([
            ("ALL_PROXY".into(), "http://all.invalid:1".into()),
            ("HTTPS_PROXY".into(), "http://upper.invalid:2".into()),
            ("https_proxy".into(), "socks5h://lower.invalid:3".into()),
        ]);
        let proxy = environment_proxy(&url, &env).unwrap().unwrap();
        assert_eq!(proxy.uri().host().unwrap(), "lower.invalid");
        assert_eq!(proxy.protocol(), ureq::ProxyProtocol::Socks5h);
        let mut env = env;
        env.remove("https_proxy");
        assert_eq!(
            environment_proxy(&url, &env)
                .unwrap()
                .unwrap()
                .uri()
                .host()
                .unwrap(),
            "upper.invalid"
        );
        env.remove("HTTPS_PROXY");
        assert_eq!(
            environment_proxy(&url, &env)
                .unwrap()
                .unwrap()
                .uri()
                .host()
                .unwrap(),
            "all.invalid"
        );
        for pattern in ["*", ".rclone.org", "rclone.org", "downloads.rclone.org"] {
            env.insert("no_proxy".into(), pattern.into());
            assert!(environment_proxy(&url, &env).unwrap().is_none());
        }
    }
}

#[cfg(test)]
mod review_regressions {
    use super::*;
    fn directory(label: &str) -> PathBuf {
        let base = std::env::var_os("RBN_TEST_ROOT")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../.tmp/services-tests")
            });
        let root = base.join(format!("update-review-{label}-{}", Uuid::new_v4()));
        crate::storage::private_directory(&root).unwrap();
        root
    }
    #[test]
    fn windows_canonical_prefix_conversion_preserves_io_case_and_unicode_spelling() {
        let names = [
            (
                "//?/C:/MiXeD/École/e\u{301}/rclone.exe",
                "C:/MiXeD/École/e\u{301}/rclone.exe",
            ),
            (
                "//?/UNC/SeRvEr/ShArE/École/e\u{301}/rclone.exe",
                "//SeRvEr/ShArE/École/e\u{301}/rclone.exe",
            ),
            ("C:/MiXeD/École/rclone.exe", "C:/MiXeD/École/rclone.exe"),
            (
                "//Server/Share/MiXeD/rclone.exe",
                "//Server/Share/MiXeD/rclone.exe",
            ),
        ];
        for (raw, expected) in names {
            assert_eq!(windows_path_spelling(raw).unwrap(), expected);
            let backslashes = raw.replace('/', &char::from(92).to_string());
            assert_eq!(windows_path_spelling(&backslashes).unwrap(), expected);
            assert_eq!(windows_path_spelling(expected).unwrap(), expected);
        }
        let nfc = windows_path_spelling("//?/C:/É.txt").unwrap();
        let nfd = windows_path_spelling("//?/C:/E\u{301}.txt").unwrap();
        assert_ne!(nfc.as_bytes(), nfd.as_bytes());
        for unsupported in [
            "//?/GLOBALROOT/Device/HarddiskVolume1/rclone.exe",
            "//?/Volume{12345678}/rclone.exe",
        ] {
            assert!(windows_path_spelling(unsupported).is_err());
        }
    }
    #[test]
    fn windows_protected_drive_and_unc_roots_use_keys_separate_from_io_paths() {
        let roots = vec![
            "C:/Windows".into(),
            "C:/Program Files".into(),
            "//Server/Share/保護区 É".into(),
        ];
        for target in [
            "//?/c:/WINDOWS/System32/rclone.exe",
            "//?/C:/Program Files/Tool/rclone.exe",
            "//?/UNC/sErVeR/sHaRe/保護区 E\u{301}/rclone.exe",
        ] {
            assert!(
                protected_target_name(target, &roots, true).unwrap(),
                "{target}"
            );
        }
        for target in [
            "C:/Windows-backup/rclone.exe",
            "C:/Program Files-old/rclone.exe",
            "//Server/Share/保護区 É-other/rclone.exe",
        ] {
            assert!(
                !protected_target_name(target, &roots, true).unwrap(),
                "{target}"
            );
        }
        let extended = vec!["//?/UNC/Server/Share/保護区 É".into()];
        assert!(
            protected_target_name("//server/share/保護区 E\u{301}/rclone.exe", &extended, true)
                .unwrap()
        );
    }
    #[test]
    fn writable_sync_preserves_complete_candidate_bytes_on_install_update_and_rollback() {
        let root = directory("write-sync");
        let target = root.join(rclone_name());
        let stage = root.join(".rbn-update-fixture");
        fs::create_dir(&stage).unwrap();
        let candidate = stage.join(rclone_name());
        let first = (0..65553).map(|i| (i % 251) as u8).collect::<Vec<_>>();
        fs::write(&candidate, &first).unwrap();
        assert!(
            commit(&candidate, &target, |p| {
                assert_eq!(fs::read(p).unwrap(), first);
                Ok(())
            })
            .unwrap()
            .is_none()
        );
        assert!(!candidate.exists());
        assert_eq!(fs::read(&target).unwrap(), first);
        let second = vec![0x6a; 98321];
        fs::write(&candidate, &second).unwrap();
        let backup = commit(&candidate, &target, |p| {
            assert_eq!(fs::read(p).unwrap(), second);
            Ok(())
        })
        .unwrap()
        .unwrap();
        assert_eq!(fs::read(&backup).unwrap(), first);
        assert_eq!(fs::read(&target).unwrap(), second);
        fs::write(
            &candidate,
            b"post-install validation must reject this candidate",
        )
        .unwrap();
        let error = commit(&candidate, &target, |_| {
            Err("synthetic post-install validation failure".into())
        })
        .unwrap_err();
        assert!(error.contains("已自動還原"));
        assert_eq!(fs::read(&target).unwrap(), second);
        assert_eq!(
            validated_target(&validated_target(&target).unwrap()).unwrap(),
            validated_target(&target).unwrap()
        );
        fs::remove_dir_all(root).unwrap();
    }
    #[cfg(windows)]
    #[test]
    fn windows_real_canonical_parent_revalidates_and_simulated_managed_root_is_rejected() {
        let root = directory("windows-target");
        let chosen = root.join("MiXeD École e\u{301}");
        fs::create_dir(&chosen).unwrap();
        let target = chosen.join(rclone_name());
        let canonical = fs::canonicalize(&chosen).unwrap();
        let canonical = canonical.to_str().unwrap().replace(char::from(92), "/");
        assert!(canonical.starts_with("//?/"));
        let validated = validated_target(&target).unwrap();
        let spelling = validated.to_str().unwrap();
        assert!(!spelling.starts_with("//?/"));
        assert!(spelling.contains("MiXeD École e\u{301}"));
        assert!(crate::models::absolute_local(spelling));
        assert_eq!(validated_target(&validated).unwrap(), validated);
        let protected = root.join("Simulated Windows É");
        fs::create_dir(&protected).unwrap();
        let protected_target = protected.join(rclone_name());
        let roots = vec![protected.to_str().unwrap().into()];
        let error = validated_target_with_protected(&protected_target, &roots).unwrap_err();
        assert!(error.contains("管理"));
        assert_eq!(fs::read_dir(&protected).unwrap().count(), 0);
        fs::remove_dir_all(root).unwrap();
    }
}
