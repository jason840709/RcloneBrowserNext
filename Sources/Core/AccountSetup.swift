import Foundation
import CoreFoundation
#if canImport(Darwin)
import Darwin
#elseif os(Windows)
import ucrt
#else
import Glibc
#endif

/// Drives rclone's documented JSON configuration protocol, not terminal text.
/// Writes are staged beside the selected config and committed only after Save.
final class RBNAccountSetup {
    typealias Context = RcloneTools.Context
    private final class Session {
        let id = UUID().uuidString
        let name: String
        let mode: String
        let context: Context
        var provider: String
        var phase = "working"
        var step = 0
        var state = ""
        var option: [String: Any]?
        var error = ""
        var authURL: String?
        var cancelled = false
        var child: Process?
        var original: URL?
        var baseline: Data?
        var staged: URL?
        var secrets = [String]()
        init(name: String, mode: String, provider: String, context: Context) {
            self.name = name; self.mode = mode; self.provider = provider; self.context = context
        }
    }
    private let lock = NSRecursiveLock()
    private let worker = DispatchQueue(label: "RcloneBrowser.account-setup", qos: .userInitiated)
    private var session: Session?
    private var lastResult: [String: Any] = [:]
    var onFinish: ((Bool) -> Void)?
    var isOpen: Bool { lock.holding { session != nil } }

