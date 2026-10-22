import Foundation
#if canImport(Darwin)
import Darwin
#elseif os(Windows)
import ucrt
#else
import Glibc
#endif

/// A shell-free rclone controller shared by the macOS host and Linux integration tests.
/// invoke() is synchronous. Call it off the UI thread; submitted transfers run on workers.
final class RcloneEngine {
    let stateDirectory: URL
    let defaultRcloneDirectory: URL
    private let logDirectory: URL
    private let filterDirectory: URL
    private let stateLock = NSRecursiveLock()
    private let storageLock = NSLock()
    // Merge, write and environment detection form one settings transaction.
    // Operations reserve their context through this gate, so a folder chooser
    // can wait for a just-started listing without racing an updater or bootstrap.
    private let settingsMutationLock = NSRecursiveLock()
    private let operationQueue = DispatchQueue(label: "RcloneBrowser.work", qos: .userInitiated, attributes: .concurrent)
    private let callbackQueue = DispatchQueue(label: "RcloneBrowser.events", qos: .utility)
    private var settings: [String: Any]
    private var environment: [String: Any]
    private var jobs: [String: EngineJob] = [:]
    private var jobOrder: [String] = []
    private var tasks: [String: EngineTask] = [:]
    private var active: [String: EngineActiveJob] = [:]
    private var transferReports: [String: EngineTransferReport] = [:]
    private var captureChildren: [UUID: Process] = [:]
    private struct StopRequest {
        let jobID: String?
        var timers: [DispatchWorkItem]
    }
    private var stoppingChildren: [ObjectIdentifier: StopRequest] = [:]
    // This is an app responsiveness policy, not a guarantee made by rclone.
    // Its first exit signal runs atexit handlers; a second signal can interrupt
    // those handlers, so the full cleanup grace belongs after the first SIGINT.
    private static let interruptGrace: TimeInterval = 10
    private static let terminateGrace: TimeInterval = 2
    private static let stopWaitLimit: TimeInterval = 15
    private var operationCount = 0
    private var maintenance = false
    private var configurationChanging = false
    private var closing = false
    private var configPassword: String?
    private var callback: (([String: Any]) -> Void)?
    private var scheduledNotifications: [String: DispatchWorkItem] = [:]
    private var persistScheduled = false

    var onJobUpdate: (([String: Any]) -> Void)? {
        get { stateLock.holding { callback } }
        set { stateLock.holding { callback = newValue } }
    }
    var hasActiveJobs: Bool { stateLock.holding { jobs.values.contains { !EngineJob.terminal.contains($0.status) } } }

    /// Read one consistent job snapshot for the native quit decision. A terminal
    /// status still finishing its report/state write counts as active until its
    /// worker exits. Saved tasks have not started and do not enter this decision.
    func quitSummary() -> EngineQuitSummary {
        stateLock.holding {
            var activeCount = 0, failedCount = 0, unfinishedCount = 0
            for job in jobs.values {
                if active[job.id] != nil || !EngineJob.terminal.contains(job.status) { activeCount += 1 }
                else if job.status == "failed" { failedCount += 1 }
                else if job.status != "completed" { unfinishedCount += 1 }
            }
            return EngineQuitSummary(activeJobs: activeCount, failedJobs: failedCount, unfinishedJobs: unfinishedCount)
        }
    }

    init(stateDirectory: URL, defaultRcloneDirectory: URL) throws {
        self.stateDirectory = stateDirectory.standardizedFileURL
        self.defaultRcloneDirectory = defaultRcloneDirectory.standardizedFileURL
        logDirectory = stateDirectory.appendingPathComponent("logs", isDirectory: true)
        filterDirectory = stateDirectory.appendingPathComponent("filters", isDirectory: true)
        settings = Self.defaultSettings(directory: defaultRcloneDirectory)
        environment = Self.blankEnvironment(configPath: "")
        for directory in [stateDirectory, logDirectory, filterDirectory] { try EngineStorage.privateDirectory(directory) }
        let savedSettings = EngineStorage.readJSON(stateDirectory.appendingPathComponent("settings.json"), fallback: settings)
        settings = (try? Self.validateSettings(Self.migrateSettings(savedSettings), defaults: settings)) ?? settings
        environment = Self.blankEnvironment(configPath: settings["configPath"] as? String ?? "")
        let savedJobs = EngineStorage.readJSON(stateDirectory.appendingPathComponent("jobs.json"), fallback: [[String: Any]]())
        var clearedSuccessfulIDs: [String] = []
        for raw in (savedJobs as? [[String: Any]] ?? []) {
            if let job = try? EngineJob(saved: raw), jobs[job.id] == nil {
                // Successful history belongs to the session that completed it.
                // Failed and unfinished requests stay available for inspection
                // or an explicit retry; opening the app never reruns them.
                if job.status == "completed" { clearedSuccessfulIDs.append(job.id); continue }
                jobs[job.id] = job; jobOrder.append(job.id)
            }
        }
        let savedTasks = EngineStorage.readJSON(stateDirectory.appendingPathComponent("tasks.json"), fallback: [[String: Any]]())
        for raw in (savedTasks as? [[String: Any]] ?? []).prefix(1000) {
            if let task = try? EngineTask(raw) { tasks[task.id] = task }
        }
        for item in try FileManager.default.contentsOfDirectory(at: filterDirectory, includingPropertiesForKeys: nil) {
            if item.pathExtension == "filter", EngineJSON.validID(item.deletingPathExtension().lastPathComponent) { try? FileManager.default.removeItem(at: item) }
        }
        try persist()
        removeOwnedLogs(clearedSuccessfulIDs.filter { jobs[$0] == nil })
    }

    static func defaultSettings(directory: URL) -> [String: Any] {
        ["rclonePath": "", "rcloneDirectory": directory.path, "configPath": "", "language": "system", "theme": "purple-dark", "interfaceScale": 100,
         "autoCheckUpdates": true, "skippedRcloneVersion": "", "settingsRevision": 0, "settingsSchemaVersion": 7,
         "paneColumnWidths": [String: Any](), "defaultTransferOptions": EngineTransferOptions.defaults,
         "hiddenBuiltinPresets": [String](),
         "maxConcurrentJobs": 0, "proxyMode": "system", "httpProxy": "", "httpsProxy": "", "noProxy": "",
         "networkOptions": EngineNetworkOptions.defaults,
         "defaultRcloneOptions": [String](), "showStatusItem": false, "notifyOnCompletion": false, "bounceDockOnCompletion": true,
         "showHiddenFiles": true, "showFolderIcons": true, "showFileIcons": true, "alternatingRows": true,
         "streamPlayerPath": "", "streamPlayerArguments": ["-"], "initialLocations": [String: Any](), "savedWorkspace": NSNull()] as [String: Any]
    }

    /// Schema markers keep default upgrades from repeatedly overriding later
    /// choices. Only global defaults are migrated; task/workspace snapshots retain
    /// the options the user saved with them.
    private static func migrateSettings(_ value: Any) -> Any {
        guard var raw = value as? [String: Any] else { return value }
        let schema = raw["settingsSchemaVersion"] as? Int ?? 0
        if schema < 4 {
            if raw["maxConcurrentJobs"] as? Int == 2 { raw["maxConcurrentJobs"] = 0 }
            if var options = raw["defaultTransferOptions"] as? [String: Any] {
                for (key, previousDefault) in [("connectTimeout", "1m"), ("ioTimeout", "5m")] where options[key] as? String == previousDefault {
                    options[key] = "" // inherits the same common timeout until changed
                }
                raw["defaultTransferOptions"] = options
            }
            var network = raw["networkOptions"] as? [String: Any] ?? [:]
            if let arguments = raw["defaultRcloneOptions"] as? [String] {
                raw["defaultRcloneOptions"] = arguments.filter { argument in
                    let pieces = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    let key = pieces.first.map(String.init) ?? ""
                    guard EngineNetworkOptions.globalOwnedFlags.contains(key),
                          (try? EngineTransferOptions.validateExtraArguments([argument])) != nil else { return true }
                    let value = pieces.count > 1 ? String(pieces[1]) : "true"
                    switch key {
                    case "--tpslimit": if network["tpsLimit"] == nil { network["tpsLimit"] = Double(value) ?? 0 }
                    case "--tpslimit-burst": if network["tpsBurst"] == nil { network["tpsBurst"] = max(1, Int(value) ?? 1) }
                    case "--disable-http2": if network["disableHTTP2"] == nil { network["disableHTTP2"] = value == "true" }
                    default: break
                    }
                    return false
                }
            }
            raw["networkOptions"] = network
        }
        if schema < 5, var options = raw["defaultTransferOptions"] as? [String: Any] {
            if options["maxDelete"] as? Int == 100 { options["maxDelete"] = -1 }
            if options["deleteMode"] as? String == "after" { options["deleteMode"] = "during" }
            if !["checksum", "checksum-only"].contains(options["comparison"] as? String ?? "default"),
               options["localHashPolicy"] as? String == "default" { options["localHashPolicy"] = "none" }
            // A legacy partial checksum preference predates localHashPolicy.
            if ["checksum", "checksum-only"].contains(options["comparison"] as? String ?? "default"),
               options["localHashPolicy"] == nil { options["localHashPolicy"] = "default" }
            raw["defaultTransferOptions"] = options
        }
        if schema < 5, var workspace = raw["savedWorkspace"] as? [String: Any], let options = workspace["options"] as? [String: Any] {
            workspace["options"] = EngineTransferOptions.preservingLegacySnapshot(options)
            raw["savedWorkspace"] = workspace
        }
        // 0.8 names the previous 90% size 100%, and the previous 100% size
        // 110%. Keep every explicitly saved size visually unchanged, including
        // the older 110%/125% choices that become 120%/135% compatibility values.
        if schema < 7, let previous = raw["interfaceScale"] as? Int,
           [80, 90, 100, 110, 125].contains(previous) {
            raw["interfaceScale"] = previous + 10
        }
        raw["settingsSchemaVersion"] = 7
        return raw
    }

    private static func blankEnvironment(configPath: String) -> [String: Any] {
        let platform = EnginePlatform.identifier
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x64"
        #endif
        return ["version": "", "rclonePath": "", "configPath": configPath, "platform": platform, "arch": arch, "available": false]
    }

