use models::{Endpoint, TransferRequest};
use rbn_core::{local, models, storage};
use serde_json::{Value, json};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::atomic::AtomicBool,
};
use uuid::Uuid;

struct Area(PathBuf);
impl Area {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!("rbn-contract-{}", Uuid::new_v4()));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn directory(&self, name: &str) -> PathBuf {
        let p = self.0.join(name);
        fs::create_dir_all(&p).unwrap();
        p
    }
}
impl Drop for Area {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
fn request() -> Value {
    json!({"source":{"remote":"a","path":"dir"},"destination":{"remote":"b","path":"dir"},"mode":"copy","options":{},"selection":[],"dryRun":false})
}
#[test]
fn validated_argv_and_json_round_trip() {
    let mut v = request();
    v["options"] = json!({"comparison":"checksum-only","localHashPolicy":"default","symlinkMode":"preserve","extraArgs":["--use-mmap","--buffer-size=16MiB"]});
    v["label"] = json!("transfer");
    v["direction"] = json!("rl");
    let r = TransferRequest::parse(&v).unwrap();
    let args = r.arguments(None).unwrap();
    assert!(
        args.contains(&"--checksum".into())
            && args.contains(&"--ignore-size".into())
            && args.contains(&"--links".into())
    );
    assert_eq!(&args[args.len() - 3..], ["--", "a:dir", "b:dir"]);
    assert_eq!(
        TransferRequest::parse(&r.value()).unwrap().value(),
        r.value()
    );
}
#[test]
fn validates_complete_option_surface() {
    let invalid = [
        json!({"transfers":true}),
        json!({"checkers":1.5}),
        json!({"lowLevelRetries":0}),
        json!({"skipExisting":1}),
        json!({"comparison":"checksum"}),
        json!({"comparison":"none","updateOnly":true}),
        json!({"extraArgs":["--config=/tmp/x"]}),
        json!({"extraArgs":["--use-mmap","--use-mmap=false"]}),
        json!({"bandwidth":"1MB"}),
        json!({"minAge":"2d","maxAge":"47h"}),
        json!({"maxAge":"10000000000s"}),
        json!({"minSize":"2","maxSize":"2047B"}),
        json!({"include":["bad\nrule"]}),
    ];
    for options in invalid {
        let mut v = request();
        v["options"] = options.clone();
        assert!(TransferRequest::parse(&v).is_err(), "{options}");
    }
    for size in ["0", "1B", "2MiB", "0.5g", "1kI"] {
        let mut v = request();
        v["options"] = json!({"bandwidth":size});
        assert!(TransferRequest::parse(&v).is_ok(), "{size}");
    }
}
#[test]
fn selected_sync_boundaries() {
    let mut v = request();
    v["mode"] = json!("sync");
    v["selection"] = json!([{"name":"a [*]","isDir":true}]);
    let r = TransferRequest::parse(&v).unwrap();
    assert_eq!(
        models::filter_contents(&r).unwrap(),
        "- .DS_Store\n- ._*\n+ /a[ ]\\[\\*\\]/**\n- **\n"
    );
    v["options"] = json!({"deleteExcluded":true});
    assert!(TransferRequest::parse(&v).is_err());
    assert!(
        TransferRequest::parse_saved(&v)
            .unwrap()
            .validate_operation()
            .is_err()
    );
    v["options"] = json!({});
    v["selection"][0]["isDir"] = json!(false);
    assert!(TransferRequest::parse(&v).is_err());
}
#[test]
fn exact_selection_requires_filtered_destination_listing() {
    let mut v = request();
    v["mode"] = json!("sync");
    v["selection"] = json!([{"name":"資料","isDir":true}]);
    v["options"] = json!({"include":["*.txt"]});
    let r = TransferRequest::parse(&v).unwrap();
    let allowed = models::exact_filter_rules(
        &r,
        &[
            json!({"Path":"資料/gone.txt","IsDir":false}),
            json!({"Path":"unselected/file.txt","IsDir":false}),
        ],
    )
    .unwrap();
    assert_eq!(allowed, ["+ /資料/gone.txt", "- **"]);
    let spellings = models::exact_filter_rules(
        &r,
        &[
            json!({"Path":"資料/e\u{301}.txt","IsDir":false}),
            json!({"Path":"資料/é.txt","IsDir":false}),
            json!({"Path":"資料//child","IsDir":false}),
            json!({"Path":"資料/./sub","IsDir":true}),
            json!({"Path":"other/not-selected"}),
        ],
    )
    .unwrap();
    assert_eq!(
        spellings,
        [
            "+ /資料/./sub/",
            "+ /資料//child",
            "+ /資料/e\u{301}.txt",
            "- **"
        ]
    );
    assert!(models::exact_filter_rules(&r, &[json!({"Path":"../outside","IsDir":false})]).is_err());
}
#[test]
fn old_settings_only_migrate_once() {
    let area = Area::new();
    let d = models::default_settings(&area.0);
    let v = json!({"interfaceScale":90,"maxConcurrentJobs":2,"defaultTransferOptions":{"maxDelete":100,"deleteMode":"after","comparison":"checksum","ioTimeout":"5m"},"defaultRcloneOptions":["--tpslimit=12.5","--disable-http2","--use-mmap"]});
    let current = models::load_settings(&v, &d).unwrap();
    assert_eq!(current["interfaceScale"], 100);
    assert_eq!(current["maxConcurrentJobs"], 0);
    assert_eq!(
        current["defaultTransferOptions"]["localHashPolicy"],
        "default"
    );
    assert_eq!(current["defaultTransferOptions"]["maxDelete"], -1);
    assert_eq!(current["networkOptions"]["tpsLimit"], 12.5);
    assert_eq!(current["defaultRcloneOptions"], json!(["--use-mmap"]));
    assert_eq!(models::load_settings(&current, &d).unwrap(), current);
    assert_eq!(
        models::validate_settings(&json!({"interfaceScale":90}), &current).unwrap()["interfaceScale"],
        90
    );
}
#[test]
fn endpoint_and_overlap() {
    assert!(Endpoint::parse(&json!({"path":"x"})).is_err());
    assert!(Endpoint::parse(&json!({"remote":"a","path":"a/../b"})).is_err());
    assert_eq!(
        Endpoint::parse(&json!({"remote":"a","path":"//dir/./x/"}))
            .unwrap()
            .child("é")
            .unwrap()
            .target(),
        "a:/dir/x/é"
    );
    let area = Area::new();
    let src = area.directory("src");
    let mut v = request();
    v["source"] = json!({"remote":null,"path":src});
    v["destination"] = json!({"remote":null,"path":src.join("future/new")});
    assert!(models::validate_pair(&TransferRequest::parse(&v).unwrap()).is_err());
    v["source"]["path"] = json!(src.join("absent"));
    assert!(models::validate_pair(&TransferRequest::parse(&v).unwrap()).is_err());
    #[cfg(unix)]
    {
        let alias = area.0.join("alias");
        std::os::unix::fs::symlink(&src, &alias).unwrap();
        v["source"]["path"] = json!(src);
        v["destination"]["path"] = json!(alias.join("new"));
        assert!(models::validate_pair(&TransferRequest::parse(&v).unwrap()).is_err());
    }
}
#[test]
fn state_file_roundtrip_and_corruption_preserved() {
    let area = Area::new();
    let d = area.0.join("state");
    storage::private_directory(&d).unwrap();
    let p = d.join("jobs.json");
    storage::atomic_json(&p, &json!([1, 2])).unwrap();
    storage::atomic_json(&p, &json!([3])).unwrap();
    assert_eq!(
        storage::atomic_json(&p, &json!(42)).unwrap_err(),
        "資料無法儲存成 JSON。"
    );
    assert_eq!(storage::read_json(&p, Value::Null).unwrap(), json!([3]));
    fs::write(&p, "broken").unwrap();
    assert_eq!(storage::read_json(&p, json!([])).unwrap(), json!([]));
    let entries: Vec<_> = fs::read_dir(&d)
        .unwrap()
        .map(|e| e.unwrap().path())
        .collect();
    assert_eq!(entries.len(), 1);
    assert!(
        entries[0]
            .file_name()
            .unwrap()
            .to_string_lossy()
            .contains(".unreadable-")
    );
    assert_eq!(fs::read(&entries[0]).unwrap(), b"broken");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::write(&p, b"still unreadable").unwrap();
        // SAFETY: geteuid has no pointer arguments.
        if unsafe { libc::geteuid() } != 0 {
            fs::set_permissions(&d, fs::Permissions::from_mode(0o500)).unwrap();
            let value = storage::read_json(&p, json!([]));
            fs::set_permissions(&d, fs::Permissions::from_mode(0o700)).unwrap();
            assert_eq!(value.unwrap(), json!([]));
            assert_eq!(fs::read(&p).unwrap(), b"still unreadable");
        }
    }
}
#[cfg(unix)]
fn prune(
    s: &Path,
    d: &Path,
    paths: &[&str],
    max: i64,
    dry: bool,
    cancel: bool,
) -> Result<usize, String> {
    local::prune_empty_directories(
        s,
        d,
        &paths.iter().map(|s| s.to_string()).collect::<Vec<_>>(),
        max,
        dry,
        &AtomicBool::new(cancel),
        &mut |_, planned| {
            assert_eq!(planned, dry);
            Ok(())
        },
    )
}
#[cfg(unix)]
#[test]
fn descriptor_prune_protects_entries_and_filtered_siblings() {
    let area = Area::new();
    let s = area.directory("src");
    let d = area.directory("dest");
    area.directory("other/empty");
    for name in ["old/child", "é", "broken/x", "populated", "unlisted"] {
        fs::create_dir_all(d.join(name)).unwrap();
    }
    fs::create_dir(s.join("e\u{301}")).unwrap();
    std::os::unix::fs::symlink(s.join("missing"), s.join("broken")).unwrap();
    std::os::unix::fs::symlink(area.0.join("other"), d.join("link")).unwrap();
    fs::write(d.join("populated/item"), b"keep").unwrap();
    let paths = [
        "old",
        "old/child",
        "é",
        "broken/x",
        "link/empty",
        "link",
        "populated",
    ];
    assert_eq!(prune(&s, &d, &paths, -1, true, false).unwrap(), 2);
    assert!(d.join("old/child").is_dir());
    assert!(prune(&s, &d, &["old/child", "../escape"], -1, false, false).is_err());
    assert_eq!(prune(&s, &d, &paths, -1, false, true).unwrap(), 0);
    assert_eq!(prune(&s, &d, &paths, 1, false, false).unwrap(), 1);
    assert_eq!(prune(&s, &d, &paths, -1, false, false).unwrap(), 1);
    assert!(
        d.join("unlisted").is_dir()
            && d.join("é").is_dir()
            && area.0.join("other/empty").is_dir()
            && d.join("populated/item").is_file()
            && d.join("broken/x").is_dir()
    );
}

