use serde_json::{Value, json};
use std::{fs, path::Path};
use unicode_normalization::UnicodeNormalization;
pub fn home() -> String {
    if std::env::var("RBN_ISOLATED_STATE").as_deref() == Ok("1") {
        if let Ok(home) = std::env::var("RBN_TEST_HOME") {
            return home;
        }
    }
    std::env::var(if cfg!(windows) { "USERPROFILE" } else { "HOME" }).unwrap_or_else(|_| {
        if cfg!(windows) {
            "C:/".into()
        } else {
            "/".into()
        }
    })
}
pub fn language(settings: &Value) -> String {
    let selected = settings["language"].as_str().unwrap_or("system");
    let preferred = std::env::var("RBN_PREFERRED_LANGUAGES")
        .ok()
        .and_then(|s| serde_json::from_str::<Vec<String>>(&s).ok())
        .unwrap_or_else(|| {
            vec![
                std::env::var("LC_ALL")
                    .or_else(|_| std::env::var("LC_MESSAGES"))
                    .or_else(|_| std::env::var("LANG"))
                    .unwrap_or_default(),
            ]
        });
    resolve_language(selected, &preferred)
}
pub fn resolve_language(selected: &str, preferred: &[String]) -> String {
    if ["zh-TW", "en", "ja"].contains(&selected) {
        return selected.to_owned();
    }
    if selected != "system" {
        return "en".into();
    }
    let primary = preferred
        .first()
        .map(|s| s.trim().replace('_', "-").to_lowercase())
        .unwrap_or_default();
    match primary.split('-').next().unwrap_or("") {
        "zh" => "zh-TW".into(),
        "ja" => "ja".into(),
        _ => "en".into(),
    }
}

pub fn remote_group(kind: &str) -> &'static str {
    let kind = kind.to_lowercase();
    if ["smb", "sftp", "ftp"].contains(&kind.as_str()) {
        return "network";
    }
    if [
        "drive",
        "dropbox",
        "onedrive",
        "box",
        "b2",
        "azureblob",
        "azurefiles",
        "google cloud storage",
        "googlecloudstorage",
        "gcs",
        "pcloud",
        "mega",
        "yandex",
        "zoho",
        "protondrive",
        "iclouddrive",
        "google photos",
        "googlephotos",
        "1fichier",
        "jottacloud",
        "koofr",
        "storj",
        "opendrive",
        "sugarsync",
        "filefabric",
        "sharefile",
    ]
    .contains(&kind.as_str())
    {
        return "cloud";
    }
    "other"
}
pub fn locations() -> Vec<Value> {
    let home = home();
    let mut out = vec![];
    for (id, kind, name, path) in [
        ("home", "home", "Home", home.clone()),
        ("desktop", "desktop", "Desktop", format!("{home}/Desktop")),
        (
            "documents",
            "documents",
            "Documents",
            format!("{home}/Documents"),
        ),
        (
            "downloads",
            "downloads",
            "Downloads",
            format!("{home}/Downloads"),
        ),
        (
            "pictures",
            "pictures",
            "Pictures",
            format!("{home}/Pictures"),
        ),
        ("music", "music", "Music", format!("{home}/Music")),
        ("movies", "movies", "Movies", format!("{home}/Movies")),
    ] {
        if Path::new(&path).is_dir() {
            out.push(json!({"id":id,"kind":kind,"name":name,"path":path,"group":"local"}));
        }
    }
    #[cfg(target_os = "macos")]
    if std::env::var("RBN_ISOLATED_STATE").as_deref() != Ok("1") {
        if Path::new("/Volumes").is_dir() {
            out.push(json!({"id":"volumes","kind":"volumes","name":"Volumes","path":"/Volumes","group":"local"}));
        }
        if let Ok(dirs) = fs::read_dir("/Volumes") {
            for entry in dirs.flatten() {
                let path = entry.path();
                if !path.is_dir() {
                    continue;
                }
                let Some(name) = entry.file_name().to_str().map(str::to_owned) else {
                    continue;
                };
                let network = filesystem(&path)
                    .is_some_and(|fs| ["smbfs", "afpfs", "nfs", "webdav"].contains(&fs.as_str()));
                let p = path.to_string_lossy();
                let mut row = json!({"id":format!("volume:{p}"),"kind":"volume","name":name,"path":p,"group":if network{"network"}else{"local"},"isRemovable":!network});
                if network {
                    row["connection"] = json!("mac-mounted");
                }
                out.push(row);
            }
        }
    }
    #[cfg(target_os = "linux")]
    {
        for base in ["/mnt", "/media", "/run/media"] {
            if let Ok(dirs) = fs::read_dir(base) {
                for entry in dirs.flatten() {
                    let path = entry.path();
                    if path.is_dir() {
                        out.push(json!({"id":format!("volume:{}",path.display()),"kind":"volume","name":entry.file_name().to_string_lossy(),"path":path.to_string_lossy(),"group":"local"}));
                    }
                }
            }
        }
    }
    #[cfg(windows)]
    {
        for drive in b'A'..=b'Z' {
            let p = format!("{}:/", drive as char);
            if !Path::new(&p).is_dir() {
                continue;
            }
            let wide = p.encode_utf16().chain(Some(0)).collect::<Vec<_>>();
            // SAFETY: nul-terminated UTF-16 string is valid for the synchronous call.
            let kind =
                unsafe { windows_sys::Win32::Storage::FileSystem::GetDriveTypeW(wide.as_ptr()) };
            let network = kind == 4;
            let mut row = json!({"id":format!("volume:{p}"),"kind":"volume","name":p,"path":p,"group":if network{"network"}else{"local"},"isRemovable":kind==2});
            if network {
                row["connection"] = json!("system-mounted");
            }
            out.push(row);
        }
    }
    out
}
#[cfg(target_os = "macos")]
pub fn filesystem(path: &Path) -> Option<String> {
    use std::{
        ffi::{CStr, CString},
        mem::MaybeUninit,
        os::unix::ffi::OsStrExt,
    };
    let name = CString::new(path.as_os_str().as_bytes()).ok()?;
    let mut info = MaybeUninit::<libc::statfs>::uninit();
    // SAFETY: output is initialized by successful statfs; input is nul-terminated.
    unsafe {
        if libc::statfs(name.as_ptr(), info.as_mut_ptr()) != 0 {
            return None;
        }
        let info = info.assume_init();
        Some(
            CStr::from_ptr(info.f_fstypename.as_ptr())
                .to_string_lossy()
                .into_owned(),
        )
    }
}
#[cfg(not(target_os = "macos"))]
pub fn filesystem(_path: &Path) -> Option<String> {
    None
}

