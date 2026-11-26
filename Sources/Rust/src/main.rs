use rbn_core::{Result, engine::Engine, native};
use serde_json::{Value, json};
use std::{
    collections::BTreeSet,
    io::{self, BufRead, Write},
    path::PathBuf,
    sync::{Arc, Condvar, Mutex},
};
use unicode_segmentation::UnicodeSegmentation;

const LINE_LIMIT: usize = 8 * 1024 * 1024;

fn send(output: &Mutex<io::Stdout>, value: Value) {
    if let Ok(mut bytes) = serde_json::to_vec(&value) {
        bytes.push(b'\n');
        if let Ok(mut stdout) = output.lock() {
            let _ = stdout.write_all(&bytes);
            let _ = stdout.flush();
        }
    }
}

/// The queue follows CompatMain's concurrent DispatchQueue: ordinary calls may
/// overlap, a barrier waits for all earlier queue work, and cancellation controls
/// bypass barriers. Reservations are made by the single pipe reader, never by a
/// worker whose scheduling order could differ from the original request order.
#[derive(Default)]
struct QueueState {
    next: u64,
    pending: BTreeSet<u64>,
    last_barrier: Option<u64>,
    active: usize,
}
#[derive(Default)]
struct Queue {
    state: Mutex<QueueState>,
    changed: Condvar,
}
struct Ticket {
    queue: Arc<Queue>,
    index: Option<u64>,
    preceding_barrier: Option<u64>,
    barrier: bool,
}
impl Queue {
    fn reserve(self: &Arc<Self>, method: &str) -> Ticket {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        state.active += 1;
        let bypass = matches!(method, "cancelList" | "_cancelListings");
        let barrier = matches!(method, "_state" | "_shutdown");
        let preceding_barrier = state.last_barrier;
        let index = if bypass {
            None
        } else {
            let index = state.next;
            state.next += 1;
            state.pending.insert(index);
            if barrier {
                state.last_barrier = Some(index);
            }
            Some(index)
        };
        Ticket {
            queue: self.clone(),
            index,
            preceding_barrier,
            barrier,
        }
    }
    fn wait_all(&self) {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        while state.active != 0 {
            state = self.changed.wait(state).unwrap_or_else(|e| e.into_inner());
        }
    }
}
impl Ticket {
    fn wait(&self) {
        let Some(index) = self.index else { return };
        let mut state = self.queue.state.lock().unwrap_or_else(|e| e.into_inner());
        loop {
            let blocked = if self.barrier {
                state.pending.range(..index).next().is_some()
            } else {
                self.preceding_barrier
                    .is_some_and(|p| state.pending.contains(&p))
            };
            if !blocked {
                return;
            }
            state = self
                .queue
                .changed
                .wait(state)
                .unwrap_or_else(|e| e.into_inner());
        }
    }
}
impl Drop for Ticket {
    fn drop(&mut self) {
        let mut state = self.queue.state.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(index) = self.index {
            state.pending.remove(&index);
        }
        state.active -= 1;
        self.queue.changed.notify_all();
    }
}

