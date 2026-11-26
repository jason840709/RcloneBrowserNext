//! Exact original NativeMessagesTests assertion groups, replayed from Swift.
use rbn_core::native;
use serde_json::Value;
fn check(name: &str) {
    let fixture: Value =
        serde_json::from_str(include_str!("fixtures/native-report-0.11.0.json")).unwrap();
    let rows = fixture["native"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|row| row["case"] == name)
        .collect::<Vec<_>>();
    assert!(
        !rows.is_empty(),
        "missing original Swift assertion group: {name}"
    );
    for row in rows {
        let source = row["source"].as_str().unwrap();
        let output = match row["operation"].as_str().unwrap() {
            "translate" => native::translate(source, row["language"].as_str().unwrap()),
            "japanese" => native::japanese(source, row["fallback"].as_str().unwrap()),
            op => panic!("unknown recorded native operation {op}"),
        };
        assert_eq!(
            output.as_bytes(),
            row["output"].as_str().unwrap().as_bytes(),
            "original group {name}, source {source:?}"
        );
    }
}
#[test]
fn traditional_chinese_and_unsupported_language_preserve_original_bytes() {
    check("Traditional Chinese and unsupported language preserve original bytes");
}
#[test]
fn settings_transfer_tools_updater_and_finder_have_english_and_japanese() {
    check("Settings, transfer, tools, updater and Finder errors have English and Japanese");
}
#[test]
fn source_and_destination_preserve_japanese_quotes_braces_and_newlines() {
    check("Source and destination preserve Japanese, quotes, braces and newlines");
}
#[test]
fn captured_file_names_never_recursively_translate() {
    check("Captured file names never recursively become translated app labels");
}
#[test]
fn only_explicit_field_labels_and_missing_version_status_translate() {
    check("Only explicit field labels and missing-version status translate inside captures");
}
#[test]
fn http_counts_and_macos_versions_remain_exact() {
    check("HTTP codes, download counts and macOS versions remain exact");
}
#[test]
fn unknown_provider_diagnostics_remain_literal() {
    check("Unknown provider diagnostics keep embedded file names and JSON verbatim");
}
#[test]
fn engine_wrappers_leave_multiline_backend_output_literal() {
    check("Engine wrappers localize while multiline backend output remains literal");
}
#[test]
fn specific_tool_wrappers_win_without_changing_stderr() {
    check("Specific tool wrappers win over code-only variants without changing stderr");
}
#[test]
fn deletion_confirmation_preserves_selected_file_names() {
    check("Deletion confirmation preserves every selected filename");
}
#[test]
fn ambiguous_separators_preserve_entire_original() {
    check("Ambiguous path separators preserve the complete original message");
}
#[test]
fn absolute_anchors_reject_partial_diagnostic_translation() {
    check("Absolute anchors do not partially translate trailing or prefixed diagnostics");
}
#[test]
fn unknown_oversized_and_japanese_fallback_are_stable() {
    check("Unknown and oversized messages use stable fallback");
}