    func settingsSnapshot() -> [String: Any] { stateLock.holding { settings } }

    /// Returns a path without launching rclone; safe while the updater holds maintenance.
    func resolvedRclonePath() throws -> String {
        let snapshot = settingsSnapshot()
        let explicit = snapshot["rclonePath"] as? String ?? ""
        var candidates: [String] = []
        if !explicit.isEmpty { candidates = [explicit] }
        else {
            if let directory = snapshot["rcloneDirectory"] as? String, !directory.isEmpty {
                candidates.append(URL(fileURLWithPath: directory).appendingPathComponent(EnginePlatform.rcloneName).path)
            }
            candidates += EnginePlatform.executableCandidates()
        }
        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate).inserted {
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &directory), !directory.boolValue,
               FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        throw EngineError(explicit.isEmpty ? "找不到 rclone。請在設定中下載，或選擇已有的執行檔。" : "無法執行指定的 rclone，請確認路徑與執行權限。")
    }

    /// An update may replace the binary only after all jobs and browsing calls finish.
    func setMaintenance(_ enabled: Bool) throws {
        try settingsMutationLock.holding {
            try stateLock.holding {
                if enabled {
                    guard !closing else { throw EngineError("程式正在關閉。") }
                    guard !maintenance, !configurationChanging else { throw EngineError("rclone 更新或位置切換正在進行。") }
                    guard operationCount == 0, captureChildren.isEmpty, !jobs.values.contains(where: { !EngineJob.terminal.contains($0.status) }) else {
                        throw EngineError("請等候目錄載入與工作結束，再更新 rclone。")
                    }
                    maintenance = true
                } else { maintenance = false }
            }
        }
    }

    /// Native updater only. Keep the maintenance lock until the replacement and
    /// its selected path have both been committed; this never starts a process.
    func commitRcloneUpdate(path: String) throws {
        let validPath = try EngineJSON.text(path, "rclone 執行檔", maximum: 32768)
        guard EnginePlatform.absoluteLocalPath(validPath), FileManager.default.isExecutableFile(atPath: validPath) else {
            throw EngineError("更新後的 rclone 執行檔無法讀取。")
        }
        try settingsMutationLock.holding {
            try storageLock.holding {
                let changed = try stateLock.holding { () -> [String: Any] in
                    guard maintenance, !closing, operationCount == 0, captureChildren.isEmpty,
                          !jobs.values.contains(where: { !EngineJob.terminal.contains($0.status) }) else {
                        throw EngineError("無法保存 rclone 更新位置：更新程序尚未就緒。請重新檢查更新。")
                    }
                    var changed = settings
                    let url = URL(fileURLWithPath: validPath).standardizedFileURL
                    changed["rclonePath"] = url.path
                    changed["rcloneDirectory"] = url.deletingLastPathComponent().path
                    changed["skippedRcloneVersion"] = ""
                    changed["settingsRevision"] = (settings["settingsRevision"] as? Int ?? 0) + 1
                    return changed
                }
                try EngineStorage.atomicJSON(changed, to: stateDirectory.appendingPathComponent("settings.json"))
                stateLock.holding {
                    settings = changed
                    environment = Self.blankEnvironment(configPath: changed["configPath"] as? String ?? "")
                    environment["settingsRevision"] = changed["settingsRevision"]
                }
            }
        }
    }

    func invoke(_ method: String, arguments: [Any]) throws -> Any {
        func argument(_ index: Int) throws -> Any {
            guard arguments.indices.contains(index) else { throw EngineError("缺少操作參數。") }; return arguments[index]
        }
        func text(_ index: Int, _ name: String = "參數") throws -> String { try EngineJSON.text(argument(index), name, maximum: 32768) }
        switch method {
        case "bootstrap": return try bootstrap()
        case "environment", "refreshEnvironment": return try withOperation { try detectEnvironment() }
        case "list": return try list(EngineEndpoint(argument(0)))
        case "mkdir": try mkdir(EngineEndpoint(argument(0)), name: text(1, "名稱")); return NSNull()
        case "rename": try renameEntry(EngineEndpoint(argument(0)), name: text(1), newName: text(2), isDir: EngineJSON.bool(argument(3), "項目類型")); return NSNull()
        case "remove": try remove(EngineEndpoint(argument(0)), selection: EngineSelection.parse(argument(1))); return true
        case "size": return try size(EngineEndpoint(argument(0)))
        case "previewTransfer": return try withOperation { try preview(prepareRequest(argument(0))) }
        case "startTransfer": return try startTransfer(argument(0))
        case "cancelJob": try cancelJob(text(0, "工作編號")); return NSNull()
        case "retryJob": return try retryJob(text(0, "工作編號"))
        case "listJobs": return listJobs()
        case "clearFinishedJobs": try clearFinishedJobs(); return NSNull()
        case "clearJobs": return try clearJobs(argument(0))
        case "saveTask": return try saveTask(name: text(0, "作業名稱"), value: argument(1), id: arguments.count > 2 && !(arguments[2] is NSNull) ? text(2, "作業編號") : nil)
        case "deleteTask": try deleteTask(text(0, "作業編號")); return NSNull()
        case "listTasks": return listTasks()
        case "saveSettings": return try saveSettings(argument(0))
        case "unlockConfig":
            guard let password = try argument(0) as? String else { throw EngineError("密碼格式不正確。") }
            try unlockConfig(password); return NSNull()
        case "getLogPath", "exportLog": return try getLogPath(text(0, "工作編號"))
        case "getJobReport": return try getJobReport(text(0, "工作編號"), query: arguments.count > 1 ? argument(1) : [String: Any]())
        case "getJobReportPath": return try getJobReportPath(text(0, "工作編號"), format: arguments.count > 1 ? text(1, "報告格式") : "jsonl")
        case "exportTasks": return ["format": "rclone-browser-next-tasks", "version": 1, "tasks": listTasks()] as [String: Any]
        case "importTasks": return try importTasks(argument(0))
        default: throw EngineError("不支援的操作：\(method)")
        }
    }

    private func withOperation<T>(_ body: () throws -> T) throws -> T {
        try settingsMutationLock.holding {
            try stateLock.holding {
                guard !closing else { throw EngineError("程式正在關閉。") }
                guard !maintenance else { throw EngineError("rclone 正在更新，請稍候。") }
                guard !configurationChanging else { throw EngineError("rclone 位置正在切換，請稍候。") }
                operationCount += 1
            }
        }
        defer { stateLock.holding { operationCount -= 1 } }
        return try body()
    }

    private func childEnvironment() -> [String: String] {
        var result = ProcessInfo.processInfo.environment.filter { !$0.key.uppercased().hasPrefix("RCLONE_") }
        let snapshot = settingsSnapshot()
        if snapshot["proxyMode"] as? String == "manual" {
            result = result.filter { !["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"].contains($0.key.uppercased()) }
            for (key, variable) in [("httpProxy", "HTTP_PROXY"), ("httpsProxy", "HTTPS_PROXY"), ("noProxy", "NO_PROXY")] {
                if let value = snapshot[key] as? String, !value.isEmpty { result[variable] = value }
            }
        }
        if let password = stateLock.holding({ configPassword }) { result["RCLONE_CONFIG_PASS"] = password }
        return result
    }

    private func configuredArguments(_ arguments: [String]) -> [String] {
        let snapshot = settingsSnapshot()
        let path = snapshot["configPath"] as? String ?? ""
        // A transfer may explicitly override one of the permitted tuning flags.
        // All host-owned and credential flags were rejected during validation.
        let explicitKeys = Set(arguments.prefix { $0 != "--" }.map { String($0.split(separator: "=", maxSplits: 1)[0]) })
        let network = (try? EngineNetworkOptions(snapshot["networkOptions"]))?.arguments ?? []
        let defaults = (network + (snapshot["defaultRcloneOptions"] as? [String] ?? [])).filter {
            !explicitKeys.contains(String($0.split(separator: "=", maxSplits: 1)[0]))
        }
        return (path.isEmpty ? [] : ["--config=\(path)"]) + defaults + arguments
    }

    /// Native-only context for file tools and mounts. Never expose this tuple
    /// over the web bridge: its environment may contain an unlocked config key.
    func auxiliaryContext() throws -> (binary: String, arguments: [String], environment: [String: String]) {
        try stateLock.holding {
            guard !closing, !maintenance else { throw EngineError("rclone 目前無法使用，請稍後再試。") }
            return (try resolvedRclonePath(), configuredArguments([]), childEnvironment())
        }
    }

    func withAuxiliaryOperation<T>(_ body: () throws -> T) throws -> T { try withOperation(body) }

    /// Drain both pipes independently; neither output stream can block the child.
    private func runProcess(_ arguments: [String], binary: String? = nil, timeout: TimeInterval? = 120,
                            maximum: Int = 64 * 1024 * 1024, activeJob: EngineActiveJob? = nil,
                            lines: ((String) -> Void)? = nil, stdoutLines: ((String, Bool) -> Void)? = nil,
                            checked: Bool = true) throws -> EngineProcessResult {
        let executable = try binary ?? resolvedRclonePath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = configuredArguments(arguments)
        process.environment = childEnvironment()
        process.standardInput = FileHandle.nullDevice
        let outputPipe = Pipe(), errorPipe = Pipe()
        process.standardOutput = outputPipe; process.standardError = errorPipe
        let token = UUID(), buffers = EngineProcessOutput(maximum: maximum)
        try stateLock.holding {
            guard !closing, !maintenance else { throw EngineError(closing ? "程式正在關閉。" : "rclone 正在更新。") }
            guard activeJob?.cancel != true else { throw EngineError("已取消。") }
            if let failure = activeJob?.failure { throw EngineError(failure) }
            captureChildren[token] = process; activeJob?.child = process
        }
        defer {
            stateLock.holding {
                captureChildren.removeValue(forKey: token)
                let key = ObjectIdentifier(process)
                for item in stoppingChildren[key]?.timers ?? [] { item.cancel() }
                stoppingChildren.removeValue(forKey: key)
                if activeJob?.child === process { activeJob?.child = nil }
            }
            try? outputPipe.fileHandleForReading.close(); try? errorPipe.fileHandleForReading.close()
        }
        do { try EnginePlatform.prepare(process); try process.run() }
        catch { throw EngineError("無法啟動 rclone：\(error.localizedDescription)") }
        let timer: DispatchWorkItem? = timeout.map { seconds in
            let item = DispatchWorkItem {
                if process.isRunning { buffers.fail("rclone 回應逾時，請檢查連線後重試。"); Self.kill(process, signal: SIGKILL) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: item); return item
        }
        defer { timer?.cancel() }
        let drains = DispatchGroup()
        for (file, stderr) in [(outputPipe.fileHandleForReading, false), (errorPipe.fileHandleForReading, true)] {
            drains.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { drains.leave() }
                var pending = Data()
                let consume: ((String, Bool) -> Void)?
                if !stderr, let stdoutLines = stdoutLines { consume = stdoutLines }
                else if let lines = lines { consume = { line, _ in lines(line) } }
                else { consume = nil }
                do {
                    // FileHandle.read(upToCount:) may wait to fill the requested
                    // count on a pipe. POSIX read returns the bytes available now,
                    // so one-second rclone statistics reach the UI immediately.
                    while let bytes = try readPipeChunk(file) {
                        if let consume = consume {
                            pending.append(bytes)
                            while let newline = pending.firstIndex(of: 10) {
                                consume(String(decoding: pending.prefix(upTo: newline), as: UTF8.self), true)
                                pending.removeSubrange(...newline)
                            }
                            if pending.count > 2 * 1024 * 1024 {
                                buffers.fail("rclone 單行輸出過大，工作已停止。"); self.requestStop(process); pending.removeAll()
                            }
                        } else if !buffers.append(bytes, stderr: stderr) { self.requestStop(process) }
                    }
                    if !pending.isEmpty { consume?(String(decoding: pending, as: UTF8.self), false) }
                } catch { buffers.fail("無法讀取 rclone 輸出：\(error.localizedDescription)"); self.requestStop(process) }
            }
        }
        if stateLock.holding({ activeJob?.cancel == true || activeJob?.failure != nil || closing }) { requestStop(process) }
        process.waitUntilExit()
        drains.wait()
        if let failure = buffers.failure { throw EngineError(failure) }
        let result = EngineProcessResult(stdout: buffers.stdout, stderr: buffers.stderr, exitCode: process.terminationStatus)
        if checked && result.exitCode != 0 { throw EngineError(Self.processError(result.stderr, code: result.exitCode)) }
        return result
    }

    private static func kill(_ child: Process, signal: Int32) {
        if child.isRunning { _ = DarwinOrGlibcKill(child.processIdentifier, signal) }
    }
    private func requestStop(_ child: Process) {
        let key = ObjectIdentifier(child)
        let started: (Bool, String?) = stateLock.holding {
            guard child.isRunning, stoppingChildren[key] == nil else { return (false, nil) }
            let id = active.first { $0.value.child === child }?.key
            if let id = id, let job = jobs[id] {
                if job.cancellation == nil { job.cancellation = EngineJobCancellation() }
                job.cancellation?.lastSignal = "SIGINT"
            }
            let terminate = DispatchWorkItem { [weak self, weak child] in
                guard let self = self, let child = child else { return }
                self.escalateStop(child, signal: SIGTERM, name: "SIGTERM")
            }
            let kill = DispatchWorkItem { [weak self, weak child] in
                guard let self = self, let child = child else { return }
                self.escalateStop(child, signal: SIGKILL, name: "SIGKILL")
            }
            stoppingChildren[key] = StopRequest(jobID: id, timers: [terminate, kill])
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.interruptGrace, execute: terminate)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.interruptGrace + Self.terminateGrace, execute: kill)
            Self.kill(child, signal: SIGINT)
            return (true, id)
        }
        if started.0, let id = started.1 { notify(id, immediate: true) }
    }

    private func escalateStop(_ child: Process, signal: Int32, name: String) {
        let id: String? = stateLock.holding {
            guard let request = stoppingChildren[ObjectIdentifier(child)], child.isRunning else { return nil }
            if let id = request.jobID, let job = jobs[id] {
                job.cancellation?.lastSignal = name
                job.error = Self.forcedStopMessage
            }
            Self.kill(child, signal: signal)
            return request.jobID
        }
        if let id = id { notify(id, immediate: true) }
    }
    private static let cancelledMessage = "工作已停止。"
    private static let forcedStopMessage = "rclone 未回應停止要求，已強制停止。請檢查目標端的未完成檔案。"
    private static func processError(_ stderr: Data, code: Int32) -> String {
        let lines = String(decoding: stderr, as: UTF8.self).split(separator: "\n").suffix(8).map { line -> String in
            if let object = try? EngineJSON.object(Data(line.utf8)) as? [String: Any] { return object["msg"] as? String ?? object["error"] as? String ?? String(line) }
            return String(line)
        }.joined(separator: "\n")
        return "rclone 執行失敗（代碼 \(code)）" + (lines.isEmpty ? "。" : "：\n" + String(lines.suffix(8000)))
    }

    private func detectEnvironment() throws -> [String: Any] {
        var result = Self.blankEnvironment(configPath: settingsSnapshot()["configPath"] as? String ?? "")
        do {
            let path = try resolvedRclonePath()
            let version = try runProcess(["version", "--ask-password=false"], binary: path, timeout: 15)
            let firstLine = String(decoding: version.stdout, as: UTF8.self).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            guard firstLine.range(of: "^rclone v[0-9]+\\.[0-9]+", options: .regularExpression) != nil else { throw EngineError("指定的執行檔不是 rclone。") }
            result["version"] = firstLine; result["rclonePath"] = path; result["available"] = true
            if (result["configPath"] as? String ?? "").isEmpty,
               let config = try? runProcess(["config", "file", "--ask-password=false"], binary: path, timeout: 15) {
                let paths = String(decoding: config.stdout, as: UTF8.self).split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { EnginePlatform.absoluteLocalPath($0) }
                result["configPath"] = paths.last ?? ""
            }
        } catch { result["error"] = error.localizedDescription }
        stateLock.holding { result["settingsRevision"] = settings["settingsRevision"]; environment = result }
        return result
    }

    private func requireAvailable() throws -> String {
        let available = stateLock.holding { environment["available"] as? Bool ?? false }
        if !available { _ = try detectEnvironment() }
        let snapshot = stateLock.holding { environment }
        guard snapshot["available"] as? Bool == true else { throw EngineError(snapshot["error"] as? String ?? "找不到 rclone。") }
        return try resolvedRclonePath()
    }

    private func remotes(activeJob: EngineActiveJob? = nil) throws -> [[String: Any]] {
        let output = try runProcess(["listremotes", "--json", "--ask-password=false", "--use-json-log"], activeJob: activeJob)
        guard let array = try EngineJSON.object(output.stdout) as? [[String: Any]] else { throw EngineError("rclone 未回傳有效的遠端清單，請更新 rclone。") }
        return array.compactMap { item in
            guard let name = item["name"] as? String, let type = item["type"] as? String else { return nil }
            return ["name": name, "type": type, "group": EngineLocationCatalog.remoteGroup(type: type)]
        }
    }

    private func requireEndpoints(_ endpoints: [EngineEndpoint], activeJob: EngineActiveJob? = nil) throws {
        let required = endpoints.compactMap(\.remote)
        if required.isEmpty { return }
        let names = Set(try remotes(activeJob: activeJob).compactMap { $0["name"] as? String })
        for name in required where !names.contains(name) { throw EngineError("找不到遠端連線「\(name)」，請重新整理。") }
    }

    private func bootstrap() throws -> [String: Any] {
        try withOperation {
            var environment = try detectEnvironment()
            var remotes: [[String: Any]] = []
            if environment["available"] as? Bool == true {
                do { remotes = try self.remotes(); environment.removeValue(forKey: "error") }
                catch { environment["error"] = error.localizedDescription }
            }
            stateLock.holding { self.environment = environment }
            let snapshot = settingsSnapshot()
            return ["environment": environment, "settings": snapshot, "remotes": remotes,
                    "resolvedLanguage": RBNLanguageResolver.resolve(snapshot["language"] as? String ?? "system"),
                    "localLocations": EngineLocationCatalog.localLocations(),
                    "home": FileManager.default.homeDirectoryForCurrentUser.path, "jobs": listJobs(), "tasks": listTasks()]
        }
    }

    private func localList(_ endpoint: EngineEndpoint) throws -> [[String: Any]] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: endpoint.path), includingPropertiesForKeys: keys)
        guard urls.count <= 250000 else { throw EngineError("目錄超過 250,000 個項目，請選擇較小的資料夾。") }
        return try urls.map { url in
            let values = try url.resourceValues(forKeys: Set(keys))
            var isDir: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            return ["name": url.lastPathComponent, "path": url.lastPathComponent,
                    "size": isDir.boolValue ? -1 : (values.fileSize ?? 0),
                    "modified": values.contentModificationDate.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                    "isDir": isDir.boolValue, "isLink": values.isSymbolicLink ?? false] as [String: Any]
        }.sorted(by: Self.entryOrder)
    }

    private static func entryOrder(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        let ad = a["isDir"] as? Bool ?? false, bd = b["isDir"] as? Bool ?? false
        if ad != bd { return ad }
        return (a["name"] as? String ?? "").localizedStandardCompare(b["name"] as? String ?? "") == .orderedAscending
    }

    private func listRaw(_ endpoint: EngineEndpoint, extra: [String] = [], activeJob: EngineActiveJob? = nil,
                         allowMissingDirectory: Bool = false) throws -> [[String: Any]] {
        let output = try runProcess(["lsjson", "--no-mimetype", "--ask-password=false", "--use-json-log"] + extra + ["--", endpoint.argument],
                                    activeJob: activeJob, checked: false)
        // rclone's DirNotFound exit status is 3. Only the destination-side
        // selection pre-scan may treat that as empty; authorization, connection,
        // filter and partial-listing errors must stop before any sync is run.
        if allowMissingDirectory && output.exitCode == 3 { return [] }
        guard output.exitCode == 0 else { throw EngineError(Self.processError(output.stderr, code: output.exitCode)) }
        guard let array = try EngineJSON.object(output.stdout) as? [[String: Any]] else { throw EngineError("rclone 未回傳有效的目錄清單。") }
        return array
    }

    private func list(_ endpoint: EngineEndpoint) throws -> [[String: Any]] {
        if endpoint.remote == nil { return try localList(endpoint) }
        return try withOperation {
            _ = try requireAvailable(); try requireEndpoints([endpoint])
            return try listRaw(endpoint).map { item in
                ["name": item["Name"] as? String ?? "", "path": item["Path"] as? String ?? item["Name"] as? String ?? "",
                 "size": item["Size"] as? NSNumber ?? -1, "modified": item["ModTime"] as? String ?? "", "isDir": item["IsDir"] as? Bool ?? false] as [String: Any]
            }.sorted(by: Self.entryOrder)
        }
    }

    private func mkdir(_ endpoint: EngineEndpoint, name: String) throws {
        let child = try endpoint.child(name)
        if endpoint.remote == nil {
            guard !FileManager.default.fileExists(atPath: child.path) else { throw EngineError("同名項目已存在。") }
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: child.path), withIntermediateDirectories: false); return
        }
        try withOperation {
            _ = try requireAvailable(); try requireEndpoints([endpoint])
            guard !(try listRaw(endpoint)).contains(where: { $0["Name"] as? String == name }) else { throw EngineError("同名項目已存在。") }
            _ = try runProcess(["mkdir", "--ask-password=false", "--use-json-log", "--", child.argument])
        }
    }

    private func renameEntry(_ endpoint: EngineEndpoint, name: String, newName: String, isDir: Bool) throws {
        let from = try endpoint.child(name), to = try endpoint.child(newName)
        if name == newName { return }
        if endpoint.remote == nil {
            let entries = try localList(endpoint)
            try validateSelection([EngineSelection(name: name, isDir: isDir)], entries: entries)
            #if os(macOS)
            let collision = entries.contains { ($0["name"] as? String ?? "").lowercased() == newName.lowercased() }
            #else
            let collision = entries.contains { $0["name"] as? String == newName }
            #endif
            guard !collision else { throw EngineError("新名稱已存在，請選擇其他名稱。") }
            try FileManager.default.moveItem(atPath: from.path, toPath: to.path); return
        }
        try withOperation {
            _ = try requireAvailable(); try requireEndpoints([endpoint])
            let entries = try listRaw(endpoint)
            guard entries.contains(where: { $0["Name"] as? String == name && ($0["IsDir"] as? Bool ?? false) == isDir }) else { throw EngineError("原項目已不存在或類型已改變。") }
            guard !entries.contains(where: { $0["Name"] as? String == newName }) else { throw EngineError("新名稱已存在，請選擇其他名稱。") }
            let arguments = [isDir ? "move" : "moveto"] + (isDir ? ["--create-empty-src-dirs", "--delete-empty-src-dirs"] : [])
                + ["--ignore-existing", "--ask-password=false", "--use-json-log", "--log-level=INFO", "--", from.argument, to.argument]
            _ = try runProcess(arguments)
            if (try listRaw(endpoint)).contains(where: { $0["Name"] as? String == name }) {
                guard isDir else { throw EngineError("來源檔案仍存在，目的地可能出現同名項目。請重新整理確認。") }
                do { _ = try runProcess(["rmdir", "--ask-password=false", "--use-json-log", "--", from.argument]) }
                catch { throw EngineError("部分內容仍留在原資料夾，請檢查兩個資料夾。") }
            }
        }
    }

    private func validateSelection(_ selection: [EngineSelection], entries: [[String: Any]]) throws {
        for item in selection {
            guard entries.contains(where: { $0["name"] as? String == item.name && ($0["isDir"] as? Bool ?? false) == item.isDir }) else {
                throw EngineError("「\(item.name)」已不存在或類型已改變，請重新整理。")
            }
        }
    }

    private func remove(_ endpoint: EngineEndpoint, selection: [EngineSelection]) throws {
        guard !selection.isEmpty else { throw EngineError("請先選取要刪除的項目。") }
        if endpoint.remote == nil {
            try validateSelection(selection, entries: localList(endpoint))
            for item in selection { try FileManager.default.removeItem(atPath: endpoint.child(item.name).path) }
            return
        }
        try withOperation {
            _ = try requireAvailable(); try requireEndpoints([endpoint])
            let raw = try listRaw(endpoint)
            let entries = raw.map { ["name": $0["Name"] ?? "", "isDir": $0["IsDir"] ?? false] }
            try validateSelection(selection, entries: entries)
            for item in selection {
                _ = try runProcess([item.isDir ? "purge" : "deletefile", "--ask-password=false", "--use-json-log", "--log-level=INFO", "--", endpoint.child(item.name).argument])
            }
        }
    }

    private func size(_ endpoint: EngineEndpoint) throws -> [String: Any] {
        if endpoint.remote == nil {
            var count: Int64 = 0, bytes: Int64 = 0, failure: Error?
            guard let iterator = FileManager.default.enumerator(at: URL(fileURLWithPath: endpoint.path), includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], errorHandler: { _, error in failure = error; return false }) else { throw EngineError("無法讀取資料夾。") }
            for case let url as URL in iterator {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                if values.isSymbolicLink == true { iterator.skipDescendants(); continue }
                if values.isRegularFile == true { count += 1; bytes += Int64(values.fileSize ?? 0) }
            }
            if let failure = failure { throw failure }
            return ["count": count, "bytes": bytes]
        }
        return try withOperation {
            _ = try requireAvailable(); try requireEndpoints([endpoint])
            let result = try runProcess(["size", "--json", "--ask-password=false", "--use-json-log", "--", endpoint.argument], timeout: 600)
            guard let value = try EngineJSON.object(result.stdout) as? [String: Any], value["count"] is NSNumber, value["bytes"] is NSNumber else { throw EngineError("rclone 未回傳有效的容量資訊。") }
            return ["count": EngineJSON.number(value["count"]), "bytes": EngineJSON.number(value["bytes"])]
        }
    }

    private func prepareRequest(_ value: Any) throws -> EngineTransferRequest {
        _ = try requireAvailable()
        let request = try normalizedRequest(value)
        try EngineStorage.validatePair(request); try requireEndpoints([request.source, request.destination])
        return request
    }

    /// Resolve defaults without filesystem or remote access. Native confirmation
    /// must show this complete snapshot and submit its json afterward, so a
    /// later default-setting change cannot alter the operation being approved.
    func normalizedRequest(_ value: Any) throws -> EngineTransferRequest {
        var raw = try EngineJSON.dictionary(value, "傳輸設定格式不正確。")
        let supplied = try EngineJSON.dictionary(raw["options"], "傳輸选項格式不正確。")
        let defaults = settingsSnapshot()["defaultTransferOptions"] as? [String: Any] ?? EngineTransferOptions.defaults
        raw["options"] = defaults.merging(supplied) { _, new in new }
        return try EngineTransferRequest(raw)
    }

    static func displayCommand(_ executable: String, _ arguments: [String]) -> String {
        ([executable] + arguments).map { value in
            if !value.isEmpty && value.range(of: "^[A-Za-z0-9_@%+=:,./-]+$", options: .regularExpression) != nil { return value }
            return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        }.joined(separator: " ")
    }

    private func preview(_ request: EngineTransferRequest) throws -> [String: Any] {
        var warnings: [String] = []
        let complex = !request.selection.isEmpty && !request.options.includes.isEmpty
        var arguments = request.arguments(filterPath: complex ? "<精確選取清單>" : nil)
        if !complex, let index = arguments.firstIndex(of: "--") { arguments.insert(contentsOf: request.selectionFilterRules.map { "--filter=\($0)" }, at: index) }
        if let index = arguments.firstIndex(of: "--") { arguments.insert("--combined=-", at: index) }
        if request.mode == "sync" {
            let limit = request.options.integer("maxDelete")
            warnings.append(limit < 0 ? "同步會刪除目的地中來源沒有的檔案；本次未設定刪除數量上限。"
                : "同步會刪除目的地中來源沒有的檔案；本次最多刪除 \(limit) 個。超過上限前已刪除的檔案不會復原。")
            if !request.selection.isEmpty { warnings.append("只同步來源選取的資料夾至目的地同名子資料夾；未選取的目的地內容不會變更。") }
        }
        if request.mode == "move" { warnings.append("移動會在傳送成功後刪除來源檔案。") }
        if request.mode == "sync", request.options.flag("deleteExcluded") { warnings.append("已啟用刪除排除項目：目的地中符合排除規則的檔案也會刪除。") }
        if request.mode == "sync", request.options.text("deleteMode") == "before" { warnings.append("目的地多餘檔案會在傳輸開始前刪除，後續傳輸失敗不會還原這些刪除。") }
        if request.options.text("comparison") == "none" { warnings.append("本次會重新傳送所有範圍內的檔案，即使目的地已有相同內容。") }
        if let precision = EngineLocalTimePrecision.detect(for: request) { warnings.append(precision.message) }
        if request.options.text("localHashPolicy") == "none", request.source.remote == nil || request.destination.remote == nil {
            switch request.options.text("comparison") {
            case "default": warnings.append("本機比對使用檔案大小與修改時間，不讀取內容計算雜湊。")
            case "modtime": warnings.append("本機比對只使用修改時間，不讀取內容計算雜湊。")
            case "size": warnings.append("本機比對只使用檔案大小，不讀取內容計算雜湊。")
            default: break
            }
        }
        else if request.options.flag("ignoreChecksum") { warnings.append("已關閉傳送後的雜湊驗證；傳送前的雜湊比對仍依比對方式執行。") }
        if request.dryRun { warnings.append("預演不會變更檔案，傳輸統計為模擬結果。") }
        if complex {
            warnings.append(request.mode == "sync"
                ? "只處理勾選資料夾內、符合包含規則的檔案。開始前會先列出兩側檔名；此範圍內只有目標存在的檔案也會納入同步刪除。"
                : "只處理勾選範圍內、符合包含規則的檔案；開始前會先掃描來源。")
        }
        return ["command": Self.displayCommand(try resolvedRclonePath(), configuredArguments(arguments)), "warnings": warnings]
    }

    private func startTransfer(_ value: Any) throws -> [String: Any] {
        try withOperation {
            let request = try prepareRequest(value)
            let command = try preview(request)["command"] as? String ?? ""
            let job = EngineJob(request: request, command: command)
            stateLock.holding { jobs[job.id] = job; jobOrder.append(job.id) }
            do { try persist() }
            catch {
                stateLock.holding { job.status = "failed"; job.endedAt = EngineJSON.now(); job.error = "無法儲存工作，未開始傳輸：\(error.localizedDescription)" }
                notify(job.id, immediate: true); throw EngineError(job.error ?? "無法儲存工作。")
            }
            notify(job.id, immediate: true)
            pump()
            return stateLock.holding { job.json }
        }
    }

    private func pump() {
        let launch: [(EngineJob, EngineActiveJob)] = stateLock.holding {
            guard !closing, !maintenance, !configurationChanging else { return [] }
            var result: [(EngineJob, EngineActiveJob)] = []
            for id in jobOrder {
                let limit = settings["maxConcurrentJobs"] as? Int ?? 0
                guard limit == 0 || active.count < limit else { break }
                guard let job = jobs[id], job.status == "queued" else { continue }
                job.status = "running"; job.startedAt = EngineJSON.now()
                let running = EngineActiveJob(); active[id] = running; result.append((job, running))
            }
            return result
        }
        for (job, running) in launch {
            notify(job.id, immediate: true)
            operationQueue.async { [self] in
                runJob(job, running: running)
                _ = stateLock.holding { active.removeValue(forKey: job.id) }
                running.done.leave()
                pump()
            }
        }
    }

    private func writeFilter(_ job: EngineJob, running: EngineActiveJob) throws -> URL? {
        var rules: [String]
        let request = job.request
        if !request.selection.isEmpty && !request.options.includes.isEmpty {
            try appLog(job, running: running, level: "info", message: "正在套用選取範圍與包含規則。")
            // Rclone filter includes are OR rules. Source selection AND include
            // patterns therefore need an exact allowlist. For sync, enumerate
            // both sides: a source-only list would protect stale destination
            // files instead of deleting them. No hashes or contents are read.
            let endpoints = request.mode == "sync" ? [request.source, request.destination] : [request.source]
            let flags = ["--recursive", "--no-modtime"] + request.options.filterRules.map { "--filter=\($0)" }
            var allowed = Set<String>()
            let selectedNames = Set(request.selection.map(\.name))
            let selectedDirectories = Set(request.selection.filter(\.isDir).map(\.name))
            for (index, endpoint) in endpoints.enumerated() {
                let entries = try listRaw(endpoint, extra: flags, activeJob: running, allowMissingDirectory: index == 1)
                guard entries.count <= 250000 else { throw EngineError("選取清單超過 250,000 個項目，請縮小來源範圍。") }
                for entry in entries {
                    let relative = try EngineJSON.text(entry["Path"], "相對路徑", maximum: 32768)
                    let components = relative.split(separator: "/")
                    guard !relative.isEmpty, !relative.hasPrefix("/"), !components.contains("..") else { throw EngineError("遠端回傳不安全的相對路徑。") }
                    let top = components.first.map(String.init) ?? ""
                    guard selectedNames.contains(relative) || (components.count > 1 && selectedDirectories.contains(top)) else { continue }
                    allowed.insert("+ /" + EngineTransferRequest.escapeFilter(relative) + ((entry["IsDir"] as? Bool == true) ? "/" : ""))
                    guard allowed.count <= 250000 else { throw EngineError("選取清單超過 250,000 個項目，請縮小來源範圍。") }
                }
            }
            rules = allowed.sorted() + ["- **"]
        } else { rules = request.selectionFilterRules }
        if rules.isEmpty { return nil }
        let file = filterDirectory.appendingPathComponent(job.id + ".filter")
        try EngineStorage.atomicData(Data((rules.joined(separator: "\n") + "\n").utf8), to: file)
        return file
    }

    private func runJob(_ job: EngineJob, running: EngineActiveJob) {
        var filter: URL?
        var report: EngineTransferReport?
        var finalStatus = "failed"
        defer { stateLock.holding { _ = transferReports.removeValue(forKey: job.id) } }
        do {
            let writer = try EngineLogWriter(directory: logDirectory, id: job.id)
            stateLock.holding { running.log = writer }
            let reporter = try EngineTransferReport(directory: logDirectory, id: job.id)
            report = reporter
            let initialReport = reporter.summary
            stateLock.holding { transferReports[job.id] = reporter; job.report = initialReport }
            try EngineStorage.validatePair(job.request)
            try requireEndpoints([job.request.source, job.request.destination], activeJob: running)
            if stateLock.holding({ running.cancel }) { throw EngineError("已取消。") }
            if !job.request.selection.isEmpty {
                let raw = try listRaw(job.request.source, activeJob: running)
                try validateSelection(job.request.selection, entries: raw.map { ["name": $0["Name"] ?? "", "isDir": $0["IsDir"] ?? false] })
            }
            filter = try writeFilter(job, running: running)
            if stateLock.holding({ running.cancel }) { throw EngineError("已取消。") }
            var args = job.request.arguments(filterPath: filter?.path)
            // Rclone recreates a named --combined file on each high-level
            // retry. Its stdout stream instead lets us append every attempt to
            // our own report without losing early comparisons or parsing JSON
            // looking filenames as statistics.
            if let index = args.firstIndex(of: "--") { args.insert("--combined=-", at: index) }
            let command = Self.displayCommand(try resolvedRclonePath(), configuredArguments(args))
            stateLock.holding { job.command = command }
            let window = args.first { $0.hasPrefix("--modify-window=") }.map { String($0.dropFirst("--modify-window=".count)) }
            try reporter.recordConfiguration(job.request, engineVersion: stateLock.holding { environment["version"] as? String }, effectiveModifyWindow: window)
            if let precision = EngineLocalTimePrecision.detect(for: job.request) {
                try appLog(job, running: running, level: "info", message: precision.message)
            }
            try appLog(job, running: running, level: "info", message: job.request.dryRun ? "開始預演。" : "開始傳輸。")
            stateLock.holding { job.progress.start() }
            let result = try runProcess(args, timeout: nil, activeJob: running,
                                        lines: { [self] line in consumeLine(line, job: job, running: running) },
                                        stdoutLines: { [self] line, terminated in consumeComparisonLine(line, terminated: terminated, report: reporter, job: job, running: running) }, checked: false)
            if let failure = stateLock.holding({ running.failure }) { throw EngineError(failure) }
            stateLock.holding {
                job.exitCode = result.exitCode
                if running.cancel {
                    finalStatus = closing ? "interrupted" : "cancelled"
                    if job.cancellation?.forced == true { job.error = Self.forcedStopMessage }
                    else if closing { job.error = "程式關閉，工作已停止。" }
                } else if result.exitCode == 0 { finalStatus = "completed"; job.error = nil }
                else { finalStatus = "failed"; job.error = job.error ?? "rclone 結束代碼：\(result.exitCode)。請查看記錄。" }
            }
        } catch {
            stateLock.holding {
                if running.cancel {
                    finalStatus = closing ? "interrupted" : "cancelled"
                    if job.cancellation?.forced == true { job.error = Self.forcedStopMessage }
                    else if closing { job.error = "程式關閉，工作已停止。" }
                }
                else { finalStatus = "failed"; job.error = error.localizedDescription }
            }
        }
        if let report = report {
            do {
                try report.pollComparisons(final: true)
                try report.flush()
            } catch {
                stateLock.holding {
                    job.error = "逐檔報告無法完整保存：\(error.localizedDescription)"
                    if finalStatus == "completed" { finalStatus = "failed" }
                }
            }
            publishReport(report, job: job)
        }
        stateLock.holding {
            // Publish a terminal status only after both process pipes and the
            // complete per-file report have drained. A finished row must not
            // briefly show an incomplete report or zero completed throughput.
            job.status = finalStatus
            job.endedAt = EngineJSON.now()
            if running.cancel { job.cancellation?.processExited = true }
            job.stats = job.progress.finish(job.stats, completed: job.status == "completed")
        }
        do {
            let (message, level): (String, String) = stateLock.holding {
                let text = job.status == "completed" ? (job.request.dryRun ? "預演完成，檔案未變更。" : "工作完成。")
                    : job.status == "cancelled" ? Self.cancelledMessage : job.error ?? "工作已結束。"
                return (text, job.status == "failed" ? "error" : "info")
            }
            try appLog(job, running: running, level: level, message: message)
            try running.log?.flush()
        } catch {
            stateLock.holding { job.error = "記錄無法完整保存：\(error.localizedDescription)"; if job.status == "completed" { job.status = "failed" } }
        }
        if let filter = filter { try? FileManager.default.removeItem(at: filter) }
        do { try persist() }
        catch { stateLock.holding { job.error = "工作狀態無法儲存：\(error.localizedDescription)"; if job.status == "completed" { job.status = "failed" } } }
        notify(job.id, immediate: true)
    }

    private func consumeLine(_ line: String, job: EngineJob, running: EngineActiveJob) {
        if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        let parsed = (try? EngineJSON.object(Data(line.utf8))) as? [String: Any]
        let raw = parsed ?? ["time": EngineJSON.now(), "level": "info", "msg": String(line.prefix(16000)), "rawOutput": true]
        do {
            let text = parsed == nil ? String(decoding: try EngineJSON.data(raw), as: UTF8.self) : line
            try running.log?.append(text)
        } catch {
            outputFailure("無法儲存記錄：\(error.localizedDescription)", job: job, running: running)
            return
        }
        if let report = stateLock.holding({ transferReports[job.id] }) {
            do {
                try report.consume(raw, dryRun: job.request.dryRun)
                if raw["stats"] != nil { try report.pollComparisons() }
            } catch {
                reportFailure(error, job: job, running: running)
            }
            if raw["stats"] != nil || ["error", "fatal", "alert", "emergency"].contains((raw["level"] as? String ?? "").lowercased()) {
                publishReport(report, job: job)
            }
        }
        stateLock.holding {
            if let stats = raw["stats"] as? [String: Any] {
                job.stats = job.progress.update(stats, previous: job.stats)
                if let error = stats["lastError"] as? String, !error.isEmpty { job.error = String(error.prefix(16000)) }
            } else {
                let message = String((raw["msg"] as? String ?? raw["error"] as? String ?? "rclone 記錄").prefix(16000))
                let level = raw["level"] as? String ?? "info"
                var record: [String: Any] = ["time": raw["time"] as? String ?? EngineJSON.now(), "level": level, "message": message]
                if let object = raw["object"] as? String { record["object"] = String(object.prefix(16000)) }
                if let size = raw["size"] as? NSNumber { record["size"] = size }
                job.logs.append(record); if job.logs.count > 250 { job.logs.removeFirst(job.logs.count - 250) }
                if ["error", "fatal"].contains(level.lowercased()) { job.error = message }
            }
        }
        notify(job.id)
    }

    private func consumeComparisonLine(_ line: String, terminated: Bool, report: EngineTransferReport, job: EngineJob, running: EngineActiveJob) {
        do {
            try report.consumeComparisonLine(line, terminated: terminated)
        } catch { reportFailure(error, job: job, running: running) }
        // Comparison output can contain hundreds of thousands of unchanged
        // files. Its writer batches bytes; publish counters with the existing
        // one-second stderr statistics or the final drain, not once per path.
    }

    private func publishReport(_ report: EngineTransferReport, job: EngineJob) {
        let summary = report.summary
        stateLock.holding {
            // The two pipes drain concurrently. An earlier snapshot must not
            // replace newer counters just because its callback acquired the
            // state lock later; the report's append sequence is monotonic.
            if EngineJSON.number(summary["eventCount"]) >= EngineJSON.number(job.report?["eventCount"]) { job.report = summary }
        }
    }

    private func reportFailure(_ error: Error, job: EngineJob, running: EngineActiveJob) {
        outputFailure("逐檔報告無法完整保存：\(error.localizedDescription)", job: job, running: running)
    }

    private func outputFailure(_ message: String, job: EngineJob, running: EngineActiveJob) {
        let child = stateLock.holding { () -> Process? in
            if running.failure == nil { running.failure = message }
            if !EngineJob.terminal.contains(job.status) { job.status = "cancelling" }
            return running.child
        }
        // Preserve rclone's own partial-upload cleanup path if a report cannot
        // be written; never remove transfer destination files.
        if let child = child { requestStop(child) }
    }

    private func appLog(_ job: EngineJob, running: EngineActiveJob?, level: String, message: String) throws {
        let time = EngineJSON.now()
        stateLock.holding {
            job.logs.append(["time": time, "level": level, "message": message])
            if job.logs.count > 250 { job.logs.removeFirst(job.logs.count - 250) }
        }
        if let writer = running?.log { try writer.append(String(decoding: EngineJSON.data(["time": time, "level": level, "msg": message, "app": true]), as: UTF8.self)) }
    }

    private func notify(_ id: String, immediate: Bool = false) {
        stateLock.holding {
            if immediate { scheduledNotifications[id]?.cancel(); scheduledNotifications.removeValue(forKey: id) }
            if immediate {
                if let job = jobs[id] { let value = job.json; callbackQueue.async { [weak self] in self?.onJobUpdate?(value) } }
            } else if scheduledNotifications[id] == nil {
                let item = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    let value = self.stateLock.holding { () -> [String: Any]? in
                        self.scheduledNotifications.removeValue(forKey: id); return self.jobs[id]?.json
                    }
                    if let value = value { self.onJobUpdate?(value) }
                }
                scheduledNotifications[id] = item; callbackQueue.asyncAfter(deadline: .now() + 0.15, execute: item)
            }
            if !persistScheduled && !closing {
                persistScheduled = true
                operationQueue.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self = self else { return }
                    self.stateLock.holding { self.persistScheduled = false }
                    do { try self.persist() }
                    catch {
                        let children: [Process] = self.stateLock.holding {
                            var children: [Process] = []
                            for (id, running) in self.active {
                                if running.failure == nil { running.failure = "無法儲存工作狀態：\(error.localizedDescription)" }
                                if let child = running.child { children.append(child) }
                                self.jobs[id]?.error = running.failure
                                if let job = self.jobs[id], !EngineJob.terminal.contains(job.status) { job.status = "cancelling" }
                            }
                            return children
                        }
                        for child in children { self.requestStop(child) }
                    }
                }
            }
        }
    }

    private func listJobs() -> [[String: Any]] { stateLock.holding { jobOrder.reversed().compactMap { jobs[$0]?.json } } }
    private func listTasks() -> [[String: Any]] { stateLock.holding { tasks.values.sorted { $0.updatedAt > $1.updatedAt }.map(\.json) } }

    private func cancelJob(_ id: String) throws {
        let result: (EngineActiveJob?, Process?) = try stateLock.holding {
            guard let job = jobs[id] else { throw EngineError("找不到這項工作。") }
            let running = markCancellation(job)
            return (running, running?.child)
        }
        notify(id, immediate: true)
        if let child = result.1 { requestStop(child) }
        if let running = result.0, running.done.wait(timeout: .now() + Self.stopWaitLimit) == .timedOut {
            try persist()
            throw EngineError("rclone 尚未停止，工作仍保留。請查看工作狀態。")
        }
        try persist()
    }

    /// Call while holding stateLock. Mark the whole chosen batch before sending
    /// any signals, so pump() cannot start another chosen queued job meanwhile.
    private func markCancellation(_ job: EngineJob) -> EngineActiveJob? {
        guard !EngineJob.terminal.contains(job.status) else { return nil }
        if job.status == "queued" {
            job.status = closing ? "interrupted" : "cancelled"; job.endedAt = EngineJSON.now()
            job.stats = EngineStatistics.finished(job.stats, completed: false)
            return nil
        }
        guard let running = active[job.id] else { return nil }
        running.cancel = true; job.status = "cancelling"
        if job.cancellation == nil { job.cancellation = EngineJobCancellation() }
        return running
    }

    private func retryJob(_ id: String) throws -> [String: Any] {
        let request: [String: Any] = try stateLock.holding {
            guard let job = jobs[id] else { throw EngineError("找不到這項工作。") }
            guard EngineJob.terminal.contains(job.status) else { throw EngineError("工作尚未結束，不能重試。") }
            return job.request.json
        }
        return try startTransfer(request)
    }

    private func clearFinishedJobs() throws {
        let ids = stateLock.holding { jobOrder.filter { id in jobs[id].map { EngineJob.terminal.contains($0.status) } ?? false } }
        _ = try clearJobs(["ids": ids, "mode": "finished"])
    }

    private func clearJobs(_ value: Any) throws -> [String: Any] {
        let raw = try EngineJSON.dictionary(value, "工作清理設定格式不正確。")
        guard let rawIDs = raw["ids"] as? [String], rawIDs.count <= 10000,
              rawIDs.allSatisfy(EngineJSON.validID), let mode = raw["mode"] as? String,
              ["finished", "stop-and-clear"].contains(mode), Set(raw.keys).isSubset(of: ["ids", "mode"]) else {
            throw EngineError("無法清除工作紀錄：傳輸清單或清除方式已失效。請重新整理後再試。")
        }
        var seen = Set<String>()
        let ids = rawIDs.map { $0.lowercased() }.filter { seen.insert($0).inserted }
        let snapshot: [(String, EngineJob, EngineActiveJob?, Process?)] = stateLock.holding {
            ids.compactMap { id in
                guard let job = jobs[id], !EngineJob.terminal.contains(job.status), mode == "stop-and-clear" else { return nil }
                let running = markCancellation(job)
                return (id, job, running, running?.child)
            }
        }
        let finishing: [EngineActiveJob] = stateLock.holding {
            ids.compactMap { id in
                guard jobs[id].map({ EngineJob.terminal.contains($0.status) }) == true else { return nil }
                return active[id]
            }
        }
        for (id, _, _, _) in snapshot { notify(id, immediate: true) }
        for (_, _, _, child) in snapshot { if let child = child { requestStop(child) } }
        let deadline = DispatchTime.now() + Self.stopWaitLimit
        // A terminal status can appear briefly while its final log is flushing.
        // Let that worker finish before removing history, without signalling it.
        for running in finishing { _ = running.done.wait(timeout: deadline) }
        for (_, _, running, _) in snapshot { if let running = running { _ = running.done.wait(timeout: deadline) } }

        let result: [String: Any] = try storageLock.holding {
            try stateLock.holding {
                let retained = ids.filter { id in jobs[id].map { !EngineJob.terminal.contains($0.status) || active[id] != nil } ?? false }
                let retainedSet = Set(retained)
                // Already-removed IDs are reported as removed too, making a
                // repeated confirmation safe and allowing the UI to discard a
                // stale row without affecting a newly-created UUID.
                let removed = ids.filter { !retainedSet.contains($0) }
                let removedSet = Set(removed)
                let newOrder = jobOrder.filter { !removedSet.contains($0) }
                // Commit metadata before removing memory entries or owned logs.
                // A storage failure preserves the visible history for retry.
                try EngineStorage.atomicJSON(newOrder.compactMap { jobs[$0]?.json }, to: stateDirectory.appendingPathComponent("jobs.json"))
                for id in removed {
                    jobs.removeValue(forKey: id)
                    scheduledNotifications[id]?.cancel(); scheduledNotifications.removeValue(forKey: id)
                }
                jobOrder = newOrder
                return ["removedIds": removed, "retainedIds": retained,
                        "stoppedIds": snapshot.filter { EngineJob.terminal.contains($0.1.status) }.map { $0.0 },
                        "forcedStopIds": snapshot.filter { $0.1.cancellation?.forced == true }.map { $0.0 }]
            }
        }
        removeOwnedLogs(result["removedIds"] as? [String] ?? [])
        return result
    }

    /// Only app-owned log paths are removed. Transfer destination files and
    /// backend temporary objects are exclusively rclone's responsibility.
    private func removeOwnedLogs(_ ids: [String]) {
        for id in ids where EngineJSON.validID(id) {
            for suffix in [".jsonl", ".jsonl.1", ".jsonl.2", ".jsonl.3", ".jsonl.4", ".export.jsonl"] {
                try? FileManager.default.removeItem(at: logDirectory.appendingPathComponent(id + suffix))
            }
            try? EngineTransferReport.remove(directory: logDirectory, id: id)
        }
    }

    private func saveTask(name: String, value: Any, id: String?) throws -> [String: Any] {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 200 else { throw EngineError("請輸入 1 至 200 字的作業名稱。") }
        _ = try EngineJSON.text(trimmed, "作業名稱", maximum: 800)
        let request = try normalizedRequest(value), now = EngineJSON.now()
        let (task, previous): (EngineTask, EngineTask?) = try stateLock.holding {
            if let id = id, tasks[id] == nil { throw EngineError("找不到要更新的作業。") }
            guard id != nil || tasks.count < 1000 else { throw EngineError("最多可儲存 1,000 個作業。") }
            let previous = id.flatMap { tasks[$0] }
            let task = EngineTask(id: id ?? UUID().uuidString.lowercased(), name: trimmed, request: request, createdAt: previous?.createdAt ?? now, updatedAt: now)
            tasks[task.id] = task; return (task, previous)
        }
        do { try persist() } catch { stateLock.holding { tasks[task.id] = previous }; throw error }
        return task.json
    }

    private func deleteTask(_ id: String) throws {
        let previous = stateLock.holding { tasks.removeValue(forKey: id) }
        do { try persist() } catch { stateLock.holding { tasks[id] = previous }; throw error }
    }

    private func importTasks(_ value: Any) throws -> [[String: Any]] {
        var parsed = value
        if let text = value as? String {
            guard text.utf8.count <= 8 * 1024 * 1024 else { throw EngineError("作業檔案過大。") }
            parsed = try EngineJSON.object(Data(text.utf8))
        }
        guard let array = parsed as? [Any] ?? (parsed as? [String: Any])?["tasks"] as? [Any], array.count <= 1000 else { throw EngineError("請匯入有效的作業 JSON，最多 1,000 筆。") }
        let incoming = try array.map { try EngineTask($0) }
        let now = EngineJSON.now()
        let newTasks = incoming.map { EngineTask(id: UUID().uuidString.lowercased(), name: $0.name, request: $0.request, createdAt: $0.createdAt, updatedAt: now) }
        try stateLock.holding {
            guard tasks.count + newTasks.count <= 1000 else { throw EngineError("儲存的作業總數不能超過 1,000 筆。") }
            for task in newTasks { tasks[task.id] = task }
        }
        do { try persist() } catch { stateLock.holding { for task in newTasks { tasks.removeValue(forKey: task.id) } }; throw error }
        return listTasks()
    }

    private static func validateSettings(_ value: Any, defaults: [String: Any], isPatch: Bool = false) throws -> [String: Any] {
        let raw = try EngineJSON.dictionary(value, "設定格式不正確。")
        let merged = defaults.merging(raw) { _, new in new }
        var output: [String: Any] = [:]
        for (key, label) in [("rclonePath", "rclone 執行檔"), ("rcloneDirectory", "rclone 資料夾"), ("configPath", "設定檔"), ("streamPlayerPath", "播放器")] {
            let text = try EngineJSON.text(merged[key], label, maximum: 32768)
            guard text.isEmpty || EnginePlatform.absoluteLocalPath(text) else { throw EngineError("\(label)必須使用絕對路徑。") }
            output[key] = text.isEmpty ? "" : URL(fileURLWithPath: text).standardizedFileURL.path
        }
        // Choosing a file also chooses its update folder. Choosing only a folder
        // explicitly leaves executable discovery to <folder>/rclone.
        if raw["rclonePath"] != nil, let path = output["rclonePath"] as? String, !path.isEmpty {
            output["rcloneDirectory"] = URL(fileURLWithPath: path).deletingLastPathComponent().path
        } else if isPatch, raw["rcloneDirectory"] != nil,
                  raw.count <= 2 || raw["rcloneDirectory"] as? String != defaults["rcloneDirectory"] as? String,
                  let directory = output["rcloneDirectory"] as? String, !directory.isEmpty {
            output["rclonePath"] = URL(fileURLWithPath: directory).appendingPathComponent(EnginePlatform.rcloneName).path
        }
        let language = try EngineJSON.text(merged["language"], "語言")
        var theme = try EngineJSON.text(merged["theme"], "外觀")
        theme = ["dark": "blue-dark", "light": "blue-light", "system": "purple-dark"][theme] ?? theme
        guard ["system", "zh-TW", "en", "ja"].contains(language), ["purple-dark", "purple-light", "blue-dark", "blue-light", "green-dark", "green-light"].contains(theme) else {
            throw EngineError("語言或外觀設定不正確。")
        }
        output["language"] = language; output["theme"] = theme
        let interfaceScale = try EngineJSON.integer(merged["interfaceScale"], "介面比例", 80...135)
        guard [80, 90, 100, 110, 120, 125, 135].contains(interfaceScale) else { throw EngineError("請選擇支援的介面比例。") }
        output["interfaceScale"] = interfaceScale
        output["autoCheckUpdates"] = try EngineJSON.bool(merged["autoCheckUpdates"], "啟動時檢查更新")
        for key in ["showStatusItem", "notifyOnCompletion", "bounceDockOnCompletion", "showHiddenFiles", "showFolderIcons", "showFileIcons", "alternatingRows"] {
            output[key] = try EngineJSON.bool(merged[key], "介面設定")
        }
        output["skippedRcloneVersion"] = try EngineJSON.text(merged["skippedRcloneVersion"], "略過版本", maximum: 128)
        output["settingsRevision"] = try EngineJSON.integer(merged["settingsRevision"], "設定版本", 0...9007199254740990)
        output["settingsSchemaVersion"] = 7
        output["maxConcurrentJobs"] = try EngineJSON.integer(merged["maxConcurrentJobs"], "同時執行的工作數", 0...128)
        guard let hidden = merged["hiddenBuiltinPresets"] as? [String], hidden.count <= 6,
              Set(hidden).isSubset(of: ["local-nas", "nas-cloud", "local-cloud", "local-local", "cloud-cloud", "cloud-local"]) else {
            throw EngineError("內建方案設定格式不正確。")
        }
        output["hiddenBuiltinPresets"] = Array(Set(hidden)).sorted()

        let existingOptions = defaults["defaultTransferOptions"] as? [String: Any] ?? EngineTransferOptions.defaults
        let optionPatch = raw["defaultTransferOptions"] == nil ? [:] : try EngineJSON.dictionary(raw["defaultTransferOptions"], "預設傳輸選項格式不正確。")
        output["defaultTransferOptions"] = try EngineTransferOptions(existingOptions.merging(optionPatch) { _, new in new }).json
        let extraArguments = try EngineTransferOptions.validateExtraArguments(merged["defaultRcloneOptions"])
        guard !extraArguments.contains(where: { EngineNetworkOptions.globalOwnedFlags.contains(String($0.split(separator: "=", maxSplits: 1)[0])) }) else {
            throw EngineError("請在「rclone 連線」設定每秒請求上限與 HTTP/2，並移除「所有工作的額外參數」中的重複設定。")
        }
        output["defaultRcloneOptions"] = extraArguments
        let existingNetwork = defaults["networkOptions"] as? [String: Any] ?? EngineNetworkOptions.defaults
        let networkPatch = raw["networkOptions"] == nil ? [:] : try EngineJSON.dictionary(raw["networkOptions"], "網路設定格式不正確。")
        output["networkOptions"] = try EngineNetworkOptions(existingNetwork.merging(networkPatch) { _, new in new }).json

        var widths = defaults["paneColumnWidths"] as? [String: Any] ?? [:]
        if let provided = raw["paneColumnWidths"] {
            let patches = try EngineJSON.dictionary(provided, "欄寬設定格式不正確。")
            guard Set(patches.keys).isSubset(of: ["left", "right"]) else { throw EngineError("只能設定左右面板的欄寬。") }
            for (side, supplied) in patches {
                let patch = try EngineJSON.dictionary(supplied, "欄寬設定格式不正確。")
                let previous = widths[side] as? [String: Any] ?? [:]
                widths[side] = previous.merging(patch) { _, new in new }
            }
        }
        var validWidths: [String: Any] = [:]
        for side in ["left", "right"] {
            if let rawWidths = widths[side] {
                let values = try EngineJSON.dictionary(rawWidths, "欄寬設定格式不正確。")
                guard Set(values.keys).isSubset(of: ["name", "size", "modified"]) else { throw EngineError("欄寬名稱不正確。") }
                var sideWidths: [String: Any] = [:]
                for (key, range) in [("name", 120...1600), ("size", 76...400), ("modified", 150...500)] {
                    if let value = values[key] { sideWidths[key] = try EngineJSON.integer(value, "欄寬", range) }
                }
                if !sideWidths.isEmpty { validWidths[side] = sideWidths }
            }
        }
        output["paneColumnWidths"] = validWidths

        // This is an explicit user-saved starting pair, not navigation history.
        // Replace the entire value so {} really clears both panes. Endpoint
        // validation is structural only: saving must never contact a remote.
        let locations = try EngineJSON.dictionary(merged["initialLocations"], "預設啟動資料夾格式不正確。")
        guard Set(locations.keys).isSubset(of: ["left", "right"]) else { throw EngineError("只能設定左右面板的預設啟動資料夾。") }
        var initialLocations: [String: Any] = [:]
        for side in ["left", "right"] {
            if let location = locations[side] { initialLocations[side] = try EngineEndpoint(location).json }
        }
        output["initialLocations"] = initialLocations
        // Workspace is an atomic snapshot, unlike independent appearance patches.
        // Null explicitly forgets it; omission keeps the current snapshot.
        if merged["savedWorkspace"] is NSNull { output["savedWorkspace"] = NSNull() }
        else { output["savedWorkspace"] = try EngineWorkspace(merged["savedWorkspace"]).json }

        let proxyMode = try EngineJSON.text(merged["proxyMode"], "代理伺服器設定")
        guard ["system", "manual"].contains(proxyMode) else { throw EngineError("代理伺服器設定不正確。") }
        output["proxyMode"] = proxyMode
        for key in ["httpProxy", "httpsProxy"] {
            let text = try EngineJSON.text(merged[key], "代理伺服器", maximum: 4096).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                guard let url = URLComponents(string: text), let scheme = url.scheme?.lowercased(),
                      ["http", "https", "socks5", "socks5h"].contains(scheme), let host = url.host, !host.isEmpty,
                      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                      url.path.isEmpty || url.path == "/", url.port == nil || (1...65535).contains(url.port!) else {
                    throw EngineError("代理伺服器請填入 http://127.0.0.1:7890 等網址，不能包含帳號或密碼。")
                }
            }
            output[key] = text
        }
        let noProxy = try EngineJSON.text(merged["noProxy"], "不使用代理的位址", maximum: 4096)
        guard noProxy.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { throw EngineError("不使用代理的位址請以逗號分隔，不要加入空白。") }
        output["noProxy"] = noProxy
        guard let playerArguments = merged["streamPlayerArguments"] as? [Any], playerArguments.count <= 32 else {
            throw EngineError("播放器參數最多 32 個，每行填入一個參數。")
        }
        output["streamPlayerArguments"] = try playerArguments.map { try EngineJSON.text($0, "播放器參數", maximum: 2000) }
        return output
    }

    private func saveSettings(_ value: Any) throws -> [String: Any] {
        try settingsMutationLock.holding {
            let raw = try EngineJSON.dictionary(value, "設定格式不正確。")
            let previous = settingsSnapshot()
            if let suppliedRevision = raw["settingsRevision"] {
                let revision = try EngineJSON.integer(suppliedRevision, "設定版本", 0...9007199254740990)
                guard revision == (previous["settingsRevision"] as? Int ?? 0) else {
                    throw EngineError("設定已在其他操作中更新，請重新整理後再試。")
                }
            }
            var changed = try Self.validateSettings(raw, defaults: previous, isPatch: true)
            let connectionKeys = ["rclonePath", "rcloneDirectory", "configPath", "proxyMode", "httpProxy", "httpsProxy", "noProxy", "defaultRcloneOptions", "networkOptions"]
            let connectionChanged = try EngineJSON.data(previous.filter { connectionKeys.contains($0.key) }) != EngineJSON.data(changed.filter { connectionKeys.contains($0.key) })
            if let config = changed["configPath"] as? String, !config.isEmpty {
                var directory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: config, isDirectory: &directory), !directory.boolValue else { throw EngineError("指定的設定檔不存在或不是檔案。") }
            }
            var reserved = false
            defer {
                if connectionChanged {
                    stateLock.holding { if reserved { operationCount -= 1 }; configurationChanging = false }
                }
                pump()
            }
            try stateLock.holding {
                guard !closing else { throw EngineError("程式正在關閉。") }
                if connectionChanged {
                    guard !maintenance, !jobs.values.contains(where: { !EngineJob.terminal.contains($0.status) }) else {
                        throw EngineError("請等候傳輸或更新結束，再切換 rclone、設定檔或網路設定。")
                    }
                    configurationChanging = true
                }
            }
            if connectionChanged {
                // Existing directory reads keep their previous context. New calls
                // wait at settingsMutationLock until the new path is fully probed.
                let deadline = Date().addingTimeInterval(30)
                while stateLock.holding({ operationCount != 0 || !captureChildren.isEmpty }) {
                    guard Date() < deadline else { throw EngineError("目前的目錄讀取尚未結束。請稍後再切換位置。") }
                    guard !stateLock.holding({ closing }) else { throw EngineError("程式正在關閉。") }
                    Thread.sleep(forTimeInterval: 0.01)
                }
                try stateLock.holding {
                    guard !jobs.values.contains(where: { !EngineJob.terminal.contains($0.status) }) else {
                        throw EngineError("傳輸已開始，請等候工作結束再切換位置。")
                    }
                    operationCount += 1; reserved = true
                }
            }
            changed["settingsRevision"] = (previous["settingsRevision"] as? Int ?? 0) + 1
            // Write before publishing. A failed disk write cannot discard a newer
            // path, language or skipped version through a stale full-object rollback.
            try storageLock.holding {
                try EngineStorage.atomicJSON(changed, to: stateDirectory.appendingPathComponent("settings.json"))
                stateLock.holding {
                    settings = changed
                    if connectionChanged {
                        if previous["configPath"] as? String != changed["configPath"] as? String { configPassword = nil }
                        environment = Self.blankEnvironment(configPath: changed["configPath"] as? String ?? "")
                    }
                    environment["settingsRevision"] = changed["settingsRevision"]
                }
            }
            if connectionChanged { return try detectEnvironment() }
            return stateLock.holding { environment }
        }
    }

    private func unlockConfig(_ password: String) throws {
        guard password.utf8.count <= 32768, !password.contains("\0") else { throw EngineError("密碼格式不正確。") }
        try withOperation {
            _ = try requireAvailable()
            let previous = stateLock.holding { () -> String? in let old = configPassword; configPassword = password; return old }
            do { _ = try remotes(); _ = stateLock.holding { environment.removeValue(forKey: "error") } }
            catch { stateLock.holding { configPassword = previous }; throw error }
        }
    }

    private func getLogPath(_ id: String) throws -> String {
        let writer: EngineLogWriter? = try stateLock.holding {
            guard EngineJSON.validID(id), jobs[id] != nil else { throw EngineError("找不到這項工作的記錄。") }
            return active[id]?.log
        }
        return try writer?.exportPath() ?? EngineLogWriter.exportPath(directory: logDirectory, id: id)
    }

    private func getJobReport(_ id: String, query: Any) throws -> [String: Any] {
        let parameters = try EngineJSON.dictionary(query, "逐檔報告查詢格式不正確。")
        guard Set(parameters.keys).isSubset(of: ["category", "cursor", "limit"]) else { throw EngineError("逐檔報告查詢格式不正確。") }
        let category = try EngineJSON.text(parameters["category"] ?? "all", "報告分類")
        guard ["all", "success", "errors", "skipped", "comparison"].contains(category) else { throw EngineError("逐檔報告分類不正確。") }
        let cursor = try EngineJSON.integer(parameters["cursor"] ?? 0, "報告位置", 0...9000000000000000)
        let limit = try EngineJSON.integer(parameters["limit"] ?? 100, "每頁筆數", 1...200)
        let writer: EngineTransferReport? = try stateLock.holding {
            guard EngineJSON.validID(id), jobs[id] != nil else { throw EngineError("找不到這項工作的記錄。") }
            return transferReports[id]
        }
        // A page is an explicit UI request, never a directory scan or a poll of
        // transfer files. Flush only app-owned report buffers before reading it.
        try writer?.flushVisible()
        var page = try EngineTransferReport.page(directory: logDirectory, id: id, category: category, cursor: Int64(cursor), limit: limit)
        if let writer = writer { page["summary"] = writer.summary }
        else if let summary = stateLock.holding({ jobs[id]?.report }) { page["summary"] = summary }
        return page
    }

    private func getJobReportPath(_ id: String, format: String) throws -> String {
        guard ["jsonl", "comparison"].contains(format) else { throw EngineError("逐檔報告格式不正確。") }
        let writer: EngineTransferReport? = try stateLock.holding {
            guard EngineJSON.validID(id), jobs[id] != nil else { throw EngineError("找不到這項工作的記錄。") }
            return transferReports[id]
        }
        if let writer = writer { return try writer.exportPath(format: format) }
        return try EngineTransferReport.exportPath(directory: logDirectory, id: id, format: format)
    }

    private func persist() throws {
        try storageLock.holding {
            let values: ([String: Any], [[String: Any]], [[String: Any]], [String]) = stateLock.holding {
                // Keep the 200 most recent completed/failed/cancelled jobs.
                // Interrupted requests, pending jobs and active processes are
                // never evicted. Saved tasks have an independent collection.
                let completed = jobOrder.enumerated().filter { _, id in
                    active[id] == nil && jobs[id].map { EngineJob.automaticallyPrunable.contains($0.status) } == true
                }.sorted {
                    let first = jobs[$0.element]!, second = jobs[$1.element]!
                    let firstEnd = first.endedAt ?? first.createdAt, secondEnd = second.endedAt ?? second.createdAt
                    return firstEnd == secondEnd ? $0.offset < $1.offset : firstEnd < secondEnd
                }
                let expired = completed.prefix(max(0, completed.count - 200)).map(\.element)
                for id in expired {
                    jobs.removeValue(forKey: id)
                    scheduledNotifications[id]?.cancel(); scheduledNotifications.removeValue(forKey: id)
                }
                let removed = Set(expired)
                jobOrder.removeAll { removed.contains($0) }
                return (settings, jobOrder.compactMap { jobs[$0]?.json }, tasks.values.map(\.json), expired)
            }
            try EngineStorage.atomicJSON(values.0, to: stateDirectory.appendingPathComponent("settings.json"))
            try EngineStorage.atomicJSON(values.1, to: stateDirectory.appendingPathComponent("jobs.json"))
            try EngineStorage.atomicJSON(values.2, to: stateDirectory.appendingPathComponent("tasks.json"))
            // Log retention is best-effort after committing history. Failure to
            // remove an old log must never cancel an unrelated running transfer.
            removeOwnedLogs(values.3)
        }
    }

    func shutdown() {
        let children: [Process] = stateLock.holding {
            closing = true
            for item in scheduledNotifications.values { item.cancel() }; scheduledNotifications.removeAll()
            for job in jobs.values {
                if active[job.id] != nil { _ = markCancellation(job) }
                else if job.status == "queued" { job.status = "interrupted"; job.endedAt = EngineJSON.now(); job.error = "程式關閉，排隊工作未執行。" }
            }
            return Array(captureChildren.values)
        }
        for child in children { requestStop(child) }
        let running = stateLock.holding { Array(active.values) }
        for item in running { item.done.wait() }
        stateLock.holding { configPassword = nil }
        // The host has no throwing shutdown path. Jobs were persisted at submission
        // and completion; any remaining queued/running history becomes interrupted on restart.
        try? persist()
    }
}

private func DarwinOrGlibcKill(_ pid: Int32, _ signal: Int32) -> Int32 {
    EnginePlatform.signal(pid, signal)
}

private func readPipeChunk(_ handle: FileHandle) throws -> Data? {
    let bytes = try EnginePlatform.readAvailable(handle)
    return bytes.isEmpty ? nil : bytes
}
