#if os(macOS)
import Foundation
import Darwin

/// The Mac shell owns presentation only. Every engine operation, including
/// validation and normalization, crosses the same JSON-lines contract used by
/// the Windows/Linux host. The helper is never restarted automatically.
final class RBNEngineClient {
    final class Request {
        fileprivate let id: String
        fileprivate let method: String
        fileprivate let sequence: UInt64
        fileprivate let ready = DispatchSemaphore(value: 0)
        fileprivate let lock = NSLock()
        fileprivate var reply: Result<Any, Error>?
        fileprivate init(id: String, method: String, sequence: UInt64) { self.id = id; self.method = method; self.sequence = sequence }
        fileprivate func finish(_ value: Result<Any, Error>) {
            lock.holding { guard reply == nil else { return }; reply = value; ready.signal() }
        }
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var pending = [String: Request]()
    private var nextID: UInt64 = 1
    private var running = true
    private var closing = false
    private var cachedSettings = [String: Any]()
    private var cachedState = [String: Any]()
    private var cachedStateSequence: UInt64 = 0
    private var cachedLanguage = RBNHostPresentationLanguage.system
    private let nativeMetadata: [String: Any]?
    private let nativeMetadataProvider: (() -> [String: Any])?
    private var eventHandler: (([String: Any]) -> Void)?
    private let eventQueue = DispatchQueue(label: "org.rclone.browser.next.engine-events")
    let stateDirectory: URL

    var onEvent: (([String: Any]) -> Void)? {
        get { stateLock.holding { eventHandler } }
        set { stateLock.holding { eventHandler = newValue } }
    }
    var isRunning: Bool { stateLock.holding { running } }
    var resolvedLanguage: String { stateLock.holding { cachedLanguage } }
    var hasActiveJobs: Bool { stateLock.holding { cachedState["activeJobs"] as? Bool ?? false } }
    var hasActiveTools: Bool { stateLock.holding { cachedState["activeTools"] as? Bool ?? false } }

    static func bundledHelper() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["RBN_ENGINE_PATH"], override.hasPrefix("/") {
            return URL(fileURLWithPath: override)
        }
        guard let executable = Bundle.main.executableURL else { throw EngineError("App 缺少必要檔案。請重新下載並安裝 Rclone Browser Next。") }
        return executable.deletingLastPathComponent().appendingPathComponent("rbn-engine")
    }