fn overlay(base: &Value, patch: &Value) -> Value {
    let mut v = base.clone();
    for (k, value) in patch.as_object().unwrap() {
        v[k] = value.clone();
    }
    v
}
#[test]
fn swift_0110_request_oracle() {
    let fixture: Value = serde_json::from_str(include_str!("fixtures/models-0.11.0.json")).unwrap();
    assert_eq!(models::default_options(), fixture["options"]);
    for row in fixture["cases"].as_array().unwrap() {
        let req = overlay(&fixture["base"], &row["request"]);
        let parsed = TransferRequest::parse(&req);
        let exp = &row["expected"];
        let name = &row["name"];
        if exp.is_null() {
            let error = parsed.unwrap_err();
            assert_eq!(error, row["error"].as_str().unwrap(), "rejection {name}");
            for language in ["zh-TW", "en", "ja"] {
                assert_eq!(
                    rbn_core::native::translate(&error, language),
                    row["errors"][language].as_str().unwrap(),
                    "translation {name} {language}"
                );
            }
            continue;
        }
        let parsed = parsed.unwrap_or_else(|e| panic!("Swift accepts {name}: {e}"));
        let mut expected = overlay(&fixture["base"], &exp["value"]);
        expected["options"] = overlay(&fixture["options"], &expected["options"]);
        assert_eq!(parsed.value(), expected, "canonical request {name}");
        assert_eq!(
            json!(parsed.arguments(None).unwrap()),
            exp["arguments"],
            "argv {name}"
        );
        assert_eq!(
            json!(models::selection_filter_rules(&parsed)),
            exp["filters"],
            "filter rules {name}"
        );
    }
}
#[test]
fn settings_invalid_patches_are_all_or_nothing() {
    let area = Area::new();
    let state = models::default_settings(&area.0);
    let copy = state.clone();
    let bad = [
        json!({"interfaceScale":91}),
        json!({"theme":"yellow-dark"}),
        json!({"language":"zh"}),
        json!({"maxConcurrentJobs":-1}),
        json!({"settingsRevision":true}),
        json!({"settingsRevision":9007199254740991_u64}),
        json!({"hiddenBuiltinPresets":["missing"]}),
        json!({"rclonePath":"relative/rclone"}),
        json!({"notifyOnCompletion":1}),
        json!({"retryScope":"unknown"}),
        json!({"showHiddenFiles":null}),
        json!({"streamPlayerArguments":["a\nb"]}),
        json!({"defaultTransferOptions":{"checkers":true}}),
        json!({"paneColumnWidths":{"right":{"modified":520}}}),
        json!({"paneColumnWidths":{"middle":{}}}),
        json!({"paneColumnWidths":{"right":{"unsupported":12}}}),
        json!({"initialLocations":{"left":{"remote":null,"path":"relative"}}}),
        json!({"savedWorkspace":{"mode":"copy","selection":[]}}),
        json!({"proxyMode":"auto"}),
        json!({"httpProxy":"https://name@localhost/"}),
        json!({"httpsProxy":"http://:password@localhost/"}),
        json!({"httpsProxy":"http://host:65536/"}),
        json!({"httpsProxy":"http://host:0/"}),
        json!({"httpsProxy":"ftp://host"}),
        json!({"httpsProxy":"http://host?query=x"}),
        json!({"httpProxy":"http://host/path"}),
        json!({"noProxy":"one, two"}),
        json!({"networkOptions":{"tpsLimit":true}}),
        json!({"networkOptions":{"tpsBurst":0}}),
        json!({"networkOptions":{"bindMode":"address","bindAddress":"localhost"}}),
        json!({"networkOptions":{"bindMode":"address","bindAddress":"::1:2001:bad:invalid"}}),
        json!({"networkOptions":{"ioTimeout":"forever"}}),
        json!({"networkOptions":{"unknown":1}}),
        json!({"defaultRcloneOptions":["--tpslimit=1"]}),
        json!({"defaultRcloneOptions":["--disable-http2"]}),
    ];
    for patch in bad {
        assert!(
            models::validate_settings(&patch, &state).is_err(),
            "accepted {patch}"
        );
        assert_eq!(state, copy);
    }
}
#[test]
fn settings_nested_patches_snapshot_and_scale_migrations() {
    let temp = Area::new();
    let defaults = models::default_settings(&temp.0);
    for (schema, size, want) in [
        (6, 80, 90),
        (6, 90, 100),
        (5, 100, 110),
        (6, 110, 120),
        (0, 125, 135),
        (7, 100, 100),
    ] {
        let s = models::load_settings(
            &json!({"settingsSchemaVersion":schema,"interfaceScale":size}),
            &defaults,
        )
        .unwrap();
        assert_eq!(s["interfaceScale"], want);
    }
    let w = json!({"left":{"remote":"a","path":"l"},"right":{"remote":"b","path":"r"},"direction":"rl","mode":"copy","options":{"comparison":"checksum"}});
    let v=models::load_settings(&json!({"settingsSchemaVersion":4,"savedWorkspace":w,"defaultTransferOptions":{"maxDelete":100,"deleteMode":"after","localHashPolicy":"default"}}),&defaults).unwrap();
    assert_eq!(v["savedWorkspace"]["options"]["maxDelete"], 100);
    assert_eq!(v["savedWorkspace"]["options"]["deleteMode"], "after");
    assert_eq!(v["savedWorkspace"]["options"]["localHashPolicy"], "default");
    assert_eq!(v["defaultTransferOptions"]["maxDelete"], -1);
    assert_eq!(v["defaultTransferOptions"]["deleteMode"], "during");
    let patch = json!({"paneColumnWidths":{"left":{"name":200,"size":112}},"initialLocations":{"left":{"remote":"a","path":"start"}},"theme":"dark","hiddenBuiltinPresets":["nas-cloud","nas-cloud"]});
    let one = models::validate_settings(&patch, &v).unwrap();
    let two=models::validate_settings(&json!({"paneColumnWidths":{"left":{"name":320},"right":{"modified":300}},"initialLocations":{},"savedWorkspace":null}),&one).unwrap();
    assert_eq!(one["hiddenBuiltinPresets"], json!(["nas-cloud"]));
    assert_eq!(one["theme"], "blue-dark");
    assert_eq!(one["savedWorkspace"], v["savedWorkspace"]);
    assert_eq!(
        two["paneColumnWidths"],
        json!({"left":{"name":320,"size":112},"right":{"modified":300}})
    );
    assert_eq!(two["initialLocations"], json!({}));
    assert!(two["savedWorkspace"].is_null());
}
#[test]
fn global_network_and_paths() {
    let a = Area::new();
    let defaults = models::default_settings(&a.0);
    let d = a.directory("bin");
    let v = models::validate_settings(
        &json!({"rcloneDirectory":d,"settingsRevision":0}),
        &defaults,
    )
    .unwrap();
    assert_eq!(
        Path::new(v["rclonePath"].as_str().unwrap()).parent(),
        Some(d.as_path())
    );
    let manual=models::validate_settings(&json!({"networkOptions":{"bindMode":"address","bindAddress":" 127.0.0.1 ","tpsLimit":2.5,"tpsBurst":3,"userAgent":"agent","disableHTTP2":true},"httpProxy":" socks5://127.0.0.1:1080 "}),&v).unwrap();
    assert_eq!(manual["httpProxy"], "socks5://127.0.0.1:1080");
    let flags = models::network_arguments(&manual["networkOptions"]).unwrap();
    assert_eq!(
        flags,
        [
            "--bind=127.0.0.1",
            "--contimeout=1m",
            "--timeout=5m",
            "--user-agent=agent",
            "--tpslimit=2.5",
            "--tpslimit-burst=3",
            "--disable-http2=true"
        ]
    );
    let s=models::load_settings(&json!({"defaultRcloneOptions":["--tpslimit-burst=8","--disable-http2"],"networkOptions":{"tpsBurst":7,"disableHTTP2":false}}),&defaults).unwrap();
    assert_eq!(s["networkOptions"]["tpsBurst"], 7);
    assert_eq!(s["networkOptions"]["disableHTTP2"], false);
    assert_eq!(s["defaultRcloneOptions"], json!([]));
}
#[cfg(any(target_os = "linux", target_os = "macos"))]
#[test]
fn local_encoding_policy_is_effective_only_and_smb_rules_use_both_spellings() {
    use std::collections::BTreeMap;
    let a = Area::new();
    let mut v = request();
    v["source"] = json!({"remote":null,"path":a.directory("s")});
    v["destination"] = json!({"remote":null,"path":a.directory("d")});
    v["options"] = json!({"extraArgs":["--local-no-clone=false"]});
    let r = TransferRequest::parse(&v).unwrap();
    let args = r.arguments(Some(&a.0.join("filter"))).unwrap();
    assert_eq!(r.options["extraArgs"], json!(["--local-no-clone=false"]));
    assert!(args.iter().any(|a| a == local::LOCAL_ENCODING));
    if cfg!(target_os = "macos") {
        assert!(args.iter().any(|a| a == "--local-no-clone"));
        assert!(!args.iter().any(|a| a == "--local-no-clone=false"));
    }
    let types = BTreeMap::from([("files".into(), "smb".into())]);
    v["destination"] = json!({"remote":"files","path":"share"});
    let req = TransferRequest::parse(&v).unwrap();
    let args = local::smb_arguments(req.arguments(None).unwrap(), &types);
    assert!(args.iter().any(|s| s == local::SMB_ENCODING));
    assert_eq!(
        args.iter().filter(|s| *s == local::LOCAL_ENCODING).count(),
        1
    );
    assert!(args.iter().any(|s| s == "--local-no-clone=false"));
    let rules = local::smb_filter_rules(vec!["+ /é.txt".into()], &req, &types);
    if cfg!(target_os = "macos") {
        assert_eq!(rules, ["+ /é.txt", "+ /e\u{301}.txt"]);
    } else {
        assert_eq!(rules, ["+ /é.txt"]);
    }
    assert_eq!(
        local::listing_name_flags(&req, &types),
        [local::LOCAL_ENCODING]
    );
    assert!(local::listing_name_flags(&req, &BTreeMap::new()).is_empty());
}
#[cfg(unix)]
#[test]
fn prune_revalidates_replaced_root_between_candidates() {
    let area = Area::new();
    let src = area.directory("src");
    let dst = area.directory("dst");
    area.directory("dst/a");
    area.directory("dst/b");
    let result = local::prune_empty_directories(
        &src,
        &dst,
        &["a".into(), "b".into()],
        -1,
        false,
        &AtomicBool::new(false),
        &mut |p, _| {
            assert_eq!(p, "a");
            fs::rename(&src, area.0.join("old-source")).unwrap();
            fs::create_dir(&src).unwrap();
            Ok(())
        },
    );
    assert!(result.is_err());
    assert!(dst.join("b").is_dir());
}
#[cfg(unix)]
#[test]
fn prune_stops_if_a_source_name_cannot_be_decoded() {
    use std::{ffi::OsString, os::unix::ffi::OsStringExt};
    let area = Area::new();
    let s = area.directory("s");
    let d = area.directory("d");
    area.directory("d/old");
    let bad = s.join(OsString::from_vec(vec![0xfe, 0xff]));
    if fs::write(&bad, b"").is_err() {
        return;
    } // Some filesystems decline non-UTF8 names.
    assert!(prune(&s, &d, &["old"], -1, false, false).is_err());
    assert!(d.join("old").is_dir());
}
#[cfg(unix)]
#[test]
fn destination_roots_and_remote_overlap() {
    let area = Area::new();
    let mut v = request();
    let root = area.0.join("root-link");
    // Only invoke request validation. This fixture never starts a transfer.
    v["dryRun"] = json!(true);
    std::os::unix::fs::symlink("/", &root).unwrap();
    v["destination"] = json!({"remote":null,"path":root});
    assert!(models::validate_pair(&TransferRequest::parse(&v).unwrap()).is_ok());
    v["destination"]["path"] = json!("/");
    assert!(models::validate_pair(&TransferRequest::parse(&v).unwrap()).is_err());
    let missing = area.0.join("dangling");
    std::os::unix::fs::symlink(area.0.join("not-created"), &missing).unwrap();
    v["destination"]["path"] = json!(missing);
    assert!(models::validate_pair(&TransferRequest::parse(&v).unwrap()).is_ok());
    v["source"] = json!({"remote":null,"path":area.directory("local-source")});
    v["destination"]["path"] = json!(root);
    assert!(models::validate_pair(&TransferRequest::parse(&v).unwrap()).is_err());
    for (a, b, allowed) in [
        ("one", "one/two", false),
        ("one-two", "one", true),
        ("", "a", false),
        ("/x", "x/", false),
        ("é", "e\u{301}/sub", false),
    ] {
        v["source"] = json!({"remote":"files","path":a});
        v["destination"] = json!({"remote":"files","path":b});
        assert_eq!(
            models::validate_pair(&TransferRequest::parse(&v).unwrap()).is_ok(),
            allowed
        );
    }
}

