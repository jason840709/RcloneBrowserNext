//! Service parity tests. Real-rclone cases are explicitly ignored by default;
//! run them with RBN_TEST_RCLONE pointing to the pinned test-only executable.
use rbn_core::{
    accounts::{self, Accounts},
    models::Endpoint,
    process::{self, Context},
    tools::Tools,
    updater::{self, DownloadError, Fetcher, Reply, Updater},
};
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    fs,
    io::Write,
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{Arc, Mutex},
    thread,
    time::{Duration, Instant},
};
use uuid::Uuid;
struct Fixture {
    root: PathBuf,
    context: Context,
    config: PathBuf,
}
impl Fixture {
    fn new(real: bool) -> Self {
        let base = std::env::var_os("RBN_TEST_ROOT")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../.tmp/services-tests")
            });
        let root = base.join(Uuid::new_v4().to_string());
        rbn_core::storage::private_directory(&root).unwrap();
        let config = root.join("rclone.conf");
        fs::write(&config, b"").unwrap();
        let binary = if real {
            PathBuf::from(
                std::env::var_os("RBN_TEST_RCLONE")
                    .expect("set RBN_TEST_RCLONE for real-rclone tests"),
            )
        } else {
            root.join("fixture-rclone")
        };
        let mut environment: BTreeMap<String, String> = std::env::vars()
            .filter(|(k, _)| !k.to_uppercase().starts_with("RCLONE_"))
            .collect();
        environment.insert("TMPDIR".into(), root.to_string_lossy().into_owned());
        let context = Context {
            binary,
            arguments: if real {
                vec![format!("--config={}", config.display())]
            } else {
                vec![]
            },
            environment,
            work_dir: root.clone(),
        };
        Self {
            root,
            context,
            config,
        }
    }
    fn fixture_context(&self, mode: &str) -> Context {
        let mut context = self.context.clone();
        context.binary = PathBuf::from(env!("CARGO_BIN_EXE_rbn-service-fixture"));
        context.arguments.clear();
        context
            .environment
            .insert("RBN_SERVICE_FIXTURE".into(), mode.into());
        context.environment.insert(
            "RBN_TEST_CONFIG".into(),
            self.config.to_string_lossy().into_owned(),
        );
        context
    }
    fn accounts(&self) -> Arc<Accounts> {
        Accounts::new(self.root.join("state")).unwrap()
    }
    fn alias_config(&self) -> Vec<u8> {
        let target = self.root.join("target");
        fs::create_dir_all(&target).unwrap();
        let original =
            format!("[existing]\ntype = alias\nremote = {}\n", target.display()).into_bytes();
        fs::write(&self.config, &original).unwrap();
        original
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}
fn call(a: &Arc<Accounts>, c: &Context, r: Value) -> Value {
    a.handle(&r, c).unwrap()
}
fn wait(a: &Arc<Accounts>, c: &Context, mut value: Value) -> Value {
    let deadline = Instant::now() + Duration::from_secs(30);
    while value["phase"] == "running" && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(20));
        value = call(a, c, json!({"action":"poll","id":value["id"]}));
    }
    assert_ne!(value["phase"], "running", "account worker timed out");
    value
}
fn begin(a: &Arc<Accounts>, c: &Context, name: &str, mode: &str, provider: &str) -> Value {
    wait(
        a,
        c,
        call(
            a,
            c,
            json!({"action":"start","name":name,"mode":mode,"provider":provider}),
        ),
    )
}
fn batch(
    a: &Arc<Accounts>,
    c: &Context,
    name: &str,
    provider: &str,
    fields: Value,
    mode: &str,
    autosave: bool,
) -> Value {
    wait(
        a,
        c,
        call(
            a,
            c,
            json!({"action":"start","name":name,"provider":provider,"mode":mode,"setup":"detailed","fields":fields,"autoSave":autosave,"useSharedClient":true}),
        ),
    )
}
fn answer(a: &Arc<Accounts>, c: &Context, q: &Value, value: Option<&str>) -> Value {
    wait(
        a,
        c,
        call(
            a,
            c,
            json!({"action":"answer","id":q["id"],"step":q["step"],"useDefault":value.is_none(),"value":value.unwrap_or_default()}),
        ),
    )
}
fn cancel(a: &Arc<Accounts>, c: &Context, q: &Value) {
    let stopped = wait(a, c, call(a, c, json!({"action":"cancel","id":q["id"]})));
    assert_eq!(stopped["phase"], "cancelled");
}
fn finish_alias(a: &Arc<Accounts>, c: &Context, q: &Value, path: Option<&str>) -> Value {
    let first = answer(a, c, q, path);
    answer(a, c, &first, Some("false"))
}
fn check_no_staging(root: &Path) {
    assert!(
        fs::read_dir(root)
            .unwrap()
            .flatten()
            .all(|e| !e.file_name().to_string_lossy().starts_with(".rbn-account-"))
    );
}

