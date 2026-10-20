import Foundation
#if canImport(Darwin)
import Darwin
#elseif os(Windows)
import ucrt
#else
import Glibc
#endif

/// The secondary operations from the original Rclone Browser. The host supplies
/// a fresh, trusted engine snapshot for every action; credentials never appear
/// in session JSON. No command is interpreted by a shell.
final class RcloneTools {
    struct Context {
        let binary: String
        let arguments: [String]
        let environment: [String: String]
        init(binary: String, arguments: [String] = [], environment: [String: String] = [:]) {
            self.binary = binary; self.arguments = arguments; self.environment = environment
        }
    }

    private let workDirectory: URL
    private let lock = NSRecursiveLock()
    private let workers = DispatchQueue(label: "RcloneBrowser.tools", qos: .utility, attributes: .concurrent)
    private var sessions: [String: RBNToolSession] = [:]
    private var sessionOrder: [String] = []
    private var closing = false
    var onSessionUpdate: (([String: Any]) -> Void)?

    init(workDirectory: URL) throws {
        self.workDirectory = workDirectory.standardizedFileURL
        try EngineStorage.privateDirectory(self.workDirectory)
    }

    var hasActiveSessions: Bool { lock.holding { sessions.values.contains { $0.status == "running" } } }

    func listSessions() -> [[String: Any]] {
        lock.holding { sessionOrder.reversed().compactMap { sessions[$0]?.json } }
    }

    /// Directory-only tree matches the original browser's `tree -d` action.
    /// Large trees are visibly truncated, never passed to the WebView unbounded.
    static func tree(context: Context, endpoint: EngineEndpoint, maxDepth: Int = 4) throws -> [String: Any] {
        guard (1...64).contains(maxDepth) else { throw EngineError("目錄深度必須介於 1 與 64。") }
        let result = try run(context: context,
                             arguments: ["tree"] + context.arguments + ["--dirs-only", "--max-depth", String(maxDepth), "--log-level", "ERROR", "--", endpoint.argument],
                             maximumOutput: 1024 * 1024, timeout: 120)
        try requireSuccess(result, action: "讀取目錄樹失敗")
        return ["text": result.text, "truncated": result.truncated, "maxDepth": maxDepth]
    }

