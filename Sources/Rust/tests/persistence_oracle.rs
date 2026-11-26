//! Public job history and task format contracts captured from 0.11.0.
use rbn_core::engine::Engine;
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    path::{Path, PathBuf},
};

struct Area(PathBuf);
impl Area {
    fn new() -> Self {
        let p = std::env::temp_dir().join(format!("rbn-legacy-state-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&p).unwrap();
        Self(p)
    }
}
impl Drop for Area {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
fn uid(i: u64) -> String {
    format!("00000000-0000-4000-8000-{i:012x}")
}
fn expand(v: &Value) -> Value {
    if let Some(s) = v.get("$repeatText").and_then(Value::as_str) {
        return json!(s.repeat(v["count"].as_u64().unwrap() as usize));
    }
    match v.get("$series").and_then(Value::as_str) {
        Some("task") => {
            let start = v["idStart"].as_u64().unwrap();
            let rows = (0..v["count"].as_u64().unwrap())
                .map(|i| {
                    let mut t = v["base"].clone();
                    t["id"] = json!(uid(start + i));
                    t["name"] = json!(format!("task-{}", start + i));
                    t["updatedAt"] = json!(format!("2001-{i:04}"));
                    t
                })
                .collect::<Vec<_>>();
            return json!(rows);
        }
        Some("retention-jobs") => {
            let mut rows = Vec::new();
            for i in 0..v["unfinished"].as_u64().unwrap() {
                let mut j = v["base"].clone();
                j["id"] = json!(uid(500 + i));
                j["status"] = json!(if i % 2 == 0 { "queued" } else { "running" });
                rows.push(j);
            }
            for i in 0..v["ended"].as_u64().unwrap() {
                let mut j = v["base"].clone();
                j["id"] = json!(uid(1000 + i));
                j["status"] = json!("failed");
                j["endedAt"] = json!(format!("2020/{i:04}"));
                rows.push(j);
            }
            return json!(rows);
        }
        Some(other) => panic!("unknown fixture expansion {other}"),
        None => {}
    }
    match v {
        Value::Object(o) => Value::Object(o.iter().map(|(k, v)| (k.clone(), expand(v))).collect()),
        Value::Array(a) => Value::Array(a.iter().map(expand).collect()),
        _ => v.clone(),
    }
}
fn leaves(v: &Value, seen: &mut BTreeSet<String>) {
    match v {
        Value::String(s) if s.len() <= 64 => {
            seen.insert(s.clone());
        }
        Value::Array(a) => {
            for v in a {
                leaves(v, seen)
            }
        }
        Value::Object(o) => {
            for v in o.values() {
                leaves(v, seen)
            }
        }
        _ => {}
    }
}
fn normalize(v: &mut Value, known: &BTreeSet<String>, ids: &mut BTreeMap<String, String>) {
    match v {
        Value::String(s) if !known.contains(s) => {
            if uuid::Uuid::parse_str(s)
                .is_ok_and(|u| u.get_version_num() == 4 && u.to_string() == *s)
            {
                let next = ids.len() + 1;
                *s = ids
                    .entry(s.clone())
                    .or_insert_with(|| format!("@NEW_ID_{next}"))
                    .clone();
            } else if s.len() == 20
                && s.ends_with('Z')
                && s.as_str() >= "2020"
                && chrono::DateTime::parse_from_rfc3339(s).is_ok()
            {
                *s = "@NOW".into();
            }
        }
        Value::Array(a) => {
            for v in a {
                normalize(v, known, ids)
            }
        }
        Value::Object(o) => {
            for v in o.values_mut() {
                normalize(v, known, ids)
            }
        }
        _ => {}
    }
}
fn rows(rows: Value, compact: bool) -> Value {
    if !compact {
        return rows;
    }
    let mut statuses = BTreeMap::new();
    let mut ids = Vec::new();
    for r in rows.as_array().unwrap() {
        *statuses
            .entry(r["status"].as_str().unwrap_or("task"))
            .or_insert(0usize) += 1;
        ids.push(r["id"].clone());
    }
    json!({"count":ids.len(),"ids":ids,"statuses":statuses})
}
fn read_json(p: PathBuf) -> Value {
    serde_json::from_slice(&fs::read(p).unwrap()).unwrap()
}
fn names(p: &Path) -> Vec<String> {
    let mut found = fs::read_dir(p)
        .unwrap()
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .collect::<Vec<_>>();
    found.sort();
    found
}
fn run(spec: &Value) -> Result<Value, String> {
    let area = Area::new();
    for name in ["logs", "filters"] {
        let path = area.0.join(name);
        fs::create_dir(&path).unwrap();
        for f in spec[name].as_array().into_iter().flatten() {
            let leaf = f.as_str().unwrap();
            assert!(!leaf.contains(['\\', '/']));
            fs::write(path.join(leaf), b"owned fixture").unwrap();
        }
    }
    for name in ["jobs", "tasks"] {
        if let Some(seed) = spec.get(name) {
            fs::write(
                area.0.join(format!("{name}.json")),
                serde_json::to_vec(seed).unwrap(),
            )
            .unwrap();
        }
    }
    let engine = Engine::new(area.0.clone(), area.0.join("missing-tools"))?;
    let mut outputs = Vec::new();
    for call in spec["calls"].as_array().into_iter().flatten() {
        let method = call["method"].as_str().unwrap();
        assert!(matches!(
            method,
            "saveTask" | "importTasks" | "exportTasks" | "listTasks" | "listJobs" | "deleteTask"
        ));
        let args = if call["useExport"] == true {
            vec![engine.invoke("exportTasks", vec![])?]
        } else {
            call["args"].as_array().cloned().unwrap_or_default()
        };
        let response = match engine.invoke(method, args) {
            Ok(v) => json!({"result":v}),
            Err(e) => json!({"error":e}),
        };
        outputs.push(response);
    }
    let compact = spec["compact"] == true;
    let jobs = rows(engine.invoke("listJobs", vec![])?, compact);
    let tasks = rows(engine.invoke("listTasks", vec![])?, compact);
    engine.invoke("_shutdown", vec![])?;
    let disk_jobs = rows(read_json(area.0.join("jobs.json")), compact);
    let disk_tasks = rows(read_json(area.0.join("tasks.json")), compact);
    let mut actual = json!({"calls":outputs,"jobs":jobs,"tasks":tasks,"diskJobs":disk_jobs,"diskTasks":disk_tasks,
        "remainingLogs":names(&area.0.join("logs")),"remainingFilters":names(&area.0.join("filters"))});
    let mut known = BTreeSet::new();
    leaves(spec, &mut known);
    normalize(&mut actual, &known, &mut BTreeMap::new());
    // 0.11.0 saves tasks.values, which has no defined ordering on disk.
    if compact {
        actual["diskTasks"]["ids"]
            .as_array_mut()
            .unwrap()
            .sort_by(|a, b| a.as_str().cmp(&b.as_str()));
    } else {
        actual["diskTasks"]
            .as_array_mut()
            .unwrap()
            .sort_by(|a, b| a["id"].as_str().cmp(&b["id"].as_str()));
    }
    Ok(actual)
}
// Compare exactly in the integers' domain. Casting a large JSON integer to f64 could lose bits.
fn exact_integer(v: &Value) -> Option<i128> {
    let number = v.as_number()?;
    if let Some(i) = number.as_i64() {
        return Some(i128::from(i));
    }
    if let Some(u) = number.as_u64() {
        return Some(i128::from(u));
    }
    let f = number.as_f64()?;
    if f.fract() == 0.0 && (-9_223_372_036_854_775_808.0..18_446_744_073_709_551_616.0).contains(&f)
    {
        Some(f as i128)
    } else {
        None
    }
}
#[test]
fn numeric_representation_comparison_preserves_large_integer_bits() {
    for (a, b, same) in [
        (json!(0), json!(-0.0), true),
        (json!(100.0), json!(100), true),
        (json!(9007199254740993u64), json!(9007199254740992.0), false),
        (json!(9007199254740994u64), json!(9007199254740994.0), true),
        (json!(u64::MAX), json!(18446744073709551616.0), false),
        (json!(i64::MIN), json!(-9223372036854775808.0), true),
        (json!(3), json!(3.0000000000000004), false),
    ] {
        assert_eq!(
            first_difference(&json!({"a":[a]}), &json!({"a":[b]}), "").is_none(),
            same
        );
    }
}
fn first_difference(a: &Value, b: &Value, path: &str) -> Option<String> {
    if a == b || exact_integer(a).is_some_and(|i| Some(i) == exact_integer(b)) {
        return None;
    }
    if let (Some(x), Some(y)) = (a.as_object(), b.as_object()) {
        for key in x.keys().chain(y.keys()) {
            let at = format!("{path}/{key}");
            match (x.get(key), y.get(key)) {
                (Some(left), Some(right)) => {
                    if let Some(d) = first_difference(left, right, &at) {
                        return Some(d);
                    }
                }
                _ => {
                    return Some(format!(
                        "{at} field present Rust={} Swift={}",
                        x.contains_key(key),
                        y.contains_key(key)
                    ));
                }
            }
        }
        return None;
    }
    if let (Some(x), Some(y)) = (a.as_array(), b.as_array()) {
        if x.len() != y.len() {
            return Some(format!(
                "{path} Rust count {} Swift count {}",
                x.len(),
                y.len()
            ));
        }
        for (i, (left, right)) in x.iter().zip(y).enumerate() {
            if let Some(d) = first_difference(left, right, &format!("{path}/{i}")) {
                return Some(d);
            }
        }
        return None;
    }
    Some(format!(
        "{path} Rust={} Swift={}",
        a.to_string().chars().take(160).collect::<String>(),
        b.to_string().chars().take(160).collect::<String>()
    ))
}
#[test]
fn legacy_tasks_and_job_history_match_swift_public_api_and_disk() {
    let data: Value =
        serde_json::from_str(include_str!("fixtures/persistence-0.11.0.json")).unwrap();
    let mut differences = Vec::new();
    for row in data["cases"].as_array().unwrap() {
        let mut spec = row.clone();
        let expected = spec.as_object_mut().unwrap().remove("expected").unwrap();
        let actual = run(&expand(&spec));
        match actual {
            Err(error) => differences.push(format!("{}: {error}", row["name"])),
            Ok(v) => {
                for key in expected.as_object().unwrap().keys() {
                    if let Some(d) = first_difference(&v[key], &expected[key], key) {
                        differences.push(format!("{} {d}", row["name"]));
                    }
                }
            }
        }
    }
    assert!(differences.is_empty(), "{}", differences.join("\n"));
}

#[test]
fn legacy_long_decimal_durations_round_to_nearest_before_finished_rate() {
    // All three decimal strings were written by released 0.11.0 during real
    // synthetic transfers. The bit constants are checked against exact rationals.
    for (literal, bytes, elapsed_bits, speed_bits) in [
        ("0.048371500000939704", 0, 0x3fa8_c426_3520_0000, 0),
        (
            "0.00069679099999999999",
            4,
            0x3f46_d51b_4750_98ec,
            0x40b6_6c9a_2eb6_97e9,
        ),
        (
            "0.0014045419999999999",
            5,
            0x3f57_0313_7d2c_c8d8,
            0x40ab_cfc2_3460_6b2b,
        ),
    ] {
        let raw: Value =
            serde_json::from_str(&format!(r#"{{"elapsedTime":{literal},"bytes":{bytes}}}"#))
                .unwrap();
        let saved = json!({"id":uid(7), "command":"rclone", "createdAt":"2000-01-01T00:00:00Z",
            "status":"failed","request":{"source":{"remote":"a","path":"src"},"destination":{"remote":"b","path":"dst"},
            "selection":[],"mode":"copy","dryRun":false,"options":{}},"stats":raw});
        let job = rbn_core::history::job(&saved).unwrap();
        assert_eq!(
            job["stats"]["elapsedTime"].as_f64().unwrap().to_bits(),
            elapsed_bits,
            "{literal}"
        );
        assert_eq!(
            job["stats"]["speed"].as_f64().unwrap().to_bits(),
            speed_bits,
            "{literal}"
        );
    }
}

fn encoding_cases() -> Value {
    serde_json::from_str(include_str!("fixtures/storage-encoding-0.11.0.json")).unwrap()
}

fn fixture_bytes(row: &Value) -> Vec<u8> {
    let hex = row["bytesHex"].as_str().unwrap();
    (0..hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).unwrap())
        .collect()
}

#[test]
fn swift_recognized_document_encodings_and_complete_prefixes_decode_identically() {
    for row in encoding_cases()["cases"].as_array().unwrap() {
        if row["accepted"] == true {
            assert_eq!(
                rbn_core::storage::decode_json_bytes(&fixture_bytes(row)).unwrap(),
                row["decoded"],
                "{}",
                row["name"]
            );
        }
    }
}

#[test]
fn swift_rejected_malformed_bytes_preserve_the_original_backup() {
    let area = Area::new();
    for row in encoding_cases()["cases"].as_array().unwrap() {
        if row["accepted"] == false && row["name"] != "utf-32-le-bom" {
            let file = area.0.join(row["name"].as_str().unwrap());
            fs::create_dir(&file).unwrap();
            let source = file.join("state.json");
            let bytes = fixture_bytes(row);
            fs::write(&source, &bytes).unwrap();
            assert!(
                rbn_core::storage::decode_json_bytes(&bytes).is_err(),
                "{}",
                row["name"]
            );
            assert_eq!(
                rbn_core::storage::read_json(&source, json!({"fallback":true})).unwrap(),
                json!({"fallback":true}),
                "{}",
                row["name"]
            );
            let backup = fs::read_dir(&file).unwrap().next().unwrap().unwrap();
            assert!(
                backup
                    .file_name()
                    .to_string_lossy()
                    .starts_with("state.json.unreadable-")
            );
            assert_eq!(fs::read(backup.path()).unwrap(), bytes);
        }
    }
}

#[test]
fn valid_utf32le_bom_is_retained_despite_legacy_foundation_misclassification() {
    let cases = encoding_cases();
    let row = cases["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|v| v["name"] == "utf-32-le-bom")
        .unwrap();
    assert_eq!(row["accepted"], false);
    let area = Area::new();
    let path = area.0.join("tasks.json");
    let bytes = fixture_bytes(row);
    fs::write(&path, &bytes).unwrap();
    assert_eq!(
        rbn_core::storage::read_json(&path, json!([])).unwrap(),
        json!([{"檔名":"A🌱e\u{301}"}])
    );
    assert_eq!(fs::read(path).unwrap(), bytes);
}

fn encoded_state(value: &Value, encoding: &str, bom: bool) -> Vec<u8> {
    let text = serde_json::to_string(value).unwrap();
    let (mark, mut bytes): (&[u8], Vec<u8>) = match encoding {
        "utf-8" => (&[0xef, 0xbb, 0xbf], text.into_bytes()),
        "utf-16-le" => (
            &[0xff, 0xfe],
            text.encode_utf16().flat_map(u16::to_le_bytes).collect(),
        ),
        "utf-16-be" => (
            &[0xfe, 0xff],
            text.encode_utf16().flat_map(u16::to_be_bytes).collect(),
        ),
        "utf-32-le" => (
            &[0xff, 0xfe, 0, 0],
            text.chars()
                .flat_map(|c| (c as u32).to_le_bytes())
                .collect(),
        ),
        "utf-32-be" => (
            &[0, 0, 0xfe, 0xff],
            text.chars()
                .flat_map(|c| (c as u32).to_be_bytes())
                .collect(),
        ),
        other => panic!("unknown fixture encoding {other}"),
    };
    if bom {
        bytes.splice(0..0, mark.iter().copied());
    }
    bytes
}

#[test]
fn legacy_multiencoding_settings_tasks_and_jobs_survive_actual_engine_open_and_restart() {
    let req = json!({"source":{"remote":"source","path":"a"},"destination":{"remote":"target","path":"b"},
        "mode":"copy","dryRun":true,"selection":[],"options":{}});
    let date = "2000-01-01T00:00:00Z";
    let task =
        json!({"id":uid(7),"name":"舊作業 🌱","createdAt":date,"updatedAt":date,"request":req});
    let job = json!({"id":uid(8),"command":"rclone copy","createdAt":date,"status":"failed","request":req});
    for seed in encoding_cases()["oldStates"].as_array().unwrap() {
        let area = Area::new();
        let encoding = seed["encoding"].as_str().unwrap();
        let bom = seed["bom"].as_bool().unwrap();
        for (name, value) in [
            (
                "settings",
                json!({"settingsSchemaVersion":7,"language":"ja","theme":"green-dark"}),
            ),
            ("tasks", json!([task])),
            ("jobs", json!([job])),
        ] {
            fs::write(
                area.0.join(format!("{name}.json")),
                encoded_state(&value, encoding, bom),
            )
            .unwrap();
        }
        for _ in 0..2 {
            let engine = Engine::new(area.0.clone(), area.0.join("rclone")).unwrap();
            let state = engine.invoke("_preferences", vec![]).unwrap();
            let tasks = engine.invoke("listTasks", vec![]).unwrap();
            let jobs = engine.invoke("listJobs", vec![]).unwrap();
            assert_eq!(state["settings"]["language"], "ja");
            assert_eq!(state["settings"]["theme"], "green-dark");
            assert_eq!(tasks[0]["id"], uid(7));
            assert_eq!(tasks[0]["name"], "舊作業 🌱");
            assert_eq!(jobs[0]["id"], uid(8));
            assert_eq!(jobs[0]["status"], "failed");
            assert_eq!(
                engine.invoke("_state", vec![]).unwrap()["activeJobs"],
                false
            );
            engine.invoke("_shutdown", vec![]).unwrap();
        }
        for entry in fs::read_dir(&area.0).unwrap() {
            assert!(
                !entry
                    .unwrap()
                    .file_name()
                    .to_string_lossy()
                    .contains(".unreadable-"),
                "{encoding} bom={bom}"
            );
        }
    }
}
