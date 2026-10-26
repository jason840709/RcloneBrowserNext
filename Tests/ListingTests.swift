import Foundation
#if os(Windows)
import WinSDK
import ucrt
#elseif canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw EngineError(message) }
}

private func fixtureStep<T>(_ stage: String, at path: URL, _ action: () throws -> T) throws -> T {
    do { return try action() }
    catch {
        throw NSError(domain: "RcloneBrowserNext.ListingFixture", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Fixture stage=\(stage), path=\(path.path), underlying=\(error)",
            NSFilePathErrorKey: path.path, NSUnderlyingErrorKey: error, "stage": stage,
        ])
    }
}

private func waitUntil(_ description: String, seconds: TimeInterval = 8, _ condition: () throws -> Bool) throws {
    let deadline = Date().addingTimeInterval(seconds)
    while try !condition() {
        guard Date() < deadline else { throw EngineError("Timed out: \(description)") }
        Thread.sleep(forTimeInterval: 0.01)
    }
}

private func processAlive(_ pid: Int32) -> Bool {
    #if os(Windows)
    guard let handle = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, DWORD(bitPattern: pid)) else { return false }
    defer { CloseHandle(handle) }
    var code: DWORD = 0
    return GetExitCodeProcess(handle, &code) && code == DWORD(259)
    #else
    return kill(pid, 0) == 0 || errno == EPERM
    #endif
}

private final class ListingResult {
    private let lock = NSLock()
    private let done = DispatchGroup()
    private var result: Result<Any, Error>?
    init(_ action: @escaping () throws -> Any) {
        done.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let value = Result { try action() }
            lock.holding { result = value }
            done.leave()
        }
    }
    func wait(seconds: TimeInterval = 10) throws -> Any {
        guard done.wait(timeout: .now() + seconds) == .success else { throw EngineError("Listing worker did not unwind") }
        return try lock.holding { try result!.get() }
    }
}

/// The same test executable acts as a controlled rclone-shaped child. No shell,
/// external interpreter or environment credentials are used. Separate real
/// rclone tests below verify metadata, network cancellation and transfer scope.
private func fixtureChild(_ command: String) throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let configArgument = arguments.first(where: { $0.hasPrefix("--config=") }) else { throw EngineError("Missing fixture config") }
    let config = String(configArgument.dropFirst("--config=".count))
    let area = URL(fileURLWithPath: config).deletingLastPathComponent()
    let endpoint = arguments.last ?? ""
    let name = endpoint.components(separatedBy: ":").last?.replacingOccurrences(of: "/", with: "_") ?? ""
    #if !os(Windows)
    if command == "lsjson", name.hasPrefix("late") || name.hasPrefix("stubborn") {
        _ = signal(SIGINT, SIG_IGN)
        _ = signal(SIGTERM, SIG_IGN)
    }
    #endif
    let eventDirectory = area.appendingPathComponent("events", isDirectory: true)
    let event = eventDirectory.appendingPathComponent("\(command)-\(ProcessInfo.processInfo.processIdentifier).json")
    let pending = eventDirectory.appendingPathComponent("\(command)-\(UUID().uuidString).pending")
    let bytes = try fixtureStep("event-encode", at: event) {
        try EngineJSON.data(["command": command, "endpoint": endpoint, "pid": ProcessInfo.processInfo.processIdentifier,
                             "arguments": arguments])
    }
    // Publish only a fully closed file from this same directory. Final event
    // files remain immutable until the entire fixture area is removed.
    let handle = try fixtureStep("event-create", at: pending) { try EnginePlatform.createExclusiveFile(pending) }
    do {
        try fixtureStep("event-write", at: pending) { try handle.write(contentsOf: bytes) }
        try fixtureStep("event-close", at: pending) { try handle.close() }
    } catch {
        try? handle.close()
        throw error
    }
    try fixtureStep("event-publish-from-\(pending.lastPathComponent)", at: event) {
        try FileManager.default.moveItem(at: pending, to: event)
    }
    func waitForGate(_ gate: String) throws {
        try waitUntil("fixture gate \(gate)", seconds: 20) { FileManager.default.fileExists(atPath: area.appendingPathComponent(gate).path) }
    }
    switch command {
    case "version":
        if FileManager.default.fileExists(atPath: area.appendingPathComponent("block-version").path) { try waitForGate("release-version") }
        print("rclone v1.75.2 listing-test-fixture")
    case "listremotes": print("[{\"name\":\"fixture\",\"type\":\"alias\"}]")
    case "lsjson":
        if name.hasPrefix("wait") || name.hasPrefix("late") || name.hasPrefix("stubborn") { try waitForGate("release-" + name) }
        try FileHandle.standardOutput.write(contentsOf: EngineJSON.data([
            ["Name": "fixture-" + name, "Path": "fixture-" + name, "Size": 7,
             "ModTime": "2026-01-02T03:04:05Z", "IsDir": false] as [String: Any]
        ]))
    default: throw EngineError("Unexpected fixture command")
    }
}

