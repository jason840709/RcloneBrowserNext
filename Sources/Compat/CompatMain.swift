#if !os(macOS)
import Foundation

/// The compatibility window talks to the same engine as the Mac app over
/// inherited pipes. There is no HTTP server, listening port or remote page.
final class CompatEngineHost {
    let engine: RcloneEngine
    let tools: RcloneTools
    let updater: RcloneUpdater
    let releases: RBNAppReleaseChecker
    private let outputLock = NSLock()
    private let controlLock = NSRecursiveLock()
    private var configuring = false
    private var closing = false

    init(stateDirectory: URL, rcloneDirectory: URL) throws {
        engine = try RcloneEngine(stateDirectory: stateDirectory, defaultRcloneDirectory: rcloneDirectory)
        tools = try RcloneTools(workDirectory: stateDirectory.appendingPathComponent("tools"))
        updater = try RcloneUpdater(workDirectory: stateDirectory.appendingPathComponent("updates"))
        releases = try RBNAppReleaseChecker(repository: RBNProject.repository)
        engine.onJobUpdate = { [weak self] job in self?.event("jobUpdate", data: job) }
        tools.onSessionUpdate = { [weak self] session in self?.event("toolSessionUpdate", data: session) }
        updater.onStatus = { [weak self] status in self?.event("updateStatus", data: status) }
        updater.connectionSettings = { [weak self] in self?.engine.settingsSnapshot() ?? [:] }
    }

    var language: String { RBNLanguageResolver.resolve(engine.settingsSnapshot()["language"] as? String ?? "system") }

    func translatedError(_ message: String) -> String {
        RBNNativeStrings.translate(message, language: language)
    }

    func send(_ object: [String: Any]) {
        guard var bytes = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        bytes.append(10)
        outputLock.lock(); defer { outputLock.unlock() }
        try? FileHandle.standardOutput.write(contentsOf: bytes)
    }

    func event(_ type: String, data: Any) { send(["event": ["type": type, "data": data]]) }

    private func withTools<T>(_ action: (RcloneTools.Context) throws -> T) throws -> T {
        try controlLock.holding {
            guard !closing, !configuring else { throw EngineError("請先結束帳號設定，再執行工具。") }
            return try engine.withAuxiliaryOperation {
                let context = try engine.auxiliaryContext()
                return try action(.init(binary: context.binary, arguments: context.arguments, environment: context.environment))
            }
        }
    }

