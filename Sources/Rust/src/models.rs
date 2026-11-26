use crate::Result;
use regex::Regex;
use serde_json::{Map, Value, json};
use std::{
    collections::{BTreeMap, BTreeSet, HashSet},
    net::IpAddr,
    path::{Component, Path, PathBuf},
    sync::LazyLock,
};
use unicode_normalization::UnicodeNormalization;

type Object = Map<String, Value>;
fn object(v: &Value) -> Result<&Object> {
    v.as_object().ok_or_else(|| "設定格式不正確。".into())
}
pub(crate) fn text<'a>(v: &'a Value, label: &str, max: usize) -> Result<&'a str> {
    v.as_str()
        .filter(|s| s.len() <= max && !s.bytes().any(|b| b < 32 || b == 127))
        .ok_or_else(|| format!("{label} 格式不正確，不能包含控制字元。"))
}
fn integer(v: &Value, label: &str, min: i64, max: i64) -> Result<i64> {
    v.as_f64()
        .filter(|n| n.is_finite() && n.fract() == 0.0 && *n >= min as f64 && *n <= max as f64)
        .map(|n| n as i64)
        .ok_or_else(|| format!("{label} 必須介於 {min} 與 {max}。"))
}
pub(crate) fn boolean(v: &Value, label: &str) -> Result<bool> {
    v.as_bool()
        .ok_or_else(|| format!("{label} 必須為開啟或關閉。"))
}
fn choice<'a>(v: &'a Value, choices: &[&str], label: &str) -> Result<&'a str> {
    text(v, label, 4096).and_then(|s| {
        if choices.contains(&s) {
            Ok(s)
        } else {
            Err(match label {
                "比較方式" => "檔案比較方式不正確。".into(),
                "刪除時機" => "刪除時機不正確。".into(),
                "符號連結" => "符號連結請選擇略過或保留。".into(),
                "傳輸模式" | "傳輸方向" | "連線位址模式" => {
                    format!("{label}不正確。")
                }
                "本機雜湊讀取" | "重試方式" => format!("{label}設定不正確。"),
                "語言" => "語言或外觀設定不正確。".into(),
                _ => format!("{label}不正確。"),
            })
        }
    })
}
fn strings(v: &Value, max_items: usize, max_len: usize, label: &str) -> Result<Vec<String>> {
    let items = v
        .as_array()
        .filter(|a| a.len() <= max_items)
        .ok_or_else(|| match label {
            "其他選項" => "其他選項最多 64 行，每行填入一個 --選項=值。".into(),
            "篩選規則" => "最多可設定 256 條篩選規則。".into(),
            "播放器參數" => "播放器參數最多 32 個，每行填入一個參數。".into(),
            _ => format!("{label}最多 {max_items} 項。"),
        })?;
    items
        .iter()
        .map(|v| text(v, label, max_len).map(str::to_owned))
        .collect()
}
fn merged(defaults: &Value, patch: &Value) -> Result<Value> {
    let mut out = object(defaults)?.clone();
    out.extend(object(patch)?.clone());
    Ok(Value::Object(out))
}
fn subset(v: &Value, keys: &[&str], shape: &str, unknown: &str) -> Result<()> {
    if v.as_object()
        .ok_or(shape)?
        .keys()
        .all(|s| keys.contains(&s.as_str()))
    {
        Ok(())
    } else {
        Err(unknown.into())
    }
}
fn key_str<'a>(v: &'a Value, k: &str) -> &'a str {
    v[k].as_str().unwrap_or_default()
}
fn flag(v: &Value, k: &str) -> bool {
    v[k] == true
}
pub(crate) fn absolute_local(s: &str) -> bool {
    absolute_for_platform(s, cfg!(windows))
}
fn absolute_for_platform(s: &str, windows: bool) -> bool {
    if s.bytes().any(|b| b < 32 || b == 127) {
        return false;
    }
    if windows {
        let n = s.replace('\\', "/");
        if let Some(rest) = n.strip_prefix("//") {
            let mut p = rest.split('/');
            return p.next().is_some_and(|v| !["", "?", ".", ".."].contains(&v))
                && p.next().is_some_and(|v| !["", ".", ".."].contains(&v));
        }
        let b = n.as_bytes();
        return b.len() >= 3 && b[0].is_ascii_alphabetic() && b[1] == b':' && b[2] == b'/';
    }
    s.starts_with('/')
}
fn filesystem_root(s: &str, windows: bool) -> bool {
    if !windows {
        return s == "/";
    }
    let path = s.replace('\\', "/");
    if let Some(unc) = path.strip_prefix("//") {
        return unc.split('/').filter(|s| !s.is_empty()).count() <= 2;
    }
    path.len() == 3 && path.ends_with(":/")
}
pub(crate) fn standardized(s: &str) -> Result<String> {
    if !absolute_local(s) {
        return Err("本機位置必須是完整的絕對路徑。".into());
    }
    let mut result = PathBuf::new();
    for c in Path::new(s).components() {
        match c {
            Component::ParentDir => {
                result.pop();
            }
            Component::CurDir => {}
            _ => result.push(c.as_os_str()),
        }
    }
    let path = result.to_str().ok_or("無法辨識本機路徑。")?;
    Ok(if cfg!(windows) {
        path.replace('\\', "/")
    } else {
        path.into()
    })
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Endpoint {
    pub remote: Option<String>,
    pub path: String,
}
impl Endpoint {
    pub fn parse(v: &Value) -> Result<Self> {
        let o = v.as_object().ok_or("請選擇位置。")?;
        let path = text(&v["path"], "路徑", 32768)?;
        match o.get("remote") {
            Some(Value::Null) => Ok(Self {
                remote: None,
                path: standardized(path)?,
            }),
            Some(raw) => {
                let name = text(raw, "遠端連線名稱", 512)?;
                if name.trim().is_empty() || name.contains([':', '/', '\\', ',', '[', ']']) {
                    return Err("遠端連線名稱格式不正確。".into());
                }
                let mut parts = vec![];
                for component in path.split('/') {
                    match component {
                        ".." => return Err("遠端路徑不能包含「..」。".into()),
                        "" | "." => {}
                        v => parts.push(v),
                    }
                }
                Ok(Self {
                    remote: Some(name.into()),
                    path: format!(
                        "{}{}",
                        if path.starts_with('/') { "/" } else { "" },
                        parts.join("/")
                    ),
                })
            }
            None => Err("遠端連線名稱 格式不正確，不能包含控制字元。".into()),
        }
    }
    pub fn value(&self) -> Value {
        json!({"remote":self.remote,"path":self.path})
    }
    pub fn target(&self) -> String {
        self.remote
            .as_ref()
            .map_or_else(|| self.path.clone(), |n| format!("{n}:{}", self.path))
    }
    pub fn valid_name(name: &str) -> Result<()> {
        if name.len() > 4096 || name.bytes().any(|b| b < 32 || b == 127) {
            return Err("名稱 格式不正確，不能包含控制字元。".into());
        }
        if name.trim().is_empty() || matches!(name, "." | "..") || name.contains('/') {
            return Err("名稱不能留白、使用「.」「..」或包含斜線。".into());
        }
        Ok(())
    }
    pub fn child(&self, name: &str) -> Result<Self> {
        Self::valid_name(name)?;
        if cfg!(windows) && self.remote.is_none() && name.contains(['\\', ':']) {
            return Err("Windows 檔案名稱不能包含反斜線或冒號。".into());
        }
        let sep = if self.path.is_empty() || self.path.ends_with('/') {
            ""
        } else {
            "/"
        };
        Ok(Self {
            remote: self.remote.clone(),
            path: format!("{}{sep}{name}", self.path),
        })
    }
}
pub fn default_options() -> Value {
    json!({"transfers":4,"checkers":8,"bandwidth":"","comparison":"default","skipExisting":false,"updateOnly":false,
    "createEmptyDirs":true,"exclude":[".DS_Store","._*"],"include":[],"retries":3,"maxDelete":-1,"preserveMetadata":false,
    "driveSharedWithMe":false,"deleteMode":"during","deleteExcluded":false,"ignoreChecksum":false,"modifyWindow":"",
    "checkFirst":false,"noTraverse":false,"fastList":false,"oneFileSystem":false,"noUpdateModtime":false,"minSize":"",
    "maxSize":"","minAge":"","maxAge":"","maxDepth":-1,"connectTimeout":"","ioTimeout":"","lowLevelRetries":10,"retrySleep":"",
    "extraArgs":[],"localHashPolicy":"none","symlinkMode":"skip"})
}
pub fn legacy_options(v: &Value) -> Result<Value> {
    merged(
        &json!({"maxDelete":100,"deleteMode":"after","localHashPolicy":"default"}),
        v,
    )
}
static SIZE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^([0-9]+(?:\.[0-9]+)?)([bB]|[kKmMgGtTpPeE](?:[iI]|i[bB])?)?$")
        .expect("size grammar")
});
static DURATION: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"([0-9]+(?:\.[0-9]+)?)(ns|us|ms|s|m|h|d|w|M|y)").expect("duration grammar")
});
static RATE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^[0-9]+(?:\.[0-9]+)?$").expect("rate grammar"));
fn bytes(s: &str) -> Option<f64> {
    let cap = SIZE.captures(s)?;
    let n = cap[1].parse::<f64>().ok()?;
    let power = match cap
        .get(2)
        .and_then(|v| v.as_str().bytes().next())
        .map(|b| b.to_ascii_lowercase())
    {
        Some(b'b') => 0,
        Some(b'm') => 2,
        Some(b'g') => 3,
        Some(b't') => 4,
        Some(b'p') => 5,
        Some(b'e') => 6,
        _ => 1,
    };
    let total = n * 1024_f64.powi(power);
    (total.is_finite() && total <= i64::MAX as f64).then_some(total)
}
fn duration(s: &str) -> Option<f64> {
    if s == "0" {
        return Some(0.0);
    }
    let mut offset = 0;
    let mut total = 0.0;
    for c in DURATION.captures_iter(s) {
        let m = c.get(0)?;
        if m.start() != offset {
            return None;
        }
        offset = m.end();
        let w = match &c[2] {
            "ns" => 1e-9,
            "us" => 1e-6,
            "ms" => 1e-3,
            "s" => 1.,
            "m" => 60.,
            "h" => 3600.,
            "d" => 86400.,
            "w" => 604800.,
            "M" => 2592000.,
            "y" => 31536000.,
            _ => return None,
        };
        total += c[1].parse::<f64>().ok()? * w;
    }
    (offset > 0 && offset == s.len() && total <= 9e9).then_some(total)
}
fn unit(v: &Value, key: &str, parse: fn(&str) -> Option<f64>) -> Result<Option<f64>> {
    let label = match key {
        "minSize" => "最小檔案大小",
        "maxSize" => "最大檔案大小",
        "minAge" => "最小檔案年齡",
        "maxAge" => "最大檔案年齡",
        "modifyWindow" => "時間容許誤差",
        "connectTimeout" => "連線逾時",
        "ioTimeout" => "傳輸閒置逾時",
        "retrySleep" => "重試間隔",
        _ => key,
    };
    let s = text(v, label, 64)?;
    if s.is_empty() {
        Ok(None)
    } else {
        parse(s).map(Some).ok_or_else(|| {
            if matches!(key, "minSize" | "maxSize") {
                format!("{label}請填入 10M、512K 等大小；留空代表不限。")
            } else {
                format!("{label}請填入 30s、5m、24h、7d 等時間。")
            }
        })
    }
}
pub fn extra_arguments(v: &Value) -> Result<Vec<String>> {
    let mut result = vec![];
    let mut seen = HashSet::new();
    for item in strings(v, 64, 4096, "其他選項")? {
        let item = item.trim();
        let (k, arg) = item
            .split_once('=')
            .map_or((item, None), |(k, v)| (k, Some(v)));
        let flag_name = k.strip_prefix("--").unwrap_or("");
        if !flag_name
            .bytes()
            .next()
            .is_some_and(|b| b.is_ascii_lowercase())
            || !flag_name
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
            || !seen.insert(k.to_string())
        {
            return Err(
                "其他選項不可包含子命令、路徑、單字元短參數或重複項目，每行請用 --選項=值 格式。"
                    .into(),
            );
        }
        let val = arg.unwrap_or("");
        let missing = || format!("{k} 請使用 --選項=值。");
        match k {
            "--disable-http2"
            | "--no-gzip-encoding"
            | "--use-mmap"
            | "--local-no-preallocate"
            | "--local-no-clone"
            | "--server-side-across-configs"
            | "--drive-acknowledge-abuse"
            | "--s3-no-check-bucket" => {
                if arg.is_some() && !matches!(val, "true" | "false") {
                    return Err(format!("{k} 只接受 true 或 false。"));
                }
            }
            _ if val.is_empty() => return Err(missing()),
            "--buffer-size"
            | "--max-buffer-memory"
            | "--multi-thread-cutoff"
            | "--multi-thread-chunk-size"
            | "--multi-thread-write-buffer-size"
            | "--max-transfer"
            | "--drive-chunk-size"
            | "--s3-chunk-size"
            | "--s3-upload-cutoff"
            | "--sftp-chunk-size"
            | "--onedrive-chunk-size"
            | "--b2-chunk-size"
            | "--azureblob-chunk-size"
            | "--azureblob-upload-cutoff" => {
                if val.len() > 64 {
                    return Err(format!("{k} 格式不正確，不能包含控制字元。"));
                }
                if bytes(val).is_none() {
                    return Err(format!("{k}請填入 10M、512K 等大小；留空代表不限。"));
                }
            }
            "--multi-thread-streams"
            | "--max-backlog"
            | "--tpslimit-burst"
            | "--drive-pacer-burst"
            | "--s3-upload-concurrency"
            | "--sftp-concurrency"
            | "--ftp-concurrency"
            | "--b2-upload-concurrency"
            | "--azureblob-upload-concurrency" => {
                if val.len() > 7 || !val.bytes().all(|b| b.is_ascii_digit()) {
                    return Err(format!("{k} 必須是 0 至 9,999,999 的整數。"));
                }
            }
            "--max-duration" | "--drive-pacer-min-sleep" | "--expect-continue-timeout" => {
                unit(&json!(val), k, duration)?;
            }
            "--tpslimit" => {
                if !RATE.is_match(val) || !val.parse::<f64>().is_ok_and(|n| n <= 1000000.0) {
                    return Err("每秒請求上限格式不正確。".into());
                }
            }
            "--cutoff-mode" => {
                if !["HARD", "SOFT", "CAUTIOUS"]
                    .iter()
                    .any(|v| v.eq_ignore_ascii_case(val))
                {
                    return Err("cutoff-mode 請填入 HARD、SOFT 或 CAUTIOUS。".into());
                }
            }
            "--order-by" => {
                let (order, dir) = val
                    .split_once(',')
                    .map_or((val, None), |(o, d)| (o, Some(d)));
                if !matches!(order, "size" | "name" | "modtime")
                    || !dir.is_none_or(|d| {
                        matches!(d, "ascending" | "asc" | "descending" | "desc" | "mixed")
                    })
                {
                    return Err("order-by 格式不正確。".into());
                }
            }
            _ => {
                return Err(format!(
                    "{k} 不在支援的額外參數中。請改用畫面上的設定；帳號與憑證請至「帳號設定」或 Config 設定。"
                ));
            }
        }
        result.push(item.into());
    }
    Ok(result)
}
pub fn validate_options(raw: &Value) -> Result<Value> {
    let mut o = default_options();
    for (k, v) in raw.as_object().ok_or("傳輸選項格式不正確。")? {
        if o.get(k).is_some() {
            o[k] = v.clone();
        }
    }
    for (k, lo, hi) in [
        ("transfers", 1, 64),
        ("checkers", 1, 128),
        ("retries", 1, 100),
        ("maxDelete", -1, 100000),
        ("lowLevelRetries", 1, 100),
        ("maxDepth", -1, 100000),
    ] {
        let label = match k {
            "transfers" => "同時傳輸數",
            "checkers" => "同時檢查檔案數",
            "retries" => "工作嘗試次數",
            "maxDelete" => "最多刪除數",
            "lowLevelRetries" => "連線重試次數",
            _ => "目錄深度",
        };
        o[k] = json!(integer(&o[k], label, lo, hi)?);
    }
    for k in [
        "skipExisting",
        "updateOnly",
        "createEmptyDirs",
        "preserveMetadata",
        "driveSharedWithMe",
        "deleteExcluded",
        "ignoreChecksum",
        "checkFirst",
        "noTraverse",
        "fastList",
        "oneFileSystem",
        "noUpdateModtime",
    ] {
        boolean(&o[k], "傳輸選項")?;
    }
    let bw = text(&o["bandwidth"], "限速", 32)?;
    if !bw.is_empty() && bw != "off" && bytes(bw).is_none() {
        return Err("限速請填入 10M、512K 或 off；留白表示不限速。".into());
    }
    let cmp = choice(
        &o["comparison"],
        &[
            "default",
            "checksum",
            "modtime",
            "size",
            "checksum-only",
            "none",
        ],
        "比較方式",
    )?;
    if cmp == "none" && (flag(&o, "skipExisting") || flag(&o, "updateOnly")) {
        return Err(
            "「全部重新傳輸」不可同時勾選略過已存在或較新的檔案，請改選其他比對方式。".into(),
        );
    }
    choice(&o["deleteMode"], &["before", "during", "after"], "刪除時機")?;
    let policy = choice(&o["localHashPolicy"], &["default", "none"], "本機雜湊讀取")?;
    if policy == "none" && matches!(cmp, "checksum" | "checksum-only") {
        return Err("停用本機雜湊讀取時，不能使用雜湊比對。".into());
    }
    choice(&o["symlinkMode"], &["skip", "preserve"], "符號連結")?;
    let minimum_size = unit(&o["minSize"], "minSize", bytes)?;
    let maximum_size = unit(&o["maxSize"], "maxSize", bytes)?;
    if matches!((minimum_size, maximum_size), (Some(a), Some(b)) if a > b) {
        return Err("最小檔案大小不能大於最大檔案大小。".into());
    }
    let minimum_age = unit(&o["minAge"], "minAge", duration)?;
    let maximum_age = unit(&o["maxAge"], "maxAge", duration)?;
    for k in ["modifyWindow", "connectTimeout", "ioTimeout", "retrySleep"] {
        unit(&o[k], k, duration)?;
    }
    if matches!((minimum_age, maximum_age), (Some(a), Some(b)) if a > b) {
        return Err("最小檔案年齡不能大於最大檔案年齡。".into());
    }
    for k in ["include", "exclude"] {
        o[k] = json!(
            strings(&o[k], 256, 4096, "篩選規則")?
                .into_iter()
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
        );
    }
    o["extraArgs"] = json!(extra_arguments(&o["extraArgs"])?);
    Ok(o)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Selection {
    pub name: String,
    pub is_dir: bool,
}
impl Selection {
    pub fn parse(value: &Value) -> Result<Vec<Self>> {
        let mut selection = vec![];
        let mut names = HashSet::new();
        for item in value
            .as_array()
            .filter(|a| a.len() <= 10000 && a.iter().all(Value::is_object))
            .ok_or("單次最多選取 10,000 個項目。")?
        {
            let name = text(&item["name"], "名稱", 4096)?;
            Endpoint::valid_name(name)?;
            if !names.insert(name.nfc().collect::<String>()) {
                return Err("選取項目不能重複。".into());
            }
            selection.push(Selection {
                name: name.into(),
                is_dir: boolean(&item["isDir"], "項目類型")?,
            });
        }
        Ok(selection)
    }
}
#[derive(Debug, Clone)]
pub struct TransferRequest {
    pub source: Endpoint,
    pub destination: Endpoint,
    pub mode: String,
    pub options: Value,
    pub selection: Vec<Selection>,
    pub dry_run: bool,
    pub direction: Option<String>,
    pub label: Option<String>,
}
impl TransferRequest {
    pub fn parse(v: &Value) -> Result<Self> {
        let r = Self::decode(v)?;
        r.validate_operation()?;
        Ok(r)
    }
    pub fn parse_saved(v: &Value) -> Result<Self> {
        let mut saved = v.clone();
        saved["options"] = legacy_options(&v["options"])?;
        Self::decode(&saved)
    }
    fn decode(v: &Value) -> Result<Self> {
        let o = v.as_object().ok_or("傳輸設定格式不正確。")?;
        let source = Endpoint::parse(&v["source"])?;
        let destination = Endpoint::parse(&v["destination"])?;
        let mode = choice(&v["mode"], &["copy", "sync", "move"], "傳輸模式")?.into();
        let options = validate_options(&v["options"])?;
        let selection = Selection::parse(&v["selection"])?;
        Ok(Self {
            source,
            destination,
            mode,
            options,
            selection,
            dry_run: boolean(&v["dryRun"], "預演設定")?,
            direction: o
                .get("direction")
                .map(|v| choice(v, &["lr", "rl"], "傳輸方向").map(str::to_owned))
                .transpose()?,
            label: o
                .get("label")
                .map(|v| text(v, "工作名稱", 800).map(str::to_owned))
                .transpose()?,
        })
    }
    pub fn value(&self) -> Value {
        let mut v = json!({"source":self.source.value(),"destination":self.destination.value(),"mode":self.mode,"options":self.options,
            "selection":self.selection.iter().map(|s|json!({"name":s.name,"isDir":s.is_dir})).collect::<Vec<_>>(),"dryRun":self.dry_run});
        if let Some(s) = &self.label {
            v["label"] = json!(s);
        }
        if let Some(s) = &self.direction {
            v["direction"] = json!(s);
        }
        v
    }
    pub fn validate_operation(&self) -> Result<()> {
        let exclude = flag(&self.options, "deleteExcluded");
        match self.mode.as_str(){
            "sync" if self.selection.iter().any(|s|!s.is_dir)=>Err("同步只能勾選資料夾；請取消勾選個別檔案，或改用複製／移動。".into()),
            "sync" if !self.selection.is_empty()&&exclude=>Err("只同步勾選的資料夾時，請關閉「刪除目標中符合排除規則的檔案」，以免刪到未勾選的目標檔案。".into()),
            "sync" if flag(&self.options,"noTraverse")=>Err("同步需要列出目標目錄，請關閉「不先列出目標目錄（複製、移動）」。".into()),
            "move" if flag(&self.options,"updateOnly")=>Err("移動時若開啟「略過目標較新的檔案」，被略過的來源檔案仍可能被刪除；請關閉此選項或改用複製。".into()),
            "copy"|"move" if exclude=>Err("「刪除目標中符合排除規則的檔案」只適用於同步。".into()),
            "copy"|"move"|"sync"=>Ok(()),_=>Err("傳輸模式不正確。".into())
        }
    }
    pub fn arguments(&self, filter: Option<&Path>) -> Result<Vec<String>> {
        Ok(crate::local::local_arguments(
            self.base_arguments(filter)?,
            self,
        ))
    }
    pub fn base_arguments(&self, filter: Option<&Path>) -> Result<Vec<String>> {
        self.validate_operation()?;
        let o = validate_options(&self.options)?;
        let mut args = vec![self.mode.clone()];
        args.extend(
            [
                "--use-json-log",
                "--stats=1s",
                "--stats-log-level=INFO",
                "--log-level=INFO",
                "--ask-password=false",
            ]
            .map(str::to_owned),
        );
        for k in ["transfers", "checkers", "retries"] {
            args.push(format!("--{k}={}", o[k]));
        }
        args.push("--color=NEVER".into());
        if !key_str(&o, "bandwidth").is_empty() {
            args.push(format!("--bwlimit={}", key_str(&o, "bandwidth")));
        }
        let comparison: &[&str] = match key_str(&o, "comparison") {
            "checksum" => &["--checksum"],
            "modtime" => &["--ignore-size"],
            "size" => &["--size-only"],
            "checksum-only" => &["--checksum", "--ignore-size"],
            "none" => &["--ignore-times"],
            _ => &[],
        };
        args.extend(comparison.iter().map(|s| s.to_string()));
        for (k, a) in [
            ("skipExisting", "--ignore-existing"),
            ("updateOnly", "--update"),
            ("createEmptyDirs", "--create-empty-src-dirs"),
            ("preserveMetadata", "--metadata"),
        ] {
            if flag(&o, k) {
                args.push(a.into());
            }
        }
        if o["symlinkMode"] == "preserve" {
            args.push("--links".into());
        }
        for (k, a) in [
            ("driveSharedWithMe", "--drive-shared-with-me"),
            ("ignoreChecksum", "--ignore-checksum"),
            ("checkFirst", "--check-first"),
            ("noTraverse", "--no-traverse"),
            ("fastList", "--fast-list"),
            ("oneFileSystem", "--one-file-system"),
            ("noUpdateModtime", "--no-update-modtime"),
        ] {
            if flag(&o, k) {
                args.push(a.into());
            }
        }
        for (k, a) in [
            ("minSize", "min-size"),
            ("maxSize", "max-size"),
            ("minAge", "min-age"),
            ("maxAge", "max-age"),
            ("connectTimeout", "contimeout"),
            ("ioTimeout", "timeout"),
            ("retrySleep", "retries-sleep"),
        ] {
            let v = key_str(&o, k);
            if !v.is_empty() {
                args.push(format!("--{a}={v}"));
            }
        }
        let window = key_str(&o, "modifyWindow");
        let window = if window.is_empty() {
            crate::local::automatic_modify_window(self).unwrap_or_default()
        } else {
            window
        };
        if !window.is_empty() {
            args.push(format!("--modify-window={window}"));
        }
        if o["maxDepth"].as_i64().is_some_and(|i| i >= 0) {
            args.push(format!("--max-depth={}", o["maxDepth"]));
        }
        args.push(format!("--low-level-retries={}", o["lowLevelRetries"]));
        if o["localHashPolicy"] == "none" {
            args.push("--local-hashes=none".into());
        }
        if self.mode == "sync" {
            args.extend([
                format!("--delete-{}", key_str(&o, "deleteMode")),
                format!("--max-delete={}", o["maxDelete"]),
            ]);
            if flag(&o, "deleteExcluded") {
                args.push("--delete-excluded".into());
            }
        }
        args.extend(extra_arguments(&o["extraArgs"])?);
        if self.dry_run {
            args.push("--dry-run".into());
        }
        if let Some(path) = filter {
            args.push(format!(
                "--filter-from={}",
                path.to_str().ok_or("無法辨識篩選檔路徑。")?
            ));
        }
        args.extend(["--".into(), self.source.target(), self.destination.target()]);
        Ok(args)
    }
}
pub fn escape_filter(s: &str) -> String {
    let mut out = String::new();
    for c in s.chars() {
        if "\\*?[]{}".contains(c) {
            out.push('\\');
        }
        if c == ' ' {
            out.push_str("[ ]");
        } else {
            out.push(c);
        }
    }
    out
}
fn patterns<'a>(v: &'a Value, key: &str) -> impl Iterator<Item = &'a str> {
    v[key]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
}
pub fn option_filter_rules(o: &Value) -> Vec<String> {
    let mut v: Vec<_> = patterns(o, "exclude").map(|s| format!("- {s}")).collect();
    if patterns(o, "include").next().is_some() {
        v.extend(patterns(o, "include").map(|s| format!("+ {s}")));
        v.push("- **".into());
    }
    v
}
pub fn selection_filter_rules(r: &TransferRequest) -> Vec<String> {
    if r.selection.is_empty() {
        return option_filter_rules(&r.options);
    }
    let mut v: Vec<_> = patterns(&r.options, "exclude")
        .map(|s| format!("- {s}"))
        .collect();
    v.extend(r.selection.iter().map(|s| {
        format!(
            "+ /{}{}",
            escape_filter(&s.name),
            if s.is_dir { "/**" } else { "" }
        )
    }));
    v.push("- **".into());
    v
}
pub fn filter_contents(r: &TransferRequest) -> Option<String> {
    // The caller uses exact_filter_rules after a filtered lsjson for a selection AND includes.
    if !r.selection.is_empty() && patterns(&r.options, "include").next().is_some() {
        return Some("- **\n".into());
    }
    let v = selection_filter_rules(r);
    (!v.is_empty()).then(|| v.join("\n") + "\n")
}
pub fn exact_filter_rules(r: &TransferRequest, entries: &[Value]) -> Result<Vec<String>> {
    let selected: HashSet<_> = r
        .selection
        .iter()
        .map(|s| s.name.nfc().collect::<String>())
        .collect();
    let dirs: HashSet<_> = r
        .selection
        .iter()
        .filter(|s| s.is_dir)
        .map(|s| s.name.nfc().collect::<String>())
        .collect();
    let mut allowed = BTreeMap::new();
    for e in entries {
        let path = text(&e["Path"], "相對路徑", 32768)?;
        let mut components = path.split('/').filter(|part| !part.is_empty());
        if path.is_empty() || path.starts_with('/') || components.clone().any(|part| part == "..") {
            return Err("遠端回傳不安全的相對路徑。".into());
        }
        let top = components
            .next()
            .unwrap_or_default()
            .nfc()
            .collect::<String>();
        if selected.contains(&path.nfc().collect::<String>())
            || (components.next().is_some() && dirs.contains(&top))
        {
            let is_dir = e["IsDir"].as_bool() == Some(true) || e["IsDir"].as_f64() == Some(1.0);
            let rule = format!(
                "+ /{}{}",
                escape_filter(path),
                if is_dir { "/" } else { "" }
            );
            // Swift Set<String> compares canonical spellings and retains the first original spelling.
            allowed
                .entry(rule.nfc().collect::<String>())
                .or_insert(rule);
            if allowed.len() > 250000 {
                return Err("選取清單超過 250,000 個項目，請縮小來源範圍。".into());
            }
        }
    }
    let mut result: Vec<_> = allowed.into_values().collect();
    result.push("- **".into());
    Ok(result)
}
pub fn validate_pair(r: &TransferRequest) -> Result<()> {
    let (s, d) = (&r.source, &r.destination);
    if s.remote.is_none() && !Path::new(&s.path).is_dir() {
        return Err("來源資料夾不存在或無法讀取。".into());
    }
    if d.remote.is_none() {
        let p = Path::new(&d.path);
        if filesystem_root(&d.path, cfg!(windows)) {
            return Err("請選擇根目錄之下的目的資料夾。".into());
        }
        match p.metadata() {
            Ok(m) if !m.is_dir() => return Err("目的位置已存在同名檔案，請選擇資料夾。".into()),
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => return Err(e.to_string()),
            _ => {}
        }
        if s.remote.is_none() {
            let from = crate::storage::canonical_local(&s.path)?;
            let resolved = crate::storage::canonical_local(&d.path)?;
            if from.starts_with(&resolved) || resolved.starts_with(&from) {
                return Err("來源與目標不可相同，也不可互為上下層目錄（含符號連結）。".into());
            }
        }
    } else if let (Some(sr), Some(dr)) = (&s.remote, &d.remote) {
        if sr.nfc().eq(dr.nfc()) {
            let a = s.path.trim_matches('/').nfc().collect::<String>();
            let b = d.path.trim_matches('/').nfc().collect::<String>();
            if a.is_empty()
                || b.is_empty()
                || a == b
                || a.starts_with(&(b.clone() + "/"))
                || b.starts_with(&(a + "/"))
            {
                return Err("同一遠端的來源與目標不可相同，也不可互為上下層目錄。".into());
            }
        }
    }
    Ok(())
}