private final class ListingSuite {
    let root: URL
    let rclone: String
    var passed = 0, failed = 0
    private let fm = FileManager.default

    init(root: URL, rclone: String) throws {
        self.root = root; self.rclone = rclone
        try EngineStorage.privateDirectory(root)
    }

    func test(_ name: String, _ body: () throws -> Void) {
        do { try body(); passed += 1; print("PASS \(name)") }
        catch { failed += 1; print("FAIL \(name): \(error)") }
        fflush(stdout)
    }

    func area(_ name: String) throws -> URL {
        let value = root.appendingPathComponent(name)
        try EngineStorage.privateDirectory(value.appendingPathComponent("events"))
        return value
    }

    func makeEngine(_ name: String, real: Bool = false, ready: Bool = true, timeout: TimeInterval = 120,
                    config: String = "[fixture]\ntype = alias\nremote = .\n") throws -> (RcloneEngine, URL) {
        let area = try area(name), configURL = area.appendingPathComponent("rclone.conf")
        try Data(config.utf8).write(to: configURL)
        let binary = real ? rclone : URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        let state = area.appendingPathComponent("state")
        try EngineStorage.privateDirectory(state)
        var settings = RcloneEngine.defaultSettings(directory: area)
        settings["rclonePath"] = binary; settings["configPath"] = configURL.path; settings["autoCheckUpdates"] = false
        try EngineStorage.atomicJSON(settings, to: state.appendingPathComponent("settings.json"))
        let engine = try RcloneEngine(stateDirectory: state, defaultRcloneDirectory: area, listingTimeout: timeout)
        if ready {
            let environment = try engine.invoke("environment", arguments: []) as! [String: Any]
            try require(environment["available"] as? Bool == true, "Fixture engine did not initialize: \(environment)")
        }
        return (engine, area)
    }

