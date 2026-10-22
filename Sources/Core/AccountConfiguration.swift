import Foundation

/// A transactional frontend to rclone's documented JSON config questionnaire.
/// No terminal prompt scraping, HTTP control server, or provider-specific OAuth
/// implementation. Answers travel in the child environment, never argv or logs.
final class RBNAccountConfiguration {
    private unowned let engine: RcloneEngine
    private let lock = NSRecursiveLock()
    private var session: Session?
    private let fm = FileManager.default
    private struct Context {
        let binary: String
        var arguments: [String]
        var environment: [String: String]
    }
    private final class Session {
        let id = UUID().uuidString
        let name: String
        let mode: String
        var provider: String
        let setup: String
        let batched: Bool
        let useSharedClient: Bool
        let autoSave: Bool
        var fields: [String: String]
        var options = [String: [String: Any]]()
        var optionPrefix = ""
        var advancedVisited = false
        var automaticProgress = AccountSetupPolicy.AutomaticProgress()
        var needsInputReason = ""
        var context: Context
        var destination: URL?
        var staged: URL?
        var baseline: Data?
        var baselineExisted = false
        var phase = "running"
        var question: [String: Any]?
        var state = ""
        var defaultAnswer = ""
        var step = 0
        var error = ""
        var cancelled = false
        var process: Process?
        var authURL: String?
        var authorizationStarted = false
        var secrets = [String]()
        var tested = false
        var ownsMaintenance = true
        let worker = DispatchGroup()
        init(name: String, mode: String, provider: String, context: Context,
             setup: String, batched: Bool, fields: [String: String],
             useSharedClient: Bool, autoSave: Bool) {
            self.name = name; self.mode = mode; self.provider = provider; self.context = context
            self.setup = setup; self.batched = batched; self.fields = fields
            self.useSharedClient = useSharedClient; self.autoSave = autoSave && mode == "create"
        }
    }
    init(engine: RcloneEngine) { self.engine = engine }

    func handle(_ raw: Any) throws -> Any {
        guard let request = raw as? [String: Any], let action = request["action"] as? String else { throw failure("Invalid account request.") }
        if action == "info" { return try information() }
        if action == "start" { return try start(request) }
        return try lock.holding {
            guard let s = session, request["id"] as? String == s.id else { throw failure("Account setup has expired. Open it again.") }
            switch action {
            case "poll": return snapshot(s)
            case "answer":
                guard s.phase == "question", request["step"] as? Int == s.step, let option = s.question else { throw failure("This question has changed. Please use the current question.") }
                let useDefault = request["useDefault"] as? Bool == true
                let answer = useDefault ? s.defaultAnswer : (request["value"] as? String ?? "")
                guard answer.utf8.count <= 16384, !answer.utf8.contains(0) else { throw failure("The answer is too long. Use a credential file or the terminal config tool.") }
                if option["Required"] as? Bool == true && answer.isEmpty { throw failure("This field is required.") }
                if option["Exclusive"] as? Bool == true, let choices = option["Examples"] as? [[String: Any]], !choices.isEmpty {
                    guard choices.contains(where: { Self.string($0["Value"]) == answer }) else { throw failure("Choose one of the listed values.") }
                }
                if Self.secret(option), !answer.isEmpty { s.secrets.append(answer) }
                if s.options[Self.string(option["Name"])] != nil {
                    let name = Self.string(option["Name"])
                    // The form value has now been applied or replaced by this
                    // explicit answer. Do not silently retry an invalid old value.
                    s.fields.removeValue(forKey: name)
                }
                if Self.string(option["Name"]) == "config_fs_advanced", answer == "true" { s.advancedVisited = true }
                s.phase = "running"; s.error = ""; s.authURL = nil; s.needsInputReason = ""
                s.automaticProgress.reset()
                let state = s.state
                launch(s) {
                    try self.validateTypes([Self.string(option["Name"]): answer], options: [Self.string(option["Name"]): option], session: s)
                    let value = try self.preparedAnswer(answer, option: option, preserveDefault: useDefault, session: s)
                    try self.advance(self.run(s.context, ["config", "update", s.name, "--non-interactive", "--continue"], session: s,
                                              extra: ["RCLONE_STATE": state, "RCLONE_RESULT": value]), for: s)
                }
                return snapshot(s)
            case "test":
                guard s.phase == "ready" else { throw failure("Complete the questions before testing this account.") }
                guard s.mode != "delete" else { throw failure("This account is marked for removal.") }
                s.phase = "running"; s.error = ""
                launch(s) {
                    do {
                        _ = try self.run(s.context, ["lsf", s.name + ":", "--dirs-only", "--max-depth", "1"], session: s, json: false, timeout: 60)
                        self.lock.holding { s.tested = true; s.phase = "ready" }
                    } catch {
                        self.lock.holding { s.error = self.redact(error.localizedDescription, s); s.tested = false; s.phase = "ready" }
                    }
                }
                return snapshot(s)
            case "commit":
                try commit(s)
                return snapshot(s)
            case "cancel":
                if ["committed", "cancelled"].contains(s.phase) { return snapshot(s) }
                s.cancelled = true
                if let process = s.process, process.isRunning { process.terminate() }
                if s.phase != "running" { finishCancelled(s) }
                return snapshot(s)
            default: throw failure("Unsupported account action.")
            }
        }
    }