#[cfg(unix)]
#[test]
fn swift_0110_settings_oracle() {
    let fixtures: Value =
        serde_json::from_str(include_str!("fixtures/settings-0.11.0.json")).unwrap();
    let base = models::default_settings(Path::new("/oracle/rclone"));
    let mut failures = vec![];
    fn canonical(v: &Value) -> Value {
        match v {
            Value::Object(o) => {
                Value::Object(o.iter().map(|(k, v)| (k.clone(), canonical(v))).collect())
            }
            Value::Array(a) => Value::Array(a.iter().map(canonical).collect()),
            Value::Number(n)
                if n.as_f64()
                    .is_some_and(|x| x.fract() == 0. && x.abs() < 9007199254740992.) =>
            {
                json!(n.as_f64().unwrap() as i64)
            }
            other => other.clone(),
        }
    }
    assert_eq!(canonical(&base), canonical(&fixtures["defaults"]));
    for row in fixtures["cases"].as_array().unwrap() {
        let prev = row
            .get("previous")
            .map(|p| models::validate_settings(p, &base).unwrap())
            .unwrap_or_else(|| base.clone());
        let observed = if row["op"] == "load" {
            models::load_settings(&row["raw"], &prev)
        } else {
            models::validate_settings(&row["raw"], &prev)
        };
        let name = row["name"].as_str().unwrap();
        match observed {
            Ok(v) if row["expected"].is_object() => {
                let expected = overlay(&fixtures["defaults"], &row["expected"]);
                if canonical(&expected) != canonical(&v) {
                    failures.push(format!(
                        "{name} differs in {:?}",
                        expected
                            .as_object()
                            .unwrap()
                            .keys()
                            .filter(|k| canonical(&v[*k]) != canonical(&expected[*k]))
                            .collect::<Vec<_>>()
                    ));
                }
            }
            Err(e) if row["expected"].is_null() => {
                if e != row["error"] {
                    failures.push(format!("{name}: {e:?} expected {}", row["error"]));
                } else {
                    for lang in ["zh-TW", "en", "ja"] {
                        if rbn_core::native::translate(&e, lang) != row["errors"][lang] {
                            failures.push(format!("{name} translation {lang}"));
                        }
                    }
                }
            }
            other => failures.push(format!("{name} wrong acceptance: {}", other.is_ok())),
        }
    }
    assert!(failures.is_empty(), "\n{}", failures.join("\n"));
}
#[test]
fn partial_cli_preserves_usage_and_exit_codes() {
    let run = |args: &[&str]| {
        let mut stdout = vec![];
        let mut stderr = vec![];
        let code = rbn_core::partial::run_cli(
            &args.iter().map(|s| s.to_string()).collect::<Vec<_>>(),
            &mut stdout,
            &mut stderr,
        );
        (code, stdout, stderr)
    };
    assert_eq!(run(&["else"]).0, None);
    for (args, msg) in [
        (
            vec![
                "--repair-local-partials",
                "?",
                "--report",
                "/a",
                "--plan",
                "/b",
            ],
            "用法：",
        ),
        (
            vec![
                "--repair-local-partials",
                "preview",
                "--report",
                "/a",
                "--report",
                "/b",
            ],
            "請使用不重複的參數與絕對路徑。",
        ),
        (
            vec![
                "--repair-local-partials",
                "cleanup",
                "--result",
                "relative",
                "--receipt",
                "/b",
            ],
            "請使用不重複的參數與絕對路徑。",
        ),
        (
            vec![
                "--repair-local-partials",
                "apply",
                "--report",
                "/a",
                "--plan",
                "/b",
            ],
            "修復參數不正確。",
        ),
    ] {
        let (code, out, err) = run(&args);
        assert_eq!(code, Some(2));
        assert!(out.is_empty());
        assert!(err.ends_with(b"\n"));
        let e: Value = serde_json::from_slice(&err).unwrap();
        assert!(e["error"].as_str().unwrap().starts_with(msg));
    }
}