    init(stateDirectory: URL, defaultRcloneDirectory: URL, helperURL: URL? = nil,
         nativeMetadata: [String: Any]? = nil, nativeMetadataProvider: (() -> [String: Any])? = nil,
         isolated: Bool = false) throws {
        self.stateDirectory = stateDirectory
        self.nativeMetadata = nativeMetadata
        self.nativeMetadataProvider = nativeMetadataProvider
        let helper = try helperURL ?? Self.bundledHelper()
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw EngineError("App 缺少必要檔案。請重新下載並安裝 Rclone Browser Next。")
        }
        let temporary = stateDirectory.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var environment = ProcessInfo.processInfo.environment
        environment["TMPDIR"] = temporary.path + "/"
        environment["TMP"] = temporary.path
        environment["TEMP"] = temporary.path
        environment["RBN_NATIVE_LOCALIZE_RESULTS"] = "1"
        environment["RBN_APP_BUNDLE_PARENT"] = Bundle.main.bundleURL.deletingLastPathComponent().path
        if let languages = try? JSONSerialization.data(withJSONObject: Locale.preferredLanguages),
           let text = String(data: languages, encoding: .utf8) { environment["RBN_PREFERRED_LANGUAGES"] = text }
        if isolated {
            environment["RBN_ISOLATED_STATE"] = "1"
            environment["RBN_TEST_HOME"] = stateDirectory.path
            let home = temporary.appendingPathComponent("isolated-home", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            environment["HOME"] = home.path
            environment["XDG_CONFIG_HOME"] = home.appendingPathComponent(".config", isDirectory: true).path
            environment["XDG_DATA_HOME"] = home.appendingPathComponent(".local/share", isDirectory: true).path
            environment["XDG_CACHE_HOME"] = home.appendingPathComponent(".cache", isDirectory: true).path
            environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
            for name in environment.keys where name.hasPrefix("RCLONE_") { environment.removeValue(forKey: name) }
        }
        // Keep unrelated native subprocesses from retaining the helper's
        // stdin writer, and turn a child-exit write race into an ordinary error
        // instead of SIGPIPE terminating the entire App.
        for handle in [input.fileHandleForReading, input.fileHandleForWriting,
                       output.fileHandleForReading, output.fileHandleForWriting] {
            guard Darwin.fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        guard Darwin.fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        process.executableURL = helper
        process.arguments = ["--state-dir", stateDirectory.path, "--engine-dir", defaultRcloneDirectory.path]
        process.environment = environment
        process.currentDirectoryURL = helper.deletingLastPathComponent()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { running = false; throw error }
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        let reader = Thread { [weak self] in self?.readOutput() }
        reader.name = "RcloneBrowserNext Rust engine replies"
        reader.qualityOfService = .userInitiated
        reader.start()
        do {
            _ = try refreshPreferences()
            _ = try stateSnapshot()
        } catch {
            try? input.fileHandleForWriting.close()
            // The helper owns its orderly EOF shutdown. Waiting here never
            // terminates an installed app or a helper belonging to another task.
            process.waitUntilExit()
            throw error
        }
    }

    func settingsSnapshot() -> [String: Any] { stateLock.holding { cachedSettings } }

    @discardableResult
    func refreshPreferences() throws -> [String: Any] {
        guard let value = try call("_preferences", arguments: [], timeout: 30) as? [String: Any] else { throw protocolError() }
        cache(value)
        return value
    }

    @discardableResult
    func stateSnapshot() throws -> [String: Any] {
        let request = try submit("_state", arguments: [])
        guard let value = try wait(request, timeout: 30) as? [String: Any] else { throw protocolError() }
        cache(value)
        stateLock.holding {
            if request.sequence >= cachedStateSequence {
                cachedState = value; cachedStateSequence = request.sequence
            }
        }
        return value
    }

    func invoke(_ method: String, arguments: [Any], timeout: TimeInterval? = 960) throws -> Any {
        var locations: [[String: Any]]?
        if method == "bootstrap", let metadata = nativeMetadataProvider?() ?? nativeMetadata {
            guard let value = try call("_localLocations", arguments: [metadata], timeout: 30) as? [[String: Any]] else { throw protocolError() }
            locations = value
        }
        var value = try call(method, arguments: arguments, timeout: timeout)
        if method == "bootstrap", var bootstrap = value as? [String: Any] {
            cache(bootstrap)
            if let locations = locations { bootstrap["localLocations"] = locations }
            value = bootstrap
        } else if method == "saveSettings" {
            _ = try refreshPreferences()
        }
        return value
    }

    func normalizedRequest(_ raw: Any) throws -> RBNTransferDisplay {
        try RBNTransferDisplay(try call("_normalizeTransfer", arguments: [raw]))
    }

    func nativeArguments(_ method: String, arguments: [Any]) throws -> [String: Any] {
        guard let value = try call("_nativePrepare", arguments: [method, arguments]) as? [String: Any],
              value["arguments"] is [Any] else { throw protocolError() }
        return value
    }

    /// Submission is separate from waiting so list/cancelList reaches the Rust
    /// input reader in WebKit message order, before concurrent workers can run.
    func submit(_ method: String, arguments: [Any]) throws -> Request {
        guard arguments.count <= 8 else { throw EngineError("操作參數格式不正確。") }
        writeLock.lock(); defer { writeLock.unlock() }
        let request = try stateLock.holding { () throws -> Request in
            guard running, !closing || ["_state", "_shutdown", "_endConfiguration", "_cancelListings", "cancelList"].contains(method) else { throw stoppedError(language: cachedLanguage) }
            guard pending.count < 256 else { throw EngineError("操作要求過多，請稍後重試。") }
            let request = Request(id: "mac-\(nextID)", method: method, sequence: nextID)
            nextID &+= 1
            pending[request.id] = request
            return request
        }
        do {
            let object: [String: Any] = ["id": request.id, "method": method, "args": arguments]
            guard JSONSerialization.isValidJSONObject(object) else { throw EngineError("操作參數格式不正確。") }
            var bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            guard bytes.count < 8 * 1024 * 1024 else { throw EngineError("選取項目超過單次上限，請分批處理。") }
            bytes.append(10)
            try input.fileHandleForWriting.write(contentsOf: bytes)
            return request
        } catch {
            _ = stateLock.holding { pending.removeValue(forKey: request.id) }
            request.finish(.failure(error))
            throw error
        }
    }

    func wait(_ request: Request, timeout: TimeInterval? = 960) throws -> Any {
        let timedOut: Bool
        if let timeout = timeout {
            guard timeout.isFinite, timeout >= 0, timeout <= 31_536_000 else { throw EngineError("操作參數格式不正確。") }
            timedOut = request.ready.wait(timeout: .now() + timeout) == .timedOut
        } else {
            // Native recovery/export workers had no wall-clock cutoff. EOF
            // still fails this pending request immediately if the engine stops.
            request.ready.wait()
            timedOut = false
        }
        if timedOut {
            _ = stateLock.holding { pending.removeValue(forKey: request.id) }
            throw EngineError(resolvedLanguage == "zh-TW" ? "操作尚未回應，請查看工作狀態。" : resolvedLanguage == "ja" ? "操作の応答がありません。ジョブの状態を確認してください。" : "The operation has not responded. Check its job status.")
        }
        guard let reply = request.lock.holding({ request.reply }) else { throw protocolError() }
        return try reply.get()
    }

    func call(_ method: String, arguments: [Any], timeout: TimeInterval? = 960) throws -> Any {
        try wait(submit(method, arguments: arguments), timeout: timeout)
    }

    func cancelListings() { _ = try? call("_cancelListings", arguments: [], timeout: 30) }

    /// The UI reserves quit before presenting its existing confirmation. The
    /// write lock closes the race with a request prepared by an earlier dialog.
    func reserveQuit(_ value: Bool) { writeLock.holding { stateLock.holding { closing = value } } }

    func shutdown() throws {
        _ = try call("_shutdown", arguments: [])
        writeLock.holding { try? input.fileHandleForWriting.close() }
        process.waitUntilExit()
    }

    private func cache(_ value: [String: Any]) {
        guard let settings = value["settings"] as? [String: Any] else { return }
        stateLock.holding {
            let incoming = (settings["settingsRevision"] as? NSNumber)?.uint64Value ?? 0
            let current = (cachedSettings["settingsRevision"] as? NSNumber)?.uint64Value ?? 0
            guard cachedSettings.isEmpty || incoming >= current else { return }
            cachedSettings = settings
            if let language = value["resolvedLanguage"] as? String { cachedLanguage = language }
        }
    }

    private func readOutput() {
        var buffered = Data()
        do {
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                // POSIX read returns available pipe bytes immediately. The
                // borrowed buffer is valid only for this synchronous call.
                let length = chunk.withUnsafeMutableBytes { buffer in
                    Darwin.read(output.fileHandleForReading.fileDescriptor, buffer.baseAddress, buffer.count)
                }
                if length < 0 {
                    if errno == EINTR { continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                if length == 0 { break }
                // Each byte is searched only in the newly read chunk. A large
                // JSON line must not repeatedly rescan its accumulated prefix.
                // The original Mac bridge imposed no reply/event size limit.
                var start = 0
                for newline in 0..<length where chunk[newline] == 10 {
                    buffered.append(contentsOf: chunk[start..<newline])
                    guard let packet = try JSONSerialization.jsonObject(with: buffered) as? [String: Any] else { engineStopped(); return }
                    // Release a completed large frame instead of retaining its
                    // high-water allocation for all subsequent small packets.
                    buffered.removeAll(keepingCapacity: false)
                    start = newline + 1
                    if let event = packet["event"] as? [String: Any] {
                        eventQueue.async { [weak self] in
                            guard let self = self else { return }
                            let callback = self.stateLock.holding { self.eventHandler }
                            callback?(event)
                        }
                    } else if let id = packet["id"] as? String,
                              let request = stateLock.holding({ pending.removeValue(forKey: id) }) {
                        if let error = packet["error"] as? String { request.finish(.failure(RBNEngineReplyError(error))) }
                        else { request.finish(.success(packet["result"] ?? NSNull())) }
                    }
                }
                buffered.append(contentsOf: chunk[start..<length])
            }
        } catch {}
        engineStopped()
    }

    private func engineStopped() {
        let waiting = stateLock.holding { () -> [Request] in
            guard running else { return [] }
            running = false
            let requests = Array(pending.values)
            pending.removeAll()
            return requests
        }
        let error = stoppedError()
        waiting.forEach { $0.finish(.failure(error)) }
        // A malformed/closed reply stream cannot leave an unowned helper
        // running. EOF asks that same child to perform its normal shutdown.
        writeLock.holding { try? input.fileHandleForWriting.close() }
    }

    private func stoppedError() -> EngineError { stoppedError(language: stateLock.holding { cachedLanguage }) }
    private func stoppedError(language: String) -> EngineError {
        return EngineError(language == "zh-TW" ? "引擎已停止，請重新開啟程式。" : language == "ja" ? "エンジンが停止しました。アプリを開き直してください。" : "The engine stopped. Reopen the app.")
    }
    private func protocolError() -> EngineError { EngineError("引擎回覆格式不正確。") }

    /// CLI mode inherits the original stdout/stderr and passes the exact UTF-8
    /// argv directly to posix_spawn, avoiding Foundation's path normalization.
    static func runRepairCLI(_ arguments: [String]) -> Int32? {
        guard arguments.first == "--repair-local-partials" else { return nil }
        do {
            let helper = try bundledHelper()
            var strings = ([helper.path] + arguments).map { strdup($0) }
            defer { strings.forEach { free($0) } }
            strings.append(nil)
            var child: pid_t = 0
            let status = helper.path.withCString { executable in
                strings.withUnsafeMutableBufferPointer { argv in posix_spawn(&child, executable, nil, nil, argv.baseAddress!, environ) }
            }
            guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(status)) }
            var result: Int32 = 0
            while waitpid(child, &result, 0) < 0 {
                if errno != EINTR { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            }
            return result & 0x7f == 0 ? (result >> 8) & 0xff : 128 + (result & 0x7f)
        } catch {
            if var data = try? JSONSerialization.data(withJSONObject: ["error": error.localizedDescription], options: [.sortedKeys]) {
                data.append(10); try? FileHandle.standardError.write(contentsOf: data)
            }
            return 2
        }
    }
}

struct EngineError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
struct RBNEngineReplyError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
extension NSLock {
    func holding<T>(_ body: () throws -> T) rethrows -> T { lock(); defer { unlock() }; return try body() }
}
extension NSRecursiveLock {
    func holding<T>(_ body: () throws -> T) rethrows -> T { lock(); defer { unlock() }; return try body() }
}

enum RBNProject {
    static let version = "0.12.0"
    static let author = "Jason Chen"
    static let repository = "jason840709/RcloneBrowserNext"
}

/// These are display DTOs of already-normalized engine JSON. They do not
/// validate user input, set defaults or decide which files will be modified.
struct RBNEndpointDisplay {
    let json: [String: Any]
    let remote: String?
    let path: String
    var argument: String { remote.map { "\($0):\(path)" } ?? path }
    init(_ value: Any?) throws {
        guard let object = value as? [String: Any], let path = object["path"] as? String,
              object["remote"] is NSNull || object["remote"] is String else { throw EngineError("引擎回覆格式不正確。") }
        json = object; self.path = path; remote = object["remote"] as? String
    }
}
struct RBNSelectionDisplay {
    let name: String
    init(_ value: Any) throws {
        guard let object = value as? [String: Any], let name = object["name"] as? String else { throw EngineError("引擎回覆格式不正確。") }
        self.name = name
    }
}
struct RBNTransferDisplay {
    let json: [String: Any]
    let source: RBNEndpointDisplay
    let destination: RBNEndpointDisplay
    let mode: String
    let dryRun: Bool
    let selection: [RBNSelectionDisplay]
    let maxDelete: Int
    let deleteExcluded: Bool
    init(_ value: Any) throws {
        guard let object = value as? [String: Any], let mode = object["mode"] as? String,
              let dryRun = object["dryRun"] as? Bool, let selected = object["selection"] as? [Any],
              let options = object["options"] as? [String: Any], let maxDelete = options["maxDelete"] as? Int,
              let deleteExcluded = options["deleteExcluded"] as? Bool else { throw EngineError("引擎回覆格式不正確。") }
        json = object; self.mode = mode; self.dryRun = dryRun; self.maxDelete = maxDelete; self.deleteExcluded = deleteExcluded
        source = try RBNEndpointDisplay(object["source"]); destination = try RBNEndpointDisplay(object["destination"])
        selection = try selected.map(RBNSelectionDisplay.init)
    }
}
struct RBNAppReleaseResult {
    enum Status: String { case current, available, unpublished }
    let status: Status
    let current: String
    let latest: String?
    let releaseURL: URL
    let json: [String: Any]
    init(_ value: Any) throws {
        guard let object = value as? [String: Any], let raw = object["status"] as? String,
              let status = Status(rawValue: raw), let current = object["current"] as? String,
              let url = object["releaseURL"] as? String, let releaseURL = URL(string: url) else { throw EngineError("引擎回覆格式不正確。") }
        json = object; self.status = status; self.current = current; latest = object["latest"] as? String; self.releaseURL = releaseURL
    }
}

/// UI-only fallback for a launch error before the helper can return its
/// resolved language. Normal engine and page localization is owned by Rust.
enum RBNHostPresentationLanguage {
    static var system: String {
        guard let primary = Locale.preferredLanguages.first else { return "en" }
        let language = primary.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-").first.map(String.init) ?? ""
        switch language { case "zh": return "zh-TW"; case "ja": return "ja"; default: return "en" }
    }
}

/// The explicit override is used by development/native tests only. Normal
/// launches retain the published Application Support folder unchanged.
enum RBNMacLaunchState {
    static func isolatedDirectory(arguments: [String] = CommandLine.arguments,
                                  environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL? {
        let matches = arguments.indices.filter { arguments[$0] == "--state-dir" }
        guard matches.count <= 1 else { throw EngineError("操作參數格式不正確。") }
        let raw: String?
        if let index = matches.first {
            guard arguments.indices.contains(index + 1) else { throw EngineError("操作參數格式不正確。") }
            raw = arguments[index + 1]
        } else { raw = environment["RBN_STATE_DIR"] }
        guard let value = raw else { return nil }
        guard value.hasPrefix("/"), !value.contains("\0") else { throw EngineError("操作參數格式不正確。") }
        return URL(fileURLWithPath: value, isDirectory: true)
    }
}

/// Foundation contributes only OS-provided metadata. Filtering, path checks,
/// deduplication, order and network/local classification are owned by Rust.
enum RBNMacMetadata {
    static func locations(isolatedRoot: URL? = nil) -> [String: Any] {
        let manager = FileManager.default
        if let root = isolatedRoot {
            return ["home": ["path": root.path, "name": root.lastPathComponent], "folders": [], "volumes": [], "volumesRoot": NSNull()]
        }
        let home = manager.homeDirectoryForCurrentUser
        let directories: [(String, FileManager.SearchPathDirectory)] = [("desktop", .desktopDirectory), ("documents", .documentDirectory), ("downloads", .downloadsDirectory), ("pictures", .picturesDirectory), ("music", .musicDirectory), ("movies", .moviesDirectory)]
        let folders: [[String: Any]] = directories.compactMap { kind, directory in
            manager.urls(for: directory, in: .userDomainMask).first.map { ["kind": kind, "path": $0.path, "name": manager.displayName(atPath: $0.path)] }
        }
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeIsLocalKey, .volumeIsRemovableKey]
        let volumes: [[String: Any]] = (manager.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []).map { url in
            let value = try? url.resourceValues(forKeys: keys)
            return ["path": url.path, "name": value?.volumeName ?? manager.displayName(atPath: url.path),
                    "isLocal": value?.volumeIsLocal as Any? ?? NSNull(), "isRemovable": value?.volumeIsRemovable as Any? ?? NSNull()]
        }
        return ["home": ["path": home.path, "name": manager.displayName(atPath: home.path)], "folders": folders,
                "volumes": volumes, "volumesRoot": ["path": "/Volumes", "name": manager.displayName(atPath: "/Volumes")]]
    }
}

// Baseline 0.11.0 presentation translations, retained byte-for-byte below.
// Engine response/error translation is performed by Rust, not by this table.

/// Native dialogs and engine errors share these translations. Captured paths,
/// versions and rclone's own diagnostic output are preserved verbatim.
enum RBNNativeStrings {
    private struct Entry {
        let source: String
        let english: String
        let japanese: String
        let expression: NSRegularExpression?
        let labelCaptures: Set<Int>
        let sourcePieces: [String]
        init(_ source: String, _ english: String, _ japanese: String, labels: Set<Int> = []) {
            self.source = source; self.english = english; self.japanese = japanese
            self.labelCaptures = labels
            self.sourcePieces = source.components(separatedBy: "{}")
            let escaped = sourcePieces.map(NSRegularExpression.escapedPattern(for:))
            // Absolute anchors avoid translating just before a diagnostic's final
            // newline. Captures are literal by default, including nested messages.
            expression = escaped.count > 1 ? try? NSRegularExpression(pattern: "\\A" + escaped.joined(separator: "([\\s\\S]*?)") + "\\z") : nil
        }
    }
    private static let entries: [Entry] = [
        Entry("來源資料夾無法讀取，該部分尚未同步。請查看逐檔紀錄。", "Source folders could not be read, so their contents have not been synced. See the per-file report.", "コピー元のフォルダを読み込めないため、その内容はまだ同期されていません。ファイル別レポートを確認してください。"),
        Entry("正在清理來源已不存在的空資料夾。", "Removing empty destination folders that no longer exist at the source.", "コピー元にない空のコピー先フォルダを削除しています。"),
        Entry("已清理 {} 個來源不存在的空資料夾。", "Removed {} empty folders that no longer exist at the source.", "コピー元にない空のフォルダを {} 個削除しました。"),
        Entry("預演：會清理 {} 個來源不存在的空資料夾。", "Dry run: {} empty folders absent from the source would be removed.", "試行：コピー元にない空のフォルダを {} 個削除する予定です。"),
        Entry("已刪除來源不存在的空資料夾。", "Removed an empty folder that no longer exists at the source.", "コピー元にない空のフォルダを削除しました。"),
        Entry("預演：會刪除來源不存在的空資料夾。", "Dry run: this empty folder absent from the source would be removed.", "試行：コピー元にないこの空のフォルダを削除する予定です。"),
        Entry("空資料夾清理未完成：{}", "Empty-folder cleanup did not finish: {}", "空のフォルダの削除が完了しませんでした：{}"),
        Entry("空資料夾清理清單格式不正確。", "The empty-folder cleanup list is invalid.", "空のフォルダの削除一覧が正しくありません。"),
        Entry("空資料夾清理清單過大，已停止清理。", "The empty-folder list is too large. Cleanup stopped.", "空のフォルダの一覧が大きすぎるため、削除を停止しました。"),
        Entry("空資料夾清理清單含有不安全的路徑。", "The empty-folder list contains an unsafe path.", "空のフォルダの一覧に安全でないパスが含まれています。"),
        Entry("無法刪除空資料夾：{}（{}）。", "Cannot remove empty folder: {} ({}).", "空のフォルダを削除できません：{}（{}）。"),
        Entry("目錄無法讀取，已停止空資料夾清理。", "A folder cannot be read. Empty-folder cleanup stopped.", "フォルダを読み込めないため、空のフォルダの削除を停止しました。"),
        Entry("子目錄無法讀取，保留該目錄。", "The subfolder cannot be read and was kept.", "サブフォルダを読み込めないため、そのまま残しました。"),
        Entry("目錄路徑在清理期間改變，已停止清理。", "A folder path changed during cleanup. Cleanup stopped.", "削除中にフォルダのパスが変更されたため、停止しました。"),
        Entry("無法完整讀取來源目錄，已停止清理。", "The source folder cannot be fully read. Cleanup stopped.", "コピー元のフォルダを完全に読み込めないため、削除を停止しました。"),
        Entry("來源目錄讀取不完整，已停止清理。", "The source folder listing is incomplete. Cleanup stopped.", "コピー元のフォルダ一覧が不完全なため、削除を停止しました。"),
        Entry("來源有無法辨識的檔名，已停止清理。", "A source filename cannot be read. Cleanup stopped.", "コピー元に読み取れないファイル名があるため、削除を停止しました。"),
        Entry("同步位置無法讀取，已停止空資料夾清理。", "A sync location cannot be read. Empty-folder cleanup stopped.", "同期先を読み込めないため、空のフォルダの削除を停止しました。"),
        Entry("同步位置在清理期間改變，已停止清理。", "A sync location changed during cleanup. Cleanup stopped.", "削除中に同期先が変更されたため、停止しました。"),
        Entry("保留其他磁碟上的目錄。", "Folders on another filesystem were kept.", "別のファイルシステム上のフォルダは残しました。"),
        Entry("macOS 本機互傳改用一般串流複製，避免繼承來源檔案的鎖定屬性；暫存檔驗證與完成後改名仍照常執行。", "macOS local transfers use streaming copies to avoid inheriting source lock flags. Temporary-file verification and final renaming remain enabled.", "macOS のローカル転送では元のロック属性を引き継がない通常のコピーを使用します。一時ファイルの検証と完了時の名前変更は引き続き行われます。"),
        Entry("目錄讀取已取消。", "Folder loading was cancelled.", "フォルダの読み込みをキャンセルしました。"),
        Entry("目錄讀取尚未停止，請稍後再試。", "Folder loading has not stopped yet. Try again shortly.", "フォルダの読み込みはまだ停止していません。少し待ってから再試行してください。"),
        Entry("目錄讀取逾時設定不正確。", "The folder loading timeout is invalid.", "フォルダの読み込みタイムアウト設定が正しくありません。"),
        Entry("目錄讀取要求格式不正確。", "The folder loading request is invalid.", "フォルダの読み込み要求が正しくありません。"),
        Entry("目錄讀取編號已使用，請重新載入。", "This folder request was already used. Reload the folder.", "このフォルダ要求はすでに使われています。フォルダを再読み込みしてください。"),
        Entry("目錄讀取編號不可空白。", "A folder loading request ID is required.", "フォルダの読み込み要求 ID が必要です。"),
        Entry("目錄讀取要求過多，請稍後重試。", "Too many folder loading requests. Try again shortly.", "フォルダの読み込み要求が多すぎます。少し待ってから再試行してください。"),
        Entry("請先結束帳號設定，再執行工具。", "Finish account setup before using the tools.", "アカウント設定を終了してからツールを使ってください。"),
        Entry("請先關閉帳號設定視窗，再結束程式。", "Close the account setup window before quitting the app.", "アカウント設定のウインドウを閉じてからアプリを終了してください。"),
        Entry("請先停止播放，再開啟帳號設定。", "Stop playback before opening account setup.", "再生を停止してからアカウント設定を開いてください。"),
        Entry("請先結束帳號設定，並停止播放，再更新 rclone。", "Finish account setup and stop playback before updating rclone.", "アカウント設定を終了し、再生を停止してから rclone を更新してください。"),
        Entry("設定已變更，請重新檢查更新。", "Settings have changed. Check for updates again.", "設定が変更されました。更新をもう一度確認してください。"),
        Entry("作業檔必須是 8 MiB 以內的 JSON 檔案。", "Choose a task JSON file no larger than 8 MiB.", "8 MiB 以下のタスク JSON ファイルを選択してください。"),
        Entry("不支援這項操作。", "This operation is not supported.", "この操作には対応していません。"),
        Entry("請先結束帳號設定，再執行這項操作。", "Finish account setup before performing this operation.", "アカウント設定を終了してからこの操作を行ってください。"),
        Entry("請選擇一般檔案作為匯出位置。", "Choose a regular file as the export destination.", "書き出し先には通常のファイルを指定してください。"),
        Entry("請先結束帳號設定或播放，再變更 rclone 位置與連線設定。", "Finish account setup or playback before changing rclone or connection settings.", "rclone や接続設定を変更する前に、アカウント設定または再生を終了してください。"),
        Entry("App 缺少必要檔案。請重新下載並安裝 Rclone Browser Next。", "Required app files are missing. Download and reinstall Rclone Browser Next.", "アプリに必要なファイルがありません。Rclone Browser Next をダウンロードし直して再インストールしてください。"),
        Entry("只有目標有此檔案。", "This file exists only at the destination.", "このファイルは転送先にのみ存在します。"),

        Entry("介面比例只能選擇 80%、90%、100%、110% 或 125%。", "Choose an interface scale of 80%, 90%, 100%, 110% or 125%.", "表示倍率は 80%、90%、100%、110%、125% から選択してください。"),
        Entry("請選擇支援的介面比例。", "Choose a supported interface scale.", "対応している表示倍率を選択してください。"),
        Entry("工作清理設定格式不正確。", "The job cleanup settings are invalid.", "処理の消去設定が正しくありません。"),
        Entry("無法清除紀錄，傳輸清單或清除設定已失效。請重新整理後再試。", "Could not clear job records: the transfer list or cleanup choice is no longer valid. Refresh the list and try again.", "転送一覧または消去方法が無効になったため、ジョブの記録を消去できませんでした。一覧を更新して再試行してください。"),
        Entry("rclone 尚未停止，已保留此工作。請查看工作狀態。", "rclone has not stopped. The job is still listed; check its status.", "rclone はまだ停止していません。処理は一覧に残っています。状態を確認してください。"),
        Entry("工作已停止。", "The job stopped.", "処理を停止しました。"),
        Entry("rclone 未回應停止要求，已強制終止。請檢查目標端是否留有未完成檔案或上傳資料。", "rclone did not respond and was force-stopped. Check the destination for unfinished files.", "rclone が停止要求に応答しなかったため、強制停止しました。転送先の未完了ファイルを確認してください。"),
        Entry("預設啟動資料夾格式不正確。", "The default startup folder format is invalid.", "起動時のデフォルトフォルダの形式が正しくありません。"),
        Entry("只能設定左右面板的預設啟動資料夾。", "Only the left and right panes can have default startup folders.", "起動時のデフォルトフォルダは左右のペインにのみ設定できます。"),
        Entry("工作區設定格式不正確。", "The saved workspace format is invalid.", "保存した作業環境の形式が正しくありません。"),
        Entry("工作區設定需包含左右位置、方向、操作方式與傳輸選項。", "A saved workspace must include both locations, direction, operation and transfer options.", "作業環境には左右の場所、方向、操作、転送オプションが必要です。"),
        Entry("傳輸方向不正確。", "The transfer direction is invalid.", "転送方向が正しくありません。"),
        Entry("網路設定格式不正確。", "The network settings format is invalid.", "ネットワーク設定の形式が正しくありません。"),
        Entry("內建方案設定格式不正確。", "The built-in preset settings are invalid.", "組み込みプリセット設定の形式が正しくありません。"),
        Entry("網路設定包含不支援的選項。", "The network settings contain an unsupported option.", "ネットワーク設定に未対応のオプションが含まれています。"),
        Entry("連線位址模式不正確。", "The connection address mode is invalid.", "接続アドレスのモードが正しくありません。"),
        Entry("本機 IP 位址請填入有效的 IPv4 或 IPv6 位址（請勿填網卡名稱、網址或連接埠）。", "Enter a valid local IPv4 or IPv6 address, without an interface name, URL or port.", "ローカル IP アドレスには有効な IPv4 または IPv6 を入力してください。インターフェース名、URL、ポート番号は使用できません。"),
        Entry("每秒請求上限與停用 HTTP/2 請直接在「rclone 連線」設定，並從「所有傳輸都加上的參數」移除重複項目。", "Set Requests per second and HTTP/2 in rclone connection settings, then remove duplicate flags from Extra arguments for all jobs.", "毎秒リクエスト上限と HTTP/2 は「rclone 接続」で設定し、「すべてのジョブの追加引数」から重複する指定を削除してください。"),
        Entry("GitHub 專案位置不正確。", "The GitHub repository address is invalid.", "GitHub プロジェクトのアドレスが正しくありません。"),
        Entry("App 版本格式不正確。", "The app version format is invalid.", "アプリのバージョン形式が正しくありません。"),
        Entry("GitHub 更新資訊超過允許大小。", "GitHub's update response exceeds the allowed size.", "GitHub の更新情報が許容サイズを超えています。"),
        Entry("GitHub 回傳的正式版本資訊不完整。", "GitHub returned incomplete release information.", "GitHub から返された正式版の情報が不完全です。"),
        Entry("更新資訊轉址到其他位置，已停止檢查。", "The update response redirected to another address. The check was stopped.", "更新情報が別のアドレスに転送されたため、確認を停止しました。"),
        Entry("GitHub 暫時限制更新檢查，請稍後再試。", "GitHub is temporarily limiting update requests. Try again later.", "GitHub が更新確認のリクエストを一時的に制限しています。後でもう一度お試しください。"),
        Entry("GitHub 更新檢查失敗（HTTP {}）。", "The GitHub update check failed (HTTP {}).", "GitHub の更新確認に失敗しました（HTTP {}）。"),
        Entry("GitHub 未回傳更新資訊。", "GitHub did not return update information.", "GitHub から更新情報が返されませんでした。"),
        Entry("更新檢查不需要額外參數。", "The update check does not take additional arguments.", "更新確認に追加の引数は不要です。"),
        Entry("關於視窗不需要額外參數。", "The About dialog does not take additional arguments.", "情報ウインドウに追加の引数は不要です。"),
        Entry("好", "OK", "OK"),
        Entry("取消", "Cancel", "キャンセル"),
        Entry("刪除", "Delete", "削除"),
        Entry("下載", "Download", "ダウンロード"),
        Entry("更新", "Update", "更新"),
        Entry("稍後", "Later", "あとで"),
        Entry("跳過此版本", "Skip this version", "このバージョンをスキップ"),
        Entry("尚未安裝", "Not installed", "未インストール"),
        Entry("rclone 已是最新版本", "rclone is up to date", "rclone は最新です"),
        Entry("rclone 已是最新版本。", "rclone is up to date.", "rclone は最新です。"),
        Entry("無法自動更新", "Automatic update unavailable", "自動更新を利用できません"),
        Entry("rclone 正在更新", "rclone is updating", "rclone を更新中です"),
        Entry("請等更新完成後再結束 App。", "Wait for the update to finish before quitting.", "更新が完了してからアプリを終了してください。"),
        Entry("停止工作並結束？", "Stop jobs and quit?", "処理を停止して終了しますか？"),
        Entry("停止並結束", "Stop and quit", "停止して終了"),
        Entry("仍有工作正在執行或排隊。結束程式會停止這些工作，且已完成的檔案變更不會復原。", "There are running or queued jobs. Quitting stops them; completed file changes are not undone.", "実行中または待機中の処理があります。終了すると停止しますが、完了したファイルの変更は元に戻りません。"),
        Entry("刪除選取項目？", "Delete selected items?", "選択した項目を削除しますか？"),
        Entry("位置：{}\n\n{}\n\n確定永久刪除這 {} 個選取項目？（不會移到垃圾桶）", "Location: {}\n\n{}\n\nDelete {} selected items. Items are not moved to Trash.", "場所：{}\n\n{}\n\n選択した {} 個の項目を削除します。ゴミ箱には移動しません。"),
        Entry("來源：{}\n目標：{}", "Source: {}\nDestination: {}", "転送元：{}\n転送先：{}"),
        Entry("同步到目標？", "Sync to destination?", "転送先を同期しますか？"),
        Entry("\n\n目標端多出的檔案會被刪除（本次最多刪除 {} 個項目）。", "\n\nDestination files absent from the source will be deleted. Maximum deletions: {}.", "\n\n転送元に存在しない転送先のファイルを削除します。削除上限：{} 件。"),
        Entry("開始同步", "Start sync", "同期を開始"),
        Entry("移動到目標？", "Move to destination?", "転送先へ移動しますか？"),
        Entry("\n\n檔案傳送成功後會從來源刪除。", "\n\nSuccessfully transferred items are removed from the source.", "\n\n転送に成功した項目を転送元から削除します。"),
        Entry("開始移動", "Start move", "移動を開始"),
        Entry("選擇資料夾", "Choose folder", "フォルダを選択"),
        Entry("選擇 rclone 執行檔", "Choose rclone executable", "rclone 実行ファイルを選択"),
        Entry("選擇 rclone 設定檔", "Choose rclone configuration", "rclone 設定ファイルを選択"),
        Entry("匯入作業", "Import tasks", "タスクを読み込む"),
        Entry("下載 rclone？", "Download rclone?", "rclone をダウンロードしますか？"),
        Entry("發現新版 rclone", "A new rclone version is available", "rclone の新しいバージョンがあります"),
        Entry("目前：{}\n新版：{}\n\n存放位置：{}", "Current: {}\nLatest: {}\n\nLocation: {}", "現在：{}\n最新：{}\n\n保存先：{}", labels: [1]),
        Entry("已跳過 {}。", "Skipped {}.", "{} をスキップしました。"),
        Entry("rclone 已更新為 {}。", "rclone updated to {}.", "rclone を {} に更新しました。"),
        Entry("操作未完成", "Could not complete the operation", "操作を完了できませんでした"),
        Entry("雙面板 rclone 檔案傳輸工具\n\n介面採用 macOS 原生 AppKit 與 WebKit，搭配外部安裝的 rclone 執行。", "A dual-pane rclone file manager.\n\nUses macOS AppKit and WebKit. Select a separate rclone executable in Settings.", "2 ペインの rclone ファイル管理アプリです。\n\nmacOS の AppKit と WebKit を使用します。rclone は設定で指定した外部の実行ファイルを使用します。"),
        Entry("正在檢查 rclone 版本…", "Checking rclone versions…", "rclone のバージョンを確認中…"),
        Entry("版本檢查完成。", "Version check complete.", "バージョンの確認が完了しました。"),
        Entry("連線暫時失敗，正在重試（{}/2）…", "Connection interrupted. Retrying ({}/2)…", "接続が一時的に失敗しました。再試行中（{}/2）…"),
        Entry("正在下載 rclone {}…", "Downloading rclone {}…", "rclone {} をダウンロード中…"),
        Entry("正在檢查架構、macOS 需求與版本…", "Checking architecture, macOS requirements and version…", "アーキテクチャ、必要な macOS、バージョンを確認中…"),
        Entry("正在檢查執行檔架構與版本…", "Checking executable architecture and version…", "実行ファイルのアーキテクチャとバージョンを確認中…"),
        Entry("正在備份並替換 rclone…", "Backing up and replacing rclone…", "rclone をバックアップして置き換え中…"),
        Entry("已更新至 rclone {}。", "Updated to rclone {}.", "rclone {} に更新しました。"),
        Entry("更新檢查未完成，請重試。", "Update check did not finish. Try again.", "更新の確認が完了しませんでした。もう一度お試しください。"),
        Entry("rclone 官方下載站回傳 HTTP {}（{}）。請稍後重試。", "The official rclone server returned HTTP {} ({}). Try again later.", "rclone 公式サーバーから HTTP {}（{}）が返されました。しばらくしてから再試行してください。"),
        Entry("下載大小超過上限（{} bytes，上限 {} bytes），已停止下載。", "Download exceeds the size limit ({} bytes; limit {} bytes). Download stopped.", "ダウンロードがサイズ上限を超えたため停止しました（{} bytes、上限 {} bytes）。"),
        Entry("更新回應並非來自 rclone 官方下載站。", "The update response did not come from the official rclone server.", "更新応答が rclone の公式ダウンロードサーバーからのものではありません。"),
        Entry("rclone 官網回傳的版本資訊無法辨識，請稍後再試。", "The official rclone version response is invalid. Try again later.", "rclone 公式サイトのバージョン情報を読み取れませんでした。しばらくしてから再試行してください。"),
        Entry("目前使用的是自訂或測試版 rclone；若要更換，請手動選擇要使用的穩定版。", "This is a custom or test rclone build. Select a stable release manually.", "カスタム版またはテスト版の rclone を使用しています。安定版を手動で選択してください。"),
        Entry("無法執行這個 rclone：\n{}", "Could not run this rclone:\n{}", "この rclone を実行できません：\n{}"),
        Entry("所選檔案沒有回傳有效的 rclone 版本。", "The selected file did not return a valid rclone version.", "選択したファイルから有効な rclone バージョンが返されませんでした。"),
        Entry("請先選擇存放 rclone 的資料夾。", "Choose a folder for rclone first.", "rclone を保存するフォルダを選択してください。"),
        Entry("請選擇有效的 rclone 執行檔或資料夾。", "Choose a valid rclone executable or folder.", "有効な rclone 実行ファイルまたはフォルダを選択してください。"),
        Entry("下載未完成，原有的 rclone 維持不變。\n{}", "The download failed. Your existing rclone is unchanged.\n{}", "ダウンロードに失敗しました。既存の rclone は変更されていません。\n{}"),
        Entry("下載檔的 SHA-256 不符，已停止安裝。", "The download SHA-256 does not match. Installation stopped.", "ダウンロードしたファイルの SHA-256 が一致しないため、インストールを停止しました。"),
        Entry("下載的 rclone 執行檔不完整。", "The downloaded rclone executable is incomplete.", "ダウンロードした rclone 実行ファイルが不完全です。"),
        Entry("下載檔回報的版本與選定版本不符，已停止更新。", "The downloaded version does not match the selected release. Update stopped.", "ダウンロードしたバージョンが選択したリリースと一致しないため、更新を停止しました。"),
        Entry("更新後的版本檢查失敗。", "The post-update version check failed.", "更新後のバージョン確認に失敗しました。"),
        Entry("新版驗證未通過，已自動還原原有的 rclone。\n{}", "Post-update validation failed. The previous rclone was restored.\n{}", "更新後の検証に失敗したため、元の rclone を復元しました。\n{}"),
        Entry("新版驗證未通過，且自動還原失敗。\n舊版備份位置：{}\n{}", "Post-update validation and automatic restoration failed.\nPrevious version backup: {}\n{}", "更新後の検証と自動復元に失敗しました。\n旧バージョンのバックアップ：{}\n{}"),
        Entry("rclone 在更新期間被其他程式更動，已停止替換。", "Another process changed rclone during the update. Replacement stopped.", "更新中にほかのプロセスが rclone を変更したため、置き換えを停止しました。"),
        Entry("這個位置剛出現另一個檔案，已停止替換。", "A file appeared at the destination. Replacement stopped.", "保存先に別のファイルが作成されたため、置き換えを停止しました。"),
        Entry("請先完成 rclone 更新或目前開啟的設定工具。", "Finish the current update or account setup first.", "実行中の更新またはアカウント設定を完了してください。"),
        Entry("請先結束 Terminal 中的 rclone 設定工具，再更新。", "Close rclone account setup in Terminal before updating.", "更新する前に、ターミナルで開いている rclone 設定を終了してください。"),
        Entry("無法開啟 Terminal。請在終端機執行所選 rclone 的 config 指令。", "Could not open Terminal. Run the selected rclone's config command in Terminal.", "ターミナルを開けませんでした。選択した rclone の config コマンドをターミナルで実行してください。"),
        Entry("請先選取要刪除的項目。", "Select items to delete first.", "削除する項目を選択してください。"),
        Entry("找不到這個工作。", "This job could not be found.", "この処理が見つかりません。"),
        Entry("找不到工作記錄。", "The job log could not be found.", "処理のログが見つかりません。"),
        Entry("作業檔超過 8 MiB，請縮小後再匯入。", "The task file exceeds 8 MiB. Reduce it before importing.", "タスクファイルが 8 MiB を超えています。小さくしてから読み込んでください。"),
        Entry("不支援的操作。", "Unsupported operation.", "この操作には対応していません。"),
        Entry("上次關閉時工作尚未完成，未自動重跑。", "This job was interrupted when the app closed. It was not restarted automatically.", "アプリの終了時にこの処理が中断されました。自動では再実行していません。"),
        Entry("請先結束執行中的工作，再變更 rclone 或設定檔。", "Finish active jobs before changing rclone or its configuration.", "rclone または設定ファイルを変更する前に、実行中の処理を終了してください。"),
        Entry("正在更新 rclone，請稍候。", "rclone is updating. Please wait.", "rclone を更新中です。しばらくお待ちください。"),

        // Core validation. Only the field-name captures below are app-owned.
        Entry("{} 格式不正確，不能包含控制字元。", "{} has an invalid format. Control characters are not allowed.", "{}の形式が正しくありません。制御文字は使用できません。", labels: [1]),
        Entry("{} 必須為開啟或關閉。", "{} must be on or off.", "{}はオンまたはオフで指定してください。", labels: [1]),
        Entry("{} 必須介於 {} 與 {}。", "{} must be between {} and {}.", "{}は {} から {} の範囲で指定してください。", labels: [1]),
        Entry("{}必須使用絕對路徑。", "{} must use an absolute path.", "{}には絶対パスを指定してください。", labels: [1]),
        Entry("{}請填入 10M、512K 等大小；留空代表不限。", "For {}, enter a size such as 10M or 512K. Leave blank for no limit.", "{}には 10M、512K などのサイズを入力してください。空欄にすると制限しません。", labels: [1]),
        Entry("{}請填入 30s、5m、24h、7d 等時間。", "For {}, enter a duration such as 30s, 5m, 24h or 7d.", "{}には 30s、5m、24h、7d などの時間を入力してください。", labels: [1]),
        Entry("資料無法儲存成 JSON。", "The data cannot be saved as JSON.", "データを JSON 形式で保存できません。"),
        Entry("請選擇位置。", "Choose a location.", "場所を選択してください。"),
        Entry("本機位置必須是完整的絕對路徑。", "A local location must be a full absolute path.", "ローカルの場所には完全な絶対パスを指定してください。"),
        Entry("遠端連線名稱格式不正確。", "The remote name is invalid.", "リモート名の形式が正しくありません。"),
        Entry("遠端路徑不能包含「..」。", "A remote path cannot contain '..'.", "リモートのパスに「..」は使用できません。"),
        Entry("名稱不能留白、使用「.」「..」或包含斜線。", "Names cannot be blank, be '.' or '..', or contain a slash.", "名前は空欄にできません。「.」「..」やスラッシュは使用できません。"),
        Entry("單次最多選取 10,000 個項目。", "Select up to 10,000 items at a time.", "一度に選択できる項目は 10,000 件までです。"),
        Entry("選取項目不能重複。", "Selected items cannot be duplicated.", "同じ項目を重複して選択できません。"),
        Entry("傳輸選項格式不正確。", "The transfer options are invalid.", "転送オプションの形式が正しくありません。"),
        Entry("傳輸選項格式不正確。", "The transfer options are invalid.", "転送オプションの形式が正しくありません。"),
        Entry("限速請填入 10M、512K 或 off；留白表示不限速。", "Enter a bandwidth limit such as 10M, 512K or off. Leave blank for no limit.", "帯域制限には 10M、512K、off などを入力してください。空欄にすると制限しません。"),
        Entry("檔案比較方式不正確。", "The file comparison method is invalid.", "ファイルの比較方法が正しくありません。"),
        Entry("「全部重新傳輸」不可同時勾選略過已存在或較新的檔案，請改選其他比對方式。", "Retransfer all cannot also skip existing or newer files. Choose a comparison method.", "すべて再転送する場合、既存のファイルや新しいファイルをスキップできません。比較方法を選択してください。"),
        Entry("刪除時機不正確。", "The deletion timing is invalid.", "削除のタイミングが正しくありません。"),
        Entry("本機雜湊讀取設定不正確。", "The local hashing setting is invalid.", "ローカルのハッシュ計算設定が正しくありません。"),
        Entry("符號連結請選擇略過或保留。", "Choose Skip or Preserve for symbolic links.", "シンボリックリンクは「スキップ」または「保持」を選択してください。"),
        Entry("停用本機雜湊讀取時，不能使用雜湊比對。", "Hash comparison is unavailable when local hashing is disabled.", "ローカルのハッシュ計算を無効にしている場合、ハッシュで比較できません。"),
        Entry("最小檔案大小不能大於最大檔案大小。", "Minimum file size cannot exceed maximum file size.", "最小ファイルサイズは最大ファイルサイズ以下にしてください。"),
        Entry("最小檔案年齡不能大於最大檔案年齡。", "Minimum file age cannot exceed maximum file age.", "最小経過時間は最大経過時間以下にしてください。"),
        Entry("最多可設定 256 條篩選規則。", "You can set up to 256 filter rules.", "フィルタールールは 256 件まで設定できます。"),
        Entry("其他選項最多 64 行，每行填入一個 --選項=值。", "Additional options allow up to 64 lines. Enter one --option=value per line.", "追加オプションは 64 行までです。1 行に 1 つずつ --option=value を入力してください。"),
        Entry("其他選項不可包含子命令、路徑、單字元短參數或重複項目，每行請用 --選項=值 格式。", "Additional options cannot contain commands, paths, short flags or duplicate options. Use --option=value on each line.", "追加オプションにコマンド、パス、短縮フラグ、重複したオプションは指定できません。各行に --option=value を入力してください。"),
        Entry("{} 只接受 true 或 false。", "{} accepts only true or false.", "{}には true または false を指定してください。"),
        Entry("{} 請使用 --選項=值。", "Use --option=value for {}.", "{}は --option=value の形式で指定してください。"),
        Entry("{} 必須是 0 至 9,999,999 的整數。", "{} must be an integer from 0 to 9,999,999.", "{}には 0 から 9,999,999 までの整数を指定してください。"),
        Entry("每秒請求上限格式不正確。", "The requests-per-second limit is invalid.", "1 秒あたりのリクエスト上限が正しくありません。"),
        Entry("cutoff-mode 請填入 HARD、SOFT 或 CAUTIOUS。", "For cutoff-mode, enter HARD, SOFT or CAUTIOUS.", "cutoff-mode には HARD、SOFT、CAUTIOUS のいずれかを指定してください。"),
        Entry("order-by 格式不正確。", "The order-by value is invalid.", "order-by の形式が正しくありません。"),
        Entry("{} 不在支援的額外參數中。請改用畫面上的設定；帳號與憑證請至「帳號設定」或 Config 設定。", "{} is not a supported additional option. Use its setting in the interface; configure accounts and credentials in Config.", "{}は追加オプションとして指定できません。画面の該当する設定を使用してください。アカウントと認証情報は Config で設定してください。"),
        Entry("傳輸設定格式不正確。", "The transfer configuration is invalid.", "転送設定の形式が正しくありません。"),
        Entry("傳輸模式不正確。", "The transfer mode is invalid.", "転送モードが正しくありません。"),
        Entry("同步適用於整個目前目錄。請清除選取，或改用複製／移動。", "Sync applies to the entire current folder. Clear the selection or use Copy or Move.", "同期は現在のフォルダ全体に適用されます。選択を解除するか、コピーまたは移動を使用してください。"),
        Entry("同步只能勾選資料夾；請取消勾選個別檔案，或改用複製／移動。", "Select folders only for Sync. Deselect files or use Copy or Move.", "同期ではフォルダのみ選択できます。ファイルの選択を解除するか、コピーまたは移動を使用してください。"),
        Entry("只同步勾選的資料夾時，請關閉「刪除目標中符合排除規則的檔案」，以免刪到未勾選的目標檔案。", "For selected-folder sync, turn off Delete excluded destination files. It would also delete destination contents outside the selected folders.", "選択フォルダの同期では「転送先の除外ファイルも削除」をオフにしてください。この設定では未選択の転送先も削除対象になります。"),
        Entry("同步需要列出目標目錄，請關閉「不先列出目標目錄（複製、移動）」。", "Sync needs a destination listing. Turn off Skip listing the destination (copy and move).", "同期には転送先一覧が必要です。「転送先一覧を先に取得しない（コピー・移動）」をオフにしてください。"),
        Entry("移動時若開啟「略過目標較新的檔案」，被略過的來源檔案仍可能被刪除；請關閉此選項或改用複製。", "Move also deletes source files skipped because the destination is newer. Turn off Skip files newer at destination, or use Copy.", "移動では、転送先の方が新しいため転送をスキップした転送元ファイルも削除します。「転送先の方が新しいファイルをスキップ」をオフにするか、コピーを使用してください。"),
        Entry("「刪除目標中符合排除規則的檔案」只適用於同步。", "Delete excluded destination files is available only for Sync.", "「転送先の除外ファイルも削除」は同期でのみ使用できます。"),
        Entry("工作編號格式不正確。", "The job ID is invalid.", "処理 ID の形式が正しくありません。"),
        Entry("工作狀態格式不正確。", "The job status is invalid.", "処理の状態が正しくありません。"),
        Entry("作業格式不正確。", "The task format is invalid.", "タスクの形式が正しくありません。"),
        Entry("作業編號格式不正確。", "The task ID is invalid.", "タスク ID の形式が正しくありません。"),
        Entry("請輸入作業名稱。", "Enter a task name.", "タスク名を入力してください。"),

        // Storage, connections and transfer lifecycle.
        Entry("無法寫入 {}。", "Could not write {}.", "{} に書き込めません。"),
        Entry("儲存資料過大。", "The saved data is too large.", "保存データが大きすぎます。"),
        Entry("無法解析本機路徑。", "Could not resolve the local path.", "ローカルのパスを解決できません。"),
        Entry("來源資料夾不存在或無法讀取。", "The source folder does not exist or cannot be read.", "転送元フォルダが存在しないか、読み取れません。"),
        Entry("請選擇根目錄之下的目的資料夾。", "Choose a destination folder below the root directory.", "ルートディレクトリ以外の転送先フォルダを選択してください。"),
        Entry("目的位置已存在同名檔案，請選擇資料夾。", "A file already exists at the destination path. Choose a folder.", "転送先に同名のファイルが存在します。フォルダを選択してください。"),
        Entry("來源與目標不可相同，也不可互為上下層目錄（含符號連結）。", "Source and destination cannot be the same or contain one another, including through symbolic links.", "転送元と転送先に同じ場所や親子関係のあるフォルダは指定できません。シンボリックリンクも対象です。"),
        Entry("同一遠端的來源與目標不可相同，也不可互為上下層目錄。", "On the same remote, source and destination cannot be the same or contain one another.", "同じリモート内では、転送元と転送先に同じ場所や親子関係のあるフォルダは指定できません。"),
        Entry("無法建立工作記錄。", "Could not create the job log.", "処理のログを作成できません。"),
        Entry("紀錄檔已自動輪替（每項工作最多保留最近 100 MiB）。", "Log rotation: the latest 100 MiB is kept for each job.", "ログをローテーションします。各処理の最新 100 MiB を保存します。"),
        Entry("無法輪替工作記錄。", "Could not rotate the job log.", "処理のログをローテーションできません。"),
        Entry("工作記錄已關閉。", "The job log is closed.", "処理のログは閉じられています。"),
        Entry("這項工作尚未產生記錄。", "This job has not produced a log yet.", "この処理のログはまだありません。"),
        Entry("無法匯出記錄。", "Could not export the log.", "ログを書き出せません。"),
        Entry("逐檔報告查詢格式不正確。", "The file-report query is invalid.", "ファイル別レポートの照会形式が正しくありません。"),
        Entry("逐檔報告分類不正確。", "The file-report category is invalid.", "ファイル別レポートの分類が正しくありません。"),
        Entry("逐檔報告格式不正確。", "The file-report format is invalid.", "ファイル別レポートの形式が正しくありません。"),
        Entry("無法完整保存逐檔紀錄：{}", "The file report could not be saved completely: {}", "ファイル別レポートを完全に保存できませんでした：{}"),
        Entry("部分比對紀錄無法解析，可匯出原始比對紀錄查看。", "Some comparison entries could not be parsed. Check the original comparison log.", "一部の比較記録を読み取れませんでした。元の比較ログを確認してください。"),
        Entry("依本次比對與略過設定，不需更新。", "No update is needed under this job's comparison and skip settings.", "この処理の比較・スキップ設定では更新不要です。"),
        Entry("目標缺少此檔案，已列入傳輸清單。", "This file is missing at the destination and is listed for transfer.", "転送先にこのファイルがないため、転送対象に追加しました。"),
        Entry("檔案有變更，已列入傳輸清單。", "This file has changed and is listed for transfer.", "このファイルに変更があるため、転送対象に追加しました。"),
        Entry("此檔案只在目標存在；同步依篩選與刪除設定處理，複製會保留。", "This file exists only at the destination. Sync removes it; Copy keeps it.", "このファイルは転送先にのみ存在します。同期では削除し、コピーでは保持します。"),
        Entry("此檔案處理失敗，原因列於錯誤紀錄。", "This file failed. See its error record for the cause.", "このファイルの処理に失敗しました。原因はエラー記録で確認できます。"),
        Entry("傳輸設定", "Transfer settings", "転送設定"),
        Entry("比對時發生錯誤，請查看錯誤紀錄。", "An error occurred during comparison. Check the error log.", "比較中にエラーが発生しました。エラー記録を確認してください。"),
        Entry("逐檔記錄的分頁參數不正確。", "The file-report page parameters are invalid.", "ファイル別レポートのページ指定が正しくありません。"),
        Entry("逐檔記錄的分頁位置已失效。", "The file-report page position is no longer valid.", "ファイル別レポートの読み取り位置が無効になりました。"),
        Entry("逐檔記錄的分頁位置不正確。", "The file-report page position is invalid.", "ファイル別レポートの読み取り位置が正しくありません。"),
        Entry("逐檔記錄內容不完整，請匯出原始記錄查看。", "The file report is incomplete. Export the original log for details.", "ファイル別レポートが不完全です。元のログを書き出して確認してください。"),
        Entry("單筆逐檔記錄過大。", "A file-report entry is too large.", "ファイル別レポートの 1 件が大きすぎます。"),
        Entry("單筆逐檔記錄過大，無法完整儲存。", "A file-report entry is too large to save completely.", "ファイル別レポートの 1 件が大きすぎるため、完全に保存できません。"),
        Entry("逐檔記錄必須是一般檔案。", "The file report must be a regular file.", "ファイル別レポートには通常のファイルが必要です。"),
        Entry("不支援這個逐檔記錄格式。", "This file-report format is not supported.", "このファイル別レポート形式には対応していません。"),
        Entry("這項工作尚未產生逐檔記錄。", "This job has not produced a file report yet.", "この処理のファイル別レポートはまだありません。"),
        Entry("逐檔記錄在匯出時發生變更，請重新匯出。", "The file report changed during export. Export it again.", "書き出し中にファイル別レポートが変更されました。もう一度書き出してください。"),
        Entry("無法建立逐檔記錄：{}", "Could not create the file report: {}", "ファイル別レポートを作成できません：{}"),
        Entry("無法移除逐檔記錄：{}", "Could not remove the file report: {}", "ファイル別レポートを削除できません：{}"),
        Entry("無法移除逐檔記錄快照：{}", "Could not remove the file-report export snapshot: {}", "ファイル別レポートの書き出し用スナップショットを削除できません：{}"),
        Entry("無法讀取逐檔記錄：{}", "Could not read the file report: {}", "ファイル別レポートを読み取れません：{}"),
        Entry("無法建立逐檔記錄快照：{}", "Could not create the file-report export snapshot: {}", "ファイル別レポートの書き出し用スナップショットを作成できません：{}"),
        Entry("目錄資料超過單次可載入大小，請進入較小的資料夾。", "The directory listing is too large to load at once. Open a smaller folder.", "ディレクトリの一覧が大きすぎて一度に読み込めません。小さいフォルダを開いてください。"),
        Entry("找不到 rclone。請在設定中下載，或選擇已有的執行檔。", "rclone was not found. Download it in Settings or choose an existing executable.", "rclone が見つかりません。設定からダウンロードするか、既存の実行ファイルを選択してください。"),
        Entry("無法執行指定的 rclone，請確認路徑與執行權限。", "The selected rclone cannot run. Check its path and execution permissions.", "指定した rclone を実行できません。パスと実行権限を確認してください。"),
        Entry("程式正在關閉。", "The app is closing.", "アプリを終了しています。"),
        Entry("rclone 更新或位置切換正在進行。", "A rclone update or location change is in progress.", "rclone の更新または場所の変更が進行中です。"),
        Entry("請等候目錄載入與工作結束，再更新 rclone。", "Wait for directory loading and jobs to finish before updating rclone.", "ディレクトリの読み込みと処理が終わってから rclone を更新してください。"),
        Entry("更新後的 rclone 執行檔無法讀取。", "The updated rclone executable cannot be read.", "更新後の rclone 実行ファイルを読み取れません。"),
        Entry("無法保存 rclone 更新位置：更新程序尚未就緒。請重新檢查更新。", "Could not save the rclone location: the update process is not ready. Check for updates again.", "更新処理が準備できていないため、rclone の場所を保存できません。更新をもう一度確認してください。"),
        Entry("缺少操作參數。", "A required operation argument is missing.", "操作に必要な引数がありません。"),
        Entry("密碼格式不正確。", "The password format is invalid.", "パスワードの形式が正しくありません。"),
        Entry("不支援的操作：{}", "Unsupported operation: {}", "この操作には対応していません：{}"),
        Entry("rclone 正在更新，請稍候。", "rclone is updating. Please wait.", "rclone を更新中です。しばらくお待ちください。"),
        Entry("rclone 位置正在切換，請稍候。", "The rclone location is changing. Please wait.", "rclone の場所を変更中です。しばらくお待ちください。"),
        Entry("rclone 目前無法使用，請稍後再試。", "rclone is currently unavailable. Try again shortly.", "現在 rclone を使用できません。しばらくしてから再試行してください。"),
        Entry("rclone 正在更新。", "rclone is updating.", "rclone を更新中です。"),
        Entry("無法啟動 rclone：{}", "Could not start rclone: {}", "rclone を起動できません：{}"),
        Entry("rclone 回應逾時，請檢查連線後重試。", "rclone timed out. Check the connection and try again.", "rclone の応答がタイムアウトしました。接続を確認して再試行してください。"),
        Entry("rclone 單行輸出過大，工作已停止。", "A rclone output line was too large. The job was stopped.", "rclone の出力行が大きすぎるため、処理を停止しました。"),
        Entry("無法讀取 rclone 輸出：{}", "Could not read rclone output: {}", "rclone の出力を読み取れません：{}"),
        Entry("rclone 執行失敗（代碼 {}）：\n{}", "rclone failed (code {}):\n{}", "rclone の実行に失敗しました（コード {}）：\n{}"),
        Entry("rclone 執行失敗（代碼 {}）。", "rclone failed (code {}).", "rclone の実行に失敗しました（コード {}）。"),
        Entry("指定的執行檔不是 rclone。", "The selected executable is not rclone.", "指定した実行ファイルは rclone ではありません。"),
        Entry("找不到 rclone。", "rclone was not found.", "rclone が見つかりません。"),
        Entry("缺少 Mac 程序啟動元件，請重新安裝。", "A Mac process launch component is missing. Reinstall the app.", "Mac のプロセス起動コンポーネントがありません。アプリを再インストールしてください。"),
        Entry("rclone 未回傳有效的遠端清單，請更新 rclone。", "rclone did not return a valid remote list. Update rclone.", "rclone から有効なリモート一覧が返されませんでした。rclone を更新してください。"),
        Entry("找不到遠端連線「{}」，請重新整理。", "Remote '{}' was not found. Refresh the list.", "リモート「{}」が見つかりません。一覧を更新してください。"),
        Entry("目錄超過 250,000 個項目，請選擇較小的資料夾。", "The directory has more than 250,000 items. Choose a smaller folder.", "ディレクトリの項目数が 250,000 件を超えています。小さいフォルダを選択してください。"),
        Entry("rclone 未回傳有效的目錄清單。", "rclone did not return a valid directory listing.", "rclone から有効なディレクトリ一覧が返されませんでした。"),
        Entry("同名項目已存在。", "An item with the same name already exists.", "同じ名前の項目がすでに存在します。"),
        Entry("新名稱已存在，請選擇其他名稱。", "The new name already exists. Choose another name.", "その名前はすでに使用されています。別の名前を指定してください。"),
        Entry("原項目已不存在或類型已改變。", "The original item no longer exists or its type has changed.", "元の項目が存在しないか、種類が変更されています。"),
        Entry("來源項目仍存在，目標端可能已有同名項目，請重新整理確認。", "The source file still exists and a same-named item may be at the destination. Refresh to check both locations.", "転送元ファイルが残っています。転送先に同名の項目がある可能性があります。両方の場所を更新して確認してください。"),
        Entry("部分內容仍留在原資料夾，請一併檢查新舊兩個資料夾。", "Some contents remain in the original folder. Check both folders.", "元のフォルダに一部の内容が残っています。両方のフォルダを確認してください。"),
        Entry("「{}」已不存在或類型已改變，請重新整理。", "'{}' no longer exists or its type has changed. Refresh the list.", "「{}」が存在しないか、種類が変更されています。一覧を更新してください。"),
        Entry("無法讀取資料夾。", "Could not read the folder.", "フォルダを読み取れません。"),
        Entry("rclone 未回傳有效的容量資訊。", "rclone did not return valid size information.", "rclone から有効なサイズ情報が返されませんでした。"),
        Entry("同步會刪除目標端多出的檔案（本次最多刪除 {} 個；達上限前已刪除的檔案不會復原）。", "Sync deletes destination files absent from the source, up to {} files this time. Deletions made before the limit is reached are not undone.", "同期では転送元に存在しない転送先のファイルを削除します。今回の上限は {} 件です。上限に達する前に削除したファイルは元に戻りません。"),
        Entry("同步會刪除目標端多出的檔案（本次不限刪除數量）。", "Sync deletes destination files absent from the source. No deletion limit is set for this run.", "同期では転送元に存在しない転送先のファイルを削除します。今回は削除数の上限を設定していません。"),
        Entry("移動會在檔案傳送成功後刪除來源檔案。", "Move removes source files after successful transfer.", "移動では、転送が成功したあとに転送元ファイルを削除します。"),
        Entry("已開啟「刪除目標中符合排除規則的檔案」：目標端符合排除規則的檔案也會被刪除。", "Delete excluded is on: destination files matching exclusion rules will also be deleted.", "除外した項目の削除が有効です。除外ルールに一致する転送先ファイルも削除します。"),
        Entry("目標端多出的檔案會在傳輸開始前先刪除；若後續傳輸失敗，已刪除的檔案不會復原。", "Extra destination files will be deleted before transfer. A later transfer failure will not restore them.", "転送開始前に転送先の余分なファイルを削除します。その後に転送が失敗しても復元されません。"),
        Entry("本次會重傳範圍內的所有檔案（即使目標已有相同檔案）。", "All files in scope will be retransferred, even if the destination has identical contents.", "転送先に同じ内容があっても、対象範囲のすべてのファイルを再転送します。"),
        Entry("本機比對僅檢查檔案大小與修改時間，不讀取檔案內容算雜湊。", "Local comparison uses file size and modification time without reading file contents for hashes.", "ローカルではサイズと更新日時で比較し、ハッシュ計算のためにファイルの内容を読み込みません。"),
        Entry("本機比對僅檢查檔案大小，不讀取檔案內容算雜湊。", "Local comparison uses file size without reading file contents for hashes.", "ローカルではサイズで比較し、ハッシュ計算のためにファイルの内容を読み込みません。"),
        Entry("本機比對僅檢查修改時間，不讀取檔案內容算雜湊。", "Local comparison uses modification time without reading file contents for hashes.", "ローカルでは更新日時で比較し、ハッシュ計算のためにファイルの内容を読み込みません。"),
        Entry("偵測到 {}，時間容許差已自動設為 {}，避免因磁碟時間精度差異而重傳。", "Detected {}. Modification-time tolerance is set to {} to avoid retransfers caused by filesystem timestamp precision.", "{} を検出したため、更新日時の許容誤差を {} に設定しました。ファイルシステムの日時精度による再転送を防ぎます。"),
        Entry("已略過傳完後的雜湊驗證（傳送前的比對仍依所選比對方式執行）。", "Post-transfer hash verification is off. Pre-transfer hash comparison still follows the selected comparison method.", "転送後のハッシュ検証は無効です。転送前のハッシュ比較は、選択した比較方法に従います。"),
        Entry("預演不會實際改動檔案，以下為模擬統計結果。", "A dry run does not change files. Transfer statistics are simulated.", "試行ではファイルを変更しません。転送統計はシミュレーションの結果です。"),
        Entry("只處理勾選範圍內且符合篩選規則的檔案（開始前會先掃描來源）。", "Only files within the selection that match the include rules are in scope. The source is scanned before starting.", "選択範囲内で、含めるルールに一致するファイルを対象にします。開始前に転送元を走査します。"),
        Entry("只將勾選的來源資料夾同步至目標同名子資料夾，未勾選的目標資料夾不會更動。", "Sync only the selected source folders into same-named destination subfolders. Unselected destination contents are left unchanged.", "転送元で選択したフォルダのみ、転送先の同名サブフォルダに同期します。選択範囲外の転送先の内容は変更しません。"),
        Entry("只同步勾選資料夾內符合包含規則的檔案（開始前會先掃描兩端檔名；該範圍內目標多出的檔案也會一併刪除）。", "Only files within the selected folders that match the include rules are in scope. Both sides are listed first; destination-only files in this scope are included for sync deletion.", "選択フォルダ内で、含めるルールに一致するファイルを対象にします。最初に両側のファイル名を取得し、この範囲内で転送先にのみ存在するファイルも同期の削除対象に含めます。"),
        Entry("工作紀錄已達 200 筆，請先清除已結束的工作。", "Job history has reached 200 entries. Clear finished jobs first.", "処理履歴が 200 件に達しました。完了した処理を先に消去してください。"),
        Entry("無法儲存工作，未開始傳輸：{}", "The job could not be saved. Transfer did not start: {}", "処理を保存できなかったため、転送は開始していません：{}"),
        Entry("無法儲存工作。", "Could not save the job.", "処理を保存できません。"),
        Entry("正在套用選取範圍與包含規則。", "Applying the selection and include rules.", "選択範囲と含めるルールを適用しています。"),
        Entry("選取清單超過 250,000 個項目，請縮小來源範圍。", "The selection exceeds 250,000 items. Narrow the source scope.", "選択項目が 250,000 件を超えています。転送元の範囲を狭くしてください。"),
        Entry("遠端回傳不安全的相對路徑。", "The remote returned an unsafe relative path.", "リモートから安全でない相対パスが返されました。"),
        Entry("已取消。", "Cancelled.", "キャンセルしました。"),
        Entry("開始預演。", "Dry run started.", "試行を開始しました。"),
        Entry("開始傳輸。", "Transfer started.", "転送を開始しました。"),
        Entry("程式關閉，工作已停止。", "The app closed and the job stopped.", "アプリの終了により処理を停止しました。"),
        Entry("rclone 結束代碼：{}。請查看記錄。", "rclone exit code: {}. Check the log.", "rclone の終了コード：{}。ログを確認してください。"),
        Entry("預演完成，檔案未變更。", "Dry run complete. No files were changed.", "試行が完了しました。ファイルは変更していません。"),
        Entry("工作完成。", "Job complete.", "処理が完了しました。"),
        Entry("重試方式設定不正確。", "The retry setting is invalid.", "再試行の設定が正しくありません。"),
        Entry("第 {} 輪：只重試上一輪失敗的 {} 個檔案，不重掃其他檔案。", "Pass {}: retrying only the {} files that failed in the previous pass. Other files are not checked again.", "{} 回目：前回失敗した {} 件のファイルだけを再試行します。ほかのファイルは確認し直しません。"),
        Entry("第 {} 輪：因有不屬於單一檔案的錯誤，重新檢查全部檔案。", "Pass {}: checking all files again, because an error did not name a specific file.", "{} 回目：特定のファイルに対応しないエラーがあったため、すべてのファイルを確認し直します。"),
        Entry("第 {} 輪：因上一輪有資料夾讀取失敗，重新檢查全部檔案。", "Pass {}: checking all files again, because a folder could not be read and must be listed again.", "{} 回目：読み取れなかったフォルダを一覧し直すため、すべてのファイルを確認し直します。"),
        Entry("第 {} 輪：因失敗檔案數過多，改為重新檢查全部檔案。", "Pass {}: checking all files again, because too many files failed.", "{} 回目：失敗したファイルが多すぎるため、すべてのファイルを確認し直します。"),
        Entry("第 {} 輪：因開啟了「刪除排除項目」，只重試部分檔案會誤刪其他檔案，改為重新檢查全部檔案。", "Pass {}: checking all files again, because Delete excluded files is on. Retrying only some files would delete the others.", "{} 回目：「除外項目を削除」がオンのため、すべてのファイルを確認し直します。一部だけを再試行すると、ほかのファイルが削除されます。"),
        Entry("第 {} 輪：重新檢查全部檔案，以補做先前因錯誤而暫停的刪除。", "Pass {}: checking all files again to complete deletions that were paused because of errors.", "{} 回目：エラーのため保留した削除を行うため、すべてのファイルを確認し直します。"),
        Entry("第 {} 輪：因 rclone 異常中斷且無單檔錯誤紀錄，重新檢查全部檔案。", "Pass {}: checking all files again, because rclone ended unexpectedly without reporting which file failed.", "{} 回目：rclone がどのファイルで失敗したかを示さずに終了したため、すべてのファイルを確認し直します。"),
        Entry("有 {} 個固定錯誤（如找不到檔案、無權限、檔名不支援）重試也無法解決，不再重試。", "{} errors would fail the same way again (for example not found, no permission or an unsupported name). They are not retried, and other files are not checked again.", "{} 件のエラーは再試行しても同じ結果になるため（見つからない、権限がない、使えない名前など）、再試行せず、ほかのファイルも確認し直しません。"),
        Entry("rclone 回報無法繼續的嚴重錯誤，停止重試。", "rclone reported an error it cannot continue from. No further retries.", "rclone が続行できないエラーを報告したため、これ以上再試行しません。"),
        Entry("rclone 判定這些錯誤重試也無法解決，停止重試。", "rclone determined that retrying would not fix these errors. No further retries.", "rclone はこれらのエラーが再試行しても解決しないと判断したため、これ以上再試行しません。"),
        Entry("已達 {} 輪嘗試上限，仍有未解決的錯誤。", "All {} passes were used and errors remain.", "{} 回の試行をすべて使いましたが、エラーが残っています。"),
        Entry("檔案傳輸錯誤已在重試後解決，但已達輪次上限；先前暫停的目標刪除尚未執行，下次同步時會處理。", "The errors were resolved by retrying, but no passes remain. Deletions paused because of the errors were not done; the next sync will complete them.", "エラーは再試行で解決しましたが、試行回数が残っていません。エラーのため保留した削除は行っていません。次回の同期で行われます。"),
        Entry("已取消傳輸（已完成的檔案變更不會復原）。", "Cancelled. Completed file changes are not undone.", "キャンセルしました。完了したファイルの変更は元に戻りません。"),
        Entry("工作已結束。", "The job has ended.", "処理が終了しました。"),
        Entry("記錄無法完整保存：{}", "The log could not be saved completely: {}", "ログを完全に保存できませんでした：{}"),
        Entry("工作狀態無法儲存：{}", "The job status could not be saved: {}", "処理の状態を保存できませんでした：{}"),
        Entry("無法儲存記錄：{}", "Could not save the log: {}", "ログを保存できません：{}"),
        Entry("無法儲存工作狀態：{}", "Could not save the job status: {}", "処理の状態を保存できません：{}"),
        Entry("找不到這項工作。", "This job could not be found.", "この処理が見つかりません。"),
        Entry("工作尚未結束，不能重試。", "The job has not finished and cannot be retried yet.", "処理がまだ終了していないため、再試行できません。"),
        Entry("程式關閉，排隊工作未執行。", "The app closed before the queued job started.", "アプリが終了したため、待機中の処理は実行していません。"),

        // Saved tasks, settings and immediate connection changes.
        Entry("請輸入 1 至 200 字的作業名稱。", "Enter a task name between 1 and 200 characters.", "タスク名を 1〜200 文字で入力してください。"),
        Entry("找不到要更新的作業。", "The task to update was not found.", "更新するタスクが見つかりません。"),
        Entry("最多可儲存 1,000 個作業。", "You can save up to 1,000 tasks.", "保存できるタスクは 1,000 件までです。"),
        Entry("作業檔案過大。", "The task file is too large.", "タスクファイルが大きすぎます。"),
        Entry("請匯入有效的作業 JSON，最多 1,000 筆。", "Import a valid task JSON file containing up to 1,000 tasks.", "1,000 件以内のタスクを含む有効な JSON ファイルを読み込んでください。"),
        Entry("儲存的作業總數不能超過 1,000 筆。", "The total number of saved tasks cannot exceed 1,000.", "保存するタスクの合計は 1,000 件を超えられません。"),
        Entry("設定格式不正確。", "The settings are invalid.", "設定の形式が正しくありません。"),
        Entry("語言或外觀設定不正確。", "The language or appearance setting is invalid.", "言語または外観の設定が正しくありません。"),
        Entry("預設傳輸選項格式不正確。", "The default transfer options are invalid.", "既定の転送オプションの形式が正しくありません。"),
        Entry("欄寬設定格式不正確。", "The column width settings are invalid.", "列幅の設定が正しくありません。"),
        Entry("只能設定左右面板的欄寬。", "Column widths can be set only for the left and right panes.", "列幅を設定できるのは左右のペインのみです。"),
        Entry("欄寬名稱不正確。", "The column width name is invalid.", "列幅の項目名が正しくありません。"),
        Entry("啟動位置格式不正確。", "The startup locations are invalid.", "起動時の場所の形式が正しくありません。"),
        Entry("只能設定左右面板的啟動位置。", "Startup locations can be set only for the left and right panes.", "起動時の場所を設定できるのは左右のペインのみです。"),
        Entry("代理伺服器設定不正確。", "The proxy settings are invalid.", "プロキシ設定が正しくありません。"),
        Entry("App 更新檢查目前不支援 https:// 代理伺服器，請改用 http:// 或 socks5://（rclone 傳輸仍可使用 https:// 代理）。", "Update checks do not currently support https:// proxy addresses. Use http:// or socks5:// for updates; rclone transfers can still use an https:// proxy.", "更新確認では現在 https:// のプロキシアドレスに対応していません。更新には http:// または socks5:// を使用してください。rclone の転送では引き続き https:// プロキシを使用できます。"),
        Entry("代理伺服器請填入如 http://127.0.0.1:7890 的網址，不可包含帳號密碼。", "Enter a proxy URL such as http://127.0.0.1:7890 without a username or password.", "プロキシには http://127.0.0.1:7890 などの URL を入力してください。ユーザー名やパスワードは含められません。"),
        Entry("不使用代理的位址請以逗號分隔，不要加入空白。", "Separate proxy bypass addresses with commas and no spaces.", "プロキシを使用しないアドレスは、空白を入れずにカンマで区切ってください。"),
        Entry("播放器參數最多 32 個，每行填入一個參數。", "Enter up to 32 player arguments, one per line.", "プレーヤーの引数は 1 行に 1 つ、32 個まで入力できます。"),
        Entry("設定已在其他操作中更新，請重新整理後再試。", "Another operation updated the settings. Refresh and try again.", "別の操作で設定が更新されました。再読み込みしてからお試しください。"),
        Entry("指定的設定檔不存在或不是檔案。", "The selected configuration file does not exist or is not a file.", "指定した設定ファイルが存在しないか、ファイルではありません。"),
        Entry("請等候傳輸或更新結束，再切換 rclone、設定檔或網路設定。", "Wait for transfers or updates to finish before changing rclone, its configuration or network settings.", "転送または更新が完了してから、rclone、設定ファイル、ネットワーク設定を変更してください。"),
        Entry("目前的目錄讀取尚未結束。請稍後再切換位置。", "The directory is still loading. Wait before changing the location.", "ディレクトリを読み込み中です。しばらく待ってから場所を変更してください。"),
        Entry("傳輸已開始，請等候工作結束再切換位置。", "A transfer has started. Wait for it to finish before changing the location.", "転送が開始されました。完了してから場所を変更してください。"),
        Entry("找不到這項工作的記錄。", "The log for this job was not found.", "この処理のログが見つかりません。"),

        // Directory tools, public links, mounts and streaming. Provider output
        // in the action wrappers below is intentionally a literal capture.
        Entry("目錄深度必須介於 1 與 64。", "Directory depth must be between 1 and 64.", "ディレクトリの深さは 1〜64 で指定してください。"),
        Entry("請選擇本機匯出位置。", "Choose a local export location.", "書き出し先にローカルの場所を選択してください。"),
        Entry("匯出資料夾不存在。", "The export folder does not exist.", "書き出し先のフォルダが存在しません。"),
        Entry("匯出位置必須是一般檔案，不能是資料夾或符號連結。", "The export destination must be a regular file, not a folder or symbolic link.", "書き出し先には通常のファイルを指定してください。フォルダやシンボリックリンクは指定できません。"),
        Entry("無法在這個資料夾建立匯出檔案。", "Could not create the export file in this folder.", "このフォルダに書き出すファイルを作成できません。"),
        Entry("清單超過 512 MB，請選擇較小的目錄再匯出。", "The listing exceeds 512 MB. Choose a smaller directory to export.", "一覧が 512 MB を超えています。小さいディレクトリを選択して書き出してください。"),
        Entry("寫入匯出檔案失敗：{}", "Could not write the export file: {}", "書き出しファイルに書き込めません：{}"),
        Entry("無法儲存匯出檔案；原檔案未被替換。", "Could not save the export. The original file was not replaced.", "書き出したファイルを保存できませんでした。元のファイルは置き換えていません。"),
        Entry("公開連結只適用於支援分享功能的雲端位置。", "Public links are available only for cloud locations that support sharing.", "公開リンクは、共有に対応するクラウドでのみ作成できます。"),
        Entry("rclone 沒有回傳有效的公開連結。", "rclone did not return a valid public link.", "rclone から有効な公開リンクが返されませんでした。"),
        Entry("掛載選項過多。", "Too many mount options.", "マウントオプションが多すぎます。"),
        Entry("掛載選項不能重複。", "Mount options cannot be duplicated.", "マウントオプションを重複して指定できません。"),
        Entry("掛載只接受唯讀與 VFS 快取模式選項。", "Mount accepts only read-only and VFS cache mode options.", "マウントでは読み取り専用と VFS キャッシュモードのみ指定できます。"),
        Entry("請選擇要掛載的雲端位置。", "Choose a cloud location to mount.", "マウントするクラウドの場所を選択してください。"),
        Entry("請選擇本機掛載資料夾。", "Choose a local mount folder.", "マウント先にローカルフォルダを選択してください。"),
        Entry("掛載位置必須是已存在的空資料夾（不可為符號連結）。", "The mount location must be an existing empty folder, not a symbolic link.", "マウント先には既存の空のフォルダを指定してください。シンボリックリンクは指定できません。"),
        Entry("圖形介面的掛載功能目前只支援 macOS。", "Mounting from this app is currently available only on macOS.", "このアプリからのマウントは現在 macOS のみに対応しています。"),
        Entry("這個資料夾已經有進行中的掛載。", "This folder already has an active mount.", "このフォルダはすでにマウントに使用されています。"),
        Entry("請選擇已安裝播放器的執行檔。", "Choose the executable of an installed player.", "インストール済みプレーヤーの実行ファイルを選択してください。"),
        Entry("播放器參數格式不正確。", "The player arguments are invalid.", "プレーヤーの引数の形式が正しくありません。"),
        Entry("串流播放只能選擇檔案，不能選擇資料夾。", "Choose a file to stream. Folders cannot be streamed.", "ストリーミング再生するファイルを選択してください。フォルダは再生できません。"),
        Entry("無法啟動串流：{}", "Could not start the stream: {}", "ストリーミング再生を開始できません：{}"),
        Entry("無法卸載。請先關閉使用這個磁碟的檔案，再重試。\n{}", "Could not unmount. Close files using this disk and try again.\n{}", "マウントを解除できません。このディスクのファイルを閉じてから再試行してください。\n{}"),
        Entry("工作尚未停止，請稍候再試。", "The job has not stopped yet. Try again shortly.", "処理がまだ停止していません。しばらくしてから再試行してください。"),
        Entry("最多可同時執行 16 個掛載或串流。", "Up to 16 mounts or streams can run at the same time.", "マウントとストリーミング再生は合計 16 件まで同時に実行できます。"),
        Entry("工具輸出尚未關閉，請確認播放器是否仍在執行。", "The tool's output is still open. Check whether the player is still running.", "ツールの出力がまだ閉じていません。プレーヤーが実行中か確認してください。"),
        Entry("rclone 或播放器提早結束。", "rclone or the player exited early.", "rclone またはプレーヤーが途中で終了しました。"),
        Entry("rclone 或工具的執行位置與參數不正確。", "The rclone or tool executable location or arguments are invalid.", "rclone またはツールの実行ファイルの場所、もしくは引数が正しくありません。"),
        Entry("無法執行工具：{}", "Could not run the tool: {}", "ツールを実行できません：{}"),
        Entry("操作逾時。\n{}", "The operation timed out.\n{}", "操作がタイムアウトしました。\n{}"),
        Entry("工具的輸出尚未結束，請稍後重試。", "The tool's output is still open. Try again shortly.", "ツールの出力がまだ閉じていません。しばらくしてから再試行してください。"),
        Entry("讀寫工具輸出失敗：{}", "Could not read or write tool output: {}", "ツールの出力の読み書きに失敗しました：{}"),
        Entry("讀取目錄樹失敗（代碼 {}）。", "Could not read the directory tree (code {}).", "ディレクトリツリーを読み取れませんでした（コード {}）。"),
        Entry("讀取目錄樹失敗（代碼 {}）。\n{}", "Could not read the directory tree (code {}).\n{}", "ディレクトリツリーを読み取れませんでした（コード {}）。\n{}"),
        Entry("匯出檔案清單失敗（代碼 {}）。", "Could not export the file list (code {}).", "ファイル一覧を書き出せませんでした（コード {}）。"),
        Entry("匯出檔案清單失敗（代碼 {}）。\n{}", "Could not export the file list (code {}).\n{}", "ファイル一覧を書き出せませんでした（コード {}）。\n{}"),
        Entry("建立公開連結失敗（代碼 {}）。", "Could not create a public link (code {}).", "公開リンクを作成できませんでした（コード {}）。"),
        Entry("建立公開連結失敗（代碼 {}）。\n{}", "Could not create a public link (code {}).\n{}", "公開リンクを作成できませんでした（コード {}）。\n{}"),
        Entry("無法讀取要播放的檔案（代碼 {}）。", "Could not read the file to play (code {}).", "再生するファイルを読み取れませんでした（コード {}）。"),
        Entry("無法讀取要播放的檔案（代碼 {}）。\n{}", "Could not read the file to play (code {}).\n{}", "再生するファイルを読み取れませんでした（コード {}）。\n{}"),
        Entry("目前無法使用 FUSE 掛載；請確認 rclone 支援 mount，並已安裝 macFUSE 或 FUSE-T（代碼 {}）。", "This rclone cannot use FUSE mounting. Use an engine that supports mount and an installed macFUSE or FUSE-T (code {}).", "この rclone では FUSE マウントを利用できません。mount に対応するエンジンと、インストール済みの macFUSE または FUSE-T を使用してください（コード {}）。"),
        Entry("目前無法使用 FUSE 掛載；請確認 rclone 支援 mount，並已安裝 macFUSE 或 FUSE-T（代碼 {}）。\n{}", "This rclone cannot use FUSE mounting. Use an engine that supports mount and an installed macFUSE or FUSE-T (code {}).\n{}", "この rclone では FUSE マウントを利用できません。mount に対応するエンジンと、インストール済みの macFUSE または FUSE-T を使用してください（コード {}）。\n{}"),

        // Updater validation and recovery. File paths and OS diagnostics stay
        // unchanged, even when they happen to equal an app phrase.
        Entry("更新版本格式不正確。", "The update version is invalid.", "更新するバージョンの形式が正しくありません。"),
        Entry("下載與安裝 Mac 版 rclone 必須在 Mac 執行。", "Downloading and installing rclone for Mac must be done on a Mac.", "Mac 版 rclone のダウンロードとインストールは Mac で実行してください。"),
        Entry("下載檔裡沒有唯一的 rclone 執行檔。", "The download does not contain exactly one rclone executable.", "ダウンロードしたファイル内の rclone 実行ファイルを一意に特定できません。"),
        Entry("rclone 解壓縮失敗，原本的版本保持不變。", "Could not extract rclone. Your existing version is unchanged.", "rclone を展開できませんでした。既存のバージョンは変更していません。"),
        Entry("無法讀取官方校驗資訊。", "Could not read the official checksum information.", "公式のチェックサム情報を読み取れません。"),
        Entry("官方校驗表找不到唯一的對應檔案，已停止安裝。", "The official checksum list does not identify exactly one matching file. Installation stopped.", "公式チェックサム一覧で対応するファイルを一意に特定できないため、インストールを停止しました。"),
        Entry("此位置由 App 或套件管理工具管理。請另外選擇自己管理的資料夾來存放並更新 rclone。", "This location is managed by an app or package manager. Choose your own rclone folder to download updates.", "この場所はアプリまたはパッケージ管理ツールが管理しています。更新をダウンロードするには、自分で管理する rclone フォルダを選択してください。"),
        Entry("不能直接替換符號連結或資料夾。請選擇獨立的 rclone 執行檔。", "A symbolic link or folder cannot be replaced directly. Choose a standalone rclone executable.", "シンボリックリンクやフォルダは直接置き換えられません。独立した rclone 実行ファイルを選択してください。"),
        Entry("更新暫存檔不在所選 rclone 資料夾內。", "The update temporary file is not in the selected rclone folder.", "更新用の一時ファイルが、選択した rclone フォルダ内にありません。"),
        Entry("備份位置不是一般資料夾，已停止更新。", "The backup location is not a regular folder. Update stopped.", "バックアップ先が通常のフォルダではないため、更新を停止しました。"),
        Entry("舊版備份驗證失敗，已停止更新。", "Validation of the previous version's backup failed. Update stopped.", "旧バージョンのバックアップの検証に失敗したため、更新を停止しました。"),
        Entry("無法替換 rclone：{}", "Could not replace rclone: {}", "rclone を置き換えられません：{}"),
        Entry("新安裝的 rclone 驗證失敗，且無法移除。\n檔案位置：{}\n{}", "The newly installed rclone failed validation and could not be removed.\nFile location: {}\n{}", "新しくインストールした rclone の検証に失敗し、削除もできませんでした。\nファイルの場所：{}\n{}"),
        Entry("新安裝的 rclone 驗證失敗，已移除。\n{}", "The newly installed rclone failed validation and was removed.\n{}", "新しくインストールした rclone の検証に失敗したため、削除しました。\n{}"),
        Entry("更新網址不在 rclone 官方下載站。", "The update URL is not on the official rclone download server.", "更新 URL が rclone の公式ダウンロードサイトではありません。"),
        Entry("無法建立更新暫存檔。", "Could not create the update temporary file.", "更新用の一時ファイルを作成できません。"),
        Entry("無法執行 {}：{}", "Could not run {}: {}", "{} を実行できません：{}"),
        Entry("rclone 作業逾時，原本的版本保持不變。", "The rclone operation timed out. Your existing version is unchanged.", "rclone の操作がタイムアウトしました。既存のバージョンは変更していません。"),
        Entry("rclone 已結束，但輸出尚未關閉，已停止更新。", "rclone exited but its output is still open. Update stopped.", "rclone は終了しましたが出力が閉じていないため、更新を停止しました。"),
        Entry("官方下載站轉址到未允許的位置，已停止下載。", "The official download server redirected to a disallowed location. Download stopped.", "公式ダウンロードサイトが許可されていない場所へリダイレクトしたため、ダウンロードを停止しました。"),
        Entry("下載檔超過允許大小，已停止下載。", "The download exceeds the size limit. Download stopped.", "ファイルがサイズ上限を超えたため、ダウンロードを停止しました。"),
        Entry("rclone 不是有效的 Mac 執行檔。", "rclone is not a valid Mac executable.", "rclone が有効な Mac 実行ファイルではありません。"),
        Entry("Mac 執行檔的架構表不完整。", "The Mac executable's architecture table is incomplete.", "Mac 実行ファイルのアーキテクチャテーブルが不完全です。"),
        Entry("新版 rclone 不包含這台 Mac 的處理器架構。", "The new rclone does not include this Mac's processor architecture.", "新しい rclone にこの Mac のプロセッサアーキテクチャが含まれていません。"),
        Entry("Mac 執行檔的架構範圍不正確。", "The Mac executable's architecture range is invalid.", "Mac 実行ファイルのアーキテクチャの範囲が正しくありません。"),
        Entry("新版 rclone 的執行檔格式或架構不符。", "The new rclone executable's format or architecture is incompatible.", "新しい rclone 実行ファイルの形式またはアーキテクチャが対応していません。"),
        Entry("Mac 執行檔的載入資訊不完整。", "The Mac executable's load information is incomplete.", "Mac 実行ファイルのロード情報が不完全です。"),
        Entry("Mac 執行檔已截斷。", "The Mac executable is truncated.", "Mac 実行ファイルの一部が欠けています。"),
        Entry("Mac 執行檔的載入資訊已截斷。", "The Mac executable's load information is truncated.", "Mac 実行ファイルのロード情報の一部が欠けています。"),
        Entry("Mac 執行檔包含無效載入指令。", "The Mac executable contains an invalid load command.", "Mac 実行ファイルに無効なロードコマンドが含まれています。"),
        Entry("新版 rclone 的目標平台不是 macOS。", "The new rclone does not target macOS.", "新しい rclone の対象プラットフォームが macOS ではありません。"),
        Entry("macOS 最低版本資訊不完整。", "The minimum macOS version information is incomplete.", "必要な macOS の最低バージョン情報が不完全です。"),
        Entry("無法確認新版 rclone 的 macOS 需求，已保留原版。", "Could not verify the new rclone's macOS requirements. The previous version was kept.", "新しい rclone に必要な macOS を確認できなかったため、元のバージョンを保持しました。"),
        Entry("這份官方 rclone 需要 macOS {} 以上（高於目前系統版本）。已保留原有的 rclone，請改選其他相容版本。", "This official rclone executable requires macOS {}, which is newer than this system. Your existing rclone is unchanged; you can select another compatible version.", "この公式 rclone 実行ファイルには、現在のシステムより新しい macOS {} が必要です。既存の rclone は変更していません。対応する別のバージョンを選択できます。"),

        // Finder drops and native file dialogs.
        Entry("一次最多拖入 10,000 個項目。", "Drop up to 10,000 items at a time.", "一度にドロップできる項目は 10,000 件までです。"),
        Entry("請從 Finder 拖入本機檔案或資料夾。", "Drag local files or folders from Finder.", "Finder からローカルのファイルまたはフォルダをドラッグしてください。"),
        Entry("請拖入資料夾內的項目。", "Drag items from inside a folder.", "フォルダ内の項目をドラッグしてください。"),
        Entry("單次拖放請選取同一個資料夾內的項目；不同資料夾請分批拖入。", "Drop items from the same folder together. Add different source folders separately.", "一度にドロップする項目は同じフォルダから選択してください。別のフォルダの項目は分けて追加できます。"),
        Entry("拖入的項目不是可傳輸的檔案或資料夾。", "The dropped item is not a transferable file or folder.", "ドロップした項目は転送できるファイルまたはフォルダではありません。"),
        Entry("請拖入檔案或資料夾。", "Drag a file or folder.", "ファイルまたはフォルダをドラッグしてください。"),
        Entry("請直接拖入原始檔案或資料夾（拖放不支援符號連結）。", "Drag the original file or folder. Drag and drop does not follow symbolic links.", "元のファイルまたはフォルダをドラッグしてください。ドラッグ＆ドロップではシンボリックリンクをたどりません。"),
        Entry("App 缺少資源資料夾。請重新建置。", "The app's Resources folder is missing. Build the app again.", "アプリの Resources フォルダがありません。アプリを再ビルドしてください。"),
        Entry("App 缺少介面檔案。請重新建置。", "The app's interface files are missing. Build the app again.", "アプリの画面ファイルがありません。アプリを再ビルドしてください。"),
        Entry("無法開啟 Rclone Browser Next", "Could not open Rclone Browser Next", "Rclone Browser Next を開けません"),
        Entry("檔案類型不正確。", "The file type is invalid.", "ファイルの種類が正しくありません。"),
        Entry("只能開啟 rclone 官方網站與參考專案。", "Only the official rclone websites and reference projects can be opened.", "開けるのは rclone の公式サイトと参考プロジェクトのみです。"),
        Entry("無法開啟瀏覽器。", "Could not open the browser.", "ブラウザを開けません。"),
        Entry("匯出格式不正確。", "The export format is invalid.", "書き出し形式が正しくありません。"),
        Entry("快取模式不正確。", "The cache mode is invalid.", "キャッシュモードが正しくありません。")
    ]