    /// Only native hosts call this to reopen the URL captured from this rclone
    /// process. The renderer cannot provide an arbitrary localhost URL.
    func authorizationURL() throws -> URL {
        try lock.holding {
            guard let s = session, s.phase == "running", !s.cancelled,
                  let value = s.authURL, let url = Self.allowedAuthorization(value) else { throw failure("No browser sign-in is waiting.") }
            return url
        }
    }

    func shutdown() {
        let current = lock.holding { () -> Session? in
            guard let s = session, s.ownsMaintenance else { return nil }
            s.cancelled = true
            if let p = s.process, p.isRunning { p.terminate() }
            return s
        }
        if let s = current {
            _ = s.worker.wait(timeout: .now() + 5)
            lock.holding { if s.process == nil { finishCancelled(s) } }
        }
    }

    private func context() throws -> Context {
        let c = try engine.auxiliaryContext()
        return Context(binary: c.binary, arguments: c.arguments, environment: c.environment)
    }
    private func information() throws -> [String: Any] {
        guard lock.holding({ session == nil || ["committed", "cancelled"].contains(session!.phase) }) else { throw failure("Finish or cancel the current account setup first.") }
        return try engine.withAuxiliaryOperation {
            let c = try context()
            let providers = try run(c, ["config", "providers"], timeout: 30) as? [[String: Any]] ?? []
            guard !providers.isEmpty else { throw failure("This rclone does not provide a supported configuration schema. Use config or update rclone.") }
            let help = try run(c, ["config", "create", "--help"], json: false, timeout: 30) as? String ?? ""
            guard help.contains("--all"), help.contains("--non-interactive"), help.contains("--continue") else { throw failure("Update rclone to use graphical account setup. Traditional config is still available.") }
            let paths = try run(c, ["rc", "--loopback", "config/paths"], timeout: 30) as? [String: Any] ?? [:]
            let configPath = Self.string(paths["config"])
            let encrypted: Bool
            if EnginePlatform.absoluteLocalPath(configPath), let content = try readConfiguration(URL(fileURLWithPath: configPath)) {
                encrypted = String(decoding: content.prefix(4096), as: UTF8.self).split(whereSeparator: \.isNewline)
                    .contains { $0.trimmingCharacters(in: .whitespaces) == "RCLONE_ENCRYPT_V0:" }
            } else { encrypted = false }
            var requiresUnlock = false
            let remotes: [[String: Any]]
            do { remotes = try run(c, ["listremotes", "--json"], timeout: 30) as? [[String: Any]] ?? [] }
            catch {
                guard encrypted else { throw error }
                // Only an actual encrypted file that rclone cannot read offers
                // an unlock form. An unlocked encrypted file needs no password.
                requiresUnlock = true; remotes = []
            }
            return ["providers": providers.filter { $0["Hide"] as? Bool != true }.map { p in
                ["name": Self.string(p["Name"]), "description": Self.string(p["Description"]),
                 "quickSetup": AccountSetupPolicy.oauthProviders.contains(Self.string(p["Name"])),
                 "options": AccountSetupPolicy.visibleOptions(p).map(AccountSetupPolicy.sanitizedOption)] as [String: Any]
            }, "remotes": remotes.map { ["name": Self.string($0["name"] ?? $0["Name"]), "type": Self.string($0["type"] ?? $0["Type"])] },
                    "configPath": configPath, "binary": c.binary, "requiresUnlock": requiresUnlock]
        }
    }