    func catalog(context: Context) throws -> [String: Any] {
        let help = try run(context, ["config", "create", "--help"], timeout: 20).output
        let text = String(decoding: help, as: UTF8.self)
        guard ["--non-interactive", "--continue", "--all"].allSatisfy(text.contains) else {
            throw EngineError("此 rclone 不支援圖形設定所需的 JSON 流程。請更新 rclone，或使用旁邊的 config。")
        }
        let registered = try rpc(context, "config/providers")
        guard let providers = registered["providers"] as? [[String: Any]], !providers.isEmpty else {
            throw EngineError("rclone 未回傳可辨識的服務清單。原有設定未變更，可改用 config。")
        }
        let items = providers.compactMap { p -> [String: Any]? in
            guard let name = p["Name"] as? String, let description = p["Description"] as? String else { return nil }
            return ["name": name, "description": description]
        }
        let remotes = try remoteList(context)
        let paths = try rpc(context, "config/paths")
        return ["providers": items, "remotes": remotes, "configPath": paths["config"] as? String ?? ""]
    }
    func begin(_ input: [String: Any], context: Context) throws -> [String: Any] {
        let name = try EngineJSON.text(input["name"], "帳號名稱", maximum: 128)
        let mode = input["mode"] as? String ?? "create"
        guard ["create", "edit", "delete"].contains(mode), !name.isEmpty,
              name.rangeOfCharacter(from: CharacterSet(charactersIn: ":/\\[]").union(.controlCharacters)) == nil,
              !name.hasPrefix("-"), name == name.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw EngineError("帳號名稱不可空白，也不能包含冒號、斜線、方括號或控制字元。")
        }
        let s = Session(name: name, mode: mode, provider: input["provider"] as? String ?? "", context: context)
        try lock.holding {
            guard session == nil else { throw EngineError("請先完成或取消目前的帳號設定。") }
            session = s; lastResult = [:]
        }
        worker.async { [self] in
            do {
                let catalog = try self.catalog(context: context)
                try self.ensureLive(s)
                let remotes = catalog["remotes"] as? [[String: Any]] ?? []
                let existing = remotes.first { $0["name"] as? String == name }
                if mode == "create" {
                    guard existing == nil else { throw EngineError("已有同名帳號，請換一個名稱，或回到清單編輯原帳號。") }
                    guard (catalog["providers"] as? [[String: Any]] ?? []).contains(where: { $0["name"] as? String == s.provider }) else {
                        throw EngineError("目前的 rclone 不支援這個服務。請重新讀取服務清單。")
                    }
                } else {
                    guard let existing, let type = existing["type"] as? String else { throw EngineError("找不到要編輯的帳號，請重新整理。") }
                    self.lock.holding { s.provider = type }
                }
                guard let path = catalog["configPath"] as? String, EnginePlatform.absoluteLocalPath(path) else {
                    throw EngineError("無法確認 rclone 設定檔的位置。請先在設定中指定設定檔。")
                }
                let original = URL(fileURLWithPath: path).standardizedFileURL
                let parent = original.deletingLastPathComponent()
                let baseline = try Self.readConfig(original)
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: EnginePlatform.permissions(0o700))
                let staged = parent.appendingPathComponent(".rbn-account-\(s.id).conf")
                let handle = try EnginePlatform.createExclusiveFile(staged)
                self.lock.holding { s.original = original; s.baseline = baseline; s.staged = staged }
                do { try handle.write(contentsOf: baseline ?? Data()); try handle.close() }
                catch { try? handle.close(); throw error }
                try self.ensureLive(s)
                if mode == "delete" {
                    let result = try self.run(self.stagedContext(s), ["config", "delete", name], session: s, timeout: 30)
                    guard result.code == 0 else { throw EngineError("無法移除這個帳號設定。") }
                    self.lock.holding { s.phase = "ready"; s.step += 1 }
                } else {
                    let output = try self.configure(s)
                    try self.accept(output, session: s)
                }
            } catch { self.failed(error, session: s) }
        }
        return snapshot(s)
    }
    func status(_ id: String) throws -> [String: Any] {
        try lock.holding {
            if let s = session, s.id == id { return snapshot(s) }
            if lastResult["id"] as? String == id { return lastResult }
            throw EngineError("帳號設定已結束，請重新開啟。")
        }
    }
    func answer(_ id: String, step: Int, value: String?, useDefault: Bool) throws -> [String: Any] {
        let (s, result): (Session, String) = try lock.holding {
            guard let s = session, s.id == id, s.phase == "question", s.step == step, let option = s.option else {
                throw EngineError("設定步驟已變更，請依目前畫面繼續。")
            }
            let result = useDefault ? Self.string(option["Default"]) : (value ?? "")
            guard result.utf8.count <= 64 * 1024, !result.contains("\0") else { throw EngineError("輸入值過長或含有無效字元。") }
            if option["Required"] as? Bool == true && result.isEmpty { throw EngineError("這個欄位是必填，請輸入值後繼續。") }
            if option["Exclusive"] as? Bool == true {
                let examples = option["Examples"] as? [[String: Any]] ?? []
                guard examples.contains(where: { Self.string($0["Value"]) == result }) else { throw EngineError("請選擇 rclone 提供的其中一個選項。") }
            }
            if Self.isSecret(option), !result.isEmpty { s.secrets.append(result) }
            s.phase = "working"; s.authURL = nil; s.error = ""
            return (s, result)
        }
        worker.async { [self] in
            do {
                let output = try self.configure(s, answer: result)
                try self.accept(output, session: s)
            } catch { self.failed(error, session: s) }
        }
        return snapshot(s)
    }
    func commit(_ id: String) throws -> [String: Any] {
        let s: Session = try lock.holding {
            guard let s = session, s.id == id, s.phase == "ready", !s.cancelled else { throw EngineError("帳號尚未設定完成，無法儲存。") }
            s.phase = "saving"; return s
        }
        do {
            guard let original = s.original, let staged = s.staged else { throw EngineError("缺少暫存設定檔。") }
            guard try Self.readConfig(original) == s.baseline else {
                throw EngineError("設定期間原始檔案已被其他程式變更。為了保留那些變更，這次不覆寫；請取消後重新設定。")
            }
            guard let data = try Self.readConfig(staged), data.count <= Self.limit else { throw EngineError("暫存設定檔無法讀取。") }
            try EnginePlatform.replaceFile(staged.path, original.path)
            let result = ["id": s.id, "phase": "saved", "name": s.name, "mode": s.mode, "step": s.step] as [String: Any]
            finish(s, result: result, saved: true)
            return result
        } catch {
            lock.holding { s.phase = "ready"; s.error = sanitized(error.localizedDescription, s) }
            throw EngineError(sanitized(error.localizedDescription, s))
        }
    }
    @discardableResult func cancel(_ id: String) throws -> [String: Any] {
        let s: Session? = try lock.holding {
            guard let s = session else {
                if lastResult["id"] as? String == id { return nil }
                throw EngineError("帳號設定已結束，請重新開啟。")
            }
            guard s.id == id, s.phase != "saving" else { throw EngineError("設定正在儲存，請稍候。") }
            s.cancelled = true; s.phase = "cancelling"
            if let p = s.child, p.isRunning { _ = EnginePlatform.signal(p.processIdentifier, SIGTERM) }
            return s
        }
        guard let s else { return lock.holding { lastResult } }
        worker.async { [self] in finishCancelled(s) }
        return snapshot(s)
    }
    func browserURL(_ id: String) throws -> URL {
        try lock.holding {
            guard let s = session, s.id == id, s.phase == "working", !s.cancelled,
                  let raw = s.authURL, let url = URL(string: raw), Self.permittedAuthURL(url) else {
                throw EngineError("目前沒有可重新開啟的登入頁面。請依畫面上的設定步驟繼續。")
            }
            return url
        }
    }
    static func permittedAuthURL(_ url: URL) -> Bool {
        url.scheme == "http" && ["127.0.0.1", "localhost", "[::1]", "::1"].contains(url.host ?? "") &&
        url.user == nil && url.password == nil && url.fragment == nil && url.path == "/auth" &&
        (1...65535).contains(url.port ?? 0)
    }
    private static let limit = 8 * 1024 * 1024
    private static func readConfig(_ path: URL) throws -> Data? {
        guard let handle = try EnginePlatform.readRegularFile(path) else { return nil }
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw EngineError("設定檔超過 8 MiB，請改用 config。") }
        return data
    }
    private func remoteList(_ context: Context) throws -> [[String: Any]] {
        let output = try run(context, ["listremotes", "--json"], timeout: 30)
        guard output.code == 0, let list = try JSONSerialization.jsonObject(with: output.output) as? [[String: Any]] else {
            throw EngineError("無法讀取帳號清單。設定檔若已加密，請先到設定解鎖。")
        }
        return list.compactMap { item in
            guard let name = item["name"] as? String, let type = item["type"] as? String else { return nil }
            return ["name": name, "type": type]
        }
    }
    private func stagedContext(_ s: Session) throws -> Context {
        try ensureLive(s)
        guard let staged = s.staged else { throw EngineError("缺少暫存設定檔。") }
        return Context(binary: s.context.binary, arguments: s.context.arguments.filter { !$0.hasPrefix("--config=") } + ["--config=\(staged.path)"], environment: s.context.environment)
    }
    private func snapshot(_ s: Session) -> [String: Any] {
        lock.holding {
            var result: [String: Any] = ["id": s.id, "name": s.name, "provider": s.provider, "mode": s.mode,
                "phase": s.phase, "step": s.step, "error": s.error, "canOpenBrowser": s.authURL != nil]
            if s.phase == "question", let raw = s.option {
                var option = raw.filter { ["Name", "Help", "Type", "Default", "Required", "Exclusive", "Examples", "IsPassword"].contains($0.key) }
                option["hasDefault"] = !Self.string(option["Default"]).isEmpty
                if Self.isSecret(option) { option["Default"] = ""; option["IsPassword"] = true }
                result["option"] = option
            }
            return result
        }
    }
    private func accept(_ output: [String: Any], session s: Session) throws {
        try ensureLive(s)
        guard let state = output["State"] as? String else { throw EngineError("rclone 設定協定的回覆無法辨識。原有帳號未變更，請取消並改用 config。") }
        try lock.holding {
            s.state = state; s.error = sanitized(output["Error"] as? String ?? "", s); s.authURL = nil; s.step += 1
            if state.isEmpty {
                guard s.error.isEmpty else { throw EngineError(s.error) }
                s.option = nil; s.phase = "ready"
            } else {
                guard let option = output["Option"] as? [String: Any], let name = option["Name"] as? String, !name.isEmpty else {
                    throw EngineError("rclone 沒有提供下一步的欄位資訊。原有帳號未變更，請取消並改用 config。")
                }
                guard option["Help"] is String, option["Type"] is String,
                      ["Required", "Exclusive", "IsPassword"].allSatisfy({ option[$0] == nil || (option[$0] as? NSNumber).map(EngineJSON.isBoolean) == true }),
                      option["Examples"] == nil || (option["Examples"] as? [[String: Any]])?.allSatisfy({ $0["Value"] is String && $0["Help"] is String }) == true else {
                    throw EngineError("rclone 設定協定的回覆無法辨識。原有帳號未變更，請取消並改用 config。")
                }
                s.option = option; s.phase = "question"
            }
        }
    }
    private func ensureLive(_ s: Session) throws {
        try lock.holding { guard session === s, !s.cancelled else { throw EngineError("已取消帳號設定。") } }
    }
    private func failed(_ error: Error, session s: Session) {
        if lock.holding({ s.cancelled }) { finishCancelled(s); return }
        lock.holding { s.error = sanitized(error.localizedDescription, s); s.phase = "error"; s.authURL = nil }
    }
    private func finishCancelled(_ s: Session) {
        finish(s, result: ["id": s.id, "phase": "cancelled", "name": s.name, "step": s.step], saved: false)
    }
    private func finish(_ s: Session, result: [String: Any], saved: Bool) {
        let callback: ((Bool) -> Void)? = lock.holding {
            guard session === s else { return nil }
            if let staged = s.staged { try? FileManager.default.removeItem(at: staged) }
            s.option = nil; s.secrets.removeAll(); s.state = ""; s.authURL = nil
            session = nil; lastResult = result
            return onFinish
        }
        callback?(saved)
    }
    static func string(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        if let bool = value as? NSNumber, CFGetTypeID(bool) == CFBooleanGetTypeID() { return bool.boolValue ? "true" : "false" }
        return value as? String ?? String(describing: value)
    }
    private static func isSecret(_ option: [String: Any]) -> Bool {
        if option["IsPassword"] as? Bool == true { return true }
        let name = (option["Name"] as? String ?? "").lowercased()
        return ["password", "secret", "token", "access_key", "private_key"].contains { name.contains($0) }
    }
    private func sanitized(_ message: String, _ s: Session?) -> String {
        var result = String(message.prefix(3000))
        for secret in s?.secrets ?? [] where !secret.isEmpty { result = result.replacingOccurrences(of: secret, with: "[redacted]") }
        result = result.replacingOccurrences(of: "(?i)(access_token|refresh_token|client_secret|password)[\\\"' :=]+[^\\s,}\\\"]+", with: "$1=[redacted]", options: .regularExpression)
        return result
    }
    private func configure(_ s: Session, answer: String? = nil) throws -> [String: Any] {
        let base = try stagedContext(s)
        var environment = base.environment
        var args = ["config", answer == nil && s.mode == "create" ? "create" : "update", s.name]
        if answer == nil && s.mode == "create" { args.append(s.provider) }
        args += ["--non-interactive", "--all"]
        if let answer {
            args.append("--continue")
            environment["RCLONE_STATE"] = s.state
            environment["RCLONE_RESULT"] = answer
        } else { args.append("--obscure") }
        let output = try run(Context(binary: base.binary, arguments: base.arguments, environment: environment), args, session: s, timeout: 600)
        guard output.code == 0, let result = (try? JSONSerialization.jsonObject(with: output.output)) as? [String: Any] else {
            throw EngineError("rclone 未完成帳號設定（代碼 \(output.code)）。原有設定未變更；請取消後檢查登入、網路或改用 config。")
        }
        return result
    }
    private func rpc(_ context: Context, _ method: String, session s: Session? = nil) throws -> [String: Any] {
        guard ["config/providers", "config/paths"].contains(method) else { throw EngineError("不支援的帳號操作。") }
        let output = try run(context, ["rc", "--loopback", method], session: s, timeout: s == nil ? 30 : 600)
        let object = (try? JSONSerialization.jsonObject(with: output.output)) as? [String: Any]
        guard output.code == 0, let object else {
            throw EngineError(sanitized(object?["error"] as? String ?? "rclone 帳號設定未完成（代碼 \(output.code)）。請檢查 rclone 版本、連線及設定檔密碼。", s))
        }
        return object
    }
    private final class Capture {
        let lock = NSLock()
        var data = Data()
        var overflow = false
        func append(_ chunk: Data) { lock.holding {
            if data.count + chunk.count <= 16 * 1024 * 1024 { data.append(chunk) } else { overflow = true }
        } }
    }
    private struct Result { let code: Int32; let output: Data }
    private func run(_ context: Context, _ args: [String], session s: Session? = nil, timeout: TimeInterval) throws -> Result {
        let p = Process(), out = Pipe(), err = Pipe()
        // Secrets go only to a private child environment, never argv or logs.
        p.executableURL = URL(fileURLWithPath: context.binary)
        p.arguments = context.arguments + ["--ask-password=false", "--log-level=NOTICE", "--use-json-log"] + args
        p.environment = context.environment; p.standardInput = FileHandle.nullDevice; p.standardOutput = out; p.standardError = err
        try EnginePlatform.prepare(p)
        try lock.holding {
            if let s { try ensureLive(s); s.child = p }
            try p.run()
        }
        let group = DispatchGroup(), capture = Capture()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            while let chunk = try? EnginePlatform.readAvailable(out.fileHandleForReading, maximum: 65536), !chunk.isEmpty {
                capture.append(chunk)
            }
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { group.leave() }
            var pending = Data()
            while let chunk = try? EnginePlatform.readAvailable(err.fileHandleForReading, maximum: 8192), !chunk.isEmpty {
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 10) {
                    let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
                    // Retain only the exact local OAuth endpoint; discard logs.
                    if let s, let log = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let message = log["msg"] as? String,
                       let range = message.range(of: "http://(?:127\\.0\\.0\\.1|localhost):[0-9]+/auth(?:\\?[^\\s\\\"<>]+)?", options: .regularExpression),
                       let url = URL(string: String(message[range])), Self.permittedAuthURL(url) {
                        lock.holding { if session === s && !s.cancelled { s.authURL = url.absoluteString } }
                    }
                }
                if pending.count > 65536 { pending.removeAll() }
            }
        }
        let start = ProcessInfo.processInfo.systemUptime
        var stopStarted: TimeInterval?
        while p.isRunning {
            let now = ProcessInfo.processInfo.systemUptime
            let cancelled = lock.holding { s?.cancelled ?? false }
            if (cancelled || now - start > timeout || capture.lock.holding({ capture.overflow })), stopStarted == nil {
                stopStarted = now; _ = EnginePlatform.signal(p.processIdentifier, SIGTERM)
            }
            if let stopStarted, now - stopStarted > 2 { _ = EnginePlatform.signal(p.processIdentifier, SIGKILL) }
            Thread.sleep(forTimeInterval: 0.05)
        }
        p.waitUntilExit(); group.wait()
        try? out.fileHandleForReading.close(); try? err.fileHandleForReading.close()
        if let s { lock.holding { s.child = nil }; try ensureLive(s) }
        if stopStarted != nil { throw EngineError("登入或帳號設定逾時。原有設定未變更，請取消後再試。") }
        return Result(code: p.terminationStatus, output: capture.lock.holding { capture.data })
    }
}