    // This is a closed set of labels passed by the app to EngineJSON validation.
    // A value is looked up here only when its template explicitly marks that
    // capture as a label. The same words in paths or raw errors stay untouched.
    private static let fieldLabels: [String: (String, String)] = [
        "本機 IP 位址": ("Local IP address", "ローカル IP アドレス"),
        "同時傳輸數": ("Concurrent transfers", "同時転送数"), "同時檢查檔案數": ("Concurrent file checks", "同時チェック数"),
        "工作嘗試次數": ("Job attempts", "ジョブの試行回数"),
        "傳輸方向": ("Transfer direction", "転送方向"), "連線位址模式": ("Connection address mode", "接続アドレスのモード"),
        "來源 IP 位址": ("Source IP address", "接続元 IP アドレス"), "瞬間請求上限": ("Request burst limit", "リクエストのバースト上限"),
        "User-Agent": ("User-Agent", "User-Agent"), "停用 HTTP/2": ("Disable HTTP/2", "HTTP/2 を無効化"),
        "尚未安裝": ("Not installed", "未インストール"),
        "路徑": ("Path", "パス"), "遠端連線名稱": ("Remote name", "リモート名"),
        "名稱": ("Name", "名前"), "項目類型": ("Item type", "項目の種類"),
        "平行傳輸數": ("Parallel transfers", "並列転送数"), "平行檢查數": ("Parallel checks", "並列チェック数"),
        "重試次數": ("Retry count", "再試行回数"), "最多刪除數": ("Maximum deletions", "削除上限"),
        "連線重試次數": ("Connection retries", "接続の再試行回数"), "目錄深度": ("Directory depth", "ディレクトリの深さ"),
        "傳輸選項": ("Transfer options", "転送オプション"), "限速": ("Bandwidth limit", "帯域制限"),
        "比較方式": ("Comparison method", "比較方法"), "刪除時機": ("Deletion timing", "削除のタイミング"),
        "本機雜湊讀取": ("Local hashing", "ローカルのハッシュ計算"), "符號連結": ("Symbolic links", "シンボリックリンク"),
        "最小檔案大小": ("Minimum file size", "最小ファイルサイズ"), "最大檔案大小": ("Maximum file size", "最大ファイルサイズ"),
        "最小檔案年齡": ("Minimum file age", "最小経過時間"), "最大檔案年齡": ("Maximum file age", "最大経過時間"),
        "時間容許誤差": ("Modification-time tolerance", "更新日時の許容誤差"),
        "連線逾時": ("Connection timeout", "接続タイムアウト"), "傳輸閒置逾時": ("Idle transfer timeout", "転送の無通信タイムアウト"),
        "重試間隔": ("Retry interval", "再試行間隔"), "篩選規則": ("Filter rule", "フィルタールール"),
        "其他選項": ("Additional option", "追加オプション"), "傳輸模式": ("Transfer mode", "転送モード"),
        "預演設定": ("Dry-run setting", "試行設定"), "工作名稱": ("Job name", "処理名"),
        "工作編號": ("Job ID", "処理 ID"), "建立時間": ("Creation time", "作成日時"),
        "報告格式": ("Report format", "レポート形式"), "報告分類": ("Report category", "レポート分類"),
        "報告位置": ("Report cursor", "レポートの読み取り位置"), "每頁筆數": ("Rows per page", "ページあたりの件数"),
        "工作狀態": ("Job status", "処理の状態"), "作業編號": ("Task ID", "タスク ID"),
        "作業名稱": ("Task name", "タスク名"), "更新時間": ("Updated time", "更新日時"),
        "rclone 執行檔": ("rclone executable", "rclone 実行ファイル"), "參數": ("Argument", "引数"),
        "相對路徑": ("Relative path", "相対パス"), "rclone 資料夾": ("rclone folder", "rclone フォルダ"),
        "設定檔": ("Configuration file", "設定ファイル"), "播放器": ("Player", "プレーヤー"),
        "語言": ("Language", "言語"), "外觀": ("Appearance", "外観"),
        "啟動時檢查更新": ("Check updates at startup", "起動時の更新確認"), "介面設定": ("Interface setting", "インターフェース設定"),
        "略過版本": ("Skipped version", "スキップしたバージョン"), "設定版本": ("Settings revision", "設定のリビジョン"),
        "同時執行的工作數": ("Concurrent jobs", "同時実行する処理数"), "欄寬": ("Column width", "列幅"),
        "介面比例": ("Interface scale", "表示倍率"), "停止狀態": ("Stop status", "停止状態"),
        "代理伺服器設定": ("Proxy setting", "プロキシ設定"), "代理伺服器": ("Proxy server", "プロキシサーバー"),
        "不使用代理的位址": ("Proxy bypass addresses", "プロキシを使用しないアドレス"),
        "播放器參數": ("Player argument", "プレーヤーの引数"), "檔案類型": ("File type", "ファイルの種類"),
        "網址": ("URL", "URL"), "更新檢查方式": ("Update check mode", "更新確認の方法"),
        "文字": ("Text", "テキスト"), "檔案名稱": ("Filename", "ファイル名"),
        "資料夾": ("Folder", "フォルダ"), "唯讀": ("Read only", "読み取り専用")
    ]