    private func start(_ request: [String: Any]) throws -> [String: Any] {
        try lock.holding {
            guard session == nil || ["committed", "cancelled"].contains(session!.phase) else { throw failure("Account setup is already open.") }
            let name = request["name"] as? String ?? "", mode = request["mode"] as? String ?? "create", provider = request["provider"] as? String ?? ""
            guard Self.validName(name), ["create", "edit", "delete"].contains(mode) else { throw failure("Choose a valid account name and action.") }
            let setup = request["setup"] as? String ?? "detailed"
            guard ["quick", "detailed"].contains(setup) else { throw failure("Choose quick or detailed account setup.") }
            let fields: [String: String]
            if let rawFields = request["fields"] {
                guard let values = rawFields as? [String: String] else { throw failure("Account fields must contain text values.") }
                fields = values
            } else { fields = [:] }
            let batched = request["setup"] != nil || request["fields"] != nil
            let useSharedClient = request["useSharedClient"] as? Bool == true
            let autoSave = request["autoSave"] as? Bool == true
            guard fields.count <= 512, fields.values.allSatisfy({ $0.utf8.count <= 16384 && !$0.utf8.contains(0) }) else {
                throw failure("An account field is too long. Use a credential file for large credentials.")
            }
            let c = try context()
            try engine.setMaintenance(true)
            let s = Session(name: name, mode: mode, provider: provider, context: c,
                            setup: setup, batched: batched, fields: fields,
                            useSharedClient: useSharedClient, autoSave: autoSave)
            session = s
            launch(s) {
                let paths = try self.run(c, ["rc", "--loopback", "config/paths"], session: s) as? [String: Any] ?? [:]
                guard let path = paths["config"] as? String, EnginePlatform.absoluteLocalPath(path) else { throw self.failure("rclone did not return a writable configuration path.") }
                let destination = URL(fileURLWithPath: path).standardizedFileURL
                let original = try self.readConfiguration(destination)
                let parent = destination.deletingLastPathComponent()
                try self.fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let staged = parent.appendingPathComponent(".rbn-account-" + s.id + ".conf")
                let handle = try EnginePlatform.createExclusiveFile(staged)
                self.lock.holding { s.destination = destination; s.staged = staged; s.baseline = original; s.baselineExisted = original != nil }
                try handle.write(contentsOf: original ?? Data()); try handle.close()
                self.lock.holding {
                    s.context.arguments = c.arguments.filter { !$0.hasPrefix("--config=") } + ["--config=" + staged.path]
                    s.context.environment["RCLONE_AUTH_NO_OPEN_BROWSER"] = "true"
                }
                let existing = try self.run(s.context, ["listremotes", "--json"], session: s) as? [[String: Any]] ?? []
                let current = existing.first { Self.string($0["name"] ?? $0["Name"]) == name }
                let present = current != nil
                guard present == (mode != "create") else { throw self.failure(present ? "That account name already exists." : "That account no longer exists.") }
                if let current = current {
                    let actualProvider = Self.string(current["type"] ?? current["Type"])
                    guard !s.batched || provider.isEmpty || provider == actualProvider else { throw self.failure("The account provider changed. Reopen the account form.") }
                    self.lock.holding { s.provider = actualProvider }
                }
                if mode == "delete" {
                    _ = try self.run(s.context, ["config", "delete", name], session: s, json: false)
                    self.lock.holding { s.phase = "ready" }; return
                }
                let providers = try self.run(s.context, ["config", "providers"], session: s) as? [[String: Any]] ?? []
                guard let selected = providers.first(where: { $0["Name"] as? String == s.provider }) else {
                    throw self.failure("Choose a provider supported by the selected rclone.")
                }
                let options = Dictionary(AccountSetupPolicy.visibleOptions(selected).map { (Self.string($0["Name"]), $0) }, uniquingKeysWith: { first, _ in first })
                try AccountSetupPolicy.validateFields(fields, options: options)
                self.lock.holding {
                    s.options = options
                    s.optionPrefix = Self.string(selected["Prefix"])
                    for (key, value) in fields where Self.secret(options[key] ?? [:]) && !value.isEmpty { s.secrets.append(value) }
                }
                try self.validateTypes(fields, options: options, session: s)
                let args = mode == "create" ? ["config", "create", name, provider] : ["config", "update", name]
                try self.advance(self.run(s.context, args + ["--non-interactive", "--all"], session: s), for: s)
            }
            return snapshot(s)
        }
    }

