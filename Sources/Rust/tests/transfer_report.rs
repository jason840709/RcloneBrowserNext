//! The 26 original 0.11.0 TransferReportTests groups, plus recorded Swift replay.
#[path = "support/fixture_paths.rs"]
mod fixture_paths;
use rbn_core::{
    models::{self, TransferRequest},
    process::{self, Context},
    report::{self, Report},
};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{self, File, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
    time::{Duration, UNIX_EPOCH},
};
struct Fixture {
    root: PathBuf,
    id: String,
    report: Report,
}
impl Fixture {
    fn new() -> Self {
        let base = std::env::var_os("RBN_TEST_ROOT")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../.tmp/services-tests")
            });
        let root = base.join(format!("transfer-report-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        let root = fixture_paths::canonical(&root);
        let id = uuid::Uuid::new_v4().to_string();
        let report = Report::new(&root, &id).unwrap();
        Self { root, id, report }
    }
    fn rows(&self, category: &str) -> Vec<Value> {
        report::page(
            &self.root,
            &self.id,
            &json!({"category":category}),
            Value::Null,
        )
        .unwrap()["items"]
            .as_array()
            .unwrap()
            .clone()
    }
    fn count(&self, key: &str) -> u64 {
        self.report.summary()[key].as_u64().unwrap()
    }
    fn export(&mut self, format: &str) -> PathBuf {
        self.report.flush().unwrap();
        report::path(&self.root, &self.id, format).unwrap()
    }
    fn request(&self) -> Value {
        json!({"source":{"remote":null,"path":self.root.join("from")},"destination":{"remote":null,"path":self.root.join("to")},"mode":"copy","selection":[],"dryRun":false,"options":{}})
    }
    fn compare(&mut self, line: &str) {
        self.report.comparison_line(line, true).unwrap();
    }
    fn consume(&mut self, value: Value) {
        self.report.consume(&value, false).unwrap();
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}
#[test]
fn symbolic_links_skip_by_default_and_preserve_only_by_explicit_choice() {
    let f = Fixture::new();
    let raw = f.request();
    let normal = TransferRequest::parse(&raw).unwrap();
    assert_eq!(normal.options["symlinkMode"], "skip");
    assert!(!normal.arguments(None).unwrap().contains(&"--links".into()));
    let mut preserve = raw;
    preserve["options"] = json!({"symlinkMode":"preserve"});
    let args = TransferRequest::parse(&preserve)
        .unwrap()
        .arguments(None)
        .unwrap();
    assert!(args.contains(&"--links".into()) && !args.contains(&"--copy-links".into()));
    assert!(models::validate_options(&json!({"symlinkMode":"follow"})).is_err());
    assert!(models::validate_options(&json!({"extraArgs":["--copy-links"]})).is_err());
}
#[test]
fn exports_retain_actual_comparison_settings_and_version_without_environment() {
    let mut f = Fixture::new();
    let raw = json!({"source":{"remote":null,"path":f.root.join("from")},"destination":{"remote":"archive","path":"backup"},"mode":"sync","selection":[{"name":"資料","isDir":true}],"dryRun":false,"options":{"comparison":"size","symlinkMode":"preserve","modifyWindow":"1s","transfers":1,"checkers":10}});
    let request = TransferRequest::parse(&raw).unwrap();
    f.report
        .configuration_details(
            &request.value(),
            Some("rclone v1.75.2"),
            Some("1s"),
            None,
            None,
            None,
        )
        .unwrap();
    let rows = f.rows("all");
    let item = &rows[0];
    let context = &item["configuration"];
    let options = &context["request"]["options"];
    assert_eq!(item["action"], "configuration");
    assert_eq!(context["engineVersion"], "rclone v1.75.2");
    assert_eq!(context["effectiveModifyWindow"], "1s");
    assert_eq!(options["comparison"], "size");
    assert_eq!(options["symlinkMode"], "preserve");
    for key in ["environment", "configContents", "password"] {
        assert!(context.get(key).is_none());
    }
    assert_eq!(f.count("maxAttempts"), 3);
    assert_eq!(f.count("copiedEvents"), 0);
}
#[test]
fn large_valid_selection_splits_into_bounded_reconstructable_configuration() {
    let mut f = Fixture::new();
    let names = (0..400)
        .map(|i| format!("資料-{i}-{}", "a".repeat(3000)))
        .collect::<Vec<_>>();
    let mut raw = f.request();
    raw["destination"] = json!({"remote":"archive","path":"backup"});
    raw["selection"] = json!(
        names
            .iter()
            .map(|name| json!({"name":name,"isDir":false}))
            .collect::<Vec<_>>()
    );
    let request = TransferRequest::parse(&raw).unwrap();
    f.report
        .configuration_details(
            &request.value(),
            Some("rclone v1.75.2"),
            None,
            None,
            None,
            None,
        )
        .unwrap();
    let data = fs::read(f.export("jsonl")).unwrap();
    let lines = data
        .split(|b| *b == b'\n')
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>();
    let items = lines
        .iter()
        .map(|l| serde_json::from_slice::<Value>(l).unwrap())
        .collect::<Vec<_>>();
    let configurations = items
        .iter()
        .map(|i| &i["configuration"])
        .collect::<Vec<_>>();
    assert_eq!(configurations[0]["kind"], "header");
    let restored = configurations
        .iter()
        .filter(|c| c["name"] == "request.selection")
        .flat_map(|c| c["items"].as_array().unwrap())
        .map(|v| v["name"].as_str().unwrap().to_owned())
        .collect::<Vec<_>>();
    assert_eq!(restored, names);
    assert!(lines.iter().all(|l| l.len() < 1024 * 1024));
    assert!(f.rows("all").len() < items.len());
}
#[test]
fn comparison_candidates_never_count_as_completed_transfers() {
    let mut f = Fixture::new();
    for l in [
        "= same.txt",
        "+ new.txt",
        "* changed.txt",
        "- extra.txt",
        "! unreadable.txt",
    ] {
        f.compare(l);
    }
    f.report.poll(true).unwrap();
    assert_eq!(f.count("successEvents"), 0);
    assert_eq!(f.count("matchedEvents"), 1);
    assert_eq!(f.count("candidateEvents"), 2);
    assert_eq!(f.count("comparisonErrorEvents"), 1);
    assert_eq!(f.count("errorEvents"), 0);
    assert_eq!(f.rows("skipped").len(), 1);
    assert_eq!(f.rows("comparison").len(), 5);
    assert!(
        f.report.summary()["skippedFiles"].is_null() && f.report.summary()["failedFiles"].is_null()
    );
}
#[test]
fn successful_copy_and_failed_move_source_deletion_remain_separate() {
    let mut f = Fixture::new();
    f.consume(json!({"time":"2026-10-20T00:00:00Z","level":"info","object":"file.txt","objectType":"*local.Object","msg":"Copied (new)","size":42}));
    f.consume(
        json!({"level":"error","object":"file.txt","msg":"Couldn't delete: permission denied"}),
    );
    f.report.flush().unwrap();
    let success = f.rows("success");
    let errors = f.rows("errors");
    assert_eq!(success.len(), 1);
    assert_eq!(success[0]["action"], "copy");
    assert_eq!(f.count("movedEvents"), 0);
    assert_eq!(errors.len(), 1);
    assert_eq!(errors[0]["path"], "file.txt");
}
#[test]
fn retries_retain_error_evidence_and_event_counts_are_not_unique_files() {
    let mut f = Fixture::new();
    f.compare("+ repeat.txt");
    f.consume(json!({"level":"error","object":"repeat.txt","msg":"Failed to copy: network reset"}));
    f.compare("+ repeat.txt");
    f.consume(json!({"level":"info","object":"repeat.txt","msg":"Multi-thread Copied (new)"}));
    f.consume(json!({"level":"error","msg":"Attempt 2/3 succeeded"}));
    f.report.flush().unwrap();
    assert_eq!(f.count("candidateEvents"), 2);
    assert_eq!(f.count("copiedEvents"), 1);
    assert_eq!(f.rows("errors").len(), 1);
    assert_eq!(
        fs::read_to_string(f.export("comparison")).unwrap(),
        "+ repeat.txt\n+ repeat.txt\n"
    );
}
fn mismatch(f: &mut Fixture, source: u64, destination: u64, suffix: &str) {
    f.consume(json!({"level":"error","object":format!("logs/live.jsonl.{suffix}.partial"),"objectType":"*local.Object","msg":format!("corrupted on transfer: sizes differ src(Local file system at /source) {source} vs dst(Local file system at /backup) {destination}")}));
}
#[test]
fn growing_file_retries_separate_completed_and_failed_size_verification_bytes() {
    let mut f = Fixture::new();
    f.consume(json!({"level":"info","object":"database.sqlite","msg":"Copied (server-side copy)","size":40}));
    mismatch(&mut f, 100, 110, "aabbcc01");
    f.consume(json!({"level":"error","msg":"Attempt 1/3 failed with 1 errors and: corrupted on transfer: sizes differ src(Local file system at /source) 100 vs dst(Local file system at /backup) 110"}));
    f.consume(json!({"level":"info","object":"database.sqlite","msg":"Copied (server-side copy)","size":40}));
    mismatch(&mut f, 110, 120, "aabbcc02");
    f.consume(json!({"level":"error","msg":"Attempt 2/3 failed with 1 errors"}));
    mismatch(&mut f, 120, 150, "aabbcc03");
    f.consume(json!({"level":"error","msg":"Attempt 3/3 failed with 1 errors"}));
    f.report.flush().unwrap();
    for (k, v) in [
        ("copiedBytes", 80),
        ("failedCopyBytes", 380),
        ("copiedEvents", 2),
        ("sizeMismatchEvents", 3),
        ("retryFailures", 3),
        ("lastAttempt", 3),
        ("maxAttempts", 3),
        ("growingSourceEvents", 2),
    ] {
        assert_eq!(f.count(k), v, "{k}");
    }
    let errors = f.rows("errors");
    assert_eq!(errors.len(), 3);
    assert_eq!(errors[0]["issue"], "size-mismatch");
    assert_eq!(errors[1]["issue"], "source-growing");
    assert_eq!(errors[2]["relatedPath"], "logs/live.jsonl");
    assert_eq!(errors[2]["path"], "logs/live.jsonl.aabbcc03.partial");
    assert_eq!(errors[2]["sourceSize"], 120);
    assert_eq!(errors[2]["destinationSize"], 150);
}
#[test]
fn successful_retry_stays_out_of_errors_and_missing_copy_sizes_stay_explicit() {
    let mut f = Fixture::new();
    f.consume(json!({"level":"info","object":"known.txt","msg":"Copied (new)","size":12}));
    f.consume(json!({"level":"info","object":"unknown.txt","msg":"Copied (new)"}));
    f.consume(json!({"level":"error","msg":"Attempt 2/3 succeeded"}));
    f.report.flush().unwrap();
    assert_eq!(f.report.summary()["copyByteTotalsAvailable"], false);
    assert_eq!(f.count("copiedBytes"), 12);
    assert!(f.rows("errors").is_empty());
    assert_eq!(f.count("lastAttempt"), 2);
    assert_eq!(f.rows("all").last().unwrap()["action"], "retry");
}
#[test]
fn ignored_links_and_special_files_remain_discoverable_in_skipped_records() {
    let mut f = Fixture::new();
    f.consume(json!({"level":"notice","object":"link","msg":"Can't follow symlink without -L/--copy-links"}));
    f.consume(
        json!({"level":"notice","object":"ipc.sock","msg":"Can't transfer non file/directory"}),
    );
    f.report.flush().unwrap();
    let rows = f.rows("skipped");
    assert_eq!(rows.len(), 2);
    assert_eq!(f.count("errorEvents"), 0);
    assert_eq!(
        rows.iter()
            .map(|r| r["issue"].as_str().unwrap())
            .collect::<Vec<_>>(),
        ["symlink-ignored", "special-ignored"]
    );
}
#[test]
fn denied_local_partial_rename_retains_original_error_without_completed_copy() {
    let mut f = Fixture::new();
    let message = "partial file rename failed: rename /destination/book.txt.1234abcd.partial /destination/book.txt: operation not permitted";
    f.consume(json!({"level":"error","object":"book.txt.1234abcd.partial","objectType":"*local.Object","msg":message}));
    f.consume(json!({"level":"error","object":"other.txt.1234abcd.partial","objectType":"*local.Object","msg":"partial file rename failed: no space left on device"}));
    f.consume(json!({"level":"error","object":"cloud.txt.1234abcd.partial","objectType":"*drive.Object","msg":message}));
    f.report.flush().unwrap();
    let rows = f.rows("errors");
    assert_eq!(rows.len(), 3);
    assert_eq!(rows[0]["issue"], "partial-rename-denied");
    assert_eq!(rows[0]["message"], message);
    assert_eq!(rows[0]["path"], "book.txt.1234abcd.partial");
    assert_eq!(rows[0]["relatedPath"], "book.txt");
    assert!(rows[1].get("issue").is_none() && rows[2].get("issue").is_none());
    assert_eq!(f.count("successEvents"), 0);
    assert_eq!(f.count("copiedBytes"), 0);
}
#[test]
fn cleanup_failures_are_visible_even_at_info_level() {
    let mut f = Fixture::new();
    f.consume(json!({"level":"info","object":"unfinished.partial","msg":"Removing failed copy"}));
    f.consume(json!({"level":"info","object":"unfinished.partial","msg":"Failed to remove failed copy: access denied"}));
    f.consume(json!({"level":"error","object":"Local file system at /backup","objectType":"*local.Fs","msg":"not deleting directories as there were IO errors"}));
    f.report.flush().unwrap();
    let rows = f.rows("errors");
    assert_eq!(f.count("cleanupEvents"), 1);
    assert_eq!(f.count("cleanupFailureEvents"), 1);
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0]["issue"], "cleanup-failed");
    assert_eq!(rows[1]["issue"], "deletion-deferred");
    assert!(rows[1].get("path").is_none());
}
#[test]
fn size_diagnostics_reject_malformed_numbers_and_truncated_names() {
    let mut f = Fixture::new();
    for (name, msg) in [
        (
            format!("{}.1234abcd.partial", "a".repeat(110)),
            "corrupted on transfer: sizes differ src(Local) 3 vs dst(Local) 4",
        ),
        (
            format!("{}.1234abce.partial", "a".repeat(82)),
            "corrupted on transfer: sizes differ src(Local) 4 vs dst(Local) 5",
        ),
    ] {
        f.consume(json!({"level":"error","object":name,"objectType":"*local.Object","msg":msg}));
    }
    for message in [
        "corrupted on transfer: sizes differ src(Local) -1 vs dst(Local) 3",
        "corrupted on transfer: sizes differ src(Local) 3 vs dst(Local) 9007199254740992",
        "corrupted on transfer: sizes differ src(Local) 3 vs dst(Local) 3",
    ] {
        f.consume(json!({"level":"error","object":"file","msg":message}));
    }
    f.report.flush().unwrap();
    assert_eq!(f.count("sizeMismatchEvents"), 2);
    assert_eq!(f.count("failedCopyBytes"), 9);
    assert!(
        f.rows("errors")
            .iter()
            .all(|r| r.get("relatedPath").is_none())
    );
}
#[test]
fn size_failure_history_is_bounded_during_large_error_sets() {
    let mut f = Fixture::new();
    for index in 0..=256 {
        f.consume(json!({"level":"error","object":format!("file-{index}.1234abcd.partial"),"objectType":"*local.Object","msg":"corrupted on transfer: sizes differ src(Local) 3 vs dst(Local) 4"}));
    }
    f.consume(json!({"level":"error","object":"file-0.1234abce.partial","objectType":"*local.Object","msg":"corrupted on transfer: sizes differ src(Local) 4 vs dst(Local) 5"}));
    assert_eq!(f.count("growingSourceEvents"), 0);
    assert_eq!(f.count("sizeMismatchEvents"), 258);
}
#[test]
fn jsonl_preserves_quotes_unicode_and_literal_newlines_in_filenames() {
    let mut f = Fixture::new();
    let name = "資料/line\nbreak,\"quoted\".txt";
    f.consume(json!({"level":"error","object":name,"msg":"read failed\nsecond line"}));
    f.report.flush().unwrap();
    let data = fs::read(f.export("jsonl")).unwrap();
    assert_eq!(data.iter().filter(|b| **b == b'\n').count(), 1);
    assert_eq!(f.rows("errors")[0]["path"], name);
}
#[test]
fn dry_run_is_planned_and_statistics_never_create_file_rows() {
    let mut f = Fixture::new();
    f.report.consume(&json!({"level":"warning","object":"dry.txt","skipped":"copy","size":12,"msg":"Skipped copy as --dry-run is set (size 12)"}),true).unwrap();
    f.report.consume(&json!({"level":"info","stats":{"checks":9,"transfers":4,"totalTransfers":7,"errors":3}}),true).unwrap();
    f.report.flush().unwrap();
    assert_eq!(f.count("eventCount"), 1);
    assert_eq!(f.count("plannedEvents"), 1);
    assert_eq!(f.count("successEvents"), 0);
    assert_eq!(f.rows("all")[0]["status"], "planned");
}
#[test]
fn malformed_comparison_and_incomplete_tail_are_visible_without_invented_paths() {
    let mut f = Fixture::new();
    f.compare("not a comparison");
    f.report.comparison_line("= half", false).unwrap();
    f.report.poll(true).unwrap();
    assert_eq!(f.count("comparisonMalformed"), 2);
    assert_eq!(f.count("matchedEvents"), 0);
    let all = f.rows("all");
    assert_eq!(all.len(), 1);
    assert!(all[0].get("path").is_none());
    assert_eq!(
        fs::read_to_string(f.export("comparison")).unwrap(),
        "not a comparison\n= half"
    );
}
#[test]
fn reported_paths_cannot_trigger_file_operations() {
    let mut f = Fixture::new();
    let untouched = f.root.join("untouched.txt");
    fs::write(&untouched, b"keep").unwrap();
    f.compare(&format!("- {}", untouched.display()));
    f.compare("= ../../escape;$(command).txt");
    f.report.flush().unwrap();
    report::remove(&f.root, &f.id).unwrap();
    assert_eq!(fs::read_to_string(untouched).unwrap(), "keep");
}
#[test]
fn filesystem_and_global_errors_have_no_fake_filename() {
    let mut f = Fixture::new();
    f.consume(json!({"level":"error","object":"Local file system at /fixture","objectType":"*local.Fs","msg":"error listing"}));
    f.consume(json!({"level":"error","msg":"Failed to sync: network unavailable"}));
    f.report.flush().unwrap();
    assert_eq!(f.count("unattributedErrors"), 2);
    assert!(f.rows("errors").iter().all(|r| r.get("path").is_none()));
}
#[test]
fn cursors_keep_stable_boundaries_and_enforce_small_pages() {
    let mut f = Fixture::new();
    for n in 0..1003 {
        f.compare(&format!("= file-{n}.txt"));
    }
    f.report.poll(true).unwrap();
    let (mut cursor, mut seen) = (0u64, 0);
    let mut sequences = BTreeSet::new();
    loop {
        let page = report::page(
            &f.root,
            &f.id,
            &json!({"category":"skipped","cursor":cursor,"limit":73}),
            Value::Null,
        )
        .unwrap();
        let items = page["items"].as_array().unwrap();
        assert!(items.len() <= 73);
        for item in items {
            sequences.insert(item["sequence"].as_u64().unwrap());
        }
        seen += items.len();
        let Some(next) = page["nextCursor"].as_u64() else {
            break;
        };
        assert!(next > cursor);
        cursor = next;
    }
    assert_eq!(seen, 1003);
    assert_eq!(sequences.len(), 1003);
    assert!(report::page(&f.root, &f.id, &json!({"cursor":2}), Value::Null).is_err());
    assert!(report::page(&f.root, &f.id, &json!({"limit":100000}), Value::Null).is_err());
}
#[test]
fn saved_summaries_allow_finite_counters_and_keep_uncertain_counts_unknown() {
    // serde_json represents nonfinite input as null; neither is a counter.
    let parsed=report::normalized_summary(&json!({"available":true,"eventCount":5,"successEvents":true,"errorEvents":f64::INFINITY,"matchedEvents":-2,"skippedFiles":999,"secret":"drop"})).unwrap();
    assert_eq!(parsed["eventCount"], 5);
    assert_eq!(parsed["successEvents"], 0);
    assert_eq!(parsed["matchedEvents"], 0);
    assert!(parsed["skippedFiles"].is_null());
    assert!(parsed.get("secret").is_none());
    assert!(parsed.get("copiedBytes").is_none() && parsed.get("copyByteTotalsAvailable").is_none());
    let current=report::normalized_summary(&json!({"available":true,"formatVersion":2,"copyByteTotalsAvailable":true,"copiedBytes":15,"failedCopyBytes":24,"lastAttempt":3,"maxAttempts":3})).unwrap();
    assert_eq!(current["copyByteTotalsAvailable"], true);
    assert_eq!(current["copiedBytes"], 15);
    assert_eq!(current["lastAttempt"], 3);
}
#[test]
fn legacy_or_queued_jobs_without_ledger_return_unavailable_empty_page() {
    let f = Fixture::new();
    let page = report::page(
        &f.root,
        &uuid::Uuid::new_v4().to_string(),
        &json!({}),
        Value::Null,
    )
    .unwrap();
    assert_eq!(page["available"], false);
    assert!(page["items"].as_array().unwrap().is_empty());
    assert!(report::page(&f.root, "../escape", &json!({}), Value::Null).is_err());
}
#[test]
fn both_export_formats_are_immutable_while_live_job_grows() {
    let mut f = Fixture::new();
    f.compare("= before.txt");
    let first_json = f.export("jsonl");
    let first_raw = f.export("comparison");
    let bytes = fs::read(&first_json).unwrap();
    f.compare("= after.txt");
    f.report.flush().unwrap();
    assert_eq!(fs::read(&first_json).unwrap(), bytes);
    assert_eq!(fs::read_to_string(first_raw).unwrap(), "= before.txt\n");
    assert_ne!(f.export("jsonl"), first_json);
}
#[test]
fn static_json_export_omits_crash_truncated_final_record() {
    let mut f = Fixture::new();
    f.compare("= complete.txt");
    f.report.flush().unwrap();
    let mut writer = OpenOptions::new()
        .append(true)
        .open(f.root.join(format!("{}.report.jsonl", f.id)))
        .unwrap();
    writer.write_all(b"{\"sequence\":").unwrap();
    drop(writer);
    let path = report::path(&f.root, &f.id, "jsonl").unwrap();
    let bytes = fs::read(path).unwrap();
    assert_eq!(bytes.last(), Some(&b'\n'));
    assert_eq!(bytes.iter().filter(|b| **b == b'\n').count(), 1);
}
#[test]
fn cleanup_removes_only_owned_reports_snapshots_and_readers_reject_symlinks() {
    let mut f = Fixture::new();
    f.compare("= a.txt");
    let snapshot = f.export("jsonl");
    let neighbor = f
        .root
        .join(format!("{}.report-export-not-a-uuid.jsonl", f.id));
    fs::write(&neighbor, b"keep").unwrap();
    report::remove(&f.root, &f.id).unwrap();
    assert!(!snapshot.exists() && neighbor.exists());
    let other = uuid::Uuid::new_v4().to_string();
    let link = f.root.join(format!("{other}.report.jsonl"));
    #[cfg(unix)]
    std::os::unix::fs::symlink(&neighbor, &link).unwrap();
    #[cfg(windows)]
    std::os::windows::fs::symlink_file(&neighbor, &link).unwrap();
    assert!(report::page(&f.root, &other, &json!({}), Value::Null).is_err());
}
fn run_rclone(
    f: &mut Fixture,
    mode: &str,
    source: &Path,
    destination: &Path,
    additional: &[&str],
    source_argument: Option<String>,
    destination_argument: Option<String>,
) -> Value {
    let binary = PathBuf::from(
        std::env::var_os("RBN_TEST_RCLONE").expect("required pinned RBN_TEST_RCLONE fixture"),
    );
    assert!(binary.is_file());
    let config = f.root.join("empty-rclone.conf");
    fs::write(&config, b"").unwrap();
    let environment: BTreeMap<String, String> = std::env::vars()
        .filter(|(k, _)| !k.to_uppercase().starts_with("RCLONE_"))
        .collect();
    let context = Context {
        binary,
        arguments: vec![],
        environment,
        work_dir: f.root.clone(),
    };
    let mut args = vec![mode.to_owned(), format!("--config={}", config.display())];
    args.extend(
        [
            "--combined=-",
            "--use-json-log",
            "--stats=1s",
            "--stats-log-level=INFO",
            "--log-level=INFO",
            "--local-hashes=none",
            "--transfers=1",
            "--checkers=10",
            "--retries=1",
            "--multi-thread-streams=0",
            "--ask-password=false",
        ]
        .map(str::to_owned),
    );
    args.extend(additional.iter().map(|s| s.to_string()));
    args.push("--".into());
    args.push(source_argument.unwrap_or_else(|| source.to_string_lossy().into_owned()));
    args.push(destination_argument.unwrap_or_else(|| destination.to_string_lossy().into_owned()));
    let result = process::capture(
        &context,
        &args,
        4 * 1024 * 1024,
        Duration::from_secs(30),
        None,
    )
    .unwrap();
    assert_eq!(
        result.exit_code,
        0,
        "real rclone fixture failed: {}",
        String::from_utf8_lossy(&result.stderr)
    );
    for line in String::from_utf8(result.stdout).unwrap().lines() {
        f.compare(line);
    }
    let mut stats = json!({});
    for line in String::from_utf8(result.stderr).unwrap().lines() {
        let Ok(raw) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        if raw["stats"].is_object() {
            stats = raw["stats"].clone();
        }
        f.consume(raw);
    }
    f.report.poll(true).unwrap();
    f.report.flush().unwrap();
    stats
}
#[test]
#[ignore = "requires pinned RBN_TEST_RCLONE"]
fn real_rclone_copy_repeat_sync_and_delete_keep_honest_checks_and_outcomes() {
    let mut f = Fixture::new();
    let source = f.root.join("real-source");
    let destination = f.root.join("real-destination");
    fs::create_dir_all(&source).unwrap();
    fs::create_dir_all(&destination).unwrap();
    let timestamp = UNIX_EPOCH + Duration::from_secs(1_750_000_000);
    for name in ["same.txt", "new.txt", "line\nbreak.txt"] {
        let path = source.join(name);
        fs::write(&path, b"fixture").unwrap();
        File::options()
            .write(true)
            .open(path)
            .unwrap()
            .set_times(fs::FileTimes::new().set_modified(timestamp))
            .unwrap();
    }
    let same = destination.join("same.txt");
    fs::write(&same, b"fixture").unwrap();
    File::options()
        .write(true)
        .open(same)
        .unwrap()
        .set_times(fs::FileTimes::new().set_modified(timestamp))
        .unwrap();
    let first = run_rclone(&mut f, "copy", &source, &destination, &[], None, None);
    assert_eq!(f.count("copiedEvents"), 2);
    assert_eq!(f.count("matchedEvents"), 1);
    assert_eq!(first["transfers"], 2);
    assert!(
        f.rows("success")
            .iter()
            .any(|i| i["path"].as_str().is_some_and(|s| s.contains("line␊break")))
    );
    fs::write(destination.join("extra.txt"), b"extra").unwrap();
    let id = uuid::Uuid::new_v4().to_string();
    f.report = Report::new(&f.root, &id).unwrap();
    f.id = id;
    let second = run_rclone(&mut f, "sync", &source, &destination, &[], None, None);
    assert_eq!(second["transfers"], 0);
    assert_eq!(f.count("matchedEvents"), 3);
    assert_eq!(f.count("deletedEvents"), 1);
    assert_ne!(second["checks"].as_u64().unwrap(), f.count("matchedEvents"));
}
#[test]
#[ignore = "requires pinned RBN_TEST_RCLONE"]
fn real_rclone_preserves_links_locally_and_round_trips_cloud_style_link_files() {
    let mut f = Fixture::new();
    let source = f.root.join("links-source");
    let local = f.root.join("links-local");
    let archive = f.root.join("links-archive");
    let restored = f.root.join("links-restored");
    for d in [&source, &local, &archive, &restored] {
        fs::create_dir_all(d).unwrap();
    }
    let outside = f.root.join("link-target.txt");
    let text = "The linked content stays at its original location.";
    fs::write(&outside, text).unwrap();
    #[cfg(unix)]
    std::os::unix::fs::symlink("../link-target.txt", source.join("link.txt")).unwrap();
    #[cfg(windows)]
    std::os::windows::fs::symlink_file("../link-target.txt", source.join("link.txt")).unwrap();
    run_rclone(&mut f, "copy", &source, &local, &["--links"], None, None);
    assert_eq!(
        fs::read_link(local.join("link.txt")).unwrap(),
        Path::new("../link-target.txt")
    );
    let id = uuid::Uuid::new_v4().to_string();
    f.report = Report::new(&f.root, &id).unwrap();
    f.id = id;
    run_rclone(
        &mut f,
        "copy",
        &source,
        &archive,
        &[],
        Some(format!(":local,links=true:{}", source.display())),
        None,
    );
    assert_eq!(
        fs::read_to_string(archive.join("link.txt.rclonelink")).unwrap(),
        "../link-target.txt"
    );
    let id = uuid::Uuid::new_v4().to_string();
    f.report = Report::new(&f.root, &id).unwrap();
    f.id = id;
    run_rclone(
        &mut f,
        "copy",
        &archive,
        &restored,
        &[],
        None,
        Some(format!(":local,links=true:{}", restored.display())),
    );
    assert_eq!(
        fs::read_link(restored.join("link.txt")).unwrap(),
        Path::new("../link-target.txt")
    );
    assert_eq!(fs::read_to_string(outside).unwrap(), text);
}
fn normalized(v: &Value, root: &Path) -> Value {
    match v {
        Value::Number(n) => json!(n.as_f64().unwrap()),
        Value::String(s) => json!(s.replace(&fixture_paths::wire(root), "$ROOT")),
        Value::Array(a) => Value::Array(a.iter().map(|v| normalized(v, root)).collect()),
        Value::Object(m) => Value::Object(
            m.iter()
                .filter(|(k, _)| k.as_str() != "time")
                .map(|(k, v)| (k.clone(), normalized(v, root)))
                .collect(),
        ),
        _ => v.clone(),
    }
}
fn restore_root(v: &Value, root: &Path) -> Value {
    match v {
        Value::String(s) => json!(s.replace("$ROOT", &fixture_paths::wire(root))),
        Value::Array(a) => Value::Array(a.iter().map(|v| restore_root(v, root)).collect()),
        Value::Object(m) => Value::Object(
            m.iter()
                .map(|(k, v)| (k.clone(), restore_root(v, root)))
                .collect(),
        ),
        _ => v.clone(),
    }
}
#[test]
fn swift_original_report_steps_summaries_categories_and_raw_replay_exactly() {
    let fixture: Value =
        serde_json::from_str(include_str!("fixtures/native-report-0.11.0.json")).unwrap();
    for case in fixture["reports"].as_array().unwrap() {
        let mut f = Fixture::new();
        let name = case["name"].as_str().unwrap();
        for (index, step) in case["steps"].as_array().unwrap().iter().enumerate() {
            let step = restore_root(step, &f.root);
            match step["op"].as_str().unwrap() {
                "consume" => f
                    .report
                    .consume(&step["value"], step["dry"].as_bool().unwrap())
                    .unwrap(),
                "comparison" => f
                    .report
                    .comparison_line(
                        step["line"].as_str().unwrap(),
                        step["terminated"].as_bool().unwrap(),
                    )
                    .unwrap(),
                "poll" => f.report.poll(step["final"].as_bool().unwrap()).unwrap(),
                "configuration" => f
                    .report
                    .configuration_details(
                        &step["request"],
                        step["version"].as_str(),
                        step["window"].as_str(),
                        None,
                        None,
                        None,
                    )
                    .unwrap(),
                op => panic!("unknown recorded op {op}"),
            };
            assert_eq!(
                normalized(&f.report.summary(), &f.root),
                normalized(&step["summary"], &f.root),
                "{name} step {index}"
            );
        }
        assert_eq!(
            normalized(&f.report.summary(), &f.root),
            normalized(&case["summary"], &f.root),
            "{name} final"
        );
        if case["removed"] == true {
            continue;
        }
        f.report.flush().unwrap();
        for (category, expected) in case["categories"].as_object().unwrap() {
            let mut cursor = 0u64;
            let mut rows = vec![];
            loop {
                let page = report::page(
                    &f.root,
                    &f.id,
                    &json!({"category":category,"cursor":cursor,"limit":200}),
                    Value::Null,
                )
                .unwrap();
                rows.extend(page["items"].as_array().unwrap().clone());
                let Some(next) = page["nextCursor"].as_u64() else {
                    break;
                };
                assert!(next > cursor);
                cursor = next;
            }
            assert_eq!(
                normalized(&json!(rows), &f.root),
                normalized(expected, &f.root),
                "{name} category {category}"
            );
        }
        assert_eq!(
            normalized(
                &json!(
                    fs::read_to_string(f.root.join(format!("{}.comparison.log", f.id))).unwrap()
                ),
                &f.root
            ),
            normalized(&case["comparisonText"], &f.root),
            "{name} raw comparison"
        );
    }
}
