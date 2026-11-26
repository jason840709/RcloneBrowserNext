//! The persisted 0.11.0 task and job formats, including their legacy snapshots.
use crate::{
    Result,
    models::{self, TransferRequest},
    now, report, stats,
};
use serde_json::{Value, json};
use unicode_segmentation::UnicodeSegmentation;
fn field(raw: &Value, key: &str, label: &str, maximum: usize) -> Result<String> {
    models::text(&raw[key], label, maximum).map(str::to_owned)
}
fn request(raw: &Value) -> Result<TransferRequest> {
    if !raw.is_object() {
        return Err("傳輸設定格式不正確。".into());
    }
    TransferRequest::parse_saved(raw)
}
pub fn task(raw: &Value) -> Result<Value> {
    if !raw.is_object() {
        return Err("作業格式不正確。".into());
    }
    let id = field(raw, "id", "作業編號", 4096)?;
    if !crate::valid_id(&id) {
        return Err("作業編號格式不正確。".into());
    }
    let name = field(raw, "name", "作業名稱", 800)?;
    if name
        .trim_matches(|c: char| c.is_whitespace() && c != '\n' && c != '\r')
        .is_empty()
    {
        return Err("請輸入作業名稱。".into());
    }
    let request = request(&raw["request"])?;
    let created = field(raw, "createdAt", "建立時間", 4096)?;
    let updated = field(raw, "updatedAt", "更新時間", 4096)?;
    let mut task = json!({"id":id,"name":name,"request":request.value(),"createdAt":created,"updatedAt":updated});
    if let Err(error) = request.validate_operation() {
        task["validationError"] = json!(error);
    }
    Ok(task)
}
fn cancellation(raw: &Value) -> Option<Value> {
    raw.as_object()?;
    let requested = raw["requestedAt"].as_str()?;
    let exited = raw["processExited"].as_bool()?;
    let signal = raw["lastSignal"].as_str();
    if signal.is_some_and(|s| !["SIGINT", "SIGTERM", "SIGKILL"].contains(&s)) {
        return None;
    }
    let mut value = json!({"requestedAt":requested,"processExited":exited,"forced":matches!(signal,Some("SIGTERM"|"SIGKILL"))});
    if let Some(signal) = signal {
        value["lastSignal"] = json!(signal);
    }
    Some(value)
}
pub fn job(raw: &Value) -> Result<Value> {
    let id = field(raw, "id", "工作編號", 4096)?;
    if !crate::valid_id(&id) {
        return Err("工作編號格式不正確。".into());
    }
    let request = request(&raw["request"])?;
    let created = field(raw, "createdAt", "建立時間", 4096)?;
    let previous = field(raw, "status", "工作狀態", 4096)?;
    if ![
        "completed",
        "failed",
        "cancelled",
        "interrupted",
        "queued",
        "running",
        "cancelling",
        "paused",
    ]
    .contains(&previous.as_str())
    {
        return Err("工作狀態格式不正確。".into());
    }
    let status = if ["completed", "failed", "cancelled", "interrupted"].contains(&previous.as_str())
    {
        previous.as_str()
    } else {
        "interrupted"
    };
    let logs=raw["logs"].as_array().filter(|a|a.iter().all(Value::is_object)).map(|a|a.iter().skip(a.len().saturating_sub(250)).map(|line|{
        let mut row=json!({"time":line["time"].as_str().unwrap_or(""),"level":line["level"].as_str().unwrap_or("info"),"message":line["message"].as_str().unwrap_or("").graphemes(true).take(16000).collect::<String>()});
        if let Some(object)=line["object"].as_str(){row["object"]=json!(object.graphemes(true).take(16000).collect::<String>());}row
    }).collect::<Vec<_>>()).unwrap_or_default();
    let statistics = stats::finished(
        &stats::parse(&raw["stats"], &stats::empty()),
        status == "completed",
    );
    let mut job = json!({"id":id,"request":request.value(),"status":status,"createdAt":created,"stats":statistics,"logs":logs,"command":raw["command"].as_str().unwrap_or("")});
    for key in ["startedAt", "endedAt", "error"] {
        if let Some(value) = raw[key].as_str() {
            job[key] = json!(value);
        }
    }
    // NSNumber.int32Value in the reference also accepts a persisted JSON Bool.
    let code = if let Some(n) = raw["exitCode"].as_i64() {
        Some(n as i32)
    } else if let Some(n) = raw["exitCode"].as_u64() {
        Some(n as i32)
    } else if let Some(n) = raw["exitCode"].as_f64() {
        Some(n as i32)
    } else {
        raw["exitCode"].as_bool().map(i32::from)
    };
    if let Some(code) = code {
        job["exitCode"] = json!(code);
    }
    if let Some(value) = cancellation(&raw["cancellation"]) {
        job["cancellation"] = value;
    }
    if let Some(summary) = report::normalized_summary(&raw["report"]) {
        job["report"] = summary;
    }
    if status != previous {
        job["endedAt"] = json!(now());
        job["error"] = json!("上次關閉時工作尚未完成，未自動重跑。");
    }
    Ok(job)
}
pub fn sorted_tasks(tasks: &[Value]) -> Vec<Value> {
    let mut tasks = tasks.to_vec();
    tasks.sort_by(|a, b| {
        b["updatedAt"]
            .as_str()
            .unwrap_or("")
            .cmp(a["updatedAt"].as_str().unwrap_or(""))
    });
    tasks
}
