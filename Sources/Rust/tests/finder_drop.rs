//! The five original FinderDropTests groups; all files are isolated synthetic data.
#[path = "support/fixture_paths.rs"]
mod fixture_paths;
use rbn_core::native_requests::finder_drop;
use serde_json::{Value, json};
use std::{
    fs,
    path::{Path, PathBuf},
};
struct Fixture {
    root: PathBuf,
    source: PathBuf,
    file: PathBuf,
    folder: PathBuf,
}
impl Fixture {
    fn new() -> Self {
        let root = std::env::var_os("RBN_TEST_ROOT")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../.tmp/services-tests")
            });
        let root = root.join(format!("finder-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        let root = fixture_paths::canonical(&root);
        let source = root.join("測試 ' folder");
        fs::create_dir_all(&source).unwrap();
        let file = source.join("写真 ' [1].txt");
        fs::write(&file, b"kept").unwrap();
        let folder = source.join("Backup 2026");
        fs::create_dir(&folder).unwrap();
        Self {
            root,
            source,
            file,
            folder,
        }
    }
    fn url(path: &Path) -> Value {
        json!(url::Url::from_file_path(path).unwrap().as_str())
    }
    fn urls(&self) -> Value {
        json!([Self::url(&self.file), Self::url(&self.folder)])
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.root).unwrap();
    }
}
fn golden_success(case: &str, actual: &Value, root: &Path) {
    let fixture: Value =
        serde_json::from_str(include_str!("fixtures/native-report-0.11.0.json")).unwrap();
    let row = fixture["finder"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["case"] == case)
        .unwrap();
    assert_eq!(row["ok"], true);
    let mut expected = row["value"].clone();
    expected["source"]["path"] = json!(expected["source"]["path"].as_str().unwrap().replacen(
        "$ROOT",
        &fixture_paths::wire(root),
        1
    ));
    assert_eq!(actual, &expected);
}
#[test]
fn finder_files_preserve_exact_names_and_folder_without_transferring() {
    let f = Fixture::new();
    let result = finder_drop(&f.urls()).unwrap();
    assert!(result["source"]["remote"].is_null());
    assert_eq!(result["source"]["path"], fixture_paths::wire(&f.source));
    let selected = result["selection"].as_array().unwrap();
    assert_eq!(selected.len(), 2);
    assert_eq!(selected[0]["name"], "写真 ' [1].txt");
    assert_eq!(selected[0]["isDir"], false);
    assert_eq!(selected[1]["isDir"], true);
    assert_eq!(fs::read_to_string(&f.file).unwrap(), "kept");
    golden_success(
        "Finder files preserve exact names and folder selection without transferring",
        &result,
        &f.root,
    );
}
#[test]
fn duplicate_finder_urls_select_each_item_once() {
    let f = Fixture::new();
    let result = finder_drop(&json!([
        Fixture::url(&f.file),
        Fixture::url(&f.file),
        Fixture::url(&f.folder),
        Fixture::url(&f.folder)
    ]))
    .unwrap();
    assert_eq!(result["selection"].as_array().unwrap().len(), 2);
    golden_success(
        "duplicate Finder URLs select each item once",
        &result,
        &f.root,
    );
}
#[test]
fn mixed_parents_and_non_file_urls_reject_before_transfer() {
    let f = Fixture::new();
    let other = f.root.join("other.txt");
    fs::write(&other, b"other").unwrap();
    assert!(finder_drop(&json!([Fixture::url(&f.file), Fixture::url(&other)])).is_err());
    assert!(finder_drop(&json!(["https://example.org/file"])).is_err());
    assert!(finder_drop(&json!(["file://other-host/tmp/example"])).is_err());
    assert!(other.exists());
}
#[test]
fn empty_missing_root_oversized_and_control_character_drops_reject() {
    let f = Fixture::new();
    assert!(finder_drop(&json!([])).is_err());
    assert!(finder_drop(&json!([Fixture::url(&f.source.join("missing.txt"))])).is_err());
    assert!(finder_drop(&json!(["file:///"])).is_err());
    assert!(finder_drop(&Value::Array(vec![Fixture::url(&f.file); 10001])).is_err());
    let invalid = f.source.join("line\nbreak.txt");
    #[cfg(not(windows))]
    fs::write(&invalid, b"test").unwrap();
    // Win32 rejects a control-character leaf before a file can exist. Keep
    // feeding the original newline URL to the drop parser on this platform.
    #[cfg(windows)]
    assert!(fs::write(&invalid, b"test").is_err());
    assert!(finder_drop(&json!([Fixture::url(&invalid)])).is_err());
}
#[test]
fn symbolic_links_reject_and_leave_original_target_unchanged() {
    let f = Fixture::new();
    let link = f.source.join("folder-link");
    #[cfg(unix)]
    std::os::unix::fs::symlink(&f.folder, &link).unwrap();
    #[cfg(windows)]
    std::os::windows::fs::symlink_dir(&f.folder, &link).unwrap();
    assert!(finder_drop(&json!([Fixture::url(&link)])).is_err());
    assert!(f.folder.exists());
}
