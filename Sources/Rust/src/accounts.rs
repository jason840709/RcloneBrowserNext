//! Transactional rclone questionnaire. Opaque state and credentials stay in native
//! memory; the renderer sees only sanitized questions and progress snapshots.
use crate::{
    Result,
    process::{self, Context, LineHandler},
};
use regex::Regex;
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::{
        Arc, Condvar, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::{Duration, Instant},
};
use unicode_segmentation::UnicodeSegmentation;
use uuid::Uuid;

const CONFIG_LIMIT: usize = 8 * 1024 * 1024;
const OUTPUT_LIMIT: usize = 32 * 1024 * 1024;

pub struct Accounts {
    session: Mutex<Option<Session>>,
    finished: Condvar,
}
struct Session {
    id: String,
    name: String,
    mode: String,
    provider: String,
    setup: String,
    batched: bool,
    use_shared_client: bool,
    auto_save: bool,
    fields: BTreeMap<String, String>,
    options: BTreeMap<String, Value>,
    option_prefix: String,
    advanced_visited: bool,
    answered: BTreeSet<String>,
    automatic_count: usize,
    needs_input_reason: String,
    context: Context,
    destination: Option<PathBuf>,
    staged: Option<PathBuf>,
    baseline: Option<Vec<u8>>,
    phase: String,
    question: Option<Value>,
    state: String,
    default_answer: String,
    step: u64,
    error: String,
    cancelled: Arc<AtomicBool>,
    workers: usize,
    auth_url: Option<String>,
    authorization_started: bool,
    secrets: Vec<String>,
    tested: bool,
}
fn redact_text(input: &str, secrets: &[String]) -> String {
    // Mask before truncating: a known credential can cross the public-output
    // boundary or itself be longer than the boundary. A partial match must not
    // escape merely because truncation removed the rest of the credential.
    let mut clean = input.to_owned();
    let mut secrets: Vec<_> = secrets.iter().filter(|s| !s.is_empty()).collect();
    secrets.sort_by_key(|s| std::cmp::Reverse(s.graphemes(true).count()));
    for secret in secrets {
        clean = clean.replace(secret, "••••");
    }
    clean.graphemes(true).take(8192).collect()
}

