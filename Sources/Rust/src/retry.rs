use crate::models::TransferRequest;
use serde_json::{Value, json};
use std::collections::BTreeSet;
use unicode_normalization::UnicodeNormalization;
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Failure {
    pub path: Option<String>,
    pub object_type: Option<String>,
    pub message: String,
}
#[derive(Debug, PartialEq)]
pub enum Decision {
    Finish(Option<String>),
    Files(Vec<String>),
    Full(String),
}
pub struct Outcome {
    pub decision: Decision,
    pub permanent: Vec<Failure>,
    pub deletion_deferred: bool,
}
const TEMP: &[&str] = &[
    "ratelimit",
    "rate limit",
    "too many requests",
    "429",
    "quota exceeded for quota metric",
    "timeout",
    "timed out",
    "connection reset",
    "connection refused",
    "broken pipe",
    "unexpected eof",
    "tls handshake",
    "no such host",
    "network is unreachable",
    "temporarily",
    "try again",
    "internal error",
    "internalerror",
    "backenderror",
    "service unavailable",
    "bad gateway",
    "500",
    "502",
    "503",
    "504",
    "source file is being updated",
    "sizes differ",
    "corrupted on transfer",
];
const PERMANENT: &[&str] = &[
    "directory not found",
    "object not found",
    "file not found",
    "no such file or directory",
    "permission denied",
    "operation not permitted",
    "access is denied",
    "insufficientpermissions",
    "file name too long",
    "name too long",
    "path too long",
    "illegal byte sequence",
    "invalid utf-8",
    "invalid argument",
    "not a directory",
    "is a directory",
    "no space left on device",
    "storagequotaexceeded",
    "insufficient storage",
    "storage quota",
    "can't follow symlink",
    "can't transfer non file/directory",
];
pub fn is_permanent(message: &str) -> bool {
    let text = message.to_lowercase();
    !TEMP.iter().any(|s| text.contains(s)) && PERMANENT.iter().any(|s| text.contains(s))
}
pub fn is_summary(f: &Failure) -> bool {
    f.path.is_none()
        && [
            "Attempt ",
            "Fatal error received",
            "Can't retry any of the errors",
            "Failed to sync",
            "Failed to copy",
            "Failed to move",
            "Failed to bisync",
        ]
        .iter()
        .any(|s| f.message.starts_with(s))
}
pub fn is_deferred(f: &Failure) -> bool {
    matches!(
        f.message.as_str(),
        "not deleting files as there were IO errors"
            | "not deleting directories as there were IO errors"
    )
}
fn directory(f: &Failure) -> bool {
    let text = f.message.to_lowercase();
    [
        "error reading source directory",
        "error reading destination directory",
        "error listing",
        "failed to make directory",
        "failed to read directory",
        "couldn't list",
    ]
    .iter()
    .any(|s| text.contains(s))
        || f.object_type.as_ref().is_some_and(|t| {
            ["Directory", ".Dir", ".Fs", ".fs"]
                .iter()
                .any(|s| t.ends_with(s))
        })
}
pub struct Pass<'a> {
    pub failures: &'a [Failure],
    pub overflow: bool,
    pub exit: i32,
    pub cancelled: bool,
    pub attempt: usize,
    pub limit: usize,
    pub request: &'a TransferRequest,
    pub fatal: bool,
    pub retryable: Option<bool>,
    pub last_scoped: bool,
    pub deferred_earlier: bool,
    pub outstanding: usize,
}
pub fn decide(pass: Pass<'_>) -> Outcome {
    let mut result = Outcome {
        decision: Decision::Finish(None),
        permanent: vec![],
        deletion_deferred: false,
    };
    let mut files = Vec::new();
    let mut seen = BTreeSet::new();
    let mut full: Option<String> = None;
    let mut meaningful = 0;
    for f in pass.failures {
        if is_deferred(f) {
            result.deletion_deferred = true;
            continue;
        }
        if is_summary(f) {
            continue;
        }
        meaningful += 1;
        if is_permanent(&f.message) {
            result.permanent.push(f.clone());
            continue;
        }
        if let Some(path) = f.path.as_deref().filter(|p| !p.is_empty() && !directory(f)) {
            if path.contains(['\n', '\r']) {
                full.get_or_insert("因有不屬於單一檔案的錯誤，重新檢查全部檔案。".into());
                continue;
            }
            if seen.insert(path.nfc().collect::<String>()) {
                files.push(path.to_owned());
            }
        } else {
            full.get_or_insert_with(|| {
                if f.path.is_none() {
                    "因有不屬於單一檔案的錯誤，重新檢查全部檔案。".into()
                } else {
                    "因上一輪有資料夾讀取失敗，重新檢查全部檔案。".into()
                }
            });
        }
    }
    if pass.overflow {
        full = Some("因失敗檔案數過多，改為重新檢查全部檔案。".into());
    }
    if pass.exit == 0 && meaningful == 0 {
        if pass.request.mode == "sync"
            && !pass.request.dry_run
            && pass.last_scoped
            && pass.deferred_earlier
            && pass.outstanding == 0
        {
            result.decision = if pass.attempt < pass.limit {
                Decision::Full("重新檢查全部檔案，以補做先前因錯誤而暫停的刪除。".into())
            } else {
                Decision::Finish(Some("檔案傳輸錯誤已在重試後解決，但已達輪次上限；先前暫停的目標刪除尚未執行，下次同步時會處理。".into()))
            };
        }
        return result;
    }
    if pass.cancelled || pass.request.dry_run {
        return result;
    }
    if pass.fatal {
        result.decision =
            Decision::Finish(Some("rclone 回報無法繼續的嚴重錯誤，停止重試。".into()));
        return result;
    }
    if meaningful == 0 && pass.exit != 0 {
        full.get_or_insert("因 rclone 異常中斷且無單檔錯誤紀錄，重新檢查全部檔案。".into());
    }
    if full.is_none() && files.is_empty() {
        if !result.permanent.is_empty() {
            result.decision = Decision::Finish(Some(format!(
                "有 {} 個固定錯誤（如找不到檔案、無權限、檔名不支援）重試也無法解決，不再重試。",
                result.permanent.len()
            )));
        }
        return result;
    }
    if pass.retryable == Some(false) {
        result.decision =
            Decision::Finish(Some("rclone 判定這些錯誤重試也無法解決，停止重試。".into()));
        return result;
    }
    if pass.attempt >= pass.limit {
        result.decision = Decision::Finish(Some(format!(
            "已達 {} 輪嘗試上限，仍有未解決的錯誤。",
            pass.limit
        )));
        return result;
    }
    if pass.request.mode == "sync" && pass.request.options["deleteExcluded"] == true {
        full.get_or_insert(
            "因開啟了「刪除排除項目」，只重試部分檔案會誤刪其他檔案，改為重新檢查全部檔案。".into(),
        );
    }
    if files.len() > 50000 {
        full.get_or_insert("因失敗檔案數過多，改為重新檢查全部檔案。".into());
    }
    result.decision = full.map(Decision::Full).unwrap_or(Decision::Files(files));
    result
}
pub fn single_pass(args: &[String]) -> Vec<String> {
    args.iter()
        .map(|s| {
            if s.starts_with("--retries=") {
                "--retries=1".into()
            } else {
                s.clone()
            }
        })
        .collect()
}
pub fn scoped(args: &[String], path: &str) -> Vec<String> {
    let Some(boundary) = args.iter().position(|s| s == "--") else {
        return single_pass(args);
    };
    let flags = [
        "--filter",
        "--filter-from",
        "--include",
        "--include-from",
        "--exclude",
        "--exclude-from",
        "--files-from",
        "--files-from-raw",
        "--min-size",
        "--max-size",
        "--min-age",
        "--max-age",
        "--max-depth",
        "--exclude-if-present",
        "--delete-excluded",
    ];
    let mut result = single_pass(&args[..boundary])
        .into_iter()
        .filter(|s| !flags.contains(&s.split('=').next().unwrap_or("")))
        .collect::<Vec<_>>();
    result.push(format!("--files-from-raw={path}"));
    result.extend_from_slice(&args[boundary..]);
    result
}
pub fn accumulate(raw: &Value, base: &Value, carried: usize) -> Value {
    let mut value = raw.clone();
    for key in [
        "bytes",
        "checks",
        "transfers",
        "deletes",
        "deletedDirs",
        "renames",
        "listed",
        "elapsedTime",
        "transferTime",
        "serverSideCopies",
        "serverSideCopyBytes",
        "serverSideMoves",
        "serverSideMoveBytes",
    ] {
        if !base[key].is_null() || !raw[key].is_null() {
            value[key] = json!(crate::stats::number(&base[key]) + crate::stats::number(&raw[key]));
        }
    }
    for (total, done) in [
        ("totalBytes", "bytes"),
        ("totalChecks", "checks"),
        ("totalTransfers", "transfers"),
    ] {
        if !raw[total].is_null() {
            value[total] =
                json!(crate::stats::number(&base[done]) + crate::stats::number(&raw[total]));
        }
    }
    if carried > 0 {
        value["errors"] = json!(raw["errors"].as_u64().unwrap_or(0) + carried as u64);
    }
    value
}
pub fn seconds(text: &str) -> Option<f64> {
    if text.is_empty() {
        return None;
    }
    let mut rest = text;
    let mut total = 0.;
    while !rest.is_empty() {
        let n = rest
            .find(|c: char| !c.is_ascii_digit() && c != '.')
            .unwrap_or(rest.len());
        if n == 0 {
            return None;
        }
        let number = rest[..n].parse::<f64>().ok()?;
        rest = &rest[n..];
        let (unit, factor) = [("ms", 0.001), ("h", 3600.), ("m", 60.), ("s", 1.)]
            .into_iter()
            .find(|(u, _)| rest.starts_with(u))?;
        total += number * factor;
        rest = &rest[unit.len()..];
    }
    if total.is_finite() { Some(total) } else { None }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn temporary_beats_permission_marker() {
        assert!(!is_permanent("403 rate limit exceeded"));
        assert!(is_permanent("permission denied"));
        assert!(!is_permanent("errno -1"));
    }
    #[test]
    fn scoped_drops_filters_but_preserves_targets() {
        let a = [
            "sync",
            "--retries=3",
            "--delete-excluded",
            "--include=*.jpg",
            "--",
            "s",
            "d",
        ]
        .map(str::to_owned);
        let r = scoped(&a, "/tmp/list");
        assert!(
            !r.iter()
                .any(|s| s.starts_with("--include") || s == "--delete-excluded")
        );
        assert_eq!(&r[r.len() - 3..], ["--", "s", "d"]);
    }
    #[test]
    fn counters_cross_passes() {
        let x = accumulate(
            &json!({"bytes":3,"transfers":1,"errors":0,"totalBytes":5}),
            &json!({"bytes":10,"transfers":2}),
            2,
        );
        assert_eq!(x["bytes"], 13.);
        assert_eq!(x["totalBytes"], 15.);
        assert_eq!(x["errors"], 2);
    }
    #[test]
    fn durations() {
        assert_eq!(seconds("1m30s"), Some(90.));
        assert_eq!(seconds("500ms"), Some(0.5));
        assert_eq!(seconds("1"), None);
    }
}