#[test]
#[ignore = "requires pinned RBN_TEST_RCLONE"]
fn real_account_schema_transaction_test_save_edit_delete_conflict_and_unicode() {
    let f = Fixture::new(true);
    let original = f.alias_config();
    let a = f.accounts();
    let c = &f.context;
    let info = call(&a, c, json!({"action":"info"}));
    assert_eq!(info["requiresUnlock"], false);
    assert_eq!(
        fs::canonicalize(info["configPath"].as_str().unwrap()).unwrap(),
        fs::canonicalize(&f.config).unwrap()
    );
    let drive = info["providers"]
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["name"] == "drive")
        .unwrap();
    assert_eq!(drive["quickSetup"], true);
    assert!(
        drive["options"]
            .as_array()
            .unwrap()
            .iter()
            .all(|o| o.get("Value").is_none()
                && o.get("ValueStr").is_none()
                && (!accounts::secret(o)
                    || (accounts::string(&o["Default"]).is_empty()
                        && accounts::string(&o["DefaultStr"]).is_empty())))
    );
    let q = begin(&a, c, "new-alias", "create", "alias");
    assert_eq!(q["question"]["Name"], "remote");
    assert!(
        a.handle(
            &json!({"action":"answer","id":q["id"],"step":q["step"],"value":""}),
            c
        )
        .is_err()
    );
    assert!(
        a.handle(
            &json!({"action":"answer","id":q["id"],"step":-1,"value":"x"}),
            c
        )
        .is_err()
    );
    assert!(
        a.handle(
            &json!({"action":"start","name":"other","provider":"alias"}),
            c
        )
        .is_err()
    );
    let ready = finish_alias(&a, c, &q, Some(f.root.join("target").to_str().unwrap()));
    assert_eq!(ready["phase"], "ready");
    assert_eq!(fs::read(&f.config).unwrap(), original);
    let tested = wait(&a, c, call(&a, c, json!({"action":"test","id":q["id"]})));
    assert_eq!(tested["tested"], true);
    call(&a, c, json!({"action":"commit","id":q["id"]}));
    assert!(!a.has_active());
    assert!(
        fs::read_to_string(&f.config)
            .unwrap()
            .contains("[new-alias]")
    );
    check_no_staging(&f.root);
    let before = fs::read(&f.config).unwrap();
    let q = begin(&a, c, "cancel-me", "create", "alias");
    finish_alias(&a, c, &q, Some(f.root.join("target").to_str().unwrap()));
    cancel(&a, c, &q);
    call(&a, c, json!({"action":"cancel","id":q["id"]}));
    assert_eq!(fs::read(&f.config).unwrap(), before);
    check_no_staging(&f.root);
    let q = begin(&a, c, "existing", "edit", "");
    assert_eq!(
        q["question"]["Default"],
        f.root.join("target").to_string_lossy().as_ref()
    );
    let ready = finish_alias(&a, c, &q, None);
    assert_eq!(ready["phase"], "ready");
    call(&a, c, json!({"action":"commit","id":q["id"]}));
    assert!(
        fs::read_to_string(&f.config)
            .unwrap()
            .contains("[new-alias]")
    );
    let q = begin(&a, c, "conflict", "create", "alias");
    finish_alias(&a, c, &q, Some(f.root.join("target").to_str().unwrap()));
    let external = fs::read_to_string(&f.config).unwrap() + "\n# external edit\n";
    fs::write(&f.config, &external).unwrap();
    assert!(
        a.handle(&json!({"action":"commit","id":q["id"]}), c)
            .is_err()
    );
    assert_eq!(fs::read_to_string(&f.config).unwrap(), external);
    cancel(&a, c, &q);
    let before = fs::read(&f.config).unwrap();
    let q = begin(&a, c, "new-alias", "delete", "");
    assert_eq!(q["phase"], "ready");
    assert_eq!(fs::read(&f.config).unwrap(), before);
    call(&a, c, json!({"action":"commit","id":q["id"]}));
    let text = fs::read_to_string(&f.config).unwrap();
    assert!(!text.contains("[new-alias]") && text.contains("[existing]"));
    let missing = f.root.join("new.conf");
    let mut nc = c.clone();
    nc.arguments = vec![format!("--config={}", missing.display())];
    let q = begin(&a, &nc, "測試-日本語", "create", "alias");
    finish_alias(&a, &nc, &q, Some(f.root.join("target").to_str().unwrap()));
    assert!(!missing.exists());
    call(&a, &nc, json!({"action":"commit","id":q["id"]}));
    assert!(
        fs::read_to_string(missing)
            .unwrap()
            .contains("[測試-日本語]")
    );
    a.cancel_all().unwrap();
}
#[test]
#[ignore = "requires pinned RBN_TEST_RCLONE"]
fn real_account_forms_validate_types_apply_advanced_defaults_and_conflict_check_autosave() {
    let f = Fixture::new(true);
    let original = f.alias_config();
    let a = f.accounts();
    let c = &f.context;
    let target = f.root.join("target");
    let ready = batch(
        &a,
        c,
        "form-alias",
        "alias",
        json!({"remote":target,"description":"Form description"}),
        "create",
        false,
    );
    assert_eq!(ready["phase"], "ready", "{}", ready["error"]);
    assert_eq!(fs::read(&f.config).unwrap(), original);
    call(&a, c, json!({"action":"commit","id":ready["id"]}));
    assert!(
        fs::read_to_string(&f.config)
            .unwrap()
            .contains("Form description")
    );
    let q = batch(
        &a,
        c,
        "auto-alias",
        "alias",
        json!({"remote":target}),
        "create",
        true,
    );
    assert_eq!(q["phase"], "committed", "{}", q["error"]);
    assert_eq!(q["authorizationStarted"], false);
    let before = fs::read(&f.config).unwrap();
    let edit = batch(
        &a,
        c,
        "auto-alias",
        "alias",
        json!({"description":"Changed later"}),
        "edit",
        true,
    );
    assert_eq!(edit["phase"], "ready", "{}", edit["error"]);
    assert_eq!(edit["autoSave"], false);
    assert_eq!(fs::read(&f.config).unwrap(), before);
    call(&a, c, json!({"action":"commit","id":edit["id"]}));
    let saved = fs::read_to_string(&f.config).unwrap();
    assert!(saved.contains("Changed later") && saved.contains(target.to_str().unwrap()));
    let before = fs::read(&f.config).unwrap();
    for (name, provider, fields) in [
        (
            "unknown",
            "alias",
            json!({"remote":target,"not_a_provider_option":"value"}),
        ),
        (
            "bad-port",
            "sftp",
            json!({"host":"127.0.0.1","port":"not-an-integer"}),
        ),
        (
            "bad-bool",
            "sftp",
            json!({"host":"127.0.0.1","set_modtime":"not-a-boolean"}),
        ),
        (
            "bad-password",
            "webdav",
            json!({"url":"http://127.0.0.1:9","pass":"first\nsecond"}),
        ),
    ] {
        let q = batch(&a, c, name, provider, fields, "create", false);
        assert_eq!(q["phase"], "error");
        cancel(&a, c, &q);
        assert_eq!(fs::read(&f.config).unwrap(), before);
    }
    let q = batch(&a, c, "auto-conflict", "alias", json!({}), "create", true);
    assert_eq!(q["phase"], "question");
    assert_eq!(q["needsInputReason"], "additional-input");
    let external = String::from_utf8(before).unwrap() + "\n# concurrent form edit\n";
    fs::write(&f.config, &external).unwrap();
    let failed = answer(&a, c, &q, Some(target.to_str().unwrap()));
    assert_eq!(failed["phase"], "error");
    assert_eq!(fs::read_to_string(&f.config).unwrap(), external);
    cancel(&a, c, &failed);
    check_no_staging(&f.root);
}
#[test]
#[ignore = "requires pinned RBN_TEST_RCLONE"]
fn real_oauth_profiles_reach_native_url_cancel_without_exposing_state_or_credentials() {
    let f = Fixture::new(true);
    let original = f.alias_config();
    let a = f.accounts();
    let c = &f.context;
    for (name, provider, fields, shared) in [
        ("quick-drive", "drive", json!({}), true),
        ("quick-onedrive", "onedrive", json!({}), true),
        ("quick-dropbox", "dropbox", json!({}), true),
        (
            "custom-google",
            "drive",
            json!({"client_id":"synthetic-client-id.apps.googleusercontent.com","client_secret":"synthetic-oauth-secret-not-real"}),
            false,
        ),
    ] {
        let mut q = call(
            &a,
            c,
            json!({"action":"start","name":name,"provider":provider,"setup":"quick","fields":fields,"useSharedClient":shared,"autoSave":true}),
        );
        let deadline = Instant::now() + Duration::from_secs(30);
        while q["phase"] == "running" && q["canOpenBrowser"] != true && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(20));
            q = call(&a, c, json!({"action":"poll","id":q["id"]}));
        }
        assert_eq!(q["phase"], "running", "{}", q);
        assert_eq!(q["canOpenBrowser"], true, "{}", q);
        let url = a.authorization_url().unwrap();
        assert!(accounts::allowed_authorization(&url));
        let public = q.to_string();
        assert!(
            !public.contains(&url)
                && !public.contains("synthetic-client-id")
                && !public.contains("synthetic-oauth-secret")
        );
        assert_eq!(fs::read(&f.config).unwrap(), original);
        cancel(&a, c, &q);
        assert!(a.authorization_url().is_err());
    }
    let q = wait(
        &a,
        c,
        call(
            &a,
            c,
            json!({"action":"start","name":"missing-client","provider":"drive","setup":"quick","fields":{},"useSharedClient":false}),
        ),
    );
    assert_eq!(q["phase"], "question");
    assert_eq!(q["question"]["Name"], "client_id");
    assert_eq!(q["question"]["Required"], true);
    cancel(&a, c, &q);
    check_no_staging(&f.root);
}
struct Server(Child);
impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
#[test]
#[ignore = "requires pinned RBN_TEST_RCLONE"]
fn real_webdav_password_is_obscured_authenticates_and_is_not_encoded_twice() {
    let f = Fixture::new(true);
    f.alias_config();
    let a = f.accounts();
    let c = &f.context;
    let log = f.root.join("webdav-fixture.log");
    let password = "synthetic-webdav-password-秘密";
    let server = Command::new(&c.binary)
        .args(&c.arguments)
        .args([
            "serve",
            "webdav",
            f.root.join("target").to_str().unwrap(),
            "--addr",
            "127.0.0.1:0",
            "--read-only",
            "--log-level",
            "INFO",
            "--log-file",
            log.to_str().unwrap(),
        ])
        .env_clear()
        .envs(&c.environment)
        .env("RCLONE_USER", "fixture")
        .env("RCLONE_PASS", password)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let _server = Server(server);
    let expression = regex::Regex::new(r"http://127\.0\.0\.1:[0-9]+/").unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    let url = loop {
        if let Ok(s) = fs::read_to_string(&log) {
            if let Some(m) = expression.find(&s) {
                break m.as_str().to_owned();
            }
        }
        assert!(Instant::now() < deadline, "WebDAV fixture did not bind");
        thread::sleep(Duration::from_millis(25));
    };
    let q = batch(
        &a,
        c,
        "password-form",
        "webdav",
        json!({"url":url,"vendor":"other","user":"fixture","pass":password}),
        "create",
        false,
    );
    assert_eq!(q["phase"], "ready", "{}", q["error"]);
    assert!(!q.to_string().contains(password));
    let tested = wait(&a, c, call(&a, c, json!({"action":"test","id":q["id"]})));
    assert_eq!(tested["tested"], true, "{}", tested["error"]);
    call(&a, c, json!({"action":"commit","id":q["id"]}));
    let saved = fs::read_to_string(&f.config).unwrap();
    assert!(!saved.contains(password));
    let dump = process::capture(
        c,
        &["config".into(), "dump".into()],
        1024 * 1024,
        Duration::from_secs(10),
        None,
    )
    .unwrap()
    .json()
    .unwrap();
    let encoded = dump["password-form"]["pass"].as_str().unwrap().to_owned();
    assert!(!encoded.is_empty() && encoded != password);
    let q = batch(
        &a,
        c,
        "password-form",
        "webdav",
        json!({"description":"Keep password"}),
        "edit",
        false,
    );
    assert_eq!(q["phase"], "ready", "{}", q["error"]);
    assert!(!q.to_string().contains(&encoded));
    let tested = wait(&a, c, call(&a, c, json!({"action":"test","id":q["id"]})));
    assert_eq!(tested["tested"], true, "{}", tested["error"]);
    call(&a, c, json!({"action":"commit","id":q["id"]}));
    assert!(fs::read_to_string(&f.config).unwrap().contains(&encoded));
    check_no_staging(&f.root);
}
#[test]
#[ignore = "requires pinned RBN_TEST_RCLONE"]
fn real_encrypted_config_reports_lock_and_preserves_encryption_after_save() {
    let f = Fixture::new(true);
    f.alias_config();
    let a = f.accounts();
    let c = &f.context;
    let password = "synthetic-config-key-not-real";
    process::capture_input(
        c,
        &["config".into(), "encryption".into(), "set".into()],
        format!("{password}\n{password}\n").as_bytes(),
        1024 * 1024,
        Duration::from_secs(10),
        None,
    )
    .unwrap()
    .checked()
    .unwrap();
    let locked = call(&a, c, json!({"action":"info"}));
    assert_eq!(locked["requiresUnlock"], true);
    let mut unlocked = c.clone();
    unlocked
        .environment
        .insert("RCLONE_CONFIG_PASS".into(), password.into());
    assert_eq!(
        call(&a, &unlocked, json!({"action":"info"}))["requiresUnlock"],
        false
    );
    let q = batch(
        &a,
        &unlocked,
        "encrypted-new",
        "alias",
        json!({"remote":f.root.join("target")}),
        "create",
        true,
    );
    assert_eq!(q["phase"], "committed", "{}", q["error"]);
    let text = fs::read_to_string(&f.config).unwrap();
    assert!(text.contains("RCLONE_ENCRYPT_V0:") && !text.contains("[encrypted-new]"));
    assert!(
        call(&a, &unlocked, json!({"action":"info"}))["remotes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|r| r["name"] == "encrypted-new")
    );
}
#[test]
#[ignore = "requires pinned RBN_TEST_RCLONE"]
fn real_tree_and_exports_preserve_filenames_csv_and_exclude_own_staging() {
    let f = Fixture::new(true);
    let source = f.root.join("source");
    fs::create_dir_all(source.join("level1/level2/level3")).unwrap();
    for name in [
        "alpha.txt",
        "name,\"中文\".txt",
        if cfg!(windows) {
            "line␊break.txt"
        } else {
            "line\nbreak.txt"
        },
    ] {
        fs::write(source.join(name), b"data").unwrap();
    }
    let e = Endpoint {
        remote: None,
        path: source.to_string_lossy().into_owned(),
    };
    let tree = Tools::tree(&f.context, &e, 2).unwrap();
    let text = tree["text"].as_str().unwrap();
    assert!(
        text.contains("level1")
            && text.contains("level2")
            && !text.contains("level3")
            && !text.contains("alpha.txt")
    );
    assert_eq!(tree["truncated"], false);
    let output = f.root.join("list.csv");
    let result = Tools::export(&f.context, &e, &output, false).unwrap();
    let text = fs::read_to_string(output).unwrap();
    assert_eq!(result["count"], 3);
    assert!(
        regex::Regex::new(r",[0-9]+,[0-9]{4}-[0-9]{2}-[0-9]{2}")
            .unwrap()
            .is_match(&text),
        "CSV omitted size/date"
    );
    assert!(
        text.starts_with("Path,Size,Modified\n")
            && text.contains("\"name,\"\"中文\"\".txt\"")
            && text.contains("line␊break.txt")
    );
    let plain = f.root.join("plain");
    fs::create_dir(&plain).unwrap();
    fs::write(plain.join("quoted ' file.txt"), b"one").unwrap();
    let e = Endpoint {
        remote: None,
        path: plain.to_string_lossy().into_owned(),
    };
    let destination = plain.join("files.txt");
    let r = Tools::export(&f.context, &e, &destination, true).unwrap();
    assert_eq!(r["count"], 1);
    assert_eq!(
        fs::read_to_string(destination).unwrap(),
        "quoted ' file.txt\n"
    );
    assert!(
        fs::read_dir(plain)
            .unwrap()
            .flatten()
            .all(|e| !e.file_name().to_string_lossy().starts_with(".rbn-export-"))
    );
}
#[test]
fn tool_fixtures_cover_large_tree_public_links_and_transactional_export_failure() {
    let f = Fixture::new(false);
    let root = Endpoint {
        remote: None,
        path: f.root.to_string_lossy().into_owned(),
    };
    let remote = Endpoint {
        remote: Some("fixture".into()),
        path: "folder".into(),
    };
    let c = f.fixture_context("tree-large");
    let tree = Tools::tree(&c, &root, 4).unwrap();
    assert_eq!(tree["truncated"], true);
    assert_eq!(tree["text"].as_str().unwrap().len(), 1024 * 1024);
    assert!(Tools::tree(&c, &root, 0).is_err());
    for (mode, valid) in [
        ("link-valid", true),
        ("link-script", false),
        ("link-credentials", false),
        ("link-bad", false),
    ] {
        let c = f.fixture_context(mode);
        assert_eq!(
            Tools::public_link(&c, &remote, "picture.png", false).is_ok(),
            valid
        );
    }
    let link = Tools::public_link(
        &f.fixture_context("link-valid"),
        &remote,
        "picture.png",
        false,
    )
    .unwrap();
    let link = url::Url::parse(&link).unwrap();
    assert_eq!(link.scheme(), "https");
    assert_eq!(link.host_str(), Some("example.invalid"));
    assert!(Tools::public_link(&c, &root, "x", false).is_err());
    assert!(Tools::public_link(&c, &remote, "../escape", false).is_err());
    let report = f.root.join("protected.csv");
    fs::write(&report, b"previous report").unwrap();
    let c = f.fixture_context("failure");
    assert!(Tools::export(&c, &root, &report, false).is_err());
    assert_eq!(fs::read(&report).unwrap(), b"previous report");
    assert!(
        fs::read_dir(&f.root)
            .unwrap()
            .flatten()
            .all(|e| !e.file_name().to_string_lossy().starts_with(".rbn-export-"))
    );
    {
        let link = f.root.join("symlink.csv");
        #[cfg(unix)]
        std::os::unix::fs::symlink(&report, &link).unwrap();
        #[cfg(windows)]
        std::os::windows::fs::symlink_file(&report, &link).unwrap();
        assert!(Tools::export(&c, &root, &link, false).is_err());
        assert_eq!(fs::read(&report).unwrap(), b"previous report");
    }
    let c = f.fixture_context("csv-multiline");
    let result = Tools::export(&c, &root, &f.root.join("multi.csv"), false).unwrap();
    assert_eq!(result["count"], 2);
}

fn finished(manager: &Arc<Tools>, c: &Context, id: &Value) -> Value {
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        let rows = manager
            .handle("listToolSessions", &[], c, &json!({}))
            .unwrap();
        let item = rows
            .as_array()
            .unwrap()
            .iter()
            .find(|v| &v["id"] == id)
            .unwrap();
        if item["status"] != "running" {
            return item.clone();
        }
        assert!(Instant::now() < deadline, "tool session never finished");
        thread::sleep(Duration::from_millis(20));
    }
}
#[test]
#[ignore = "requires pinned RBN_TEST_RCLONE"]
fn real_cat_stream_preserves_complete_media_and_does_not_forward_cloud_credentials() {
    let f = Fixture::new(true);
    let source = f.root.join("media");
    fs::create_dir(&source).unwrap();
    let bytes: Vec<_> = (0..1024 * 1024 + 17).map(|i| (i % 251) as u8).collect();
    fs::write(source.join("movie ' 中文.dat"), &bytes).unwrap();
    let captured = f.root.join("captured.bin");
    let player = PathBuf::from(env!("CARGO_BIN_EXE_rbn-service-fixture"));
    let mut c = f.context.clone();
    c.environment.insert(
        "RCLONE_CONFIG_PASS".into(),
        "test-only-do-not-forward".into(),
    );
    c.environment.insert(
        "AWS_SECRET_ACCESS_KEY".into(),
        "test-only-cloud-secret".into(),
    );
    c.environment.insert(
        "HTTPS_PROXY".into(),
        "https://fixture:secret@example.invalid".into(),
    );
    let manager = Tools::new(f.root.join("stream-work")).unwrap();
    let endpoint = Endpoint {
        remote: None,
        path: source.to_string_lossy().into_owned(),
    };
    let session = manager
        .start_stream(
            &c,
            &endpoint,
            "movie ' 中文.dat",
            &player,
            &[
                "--fixture-player".into(),
                captured.to_string_lossy().into_owned(),
            ],
        )
        .unwrap();
    let result = finished(&manager, &c, &session["id"]);
    assert_eq!(result["status"], "completed", "{}", result);
    assert_eq!(fs::read(&captured).unwrap(), bytes);
    assert_eq!(
        fs::read_to_string(captured.with_extension("bin.credential-check")).unwrap(),
        "clean"
    );
    assert!(!result.to_string().contains("test-only"));
    manager.shutdown().unwrap();
}
#[test]
fn stream_cancel_failures_shutdown_and_invalid_players_leave_no_running_session() {
    let f = Fixture::new(false);
    let c = f.fixture_context("stream");
    let remote = Endpoint {
        remote: Some("fixture".into()),
        path: "folder".into(),
    };
    let player = PathBuf::from(env!("CARGO_BIN_EXE_rbn-service-fixture"));
    let discard = vec!["--fixture-player-discard".into()];
    let manager = Tools::new(f.root.join("work")).unwrap();
    assert!(
        manager
            .start_stream(&c, &remote, "x", &f.root.join("missing"), &[])
            .is_err()
    );
    assert!(!manager.has_active());
    let session = manager
        .start_stream(&c, &remote, "large.bin", &player, &discard)
        .unwrap();
    thread::sleep(Duration::from_millis(100));
    let result = manager
        .stop_session(session["id"].as_str().unwrap())
        .unwrap();
    assert_eq!(result["status"], "stopped");
    assert!(!manager.has_active());
    let session = manager
        .start_stream(
            &c,
            &remote,
            "large.bin",
            &player,
            &["--fixture-player-fail".into()],
        )
        .unwrap();
    assert_eq!(finished(&manager, &c, &session["id"])["status"], "failed");
    assert!(!manager.has_active());
    let fail = f.fixture_context("stream-fail");
    let session = manager
        .start_stream(&fail, &remote, "large.bin", &player, &discard)
        .unwrap();
    assert_eq!(finished(&manager, &c, &session["id"])["status"], "failed");
    manager
        .start_stream(&c, &remote, "x", &player, &discard)
        .unwrap();
    manager.shutdown().unwrap();
    assert!(!manager.has_active());
    assert!(
        manager
            .start_stream(&c, &remote, "x", &player, &discard)
            .is_err()
    );
}

