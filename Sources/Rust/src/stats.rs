use serde_json::{Value, json};
use std::collections::BTreeMap;
use unicode_segmentation::UnicodeSegmentation;
fn seconds(v: &Value) -> Option<f64> {
    v.as_f64().filter(|x| x.is_finite() && *x >= 0.)
}
pub fn number(v: &Value) -> f64 {
    v.as_f64()
        .filter(|x| x.is_finite() && *x >= 0.)
        .unwrap_or(0.)
}
pub fn empty() -> Value {
    json!({"bytes":0,"totalBytes":0,"speed":0,"eta":null,"transfers":0,"totalTransfers":0,"checks":0,"totalChecks":0,"listed":0,"errors":0,"deletes":0,"elapsedTime":0,"transferring":[],"speedKind":"rolling","speedWindowSeconds":0,"averageSpeed":0,"filesPerSecond":0,"etaSource":null})
}
pub fn parse(raw: &Value, previous: &Value) -> Value {
    if !raw.is_object() {
        return previous.clone();
    }
    let mut out = empty();
    for key in [
        "bytes",
        "totalBytes",
        "transfers",
        "totalTransfers",
        "checks",
        "totalChecks",
        "listed",
        "errors",
        "deletes",
        "elapsedTime",
    ] {
        out[key] = json!(seconds(&raw[key]).unwrap_or_else(|| number(&previous[key])));
    }
    for key in [
        "speed",
        "speedWindowSeconds",
        "averageSpeed",
        "filesPerSecond",
    ] {
        out[key] = json!(number(&raw[key]));
    }
    out["eta"] = seconds(&raw["eta"]).map_or(Value::Null, |n| json!(n));
    out["speedKind"] = json!(if raw["speedKind"] == "overall" {
        "overall"
    } else {
        "rolling"
    });
    if ["bytes", "files"].contains(&raw["etaSource"].as_str().unwrap_or("")) {
        out["etaSource"] = raw["etaSource"].clone();
    }
    if let Some(files) = raw["transferring"]
        .as_array()
        .filter(|a| a.iter().all(Value::is_object))
    {
        out["transferring"]=Value::Array(files.iter().take(64).map(|f|{
        let size=number(&f["size"]);let bytes=number(&f["bytes"]);
        json!({"name":f["name"].as_str().unwrap_or("").graphemes(true).take(16000).collect::<String>(),"size":size,"bytes":bytes,"percentage":seconds(&f["percentage"]).unwrap_or_else(||if size>0.{bytes/size*100.}else{0.}).min(100.),"speed":number(&f["speed"]),"speedAvg":number(&f["speedAvg"]),"eta":seconds(&f["eta"]).map_or(Value::Null,|n|json!(n))})
    }).collect());
    }
    out
}
pub fn finished(value: &Value, completed: bool) -> Value {
    let mut out = value.clone();
    let elapsed = number(&out["elapsedTime"]);
    let average = if elapsed > 0. {
        number(&out["bytes"]) / elapsed
    } else {
        number(&out["averageSpeed"])
    };
    out["speed"] = json!(if average.is_finite() { average } else { 0. });
    out["averageSpeed"] = out["speed"].clone();
    out["speedKind"] = json!("overall");
    out["speedWindowSeconds"] = json!(elapsed);
    let rate = if elapsed > 0. {
        number(&out["transfers"]) / elapsed
    } else {
        0.
    };
    out["filesPerSecond"] = json!(if rate.is_finite() { rate } else { 0. });
    out["eta"] = if completed { json!(0) } else { Value::Null };
    out["etaSource"] = Value::Null;
    out["transferring"] = json!([]);
    out
}
#[derive(Clone, Copy)]
struct Sample {
    time: f64,
    bytes: f64,
    files: f64,
}
#[derive(Default)]
pub struct Throughput {
    samples: Vec<Sample>,
    last_elapsed: f64,
    last_raw_elapsed: Option<f64>,
    last_bytes: f64,
    last_files: f64,
    last_observed: Option<f64>,
    started: Option<f64>,
    monotonic: Option<std::time::Instant>,
    last_increase: f64,
    active_time: f64,
    last_raw_active: Option<f64>,
    saw_clock: bool,
    silent: BTreeMap<String, f64>,
}
impl Throughput {
    pub fn sample_count(&self) -> usize {
        self.samples.len()
    }
    pub fn start(&mut self) {
        let clock = std::time::Instant::now();
        self.start_at(0.);
        self.monotonic = Some(clock);
    }
    pub fn start_at(&mut self, uptime: f64) {
        *self = Self::default();
        self.started = Some(uptime);
        self.last_observed = Some(uptime);
        self.samples.push(Sample {
            time: 0.,
            bytes: 0.,
            files: 0.,
        });
    }
    pub fn update(&mut self, raw: &Value, previous: &Value) -> Value {
        let uptime = self
            .monotonic
            .get_or_insert_with(std::time::Instant::now)
            .elapsed()
            .as_secs_f64();
        self.update_at(raw, previous, uptime)
    }
    pub fn update_at(&mut self, raw: &Value, previous: &Value, uptime: f64) -> Value {
        if self.samples.is_empty() {
            let clock = self.monotonic;
            self.start_at(uptime);
            self.monotonic = clock;
        }
        let mut out = parse(raw, previous);
        let bytes = number(&out["bytes"]);
        let files = number(&out["transfers"]);
        let raw_elapsed = seconds(&raw["elapsedTime"]);
        let reset_clock = raw_elapsed
            .zip(self.last_raw_elapsed)
            .is_some_and(|(a, b)| a < b);
        let elapsed = raw_elapsed
            .map(|v| {
                if reset_clock {
                    v
                } else {
                    v.max(self.last_elapsed)
                }
            })
            .unwrap_or(self.last_elapsed + (uptime - self.last_observed.unwrap_or(uptime)).max(0.));
        let raw_active = seconds(&raw["transferTime"]);
        let active_reset = raw_active
            .zip(self.last_raw_active)
            .is_some_and(|(a, b)| a < b);
        let step = if let Some(active) = raw_active {
            self.saw_clock = true;
            if active_reset {
                active
            } else {
                (active - self.last_raw_active.unwrap_or(0.)).max(0.)
            }
        } else if reset_clock {
            0.
        } else {
            (elapsed - self.last_elapsed).max(0.)
        };
        self.active_time += step;
        let transferring = bytes > self.last_bytes || step > 0.;
        let current = Sample {
            time: self.active_time,
            bytes,
            files,
        };
        if self.samples.is_empty() {
            self.samples.push(Sample {
                time: 0.,
                bytes: 0.,
                files: 0.,
            });
        }
        if bytes < self.last_bytes || files < self.last_files || reset_clock || active_reset {
            self.samples = vec![current];
            self.last_increase = elapsed;
            self.silent.clear();
        } else {
            if bytes > self.last_bytes {
                self.last_increase = elapsed;
            }
            let replace = self.samples.len() > 1
                && self.samples.last().is_some_and(|s| {
                    s.time.floor() == current.time.floor() || current.time <= s.time
                });
            if replace {
                if let Some(s) = self.samples.last_mut() {
                    *s = current;
                }
            } else if self.samples.last().is_some_and(|s| current.time > s.time) {
                self.samples.push(current);
            }
            let cutoff = (current.time - 60.).max(0.);
            while self.samples.len() > 2 && self.samples[1].time <= cutoff {
                self.samples.remove(0);
            }
            if self.samples.len() > 64 {
                self.samples.drain(..self.samples.len() - 64);
            }
        }
        let mut silent = BTreeMap::new();
        if let Some(active) = out["transferring"].as_array() {
            for f in active {
                if number(&f["size"]) > 0. && number(&f["bytes"]) == 0. {
                    let name = f["name"].as_str().unwrap_or("").to_owned();
                    let since = *self.silent.get(&name).unwrap_or(&elapsed);
                    silent.insert(name, since);
                }
            }
        }
        self.silent = silent;
        let hidden =
            elapsed - self.last_increase >= 5. && self.silent.values().any(|t| elapsed - *t >= 5.);
        let (speed, span) = self.rate(0, if hidden { 60. } else { 10. }, current);
        let calm = self.rate(0, if hidden { 60. } else { 30. }, current).0;
        let file_rate = self.rate(1, 30., current).0;
        let checking = raw["checking"].as_array().is_some_and(|a| !a.is_empty());
        out["speed"] = json!(speed);
        out["filesPerSecond"] = json!(file_rate);
        out["speedKind"] = json!("rolling");
        out["speedWindowSeconds"] = json!(span);
        out["speedState"] = json!(if hidden {
            "hidden"
        } else if self.saw_clock && !transferring {
            if checking { "checking" } else { "idle" }
        } else if span > 0. {
            "live"
        } else {
            "measuring"
        });
        out["transferTime"] = json!(self.active_time);
        let average = if self.active_time > 0. {
            bytes / self.active_time
        } else {
            0.
        };
        out["averageSpeed"] = json!(if average.is_finite() { average } else { 0. });
        out["eta"] = Value::Null;
        out["etaSource"] = Value::Null;
        let remaining = (number(&out["totalBytes"]) - bytes).max(0.);
        let remaining_files = (number(&out["totalTransfers"]) - files).max(0.);
        if remaining > 0. && calm > 0. {
            let eta = remaining / calm;
            if eta.is_finite() {
                out["eta"] = json!(eta);
                out["etaSource"] = json!("bytes");
            }
        } else if remaining == 0. && remaining_files > 0. && file_rate > 0. {
            let eta = remaining_files / file_rate;
            if eta.is_finite() {
                out["eta"] = json!(eta);
                out["etaSource"] = json!("files");
            }
        }
        for key in ["retryError", "fatalError"] {
            if raw[key].is_boolean() {
                out[key] = raw[key].clone();
            }
        }
        self.last_observed = Some(uptime);
        self.last_elapsed = elapsed;
        self.last_raw_elapsed = raw_elapsed.or(self.last_raw_elapsed);
        self.last_raw_active = raw_active.or(self.last_raw_active);
        self.last_bytes = bytes;
        self.last_files = files;
        out["elapsedTime"] = json!(elapsed);
        out
    }
    fn rate(&self, key: u8, window: f64, now: Sample) -> (f64, f64) {
        let Some(first) = self.samples.first() else {
            return (0., 0.);
        };
        if now.time <= first.time {
            return (0., 0.);
        }
        let get = |s: Sample| if key == 0 { s.bytes } else { s.files };
        let increases = self
            .samples
            .windows(2)
            .enumerate()
            .filter_map(|(i, p)| {
                if get(p[1]) > get(p[0]) {
                    Some(i + 1)
                } else {
                    None
                }
            })
            .collect::<Vec<_>>();
        let mut start = (now.time - window).max(first.time);
        if increases
            .iter()
            .filter(|i| self.samples[**i].time > start)
            .count()
            < 3
        {
            let times = increases
                .iter()
                .rev()
                .take(4)
                .rev()
                .map(|i| self.samples[*i].time)
                .collect::<Vec<_>>();
            let mut gaps = times.windows(2).map(|p| p[1] - p[0]).collect::<Vec<_>>();
            gaps.sort_by(f64::total_cmp);
            let usual = gaps.get(gaps.len() / 2);
            let quiet = now.time - times.last().copied().unwrap_or(first.time);
            if usual.is_none_or(|u| quiet <= 2. * u) {
                if increases.len() > 3 {
                    start = start.min(self.samples[increases[increases.len() - 4]].time);
                } else {
                    start = first.time;
                }
            }
        }
        let after = self
            .samples
            .iter()
            .position(|s| s.time >= start)
            .unwrap_or(self.samples.len() - 1);
        let value = if after == 0 {
            get(self.samples[0])
        } else {
            let a = self.samples[after - 1];
            let b = self.samples[after];
            if b.time > a.time {
                get(a) + (get(b) - get(a)) * (start - a.time) / (b.time - a.time)
            } else {
                get(b)
            }
        };
        let span = now.time - start;
        if span <= 0. {
            (0., 0.)
        } else {
            let quotient = (get(now) - value).max(0.) / span;
            (if quotient.is_finite() { quotient } else { 0. }, span)
        }
    }
    pub fn finish(&self, value: &Value, completed: bool) -> Value {
        self.finish_at(
            value,
            completed,
            self.monotonic
                .map(|t| t.elapsed().as_secs_f64())
                .unwrap_or(self.last_observed.unwrap_or(0.)),
        )
    }
    pub fn finish_at(&self, value: &Value, completed: bool, uptime: f64) -> Value {
        let mut out = value.clone();
        if number(&out["elapsedTime"]) == 0. && !self.samples.is_empty() {
            if let Some(started) = self.started {
                out["elapsedTime"] = json!((uptime - started).max(0.));
            }
        }
        let mut out = finished(&out, completed);
        if self.saw_clock && self.active_time > 0. {
            let average = number(&out["bytes"]) / self.active_time;
            if average.is_finite() {
                out["speed"] = json!(average);
                out["averageSpeed"] = json!(average);
                out["speedWindowSeconds"] = json!(self.active_time);
                out["filesPerSecond"] = json!(number(&out["transfers"]) / self.active_time);
            }
            out["transferTime"] = json!(self.active_time);
        }
        out["speedState"] = json!("live");
        out
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn comparing_does_not_dilute_transfer_speed() {
        let mut t = Throughput::default();
        let a = t.update(
            &json!({"bytes":100,"transfers":1,"elapsedTime":10,"transferTime":1}),
            &empty(),
        );
        let b = t.update(
            &json!({"bytes":100,"transfers":1,"elapsedTime":100,"transferTime":1,"checking":["a"]}),
            &a,
        );
        assert_eq!(b["speed"], 100.);
        assert_eq!(b["speedState"], "checking");
        let done = t.finish(&b, true);
        assert_eq!(done["speed"], 100.);
    }
    #[test]
    fn rounds_never_produce_negative_speed() {
        let mut t = Throughput::default();
        let a = t.update(
            &json!({"bytes":100,"elapsedTime":10,"transferTime":3}),
            &empty(),
        );
        let b = t.update(&json!({"bytes":1,"elapsedTime":1,"transferTime":0.1}), &a);
        assert!(number(&b["speed"]) >= 0.);
    }
}