pub fn default_network() -> Value {
    json!({"bindMode":"auto","bindAddress":"","connectTimeout":"1m","ioTimeout":"5m","tpsLimit":0.0,"tpsBurst":1,"userAgent":"","disableHTTP2":false})
}
fn validate_network(v: &Value) -> Result<Value> {
    subset(
        v,
        &[
            "bindMode",
            "bindAddress",
            "connectTimeout",
            "ioTimeout",
            "tpsLimit",
            "tpsBurst",
            "userAgent",
            "disableHTTP2",
        ],
        "網路設定格式不正確。",
        "網路設定包含不支援的選項。",
    )?;
    let mut n = merged(&default_network(), v)?;
    let mode = choice(
        &n["bindMode"],
        &["auto", "ipv4", "ipv6", "address"],
        "連線位址模式",
    )?;
    let address = text(&n["bindAddress"], "本機 IP 位址", 128)?.trim();
    if (mode == "address" && address.is_empty())
        || (!address.is_empty() && address.parse::<IpAddr>().is_err())
    {
        return Err(
            "本機 IP 位址請填入有效的 IPv4 或 IPv6 位址（請勿填網卡名稱、網址或連接埠）。".into(),
        );
    }
    n["bindAddress"] = json!(address);
    for k in ["connectTimeout", "ioTimeout"] {
        unit(&n[k], k, duration)?;
    }
    let rate = n["tpsLimit"]
        .as_f64()
        .filter(|r| (0.0..=1000000.0).contains(r))
        .ok_or("每秒請求上限格式不正確。")?;
    n["tpsLimit"] = json!(rate);
    n["tpsBurst"] = json!(integer(&n["tpsBurst"], "瞬間請求上限", 1, 1000000)?);
    text(&n["userAgent"], "User-Agent", 1024)?;
    boolean(&n["disableHTTP2"], "停用 HTTP/2")?;
    Ok(n)
}
pub fn network_arguments(n: &Value) -> Result<Vec<String>> {
    let n = validate_network(n)?;
    let mut a = vec![];
    match key_str(&n, "bindMode") {
        "ipv4" => a.push("--bind=0.0.0.0".into()),
        "ipv6" => a.push("--bind=::0".into()),
        "address" => a.push(format!("--bind={}", key_str(&n, "bindAddress"))),
        _ => {}
    }
    for (k, flag) in [
        ("connectTimeout", "contimeout"),
        ("ioTimeout", "timeout"),
        ("userAgent", "user-agent"),
    ] {
        let v = key_str(&n, k);
        if !v.is_empty() {
            a.push(format!("--{flag}={v}"));
        }
    }
    a.extend([
        format!("--tpslimit={}", n["tpsLimit"]),
        format!("--tpslimit-burst={}", n["tpsBurst"]),
        format!("--disable-http2={}", n["disableHTTP2"]),
    ]);
    Ok(a)
}
pub fn default_settings(directory: &Path) -> Value {
    json!({"rclonePath":"","rcloneDirectory":directory,"configPath":"","language":"system","theme":"purple-auto","interfaceScale":100,
    "autoCheckUpdates":true,"skippedRcloneVersion":"","settingsRevision":0,"settingsSchemaVersion":7,"paneColumnWidths":{},"defaultTransferOptions":default_options(),
    "hiddenBuiltinPresets":[],"maxConcurrentJobs":0,"retryScope":"failed","proxyMode":"system","httpProxy":"","httpsProxy":"","noProxy":"",
    "networkOptions":default_network(),"defaultRcloneOptions":[],"showStatusItem":false,"notifyOnCompletion":false,"bounceDockOnCompletion":true,
    "showHiddenFiles":true,"showFolderIcons":true,"showFileIcons":true,"alternatingRows":true,"streamPlayerPath":"","streamPlayerArguments":["-"],"initialLocations":{},"savedWorkspace":null})
}
fn network_key(k: &str) -> bool {
    matches!(k, "--tpslimit" | "--tpslimit-burst" | "--disable-http2")
}
pub fn load_settings(saved: &Value, defaults: &Value) -> Result<Value> {
    object(saved)?;
    let mut raw = saved.clone();
    let schema = raw["settingsSchemaVersion"].as_i64().unwrap_or(0);
    if schema < 4 {
        if raw["maxConcurrentJobs"] == 2 {
            raw["maxConcurrentJobs"] = json!(0);
        }
        if let Some(o) = raw
            .get_mut("defaultTransferOptions")
            .and_then(Value::as_object_mut)
        {
            for (k, old) in [("connectTimeout", "1m"), ("ioTimeout", "5m")] {
                if o.get(k).and_then(Value::as_str) == Some(old) {
                    o.insert(k.into(), json!(""));
                }
            }
        }
        let mut net = raw["networkOptions"]
            .as_object()
            .cloned()
            .unwrap_or_default();
        if let Some(args) = raw["defaultRcloneOptions"].as_array() {
            let mut keep = Vec::new();
            for arg in args {
                let s = arg.as_str().unwrap_or_default();
                let (k, v) = s.split_once('=').unwrap_or((s, "true"));
                if !network_key(k) || extra_arguments(&json!([arg])).is_err() {
                    keep.push(arg.clone());
                    continue;
                }
                let (key, value) = match k {
                    "--tpslimit" => ("tpsLimit", json!(v.parse::<f64>().unwrap_or_default())),
                    "--tpslimit-burst" => ("tpsBurst", json!(v.parse::<i64>().unwrap_or(1).max(1))),
                    _ => ("disableHTTP2", json!(v == "true")),
                };
                net.entry(key.to_owned()).or_insert(value);
            }
            raw["defaultRcloneOptions"] = json!(keep);
        }
        raw["networkOptions"] = Value::Object(net);
    }
    if schema < 5 {
        if let Some(o) = raw
            .get_mut("defaultTransferOptions")
            .filter(|o| o.is_object())
        {
            if o["maxDelete"] == 100 {
                o["maxDelete"] = json!(-1);
            }
            if o["deleteMode"] == "after" {
                o["deleteMode"] = json!("during");
            }
            let checksum = matches!(o["comparison"].as_str(), Some("checksum" | "checksum-only"));
            if !checksum && o["localHashPolicy"] == "default" {
                o["localHashPolicy"] = json!("none");
            }
            if checksum && o.get("localHashPolicy").is_none() {
                o["localHashPolicy"] = json!("default");
            }
        }
        if let Some(w) = raw
            .get_mut("savedWorkspace")
            .filter(|v| v["options"].is_object())
        {
            w["options"] = legacy_options(&w["options"])?;
        }
    }
    if schema < 7 {
        if let Some(s) = raw["interfaceScale"]
            .as_i64()
            .filter(|n| [80, 90, 100, 110, 125].contains(n))
        {
            raw["interfaceScale"] = json!(s + 10);
        }
    }
    raw["settingsSchemaVersion"] = json!(7);
    settings(&raw, defaults, false)
}
pub fn validate_settings(raw: &Value, defaults: &Value) -> Result<Value> {
    settings(raw, defaults, true)
}
fn settings(raw: &Value, defaults: &Value, patch: bool) -> Result<Value> {
    let incoming = object(raw)?;
    let m = merged(defaults, raw)?;
    let mut out = default_settings(Path::new(""));
    for (k, v) in object(&m)? {
        if out.get(k).is_some() {
            out[k] = v.clone();
        }
    }
    for k in [
        "rclonePath",
        "rcloneDirectory",
        "configPath",
        "streamPlayerPath",
    ] {
        let label = match k {
            "rclonePath" => "rclone 執行檔",
            "rcloneDirectory" => "rclone 資料夾",
            "configPath" => "設定檔",
            _ => "播放器",
        };
        let s = text(&m[k], label, 32768)?;
        if !s.is_empty() {
            if !absolute_local(s) {
                return Err(format!("{label}必須使用絕對路徑。"));
            }
            out[k] = json!(standardized(s)?);
        }
    }
    if incoming.contains_key("rclonePath") && !key_str(&out, "rclonePath").is_empty() {
        out["rcloneDirectory"] = json!(
            Path::new(key_str(&out, "rclonePath"))
                .parent()
                .ok_or("rclone 執行檔路徑不正確。")?
        );
    } else if patch
        && incoming.contains_key("rcloneDirectory")
        && (incoming.len() <= 2 || raw["rcloneDirectory"] != defaults["rcloneDirectory"])
        && !key_str(&out, "rcloneDirectory").is_empty()
    {
        out["rclonePath"] = json!(standardized(
            &Path::new(key_str(&out, "rcloneDirectory"))
                .join(if cfg!(windows) {
                    "rclone.exe"
                } else {
                    "rclone"
                })
                .to_string_lossy()
        )?);
    }
    choice(&m["language"], &["system", "zh-TW", "en", "ja"], "語言")?;
    let theme = match text(&m["theme"], "外觀", 4096)? {
        "dark" => "blue-dark",
        "light" => "blue-light",
        "system" => "purple-auto",
        v => v,
    };
    if !theme.split_once('-').is_some_and(|(a, b)| {
        ["purple", "blue", "green"].contains(&a) && ["dark", "light", "auto"].contains(&b)
    }) {
        return Err("語言或外觀設定不正確。".into());
    }
    out["theme"] = json!(theme);
    let scale = integer(&m["interfaceScale"], "介面比例", 80, 135)?;
    if ![80, 90, 100, 110, 120, 125, 135].contains(&scale) {
        return Err("請選擇支援的介面比例。".into());
    }
    out["interfaceScale"] = json!(scale);
    for k in [
        "autoCheckUpdates",
        "showStatusItem",
        "notifyOnCompletion",
        "bounceDockOnCompletion",
        "showHiddenFiles",
        "showFolderIcons",
        "showFileIcons",
        "alternatingRows",
    ] {
        boolean(
            &m[k],
            if k == "autoCheckUpdates" {
                "啟動時檢查更新"
            } else {
                "介面設定"
            },
        )?;
    }
    text(&m["skippedRcloneVersion"], "略過版本", 128)?;
    out["settingsRevision"] = json!(integer(
        &m["settingsRevision"],
        "設定版本",
        0,
        9007199254740990
    )?);
    out["settingsSchemaVersion"] = json!(7);
    out["maxConcurrentJobs"] = json!(integer(
        &m["maxConcurrentJobs"],
        "同時執行的工作數",
        0,
        128
    )?);
    if !matches!(m["retryScope"].as_str(), Some("full" | "failed")) {
        return Err("重試方式設定不正確。".into());
    }
    let hidden = strings(&m["hiddenBuiltinPresets"], 6, 32, "內建方案")
        .map_err(|_| "內建方案設定格式不正確。")?
        .into_iter()
        .collect::<BTreeSet<_>>();
    if !hidden.iter().all(|s| {
        [
            "local-nas",
            "nas-cloud",
            "local-cloud",
            "local-local",
            "cloud-cloud",
            "cloud-local",
        ]
        .contains(&s.as_str())
    }) {
        return Err("內建方案設定格式不正確。".into());
    }
    out["hiddenBuiltinPresets"] = json!(hidden);
    let empty = json!({});
    out["defaultTransferOptions"] = validate_options(
        &merged(
            &defaults["defaultTransferOptions"],
            raw.get("defaultTransferOptions").unwrap_or(&empty),
        )
        .map_err(|_| "預設傳輸選項格式不正確。")?,
    )?;
    let extra = extra_arguments(&m["defaultRcloneOptions"])?;
    if extra
        .iter()
        .any(|a| network_key(a.split('=').next().unwrap_or("")))
    {
        return Err("每秒請求上限與停用 HTTP/2 請直接在「rclone 連線」設定，並從「所有傳輸都加上的參數」移除重複項目。".into());
    }
    out["defaultRcloneOptions"] = json!(extra);
    out["networkOptions"] = validate_network(
        &merged(
            &defaults["networkOptions"],
            raw.get("networkOptions").unwrap_or(&empty),
        )
        .map_err(|_| "網路設定格式不正確。")?,
    )?;
    let widths = raw.get("paneColumnWidths").unwrap_or(&empty);
    subset(
        widths,
        &["left", "right"],
        "欄寬設定格式不正確。",
        "只能設定左右面板的欄寬。",
    )?;
    let mut valid = json!({});
    for side in ["left", "right"] {
        let combined = merged(
            defaults["paneColumnWidths"].get(side).unwrap_or(&empty),
            widths.get(side).unwrap_or(&empty),
        )
        .map_err(|_| "欄寬設定格式不正確。")?;
        subset(
            &combined,
            &["name", "size", "modified"],
            "欄寬設定格式不正確。",
            "欄寬名稱不正確。",
        )?;
        for (k, min, max) in [
            ("name", 120, 1600),
            ("size", 76, 400),
            ("modified", 150, 500),
        ] {
            if let Some(v) = combined.get(k) {
                valid[side][k] = json!(integer(v, "欄寬", min, max)?);
            }
        }
    }
    out["paneColumnWidths"] = valid;
    subset(
        &m["initialLocations"],
        &["left", "right"],
        "預設啟動資料夾格式不正確。",
        "只能設定左右面板的預設啟動資料夾。",
    )?;
    let mut loc = json!({});
    for (side, item) in object(&m["initialLocations"])? {
        loc[side] = Endpoint::parse(item)?.value();
    }
    out["initialLocations"] = loc;
    if !m["savedWorkspace"].is_null() {
        let w = &m["savedWorkspace"];
        if w.as_object().ok_or("工作區設定格式不正確。")?.len() != 5 {
            return Err("工作區設定需包含左右位置、方向、操作方式與傳輸選項。".into());
        }
        subset(
            w,
            &["left", "right", "direction", "mode", "options"],
            "工作區設定格式不正確。",
            "工作區設定需包含左右位置、方向、操作方式與傳輸選項。",
        )?;
        let l = Endpoint::parse(&w["left"])?.value();
        let r = Endpoint::parse(&w["right"])?.value();
        let direction = choice(&w["direction"], &["lr", "rl"], "傳輸方向")?;
        let (s, d) = if direction == "lr" {
            (&l, &r)
        } else {
            (&r, &l)
        };
        let req = TransferRequest::parse(
            &json!({"source":s,"destination":d,"direction":direction,"mode":w["mode"],"options":w["options"],"dryRun":true,"selection":[]}),
        )?;
        out["savedWorkspace"] =
            json!({"left":l,"right":r,"direction":direction,"mode":req.mode,"options":req.options});
    }
    choice(&m["proxyMode"], &["system", "manual"], "代理伺服器設定")?;
    for k in ["httpProxy", "httpsProxy"] {
        let value = text(&m[k], "代理伺服器", 4096)?.trim();
        if !value.is_empty() {
            let authority = value
                .split_once("://")
                .map(|(_, a)| a.trim_end_matches('/'))
                .unwrap_or("");
            let valid = url::Url::parse(value).ok().is_some_and(|u| {
                matches!(u.scheme(), "http" | "https" | "socks5" | "socks5h")
                    && u.host().is_some()
                    && !authority.is_empty()
                    && !authority.contains(['@', '/', '\\'])
                    && !authority.chars().any(char::is_whitespace)
                    && u.username().is_empty()
                    && u.password().is_none()
                    && u.query().is_none()
                    && u.fragment().is_none()
                    && matches!(u.path(), "" | "/")
                    && u.port() != Some(0)
            });
            if !valid {
                return Err(
                    "代理伺服器請填入如 http://127.0.0.1:7890 的網址，不可包含帳號密碼。".into(),
                );
            }
        }
        out[k] = json!(value);
    }
    if text(&m["noProxy"], "不使用代理的位址", 4096)?
        .chars()
        .any(char::is_whitespace)
    {
        return Err("不使用代理的位址請以逗號分隔，不要加入空白。".into());
    }
    out["streamPlayerArguments"] = json!(strings(
        &m["streamPlayerArguments"],
        32,
        2000,
        "播放器參數"
    )?);
    Ok(out)
}