    private static let exactEntries: [String: Entry] = Dictionary(entries.filter { $0.expression == nil }.map { ($0.source, $0) }, uniquingKeysWith: { first, _ in first })
    // Prefer a diagnostic wrapper over its shorter, code-only variant. Without
    // this order a final punctuation mark inside stderr could look like the end
    // of the shorter template and become part of the "exit code" capture.
    private static let templateEntries = entries.enumerated().filter { $0.element.expression != nil }.sorted {
        let left = $0.element.sourcePieces.reduce(0) { $0 + $1.utf8.count }
        let right = $1.element.sourcePieces.reduce(0) { $0 + $1.utf8.count }
        return left == right ? $0.offset < $1.offset : left > right
    }.map { $0.element }

    static func japanese(_ source: String, fallback: String) -> String {
        translated(source, language: "ja") ?? fallback
    }

    static func translate(_ source: String, language: String) -> String {
        guard language == "en" || language == "ja" else { return source }
        return translated(source, language: language) ?? source
    }

    private static func translated(_ source: String, language: String) -> String? {
        guard source.utf8.count <= 65536 else { return nil }
        if let entry = exactEntries[source] { return language == "ja" ? entry.japanese : entry.english }
        for entry in templateEntries {
            let output = language == "ja" ? entry.japanese : entry.english
            guard source.hasPrefix(entry.sourcePieces.first!), source.hasSuffix(entry.sourcePieces.last!) else { continue }
            // A path can contain newline-delimited text that resembles the next
            // field. If a separator occurs more than once, the original message
            // is safer than guessing where that user-controlled value ends.
            let separators = entry.sourcePieces.dropFirst().dropLast().filter { !$0.isEmpty }
            guard separators.allSatisfy({ separator in
                let literalCount = entry.sourcePieces.reduce(0) { $0 + $1.components(separatedBy: separator).count - 1 }
                return source.components(separatedBy: separator).count - 1 <= literalCount
            }) else { return nil }
            // Reject ambiguous delimiters before regex evaluation as well, so
            // repeated provider text cannot trigger excessive backtracking.
            guard let match = entry.expression?.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) else { continue }
            let pieces = output.components(separatedBy: "{}")
            guard pieces.count == match.numberOfRanges else { continue }
            var text = pieces[0]
            for index in 1..<pieces.count {
                guard let range = Range(match.range(at: index), in: source) else { return nil }
                let value = String(source[range])
                // Only explicitly marked app-owned field labels may translate.
                // Never recursively translate a captured path, filename, version,
                // URL, process error or provider diagnostic.
                if entry.labelCaptures.contains(index), let labels = fieldLabels[value] {
                    text += language == "ja" ? labels.1 : labels.0
                } else { text += value }
                text += pieces[index]
            }
            return text
        }
        return nil
    }
}

#endif