    func handle(_ method: String, arguments: [Any]) throws -> Any {
        func argument(_ index: Int) -> Any? { arguments.indices.contains(index) ? arguments[index] : nil }
        func text(_ index: Int, _ label: String = "參數") throws -> String { try EngineJSON.text(argument(index), label, maximum: 32768) }
        // These private methods can only be called by the trusted native host.
        // Its renderer allowlist never forwards a leading underscore.
        switch method {
        case "accountConfig":
            guard !tools.hasActiveSessions, !controlLock.holding({ configuring || closing }) else { throw EngineError("請先結束終端機設定或播放，再開啟圖形帳號設定。") }
            return try engine.invoke(method, arguments: arguments)
        case "_accountAuthorization": return try engine.accounts.authorizationURL().absoluteString
        case "_cancelListings": engine.cancelListings(); return true
        case "_preferences":
            return ["settings": engine.settingsSnapshot(), "resolvedLanguage": language]
        case "_state":
            let quit = engine.quitSummary()
            return ["activeJobs": quit.activeJobs > 0, "activeTools": tools.hasActiveSessions, "quit": quit.json,
                    "configuring": controlLock.holding { configuring }, "settings": engine.settingsSnapshot(), "resolvedLanguage": language]
        case "_normalizeTransfer": return try engine.normalizedRequest(argument(0) ?? NSNull()).json
        case "_shutdown":
            try controlLock.holding {
                guard !configuring else { throw EngineError("請先關閉帳號設定視窗，再結束程式。") }
                try tools.shutdown()
                closing = true
                engine.shutdown()
            }
            return true
        case "_beginConfiguration":
            return try controlLock.holding {
                guard !closing, !configuring, !tools.hasActiveSessions else { throw EngineError("請先停止播放，再開啟帳號設定。") }
                let context = try engine.auxiliaryContext()
                try engine.setMaintenance(true)
                configuring = true
                return ["binary": context.binary, "arguments": context.arguments, "environment": context.environment]
            }
        case "_endConfiguration":
            try controlLock.holding { configuring = false; try engine.setMaintenance(false) }
            event("configurationChanged", data: [:])
            return true
        case "_checkRclone":
            let manual = try EngineJSON.bool(argument(0) ?? true, "更新檢查方式")
            let settings = engine.settingsSnapshot()
            if !manual && settings["autoCheckUpdates"] as? Bool == false { return ["status": "disabled"] }
            let resolved = try? engine.resolvedRclonePath()
            let target = try RcloneUpdater.defaultTarget(settings: settings, resolvedPath: resolved)
            let current = FileManager.default.isExecutableFile(atPath: target) ? target : (manual ? nil : resolved)
            if !manual && current == nil { return ["status": "notInstalled"] }
            var result = try updater.check(currentPath: current, skippedVersion: settings["skippedRcloneVersion"] as? String ?? "", manual: manual)
            result["targetPath"] = target
            result["settingsRevision"] = settings["settingsRevision"] ?? 0
            return result
        case "_installRclone":
            return try controlLock.holding {
                guard !closing, !configuring, !tools.hasActiveSessions else { throw EngineError("請先結束帳號設定，並停止播放，再更新 rclone。") }
                let version = try text(0, "版本")
                let revision = try EngineJSON.integer(argument(1), "設定版本", 0...Int.max)
                try engine.setMaintenance(true)
                defer { try? engine.setMaintenance(false) }
                let settings = engine.settingsSnapshot()
                guard (settings["settingsRevision"] as? Int ?? 0) == revision else { throw EngineError("設定已變更，請重新檢查更新。") }
                let target = try RcloneUpdater.defaultTarget(settings: settings, resolvedPath: try? engine.resolvedRclonePath())
                let current = FileManager.default.isExecutableFile(atPath: target) ? target : nil
                let result = try updater.install(version: version, targetPath: target, currentPath: current)
                try engine.commitRcloneUpdate(path: result["path"] as? String ?? target)
                return result
            }
        case "checkAppUpdates": return try releases.check(settings: engine.settingsSnapshot()).json
        case "directoryTree":
            let endpoint = try EngineEndpoint(argument(0)), depth = try EngineJSON.integer(argument(1) ?? 4, "目錄深度", 1...64)
            return try withTools { try RcloneTools.tree(context: $0, endpoint: endpoint, maxDepth: depth) }
        case "_exportFileList":
            let endpoint = try EngineEndpoint(argument(0)), format = try text(1), destination = URL(fileURLWithPath: try text(2))
            guard ["csv", "txt"].contains(format) else { throw EngineError("匯出格式不正確。") }
            return try withTools { try RcloneTools.exportList(context: $0, endpoint: endpoint, destination: destination, filenamesOnly: format == "txt") }
        case "publicLink":
            let endpoint = try EngineEndpoint(argument(0)), name = try text(1), isDir = try EngineJSON.bool(argument(2), "資料夾")
            return try withTools { try RcloneTools.publicLink(context: $0, endpoint: endpoint, name: name, isDir: isDir).absoluteString }
        case "_startMount":
            let endpoint = try EngineEndpoint(argument(0)), point = URL(fileURLWithPath: try text(2))
            let options = argument(1) as? [String: Any] ?? [:]
            let readOnly = try EngineJSON.bool(options["readOnly"] ?? true, "唯讀")
            let cache = options["cacheMode"] as? String ?? "writes"
            return try withTools { try tools.startMount(context: $0, endpoint: endpoint, mountPoint: point,
                                                       options: (readOnly ? ["--read-only"] : []) + ["--vfs-cache-mode", cache]) }
        case "_startStream":
            let endpoint = try EngineEndpoint(argument(0)), name = try text(1), settings = engine.settingsSnapshot()
            let player = settings["streamPlayerPath"] as? String ?? ""
            return try withTools { try tools.startStream(context: $0, endpoint: endpoint, name: name, player: URL(fileURLWithPath: player),
                                                        playerArgs: settings["streamPlayerArguments"] as? [String] ?? ["-"]) }
        case "listToolSessions": return tools.listSessions()
        case "stopToolSession": return try tools.stopSession(text(0))
        case "_exportTo":
            let kind = try text(0), id = try text(1), destination = URL(fileURLWithPath: try text(2))
            let format = argument(3) as? String ?? "jsonl"
            let source: String
            if kind == "report" {
                guard let value = try engine.invoke("getJobReportPath", arguments: [id, format]) as? String else { throw EngineError("找不到工作記錄。") }
                source = value
            } else if kind == "log" {
                guard let value = try engine.invoke("getLogPath", arguments: [id]) as? String else { throw EngineError("找不到工作記錄。") }
                source = value
            } else { throw EngineError("匯出格式不正確。") }
            defer { if kind == "report" { try? FileManager.default.removeItem(atPath: source) } }
            try Self.copyExport(from: URL(fileURLWithPath: source), to: destination)
            return destination.path
        case "_exportTasks":
            let destination = URL(fileURLWithPath: try text(0))
            try EngineStorage.atomicJSON(engine.invoke("exportTasks", arguments: []), to: destination)
            return destination.path
        case "_importTasks":
            let source = URL(fileURLWithPath: try text(0))
            let attrs = try FileManager.default.attributesOfItem(atPath: source.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular,
                  (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= 8 * 1024 * 1024 else { throw EngineError("作業檔必須是 8 MiB 以內的 JSON 檔案。") }
            return try engine.invoke("importTasks", arguments: [JSONSerialization.jsonObject(with: Data(contentsOf: source))])
        default:
            let permitted: Set<String> = ["bootstrap", "list", "cancelList", "mkdir", "rename", "remove", "size", "previewTransfer", "startTransfer", "cancelJob", "retryJob", "listJobs", "clearFinishedJobs", "clearJobs", "saveTask", "deleteTask", "listTasks", "saveSettings", "unlockConfig", "getJobReport"]
            guard permitted.contains(method) else { throw EngineError("不支援這項操作。") }
            #if os(Windows)
            if method == "bootstrap", let result = try engine.invoke(method, arguments: arguments) as? [String: Any] {
                return WindowsLocalFileSystem.bootstrap(result)
            }
            if ["list", "mkdir", "rename", "remove", "size"].contains(method) {
                let endpoint = try EngineEndpoint(argument(0))
                if endpoint.remote == nil {
                    switch method {
                    case "list": return try engine.listDirectory(endpoint, options: argument(1), localListing: WindowsLocalFileSystem.list)
                    case "size": return try WindowsLocalFileSystem.size(endpoint)
                    case "mkdir": try WindowsLocalFileSystem.mkdir(endpoint, name: text(1)); return NSNull()
                    case "rename":
                        try WindowsLocalFileSystem.rename(endpoint, name: text(1), newName: text(2),
                                                          isDirectory: EngineJSON.bool(argument(3), "項目類型"))
                        return NSNull()
                    case "remove":
                        try WindowsLocalFileSystem.remove(endpoint, selection: EngineSelection.parse(argument(1)))
                        return true
                    default: break
                    }
                }
            }
            #endif
            if method == "saveSettings" {
                let patch = argument(0) as? [String: Any] ?? [:]
                let connectionKeys = ["rclonePath", "rcloneDirectory", "configPath", "proxyMode", "httpProxy", "httpsProxy", "noProxy", "defaultRcloneOptions", "networkOptions"]
                if connectionKeys.contains(where: { patch[$0] != nil }) {
                    return try controlLock.holding {
                        guard !closing, !configuring, !tools.hasActiveSessions else {
                            throw EngineError("請先結束帳號設定或播放，再變更 rclone 位置與連線設定。")
                        }
                        return try engine.invoke(method, arguments: arguments)
                    }
                }
                // Appearance, language and workspace preferences apply even
                // while the account terminal or an engine update is open.
                return try engine.invoke(method, arguments: arguments)
            }
            if ["startTransfer", "retryJob"].contains(method) {
                return try controlLock.holding {
                    guard !closing, !configuring else { throw EngineError("請先結束帳號設定，再執行這項操作。") }
                    return try engine.invoke(method, arguments: arguments)
                }
            }
            return try engine.invoke(method, arguments: arguments)
        }
    }

    private static func copyExport(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: destination.path), attrs[.type] as? FileAttributeType != .typeRegular {
            throw EngineError("請選擇一般檔案作為匯出位置。")
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".rbn-export-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temporary) }
        let input = try FileHandle(forReadingFrom: source), output = try EnginePlatform.createExclusiveFile(temporary)
        defer { try? input.close(); try? output.close() }
        while let bytes = try input.read(upToCount: 65536), !bytes.isEmpty { try output.write(contentsOf: bytes) }
        try output.synchronize(); try output.close(); try input.close()
        try EnginePlatform.replaceFile(temporary.path, destination.path)
    }
}

@main
enum CompatMain {
    static func main() {
        do {
            let args = CommandLine.arguments
            guard args.count == 5, args[1] == "--state-dir", args[3] == "--engine-dir" else {
                throw EngineError("Usage: rbn-engine --state-dir PATH --engine-dir PATH")
            }
            let host = try CompatEngineHost(stateDirectory: URL(fileURLWithPath: args[2]), rcloneDirectory: URL(fileURLWithPath: args[4]))
            let queue = DispatchQueue(label: "RcloneBrowser.compat.requests", qos: .userInitiated, attributes: .concurrent)
            let group = DispatchGroup()
            while let line = readLine() {
                guard line.utf8.count <= 8 * 1024 * 1024,
                      let data = line.data(using: .utf8),
                      let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = raw["id"] as? String, !id.isEmpty, id.count <= 96,
                      let method = raw["method"] as? String, method.count <= 80,
                      let arguments = raw["args"] as? [Any], arguments.count <= 8 else { continue }
                if method == "list" {
                    do { try host.engine.prepareListing(options: arguments.count > 1 ? arguments[1] : nil) }
                    catch { host.send(["id": id, "error": host.translatedError(error.localizedDescription)]); continue }
                }
                group.enter()
                // Stop listings before placing shutdown behind their workers.
                // Waiting at the barrier first would defer cancellation until
                // the very directory read we intend to stop had timed out.
                if method == "_shutdown" { host.engine.cancelListings() }
                // Quit snapshots follow every already-submitted operation. The
                // native host blocks new submissions while deciding to quit.
                let flags: DispatchWorkItemFlags = ["_state", "_shutdown"].contains(method) ? .barrier : []
                // Stop controls must bypass a previously queued state barrier;
                // that barrier may itself be waiting for the folder being read.
                let targetQueue = ["cancelList", "_cancelListings"].contains(method) ? DispatchQueue.global(qos: .userInitiated) : queue
                targetQueue.async(flags: flags) {
                    defer { group.leave() }
                    do { host.send(["id": id, "result": try host.handle(method, arguments: arguments)]) }
                    catch { host.send(["id": id, "error": host.translatedError(error.localizedDescription)]) }
                }
            }
            host.engine.cancelListings()
            group.wait()
            _ = try? host.handle("_shutdown", arguments: [])
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
#endif
