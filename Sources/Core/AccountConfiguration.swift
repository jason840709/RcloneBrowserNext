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
        let provider: String
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
        var secrets = [String]()
        var tested = false
        var ownsMaintenance = true
        let worker = DispatchGroup()
        init(name: String, mode: String, provider: String, context: Context) {
            self.name = name; self.mode = mode; self.provider = provider; self.context = context
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
                s.phase = "running"; s.error = ""; s.authURL = nil
                let state = s.state
                launch(s) { try self.accept(self.run(s.context, ["config", "update", s.name, "--non-interactive", "--continue"], session: s,
                                                     extra: ["RCLONE_STATE": state, "RCLONE_RESULT": answer]), for: s) }
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
                guard s.phase == "ready", let destination = s.destination, let staged = s.staged else { throw failure("Finish account setup before saving.") }
                let current = try readConfiguration(destination)
                guard (current != nil) == s.baselineExisted, current == s.baseline else { throw failure("The configuration file changed in another program. Cancel and reopen account setup; no changes were saved.") }
                guard let content = try readConfiguration(staged) else { throw failure("The staged configuration is missing. No changes were saved.") }
                // The staging file is in the same directory, so relative credential
                // paths and RCLONE_CONFIG_DIR retain their original meaning.
                let output = destination.deletingLastPathComponent().appendingPathComponent(".rbn-save-" + UUID().uuidString)
                let handle = try EnginePlatform.createExclusiveFile(output)
                defer { try? handle.close(); try? fm.removeItem(at: output) }
                try handle.write(contentsOf: content); try handle.synchronize(); try handle.close()
                // Recheck immediately before the atomic replacement.
                guard try readConfiguration(destination) == current else { throw failure("The configuration changed while saving. No changes were saved.") }
                try EnginePlatform.replaceFile(output.path, destination.path)
                cleanup(s); s.phase = "committed"; s.question = nil; s.secrets.removeAll(); s.context.environment.removeAll()
                releaseMaintenance(s)
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
            let remotes = try run(c, ["listremotes", "--json"], timeout: 30) as? [[String: Any]] ?? []
            return ["providers": providers.filter { $0["Hide"] as? Bool != true }.map { p in
                ["name": Self.string(p["Name"]), "description": Self.string(p["Description"])]
            }, "remotes": remotes.map { ["name": Self.string($0["name"] ?? $0["Name"]), "type": Self.string($0["type"] ?? $0["Type"])] },
                    "configPath": paths["config"] ?? "", "binary": c.binary]
        }
    }

    private func start(_ request: [String: Any]) throws -> [String: Any] {
        try lock.holding {
            guard session == nil || ["committed", "cancelled"].contains(session!.phase) else { throw failure("Account setup is already open.") }
            let name = request["name"] as? String ?? "", mode = request["mode"] as? String ?? "create", provider = request["provider"] as? String ?? ""
            guard Self.validName(name), ["create", "edit", "delete"].contains(mode) else { throw failure("Choose a valid account name and action.") }
            let c = try context()
            try engine.setMaintenance(true)
            let s = Session(name: name, mode: mode, provider: provider, context: c)
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
                }
                let existing = try self.run(s.context, ["listremotes", "--json"], session: s) as? [[String: Any]] ?? []
                let present = existing.contains { Self.string($0["name"] ?? $0["Name"]) == name }
                guard present == (mode != "create") else { throw self.failure(present ? "That account name already exists." : "That account no longer exists.") }
                if mode == "delete" {
                    _ = try self.run(s.context, ["config", "delete", name], session: s, json: false)
                    self.lock.holding { s.phase = "ready" }; return
                }
                if mode == "create" {
                    let providers = try self.run(s.context, ["config", "providers"], session: s) as? [[String: Any]] ?? []
                    guard providers.contains(where: { $0["Name"] as? String == provider }) else { throw self.failure("Choose a provider supported by the selected rclone.") }
                }
                let args = mode == "create" ? ["config", "create", name, provider] : ["config", "update", name]
                try self.accept(self.run(s.context, args + ["--non-interactive", "--all"], session: s), for: s)
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
         "configPath": s.destination?.path ?? "", "canOpenBrowser": s.authURL != nil && !s.cancelled,
         "tested": s.tested]
    }
    private func cleanup(_ s: Session) {
        if let staged = s.staged {
            try? fm.removeItem(at: staged)
            try? fm.removeItem(atPath: staged.path + ".old")
        }
    }
    private func finishCancelled(_ s: Session) {
        cleanup(s); s.phase = "cancelled"; s.question = nil; s.secrets.removeAll(); s.context.environment.removeAll()
        releaseMaintenance(s)
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
                     extra: [String: String] = [:], json: Bool = true, timeout: TimeInterval = 600) throws -> Any {
        let process = Process(), out = Pipe(), err = Pipe()
        process.executableURL = URL(fileURLWithPath: context.binary)
        process.arguments = context.arguments + ["--ask-password=false", "--log-level=NOTICE"] + args
        process.environment = context.environment.merging(extra) { _, new in new }
        process.standardInput = FileHandle.nullDevice; process.standardOutput = out; process.standardError = err
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
                                if Self.allowedAuthorization(value) != nil { self.lock.holding { s.authURL = value } }
                            }
                        }
                    } catch { break }
                }
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
    private var exceeded = false, stopping = false
    func append(_ data: Data, standard: Bool) {
        lock.holding {
            if standard { if stdout.count + data.count <= 32 * 1024 * 1024 { stdout.append(data) } else { exceeded = true } }
            else { stderr.append(data); if stderr.count > 65536 { stderr.removeFirst(stderr.count - 65536) } }
        }
    }
    var output: Data { lock.holding { stdout } }
    var errorText: String { lock.holding { String(decoding: stderr, as: UTF8.self) } }
    var overflow: Bool { lock.holding { exceeded } }
    var stop: Bool { get { lock.holding { stopping } } set { lock.holding { stopping = newValue } } }
}