#[cfg(target_os = "macos")]
#[test]
fn preview_effective_arguments_and_warning_order() {
    let rows: Vec<Value> =
        serde_json::from_str(include_str!("fixtures/preview-0.11.0.json")).unwrap();
    let mut failed = true;
    for row in rows {
        if let Some(scope) = row.get("settings").and_then(|v| v["retryScope"].as_str()) {
            failed = scope == "failed";
        }
        // Absolute local placeholder paths keep the original public request shape.
        let raw = row["request"]
            .to_string()
            .replace("RBN_TEST_AREA", "/rbn-preview-golden");
        let input: Value = serde_json::from_str(&raw).unwrap();
        let request = TransferRequest::parse(&input);
        if row["expected"].is_null() {
            assert_eq!(
                request.unwrap_err(),
                row["error"].as_str().unwrap(),
                "{}",
                row["name"]
            );
            continue;
        }
        let (args, warnings) =
            local::preview_arguments(&request.unwrap(), &Default::default(), failed).unwrap();
        assert_eq!(
            json!(warnings),
            row["expected"]["warnings"],
            "{}",
            row["name"]
        );
        let expected = row["expected"]["command"]
            .as_str()
            .unwrap()
            .replace("RBN_TEST_AREA", "/rbn-preview-golden");
        let actual = local::display_command(&args);
        assert!(
            expected.ends_with(&actual),
            "{}\nSwift {expected}\nRust {actual}",
            row["name"]
        );
    }
}