    /// Writes rclone's real CSV (path, bytes, time) directly to a private staging
    /// file. A failed listing cannot leave a partial report over an existing file.
    /// `filenamesOnly` preserves the original browser's plain-text export mode.
    static func exportList(context: Context, endpoint: EngineEndpoint, destination: URL,
                           filenamesOnly: Bool = false) throws -> [String: Any] {
        guard destination.isFileURL else { throw EngineError("請選擇本機匯出位置。") }
        let destination = destination.standardizedFileURL
        let parent = destination.deletingLastPathComponent()
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &directory), directory.boolValue else {
            throw EngineError("匯出資料夾不存在。")
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path),
           attrs[.type] as? FileAttributeType != .typeRegular {
            throw EngineError("匯出位置必須是一般檔案，不能是資料夾或符號連結。")
        }
        let temporary = parent.appendingPathComponent(".rbn-export-" + UUID().uuidString)
        let output = try EnginePlatform.createExclusiveFile(temporary)
        var committed = false
        defer { try? output.close(); if !committed { try? FileManager.default.removeItem(at: temporary) } }
        if !filenamesOnly { try output.write(contentsOf: Data("Path,Size,Modified\n".utf8)) }
        let sink = RBNToolsOutput(limit: 512 * 1024 * 1024, file: output, csv: !filenamesOnly)
        var arguments = ["lsf"] + context.arguments + ["--recursive", "--files-only", "--format", filenamesOnly ? "p" : "pst"]
        if !filenamesOnly { arguments += ["--csv", "--separator", ","] }
        // Exclude only this unpredictable staging filename if the user exports
        // inside the directory being listed; no user's file is filtered out.
        arguments += ["--exclude", temporary.lastPathComponent, "--log-level", "ERROR", "--", endpoint.argument]
        let result = try run(context: context, arguments: arguments, maximumOutput: 0, timeout: 600, output: sink)
        try requireSuccess(result, action: "匯出檔案清單失敗")
        guard !sink.truncated else { throw EngineError("清單超過 512 MB，請選擇較小的目錄再匯出。") }
        if let error = sink.writeError { throw EngineError("寫入匯出檔案失敗：\(error)") }
        try output.synchronize()
        try output.close()
        try EnginePlatform.replaceFile(temporary.path, destination.path)
        committed = true
        return ["path": destination.path, "count": sink.recordCount, "format": filenamesOnly ? "txt" : "csv"]
    }

    /// rclone link may CREATE a public share. The host must obtain explicit
    /// confirmation for the selected file/folder before calling this method.
    static func publicLink(context: Context, endpoint: EngineEndpoint, name: String? = nil,
                           isDir: Bool = false) throws -> URL {
        guard endpoint.remote != nil else { throw EngineError("公開連結只適用於支援分享功能的雲端位置。") }
        let target = try name.map { try endpoint.child($0) } ?? endpoint
        var argument = target.argument
        if isDir && !argument.hasSuffix("/") { argument += "/" }
        let result = try run(context: context, arguments: ["link"] + context.arguments + ["--log-level", "ERROR", "--", argument],
                             maximumOutput: 32768, timeout: 90)
        try requireSuccess(result, action: "建立公開連結失敗")
        guard !result.truncated,
              let line = result.text.split(whereSeparator: { $0.isNewline }).last.map(String.init),
              line.utf8.count <= 16384, !line.unicodeScalars.contains(where: { $0.value < 33 || $0.value == 127 }),
              let url = URL(string: line), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
            throw EngineError("rclone 沒有回傳有效的公開連結。")
        }
        return url
    }

    /// Validates the deliberately small mount option surface independently of
    /// platform availability so imported data cannot enable daemon/RC/shell hooks.
    static func validatedMountOptions(_ options: [String]) throws -> [String] {
        guard options.count <= 8 else { throw EngineError("掛載選項過多。") }
        var result: [String] = [], seen = Set<String>(), index = 0
        while index < options.count {
            let key = options[index]; index += 1
            guard seen.insert(key).inserted else { throw EngineError("掛載選項不能重複。") }
            if key == "--read-only" { result.append(key); continue }
            guard key == "--vfs-cache-mode", index < options.count,
                  ["off", "minimal", "writes", "full"].contains(options[index]) else {
                throw EngineError("掛載只接受唯讀與 VFS 快取模式選項。")
            }
            result += [key, options[index]]; index += 1
        }
        if !seen.contains("--vfs-cache-mode") { result += ["--vfs-cache-mode", "writes"] }
        return result
    }

    func startMount(context: Context, endpoint: EngineEndpoint, mountPoint: URL,
                    options: [String] = []) throws -> [String: Any] {
        let options = try Self.validatedMountOptions(options)
        guard endpoint.remote != nil else { throw EngineError("請選擇要掛載的雲端位置。") }
        guard mountPoint.isFileURL else { throw EngineError("請選擇本機掛載資料夾。") }
        let selectedPoint = mountPoint.standardizedFileURL
        let attributes = try FileManager.default.attributesOfItem(atPath: selectedPoint.path)
        let point = selectedPoint.resolvingSymlinksInPath()
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              point.path != "/", (try FileManager.default.contentsOfDirectory(atPath: point.path)).isEmpty else {
            throw EngineError("掛載位置必須是既存的空資料夾，不能是符號連結。")
        }
        #if !os(macOS)
        throw EngineError("圖形介面的掛載功能目前只支援 macOS。")
        #else
        let capability = try Self.run(context: context, arguments: ["mount"] + context.arguments + ["--help"], maximumOutput: 128 * 1024, timeout: 15)
        try Self.requireSuccess(capability, action: "這個 rclone 無法使用 FUSE 掛載；請使用支援 mount 的引擎與已安裝的 macFUSE 或 FUSE-T")
        return try lock.holding {
            try ensureCanStart()
            guard !sessions.values.contains(where: { $0.kind == "mount" && $0.status == "running" && $0.destination == point.path }) else {
                throw EngineError("這個資料夾已經有進行中的掛載。")
            }
            // Each session keeps its VFS data in the selected application work
            // directory instead of inheriting rclone's global cache directory.
            let session = RBNToolSession(kind: "mount", title: endpoint.argument, destination: point.path)
            let cache = workDirectory.appendingPathComponent("mount-" + session.id, isDirectory: true)
            try EngineStorage.privateDirectory(cache)
            let arguments = ["mount"] + context.arguments + options + ["--cache-dir", cache.path, "--log-level", "INFO", "--", endpoint.argument, point.path]
            let process = try Self.makeProcess(context: context, arguments: arguments)
            let errors = Pipe(), standard = Pipe()
            process.standardError = errors; process.standardOutput = standard
            process.standardInput = FileHandle.nullDevice
            session.processes = [process]
            try EnginePlatform.prepare(process); try process.run()
            RBNToolsDrains.start(errors, into: session.logs, group: session.drains, stop: session.drainStop)
            RBNToolsDrains.start(standard, into: session.logs, group: session.drains, stop: session.drainStop)
            register(session)
            monitor(session)
            return session.json
        }
        #endif
    }

    func startStream(context: Context, endpoint: EngineEndpoint, name: String,
                     player: URL, playerArgs: [String] = ["-"]) throws -> [String: Any] {
        let target = try endpoint.child(name)
        guard player.isFileURL, EnginePlatform.absoluteLocalPath(player.path), FileManager.default.isExecutableFile(atPath: player.path) else {
            throw EngineError("請選擇已安裝播放器的執行檔。")
        }
        guard playerArgs.count <= 64, playerArgs.reduce(0, { $0 + $1.utf8.count }) <= 16384,
              playerArgs.allSatisfy({ !$0.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) }) else {
            throw EngineError("播放器參數格式不正確。")
        }
        if target.remote == nil {
            let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw EngineError("串流播放只能選擇檔案，不能選擇資料夾。")
            }
        } else {
            let metadata = try Self.run(context: context,
                                         arguments: ["lsjson"] + context.arguments + ["--stat", "--no-mimetype", "--no-modtime", "--log-level", "ERROR", "--", target.argument],
                                         maximumOutput: 65536, timeout: 60)
            try Self.requireSuccess(metadata, action: "無法讀取要播放的檔案")
            guard !metadata.truncated,
                  let object = try? JSONSerialization.jsonObject(with: Data(metadata.text.utf8)) as? [String: Any],
                  object["IsDir"] as? Bool == false else {
                throw EngineError("串流播放只能選擇檔案，不能選擇資料夾。")
            }
        }
        return try lock.holding {
            try ensureCanStart()
            let session = RBNToolSession(kind: "stream", title: target.argument, destination: player.lastPathComponent)
            let producer = try Self.makeProcess(context: context,
                                                arguments: ["cat"] + context.arguments + ["--log-level", "ERROR", "--", target.argument])
            // The player consumes stdin. It does not need cloud, proxy or rclone
            // credentials that the engine may have inherited for a remote.
            let playerKeys: Set<String> = ["PATH", "HOME", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR",
                                            "DISPLAY", "WAYLAND_DISPLAY", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS",
                                            "LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH"]
            let playerEnvironment = context.environment.filter { playerKeys.contains($0.key) }
            let consumer = try Self.makeProcess(context: Context(binary: player.path, environment: playerEnvironment), arguments: playerArgs)
            let media = Pipe(), producerErrors = Pipe(), consumerErrors = Pipe()
            producer.standardInput = FileHandle.nullDevice; producer.standardOutput = media; producer.standardError = producerErrors
            consumer.standardInput = media; consumer.standardOutput = FileHandle.nullDevice; consumer.standardError = consumerErrors
            session.processes = [producer, consumer]
            do {
                try EnginePlatform.prepare(consumer)
                try EnginePlatform.prepare(producer)
                try consumer.run()
                try producer.run()
            } catch {
                Self.terminate(consumer)
                try? media.fileHandleForReading.close(); try? media.fileHandleForWriting.close()
                throw EngineError("無法啟動串流：\(error.localizedDescription)")
            }
            // The children own the pipe ends now. Keeping a parent writer open
            // would prevent the player from ever receiving EOF.
            try? media.fileHandleForReading.close(); try? media.fileHandleForWriting.close()
            RBNToolsDrains.start(producerErrors, into: session.logs, group: session.drains, stop: session.drainStop)
            RBNToolsDrains.start(consumerErrors, into: session.logs, group: session.drains, stop: session.drainStop)
            register(session)
            monitor(session)
            return session.json
        }
    }

    @discardableResult
    func stopSession(_ id: String) throws -> [String: Any] {
        guard let session = lock.holding({ sessions[id] }) else { throw EngineError("找不到這個工作。") }
        return try session.stopLock.holding {
            guard lock.holding({ session.status == "running" }) else { return lock.holding { session.json } }
            #if os(macOS)
            if session.kind == "mount", session.processes.first?.isRunning == true {
                let unmount = try Self.run(context: Context(binary: "/sbin/umount", environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]),
                                           arguments: [session.destination], maximumOutput: 8192, timeout: 30)
                guard unmount.status == 0 else {
                    throw EngineError("無法卸載。請先關閉使用這個磁碟的檔案，再重試。\n" + Self.cleanError(unmount.errorText))
                }
            }
            #endif
            lock.holding { session.stopRequested = true }
            // For streams, stop the consumer first so no more media is needed.
            for process in session.processes.reversed() { Self.terminate(process) }
            guard session.finished.wait(timeout: .now() + 8) == .success else {
                throw EngineError("工作尚未停止，請稍候再試。")
            }
            return lock.holding { session.json }
        }
    }

    /// A busy mount throws. The host must keep the app open on this error rather
    /// than silently force-unmounting or abandoning buffered writes.
    func shutdown() throws {
        let ids = lock.holding { () -> [String] in
            closing = true
            return sessionOrder.filter { sessions[$0]?.status == "running" }
        }
        do { for id in ids { try stopSession(id) } }
        catch { lock.holding { closing = false }; throw error }
    }

    private func ensureCanStart() throws {
        guard !closing else { throw EngineError("程式正在關閉。") }
        guard sessions.values.filter({ $0.status == "running" }).count < 16 else { throw EngineError("最多可同時執行 16 個掛載或串流。") }
    }

    private func register(_ session: RBNToolSession) {
        session.finished.enter()
        sessions[session.id] = session; sessionOrder.append(session.id)
        while sessionOrder.count > 100, let old = sessionOrder.first(where: { sessions[$0]?.status != "running" }) {
            sessions.removeValue(forKey: old); sessionOrder.removeAll { $0 == old }
        }
    }

    private func monitor(_ session: RBNToolSession) {
        workers.async { [self] in
            var playerClosed = false
            while session.processes.contains(where: { $0.isRunning }) {
                if session.kind == "stream", session.processes.count == 2 {
                    let producer = session.processes[0], consumer = session.processes[1]
                    if !consumer.isRunning && producer.isRunning {
                        playerClosed = consumer.terminationStatus == 0
                        Self.terminate(producer)
                    } else if !producer.isRunning && producer.terminationStatus != 0 && consumer.isRunning {
                        Self.terminate(consumer)
                    }
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            let drainFailed = session.drains.wait(timeout: .now() + 2) != .success
            if drainFailed {
                session.drainStop.set()
                _ = session.drains.wait(timeout: .now() + 1)
            }
            let result: [String: Any] = lock.holding {
                if session.stopRequested || playerClosed { session.status = "stopped" }
                else if drainFailed || session.logs.writeError != nil || session.processes.contains(where: { $0.terminationStatus != 0 }) {
                    session.status = "failed"
                    let detail = Self.cleanError(session.logs.text)
                    session.error = drainFailed ? "工具的輸出尚未結束，請檢查播放器是否仍在執行。" : (session.logs.writeError ?? (detail.isEmpty ? "rclone 或播放器提早結束。" : detail))
                } else { session.status = "completed" }
                return session.json
            }
            session.finished.leave()
            onSessionUpdate?(result)
        }
    }

    private static func makeProcess(context: Context, arguments: [String]) throws -> Process {
        var directory: ObjCBool = false
        guard EnginePlatform.absoluteLocalPath(context.binary), FileManager.default.fileExists(atPath: context.binary, isDirectory: &directory), !directory.boolValue,
              FileManager.default.isExecutableFile(atPath: context.binary),
              !context.binary.utf8.contains(0), arguments.count <= 256,
              arguments.reduce(0, { $0 + $1.utf8.count }) <= 262144,
              !arguments.contains(where: { $0.utf8.contains(0) }) else {
            throw EngineError("rclone 或工具的執行位置與參數不正確。")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: context.binary)
        process.arguments = arguments
        process.environment = context.environment
        return process
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        EnginePlatform.signal(process.processIdentifier, SIGTERM)
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { EnginePlatform.signal(process.processIdentifier, SIGKILL) }
    }

    private struct Result {
        let status: Int32
        let text: String
        let errorText: String
        let truncated: Bool
    }

    private static func run(context: Context, arguments: [String], maximumOutput: Int, timeout: TimeInterval,
                             output: RBNToolsOutput? = nil) throws -> Result {
        let process = try makeProcess(context: context, arguments: arguments)
        let standard = Pipe(), errors = Pipe(), finished = DispatchSemaphore(value: 0)
        let output = output ?? RBNToolsOutput(limit: maximumOutput)
        let errorOutput = RBNToolsOutput(limit: 65536, retainTail: true)
        let drains = DispatchGroup(), drainStop = RBNToolsStop()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = standard; process.standardError = errors
        process.terminationHandler = { _ in finished.signal() }
        do { try EnginePlatform.prepare(process); try process.run() }
        catch { throw EngineError("無法執行工具：\(error.localizedDescription)") }
        RBNToolsDrains.start(standard, into: output, group: drains, stop: drainStop)
        RBNToolsDrains.start(errors, into: errorOutput, group: drains, stop: drainStop)
        let expired = finished.wait(timeout: .now() + timeout) != .success
        if expired { terminate(process); _ = finished.wait(timeout: .now() + 3) }
        let drained = drains.wait(timeout: .now() + 2) == .success
        if !drained { drainStop.set(); _ = drains.wait(timeout: .now() + 1) }
        if expired { throw EngineError("操作逾時。\n" + cleanError(errorOutput.text)) }
        guard drained else { throw EngineError("工具的輸出尚未結束，請稍後重試。") }
        if let error = output.writeError ?? errorOutput.writeError { throw EngineError("讀寫工具輸出失敗：\(error)") }
        return Result(status: process.terminationStatus, text: output.text, errorText: errorOutput.text, truncated: output.truncated)
    }

    private static func requireSuccess(_ result: Result, action: String) throws {
        guard result.status == 0 else {
            let detail = cleanError(result.errorText.isEmpty ? result.text : result.errorText)
            throw EngineError("\(action)（代碼 \(result.status)）。" + (detail.isEmpty ? "" : "\n" + detail))
        }
    }

    private static func cleanError(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value >= 32 || $0 == "\n" || $0 == "\t" })).suffix(8192).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class RBNToolSession {
    let id = UUID().uuidString
    let kind: String
    let title: String
    let destination: String
    let createdAt = EngineJSON.now()
    var status = "running"
    var error: String?
    var stopRequested = false
    var processes: [Process] = []
    let logs = RBNToolsOutput(limit: 65536, retainTail: true)
    let drains = DispatchGroup()
    let drainStop = RBNToolsStop()
    let finished = DispatchGroup()
    let stopLock = NSLock()
    init(kind: String, title: String, destination: String) {
        self.kind = kind; self.title = title; self.destination = destination
    }
    var json: [String: Any] {
        var result: [String: Any] = ["id": id, "kind": kind, "title": title, "status": status, "destination": destination, "createdAt": createdAt]
        if let error = error { result["error"] = error }
        return result
    }
}