#[cfg(test)]
mod canonical_retry_tests {
    use super::*;
    fn request() -> TransferRequest {
        TransferRequest::parse(&json!({"source":{"remote":"source","path":""},"destination":{"remote":"target","path":""},"mode":"copy","selection":[],"dryRun":false,"options":{"retries":3}})).unwrap()
    }
    fn plan(failures: &[Failure]) -> Outcome {
        let request = request();
        decide(Pass {
            failures,
            overflow: false,
            exit: 1,
            cancelled: false,
            attempt: 1,
            limit: 3,
            request: &request,
            fatal: false,
            retryable: Some(true),
            last_scoped: false,
            deferred_earlier: false,
            outstanding: 0,
        })
    }
    fn error(path: &str) -> Failure {
        Failure {
            path: Some(path.into()),
            object_type: Some("*local.Object".into()),
            message: "network timeout".into(),
        }
    }
    #[test]
    fn canonically_equal_retry_paths_keep_the_first_literal_spelling() {
        let nfc = "é.txt";
        let nfd = "e\u{301}.txt";
        assert_eq!(
            plan(&[error(nfc), error(nfd)]).decision,
            Decision::Files(vec![nfc.into()])
        );
        assert_eq!(
            plan(&[error(nfd), error(nfc)]).decision,
            Decision::Files(vec![nfd.into()])
        );
    }
    #[test]
    fn canonical_duplicate_does_not_force_a_complete_rescan_at_the_retry_file_limit() {
        let mut failures = (0..50000)
            .map(|index| error(&format!("é-{index}.txt")))
            .collect::<Vec<_>>();
        failures.push(error("e\u{301}-0.txt"));
        let Decision::Files(files) = plan(&failures).decision else {
            panic!("canonical duplicate widened the retry scope")
        };
        assert_eq!(files.len(), 50000);
        assert_eq!(files[0], "é-0.txt");
    }
}