#[test]
#[ignore = "requires pinned RBN_TEST_RCLONE"]
fn real_updater_version_skip_manual_override_and_native_verification() {
    let f = Fixture::new(true);
    let probe = Updater::new(f.root.join("version")).unwrap();
    let actual = probe.version_of(&f.context.binary).unwrap();
    let current = updater::Release::parse(&actual).unwrap();
    let latest = format!("v{}.{}.{}", current.major, current.minor, current.patch + 1);
    let text = format!("rclone {latest}\n");
    let requests = Arc::new(Mutex::new(Vec::<String>::new()));
    let recorded = requests.clone();
    let fetcher: Fetcher = Arc::new(move |url, max, _| {
        recorded.lock().unwrap().push(url.to_owned());
        assert_eq!(url, "https://downloads.rclone.org/version.txt");
        assert_eq!(max, 1024);
        Ok(Reply {
            data: text.as_bytes().to_vec(),
            status: 200,
            url: url.into(),
            declared_size: None,
        })
    });
    let up = Updater::with_fetcher(f.root.join("updates"), fetcher).unwrap();
    assert_eq!(
        up.check(Some(&f.context.binary), &latest, false, &json!({}))
            .unwrap()["status"],
        "skipped"
    );
    assert_eq!(
        up.check(Some(&f.context.binary), &latest, true, &json!({}))
            .unwrap()["status"],
        "available"
    );
    assert_eq!(
        up.check(
            Some(&f.context.binary),
            &current.version(),
            false,
            &json!({})
        )
        .unwrap()["status"],
        "available"
    );
    assert_eq!(
        up.check(None, "", false, &json!({})).unwrap()["status"],
        "notInstalled"
    );
    let requests = requests.lock().unwrap();
    assert_eq!(requests.len(), 4);
    assert!(
        requests
            .iter()
            .all(|u| u == "https://downloads.rclone.org/version.txt")
    );
    let architecture = updater::hardware_architecture();
    #[cfg(target_os = "macos")]
    {
        // Original PlatformTests validates the actual executable's declared
        // deployment target before testing current-system eligibility.
        let minimum =
            updater::verify_native(&f.context.binary, &architecture, [65535, 255, 255]).unwrap();
        let requirement = minimum
            .split('.')
            .map(|part| part.parse::<u32>().unwrap())
            .collect::<Vec<_>>();
        assert_eq!(requirement.len(), 3, "Invalid declared minimum OS");
        let mut buffer = [0u8; 64];
        let mut length = buffer.len();
        // SAFETY: sysctl writes into the sized buffer, and the name is NUL-terminated.
        let result = unsafe {
            libc::sysctlbyname(
                c"kern.osproductversion".as_ptr(),
                buffer.as_mut_ptr().cast(),
                &mut length,
                std::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(result, 0, "cannot query actual macOS product version");
        let version = std::str::from_utf8(&buffer[..length.min(buffer.len())])
            .unwrap()
            .trim_matches('\0');
        let mut system = [0u32; 3];
        for (index, part) in version.split('.').take(3).enumerate() {
            system[index] = part.parse().unwrap();
        }
        let required = [requirement[0], requirement[1], requirement[2]];
        if system < required {
            assert!(updater::verify_native(&f.context.binary, &architecture, system).is_err());
            println!(
                "INFO actual rclone declares macOS {minimum}; current {version} correctly rejects installation"
            );
        } else {
            assert_eq!(
                updater::verify_native(&f.context.binary, &architecture, system).unwrap(),
                minimum,
                "Compatible fixture rejected"
            );
        }
    }
    #[cfg(not(target_os = "macos"))]
    updater::verify_native(&f.context.binary, &architecture, [0, 0, 0]).unwrap();
}
#[test]
#[ignore = "requires pinned RBN_TEST_RCLONE"]
fn official_archive_install_verifies_checksum_architecture_version_and_preserves_failed_target() {
    let f = Fixture::new(true);
    let probe = Updater::new(f.root.join("probe")).unwrap();
    let version = probe.version_of(&f.context.binary).unwrap();
    let architecture = updater::hardware_architecture();
    let system = if cfg!(target_os = "macos") {
        "osx"
    } else if cfg!(windows) {
        "windows"
    } else {
        "linux"
    };
    let executable = if cfg!(windows) {
        "rclone.exe"
    } else {
        "rclone"
    };
    let archive_name = format!("rclone-{version}-{system}-{architecture}.zip");
    let member = format!("rclone-{version}-{system}-{architecture}/{executable}");
    // The pinned official macOS fixture may require a newer system than the
    // runner. Its actual minimum-OS rejection is tested separately above. This
    // synthetic HTTPS archive needs a compatible native program to exercise the
    // successful install and checksum-failure paths on every supported macOS.
    #[cfg(target_os = "macos")]
    let packaged_binary = {
        let source = f.root.join("native-update-fixture.c");
        let target = f.root.join("native-update-fixture");
        assert!(updater::Release::parse(&version).is_some());
        fs::write(
            &source,
            format!("#include <stdio.h>\nint main(void) {{ puts(\"rclone {version}\"); return 0; }}\n"),
        )
        .unwrap();
        let arch = if architecture == "amd64" { "x86_64" } else { &architecture };
        let output = Command::new("/usr/bin/cc")
            .args(["-mmacosx-version-min=13.0", "-arch", arch])
            .arg(&source)
            .arg("-o")
            .arg(&target)
            .output()
            .unwrap();
        assert!(output.status.success(), "Native fixture compile failed: {}", String::from_utf8_lossy(&output.stderr));
        assert_eq!(updater::verify_native(&target, &architecture, [13, 0, 0]).unwrap(), "13.0.0");
        assert_eq!(probe.version_of(&target).unwrap(), version);
        target
    };
    #[cfg(not(target_os = "macos"))]
    let packaged_binary = f.context.binary.clone();
    let binary = fs::read(&packaged_binary).unwrap();
    let mut zip = zip::ZipWriter::new(std::io::Cursor::new(Vec::new()));
    zip.start_file(
        member,
        zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Stored)
            .unix_permissions(0o755),
    )
    .unwrap();
    zip.write_all(&binary).unwrap();
    let archive = Arc::new(zip.finish().unwrap().into_inner());
    let hash = updater::sha256(&archive);
    let sums = format!("{hash}  {archive_name}\n");
    let bytes = archive.clone();
    let expected = archive_name.clone();
    let fetcher: Fetcher = Arc::new(move |url, _, _| {
        let data = if url.ends_with("/SHA256SUMS") {
            sums.as_bytes().to_vec()
        } else if url.ends_with(&expected) {
            bytes.as_ref().clone()
        } else {
            return Err(DownloadError {
                message: "unexpected URL".into(),
                retryable: false,
            });
        };
        Ok(Reply {
            data,
            status: 200,
            url: url.into(),
            declared_size: None,
        })
    });
    let updater = Updater::with_fetcher(f.root.join("updates"), fetcher).unwrap();
    let target = f
        .root
        .join(if cfg!(windows) {
            "installation MiXeD École e\u{301}"
        } else {
            "installation"
        })
        .join(executable);
    let result = updater
        .install(&version, &target, None, &json!({"proxyMode":"manual"}))
        .unwrap();
    assert_eq!(result["status"], "updated");
    assert_eq!(result["verification"], "HTTPS + SHA-256");
    assert_eq!(fs::read(&target).unwrap(), binary);
    assert_eq!(probe.version_of(&target).unwrap(), version);
    #[cfg(windows)]
    {
        let accepted = updater::validated_target(&target).unwrap();
        assert_eq!(updater::validated_target(&accepted).unwrap(), accepted);
        let public = accepted.to_str().unwrap();
        assert!(!public.starts_with("//?/"));
        assert!(public.contains("MiXeD École e\u{301}"));
        let stage = accepted
            .parent()
            .unwrap()
            .join(".rbn-update-postcheck-fixture");
        fs::create_dir(&stage).unwrap();
        let rejected = stage.join(executable);
        fs::write(&rejected, b"synthetic broken replacement").unwrap();
        let before = updater::sha256(&fs::read(&accepted).unwrap());
        let error = updater::commit(&rejected, &accepted, |_| {
            Err("synthetic post-install check".into())
        })
        .unwrap_err();
        assert!(error.contains("已自動還原"));
        assert_eq!(updater::sha256(&fs::read(&accepted).unwrap()), before);
        assert_eq!(probe.version_of(&accepted).unwrap(), version);
        fs::remove_dir_all(stage).unwrap();
    }
    assert!(
        fs::read_dir(target.parent().unwrap())
            .unwrap()
            .flatten()
            .all(|e| !e.file_name().to_string_lossy().starts_with(".rbn-update-"))
    );
    let wrong = Updater::with_fetcher(
        f.root.join("bad-updates"),
        Arc::new(move |url, _, _| {
            Ok(Reply {
                data: if url.ends_with("SHA256SUMS") {
                    format!("{}  {archive_name}\n", "0".repeat(64)).into_bytes()
                } else {
                    archive.as_ref().clone()
                },
                status: 200,
                url: url.into(),
                declared_size: None,
            })
        }),
    )
    .unwrap();
    assert!(
        wrong
            .install(&version, &target, None, &json!({}))
            .unwrap_err()
            .contains("SHA-256")
    );
    assert_eq!(probe.version_of(&target).unwrap(), version);
}

#[test]
fn updater_parsers_and_policy_match_recorded_swift_0_11_0() {
    let golden: Value =
        serde_json::from_str(include_str!("fixtures/service-goldens.json")).unwrap();
    for case in golden["versions"].as_array().unwrap() {
        let input = case["input"].as_str().unwrap();
        let rclone = updater::Release::parse(input)
            .map(|r| json!(r.version()))
            .unwrap_or(Value::Null);
        let app = updater::Release::stable_app(input)
            .map(|r| json!(r.version()))
            .unwrap_or(Value::Null);
        assert_eq!(rclone, case["rclone"], "Swift release case {input:?}");
        assert_eq!(app, case["app"], "Swift app version case {input:?}");
    }
    for case in golden["appReleases"].as_array().unwrap() {
        let i = &case["input"];
        let r = Reply {
            data: if i["raw"] == true {
                i["body"].as_str().unwrap().as_bytes().to_vec()
            } else {
                serde_json::to_vec(&i["body"]).unwrap()
            },
            status: i["status"].as_u64().unwrap() as u16,
            url: i["url"].as_str().unwrap().into(),
            declared_size: i["declared"].as_u64(),
        };
        let actual = match updater::Release::stable_app(i["current"].as_str().unwrap()) {
            None => json!({"error":"App 版本格式不正確。"}),
            Some(current) => {
                updater::decode_app_reply(&r, current, i["repository"].as_str().unwrap())
                    .unwrap_or_else(|e| json!({"error":e}))
            }
        };
        assert_eq!(
            actual, case["expected"],
            "Swift app parser case {}",
            case["label"]
        );
    }
    for case in golden["downloads"].as_array().unwrap() {
        let i = &case["input"];
        let r = Reply {
            data: vec![],
            status: i["status"].as_u64().unwrap() as u16,
            url: i["url"].as_str().unwrap().into(),
            declared_size: i["size"].as_u64(),
        };
        let actual =
            match updater::validate_download_reply(&r, i["maximum"].as_u64().unwrap() as usize) {
                Ok(()) => json!({"ok":true}),
                Err(e) => json!({"error":e.message,"retryable":e.retryable}),
            };
        assert_eq!(actual, case["expected"], "Swift HTTP policy case {i}");
    }
}

#[test]
#[ignore = "requires pinned RBN_TEST_RCLONE"]
fn stored_password_defaults_are_native_only_and_marked_saved_in_each_question() {
    let f = Fixture::new(true);
    f.alias_config();
    let a = f.accounts();
    let c = &f.context;
    let password = "fixture-secret-not-real";
    let out = process::capture_input(
        c,
        &["obscure".into(), "-".into()],
        password.as_bytes(),
        4096,
        Duration::from_secs(10),
        None,
    )
    .unwrap()
    .checked()
    .unwrap();
    let encoded = String::from_utf8(out.stdout).unwrap().trim().to_owned();
    let text = fs::read_to_string(&f.config).unwrap()
        + &format!(
            "\n[private-fixture]\ntype = webdav\nurl = http://127.0.0.1:9\nvendor = other\nuser = fixture\npass = {encoded}\n"
        );
    fs::write(&f.config, text).unwrap();
    let mut q = begin(&a, c, "private-fixture", "edit", "");
    let mut saw_password = false;
    for _ in 0..30 {
        if q["phase"] == "ready" {
            break;
        }
        assert_eq!(q["phase"], "question", "{}", q);
        let public = q.to_string();
        assert!(!public.contains(password) && !public.contains(&encoded));
        if q["question"]["Name"] == "pass" {
            saw_password = true;
            assert_eq!(q["question"]["HasSavedValue"], true);
        }
        q = answer(&a, c, &q, None);
    }
    assert!(saw_password);
    assert_eq!(q["phase"], "ready");
    call(&a, c, json!({"action":"commit","id":q["id"]}));
    assert!(fs::read_to_string(&f.config).unwrap().contains(&encoded));
}
#[test]
#[ignore = "requires pinned RBN_TEST_RCLONE"]
fn detailed_google_shared_client_and_onedrive_browser_choices_follow_live_questions() {
    let f = Fixture::new(true);
    let original = f.alias_config();
    let a = f.accounts();
    let c = &f.context;
    let mut q = begin(&a, c, "google-fixture", "create", "drive");
    let mut saw_shared = false;
    let mut saw_required = false;
    for _ in 0..12 {
        let question = &q["question"];
        let name = question["Name"].as_str().unwrap_or_default();
        if name == "config_shared_client_id" {
            saw_shared = true;
        }
        if name == "client_id" && question["Required"] == true {
            saw_required = true;
            assert!(
                a.handle(
                    &json!({"action":"answer","id":q["id"],"step":q["step"],"value":""}),
                    c
                )
                .is_err()
            );
            break;
        }
        let supplied = (name == "scope").then_some("drive");
        q = answer(&a, c, &q, supplied);
    }
    assert!(saw_shared && saw_required, "{}", q);
    assert_eq!(fs::read(&f.config).unwrap(), original);
    cancel(&a, c, &q);
    let mut q = begin(&a, c, "microsoft-fixture", "create", "onedrive");
    let mut browser = false;
    for _ in 0..15 {
        if q["question"]["Name"] == "config_is_local" {
            browser = true;
            break;
        }
        q = answer(&a, c, &q, None);
    }
    assert!(browser, "{}", q);
    cancel(&a, c, &q);
}
#[test]
fn repeated_questionnaire_states_pause_without_looping_or_losing_original_config() {
    let f = Fixture::new(false);
    let original = f.alias_config();
    let c = f.fixture_context("repeated-questionnaire");
    let a = f.accounts();
    let q = batch(
        &a,
        &c,
        "repeated",
        "alias",
        json!({"remote":"/synthetic"}),
        "create",
        false,
    );
    assert_eq!(q["phase"], "question");
    assert_eq!(q["needsInputReason"], "repeated-question");
    assert_eq!(fs::read(&f.config).unwrap(), original);
    cancel(&a, &c, &q);
    check_no_staging(&f.root);
}

#[test]
#[ignore = "requires pinned RBN_TEST_RCLONE"]
fn updater_never_suggests_downgrade_and_invalid_official_version_response_is_rejected() {
    let f = Fixture::new(true);
    let up = Updater::with_fetcher(
        f.root.join("older"),
        Arc::new(|url, _, _| {
            Ok(Reply {
                data: b"rclone v0.0.0\n".to_vec(),
                status: 200,
                url: url.into(),
                declared_size: None,
            })
        }),
    )
    .unwrap();
    assert_eq!(
        up.check(Some(&f.context.binary), "", true, &json!({}))
            .unwrap()["status"],
        "current"
    );
    let invalid = Updater::with_fetcher(
        f.root.join("invalid"),
        Arc::new(|url, _, _| {
            Ok(Reply {
                data: b"<html>error</html>".to_vec(),
                status: 200,
                url: url.into(),
                declared_size: None,
            })
        }),
    )
    .unwrap();
    let actual = invalid.version_of(&f.context.binary).unwrap();
    assert!(actual.starts_with('v') && actual.chars().count() < 120);
    assert_eq!(
        invalid
            .check(Some(&f.context.binary), "", true, &json!({}))
            .unwrap_err(),
        "rclone 官網回傳的版本資訊無法辨識，請稍後再試。"
    );
}
#[test]
fn custom_rclone_version_reports_unavailable_and_mount_validation_starts_nothing() {
    let f = Fixture::new(false);
    let mut c = f.fixture_context("custom-version");
    c.binary = f.root.join(if cfg!(windows) {
        "custom-version.exe"
    } else {
        "custom-version"
    });
    fs::copy(env!("CARGO_BIN_EXE_rbn-service-fixture"), &c.binary).unwrap();
    let up = Updater::with_fetcher(
        f.root.join("updates"),
        Arc::new(|url, _, _| {
            Ok(Reply {
                data: b"rclone v9.8.7\n".to_vec(),
                status: 200,
                url: url.into(),
                declared_size: None,
            })
        }),
    )
    .unwrap();
    let r = up.check(Some(&c.binary), "", true, &json!({})).unwrap();
    assert_eq!(r["status"], "unavailable");
    assert_eq!(
        r["message"],
        "目前使用的是自訂或測試版 rclone；若要更換，請手動選擇要使用的穩定版。"
    );
    let manager = Tools::new(f.root.join("mount-work")).unwrap();
    let remote = Endpoint {
        remote: Some("fixture".into()),
        path: "folder".into(),
    };
    assert!(manager.start_mount(&c, &remote, &f.root, &[]).is_err());
    assert!(!manager.has_active());
    manager.shutdown().unwrap();
}

#[test]
fn tool_children_do_not_consume_engine_protocol_stdin() {
    if std::env::var_os("RBN_STDIN_PROBE").is_some() {
        let fixture = Fixture::new(false);
        let context = fixture.fixture_context("stdin-check");
        let endpoint = Endpoint {
            remote: None,
            path: fixture.root.to_string_lossy().into_owned(),
        };
        assert_eq!(
            Tools::tree(&context, &endpoint, 1).unwrap()["text"],
            "closed\n"
        );
        return;
    }
    let mut child = Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "tool_children_do_not_consume_engine_protocol_stdin",
            "--nocapture",
        ])
        .env("RBN_STDIN_PROBE", "1")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"engine-protocol-fixture\n")
        .unwrap();
    let result = child.wait_with_output().unwrap();
    assert!(
        result.status.success(),
        "stdin isolation probe failed: {} {}",
        String::from_utf8_lossy(&result.stdout),
        String::from_utf8_lossy(&result.stderr)
    );
}