impl Session {
    fn snapshot(&self) -> Value {
        json!({"id":self.id,"name":self.name,"mode":self.mode,"phase":self.phase,"step":self.step,
            "question":self.question,"error":self.error,"provider":self.provider,"setup":self.setup,
            "autoSave":self.auto_save,"needsInputReason":self.needs_input_reason,
            "authorizationStarted":self.authorization_started,
            "configPath":self.destination.as_ref().map(|p|p.to_string_lossy().into_owned()).unwrap_or_default(),
            "canOpenBrowser":self.phase=="running" && self.auth_url.is_some() && !self.cancelled.load(Ordering::Acquire),"tested":self.tested})
    }
    fn active(&self) -> bool {
        !matches!(self.phase.as_str(), "committed" | "cancelled")
    }
    fn redact(&self, input: &str) -> String {
        redact_text(input, &self.secrets)
    }
    fn clear_private(&mut self) {
        self.secrets.clear();
        self.fields.clear();
        self.answered.clear();
        self.automatic_count = 0;
        self.state.clear();
        self.default_answer.clear();
        self.auth_url = None;
        self.context.environment.clear();
        self.baseline = None;
    }
    fn cleanup(&mut self) -> Result<()> {
        if let Some(staged) = &self.staged {
            for file in [
                staged.clone(),
                PathBuf::from(format!("{}.old", staged.display())),
            ] {
                match fs::remove_file(&file) {
                    Ok(()) => {}
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                    Err(e) => {
                        return Err(format!(
                            "Unable to remove the private staged configuration: {e}"
                        ));
                    }
                }
            }
        }
        self.staged = None;
        Ok(())
    }
    fn finish_cancelled(&mut self) -> Result<()> {
        let _ = self.cleanup();
        self.phase = "cancelled".into();
        self.question = None;
        self.needs_input_reason.clear();
        self.clear_private();
        Ok(())
    }
}
impl Accounts {
    pub fn new(_state_dir: PathBuf) -> Result<Arc<Self>> {
        // Staged configurations are created beside the explicitly selected
        // config only when a session starts; this constructor owns no disk path.
        Ok(Arc::new(Self {
            session: Mutex::new(None),
            finished: Condvar::new(),
        }))
    }
    fn with<T>(&self, id: &str, action: impl FnOnce(&mut Session) -> Result<T>) -> Result<T> {
        let mut guard = self
            .session
            .lock()
            .map_err(|_| "Account setup state is unavailable.")?;
        let s = guard
            .as_mut()
            .filter(|s| s.id == id)
            .ok_or("Account setup has expired. Open it again.")?;
        action(s)
    }
    pub fn has_active(&self) -> bool {
        self.session
            .lock()
            .map(|g| g.as_ref().is_some_and(Session::active))
            .unwrap_or(true)
    }
    pub fn authorization_url(&self) -> Result<String> {
        let guard = self
            .session
            .lock()
            .map_err(|_| "Account setup state is unavailable.")?;
        let s = guard.as_ref().ok_or("No browser sign-in is waiting.")?;
        if s.phase != "running" || s.cancelled.load(Ordering::Acquire) {
            return Err("No browser sign-in is waiting.".into());
        }
        s.auth_url
            .as_ref()
            .filter(|u| allowed_authorization(u))
            .cloned()
            .ok_or_else(|| "No browser sign-in is waiting.".into())
    }
    pub fn cancel_all(&self) -> Result<()> {
        let deadline = Instant::now() + Duration::from_secs(20);
        let mut guard = self
            .session
            .lock()
            .map_err(|_| "Account setup state is unavailable.")?;
        if let Some(s) = guard.as_mut().filter(|s| s.active()) {
            s.cancelled.store(true, Ordering::Release);
        }
        loop {
            let Some(s) = guard.as_mut().filter(|s| s.active()) else {
                return Ok(());
            };
            if s.workers == 0 {
                return s.finish_cancelled();
            }
            let wait = deadline.saturating_duration_since(Instant::now());
            if wait.is_zero() {
                return Err("Account setup has not stopped yet. Please try again.".into());
            }
            guard = self
                .finished
                .wait_timeout(guard, wait)
                .map_err(|_| "Account setup state is unavailable.")?
                .0;
        }
    }
    pub fn handle(self: &Arc<Self>, request: &Value, context: &Context) -> Result<Value> {
        let action = request["action"]
            .as_str()
            .ok_or("Invalid account request.")?;
        if action == "info" {
            return self.information(context);
        }
        if action == "start" {
            return self.start(request, context);
        }
        self.handle_session(request)
    }
    /// Continue the captured session without resolving the selected executable
    /// again. Poll/commit/cancel remain usable after that executable moves.
    pub fn handle_session(self: &Arc<Self>, request: &Value) -> Result<Value> {
        let action = request["action"]
            .as_str()
            .ok_or("Invalid account request.")?;
        let id = request["id"]
            .as_str()
            .ok_or("Account setup has expired. Open it again.")?
            .to_owned();
        match action {
            "poll" => self.with(&id, |s| Ok(s.snapshot())),
            "answer" => {
                let (option, answer, preserve, state) = self.with(&id, |s| {
                    if s.phase != "question" || request["step"].as_u64() != Some(s.step) {
                        return Err(
                            "This question has changed. Please use the current question.".into(),
                        );
                    }
                    let option = s
                        .question
                        .clone()
                        .ok_or("This question has changed. Please use the current question.")?;
                    let preserve = request["useDefault"] == true;
                    let answer = if preserve {
                        s.default_answer.clone()
                    } else {
                        request["value"].as_str().unwrap_or_default().to_owned()
                    };
                    validate_answer(&answer, &option)?;
                    let name = string(&option["Name"]);
                    if secret(&option) && !answer.is_empty() {
                        s.secrets.push(answer.clone());
                    }
                    if s.options.contains_key(&name) {
                        s.fields.remove(&name);
                    }
                    if name == "config_fs_advanced" && answer == "true" {
                        s.advanced_visited = true;
                    }
                    s.phase = "running".into();
                    s.error.clear();
                    s.auth_url = None;
                    s.needs_input_reason.clear();
                    s.answered.clear();
                    s.automatic_count = 0;
                    s.workers += 1;
                    Ok((option, answer, preserve, s.state.clone()))
                })?;
                self.launch(id.clone(), move |this, id| {
                    let name = string(&option["Name"]);
                    this.validate_types(
                        id,
                        &BTreeMap::from([(name.clone(), answer.clone())]),
                        &BTreeMap::from([(name, option.clone())]),
                    )?;
                    let prepared = this.prepared_answer(id, &answer, &option, preserve)?;
                    let remote = this.with(id, |s| Ok(s.name.clone()))?;
                    let raw = this.run_session(
                        id,
                        &[
                            "config",
                            "update",
                            &remote,
                            "--non-interactive",
                            "--continue",
                        ],
                        BTreeMap::from([
                            ("RCLONE_STATE".into(), state),
                            ("RCLONE_RESULT".into(), prepared),
                        ]),
                        true,
                        600,
                        None,
                    )?;
                    this.advance(id, raw)
                });
                self.with(&id, |s| Ok(s.snapshot()))
            }
            "test" => {
                self.with(&id, |s| {
                    if s.phase != "ready" {
                        return Err("Complete the questions before testing this account.".into());
                    }
                    if s.mode == "delete" {
                        return Err("This account is marked for removal.".into());
                    }
                    s.phase = "running".into();
                    s.error.clear();
                    s.workers += 1;
                    Ok(())
                })?;
                self.launch(id.clone(), move |this, id| {
                    let remote = this.with(id, |s| Ok(format!("{}:", s.name)))?;
                    let result = this.run_session(
                        id,
                        &["lsf", &remote, "--dirs-only", "--max-depth", "1"],
                        BTreeMap::new(),
                        false,
                        60,
                        None,
                    );
                    this.with(id, |s| {
                        s.tested = result.is_ok();
                        s.error = result.err().map(|e| s.redact(&e)).unwrap_or_default();
                        s.phase = "ready".into();
                        Ok(())
                    })
                });
                self.with(&id, |s| Ok(s.snapshot()))
            }
            "commit" => self.with(&id, |s| {
                commit(s)?;
                Ok(s.snapshot())
            }),
            "cancel" => self.with(&id, |s| {
                if !s.active() {
                    return Ok(s.snapshot());
                }
                s.cancelled.store(true, Ordering::Release);
                if s.workers == 0 {
                    s.finish_cancelled()?;
                }
                Ok(s.snapshot())
            }),
            _ => Err("Unsupported account action.".into()),
        }
    }
    fn launch(
        self: &Arc<Self>,
        id: String,
        action: impl FnOnce(&Arc<Self>, &str) -> Result<()> + Send + 'static,
    ) {
        let this = Arc::clone(self);
        thread::spawn(move || {
            let result = action(&this, &id);
            let _ = this.with(&id, |s| {
                s.workers = s.workers.saturating_sub(1);
                if s.cancelled.load(Ordering::Acquire) && s.workers == 0 {
                    if let Err(e) = s.finish_cancelled() {
                        s.phase = "error".into();
                        s.error = e;
                    }
                } else if let Err(e) = result {
                    s.error = s.redact(&e);
                    s.phase = "error".into();
                    s.auth_url = None;
                }
                Ok(())
            });
            this.finished.notify_all();
        });
    }
    fn information(&self, context: &Context) -> Result<Value> {
        if self.has_active() {
            return Err("Finish or cancel the current account setup first.".into());
        }
        let providers = run(
            context,
            &["config", "providers"],
            BTreeMap::new(),
            true,
            30,
            None,
            None,
            None,
        )?;
        let providers=providers.as_array().filter(|p|!p.is_empty()).ok_or("This rclone does not provide a supported configuration schema. Use config or update rclone.")?;
        let help = run(
            context,
            &["config", "create", "--help"],
            BTreeMap::new(),
            false,
            30,
            None,
            None,
            None,
        )?;
        let help = help.as_str().unwrap_or_default();
        if !["--all", "--non-interactive", "--continue"]
            .iter()
            .all(|s| help.contains(s))
        {
            return Err("Update rclone to use graphical account setup. Traditional config is still available.".into());
        }
        let paths = run(
            context,
            &["rc", "--loopback", "config/paths"],
            BTreeMap::new(),
            true,
            30,
            None,
            None,
            None,
        )?;
        let path = string(&paths["config"]);
        let encrypted = if crate::models::absolute_local(&path) {
            read_configuration(Path::new(&path))?.is_some_and(|b| {
                String::from_utf8_lossy(&b[..b.len().min(4096)])
                    .lines()
                    .any(|l| l.trim() == "RCLONE_ENCRYPT_V0:")
            })
        } else {
            false
        };
        let (remotes, requires_unlock) = match run(
            context,
            &["listremotes", "--json"],
            BTreeMap::new(),
            true,
            30,
            None,
            None,
            None,
        ) {
            Ok(v) => (v, false),
            Err(_) if encrypted => (json!([]), true),
            Err(e) => return Err(e),
        };
        Ok(
            json!({"providers":providers.iter().filter(|p|p["Hide"]!=true).map(|p|json!({"name":string(&p["Name"]),"description":string(&p["Description"]),"quickSetup":oauth_provider(&string(&p["Name"])),"options":visible_options(p).iter().map(sanitized_option).collect::<Vec<_>>()})).collect::<Vec<_>>(),
            "remotes":remotes.as_array().into_iter().flatten().map(|r|json!({"name":string(r.get("name").unwrap_or(&r["Name"])),"type":string(r.get("type").unwrap_or(&r["Type"]))})).collect::<Vec<_>>(),
            "configPath":path,"binary":context.binary,"requiresUnlock":requires_unlock}),
        )
    }
    fn start(self: &Arc<Self>, request: &Value, context: &Context) -> Result<Value> {
        let name = request["name"].as_str().unwrap_or_default().to_owned();
        let mode = request["mode"].as_str().unwrap_or("create").to_owned();
        let provider = request["provider"].as_str().unwrap_or_default().to_owned();
        if !valid_name(&name) || !["create", "edit", "delete"].contains(&mode.as_str()) {
            return Err("Choose a valid account name and action.".into());
        }
        let setup = request["setup"].as_str().unwrap_or("detailed").to_owned();
        if !["quick", "detailed"].contains(&setup.as_str()) {
            return Err("Choose quick or detailed account setup.".into());
        }
        let mut fields = BTreeMap::new();
        if let Some(raw) = request.get("fields") {
            for (k, v) in raw
                .as_object()
                .ok_or("Account fields must contain text values.")?
            {
                fields.insert(
                    k.clone(),
                    v.as_str()
                        .ok_or("Account fields must contain text values.")?
                        .to_owned(),
                );
            }
        }
        if fields.len() > 512 || fields.values().any(|v| v.len() > 16384 || v.contains('\0')) {
            return Err(
                "An account field is too long. Use a credential file for large credentials.".into(),
            );
        }
        let id = Uuid::new_v4().to_string();
        {
            let mut guard = self
                .session
                .lock()
                .map_err(|_| "Account setup state is unavailable.")?;
            if guard.as_ref().is_some_and(Session::active) {
                return Err("Account setup is already open.".into());
            }
            *guard = Some(Session {
                id: id.clone(),
                name,
                mode: mode.clone(),
                provider,
                setup,
                batched: request.get("setup").is_some() || request.get("fields").is_some(),
                use_shared_client: request["useSharedClient"] == true,
                auto_save: request["autoSave"] == true && mode == "create",
                fields,
                options: BTreeMap::new(),
                option_prefix: String::new(),
                advanced_visited: false,
                answered: BTreeSet::new(),
                automatic_count: 0,
                needs_input_reason: String::new(),
                context: context.clone(),
                destination: None,
                staged: None,
                baseline: None,
                phase: "running".into(),
                question: None,
                state: String::new(),
                default_answer: String::new(),
                step: 0,
                error: String::new(),
                cancelled: Arc::new(AtomicBool::new(false)),
                workers: 1,
                auth_url: None,
                authorization_started: false,
                secrets: vec![],
                tested: false,
            });
        }
        self.launch(id.clone(), |this, id| this.initialize(id));
        self.with(&id, |s| Ok(s.snapshot()))
    }
    fn initialize(self: &Arc<Self>, id: &str) -> Result<()> {
        let paths = self.run_session(
            id,
            &["rc", "--loopback", "config/paths"],
            BTreeMap::new(),
            true,
            30,
            None,
        )?;
        let path = paths["config"]
            .as_str()
            .filter(|p| crate::models::absolute_local(p))
            .ok_or("rclone did not return a writable configuration path.")?;
        let destination = PathBuf::from(crate::models::standardized(path)?);
        let original = read_configuration(&destination)?;
        let parent = destination
            .parent()
            .ok_or("rclone did not return a writable configuration path.")?;
        let mut builder = fs::DirBuilder::new();
        builder.recursive(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            builder.mode(0o700);
        }
        builder.create(parent).map_err(|e| e.to_string())?;
        let staged = parent.join(format!(".rbn-account-{id}.conf"));
        let mut file = create_exclusive(&staged)?;
        self.with(id, |s| {
            s.destination = Some(destination.clone());
            s.staged = Some(staged.clone());
            s.baseline = original.clone();
            Ok(())
        })?;
        file.write_all(original.as_deref().unwrap_or(&[]))
            .map_err(|e| e.to_string())?;
        drop(file);
        self.with(id, |s| {
            s.context.arguments = configuration_arguments(&s.context.arguments, &staged);
            s.context
                .environment
                .insert("RCLONE_AUTH_NO_OPEN_BROWSER".into(), "true".into());
            Ok(())
        })?;
        let existing = self.run_session(
            id,
            &["listremotes", "--json"],
            BTreeMap::new(),
            true,
            30,
            None,
        )?;
        let (name, mode, mut provider, batched) = self.with(id, |s| {
            Ok((
                s.name.clone(),
                s.mode.clone(),
                s.provider.clone(),
                s.batched,
            ))
        })?;
        let current = existing
            .as_array()
            .into_iter()
            .flatten()
            .find(|r| string(r.get("name").unwrap_or(&r["Name"])) == name);
        if current.is_some() != (mode != "create") {
            return Err(if current.is_some() {
                "That account name already exists."
            } else {
                "That account no longer exists."
            }
            .into());
        }
        if let Some(current) = current {
            let actual = string(current.get("type").unwrap_or(&current["Type"]));
            if batched && !provider.is_empty() && provider != actual {
                return Err("The account provider changed. Reopen the account form.".into());
            }
            provider = actual;
            self.with(id, |s| {
                s.provider = provider.clone();
                Ok(())
            })?;
        }
        if mode == "delete" {
            self.run_session(
                id,
                &["config", "delete", &name],
                BTreeMap::new(),
                false,
                600,
                None,
            )?;
            return self.with(id, |s| {
                s.phase = "ready".into();
                Ok(())
            });
        }
        let providers = self.run_session(
            id,
            &["config", "providers"],
            BTreeMap::new(),
            true,
            30,
            None,
        )?;
        let selected = providers
            .as_array()
            .into_iter()
            .flatten()
            .find(|p| p["Name"].as_str() == Some(&provider))
            .ok_or("Choose a provider supported by the selected rclone.")?;
        let options: BTreeMap<String, Value> =
            visible_options(selected)
                .into_iter()
                .fold(BTreeMap::new(), |mut options, option| {
                    options.entry(string(&option["Name"])).or_insert(option);
                    options
                });
        let fields = self.with(id, |s| Ok(s.fields.clone()))?;
        validate_fields(&fields, &options)?;
        self.with(id, |s| {
            s.options = options.clone();
            s.option_prefix = string(&selected["Prefix"]);
            for (k, v) in &fields {
                if !v.is_empty() && options.get(k).is_some_and(secret) {
                    s.secrets.push(v.clone());
                }
            }
            Ok(())
        })?;
        self.validate_types(id, &fields, &options)?;
        let args = if mode == "create" {
            vec![
                "config",
                "create",
                &name,
                &provider,
                "--non-interactive",
                "--all",
            ]
        } else {
            vec!["config", "update", &name, "--non-interactive", "--all"]
        };
        let raw = self.run_session(id, &args, BTreeMap::new(), true, 600, None)?;
        self.advance(id, raw)
    }
    fn advance(self: &Arc<Self>, id: &str, mut raw: Value) -> Result<()> {
        loop {
            let next=self.with(id,|s|{
                if s.cancelled.load(Ordering::Acquire){return Err("Account setup cancelled.".into());}
                accept(s,&raw)?;
                if !s.batched{return Ok(None);}
                if !s.error.is_empty(){if s.phase=="ready"{return Err(s.error.clone());}s.needs_input_reason="validation".into();return Ok(None);}
                if s.phase=="ready" {
                    if !s.fields.is_empty(){return Err("Some form fields do not apply to these provider settings. Reopen the form and review the provider-specific options.".into());}
                    if s.auto_save{commit(s)?;}
                    return Ok(None);
                }
                let option=raw["Option"].clone();
                if !option.is_object(){return Err("rclone returned an unsupported account question.".into());}
                let name=string(&option["Name"]);
                match decision(&option,&s.provider,&s.setup,&s.fields,&s.options,s.use_shared_client,s.advanced_visited) {
                    Decision::Pause(reason)=>{s.needs_input_reason=reason.into();Ok(None)},
                    Decision::Answer(answer)=>{
                        let limit=(s.options.len()*2+64).min(1024);
                        if !permit_progress(&mut s.answered,&mut s.automatic_count,&s.state,&name,&answer,limit){s.needs_input_reason="repeated-question".into();return Ok(None);}
                        let supplied=s.fields.remove(&name).is_some();
                        let preserve=!supplied&&answer==s.default_answer;
                        if secret(&option)&&!answer.is_empty(){s.secrets.push(answer.clone());}
                        if name=="config_fs_advanced"&&answer=="true"{s.advanced_visited=true;}
                        s.phase="running".into();s.question=None;s.needs_input_reason.clear();
                        Ok(Some((s.name.clone(),s.state.clone(),answer,option,preserve)))
                    }
                }
            })?;
            let Some((name, state, answer, option, preserve)) = next else {
                return Ok(());
            };
            let prepared = self.prepared_answer(id, &answer, &option, preserve)?;
            raw = self.run_session(
                id,
                &["config", "update", &name, "--non-interactive", "--continue"],
                BTreeMap::from([
                    ("RCLONE_STATE".into(), state),
                    ("RCLONE_RESULT".into(), prepared),
                ]),
                true,
                600,
                None,
            )?;
        }
    }
    fn prepared_answer(
        self: &Arc<Self>,
        id: &str,
        answer: &str,
        option: &Value,
        preserve: bool,
    ) -> Result<String> {
        if option["IsPassword"] != true || preserve || answer.is_empty() {
            return Ok(answer.to_owned());
        }
        if answer.contains(['\r', '\n']) {
            return Err("This password contains a line break. Use a credential file or the terminal config tool.".into());
        }
        let value = self.run_session(
            id,
            &["obscure", "-"],
            BTreeMap::new(),
            false,
            30,
            Some(answer.as_bytes()),
        )?;
        let encoded = value.as_str().unwrap_or_default().trim().to_owned();
        if encoded.is_empty() || encoded.contains(['\r', '\n']) {
            return Err(
                "rclone could not protect this password. Your original configuration is unchanged."
                    .into(),
            );
        }
        self.with(id, |s| {
            s.secrets.push(encoded.clone());
            Ok(())
        })?;
        Ok(encoded)
    }
    fn validate_types(
        self: &Arc<Self>,
        id: &str,
        fields: &BTreeMap<String, String>,
        options: &BTreeMap<String, Value>,
    ) -> Result<()> {
        let prefix = self.with(id, |s| Ok(s.option_prefix.clone()))?;
        let mut values = BTreeMap::new();
        for (name, value) in fields {
            let Some(option) = options.get(name) else {
                continue;
            };
            if value.is_empty()
                || secret(option)
                || option["Type"].as_str().is_none_or(|t| t == "string")
            {
                continue;
            }
            let prefix = if option["NoPrefix"] == true {
                String::new()
            } else {
                format!("{prefix}_")
            };
            values.insert(
                format!(
                    "RCLONE_{}",
                    format!("{prefix}{name}").to_uppercase().replace('-', "_")
                ),
                value.clone(),
            );
        }
        if !values.is_empty() {
            self.run_session(id,&["version"],values,false,30,None).map_err(|_|"An account field has an invalid value for its rclone type. Review number, size, duration, and true/false fields.".to_owned())?;
        }
        Ok(())
    }
    fn run_session(
        self: &Arc<Self>,
        id: &str,
        args: &[&str],
        extra: BTreeMap<String, String>,
        as_json: bool,
        timeout: u64,
        input: Option<&[u8]>,
    ) -> Result<Value> {
        let (context, cancel) = self.with(id, |s| Ok((s.context.clone(), s.cancelled.clone())))?;
        let this = Arc::clone(self);
        let owned_id = id.to_owned();
        let auth: Arc<dyn Fn(String) + Send + Sync> = Arc::new(move |value| {
            let _ = this.with(&owned_id, |s| {
                if !s.cancelled.load(Ordering::Acquire) {
                    s.auth_url = Some(value);
                    s.authorization_started = true;
                }
                Ok(())
            });
        });
        let result = run(
            &context,
            args,
            extra,
            as_json,
            timeout,
            Some(&cancel),
            input,
            Some(auth),
        );
        self.with(id, |s| {
            s.auth_url = None;
            if s.cancelled.load(Ordering::Acquire) {
                Err("Account setup cancelled.".into())
            } else {
                Ok(())
            }
        })?;
        result
    }
}