    private func launch(_ s: Session, action: @escaping () throws -> Void) {
        s.worker.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { s.worker.leave() }
            do { try action() }
            catch { self.lock.holding { s.error = self.redact(error.localizedDescription, s); s.phase = "error" } }
            self.lock.holding { if s.cancelled { self.finishCancelled(s) } }
        }
    }

    /// rclone owns the questionnaire and its opaque state. Forms supply only
    /// advertised option values; reviewed profiles answer common OAuth choices.
    /// An unknown or repeated question always returns control to the user.
    private func advance(_ first: Any, for s: Session) throws {
        var raw = first
        while true {
            let next: (state: String, answer: String, option: [String: Any], preserveDefault: Bool)? = try lock.holding {
                if s.cancelled { throw failure("Account setup cancelled.") }
                try accept(raw, for: s)
                if !s.batched { return nil }
                guard s.error.isEmpty else {
                    if s.phase == "ready" { throw failure(s.error) }
                    s.needsInputReason = "validation"
                    return nil
                }
                if s.phase == "ready" {
                    // A provider-dependent option can disappear from the active
                    // questionnaire. Never claim that such form values saved.
                    guard s.fields.isEmpty else {
                        throw failure("Some form fields do not apply to these provider settings. Reopen the form and review the provider-specific options.")
                    }
                    if s.autoSave { try commit(s) }
                    return nil
                }
                guard let result = raw as? [String: Any], let option = result["Option"] as? [String: Any] else {
                    throw failure("rclone returned an unsupported account question.")
                }
                let name = Self.string(option["Name"])
                switch AccountSetupPolicy.decision(option: option, provider: s.provider, setup: s.setup,
                                                   fields: s.fields, options: s.options,
                                                   useSharedClient: s.useSharedClient, advancedVisited: s.advancedVisited) {
                case .pause(let reason):
                    s.needsInputReason = reason
                    return nil
                case .answer(let answer):
                    let limit = min(1024, s.options.count * 2 + 64)
                    guard s.automaticProgress.permit(state: s.state, name: name, answer: answer, limit: limit) else {
                        s.needsInputReason = "repeated-question"
                        return nil
                    }
                    let supplied = s.fields[name] != nil
                    let preserveDefault = !supplied && answer == s.defaultAnswer
                    if Self.secret(option), !answer.isEmpty { s.secrets.append(answer) }
                    if supplied {
                        s.fields.removeValue(forKey: name)
                    }
                    if name == "config_fs_advanced", answer == "true" { s.advancedVisited = true }
                    s.phase = "running"; s.question = nil; s.needsInputReason = ""
                    return (s.state, answer, option, preserveDefault)
                }
            }
            guard let next = next else { return }
            let answer = try preparedAnswer(next.answer, option: next.option, preserveDefault: next.preserveDefault, session: s)
            raw = try run(s.context, ["config", "update", s.name, "--non-interactive", "--continue"], session: s,
                          extra: ["RCLONE_STATE": next.state, "RCLONE_RESULT": answer])
        }
    }

    private func preparedAnswer(_ answer: String, option: [String: Any], preserveDefault: Bool, session s: Session) throws -> String {
        guard option["IsPassword"] as? Bool == true, !preserveDefault, !answer.isEmpty else { return answer }
        guard !answer.contains("\n"), !answer.contains("\r") else {
            throw failure("This password contains a line break. Use a credential file or the terminal config tool.")
        }
        // --all continuation stores IsPassword values as supplied. Unlike
        // key=value creation, --obscure does not transform these answers.
        // Existing defaults are already obscured and must not be encoded twice.
        let encoded = (try run(s.context, ["obscure", "-"], session: s, json: false,
                               timeout: 30, input: Data(answer.utf8)) as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !encoded.isEmpty, !encoded.contains("\n"), !encoded.contains("\r") else {
            throw failure("rclone could not protect this password. Your original configuration is unchanged.")
        }
        lock.holding { s.secrets.append(encoded) }
        return encoded
    }

    private func validateTypes(_ fields: [String: String], options: [String: [String: Any]], session s: Session) throws {
        var values = [String: String]()
        for (name, value) in fields {
            guard let option = options[name], !value.isEmpty,
                  !Self.secret(option), let type = option["Type"] as? String, type != "string" else { continue }
            let prefix = option["NoPrefix"] as? Bool == true ? "" : s.optionPrefix + "_"
            let key = "RCLONE_" + (prefix + name).uppercased().replacingOccurrences(of: "-", with: "_")
            values[key] = value
        }
        guard !values.isEmpty else { return }
        // --all continuation does not parse types. Let the same rclone option
        // parser validate typed, non-secret values without contacting a remote.
        // No diagnostic containing a submitted value is returned to the UI.
        do { _ = try run(s.context, ["version"], session: s, extra: values, json: false, timeout: 30) }
        catch { throw failure("An account field has an invalid value for its rclone type. Review number, size, duration, and true/false fields.") }
    }

    /// Both explicit Save and the create form's Login and Add use this single
    /// conflict-checked atomic replacement path.
    private func commit(_ s: Session) throws {
        guard s.phase == "ready", let destination = s.destination, let staged = s.staged else {
            throw failure("Complete account setup before saving.")
        }
        let current = try readConfiguration(destination)
        guard (current != nil) == s.baselineExisted, current == s.baseline else {
            throw failure("The configuration changed outside this window. Cancel and reopen account setup to avoid overwriting those changes.")
        }
        guard let data = try readConfiguration(staged) else { throw failure("The staged configuration is no longer available.") }
        let replacement = destination.deletingLastPathComponent().appendingPathComponent(".rbn-save-" + UUID().uuidString)
        let handle = try EnginePlatform.createExclusiveFile(replacement)
        defer { try? handle.close(); try? fm.removeItem(at: replacement) }
        try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
        let latest = try readConfiguration(destination)
        guard (latest != nil) == s.baselineExisted, latest == s.baseline else {
            throw failure("The configuration changed while saving. Cancel and reopen account setup.")
        }
        try EnginePlatform.replaceFile(replacement.path, destination.path)
        cleanup(s); s.phase = "committed"; s.question = nil; s.needsInputReason = ""
        clearPrivateValues(s)
        releaseMaintenance(s)
    }

    private func accept(_ raw: Any, for s: Session) throws {
        guard let result = raw as? [String: Any], let state = result["State"] as? String else { throw failure("rclone returned an unsupported questionnaire. Use config; your original settings are unchanged.") }
        try lock.holding {
            s.state = state; s.step += 1; s.error = redact(Self.string(result["Error"]), s)
            if state.isEmpty { s.phase = "ready"; s.question = nil; return }
            guard let option = result["Option"] as? [String: Any], let name = option["Name"] as? String, !name.isEmpty else { throw failure("The next rclone question is not supported. Use config; your original settings are unchanged.") }
            var display = option
            s.defaultAnswer = option["DefaultStr"] as? String ?? Self.string(option["Default"])
            let sensitive = Self.secret(option)
            if sensitive, !s.defaultAnswer.isEmpty { s.secrets.append(s.defaultAnswer) }
            // ValueStr and Value can disclose existing passwords or OAuth tokens.
            display.removeValue(forKey: "Value"); display.removeValue(forKey: "ValueStr")
            display.removeValue(forKey: "DefaultStr"); display["Default"] = sensitive ? "" : s.defaultAnswer
            display["Sensitive"] = sensitive; display["HasSavedValue"] = sensitive && !s.defaultAnswer.isEmpty
            display["Help"] = redact(Self.string(option["Help"]), s)
            s.question = display; s.phase = "question"
        }
    }

    private func snapshot(_ s: Session) -> [String: Any] {
        ["id": s.id, "name": s.name, "mode": s.mode, "phase": s.phase, "step": s.step,
         "question": s.question as Any? ?? NSNull(), "error": s.error,
         "provider": s.provider, "setup": s.setup, "autoSave": s.autoSave,
         "needsInputReason": s.needsInputReason, "authorizationStarted": s.authorizationStarted,
         "configPath": s.destination?.path ?? "", "canOpenBrowser": s.phase == "running" && s.authURL != nil && !s.cancelled,
         "tested": s.tested]
    }
    private func cleanup(_ s: Session) {
        if let staged = s.staged {
            try? fm.removeItem(at: staged)
            try? fm.removeItem(atPath: staged.path + ".old")
        }
    }
    private func finishCancelled(_ s: Session) {
        cleanup(s); s.phase = "cancelled"; s.question = nil; s.needsInputReason = ""
        clearPrivateValues(s)
        releaseMaintenance(s)
    }
    private func clearPrivateValues(_ s: Session) {
        s.secrets.removeAll(); s.fields.removeAll(); s.automaticProgress.reset()
        s.defaultAnswer = ""; s.state = ""; s.authURL = nil
        s.context.environment.removeAll()
    }
    private func releaseMaintenance(_ s: Session) {
        if s.ownsMaintenance { s.ownsMaintenance = false; try? engine.setMaintenance(false) }
    }
    private func readConfiguration(_ url: URL) throws -> Data? {
        guard let handle = try EnginePlatform.readRegularFile(url) else { return nil }
        defer { try? handle.close() }
        let limit = 8 * 1024 * 1024
        var data = Data()
        while let chunk = try handle.read(upToCount: min(65536, limit + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            if data.count > limit { break }
        }
        guard data.count <= limit else { throw failure("The configuration exceeds the 8 MiB safety limit.") }
        return data
    }

    static func validName(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && value == value.trimmingCharacters(in: .whitespacesAndNewlines) &&
        !value.hasPrefix("-") && ![".", ".."].contains(value) && !value.unicodeScalars.contains { $0.value < 32 || ":/\\[]".unicodeScalars.contains($0) }
    }
    static func secret(_ option: [String: Any]) -> Bool {
        let name = Self.string(option["Name"]).lowercased()
        return option["IsPassword"] as? Bool == true || option["Sensitive"] as? Bool == true ||
            ["password", "secret", "token", "credential", "private_key"].contains { name.contains($0) }
    }
    static func string(_ value: Any?) -> String {
        guard let value = value, !(value is NSNull) else { return "" }
        if let s = value as? String { return s }
        if let n = value as? NSNumber {
            if EngineJSON.isBoolean(n) { return n.boolValue ? "true" : "false" }
            return n.stringValue
        }
        return String(describing: value)
    }
    static func allowedAuthorization(_ value: String) -> URL? {
        guard let u = URL(string: value), u.scheme == "http", ["localhost", "127.0.0.1", "[::1]", "::1"].contains(u.host ?? ""),
              let port = u.port, (1024...65535).contains(port), u.path == "/auth", u.user == nil, u.password == nil,
              URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "state" && !($0.value ?? "").isEmpty }) == true else { return nil }
        return u
    }
    private func redact(_ text: String, _ s: Session?) -> String {
        var clean = String(text.prefix(8192))
        for secret in (s?.secrets ?? []).filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) { clean = clean.replacingOccurrences(of: secret, with: "••••") }
        return clean
    }
    private func failure(_ text: String) -> EngineError { EngineError(text) }

    /// Bounded, cancellable child with concurrent pipe drains. Raw output and
    /// answers are never persisted. Standard input cannot fall back to a TTY.
    private func run(_ context: Context, _ args: [String], session s: Session? = nil,
                     extra: [String: String] = [:], json: Bool = true, timeout: TimeInterval = 600,
                     input: Data? = nil) throws -> Any {
        let process = Process(), out = Pipe(), err = Pipe()
        let stdin = input == nil ? nil : Pipe()
        process.executableURL = URL(fileURLWithPath: context.binary)
        process.arguments = context.arguments + ["--ask-password=false", "--log-level=NOTICE"] + args
        process.environment = context.environment.merging(extra) { _, new in new }
        process.standardInput = stdin as Any? ?? FileHandle.nullDevice; process.standardOutput = out; process.standardError = err
        let buffer = AccountOutput(), drains = DispatchGroup()
        try lock.holding {
            if s?.cancelled == true { throw failure("Account setup cancelled.") }
            try EnginePlatform.prepare(process); try process.run(); s?.process = process
        }
        for (pipe, standard) in [(out, true), (err, false)] {
            try? pipe.fileHandleForWriting.close(); drains.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { try? pipe.fileHandleForReading.close(); drains.leave() }
                while !buffer.stop {
                    do {
                        guard try EnginePlatform.waitReadable(pipe.fileHandleForReading) else { continue }
                        let data = try EnginePlatform.readAvailable(pipe.fileHandleForReading)
                        if data.isEmpty { break }
                        buffer.append(data, standard: standard)
                        if !standard, let s = s {
                            let text = buffer.errorText
                            if let expression = try? NSRegularExpression(pattern: #"http://(?:127\.0\.0\.1|localhost|\[::1\]):[0-9]+/auth\?[^\s<>\"']+"#),
                               let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range, in: text) {
                                let value = String(text[range])
                                if Self.allowedAuthorization(value) != nil {
                                    self.lock.holding { s.authURL = value; s.authorizationStarted = true }
                                }
                            }
                        }
                    } catch { break }
                }
            }
        }
        if let stdin = stdin, let input = input {
            try? stdin.fileHandleForReading.close()
            drains.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { try? stdin.fileHandleForWriting.close(); drains.leave() }
                do { try stdin.fileHandleForWriting.write(contentsOf: input) }
                catch { buffer.inputFailed = true }
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        var stoppedAt: Date?
        while process.isRunning {
            if Date() > deadline || lock.holding({ s?.cancelled == true }) || buffer.overflow {
                if stoppedAt == nil { process.terminate(); stoppedAt = Date() }
                else if Date().timeIntervalSince(stoppedAt!) > 2 { EnginePlatform.signal(process.processIdentifier, 9) }
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
        process.waitUntilExit()
        let drained = drains.wait(timeout: .now() + 3) == .success
        if !drained { buffer.stop = true; _ = drains.wait(timeout: .now() + 1) }
        lock.holding { s?.process = nil; s?.authURL = nil }
        if lock.holding({ s?.cancelled == true }) { throw failure("Account setup cancelled.") }
        if stoppedAt != nil { throw failure("Account setup timed out or returned too much output. Your original configuration is unchanged.") }
        guard drained, !buffer.overflow else { throw failure("rclone did not finish its response.") }
        guard !buffer.inputFailed else { throw failure("rclone could not read the supplied credential. Your original configuration is unchanged.") }
        guard process.terminationStatus == 0 else {
            // Do not echo arbitrary subprocess diagnostics: providers may include
            // password values or tokens in errors. Question errors are redacted.
            throw failure("rclone could not complete this step (exit \(process.terminationStatus)). Check the selected config path, unlock an encrypted config, or retry using config. Your original configuration is unchanged.")
        }
        if !json { return String(decoding: buffer.output, as: UTF8.self) }
        do { return try JSONSerialization.jsonObject(with: buffer.output) }
        catch { throw failure("This rclone response is not supported JSON. Use config or update rclone; your original configuration is unchanged.") }
    }
}

private final class AccountOutput {
    private let lock = NSLock()
    private var stdout = Data(), stderr = Data()
    private var exceeded = false, stopping = false, failedInput = false
    func append(_ data: Data, standard: Bool) {
        lock.holding {
            if standard { if stdout.count + data.count <= 32 * 1024 * 1024 { stdout.append(data) } else { exceeded = true } }
            else { stderr.append(data); if stderr.count > 65536 { stderr.removeFirst(stderr.count - 65536) } }
        }
    }
    var output: Data { lock.holding { stdout } }
    var errorText: String { lock.holding { String(decoding: stderr, as: UTF8.self) } }
    var overflow: Bool { lock.holding { exceeded } }
    var inputFailed: Bool { get { lock.holding { failedInput } } set { lock.holding { failedInput = newValue } } }
    var stop: Bool { get { lock.holding { stopping } } set { lock.holding { stopping = newValue } } }
}