#[test]
fn player_arguments_keep_original_ascii_control_character_policy() {
    let f = Fixture::new(false);
    let context = f.fixture_context("stream");
    let endpoint = Endpoint {
        remote: Some("fixture".into()),
        path: "folder".into(),
    };
    let player = PathBuf::from(env!("CARGO_BIN_EXE_rbn-service-fixture"));
    let manager = Tools::new(f.root.join("player-policy")).unwrap();
    assert!(
        manager
            .start_stream(
                &context,
                &endpoint,
                "x",
                &player,
                &["--fixture-player-fail".into(), "line\nbreak".into()]
            )
            .is_err()
    );
    assert!(!manager.has_active());
    let session = manager
        .start_stream(
            &context,
            &endpoint,
            "x",
            &player,
            &[
                "--fixture-player-fail".into(),
                "allowed\u{85}argument".into(),
            ],
        )
        .unwrap();
    assert_eq!(
        finished(&manager, &context, &session["id"])["status"],
        "failed"
    );
    manager.shutdown().unwrap();
}

// These original AccountsTests clauses exercise the engine's reservation owner,
// rather than only the standalone questionnaire service.
struct AccountEngineShutdown(Arc<rbn_core::engine::Engine>);
impl Drop for AccountEngineShutdown {
    fn drop(&mut self) {
        let _ = self.0.invoke("_shutdown", vec![]);
    }
}
fn account_engine(f: &Fixture) -> Arc<rbn_core::engine::Engine> {
    let engine =
        rbn_core::engine::Engine::new(f.root.join("engine-state"), f.root.join("engine-tools"))
            .unwrap();
    let environment=engine.invoke("saveSettings",vec![json!({"rclonePath":f.context.binary,"configPath":f.config,"autoCheckUpdates":false})]).unwrap();
    assert_eq!(environment["available"], true);
    engine
}
fn engine_account_wait(engine: &Arc<rbn_core::engine::Engine>, mut value: Value) -> Value {
    let deadline = Instant::now() + Duration::from_secs(30);
    while value["phase"] == "running" && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(40));
        value = engine
            .invoke(
                "accountConfig",
                vec![json!({"action":"poll","id":value["id"]})],
            )
            .unwrap();
    }
    assert_ne!(
        value["phase"], "running",
        "original questionnaire30s worker deadline"
    );
    assert_ne!(value["phase"], "error", "{value}");
    value
}
#[test]
#[ignore = "requires pinned RBN_TEST_RCLONE"]
fn config_path_change_is_rejected_during_account_transaction() {
    let f = Fixture::new(true);
    let engine = account_engine(&f);
    let _shutdown = AccountEngineShutdown(engine.clone());
    let session=engine_account_wait(&engine,engine.invoke("accountConfig",vec![json!({"action":"start","name":"validation","provider":"alias","mode":"create"})]).unwrap());
    assert_eq!(session["question"]["Name"], "remote");
    assert!(
        engine
            .invoke(
                "accountConfig",
                vec![
                    json!({"action":"answer","id":session["id"],"step":session["step"],"value":""})
                ]
            )
            .is_err()
    );
    assert!(
        engine
            .invoke(
                "accountConfig",
                vec![json!({"action":"answer","id":session["id"],"step":-1,"value":f.root})]
            )
            .is_err()
    );
    assert!(
        engine
            .invoke(
                "accountConfig",
                vec![json!({"action":"start","name":"other","provider":"alias"})]
            )
            .is_err()
    );
    assert!(
        engine
            .invoke(
                "saveSettings",
                vec![json!({"configPath":f.root.join("other.conf")})]
            )
            .is_err()
    );
    engine_account_wait(
        &engine,
        engine
            .invoke(
                "accountConfig",
                vec![json!({"action":"cancel","id":session["id"]})],
            )
            .unwrap(),
    );
}
#[test]
#[ignore = "requires pinned RBN_TEST_RCLONE"]
fn repeated_account_cancel_does_not_release_update_or_other_session_guard() {
    let f = Fixture::new(true);
    let engine = account_engine(&f);
    let _shutdown = AccountEngineShutdown(engine.clone());
    let session = engine_account_wait(
        &engine,
        engine
            .invoke(
                "accountConfig",
                vec![json!({"action":"start","name":"lease","provider":"alias","mode":"create"})],
            )
            .unwrap(),
    );
    engine_account_wait(
        &engine,
        engine
            .invoke(
                "accountConfig",
                vec![json!({"action":"cancel","id":session["id"]})],
            )
            .unwrap(),
    );
    engine.set_maintenance(true).unwrap();
    engine
        .invoke(
            "accountConfig",
            vec![json!({"action":"cancel","id":session["id"]})],
        )
        .unwrap();
    assert!(
        engine.auxiliary_context().is_err(),
        "repeated old cancellation released another maintenance owner"
    );
    engine.set_maintenance(false).unwrap();
}