/// Discard an oversized line in bounded memory, then resume at the next frame.
/// Swift readLine also accepts a final line without a newline and strips CRLF.
fn read_frame(input: &mut impl BufRead) -> io::Result<Option<Vec<u8>>> {
    let mut bytes = Vec::new();
    let mut oversized = false;
    let mut seen = false;
    loop {
        let chunk = input.fill_buf()?;
        if chunk.is_empty() {
            break;
        }
        seen = true;
        let length = chunk
            .iter()
            .position(|b| *b == b'\n')
            .map_or(chunk.len(), |n| n + 1);
        let ended = chunk[length - 1] == b'\n';
        if !oversized {
            if bytes.len().saturating_add(length) > LINE_LIMIT + 2 {
                oversized = true;
                bytes.clear();
            } else {
                bytes.extend_from_slice(&chunk[..length]);
            }
        }
        input.consume(length);
        if ended {
            break;
        }
    }
    if !seen {
        return Ok(None);
    }
    if bytes.last() == Some(&b'\n') {
        bytes.pop();
    }
    if bytes.last() == Some(&b'\r') {
        bytes.pop();
    }
    if oversized || bytes.len() > LINE_LIMIT {
        bytes.clear();
    }
    Ok(Some(bytes))
}
fn request(bytes: &[u8]) -> Option<(String, String, Vec<Value>)> {
    let raw: Value = serde_json::from_slice(bytes).ok()?;
    let object = raw.as_object()?;
    let id = object.get("id")?.as_str()?;
    let method = object.get("method")?.as_str()?;
    let args = object.get("args")?.as_array()?;
    if id.is_empty()
        || id.graphemes(true).count() > 96
        || method.graphemes(true).count() > 80
        || args.len() > 8
    {
        return None;
    }
    Some((id.into(), method.into(), args.clone()))
}
fn run() -> Result<()> {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    if let Some(code) = rbn_core::partial::run_cli(&args, &mut io::stdout(), &mut io::stderr()) {
        if code != 0 {
            std::process::exit(code)
        }
        return Ok(());
    }
    if args == ["--version"] {
        println!("Rclone Browser Next engine {} (Rust)", rbn_core::VERSION);
        return Ok(());
    }
    if args.len() != 4 || args[0] != "--state-dir" || args[2] != "--engine-dir" {
        return Err("Usage: rbn-engine --state-dir PATH --engine-dir PATH".into());
    }
    let engine = Engine::new(PathBuf::from(&args[1]), PathBuf::from(&args[3]))?;
    let localize_results = std::env::var("RBN_NATIVE_LOCALIZE_RESULTS").as_deref() == Ok("1");
    let output = Arc::new(Mutex::new(io::stdout()));
    let events = output.clone();
    let weak = Arc::downgrade(&engine);
    engine.set_event_handler(Arc::new(move |event| {
        let event = if localize_results {
            weak.upgrade()
                .map_or(event.clone(), |e| native::response(&event, &e.language()))
        } else {
            event
        };
        send(&events, json!({"event": event}));
    }));
    let queue = Arc::new(Queue::default());
    let mut input = io::BufReader::new(io::stdin());
    while let Some(frame) = read_frame(&mut input).map_err(|e| e.to_string())? {
        let Some((id, method, args)) = request(&frame) else {
            continue;
        };
        if method == "list" {
            if let Err(error) = engine.prepare_listing(args.get(1).unwrap_or(&Value::Null)) {
                send(
                    &output,
                    json!({"id":id,"error":native::translate(&error,&engine.language())}),
                );
                continue;
            }
        }
        if method == "_shutdown" {
            engine.cancel_listings();
        }
        let ticket = queue.reserve(&method);
        let worker_engine = engine.clone();
        let out = output.clone();
        let failure_id = id.clone();
        if let Err(error) = std::thread::Builder::new().name("rbn-request".into()).spawn(move || {
            ticket.wait();
            let reply = match worker_engine.invoke(&method, args) {
                Ok(value) => json!({"id":id,"result":if localize_results {native::response(&value,&worker_engine.language())} else {value}}),
                Err(error) => json!({"id":id,"error":native::translate(&error,&worker_engine.language())}),
            };
            send(&out, reply);
            drop(ticket);
        }) {
            send(&output, json!({"id":failure_id,"error":error.to_string()}));
        }
    }
    engine.cancel_listings();
    queue.wait_all();
    let _ = engine.invoke("_shutdown", vec![]);
    Ok(())
}
fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{io::Cursor, sync::mpsc, thread, time::Duration};
    #[test]
    fn frames_resume_after_oversize_and_accept_crlf_and_final_line() {
        let mut bytes = vec![b'x'; LINE_LIMIT + 3];
        bytes.extend_from_slice(b"\n{\"id\":\"a\",\"method\":\"_state\",\"args\":[]}\r\nlast");
        let mut input = Cursor::new(bytes);
        assert_eq!(read_frame(&mut input).unwrap(), Some(vec![]));
        assert_eq!(
            request(&read_frame(&mut input).unwrap().unwrap())
                .unwrap()
                .0,
            "a"
        );
        assert_eq!(read_frame(&mut input).unwrap(), Some(b"last".to_vec()));
        assert_eq!(read_frame(&mut input).unwrap(), None);
    }
    #[test]
    fn envelopes_match_swift_grapheme_and_argument_limits() {
        let accepted =
            json!({"id":"👨‍👩‍👧‍👦".repeat(96),"method":"x".repeat(80),"args":vec![Value::Null;8]});
        assert!(request(&serde_json::to_vec(&accepted).unwrap()).is_some());
        for patch in [
            json!({"id":""}),
            json!({"id":"x".repeat(97)}),
            json!({"method":"x".repeat(81)}),
            json!({"args":vec![Value::Null;9]}),
        ] {
            let mut value = accepted.clone();
            for (k, v) in patch.as_object().unwrap() {
                value[k] = v.clone();
            }
            assert!(request(&serde_json::to_vec(&value).unwrap()).is_none());
        }
        assert!(request(b"{}").is_none());
        assert!(request(b"[]").is_none());
        assert!(request(b"not json").is_none());
    }
    #[test]
    fn state_barrier_waits_prior_requests_and_blocks_following_calls() {
        let queue = Arc::new(Queue::default());
        let first = queue.reserve("saveSettings");
        let barrier = queue.reserve("_state");
        let after = queue.reserve("listJobs");
        let (tx, rx) = mpsc::channel();
        let t = tx.clone();
        let worker = thread::spawn(move || {
            barrier.wait();
            t.send("barrier").unwrap();
            drop(barrier);
        });
        let later = thread::spawn(move || {
            after.wait();
            tx.send("after").unwrap();
        });
        assert!(rx.recv_timeout(Duration::from_millis(40)).is_err());
        drop(first);
        assert_eq!(rx.recv_timeout(Duration::from_secs(2)).unwrap(), "barrier");
        assert_eq!(rx.recv_timeout(Duration::from_secs(2)).unwrap(), "after");
        worker.join().unwrap();
        later.join().unwrap();
        queue.wait_all();
    }
    #[test]
    fn cancellation_bypasses_a_blocked_barrier() {
        let queue = Arc::new(Queue::default());
        let first = queue.reserve("list");
        let barrier = queue.reserve("_state");
        let control = queue.reserve("cancelList");
        let all = queue.reserve("_cancelListings");
        control.wait();
        all.wait();
        drop(control);
        drop(all);
        drop(first);
        barrier.wait();
        drop(barrier);
        queue.wait_all();
    }
}