pub fn supplied_locations(raw: &Value) -> crate::Result<Vec<Value>> {
    use crate::models::Endpoint;
    let mut result = Vec::new();
    let mut seen = std::collections::BTreeSet::new();
    let mut add = |entry: &Value, id: String, kind: &str, group: &str, removable: Option<bool>| {
        let Some(path) = entry["path"].as_str() else {
            return;
        };
        let Ok(endpoint) = Endpoint::parse(&json!({"remote":null,"path":path})) else {
            return;
        };
        if !Path::new(&endpoint.path).is_dir()
            || !seen.insert(endpoint.path.nfc().collect::<String>())
        {
            return;
        }
        let name = entry["name"].as_str().unwrap_or("");
        let mut value = json!({"id":id,"name":name,"path":endpoint.path,"kind":kind,"group":group});
        if let Some(v) = removable {
            value["isRemovable"] = json!(v);
        }
        if group == "network" {
            value["connection"] = json!("mac-mounted");
        }
        result.push(value);
    };
    add(&raw["home"], "home".into(), "home", "local", None);
    if let Some(folders) = raw["folders"].as_array() {
        for folder in folders {
            let kind = folder["kind"].as_str().unwrap_or("");
            if [
                "desktop",
                "documents",
                "downloads",
                "pictures",
                "music",
                "movies",
            ]
            .contains(&kind)
            {
                add(folder, kind.into(), kind, "local", None);
            }
        }
    }
    if raw["volumesRoot"].is_object() {
        add(
            &raw["volumesRoot"],
            "volumes".into(),
            "volumes",
            "local",
            None,
        );
    }
    if let Some(volumes) = raw["volumes"].as_array() {
        let mut volumes = volumes.iter().collect::<Vec<_>>();
        let name_order = crate::platform_text::NameOrder::new()?;
        crate::platform_text::stable_sort_by(&mut volumes, |a, b| {
            name_order.compare(
                a["name"].as_str().unwrap_or(""),
                b["name"].as_str().unwrap_or(""),
            )
        });
        for volume in volumes {
            let path = volume["path"].as_str().unwrap_or("");
            add(
                volume,
                format!("volume:{path}"),
                "volume",
                if volume["isLocal"] == false {
                    "network"
                } else {
                    "local"
                },
                volume["isRemovable"].as_bool(),
            );
        }
    }
    Ok(result)
}