    func endpoint(_ path: String, remote: String = "fixture") -> [String: Any] { ["remote": remote, "path": path] }
    func list(_ engine: RcloneEngine, _ path: String, id: String, remote: String = "fixture") -> ListingResult {
        ListingResult { try engine.invoke("list", arguments: [self.endpoint(path, remote: remote), ["requestId": id]]) }
    }
    func pid(_ engine: RcloneEngine, _ id: String) throws -> Int32 {
        var pid: Int32?
        try waitUntil("listing child \(id)") { pid = engine.listingProcessIdentifier(id); return pid != nil }
        return pid!
    }
    func cancel(_ engine: RcloneEngine, _ id: String) throws -> [String: Any] {
        try engine.invoke("cancelList", arguments: [id]) as! [String: Any]
    }
    func status(_ result: ListingResult, _ expected: String) throws -> [String: Any] {
        let value = try result.wait() as! [String: Any]
        try require(value["status"] as? String == expected, "Wrong listing status: \(value)")
        if expected == "cancelled" { try require((value["entries"] as? [[String: Any]])?.isEmpty == true, "Cancelled listing returned rows") }
        return value
    }
    func release(_ area: URL, _ name: String) throws {
        let gate = area.appendingPathComponent("release-" + name)
        try fixtureStep("release-gate", at: gate) { try Data().write(to: gate) }
    }
    func events(_ area: URL) throws -> [[String: Any]] {
        let directory = area.appendingPathComponent("events", isDirectory: true)
        // Read names only: an in-progress .pending file may disappear when its
        // writer publishes it, so URL enumeration must not stat that entry.
        let names = try fixtureStep("event-enumeration", at: directory) { try fm.contentsOfDirectory(atPath: directory.path) }
        return try names.filter {
            $0.range(of: #"^(version|lsjson|listremotes)-[1-9][0-9]*\.json$"#, options: .regularExpression) != nil
        }.sorted().map { name in
            let event = directory.appendingPathComponent(name)
            let bytes = try fixtureStep("event-read", at: event) { try Data(contentsOf: event) }
            return try fixtureStep("event-decode", at: event) {
                guard let value = try EngineJSON.object(bytes) as? [String: Any] else { throw EngineError("Fixture event is not a JSON object") }
                return value
            }
        }
    }

    func run() {
        test("browse preserves legacy arrays and starts only one lsjson per ready remote listing") {
            let (engine, area) = try makeEngine("one-command"); defer { engine.shutdown() }
            let old = try engine.invoke("list", arguments: [endpoint("fast")]) as! [[String: Any]]
            let value = try status(list(engine, "fast", id: UUID().uuidString), "completed")
            try require(old.count == 1 && old[0]["modified"] as? String == "2026-01-02T03:04:05Z", "Legacy metadata changed")
            try require((value["entries"] as? [[String: Any]])?.count == 1, "Scoped result lost entries")
            let calls = try events(area)
            try require(calls.filter { $0["command"] as? String == "lsjson" }.count == 2, "Listing spawned extra lsjson processes")
            try require(!calls.contains { $0["command"] as? String == "listremotes" }, "Browsing still spawned listremotes")
        }

        test("cancellation before dispatch prevents spawn and rejects reused active request IDs") {
            let (engine, area) = try makeEngine("pre-cancel"); defer { engine.shutdown() }
            let id = UUID().uuidString, count = try events(area).count
            try require(try cancel(engine, id)["cancelled"] as? Bool == true, "Pre-cancel was not acknowledged")
            try engine.prepareListing(options: ["requestId": id])
            _ = try status(list(engine, "wait-never", id: id), "cancelled")
            try require(try events(area).count == count, "Pre-cancel still started a child")
            do { _ = try engine.invoke("list", arguments: [endpoint("fast"), ["requestId": id]]); throw EngineError("Reused ID was accepted") }
            catch { try require(error.localizedDescription != "Reused ID was accepted", "Reused ID was accepted") }
        }

        test("context reset cancels a reserved worker before it starts") {
            let (engine, area) = try makeEngine("queued-reset"); defer { engine.shutdown() }
            let id = UUID().uuidString, count = try events(area).count
            try engine.prepareListing(options: ["requestId": id])
            engine.cancelListings()
            _ = try status(list(engine, "wait-never", id: id), "cancelled")
            try require(try events(area).count == count, "Reset queued child spawned later")
            _ = try status(list(engine, "fast", id: UUID().uuidString), "completed")
        }

        test("cancel reaps only its child while same-folder other pane and newer request continue") {
            let (engine, area) = try fixtureStep("pane-scope-setup", at: root.appendingPathComponent("pane-scope")) {
                try makeEngine("pane-scope")
            }
            defer { engine.shutdown() }
            let a = UUID().uuidString, b = UUID().uuidString
            let left = list(engine, "wait-shared", id: a), right = list(engine, "wait-shared", id: b)
            let leftPID = try pid(engine, a), rightPID = try pid(engine, b)
            var childPIDs: [Int32] = []
            try waitUntil("both actual fixture children") {
                childPIDs = try events(area).filter { $0["command"] as? String == "lsjson" }.compactMap { ($0["pid"] as? NSNumber)?.int32Value }
                return childPIDs.count == 2
            }
            let start = Date(); _ = try cancel(engine, a)
            try require(!processAlive(leftPID), "Cancel acknowledged while its child was still alive")
            try require(processAlive(rightPID), "Cancel killed the other pane")
            // On Windows Process refers to the protected launcher. The fixture
            // records its own child PID, proving the launcher also reaped its
            // child rather than merely exiting itself.
            try require(childPIDs.filter(processAlive).count == 1, "Cancellation did not stop exactly one actual listing child")
            _ = try status(left, "cancelled")
            let newerID = UUID().uuidString, newer = list(engine, "wait-shared", id: newerID), newerPID = try pid(engine, newerID)
            try require(try cancel(engine, a)["cancelled"] as? Bool == false, "Completed cancellation changed state")
            try require(processAlive(newerPID) && processAlive(rightPID), "Late cancellation affected a newer request")
            try release(area, "wait-shared")
            _ = try status(right, "completed"); _ = try status(newer, "completed")
            print("LISTING_CANCEL_EVIDENCE " + String(decoding: try EngineJSON.data(["pid": leftPID, "aliveAfterAck": false, "otherPID": rightPID, "actualChildPIDs": childPIDs, "actualChildrenAliveAfterAck": 1, "elapsedSeconds": Date().timeIntervalSince(start)]), as: UTF8.self))
        }

        #if !os(Windows)
        test("successful output arriving after cancellation never becomes a completed listing") {
            let (engine, area) = try makeEngine("late-output"); defer { engine.shutdown() }
            let id = UUID().uuidString, result = list(engine, "late-success", id: id), child = try pid(engine, id)
            try waitUntil("installed fixture signal handlers") { try events(area).contains { $0["command"] as? String == "lsjson" } }
            let cancellation = ListingResult { try self.cancel(engine, id) }
            Thread.sleep(forTimeInterval: 0.05)
            try release(area, "late-success")
            _ = try cancellation.wait(); _ = try status(result, "cancelled")
            try require(!processAlive(child), "Late successful child was not reaped")
        }

        test("unresponsive read-only child is force-stopped without transfer cleanup grace") {
            let (engine, area) = try makeEngine("forced-stop"); defer { engine.shutdown() }
            let id = UUID().uuidString, result = list(engine, "stubborn-read", id: id), child = try pid(engine, id)
            try waitUntil("installed stubborn signal handlers") { try events(area).contains { $0["command"] as? String == "lsjson" } }
            let start = Date(); _ = try cancel(engine, id)
            try require(Date().timeIntervalSince(start) < 4 && !processAlive(child), "Read-only escalation did not reap the child promptly")
            _ = try status(result, "cancelled")
        }
        #endif

        test("cancel covers environment discovery and allows a clean retry") {
            let (engine, area) = try makeEngine("initial-discovery", ready: false); defer { engine.shutdown() }
            try Data().write(to: area.appendingPathComponent("block-version"))
            let id = UUID().uuidString, result = list(engine, "fast", id: id), child = try pid(engine, id)
            try waitUntil("version discovery started") { try events(area).contains { $0["command"] as? String == "version" } }
            _ = try cancel(engine, id); _ = try status(result, "cancelled")
            try require(!processAlive(child), "Discovery child survived cancellation")
            try fm.removeItem(at: area.appendingPathComponent("block-version"))
            _ = try status(list(engine, "fast", id: UUID().uuidString), "completed")
        }

        test("native deadline stops its listing process and reports an error rather than empty success") {
            let (engine, _) = try makeEngine("timeout", timeout: 1.5); defer { engine.shutdown() }
            let id = UUID().uuidString, result = list(engine, "wait-timeout", id: id), child = try pid(engine, id)
            do { _ = try result.wait(); throw EngineError("Timeout returned success") }
            catch { try require(error.localizedDescription.contains("逾時"), "Timeout was not reported: \(error)") }
            try require(!processAlive(child), "Timed-out child remained alive")
            _ = try status(list(engine, "fast", id: UUID().uuidString), "completed")
        }

        test("connection change cancels old reading and queued requests before publishing new settings") {
            let (engine, _) = try makeEngine("old-config"); defer { engine.shutdown() }
            let id = UUID().uuidString, result = list(engine, "wait-old", id: id), child = try pid(engine, id)
            let queued = UUID().uuidString; try engine.prepareListing(options: ["requestId": queued])
            let next = try area("new-config"), config = next.appendingPathComponent("rclone.conf")
            try Data("[fixture]\ntype = alias\nremote = .\n".utf8).write(to: config)
            let saved = try engine.invoke("saveSettings", arguments: [["configPath": config.path]]) as! [String: Any]
            try require(saved["available"] as? Bool == true && !processAlive(child), "Settings changed before old child was reaped")
            _ = try status(result, "cancelled"); _ = try status(list(engine, "wait-obsolete", id: queued), "cancelled")
            _ = try status(list(engine, "fast", id: UUID().uuidString), "completed")
            try require(try events(next).contains { $0["command"] as? String == "lsjson" }, "New listing used the previous configuration")
        }

        test("cancel during a replacement environment probe never waits for or stops the unrelated probe") {
            let (engine, _) = try makeEngine("settings-gate"); defer { engine.shutdown() }
            let next = try area("blocked-new-config"), config = next.appendingPathComponent("rclone.conf")
            try Data("[fixture]\ntype = alias\nremote = .\n".utf8).write(to: config)
            try Data().write(to: next.appendingPathComponent("block-version"))
            let saving = ListingResult { try engine.invoke("saveSettings", arguments: [["configPath": config.path]]) }
            defer { try? release(next, "version"); _ = try? saving.wait() }
            try waitUntil("replacement probe owns settings gate") { try events(next).contains { $0["command"] as? String == "version" } }
            let probe = try events(next).first { $0["command"] as? String == "version" }!["pid"] as! NSNumber
            let id = UUID().uuidString, result = list(engine, "wait-obsolete", id: id)
            let start = Date(); _ = try cancel(engine, id)
            _ = try status(result, "cancelled")
            try require(Date().timeIntervalSince(start) < 1 && processAlive(probe.int32Value), "Cancellation waited for or stopped a different environment probe")
            try require(!(try events(next).contains { $0["command"] as? String == "lsjson" }), "Obsolete listing spawned under a replacement context")
            try release(next, "version")
            try require((try saving.wait() as! [String: Any])["available"] as? Bool == true, "Replacement settings did not finish")
            _ = try status(list(engine, "fast", id: UUID().uuidString), "completed")
        }

        test("shutdown reaps both listing children and prevents reserved late workers") {
            let (engine, _) = try makeEngine("shutdown"); defer { engine.shutdown() }
            let a = UUID().uuidString, b = UUID().uuidString, queued = UUID().uuidString
            let left = list(engine, "wait-left", id: a), right = list(engine, "wait-right", id: b)
            let first = try pid(engine, a), second = try pid(engine, b)
            try engine.prepareListing(options: ["requestId": queued])
            engine.shutdown()
            try require(!processAlive(first) && !processAlive(second), "Shutdown left directory children running")
            _ = try status(left, "cancelled"); _ = try status(right, "cancelled")
            _ = try status(list(engine, "wait-late", id: queued), "cancelled")
        }

        test("local adapter keeps original errors and pre-cancel performs no filesystem read") {
            let (engine, _) = try makeEngine("local-adapter"); defer { engine.shutdown() }
            let endpoint = try EngineEndpoint(["remote": NSNull(), "path": root.path])
            let id = UUID().uuidString; _ = try cancel(engine, id)
            var calls = 0
            let cancelled = try engine.listDirectory(endpoint, options: ["requestId": id], localListing: { _ in calls += 1; return [] }) as! [String: Any]
            try require(calls == 0 && cancelled["status"] as? String == "cancelled", "Pre-cancel invoked the filesystem adapter")
            do {
                _ = try engine.listDirectory(endpoint, options: ["requestId": UUID().uuidString], localListing: { _ in throw EngineError("original permission failure") })
                throw EngineError("Filesystem error was swallowed")
            } catch { try require(error.localizedDescription == "original permission failure", "Filesystem permissions/error semantics changed") }
        }

        test("real rclone keeps Unicode names sizes modification times and missing-remote errors") {
            let files = try area("real-files")
            try Data("1234567".utf8).write(to: files.appendingPathComponent("測試-日本語.txt"))
            try EngineStorage.privateDirectory(files.appendingPathComponent("folder"))
            let (engine, _) = try makeEngine("real-alias", real: true, config: "[fixture]\ntype = alias\nremote = \(files.path)\n")
            defer { engine.shutdown() }
            let legacy = try engine.invoke("list", arguments: [endpoint("")]) as! [[String: Any]]
            let scoped = try status(list(engine, "", id: UUID().uuidString), "completed")
            let entries = scoped["entries"] as! [[String: Any]], file = entries.first { $0["name"] as? String == "測試-日本語.txt" }
            try require(entries.count == legacy.count && entries.first?["isDir"] as? Bool == true, "Real directory shape/order changed")
            try require((file?["size"] as? NSNumber)?.intValue == 7 && !(file?["modified"] as? String ?? "").isEmpty, "Real metadata was omitted")
            do { _ = try list(engine, "", id: UUID().uuidString, remote: "missing-remote").wait(); throw EngineError("Missing remote returned success") }
            catch { try require(error.localizedDescription.contains("rclone 執行失敗"), "Missing remote did not preserve the rclone error") }
        }

        test("real throttled HTTP listing cancellation reaps rclone and preserves a running transfer") {
            try realNetworkCancellation()
        }
    }

    private func realNetworkCancellation() throws {
        let files = try area("http-root")
        for index in 0..<12 { try Data("metadata".utf8).write(to: files.appendingPathComponent("item-\(index).txt")) }
        let log = root.appendingPathComponent("http-server.log"), emptyConfig = root.appendingPathComponent("server.conf")
        try Data().write(to: emptyConfig)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: rclone)
        server.arguments = ["--config", emptyConfig.path, "serve", "http", files.path, "--addr", "127.0.0.1:0", "--log-level", "INFO", "--log-file", log.path]
        server.environment = ProcessInfo.processInfo.environment.filter { !$0.key.uppercased().hasPrefix("RCLONE_") }
        server.standardInput = FileHandle.nullDevice; server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        try EnginePlatform.prepare(server); try server.run()
        defer {
            if server.isRunning {
                _ = EnginePlatform.signal(server.processIdentifier, SIGINT)
                let deadline = Date().addingTimeInterval(2)
                while server.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
                if server.isRunning { _ = EnginePlatform.signal(server.processIdentifier, SIGKILL) }
                server.waitUntilExit()
            }
        }
        var url = ""
        let expression = try NSRegularExpression(pattern: #"http://127\.0\.0\.1:[0-9]+/"#)
        try waitUntil("real HTTP backend") {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            if let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range, in: text) { url = String(text[range]) }
            return !url.isEmpty
        }
        let (engine, _) = try makeEngine("real-http", real: true, config: "[fixture]\ntype = http\nurl = \(url)\n")
        defer { engine.shutdown() }
        _ = try engine.invoke("saveSettings", arguments: [["networkOptions": ["tpsLimit": 1, "tpsBurst": 1]]])
        let source = try area("copy-source"), destination = try area("copy-destination")
        try Data(repeating: 0x5a, count: 2 * 1024 * 1024).write(to: source.appendingPathComponent("owned.bin"))
        let request: [String: Any] = ["source": ["remote": NSNull(), "path": source.path], "destination": ["remote": NSNull(), "path": destination.path],
            "mode": "copy", "dryRun": false, "selection": [[String: Any]](),
            "options": EngineTransferOptions.defaults.merging(["bandwidth": "64K", "extraArgs": ["--local-no-clone", "--multi-thread-streams=0"]]) { _, new in new }]
        let transfer = try engine.invoke("startTransfer", arguments: [request]) as! [String: Any], transferID = transfer["id"] as! String
        func transferStatus() throws -> String? {
            let jobs = try engine.invoke("listJobs", arguments: []) as! [[String: Any]]
            return jobs.first { $0["id"] as? String == transferID }?["status"] as? String
        }
        try waitUntil("real transfer running") { try transferStatus() == "running" }
        let id = UUID().uuidString, result = list(engine, "", id: id), child = try pid(engine, id)
        Thread.sleep(forTimeInterval: 0.15)
        try require(processAlive(child), "HTTP fixture did not hold a real listing")
        let start = Date(); _ = try cancel(engine, id)
        let elapsed = Date().timeIntervalSince(start)
        _ = try status(result, "cancelled")
        try require(!processAlive(child), "Actual rclone child survived cancellation acknowledgement")
        try require(try transferStatus() == "running", "Directory cancellation changed the transfer status")
        try require(elapsed < 5, "Real rclone directory cancellation exceeded its bound")
        print("REAL_LISTING_CANCEL_EVIDENCE " + String(decoding: try EngineJSON.data(["pid": child, "aliveAfterAck": false, "elapsedSeconds": elapsed,
            "transferStillRunning": true, "loopbackOnly": true]), as: UTF8.self))
        _ = try engine.invoke("cancelJob", arguments: [transferID])
        try require(try transferStatus() == "cancelled", "Fixture transfer did not stop during explicit cleanup")
    }
}

@main
struct ListingTests {
    static func main() throws {
        if let command = CommandLine.arguments.dropFirst().first(where: { ["version", "lsjson", "listremotes"].contains($0) }) {
            try fixtureChild(command); return
        }
        guard CommandLine.arguments.count > 1 else { throw EngineError("Pass the real pinned rclone executable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rbn-listings-" + UUID().uuidString)
        let suite = try ListingSuite(root: root, rclone: CommandLine.arguments[1])
        defer { try? FileManager.default.removeItem(at: root) }
        suite.run()
        print("RESULT \(suite.passed) passed, \(suite.failed) failed")
        if suite.failed > 0 { exit(1) }
    }
}
