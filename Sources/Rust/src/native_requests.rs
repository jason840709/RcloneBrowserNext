//! Validation before a native system dialog. Filesystem mutations stay in Engine.
use crate::{
    Result,
    models::{self, Endpoint, TransferRequest},
};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
fn at(a: &[Value], i: usize) -> &Value {
    a.get(i).unwrap_or(&Value::Null)
}
fn text(a: &[Value], i: usize, label: &str, max: usize) -> Result<String> {
    models::text(at(a, i), label, max).map(str::to_owned)
}
fn boolean(a: &[Value], i: usize, label: &str) -> Result<bool> {
    models::boolean(at(a, i), label)
}
fn executable(path: &str) -> bool {
    let p = Path::new(path);
    if !p.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        p.metadata()
            .is_ok_and(|m| m.permissions().mode() & 0o111 != 0)
    }
    #[cfg(not(unix))]
    {
        true
    }
}
pub fn external_allowed(value: &str) -> bool {
    let Ok(url) = url::Url::parse(value) else {
        return false;
    };
    if url.scheme() != "https"
        || !url.username().is_empty()
        || url.password().is_some()
        || url.port().is_some_and(|p| p != 443)
    {
        return false;
    }
    match url.host_str().map(str::to_lowercase).as_deref() {
        Some("rclone.org" | "downloads.rclone.org") => true,
        Some("github.com") => [
            "/kapitainsky/RcloneBrowser",
            "/rclone/rclone",
            "/jason840709/RcloneBrowserNext",
        ]
        .iter()
        .any(|base| url.path() == *base || url.path().starts_with(&format!("{base}/"))),
        _ => false,
    }
}
pub fn prepare(
    method: &str,
    args: &[Value],
    settings: &Value,
    jobs: &[Value],
    logs: &Path,
) -> Result<Value> {
    let mut canonical = args.to_vec();
    let mut target = None::<String>;
    let mut needs_player = None;
    match method {
        "chooseFolder" => {}
        "chooseFile" => {
            let kind = text(args, 0, "檔案類型", 4096)?;
            if !["rclone", "config", "player", "credential"].contains(&kind.as_str()) {
                return Err("檔案類型不正確。".into());
            }
            canonical = vec![json!(kind)];
        }
        "remove" => {
            let endpoint = Endpoint::parse(at(args, 0))?;
            let request = TransferRequest::parse(
                &json!({"source":endpoint.value(),"destination":endpoint.value(),"mode":"copy","options":models::default_options(),"selection":at(args,1),"dryRun":false}),
            )?;
            if request.selection.is_empty() {
                return Err("請先選取要刪除的項目。".into());
            }
            canonical = vec![endpoint.value(), request.value()["selection"].clone()];
        }
        "retryJob" => {
            let id = text(args, 0, "工作編號", 4096)?;
            let job = jobs
                .iter()
                .find(|j| j["id"] == id)
                .ok_or("找不到這個工作。")?;
            TransferRequest::parse(&job["request"])?;
            canonical = vec![json!(id)];
        }
        "publicLink" => {
            let endpoint = Endpoint::parse(at(args, 0))?;
            let name = text(args, 1, "檔案名稱", 4096)?;
            let directory = boolean(args, 2, "資料夾")?;
            let child = endpoint.child(&name)?;
            if endpoint.remote.is_none() {
                return Err("請選擇支援分享功能的雲端位置。".into());
            }
            target = Some(child.target());
            canonical = vec![endpoint.value(), json!(name), json!(directory)];
        }
        "exportLog" => {
            let id = text(args, 0, "工作編號", 4096)?;
            if !crate::valid_id(&id) || !jobs.iter().any(|j| j["id"] == id) {
                return Err("找不到這項工作的記錄。".into());
            }
            if !logs.join(format!("{id}.jsonl")).is_file() {
                return Err("這項工作尚未產生記錄。".into());
            }
            canonical = vec![json!(id)];
        }
        "exportJobReport" => {
            let id = text(args, 0, "工作編號", 4096)?;
            let format = if args.len() > 1 {
                text(args, 1, "匯出格式", 4096)?
            } else {
                "jsonl".into()
            };
            if !["jsonl", "comparison"].contains(&format.as_str()) {
                return Err("匯出格式不正確。".into());
            }
            canonical = vec![json!(id), json!(format)];
        }
        "exportFileList" => {
            let endpoint = Endpoint::parse(at(args, 0))?;
            let format = if args.len() > 1 {
                text(args, 1, "匯出格式", 4096)?
            } else {
                "csv".into()
            };
            if !["csv", "txt"].contains(&format.as_str()) {
                return Err("匯出格式不正確。".into());
            }
            canonical = vec![endpoint.value(), json!(format)];
        }
        "copyText" => canonical = vec![json!(text(args, 0, "文字", 1024 * 1024)?)],
        "openExternal" => {
            let value = text(args, 0, "網址", 2048)?;
            if !external_allowed(&value) {
                return Err("只能開啟 rclone 官方網站與參考專案。".into());
            }
            canonical = vec![json!(value)];
        }
        "checkForUpdates" => {
            let manual = if args.is_empty() {
                true
            } else {
                boolean(args, 0, "更新檢查方式")?
            };
            canonical = vec![json!(manual)];
        }
        "showAbout" | "checkAppUpdates" => {
            if !args.is_empty() {
                return Err(if method == "showAbout" {
                    "關於視窗不需要額外參數。"
                } else {
                    "更新檢查不需要額外參數。"
                }
                .into());
            }
        }
        "startMount" => {
            let endpoint = Endpoint::parse(at(args, 0))?;
            let options = if args.len() > 1 {
                at(args, 1).as_object().cloned().unwrap_or_default()
            } else {
                serde_json::Map::new()
            };
            let readonly = match options.get("readOnly") {
                None => true,
                Some(v) => models::boolean(v, "唯讀")?,
            };
            let cache = options
                .get("cacheMode")
                .and_then(Value::as_str)
                .unwrap_or("writes");
            if !["off", "minimal", "writes", "full"].contains(&cache) {
                return Err("快取模式不正確。".into());
            }
            canonical = vec![
                endpoint.value(),
                json!({"readOnly":readonly,"cacheMode":cache}),
            ];
        }
        "startStream" => {
            let endpoint = Endpoint::parse(at(args, 0))?;
            let name = text(args, 1, "檔案名稱", 4096)?;
            endpoint.child(&name)?;
            needs_player = Some(!executable(
                settings["streamPlayerPath"].as_str().unwrap_or(""),
            ));
            canonical = vec![endpoint.value(), json!(name)];
        }
        _ => return Err(format!("不支援的操作：{method}")),
    }
    let mut result = json!({"arguments":canonical});
    if let Some(target) = target {
        result["target"] = json!(target);
    }
    if let Some(choice) = needs_player {
        result["needsPlayerChoice"] = json!(choice);
    }
    Ok(result)
}
fn standardized(path: &Path) -> PathBuf {
    let mut result = PathBuf::new();
    for component in path.components() {
        match component {
            std::path::Component::ParentDir => {
                result.pop();
            }
            std::path::Component::CurDir => {}
            other => result.push(other.as_os_str()),
        }
    }
    result
}
pub fn finder_drop(raw: &Value) -> Result<Value> {
    use unicode_normalization::UnicodeNormalization;
    let urls = raw.as_array().ok_or("請從 Finder 拖入本機檔案或資料夾。")?;
    if urls.is_empty() || urls.len() > 10000 {
        return Err("一次最多拖入 10,000 個項目。".into());
    }
    let mut parent: Option<PathBuf> = None;
    let mut seen = std::collections::BTreeSet::new();
    let mut selected = vec![];
    for raw in urls {
        let value = raw.as_str().ok_or("請從 Finder 拖入本機檔案或資料夾。")?;
        let path = if value.starts_with('/') {
            PathBuf::from(value)
        } else {
            let url = url::Url::parse(value).map_err(|_| "請從 Finder 拖入本機檔案或資料夾。")?;
            if url.scheme() != "file"
                || url
                    .host_str()
                    .is_some_and(|s| !s.is_empty() && s != "localhost")
            {
                return Err("請從 Finder 拖入本機檔案或資料夾。".into());
            }
            url.to_file_path()
                .map_err(|_| "請從 Finder 拖入本機檔案或資料夾。")?
        };
        let path = standardized(&path);
        if path == Path::new("/") {
            return Err("請拖入資料夾內的項目。".into());
        }
        let folder = path.parent().ok_or("請拖入資料夾內的項目。")?.to_path_buf();
        if parent
            .as_ref()
            .is_some_and(|p| !p.to_string_lossy().nfc().eq(folder.to_string_lossy().nfc()))
        {
            return Err("單次拖放請選取同一個資料夾內的項目；不同資料夾請分批拖入。".into());
        }
        parent = Some(folder);
        if !seen.insert(path.to_string_lossy().nfc().collect::<String>()) {
            continue;
        }
        #[cfg(target_os = "macos")]
        let (directory, symlink, regular) = crate::mac_exports::finder_kind(&path)?;
        #[cfg(not(target_os = "macos"))]
        let (directory, symlink, regular) = {
            let metadata = std::fs::symlink_metadata(&path).map_err(|e| e.to_string())?;
            (
                metadata.is_dir(),
                metadata.file_type().is_symlink(),
                metadata.is_file(),
            )
        };
        if symlink {
            return Err("請直接拖入原始檔案或資料夾（拖放不支援符號連結）。".into());
        }
        if !directory && !regular {
            return Err("拖入的項目不是可傳輸的檔案或資料夾。".into());
        }
        let name = path
            .file_name()
            .and_then(|s| s.to_str())
            .ok_or("檔案名稱格式不正確。")?;
        selected.push(json!({"name":name,"isDir":directory}));
    }
    let parent = parent.ok_or("請拖入檔案或資料夾。")?;
    if selected.is_empty() {
        return Err("請拖入檔案或資料夾。".into());
    }
    let source = Endpoint::parse(&json!({"remote":null,"path":parent.to_string_lossy()}))?;
    let selection = models::Selection::parse(&json!(selected))?;
    Ok(
        json!({"source":source.value(),"selection":selection.iter().map(|item|json!({"name":item.name,"isDir":item.is_dir})).collect::<Vec<_>>()}),
    )
}