#[cfg(test)]
mod platform_tests {
    use super::*;
    #[test]
    fn json_bools_stay_distinct_from_numbers() {
        let values: Vec<Value> = serde_json::from_str("[false,true,0,1,0.0,-1]").unwrap();
        for (i, value) in values.iter().enumerate() {
            assert_eq!(value.is_boolean(), i < 2);
            if i < 2 {
                assert_eq!(boolean(value, "test").unwrap(), i == 1);
                assert!(integer(value, "test", -1, 1).is_err());
            } else {
                assert!(boolean(value, "test").is_err());
                assert_eq!(integer(value, "test", -1, 1).unwrap(), [0, 1, 0, -1][i - 2]);
            }
        }
    }
    #[test]
    fn absolute_drive_unc_and_posix_spelling() {
        for s in [
            "C:/資料/備份",
            r"D:\Files\Backup",
            "//server/share/folder",
            r"\\server\share",
            "C:/",
        ] {
            assert!(absolute_for_platform(s, true), "{s:?}");
        }
        for s in [
            "C:relative",
            "relative",
            "/rooted-on-unknown-drive",
            "//server",
            "//server/",
            r"\\?\C:\device",
            r"\\.\PhysicalDrive0",
            "A:/line\nbreak",
        ] {
            assert!(!absolute_for_platform(s, true), "{s:?}");
        }
        assert!(absolute_for_platform(r"/tmp/a:b\c", false));
        assert!(!absolute_for_platform("C:/windows", false));
        for root in ["C:/", r"C:\", "//server/share", "//server/share/"] {
            assert!(filesystem_root(root, true), "{root}");
        }
        for child in ["C:/Backup", "//server/share/Backup"] {
            assert!(!filesystem_root(child, true), "{child}");
        }
    }
}

#[cfg(test)]
mod validation_order_regressions {
    use super::*;
    #[test]
    fn duration_format_failure_precedes_age_range_failure_like_swift() {
        for (key, label) in [
            ("modifyWindow", "時間容許誤差"),
            ("connectTimeout", "連線逾時"),
            ("ioTimeout", "傳輸閒置逾時"),
            ("retrySleep", "重試間隔"),
        ] {
            let mut value = json!({"minAge":"3d","maxAge":"1d"});
            value[key] = json!("wrong");
            assert_eq!(
                validate_options(&value).unwrap_err(),
                format!("{label}請填入 30s、5m、24h、7d 等時間。"),
                "{key}"
            );
        }
        assert_eq!(
            validate_options(&json!({"minAge":"3d","maxAge":"1d","modifyWindow":"1s"}))
                .unwrap_err(),
            "最小檔案年齡不能大於最大檔案年齡。"
        );
        assert_eq!(
            validate_options(&json!({"minSize":"2M","maxSize":"1M","modifyWindow":"wrong"}))
                .unwrap_err(),
            "最小檔案大小不能大於最大檔案大小。"
        );
    }
}