private final class RBNToolsStop {
    private let lock = NSLock()
    private var stopped = false
    func set() { lock.holding { stopped = true } }
    var value: Bool { lock.holding { stopped } }
}

private final class RBNToolsOutput {
    private let lock = NSLock()
    private let limit: Int
    private let file: FileHandle?
    private let csv: Bool
    private let retainTail: Bool
    private var bytes = Data()
    private var total = 0
    private var overflow = false
    private var failure: String?
    private var records = 0
    private var quoted = false
    init(limit: Int, file: FileHandle? = nil, csv: Bool = false, retainTail: Bool = false) {
        self.limit = limit; self.file = file; self.csv = csv; self.retainTail = retainTail
    }
    func append(_ data: Data) {
        lock.holding {
            let remaining = max(0, limit - total)
            total += data.count
            if total > limit { overflow = true }
            if let file = file {
                guard failure == nil, !overflow else { return }
                do { try file.write(contentsOf: data) } catch { failure = error.localizedDescription; return }
                for byte in data {
                    if csv && byte == 34 { quoted.toggle() }
                    if byte == 10 && !quoted { records += 1 }
                }
            } else if retainTail {
                bytes.append(data)
                if bytes.count > limit { bytes.removeFirst(bytes.count - limit) }
            } else if remaining > 0 { bytes.append(data.prefix(remaining)) }
        }
    }
    func recordFailure(_ error: String) { lock.holding { if failure == nil { failure = error } } }
    var text: String { lock.holding { String(decoding: bytes, as: UTF8.self) } }
    var truncated: Bool { lock.holding { overflow } }
    var writeError: String? { lock.holding { failure } }
    var recordCount: Int { lock.holding { records } }
}

private enum RBNToolsDrains {
    static func start(_ pipe: Pipe, into output: RBNToolsOutput, group: DispatchGroup, stop: RBNToolsStop) {
        try? pipe.fileHandleForWriting.close()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { try? pipe.fileHandleForReading.close(); group.leave() }
            while !stop.value {
                do {
                    guard try EnginePlatform.waitReadable(pipe.fileHandleForReading) else { continue }
                    let bytes = try EnginePlatform.readAvailable(pipe.fileHandleForReading)
                    if bytes.isEmpty { break }
                    output.append(bytes)
                } catch { output.recordFailure(error.localizedDescription); break }
            }
        }
    }
}