#[cfg(unix)]
#[test]
fn private_state_directory_follows_existing_configured_directory() {
    use std::os::unix::fs::{PermissionsExt, symlink};
    let area = Area::new();
    let selected = area.directory("owned-target");
    fs::set_permissions(&selected, fs::Permissions::from_mode(0o750)).unwrap();
    let link = area.0.join("state-location");
    symlink(&selected, &link).unwrap();
    storage::private_directory(&link).unwrap();
    assert_eq!(
        fs::metadata(&selected).unwrap().permissions().mode() & 0o777,
        0o700
    );
    assert!(fs::symlink_metadata(link).unwrap().is_symlink());
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
#[test]
fn standalone_prune_validates_distinct_roots_in_dry_run() {
    let area = Area::new();
    let source = area.directory("source");
    let dest = area.directory("source/ordinary-subdirectory");
    fs::create_dir(dest.join("old")).unwrap();
    assert_eq!(prune(&source, &dest, &["old"], -1, true, false).unwrap(), 1);
    assert!(dest.join("old").is_dir());
    assert!(prune(&dest, &dest, &["old"], -1, true, false).is_err());
}

#[cfg(unix)]
#[test]
fn original_prune_validation_limits_and_plans_preserve_exact_paths() {
    use std::os::unix::fs::symlink;

    let area = Area::new();
    let source = area.directory("unopenable/source");
    let destination = area.directory("unopenable/destination");
    symlink(area.0.join("never-created"), source.join("listed")).unwrap();
    area.directory("unopenable/destination/listed/empty");
    assert_eq!(
        prune(
            &source,
            &destination,
            &["listed/empty", "listed"],
            -1,
            false,
            false
        )
        .unwrap(),
        0
    );
    assert!(destination.join("listed/empty").is_dir());

    let source = area.directory("symlink/source");
    let destination = area.directory("symlink/destination");
    let outside = area.directory("symlink/outside");
    area.directory("symlink/outside/empty");
    symlink(&outside, destination.join("link")).unwrap();
    assert_eq!(
        prune(
            &source,
            &destination,
            &["link/empty", "link"],
            -1,
            false,
            false
        )
        .unwrap(),
        0
    );
    assert!(outside.join("empty").is_dir());

    let source = area.directory("invalid/source");
    let destination = area.directory("invalid/destination");
    area.directory("invalid/destination/old");
    assert!(
        prune(
            &source,
            &destination,
            &["old", "../outside"],
            -1,
            false,
            false
        )
        .is_err()
    );
    assert!(destination.join("old").is_dir());

    let source = area.directory("limit/source");
    let destination = area.directory("limit/destination");
    area.directory("limit/destination/a");
    area.directory("limit/destination/b");
    assert_eq!(
        prune(&source, &destination, &["a", "b"], 1, false, false).unwrap(),
        1
    );
    assert!(!destination.join("a").exists());
    assert!(destination.join("b").is_dir());
    assert_eq!(
        prune(&source, &destination, &["b"], -1, false, true).unwrap(),
        0
    );
    assert!(destination.join("b").is_dir());

    let source = area.directory("dry/source");
    let destination = area.directory("dry/destination");
    area.directory("dry/destination/old/child");
    // The shared prune wrapper checks that every record has the expected dry-run flag.
    assert_eq!(
        prune(
            &source,
            &destination,
            &["old", "old/child"],
            -1,
            true,
            false
        )
        .unwrap(),
        2
    );
    assert!(destination.join("old/child").is_dir());
}
