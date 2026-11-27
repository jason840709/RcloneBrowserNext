//! The reviewed 0.11.0 native wording, preserved independently of implementation.
use serde_json::Value;
use std::{collections::BTreeMap, sync::OnceLock};
struct Entry {
    en: String,
    ja: String,
    pieces: Vec<String>,
    labels: Vec<usize>,
    expression: Option<regex::Regex>,
}
struct Catalog {
    exact: BTreeMap<String, (String, String)>,
    templates: Vec<Entry>,
    labels: BTreeMap<String, (String, String)>,
}
fn catalog() -> &'static Catalog {
    static CATALOG: OnceLock<Catalog> = OnceLock::new();
    CATALOG.get_or_init(|| {
        let raw: Value =
            serde_json::from_str(include_str!("native_strings.json")).unwrap_or(Value::Null);
        let mut exact = BTreeMap::new();
        let mut templates = vec![];
        if let Some(rows) = raw["entries"].as_array() {
            for row in rows {
                let source = row["source"].as_str().unwrap_or("").to_owned();
                let en = row["en"].as_str().unwrap_or("").to_owned();
                let ja = row["ja"].as_str().unwrap_or("").to_owned();
                let pieces = source.split("{}").map(str::to_owned).collect::<Vec<_>>();
                if pieces.len() == 1 {
                    exact.entry(source).or_insert((en, ja));
                } else {
                    let pattern = format!(
                        "\\A{}\\z",
                        pieces
                            .iter()
                            .map(|s| regex::escape(s))
                            .collect::<Vec<_>>()
                            .join("([\\s\\S]*?)")
                    );
                    let expression = regex::Regex::new(&pattern).ok();
                    let labels = row["labels"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .filter_map(|v| v.as_u64().map(|n| n as usize))
                        .collect();
                    templates.push(Entry {
                        en,
                        ja,
                        pieces,
                        labels,
                        expression,
                    });
                }
            }
        }
        templates
            .sort_by_key(|e| std::cmp::Reverse(e.pieces.iter().map(String::len).sum::<usize>()));
        let mut labels = BTreeMap::new();
        if let Some(map) = raw["labels"].as_object() {
            for (k, v) in map {
                labels.insert(
                    k.clone(),
                    (
                        v["en"].as_str().unwrap_or("").to_owned(),
                        v["ja"].as_str().unwrap_or("").to_owned(),
                    ),
                );
            }
        }
        Catalog {
            exact,
            templates,
            labels,
        }
    })
}
fn translated(source: &str, language: &str) -> Option<String> {
    if !["en", "ja"].contains(&language) || source.len() > 65536 {
        return None;
    }
    let catalog = catalog();
    if let Some((en, ja)) = catalog.exact.get(source) {
        return Some(if language == "ja" { ja } else { en }.clone());
    }
    for entry in &catalog.templates {
        if !source.starts_with(entry.pieces.first().map(String::as_str).unwrap_or(""))
            || !source.ends_with(entry.pieces.last().map(String::as_str).unwrap_or(""))
        {
            continue;
        }
        for separator in entry
            .pieces
            .iter()
            .skip(1)
            .take(entry.pieces.len().saturating_sub(2))
            .filter(|s| !s.is_empty())
        {
            let literal = entry
                .pieces
                .iter()
                .map(|p| p.matches(separator.as_str()).count())
                .sum::<usize>();
            if source.matches(separator.as_str()).count() > literal {
                return None;
            }
        }
        let Some(captures) = entry.expression.as_ref().and_then(|r| r.captures(source)) else {
            continue;
        };
        let template = if language == "ja" {
            &entry.ja
        } else {
            &entry.en
        };
        let parts = template.split("{}").collect::<Vec<_>>();
        if parts.len() != captures.len() {
            continue;
        }
        let mut out = parts[0].to_owned();
        for (i, piece) in parts.iter().enumerate().skip(1) {
            let Some(capture) = captures.get(i) else {
                return None;
            };
            let text = capture.as_str();
            if entry.labels.contains(&i) {
                if let Some((en, ja)) = catalog.labels.get(text) {
                    out.push_str(if language == "ja" { ja } else { en });
                } else {
                    out.push_str(text);
                }
            } else {
                out.push_str(text);
            }
            out.push_str(piece);
        }
        return Some(out);
    }
    None
}
pub fn translate(source: &str, language: &str) -> String {
    translated(source, language).unwrap_or_else(|| source.to_owned())
}
pub fn japanese(source: &str, fallback: &str) -> String {
    translated(source, "ja").unwrap_or_else(|| fallback.to_owned())
}
pub fn response(value: &Value, language: &str) -> Value {
    fn walk(v: &Value, key: &str, l: &str) -> Value {
        match v {
            Value::String(s)
                if ["error", "message", "warning", "validationError"].contains(&key) =>
            {
                Value::String(translate(s, l))
            }
            Value::Array(a) => Value::Array(
                a.iter()
                    .map(|v| walk(v, if key == "warnings" { "warning" } else { key }, l))
                    .collect(),
            ),
            Value::Object(m) => {
                Value::Object(m.iter().map(|(k, v)| (k.clone(), walk(v, k, l))).collect())
            }
            _ => v.clone(),
        }
    }
    walk(value, "", language)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn original_catalog_is_well_formed() {
        let raw: Value = serde_json::from_str(include_str!("native_strings.json")).unwrap();
        assert_eq!(raw["entries"].as_array().unwrap().len(), 433);
        for row in raw["entries"].as_array().unwrap() {
            let source = row["source"].as_str().unwrap();
            for lang in ["en", "ja"] {
                let sample = source.replace("{}", "literal/path 🤍");
                assert_ne!(translate(&sample, lang), "");
            }
        }
    }
    #[test]
    fn paths_are_never_recursively_translated() {
        assert_eq!(
            translate("目錄讀取已取消。", "en"),
            "Folder loading was cancelled."
        );
        let source = "無法刪除空資料夾：目錄讀取已取消。（permission denied）。";
        assert_eq!(
            translate(source, "en"),
            "Cannot remove empty folder: 目錄讀取已取消。 (permission denied)."
        );
    }
}