#[test]
#[ignore = "requires pinned RBN_TEST_RCLONE"]
fn account_poll_and_cancel_survive_own_executable_moving_without_staged_or_lease_leaks() {
    let f = Fixture::new(true);
    let original = f.alias_config();
    let original_hash = updater::sha256(&original);
    let selected_folder = f.root.join("selected-binary");
    fs::create_dir(&selected_folder).unwrap();
    let selected = selected_folder.join(if cfg!(windows) {
        "rclone.exe"
    } else {
        "rclone"
    });
    fs::copy(&f.context.binary, &selected).unwrap();
    let moved = selected_folder.join("moved-test-only-binary");
    let engine = account_engine(&f);
    let _shutdown = AccountEngineShutdown(engine.clone());
    engine
        .invoke("saveSettings", vec![json!({"rclonePath":selected})])
        .unwrap();
    assert!(!engine.state_dir.join("tmp").exists());
    for phase in ["question", "ready"] {
        let mut session=engine_account_wait(&engine,engine.invoke("accountConfig",vec![json!({"action":"start","name":format!("move-{phase}"),"mode":"create","provider":"alias"})]).unwrap());
        assert_eq!(session["phase"], "question");
        assert_eq!(session["question"]["Name"], "remote");
        if phase == "ready" {
            session=engine_account_wait(&engine,engine.invoke("accountConfig",vec![json!({"action":"answer","id":session["id"],"step":session["step"],"value":f.root.join("target")})]).unwrap());
            session=engine_account_wait(&engine,engine.invoke("accountConfig",vec![json!({"action":"answer","id":session["id"],"step":session["step"],"value":"false"})]).unwrap());
            assert_eq!(session["phase"], "ready");
        }
        let staged = fs::read_dir(&f.root)
            .unwrap()
            .map(|e| e.unwrap().path())
            .find(|p| {
                p.file_name()
                    .unwrap()
                    .to_string_lossy()
                    .starts_with(".rbn-account-")
                    && p.extension().is_some_and(|e| e == "conf")
            })
            .expect("session must create its private staged config beside selected config");
        let old = PathBuf::from(format!("{}.old", staged.display()));
        fs::write(&old, b"synthetic owned old staging").unwrap();
        fs::rename(&selected, &moved).unwrap();
        assert!(!selected.exists());
        let polled = engine
            .invoke(
                "accountConfig",
                vec![json!({"action":"poll","id":session["id"]})],
            )
            .unwrap();
        assert_eq!(polled["phase"], phase);
        assert_eq!(polled["id"], session["id"]);
        let cancelled = engine_account_wait(
            &engine,
            engine
                .invoke(
                    "accountConfig",
                    vec![json!({"action":"cancel","id":session["id"]})],
                )
                .unwrap(),
        );
        assert_eq!(cancelled["phase"], "cancelled");
        assert!(!staged.exists() && !old.exists());
        check_no_staging(&f.root);
        assert_eq!(
            updater::sha256(&fs::read(&f.config).unwrap()),
            original_hash
        );
        assert_eq!(fs::read(&f.config).unwrap(), original);
        assert!(!engine.state_dir.join("tmp").exists());
        engine.set_maintenance(true).unwrap();
        engine.set_maintenance(false).unwrap();
        fs::rename(&moved, &selected).unwrap();
    }
}
