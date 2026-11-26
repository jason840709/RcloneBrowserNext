//! Direct counterparts of the pure assertions from the Swift 0.11.0 CoreTests.
#![recursion_limit = "256"]
use rbn_core::{
    catalog, local,
    models::{self, Endpoint, TransferRequest},
    retry,
    stats::{self, Throughput},
};
use serde_json::{Value, json};
use std::{collections::BTreeSet, path::Path};
#[path = "support/fixture_paths.rs"]
mod fixture_paths;
fn model_endpoint(name: &str) -> String {
    let parent = fixture_paths::canonical(Path::new(env!("CARGO_MANIFEST_DIR")));
    fixture_paths::wire(&parent.join(name))
}
fn source() -> &'static str {
    static PATH: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    PATH.get_or_init(|| model_endpoint("model-only-source"))
}
fn dest() -> &'static str {
    static PATH: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    PATH.get_or_init(|| model_endpoint("model-only-dest"))
}
fn request(mode: &str, options: Value) -> Value {
    json!({"source":{"remote":null,"path":source()},"destination":{"remote":null,"path":dest()},
        "mode":mode,"options":options,"dryRun":false,"selection":[]})
}
fn transfer(mode: &str, options: Value) -> TransferRequest {
    TransferRequest::parse(&request(mode, options)).unwrap()
}
fn meter(at: f64) -> Throughput {
    let mut t = Throughput::default();
    t.start_at(at);
    t
}
fn number(v: &Value, key: &str) -> f64 {
    v[key].as_f64().expect(key)
}
fn tick(t: &mut Throughput, previous: &mut Value, raw: Value, at: f64) {
    *previous = t.update_at(&raw, previous, at);
}
fn strings(v: &[&str]) -> Vec<String> {
    v.iter().map(|v| v.to_string()).collect()
}
#[test]
fn json_statistics_retain_independent_scan_counts_and_unknown_eta() {
    let first = json!({"bytes":1024,"totalBytes":2048,"speed":512,"eta":null,"totalTransfers":2,"checks":12,"totalChecks":40,
        "listed":65,"transfers":1,"errors":2,"transferring":[{"name":"file.bin","size":2048,"bytes":1024,"speed":512,"speedAvg":500,"eta":null}]});
    let a = stats::parse(&first, &stats::empty());
    assert!(a["eta"].is_null());
    let b = stats::parse(
        &json!({"bytes":1536,"totalBytes":8192,"totalTransfers":7,"eta":13,"speed":-1}),
        &a,
    );
    for (key, n) in [
        ("totalBytes", 8192.),
        ("totalTransfers", 7.),
        ("checks", 12.),
        ("totalChecks", 40.),
        ("listed", 65.),
        ("transfers", 1.),
        ("errors", 2.),
        ("speed", 0.),
        ("eta", 13.),
    ] {
        assert_eq!(number(&b, key), n, "{key}");
    }
    assert_eq!(number(&a["transferring"][0], "percentage"), 50.);
    assert!(a["transferring"][0]["eta"].is_null());
}
#[test]
fn zero_rclone_network_speed_keeps_native_logical_bytes_and_nas_argv() {
    let mut t = meter(1000.);
    let raw = json!({"bytes":1500000000,"totalBytes":3400000000i64,"elapsedTime":30,"transfers":150,"totalTransfers":340,
        "serverSideCopyBytes":1500000000,"speed":0,"eta":null});
    let v = t.update_at(&raw, &stats::empty(), 1030.);
    assert_eq!(number(&v, "speed"), 50_000_000.);
    assert_eq!(number(&v, "eta"), 38.);
    assert_eq!(v["speedKind"], "rolling");
    assert_eq!(v["etaSource"], "bytes");
    assert_eq!(number(&v, "speedWindowSeconds"), 30.);
    let args = transfer("copy", json!({})).arguments(None).unwrap();
    assert_eq!(
        args.contains(&"--local-no-clone".into()),
        cfg!(target_os = "macos")
    );
    assert!(args.contains(&"--stats=1s".into()));
    let nas = transfer(
        "sync",
        json!({"transfers":1,"checkers":10,"extraArgs":["--multi-thread-streams=0"]}),
    )
    .arguments(None)
    .unwrap();
    for flag in [
        "--transfers=1",
        "--checkers=10",
        "--local-hashes=none",
        "--delete-during",
        "--max-delete=-1",
        "--multi-thread-streams=0",
    ] {
        assert!(nas.contains(&flag.to_owned()), "{flag}");
    }
}
#[test]
fn rolling_stall_and_ten_thousand_updates_keep_memory_and_ipc_bounded() {
    let mut t = meter(0.);
    let mut s = stats::empty();
    for n in 1..=120 {
        let bytes = if n <= 60 {
            n * 100
        } else {
            6000 + (n - 60) * 200
        };
        tick(
            &mut t,
            &mut s,
            json!({"bytes":bytes,"totalBytes":100000,"elapsedTime":n,"transfers":n,"totalTransfers":1000}),
            f64::from(n),
        );
    }
    assert_eq!(number(&s, "speed"), 200.);
    assert_eq!(number(&s, "averageSpeed"), 150.);
    assert_eq!(number(&s, "speedWindowSeconds"), 10.);
    for n in 121..=181 {
        tick(
            &mut t,
            &mut s,
            json!({"bytes":18000,"totalBytes":100000,"elapsedTime":n,"transfers":120}),
            f64::from(n),
        );
    }
    assert_eq!(number(&s, "speed"), 0.);
    assert!(s["eta"].is_null());
    for n in 1..=10000 {
        let time = 181. + f64::from(n) / 100.;
        tick(
            &mut t,
            &mut s,
            json!({"bytes":18000+n,"totalBytes":100000,"elapsedTime":time}),
            time,
        );
    }
    assert!(t.sample_count() <= 64);
    assert!(number(&s, "speedWindowSeconds") <= 60.);
    assert!(serde_json::to_vec(&s).unwrap().len() < 2000);
}
#[test]
fn silent_native_file_keeps_then_loses_rate_across_a_full_minute() {
    let mut t = meter(0.);
    let mut s = stats::empty();
    let file = json!({"name":"large.mov","size":5031000000i64,"bytes":0,"speed":0});
    for (n, bytes) in [
        1_000_000,
        34_000_000,
        34_000_000,
        34_000_000,
        34_000_000,
        193_000_000,
    ]
    .into_iter()
    .enumerate()
    {
        let at = (n + 1) as f64;
        tick(
            &mut t,
            &mut s,
            json!({"bytes":bytes,"totalBytes":5225000000i64,"elapsedTime":at,"transferring":[file]}),
            at,
        );
    }
    assert_eq!(s["speedState"], "live");
    let mut previous = f64::INFINITY;
    for n in 12..=92 {
        tick(
            &mut t,
            &mut s,
            json!({"bytes":193000000,"totalBytes":5225000000i64,"elapsedTime":n,"transferring":[file]}),
            f64::from(n),
        );
        assert_eq!(s["speedState"], "hidden", "{n}");
        let speed = number(&s, "speed");
        if n == 12 {
            assert!(speed > 10_000_000. && number(&s, "eta") > 0.);
        }
        assert!(speed <= previous, "{n}");
        previous = speed;
    }
    assert_eq!(number(&s, "speed"), 0.);
    assert!(s["eta"].is_null());
    tick(
        &mut t,
        &mut s,
        json!({"bytes":5225000000i64,"totalBytes":5225000000i64,"elapsedTime":92.8,"transfers":6,"totalTransfers":6,"transferring":[]}),
        92.8,
    );
    assert_eq!(s["speedState"], "live");
    assert!(number(&s, "speed") > 0.);
    let end = t.finish_at(&s, true, 92.8);
    assert!((number(&end, "speed") - 5_225_000_000. / 92.8).abs() < 1.);
    assert_eq!(end["speedState"], "live");
}
#[test]
fn eight_megabyte_bursts_every_eight_seconds_and_then_a_stall() {
    let mut t = meter(0.);
    let mut s = stats::empty();
    let mut low = f64::INFINITY;
    let mut high = 0f64;
    let file = json!({"name":"archive.zip","size":800000000,"bytes":1,"speed":0});
    for n in 1..=96 {
        tick(
            &mut t,
            &mut s,
            json!({"bytes":(n/8)*8_000_000,"totalBytes":800000000,"elapsedTime":n,"transferring":[file]}),
            f64::from(n),
        );
        if n >= 40 {
            low = low.min(number(&s, "speed"));
            high = high.max(number(&s, "speed"));
        }
        assert_ne!(s["speedState"], "hidden");
    }
    assert!(
        low >= 700_000. && high <= 1_150_000.,
        "low {low} high {high}"
    );
    for n in 97..=140 {
        tick(
            &mut t,
            &mut s,
            json!({"bytes":96000000,"totalBytes":800000000,"elapsedTime":n,"transferring":[file]}),
            f64::from(n),
        );
    }
    assert_eq!(number(&s, "speed"), 0.);
    assert!(s["eta"].is_null());
    assert_eq!(s["speedState"], "live");
}
#[test]
fn steady_rate_tracks_each_ten_second_window_after_slowdown() {
    let mut t = meter(0.);
    let mut s = stats::empty();
    let mut bytes = 0f64;
    for n in 1..=60 {
        bytes += if n <= 30 { 50_000_000. } else { 10_000_000. };
        let files = json!([{"name":"a.bin","size":9e9,"bytes":bytes,"speed":0},{"name":"queued.bin","size":9e9,"bytes":0,"speed":0}]);
        tick(
            &mut t,
            &mut s,
            json!({"bytes":bytes,"totalBytes":18e9,"elapsedTime":n,"transferring":files}),
            f64::from(n),
        );
        if n == 30 {
            assert_eq!(number(&s, "speed"), 50_000_000.);
        }
    }
    assert_eq!(number(&s, "speed"), 10_000_000.);
    assert_eq!(s["speedState"], "live");
    assert_eq!(number(&s, "eta"), (18e9 - bytes) / 10_000_000.);
    assert_eq!(s["etaSource"], "bytes");
}
#[test]
fn comparison_and_idle_time_do_not_dilute_active_transfer_speed() {
    let mut t = meter(0.);
    let mut s = stats::empty();
    let frame = |n: i32, bytes: i64, active: i32, activity: &str| {
        let mut v = json!({"bytes":bytes,"totalBytes":1e9,"elapsedTime":n,"transferTime":active});
        match activity {
            "checking" => v["checking"] = json!([{"name":"folder/sub"}]),
            "transferring" => {
                v["transferring"] = json!([{"name":"a.bin","size":9e9,"bytes":1,"speed":0}])
            }
            _ => {}
        }
        v
    };
    for n in 1..=20 {
        tick(&mut t, &mut s, frame(n, 0, 0, "checking"), f64::from(n));
    }
    assert_eq!(s["speedState"], "checking");
    assert_eq!(number(&s, "speed"), 0.);
    assert!(s["eta"].is_null());
    for n in 21..=40 {
        tick(
            &mut t,
            &mut s,
            frame(n, i64::from(n - 20) * 10_000_000, n - 20, "transferring"),
            f64::from(n),
        );
    }
    assert_eq!(number(&s, "speed"), 10_000_000.);
    assert_eq!(number(&s, "averageSpeed"), 10_000_000.);
    for n in 41..=60 {
        tick(
            &mut t,
            &mut s,
            frame(n, 200_000_000, 20, "checking"),
            f64::from(n),
        );
    }
    assert_eq!(s["speedState"], "checking");
    assert_eq!(number(&s, "speed"), 10_000_000.);
    assert_eq!(number(&s, "eta"), 80.);
    tick(&mut t, &mut s, frame(61, 200_000_000, 20, ""), 61.);
    assert_eq!(s["speedState"], "idle");
    for n in 62..=66 {
        tick(
            &mut t,
            &mut s,
            frame(
                n,
                200_000_000 + i64::from(n - 61) * 10_000_000,
                n - 41,
                "transferring",
            ),
            f64::from(n),
        );
    }
    assert_eq!(number(&s, "speed"), 10_000_000.);
    assert_eq!(s["speedState"], "live");
    let end = t.finish_at(&s, true, 66.);
    assert_eq!(number(&end, "speed"), 10_000_000.);
    assert_eq!(number(&end, "transferTime"), 25.);
}
#[test]
fn missing_and_reset_clocks_and_extreme_rates_remain_finite() {
    let mut t = meter(100.);
    let mut s = t.update_at(
        &json!({"bytes":1000,"elapsedTime":10,"totalBytes":5000}),
        &stats::empty(),
        110.,
    );
    tick(
        &mut t,
        &mut s,
        json!({"bytes":1200,"totalBytes":6000,"elapsedTime":null}),
        112.,
    );
    assert_eq!(number(&s, "speed"), 100.);
    assert_eq!(number(&s, "elapsedTime"), 12.);
    tick(
        &mut t,
        &mut s,
        json!({"bytes":50,"elapsedTime":1,"totalBytes":5000}),
        113.,
    );
    assert_eq!(number(&s, "speed"), 0.);
    assert!(s["eta"].is_null());
    tick(&mut t, &mut s, json!({"bytes":250,"elapsedTime":3}), 115.);
    assert_eq!(number(&s, "speed"), 100.);
    assert_eq!(number(&s, "totalBytes"), 5000.);
    tick(&mut t, &mut s, json!({"bytes":350}), 116.);
    assert_eq!(number(&s, "elapsedTime"), 4.);
    assert_eq!(number(&s, "speed"), 100.);
    let mut extreme = meter(0.);
    let peak = extreme.update_at(
        &json!({"bytes":1e308,"totalBytes":1.5e308,"elapsedTime":1e-308,"transfers":1e308}),
        &stats::empty(),
        1e-308,
    );
    assert_eq!(number(&peak, "speed"), 0.);
    assert!(peak["eta"].is_null());
    serde_json::to_vec(&stats::finished(&peak, false)).unwrap();
}
#[test]
fn file_count_eta_and_finished_averages_survive_legacy_history_decoding() {
    let mut t = meter(10.);
    let v = t.update_at(
        &json!({"bytes":0,"totalBytes":0,"elapsedTime":20,"transfers":20,"totalTransfers":100}),
        &stats::empty(),
        30.,
    );
    assert_eq!(number(&v, "filesPerSecond"), 1.);
    assert_eq!(number(&v, "eta"), 80.);
    assert_eq!(v["etaSource"], "files");
    let mut short = meter(100.);
    let v=short.update_at(&json!({"bytes":1024,"totalBytes":1024,"transfers":1,"totalTransfers":1,"elapsedTime":0.25,"speed":0}),&stats::empty(),100.25);
    let end = short.finish_at(&v, true, 100.3);
    assert_eq!(number(&end, "speed"), 4096.);
    assert_eq!(end["speedKind"], "overall");
    assert_eq!(number(&end, "eta"), 0.);
    let mut saved = json!({"id":"00000000-0000-4000-8000-000000000032","createdAt":"2000-01-01T00:00:00Z","status":"completed",
        "request":request("copy",json!({})),"command":"rclone","stats":end});
    let reopened = rbn_core::history::job(&saved).unwrap();
    assert_eq!(number(&reopened["stats"], "speed"), 4096.);
    assert_eq!(reopened["stats"]["speedKind"], "overall");
    saved["stats"]["speed"] = json!(0);
    saved["stats"]
        .as_object_mut()
        .unwrap()
        .remove("averageSpeed");
    assert_eq!(
        number(&rbn_core::history::job(&saved).unwrap()["stats"], "speed"),
        4096.
    );
}
#[test]
fn unsafe_endpoints_options_selections_and_literal_filter_escaping() {
    for v in [
        json!({"remote":null,"path":"../unsafe"}),
        json!({"remote":":local,copy_links=true","path":""}),
        json!({"remote":"drive","path":"a/../b"}),
    ] {
        assert!(Endpoint::parse(&v).is_err());
    }
    for opts in [
        json!({"bandwidth":"1M --delete-excluded"}),
        json!({"updateOnly":1}),
    ] {
        assert!(models::validate_options(&opts).is_err());
    }
    let file = json!({"name":"one","isDir":false});
    let mut v = request("sync", json!({}));
    v["selection"] = json!([file]);
    assert!(TransferRequest::parse(&v).is_err());
    let folders = json!([{"name":"one[1]","isDir":true},{"name":"two","isDir":true}]);
    v["selection"] = folders;
    let r = TransferRequest::parse(&v).unwrap();
    assert_eq!(r.selection.len(), 2);
    assert!(models::selection_filter_rules(&r).ends_with(&strings(&[
        r"+ /one\[1\]/**",
        "+ /two/**",
        "- **"
    ])));
    v["options"] = json!({"deleteExcluded":true});
    assert!(TransferRequest::parse(&v).is_err());
    v["options"] = json!({});
    v["selection"]
        .as_array_mut()
        .unwrap()
        .push(json!({"name":"file.txt","isDir":false}));
    assert!(TransferRequest::parse(&v).is_err());
    assert_eq!(
        models::escape_filter(r" a[1]*?{b}\ "),
        r"[ ]a\[1\]\*\?\{b\}\\[ ]"
    );
}
#[test]
fn comparison_modes_all_enabled_arguments_and_forbidden_argv() {
    let flags = [
        "--checksum",
        "--ignore-size",
        "--size-only",
        "--ignore-times",
    ];
    for (mode, expected) in [
        ("default", vec![]),
        ("checksum", vec!["--checksum"]),
        ("modtime", vec!["--ignore-size"]),
        ("size", vec!["--size-only"]),
        ("checksum-only", vec!["--checksum", "--ignore-size"]),
        ("none", vec!["--ignore-times"]),
    ] {
        let args = transfer(
            "copy",
            json!({"comparison":mode,"localHashPolicy":"default"}),
        )
        .arguments(None)
        .unwrap();
        assert_eq!(
            args.iter()
                .map(String::as_str)
                .filter(|s| flags.contains(s))
                .collect::<BTreeSet<_>>(),
            expected.into_iter().collect()
        );
        assert!(args.ends_with(&strings(&["--", source(), dest()])));
    }
    let opts = json!({"deleteMode":"during","deleteExcluded":true,"checkFirst":true,"fastList":true,"oneFileSystem":true,
        "noUpdateModtime":true,"preserveMetadata":true,"minSize":"1K","maxSize":"2M","minAge":"1h","maxAge":"2d",
        "maxDepth":4,"connectTimeout":"20s","ioTimeout":"3m","lowLevelRetries":5,"retrySleep":"2s","modifyWindow":"1s","extraArgs":["--buffer-size=4M","--use-mmap"]});
    let args = transfer("sync", opts).arguments(None).unwrap();
    for flag in [
        "--delete-during",
        "--delete-excluded",
        "--check-first",
        "--fast-list",
        "--one-file-system",
        "--no-update-modtime",
        "--metadata",
        "--min-size=1K",
        "--max-size=2M",
        "--min-age=1h",
        "--max-age=2d",
        "--max-depth=4",
        "--contimeout=20s",
        "--timeout=3m",
        "--low-level-retries=5",
        "--retries-sleep=2s",
        "--modify-window=1s",
        "--buffer-size=4M",
        "--use-mmap",
    ] {
        assert!(args.contains(&flag.to_string()), "{flag}");
    }
    for opts in [
        json!({"comparison":"none","skipExisting":true}),
        json!({"comparison":"none","updateOnly":true}),
        json!({"comparison":"checksum","localHashPolicy":"none"}),
        json!({"minSize":"2M","maxSize":"1K"}),
        json!({"minAge":"3d","maxAge":"1h"}),
        json!({"connectTimeout":"3s --rc"}),
        json!({"maxDepth":-2}),
        json!({"minSize":"10MB"}),
        json!({"minSize":"2","maxSize":"3B"}),
    ] {
        assert!(models::validate_options(&opts).is_err(), "{opts}");
    }
    for (mode, opts) in [
        ("sync", json!({"noTraverse":true})),
        ("copy", json!({"deleteExcluded":true})),
        ("move", json!({"updateOnly":true})),
    ] {
        assert!(TransferRequest::parse(&request(mode, opts)).is_err());
    }
    for arg in [
        "--dry-run=false",
        "--rc",
        "--stats=0",
        "--use-json-log=false",
        "--log-file=/tmp/leak",
        "--filter=+ **",
        "--config=/tmp/other",
        "--password-command=anything",
        "--metadata-mapper=anything",
        "--max-delete=-1",
        "--ignore-errors",
        "--backup-dir=/tmp/outside",
        "--sftp-pass=secret",
        "--dump=headers",
        "--buffer-size=1M --rc",
        "-P",
        "sync",
        "/tmp/other",
    ] {
        assert!(
            models::validate_options(&json!({"extraArgs":[arg]})).is_err(),
            "{arg}"
        );
    }
}
#[test]
fn volume_precision_checks_both_ends_explicit_zero_and_missing_ancestor() {
    let base = transfer("sync", json!({}));
    let mut seen = BTreeSet::new();
    let mixed = local::detect_precision(&base, |path| {
        seen.insert(path.to_owned());
        Some(
            if path == Path::new(source()) {
                "hfs"
            } else {
                "exfat"
            }
            .to_owned(),
        )
    });
    assert_eq!(
        seen,
        [Path::new(source()).to_owned(), Path::new(dest()).to_owned()]
            .into_iter()
            .collect()
    );
    assert_eq!(mixed.unwrap().0, "1s");
    for (other, duration) in [
        ("msdos", Some("2s")),
        ("exfat", Some("10ms")),
        ("apfs", None),
    ] {
        assert_eq!(
            local::detect_precision(&base, |p| Some(
                if p == Path::new(source()) {
                    "apfs"
                } else {
                    other
                }
                .into()
            ))
            .map(|m| m.0),
            duration
        );
    }
    assert!(local::detect_precision(&base, |_| Some("unknown-fs".into())).is_none());
    for cmp in ["size", "none", "checksum", "checksum-only"] {
        assert!(
            local::detect_precision(
                &transfer(
                    "copy",
                    json!({"comparison":cmp,"localHashPolicy":"default"})
                ),
                |_| Some("msdos".into())
            )
            .is_none()
        );
    }
    let manual = transfer("copy", json!({"modifyWindow":"0"}));
    assert!(
        local::detect_precision(&manual, |_| panic!(
            "explicit choice queried the filesystem"
        ))
        .is_none()
    );
    assert!(
        manual
            .arguments(None)
            .unwrap()
            .contains(&"--modify-window=0".into())
    );
    let mut req = request("copy", json!({}));
    req["source"]["remote"] = json!("one");
    req["destination"]["remote"] = json!("two");
    assert!(
        local::detect_precision(&TransferRequest::parse(&req).unwrap(), |_| panic!(
            "remote queried filesystem"
        ))
        .is_none()
    );
    assert_eq!(base.options["modifyWindow"], "");
    #[cfg(target_os = "macos")]
    {
        let parent = Path::new(env!("CARGO_MANIFEST_DIR"));
        let missing = parent
            .join(format!("rbn-never-created-{}", uuid::Uuid::new_v4()))
            .join("nested");
        assert_eq!(local::mounted_fs(&missing), local::mounted_fs(parent));
        assert!(!missing.exists());
    }
}
#[test]
fn clone_policy_owns_only_one_flag_in_all_twenty_four_combinations() {
    let filter = Path::new("/test/selection.filter");
    for mode in ["copy", "sync", "move"] {
        for metadata in [false, true] {
            for over in [
                None,
                Some("--local-no-clone"),
                Some("--local-no-clone=true"),
                Some("--local-no-clone=false"),
            ] {
                let extras: Vec<_> = over.into_iter().chain(Some("--buffer-size=1M")).collect();
                let mut raw = request(
                    mode,
                    json!({"preserveMetadata":metadata,"localHashPolicy":"default","modifyWindow":"2s","extraArgs":extras}),
                );
                raw["dryRun"] = json!(true);
                let r = TransferRequest::parse(&raw).unwrap();
                let before = r.value();
                let original = r.base_arguments(Some(filter)).unwrap();
                let changed = local::clone_arguments(original.clone(), &r, "darwin");
                let is_clone =
                    |s: &str| s == "--local-no-clone" || s.starts_with("--local-no-clone=");
                assert_eq!(
                    changed
                        .iter()
                        .filter(|a| is_clone(a))
                        .cloned()
                        .collect::<Vec<_>>(),
                    strings(&["--local-no-clone"])
                );
                assert_eq!(
                    changed.iter().filter(|a| !is_clone(a)).collect::<Vec<_>>(),
                    original.iter().filter(|a| !is_clone(a)).collect::<Vec<_>>()
                );
                assert!(changed.ends_with(&strings(&["--", source(), dest()])));
                assert_eq!(changed.contains(&"--metadata".into()), metadata);
                assert!(
                    changed.contains(&"--dry-run".into())
                        && changed.contains(&"--filter-from=/test/selection.filter".into())
                );
                assert!(!changed.iter().any(|a| a == "--inplace"
                    || a.starts_with("--partial-suffix")
                    || a == "--ignore-checksum"));
                assert_eq!(r.value(), before);
            }
        }
    }
}
#[test]
fn clone_policy_leaves_all_other_platforms_and_remote_pairs_byte_identical() {
    for (s, d) in [
        (None, None),
        (Some("source"), None),
        (None, Some("target")),
        (Some("source"), Some("target")),
    ] {
        let mut raw = request(
            "copy",
            json!({"extraArgs":["--local-no-clone=false","--buffer-size=2M"]}),
        );
        raw["source"]["remote"] = json!(s);
        raw["destination"]["remote"] = json!(d);
        let r = TransferRequest::parse(&raw).unwrap();
        let original = r.base_arguments(None).unwrap();
        for platform in ["darwin", "linux", "win32"] {
            if platform == "darwin" && s.is_none() && d.is_none() {
                continue;
            }
            assert!(!local::clone_policy_applies(&r, platform));
            assert_eq!(
                local::clone_arguments(original.clone(), &r, platform),
                original
            );
        }
    }
}
#[test]
fn system_language_honors_only_primary_preference_and_explicit_selection() {
    for tag in ["zh", "zh-TW", "zh-Hant-TW", "zh-Hans-CN", "zh_CN", "ZH_hk"] {
        assert_eq!(
            catalog::resolve_language("system", &strings(&[tag])),
            "zh-TW"
        );
    }
    for tag in ["ja", "ja-JP", "ja_JP"] {
        assert_eq!(catalog::resolve_language("system", &strings(&[tag])), "ja");
    }
    for tags in [vec![], vec!["fr-FR", "ja"], vec!["en-GB"], vec!["ko-KR"]] {
        assert_eq!(catalog::resolve_language("system", &strings(&tags)), "en");
    }
    for tag in ["zh-TW", "en", "ja"] {
        assert_eq!(catalog::resolve_language(tag, &strings(&["fr-FR"])), tag);
    }
}
#[test]
fn retry_decisions_literals_paths_messages_arguments_and_accumulation() {
    use retry::{
        Decision::{Files, Finish, Full},
        Failure, Pass,
    };
    let sync = transfer("sync", json!({}));
    let make = |path: Option<&str>, object_type: Option<&str>, message: &str| Failure {
        path: path.map(str::to_owned),
        object_type: object_type.map(str::to_owned),
        message: message.to_owned(),
    };
    fn pass<'a>(request: &'a TransferRequest, failures: &'a [Failure]) -> Pass<'a> {
        Pass {
            request,
            failures,
            exit: 1,
            attempt: 1,
            limit: 3,
            overflow: false,
            cancelled: false,
            fatal: false,
            retryable: Some(true),
            last_scoped: false,
            deferred_earlier: false,
            outstanding: 0,
        }
    }
    let folder = make(
        Some("3387710-[名前] ‛‛？"),
        Some("string"),
        "error reading source directory: directory not found",
    );
    let summary = make(
        None,
        None,
        "Attempt 1/1 failed with 52 errors and: march failed with 51 error(s): first error: directory not found",
    );
    let deferral = make(
        None,
        Some("*local.Fs"),
        "not deleting directories as there were IO errors",
    );
    let mut rows = vec![folder; 52];
    rows.extend([summary.clone(), deferral]);
    let outcome = retry::decide(pass(&sync, &rows));
    assert_eq!(outcome.permanent.len(), 52);
    assert!(outcome.deletion_deferred);
    assert_eq!(
        outcome.decision,
        Finish(Some(
            "有 52 個固定錯誤（如找不到檔案、無權限、檔名不支援）重試也無法解決，不再重試。".into()
        ))
    );
    let limited = make(
        Some("a/1.jpg"),
        Some("*drive.Object"),
        "Failed to copy: googleapi: Error 403: Rate Limit Exceeded, rateLimitExceeded",
    );
    let unknown = make(
        Some("a/2.jpg"),
        Some("*local.Object"),
        "Failed to copy: couldn't copy from a to b: errno -1",
    );
    let both = [limited.clone(), unknown.clone(), limited, summary];
    let outcome = retry::decide(pass(&sync, &both));
    assert_eq!(outcome.decision, Files(strings(&["a/1.jpg", "a/2.jpg"])));
    assert!(outcome.permanent.is_empty());
    let denied = make(
        Some("a/3.jpg"),
        Some("*local.Object"),
        "Failed to copy: open /a/3.jpg: permission denied",
    );
    let outcome = retry::decide(pass(&sync, &[denied.clone(), unknown.clone()]));
    assert_eq!(outcome.decision, Files(strings(&["a/2.jpg"])));
    assert_eq!(outcome.permanent, vec![denied]);
    let slow = make(
        Some("photos"),
        Some("string"),
        "error reading source directory: i/o timeout",
    );
    let unnamed = make(None, Some("*local.Fs"), "something failed");
    // Engine::run_job adds the identical round prefix when displaying a full-pass reason.
    assert_eq!(
        retry::decide(pass(&sync, &[unknown.clone(), slow])).decision,
        Full("因上一輪有資料夾讀取失敗，重新檢查全部檔案。".into())
    );
    assert_eq!(
        retry::decide(pass(&sync, &[unnamed])).decision,
        Full("因有不屬於單一檔案的錯誤，重新檢查全部檔案。".into())
    );
    assert_eq!(
        retry::decide(Pass {
            exit: 3,
            ..pass(&sync, &[])
        })
        .decision,
        Full("因 rclone 異常中斷且無單檔錯誤紀錄，重新檢查全部檔案。".into())
    );
    let one = [unknown];
    assert_eq!(
        retry::decide(Pass {
            overflow: true,
            ..pass(&sync, &one)
        })
        .decision,
        Full("因失敗檔案數過多，改為重新檢查全部檔案。".into())
    );
    let deleting = transfer("sync", json!({"deleteExcluded":true}));
    assert_eq!(
        retry::decide(pass(&deleting, &one)).decision,
        Full(
            "因開啟了「刪除排除項目」，只重試部分檔案會誤刪其他檔案，改為重新檢查全部檔案。".into()
        )
    );
    assert_eq!(
        retry::decide(Pass {
            attempt: 3,
            ..pass(&sync, &one)
        })
        .decision,
        Finish(Some("已達 3 輪嘗試上限，仍有未解決的錯誤。".into()))
    );
    assert_eq!(
        retry::decide(Pass {
            retryable: Some(false),
            ..pass(&sync, &one)
        })
        .decision,
        Finish(Some("rclone 判定這些錯誤重試也無法解決，停止重試。".into()))
    );
    let mut dry = sync.clone();
    dry.dry_run = true;
    assert_eq!(retry::decide(pass(&dry, &one)).decision, Finish(None));
    let deferred = || Pass {
        exit: 0,
        attempt: 2,
        last_scoped: true,
        deferred_earlier: true,
        ..pass(&sync, &[])
    };
    assert_eq!(
        retry::decide(deferred()).decision,
        Full("重新檢查全部檔案，以補做先前因錯誤而暫停的刪除。".into())
    );
    assert_eq!(retry::decide(Pass{attempt:3,..deferred()}).decision,Finish(Some("檔案傳輸錯誤已在重試後解決，但已達輪次上限；先前暫停的目標刪除尚未執行，下次同步時會處理。".into())));
    assert_eq!(
        retry::decide(Pass {
            outstanding: 1,
            ..deferred()
        })
        .decision,
        Finish(None)
    );
    assert_eq!(
        retry::decide(Pass {
            exit: 0,
            ..pass(&sync, &[])
        })
        .decision,
        Finish(None)
    );
    let argv = strings(&[
        "sync",
        "--retries=3",
        "--min-size=1K",
        "--max-depth=2",
        "--delete-excluded",
        "--delete-during",
        "--filter-from=/x/job.filter",
        "--combined=-",
        "--",
        "/src",
        "/dst",
    ]);
    assert_eq!(
        retry::single_pass(&argv)
            .into_iter()
            .filter(|a| a.starts_with("--retries"))
            .collect::<Vec<_>>(),
        strings(&["--retries=1"])
    );
    assert_eq!(
        retry::scoped(&argv, "/x/job.retry"),
        strings(&[
            "sync",
            "--retries=1",
            "--delete-during",
            "--combined=-",
            "--files-from-raw=/x/job.retry",
            "--",
            "/src",
            "/dst"
        ])
    );
    for (v, e) in [
        ("1m30s", Some(90.)),
        ("500ms", Some(0.5)),
        ("2s", Some(2.)),
        ("", None),
        ("soon", None),
    ] {
        assert_eq!(retry::seconds(v), e);
    }
    let base = json!({"bytes":1000.0,"checks":239921.0,"transfers":4.0,"elapsedTime":300.0,"transferTime":2.0,"totalBytes":1200.0});
    let raw = json!({"bytes":50,"checks":2,"transfers":1,"totalTransfers":2,"totalBytes":200,"elapsedTime":3.5,"errors":1});
    let result = retry::accumulate(&raw, &base, 52);
    for (key, want) in [
        ("bytes", 1050.),
        ("checks", 239923.),
        ("transfers", 5.),
        ("totalTransfers", 6.),
        ("totalBytes", 1200.),
        ("elapsedTime", 303.5),
        ("errors", 53.),
    ] {
        assert_eq!(number(&result, key), want, "{key}");
    }
}
#[test]
fn network_limits_user_agent_and_global_vs_per_transfer_flags() {
    let n = json!({"bindMode":"ipv6","connectTimeout":"9s","tpsLimit":2.5,"userAgent":"RBN/0.4 \"quoted\"","tpsBurst":3,"disableHTTP2":true});
    let args = models::network_arguments(&n).unwrap();
    for opt in [
        "--bind=::0",
        "--contimeout=9s",
        "--timeout=5m",
        "--tpslimit=2.5",
        "--tpslimit-burst=3",
        "--disable-http2=true",
        "--user-agent=RBN/0.4 \"quoted\"",
    ] {
        assert!(args.contains(&opt.to_owned()), "{opt}");
    }
    assert!(
        models::network_arguments(&json!({"bindMode":"ipv4"}))
            .unwrap()
            .contains(&"--bind=0.0.0.0".into())
    );
    for ip in ["127.0.0.1", "::1", "2001:db8::1234"] {
        assert!(
            models::network_arguments(&json!({"bindMode":"address","bindAddress":ip}))
                .unwrap()
                .contains(&format!("--bind={ip}"))
        );
    }
    for invalid in [
        json!({"bindMode":"address","bindAddress":"en0"}),
        json!({"bindMode":"address","bindAddress":"127.0.0.1:8080"}),
        json!({"bindMode":"address","bindAddress":"localhost"}),
        json!({"bindMode":"address","bindAddress":""}),
        json!({"bindMode":"other"}),
        json!({"dns":"8.8.8.8"}),
        json!({"tpsLimit":true}),
        json!({"tpsLimit":"3"}),
        json!({"tpsLimit":-1}),
        json!({"tpsBurst":1.5}),
        json!({"tpsBurst":0}),
        json!({"userAgent":"bad\r\nAuthorization: secret"}),
        json!({"disableHTTP2":1}),
        json!({"connectTimeout":"1s --rc"}),
    ] {
        assert!(models::network_arguments(&invalid).is_err(), "{}", invalid);
    }
    let defaults = models::default_settings(Path::new(source()));
    for option in ["--tpslimit=2", "--tpslimit-burst=3", "--disable-http2"] {
        let mut saved = defaults.clone();
        saved["defaultRcloneOptions"] = json!([option]);
        assert!(models::validate_settings(&saved, &defaults).is_err());
        assert!(models::validate_options(&json!({"extraArgs":[option]})).is_ok());
    }
}
#[test]
fn settings_migrate_queue_network_sparse_snapshots_and_custom_defaults() {
    let defaults = models::default_settings(Path::new(source()));
    for (limit, schema, expected) in [(2, 0, 0), (1, 0, 1), (4, 0, 4), (2, 4, 2)] {
        let mut raw = json!({"language":"en","theme":"blue-light","maxConcurrentJobs":limit,"skippedRcloneVersion":"v99.1.0",
            "defaultTransferOptions":{"connectTimeout":"1m","ioTimeout":"5m","comparison":"size"},
            "defaultRcloneOptions":["--tpslimit=2.5","--tpslimit-burst=3","--disable-http2","--buffer-size=2M"]});
        if schema > 0 {
            raw["settingsSchemaVersion"] = json!(schema);
            raw["defaultRcloneOptions"] = json!(["--buffer-size=2M"]);
        }
        let loaded = models::load_settings(&raw, &defaults).unwrap();
        assert_eq!(loaded["settingsSchemaVersion"], 7);
        assert_eq!(loaded["maxConcurrentJobs"], expected);
        assert_eq!(loaded["language"], "en");
        assert_eq!(loaded["theme"], "blue-light");
        assert_eq!(loaded["skippedRcloneVersion"], "v99.1.0");
        if schema == 0 {
            let network = &loaded["networkOptions"];
            assert_eq!(network["tpsLimit"], 2.5);
            assert_eq!(network["tpsBurst"], 3);
            assert_eq!(network["disableHTTP2"], true);
            assert_eq!(loaded["defaultRcloneOptions"], json!(["--buffer-size=2M"]));
            let opts = &loaded["defaultTransferOptions"];
            assert_eq!(opts["connectTimeout"], "");
            assert_eq!(opts["ioTimeout"], "");
            assert_eq!(opts["comparison"], "size");
        }
        let chosen = models::validate_settings(&json!({"maxConcurrentJobs":2}), &loaded).unwrap();
        assert_eq!(
            models::load_settings(&chosen, &defaults).unwrap()["maxConcurrentJobs"],
            2
        );
    }
    let mut legacy = models::default_options();
    legacy["maxDelete"] = json!(100);
    legacy["deleteMode"] = json!("after");
    legacy["localHashPolicy"] = json!("default");
    let mut req = request("sync", legacy.clone());
    let work = json!({"left":req["source"],"right":req["destination"],"direction":"lr","mode":"sync","options":legacy});
    let upgraded = models::load_settings(
        &json!({"settingsSchemaVersion":4,"defaultTransferOptions":legacy,"savedWorkspace":work}),
        &defaults,
    )
    .unwrap();
    let opts = &upgraded["defaultTransferOptions"];
    assert_eq!(opts["maxDelete"], -1);
    assert_eq!(opts["deleteMode"], "during");
    assert_eq!(opts["comparison"], "default");
    assert_eq!(opts["localHashPolicy"], "none");
    assert_eq!(upgraded["savedWorkspace"], work);
    req["options"] = json!({"comparison":"checksum"});
    let task = rbn_core::history::task(&json!({"id":"00000000-0000-4000-8000-000000000042","name":"Legacy snapshot","request":req,"createdAt":"2000-01-01T00:00:00Z","updatedAt":"2000-01-01T00:00:00Z"})).unwrap();
    let old = &task["request"]["options"];
    assert_eq!(old["maxDelete"], 100);
    assert_eq!(old["deleteMode"], "after");
    assert_eq!(old["localHashPolicy"], "default");
    let mut sparse = work.clone();
    sparse["options"] = json!({"comparison":"checksum"});
    let s = models::load_settings(
        &json!({"settingsSchemaVersion":4,"savedWorkspace":sparse}),
        &defaults,
    )
    .unwrap();
    assert_eq!(s["savedWorkspace"]["options"]["maxDelete"], 100);
    assert_eq!(s["savedWorkspace"]["options"]["localHashPolicy"], "default");
    let explicit=models::validate_settings(&json!({"defaultTransferOptions":{"maxDelete":100,"deleteMode":"after","localHashPolicy":"default"}}),&upgraded).unwrap();
    let reloaded = models::load_settings(&explicit, &defaults).unwrap();
    assert_eq!(reloaded["defaultTransferOptions"]["maxDelete"], 100);
    assert_eq!(reloaded["defaultTransferOptions"]["deleteMode"], "after");
    assert_eq!(
        reloaded["defaultTransferOptions"]["localHashPolicy"],
        "default"
    );
    for custom in [
        json!({"comparison":"checksum","maxDelete":12,"deleteMode":"before","localHashPolicy":"default"}),
        json!({"comparison":"size","maxDelete":0,"deleteMode":"during","localHashPolicy":"none"}),
    ] {
        let actual = models::load_settings(
            &json!({"settingsSchemaVersion":4,"defaultTransferOptions":custom}),
            &defaults,
        )
        .unwrap();
        for (key, value) in custom.as_object().unwrap() {
            assert_eq!(&actual["defaultTransferOptions"][key], value, "{key}");
        }
    }
}
#[test]
fn hidden_preset_choices_preserve_options_and_refuse_each_invalid_shape() {
    let d = models::default_settings(Path::new(source()));
    let checked = |list| models::validate_settings(&json!({"hiddenBuiltinPresets":list}), &d);
    let s = checked(json!(["nas-cloud", "local-nas", "local-nas"])).unwrap();
    assert_eq!(s["hiddenBuiltinPresets"], json!(["local-nas", "nas-cloud"]));
    assert_eq!(s["defaultTransferOptions"], d["defaultTransferOptions"]);
    for v in [
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
        assert!(checked(v).is_err());
    }
    assert_eq!(
        models::load_settings(&s, &d).unwrap()["hiddenBuiltinPresets"],
        s["hiddenBuiltinPresets"]
    );
    let all = [
        "local-nas",
        "nas-cloud",
        "local-cloud",
        "local-local",
        "cloud-cloud",
        "cloud-local",
    ];
    let mut sorted = all;
    sorted.sort();
    assert_eq!(
        checked(json!(all)).unwrap()["hiddenBuiltinPresets"],
        json!(sorted)
    );
    assert_eq!(
        checked(json!([])).unwrap()["hiddenBuiltinPresets"],
        json!([])
    );
}
#[test]
fn workspace_full_option_snapshot_and_invalid_boundaries() {
    let d = models::default_settings(Path::new(source()));
    let options=models::validate_options(&json!({"transfers":7,"checkers":9,"bandwidth":"2M","comparison":"default","skipExisting":true,"createEmptyDirs":false,
        "exclude":["*.tmp","folder/**"],"include":["*.bin"],"retries":4,"maxDelete":-1,"preserveMetadata":true,"driveSharedWithMe":true,"deleteMode":"during",
        "deleteExcluded":true,"ignoreChecksum":true,"modifyWindow":"2s","checkFirst":true,"fastList":true,"oneFileSystem":true,"noUpdateModtime":true,
        "minSize":"1B","maxSize":"10M","minAge":"1h","maxAge":"3d","maxDepth":7,"connectTimeout":"11s","ioTimeout":"2m","lowLevelRetries":8,
        "retrySleep":"2s","extraArgs":["--buffer-size=1M"],"localHashPolicy":"none"})).unwrap();
    let workspace = json!({"left":{"remote":null,"path":source()},"right":{"remote":"NAS-not-configured","path":"backup/写真"},"direction":"rl","mode":"sync","options":options});
    let state = models::validate_settings(&json!({"savedWorkspace":workspace}), &d).unwrap();
    assert_eq!(state["savedWorkspace"], workspace);
    for (key, value) in [
        ("direction", json!("backwards")),
        ("left", json!({"remote":null,"path":"relative"})),
        ("mode", json!("delete")),
        ("selection", json!([{"name":"stale","isDir":false}])),
        (
            "options",
            json!({"comparison":"checksum","localHashPolicy":"none"}),
        ),
    ] {
        let mut bad = workspace.clone();
        bad[key] = value;
        assert!(
            models::validate_settings(&json!({"savedWorkspace":bad}), &state).is_err(),
            "{key}"
        );
    }
    assert!(
        models::validate_settings(&json!({"savedWorkspace":{"direction":"lr"}}), &state).is_err()
    );
    assert_eq!(state["savedWorkspace"], workspace);
    let saved = models::load_settings(&state, &d).unwrap();
    assert_eq!(saved["savedWorkspace"], workspace);
    let empty = models::validate_settings(
        &json!({"savedWorkspace":null,"initialLocations":{}}),
        &state,
    )
    .unwrap();
    assert!(empty["savedWorkspace"].is_null());
    assert_eq!(empty["initialLocations"], json!({}));
}
#[test]
fn theme_scales_initial_locations_and_every_legacy_visual_size() {
    let d = models::default_settings(Path::new(source()));
    assert_eq!(d["theme"], "purple-auto");
    assert_eq!(d["interfaceScale"], 100);
    for (theme, expected) in [
        ("dark", "blue-dark"),
        ("system", "purple-auto"),
        ("green-auto", "green-auto"),
        ("blue-auto", "blue-auto"),
        ("purple-light", "purple-light"),
    ] {
        assert_eq!(
            models::validate_settings(&json!({"theme":theme}), &d).unwrap()["theme"],
            expected
        );
    }
    for theme in ["purple", "auto", "pink-auto", "purple-auto-dark", "-auto"] {
        assert!(models::validate_settings(&json!({"theme":theme}), &d).is_err());
    }
    for loc in [
        json!({"left":{"remote":null,"path":""}}),
        json!({"left":{"remote":null,"path":"relative"}}),
        json!({"right":{"remote":"drive","path":"a/../b"}}),
        json!({"right":{"remote":"drive","path":"bad\u{0}name"}}),
        json!({"other":{"remote":null,"path":source()}}),
    ] {
        assert!(models::validate_settings(&json!({"initialLocations":loc}), &d).is_err());
    }
    for patch in [
        json!({"paneColumnWidths":{"left":{"size":2}}}),
        json!({"maxConcurrentJobs":-1}),
        json!({"maxConcurrentJobs":129}),
        json!({"theme":"pink"}),
        json!({"httpProxy":"http://user:secret@127.0.0.1:1234"}),
        json!({"defaultRcloneOptions":["--rc"]}),
    ] {
        assert!(models::validate_settings(&patch, &d).is_err(), "{patch}");
    }
    for scale in [80, 90, 100, 110, 125] {
        let s = models::validate_settings(&json!({"language":"ja","interfaceScale":scale}), &d)
            .unwrap();
        let n = models::validate_settings(
            &json!({"theme":if scale==125{"green-light"}else{"green-dark"}}),
            &s,
        )
        .unwrap();
        assert_eq!(n["interfaceScale"], scale);
        assert_eq!(n["language"], "ja");
    }
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
            models::validate_settings(&json!({"interfaceScale":invalid}), &d).is_err(),
            "{invalid}"
        );
    }
    for schema in [0, 5, 6] {
        for s in [80, 90, 100, 110, 125] {
            let migrated=models::load_settings(&json!({"settingsSchemaVersion":schema,"interfaceScale":s,"language":"ja","theme":"green-dark"}),&d).unwrap();
            assert_eq!(migrated["interfaceScale"], s + 10);
            assert_eq!(migrated["language"], "ja");
            assert_eq!(migrated["theme"], "green-dark");
            assert_eq!(migrated["settingsSchemaVersion"], 7);
            let reopened = models::load_settings(&migrated, &d).unwrap();
            assert_eq!(reopened["interfaceScale"], s + 10);
            let edited =
                models::validate_settings(&json!({"theme":"purple-dark"}), &reopened).unwrap();
            assert_eq!(edited["interfaceScale"], s + 10);
            let next = models::validate_settings(&json!({"interfaceScale":100}), &edited).unwrap();
            assert_eq!(
                models::load_settings(&next, &d).unwrap()["interfaceScale"],
                100
            );
        }
    }
}