fn run(
    context: &Context,
    args: &[&str],
    extra: BTreeMap<String, String>,
    as_json: bool,
    timeout: u64,
    cancel: Option<&AtomicBool>,
    input: Option<&[u8]>,
    auth: Option<Arc<dyn Fn(String) + Send + Sync>>,
) -> Result<Value> {
    let mut context = context.clone();
    context.environment.extend(extra);
    let args: Vec<String> = ["--ask-password=false", "--log-level=NOTICE"]
        .into_iter()
        .chain(args.iter().copied())
        .map(str::to_owned)
        .collect();
    let mut captured = Vec::new();
    let output = if let Some(input) = input {
        let out=process::capture_input(&context,&args,input,OUTPUT_LIMIT,Duration::from_secs(timeout),cancel).map_err(|_|"rclone could not read the supplied credential. Your original configuration is unchanged.".to_owned())?;
        captured = out.stdout.clone();
        out
    } else {
        let buffer = Arc::new(Mutex::new((Vec::<u8>::new(), String::new())));
        let sink = buffer.clone();
        let expression =
            Regex::new(r#"http://(?:127\.0\.0\.1|localhost|\[::1\]):[0-9]+/auth\?[^\s<>\"']+"#)
                .expect("OAuth pattern");
        let handler: LineHandler = Arc::new(move |line, stderr, terminated| {
            let mut data = sink
                .lock()
                .map_err(|_| "rclone did not finish its response.")?;
            if stderr {
                data.1.push_str(line);
                if terminated {
                    data.1.push('\n');
                }
                if data.1.len() > 65536 {
                    let at = data
                        .1
                        .char_indices()
                        .map(|(i, _)| i)
                        .find(|i| *i >= data.1.len() - 65536)
                        .unwrap_or(0);
                    data.1.drain(..at);
                }
                if let Some(callback) = &auth {
                    if let Some(value) = expression
                        .find(&data.1)
                        .map(|m| m.as_str().to_owned())
                        .filter(|s| allowed_authorization(s))
                    {
                        callback(value);
                    }
                }
            } else {
                if data
                    .0
                    .len()
                    .saturating_add(line.len() + usize::from(terminated))
                    > OUTPUT_LIMIT
                {
                    return Err("Account setup timed out or returned too much output. Your original configuration is unchanged.".into());
                }
                data.0.extend_from_slice(line.as_bytes());
                if terminated {
                    data.0.push(b'\n');
                }
            }
            Ok(())
        });
        let out=process::run(&context,&args,OUTPUT_LIMIT,Some(Duration::from_secs(timeout)),cancel,Some(handler)).map_err(|_|"Account setup timed out or returned too much output. Your original configuration is unchanged.".to_owned())?;
        captured.extend_from_slice(
            &buffer
                .lock()
                .map_err(|_| "rclone did not finish its response.")?
                .0,
        );
        out
    };
    if output.exit_code != 0 {
        return Err(format!(
            "rclone could not complete this step (exit {}). Check the selected config path, unlock an encrypted config, or retry using config. Your original configuration is unchanged.",
            output.exit_code
        ));
    }
    if as_json {
        serde_json::from_slice(&captured).map_err(|_|"This rclone response is not supported JSON. Use config or update rclone; your original configuration is unchanged.".into())
    } else {
        Ok(json!(String::from_utf8_lossy(&captured)))
    }
}
fn permit_progress(
    answered: &mut BTreeSet<String>,
    count: &mut usize,
    state: &str,
    name: &str,
    answer: &str,
    limit: usize,
) -> bool {
    if *count >= limit || !answered.insert(format!("{state}\0{name}\0{answer}")) {
        return false;
    }
    *count += 1;
    true
}

fn configuration_arguments(arguments: &[String], staged: &Path) -> Vec<String> {
    let mut result = vec![];
    let mut skip = false;
    for arg in arguments {
        if skip {
            skip = false;
            continue;
        }
        if arg == "--config" {
            skip = true;
            continue;
        }
        if !arg.starts_with("--config=") {
            result.push(arg.clone());
        }
    }
    result.push(format!("--config={}", staged.display()));
    result
}
fn accept(s: &mut Session, raw: &Value) -> Result<()> {
    let state=raw["State"].as_str().ok_or("rclone returned an unsupported questionnaire. Use config; your original settings are unchanged.")?;
    s.state = state.to_owned();
    s.step += 1;
    s.error = s.redact(&string(&raw["Error"]));
    if state.is_empty() {
        s.phase = "ready".into();
        s.question = None;
        return Ok(());
    }
    let option = &raw["Option"];
    if option["Name"].as_str().is_none_or(str::is_empty) {
        return Err("The next rclone question is not supported. Use config; your original settings are unchanged.".into());
    }
    let mut display = option.clone();
    s.default_answer = fallback(option);
    let sensitive = secret(option);
    if sensitive && !s.default_answer.is_empty() {
        s.secrets.push(s.default_answer.clone());
    }
    let object=display.as_object_mut().ok_or("The next rclone question is not supported. Use config; your original settings are unchanged.")?;
    for key in ["Value", "ValueStr", "DefaultStr"] {
        object.remove(key);
    }
    object.insert(
        "Default".into(),
        json!(if sensitive { "" } else { &s.default_answer }),
    );
    object.insert("Sensitive".into(), json!(sensitive));
    object.insert(
        "HasSavedValue".into(),
        json!(sensitive && !s.default_answer.is_empty()),
    );
    object.insert("Help".into(), json!(s.redact(&string(&option["Help"]))));
    s.question = Some(display);
    s.phase = "question".into();
    Ok(())
}
fn commit(s: &mut Session) -> Result<()> {
    if s.phase != "ready" {
        return Err("Complete account setup before saving.".into());
    }
    let destination = s
        .destination
        .clone()
        .ok_or("Complete account setup before saving.")?;
    let staged = s
        .staged
        .as_ref()
        .ok_or("Complete account setup before saving.")?;
    if read_configuration(&destination)? != s.baseline {
        return Err("The configuration changed outside this window. Cancel and reopen account setup to avoid overwriting those changes.".into());
    }
    let data =
        read_configuration(staged)?.ok_or("The staged configuration is no longer available.")?;
    let replacement = destination
        .parent()
        .ok_or("Complete account setup before saving.")?
        .join(format!(".rbn-save-{}", Uuid::new_v4()));
    let result = (|| {
        let mut file = create_exclusive(&replacement)?;
        file.write_all(&data).map_err(|e| e.to_string())?;
        file.sync_all().map_err(|e| e.to_string())?;
        drop(file);
        if read_configuration(&destination)? != s.baseline {
            return Err(
                "The configuration changed while saving. Cancel and reopen account setup.".into(),
            );
        }
        replace_file(&replacement, &destination)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&replacement);
    }
    result?;
    // Match Swift's terminal state after the replacement has committed.
    let _ = s.cleanup();
    s.phase = "committed".into();
    s.question = None;
    s.needs_input_reason.clear();
    s.clear_private();

    Ok(())
}
pub(crate) fn create_exclusive(path: &Path) -> Result<File> {
    let mut o = OpenOptions::new();
    o.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        o.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    o.open(path).map_err(|e| e.to_string())
}
pub(crate) fn read_regular(path: &Path, maximum: usize) -> Result<Option<Vec<u8>>> {
    match fs::symlink_metadata(path) {
        Ok(m) if !m.is_file() => {
            return Err("逐檔記錄必須是一般檔案。".into());
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e.to_string()),
        _ => {}
    }
    let mut o = OpenOptions::new();
    o.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        o.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        o.custom_flags(0x00200000);
    }
    let file = o.open(path).map_err(|e| e.to_string())?;
    if !file.metadata().map_err(|e| e.to_string())?.is_file() {
        return Err("逐檔記錄必須是一般檔案。".into());
    }
    let mut bytes = Vec::new();
    file.take(maximum as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| e.to_string())?;
    if bytes.len() > maximum {
        return Err("The selected file exceeds the safety limit.".into());
    }
    Ok(Some(bytes))
}
fn read_configuration(path: &Path) -> Result<Option<Vec<u8>>> {
    read_regular(path, CONFIG_LIMIT).map_err(|e| {
        if e == "The selected file exceeds the safety limit." {
            "The configuration exceeds the 8 MiB safety limit.".into()
        } else {
            e
        }
    })
}
pub(crate) fn replace_file(from: &Path, to: &Path) -> Result<()> {
    #[cfg(not(windows))]
    {
        fs::rename(from, to).map_err(|e| e.to_string())
    }
    #[cfg(windows)]
    {
        let a = crate::storage::win32_wide(from);
        let b = crate::storage::win32_wide(to);
        // SAFETY: both strings are terminated and remain alive for this call.
        let success = unsafe {
            windows_sys::Win32::Storage::FileSystem::MoveFileExW(a.as_ptr(), b.as_ptr(), 0x1 | 0x8)
        };
        if success == 0 {
            Err(std::io::Error::last_os_error().to_string())
        } else {
            Ok(())
        }
    }
}
pub fn valid_name(value: &str) -> bool {
    !value.is_empty()
        && value.graphemes(true).count() <= 128
        && value == value.trim()
        && !value.starts_with('-')
        && !matches!(value, "." | "..")
        && !value
            .chars()
            .any(|c| (c as u32) < 32 || ":/\\[]".contains(c))
}
pub fn secret(option: &Value) -> bool {
    let name = string(&option["Name"]).to_lowercase();
    option["IsPassword"] == true
        || option["Sensitive"] == true
        || ["password", "secret", "token", "credential", "private_key"]
            .iter()
            .any(|s| name.contains(s))
}
pub fn string(value: &Value) -> String {
    match value {
        Value::Null => String::new(),
        Value::String(s) => s.clone(),
        v => v.to_string(),
    }
}
fn fallback(option: &Value) -> String {
    option["DefaultStr"]
        .as_str()
        .map(str::to_owned)
        .unwrap_or_else(|| string(&option["Default"]))
}
pub fn allowed_authorization(value: &str) -> bool {
    url::Url::parse(value).ok().is_some_and(|u| {
        u.scheme() == "http"
            && matches!(
                u.host_str(),
                Some("localhost" | "127.0.0.1" | "[::1]" | "::1")
            )
            && u.port().is_some_and(|p| p >= 1024)
            && u.path() == "/auth"
            && u.username().is_empty()
            && u.password().is_none()
            && u.query_pairs().any(|(k, v)| k == "state" && !v.is_empty())
    })
}
fn oauth_provider(provider: &str) -> bool {
    matches!(provider, "drive" | "onedrive" | "dropbox")
}
fn visible_options(provider: &Value) -> Vec<Value> {
    provider["Options"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|o| {
            o["Name"].as_str().is_some_and(|n| !n.is_empty())
                && o["Hide"].as_i64().unwrap_or(0) & 2 == 0
        })
        .cloned()
        .collect()
}
fn sanitized_option(option: &Value) -> Value {
    let mut v = option.clone();
    if let Some(o) = v.as_object_mut() {
        o.remove("Value");
        o.remove("ValueStr");
        if secret(option) {
            o.insert("Default".into(), json!(""));
            o.insert("DefaultStr".into(), json!(""));
            o.insert("Sensitive".into(), json!(true));
        }
    }
    v
}
fn validate_fields(
    fields: &BTreeMap<String, String>,
    options: &BTreeMap<String, Value>,
) -> Result<()> {
    if fields.len() > 512 || fields.values().map(String::len).sum::<usize>() > 512 * 1024 {
        return Err(
            "There are too many account fields. Use a credential file for large credentials."
                .into(),
        );
    }
    for (name, value) in fields {
        let option=options.get(name).ok_or("An account field is not supported by the selected rclone provider. Reload the account form.")?;
        if value.len() > 16384 || value.contains('\0') {
            return Err(
                "An account field is too long. Use a credential file for large credentials.".into(),
            );
        }
        if option["IsPassword"] == true && value.contains(['\r', '\n']) {
            return Err("This password contains a line break. Use a credential file or the terminal config tool.".into());
        }
    }
    Ok(())
}
fn validate_answer(answer: &str, option: &Value) -> Result<()> {
    if answer.len() > 16384 || answer.contains('\0') {
        return Err(
            "The answer is too long. Use a credential file or the terminal config tool.".into(),
        );
    }
    if option["Required"] == true && answer.is_empty() {
        return Err("This field is required.".into());
    }
    if option["Exclusive"] == true
        && option["Examples"].as_array().is_some_and(|choices| {
            !choices.is_empty() && !choices.iter().any(|c| string(&c["Value"]) == answer)
        })
    {
        return Err("Choose one of the listed values.".into());
    }
    Ok(())
}
#[derive(Debug, PartialEq, Eq)]
enum Decision {
    Answer(String),
    Pause(&'static str),
}
fn checked(value: String, option: &Value) -> Decision {
    if option["Required"] == true && value.is_empty() {
        Decision::Pause("additional-input")
    } else if option["Exclusive"] == true
        && option["Examples"]
            .as_array()
            .is_some_and(|a| !a.is_empty() && !a.iter().any(|c| string(&c["Value"]) == value))
    {
        Decision::Pause("provider-changed")
    } else {
        Decision::Answer(value)
    }
}
fn advertised(value: &str, option: &Value) -> Decision {
    if option["Examples"]
        .as_array()
        .is_some_and(|a| a.iter().any(|c| string(&c["Value"]) == value))
    {
        checked(value.into(), option)
    } else {
        Decision::Pause("provider-changed")
    }
}
fn decision(
    option: &Value,
    provider: &str,
    setup: &str,
    fields: &BTreeMap<String, String>,
    options: &BTreeMap<String, Value>,
    shared: bool,
    advanced: bool,
) -> Decision {
    let name = string(&option["Name"]);
    let default = fallback(option);
    if name == "config_fs_advanced" {
        return checked(
            (!advanced
                && fields
                    .keys()
                    .any(|k| options.get(k).is_some_and(|o| o["Advanced"] == true)))
            .to_string(),
            option,
        );
    }
    if let Some(schema) = options.get(&name) {
        if let Some(value) = fields.get(&name) {
            return checked(value.clone(), option);
        }
        if setup == "quick" && provider == "drive" && name == "scope" && default.is_empty() {
            return advertised("drive", option);
        }
        if option["Required"] == true && default.is_empty() {
            return Decision::Pause("additional-input");
        }
        if schema["Advanced"] == true && !advanced {
            return Decision::Pause("provider-changed");
        }
        return checked(default, option);
    }
    if !oauth_provider(provider) {
        return Decision::Pause("additional-input");
    }
    match name.as_str() {
        "config_shared_client_id" if provider == "drive" => checked(shared.to_string(), option),
        "config_is_local" => checked("true".into(), option),
        "config_change_team_drive" if provider == "drive" && setup == "quick" => {
            checked("false".into(), option)
        }
        "config_type" if provider == "onedrive" && setup == "quick" => {
            advertised("onedrive", option)
        }
        "config_driveid" if provider == "onedrive" && setup == "quick" => {
            if let Some(a) = option["Examples"].as_array().filter(|a| a.len() == 1) {
                checked(string(&a[0]["Value"]), option)
            } else {
                Decision::Pause("additional-input")
            }
        }
        "config_drive_ok" if provider == "onedrive" && setup == "quick" => {
            checked("true".into(), option)
        }
        _ => Decision::Pause("additional-input"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn account_names_reject_option_and_path_syntax() {
        for bad in [
            "",
            "../evil",
            "bad:name",
            "-option",
            "line\nbreak",
            "[remote]",
            " leading",
        ] {
            assert!(!valid_name(bad));
        }
        assert!(valid_name("測試-日本語"));
    }
    #[test]
    fn oauth_urls_are_native_loopback_endpoints() {
        for good in [
            "http://127.0.0.1:53682/auth?state=x",
            "http://localhost:5000/auth?state=123",
            "http://[::1]:5000/auth?state=x",
        ] {
            assert!(allowed_authorization(good));
        }
        for bad in [
            "https://example.com/auth?state=x",
            "http://127.0.0.1:80/auth?state=x",
            "http://user@localhost:5000/auth?state=x",
            "http://localhost:5000/admin?state=x",
            "http://localhost:5000/auth",
            "file:///tmp/a",
        ] {
            assert!(!allowed_authorization(bad));
        }
    }
    #[test]
    fn schema_scrubbing_removes_values_and_secrets() {
        let o = json!({"Name":"client_secret","Value":"native","ValueStr":"native","Default":"native","DefaultStr":"native"});
        let public = sanitized_option(&o).to_string();
        assert!(!public.contains("native"));
        let p =
            json!({"Options":[{"Name":"ok"},{"Name":"hidden","Hide":2},{"Name":"cli","Hide":3}]});
        assert_eq!(visible_options(&p).len(), 1);
    }
    #[test]
    fn quick_policy_never_guesses_unknown_or_multiple_accounts() {
        let empty = BTreeMap::<String, String>::new();
        let schema = BTreeMap::<String, Value>::new();
        assert_eq!(
            decision(
                &json!({"Name":"future_required","Required":true}),
                "drive",
                "quick",
                &empty,
                &schema,
                true,
                false
            ),
            Decision::Pause("additional-input")
        );
        assert_eq!(
            decision(
                &json!({"Name":"config_driveid","Examples":[{"Value":"a"},{"Value":"b"}]}),
                "onedrive",
                "quick",
                &empty,
                &schema,
                true,
                false
            ),
            Decision::Pause("additional-input")
        );
        assert_eq!(
            decision(
                &json!({"Name":"config_driveid","Examples":[{"Value":"only"}]}),
                "onedrive",
                "quick",
                &empty,
                &schema,
                true,
                false
            ),
            Decision::Answer("only".into())
        );
    }
    #[test]
    fn advanced_schema_is_entered_once() {
        let fields = BTreeMap::from([("description".into(), "text".into())]);
        let options = BTreeMap::from([("description".into(), json!({"Advanced":true}))]);
        let question = json!({"Name":"config_fs_advanced"});
        assert_eq!(
            decision(
                &question, "alias", "detailed", &fields, &options, false, false
            ),
            Decision::Answer("true".into())
        );
        assert_eq!(
            decision(
                &question, "alias", "detailed", &fields, &options, false, true
            ),
            Decision::Answer("false".into())
        );
    }
    #[test]
    fn unsupported_fields_and_newline_passwords_fail() {
        let options = BTreeMap::from([("pass".into(), json!({"IsPassword":true}))]);
        assert!(
            validate_fields(&BTreeMap::from([("pass".into(), "a\nb".into())]), &options).is_err()
        );
        assert!(
            validate_fields(&BTreeMap::from([("unknown".into(), "x".into())]), &options).is_err()
        );
    }
}

#[cfg(test)]
mod swift_golden_tests {
    use super::*;
    #[test]
    fn automatic_questionnaire_and_scrubbing_match_swift_0_11_0() {
        let golden: Value =
            serde_json::from_str(include_str!("../tests/fixtures/service-goldens.json")).unwrap();
        for case in golden["accountDecisions"].as_array().unwrap() {
            let input = &case["input"];
            let fields: BTreeMap<String, String> =
                serde_json::from_value(input["fields"].clone()).unwrap();
            let options: BTreeMap<String, Value> =
                serde_json::from_value(input["options"].clone()).unwrap();
            let actual = match decision(
                &input["option"],
                input["provider"].as_str().unwrap(),
                input["setup"].as_str().unwrap(),
                &fields,
                &options,
                input["shared"].as_bool().unwrap(),
                input["advanced"].as_bool().unwrap(),
            ) {
                Decision::Answer(a) => json!({"answer":a}),
                Decision::Pause(r) => json!({"pause":r}),
            };
            assert_eq!(actual, case["expected"], "Swift case {}", case["label"]);
        }
        for case in golden["sanitizedOptions"].as_array().unwrap() {
            assert_eq!(sanitized_option(&case["input"]), case["expected"]);
        }
        for case in golden["names"].as_array().unwrap() {
            assert_eq!(
                valid_name(case["input"].as_str().unwrap()),
                case["valid"].as_bool().unwrap(),
                "Swift name case {:?}",
                case["input"]
            );
        }
        for case in golden["authorization"].as_array().unwrap() {
            assert_eq!(
                allowed_authorization(case["input"].as_str().unwrap()),
                case["valid"].as_bool().unwrap(),
                "Swift OAuth case {:?}",
                case["input"]
            );
        }
    }
}

#[cfg(test)]
mod additional_swift_goldens {
    use super::*;
    #[test]
    fn field_limits_visibility_and_automatic_progress_match_swift() {
        let golden: Value =
            serde_json::from_str(include_str!("../tests/fixtures/service-goldens.json")).unwrap();
        for case in golden["fieldValidation"].as_array().unwrap() {
            let input = &case["input"];
            let mut fields: BTreeMap<String, String> =
                serde_json::from_value(input.get("fields").cloned().unwrap_or(json!({}))).unwrap();
            let mut options: BTreeMap<String, Value> =
                serde_json::from_value(input.get("options").cloned().unwrap_or(json!({}))).unwrap();
            match input["generator"].as_str() {
                Some("oversize-field") => {
                    fields.insert("field".into(), "a".repeat(16385));
                    options.insert("field".into(), json!({}));
                }
                Some("too-many-fields") => {
                    fields = (0..513)
                        .map(|i| (format!("field{i}"), String::new()))
                        .collect()
                }
                Some("total-byte-limit") => {
                    fields = (0..33)
                        .map(|i| (format!("field{i}"), "a".repeat(16384)))
                        .collect()
                }
                _ => {}
            }
            let actual = match validate_fields(&fields, &options) {
                Ok(()) => json!({"ok":true}),
                Err(e) => json!({"error":e}),
            };
            assert_eq!(
                actual, case["expected"],
                "Swift field case {}",
                input["label"]
            );
        }
        for case in golden["visibleOptions"].as_array().unwrap() {
            assert_eq!(json!(visible_options(&case["input"])), case["expected"]);
        }
        let mut answered = BTreeSet::new();
        let mut count = 0;
        for case in golden["automaticProgress"].as_array().unwrap() {
            let i = &case["input"];
            if i["reset"] == true {
                answered.clear();
                count = 0;
            }
            assert_eq!(
                permit_progress(
                    &mut answered,
                    &mut count,
                    i["state"].as_str().unwrap(),
                    i["name"].as_str().unwrap(),
                    i["answer"].as_str().unwrap(),
                    i["limit"].as_u64().unwrap() as usize
                ),
                case["expected"].as_bool().unwrap()
            );
        }
    }
}

#[cfg(test)]
mod privacy_regressions {
    use super::*;
    #[test]
    fn known_credentials_never_leak_across_the_public_error_limit() {
        let secret = "秘密".repeat(5000);
        let output = redact_text(
            &format!("credential={secret}"),
            std::slice::from_ref(&secret),
        );
        assert_eq!(output, "credential=••••");
        let secret = "fixture-boundary-secret".to_owned();
        let output = redact_text(&("x".repeat(8190) + &secret), std::slice::from_ref(&secret));
        assert!(!output.contains("fi"));
        assert!(output.graphemes(true).count() <= 8192);
        assert_eq!(
            redact_text(
                "provider rejected fixture-password",
                &["fixture-password".into()]
            ),
            "provider rejected ••••"
        );
    }
}

#[cfg(test)]
mod review_regressions {
    use super::*;
    #[test]
    fn constructor_does_not_create_unused_state_directories_or_change_parent_permissions() {
        let root = std::env::var_os("RBN_TEST_ROOT")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../.tmp/services-tests")
            })
            .join(format!("accounts-lazy-{}", Uuid::new_v4()));
        crate::storage::private_directory(&root).unwrap();
        fs::write(root.join("sentinel"), b"unchanged").unwrap();
        let before = fs::metadata(&root).unwrap().permissions();
        let unused = root.join("tmp/accounts");
        let accounts = Accounts::new(unused.clone()).unwrap();
        assert!(!accounts.has_active());
        assert!(!unused.exists());
        assert!(!root.join("tmp").exists());
        assert_eq!(fs::read_dir(&root).unwrap().count(), 1);
        assert_eq!(fs::read(root.join("sentinel")).unwrap(), b"unchanged");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(&root).unwrap().permissions().mode(),
                before.mode()
            );
        }
        #[cfg(not(unix))]
        assert_eq!(
            fs::metadata(&root).unwrap().permissions().readonly(),
            before.readonly()
        );
        assert_eq!(
            accounts.handle_session(&json!({})).unwrap_err(),
            "Invalid account request."
        );
        fs::remove_dir_all(root).unwrap();
    }
}
