import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private struct TestFailure: Error, CustomStringConvertible { let description: String }
private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw TestFailure(description: message) }
}
private func rejects(_ message: String, _ body: () throws -> Void) throws {
    do { try body() } catch { return }; throw TestFailure(description: message)
}

private final class TestConcurrentResults {
    private let lock = NSLock()
    private var failures: [String] = []
    func capture(_ body: () throws -> Void) { do { try body() } catch { lock.holding { failures.append(String(describing: error)) } } }
    var errors: [String] { lock.holding { failures } }
}

#if os(Linux)
/// Observe actual kernel file access by the rclone child, rather than inferring
/// NAS read behavior from displayed transfer-byte counters or log wording.
private final class TestFileReadMonitor {
    private let descriptor: Int32
    init(_ path: String) throws {
        descriptor = inotify_init1(Int32(IN_NONBLOCK | IN_CLOEXEC))
        guard descriptor >= 0 else { throw TestFailure(description: "inotify init failed") }
        guard inotify_add_watch(descriptor, path, UInt32(IN_OPEN | IN_ACCESS)) >= 0 else {
            _ = Glibc.close(descriptor); throw TestFailure(description: "inotify watch failed")
        }
    }
    deinit { _ = Glibc.close(descriptor) }
    func masks() -> UInt32 {
        var result: UInt32 = 0
        var bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Glibc.read(descriptor, &bytes, bytes.count)
            if count <= 0 { return result }
            var offset = 0
            while offset + 16 <= count {
                func little(_ index: Int) -> UInt32 { (0..<4).reduce(0) { $0 | (UInt32(bytes[index + $1]) << UInt32($1 * 8)) } }
                result |= little(offset + 4)
                offset += 16 + Int(little(offset + 12))
            }
        }
    }
}
#endif

/// A small loopback HTTP backend for real-rclone network tests. It binds an
/// ephemeral port and records only requests from this test; no internet service
/// or external interpreter is needed on macOS or Linux.
private final class TestHTTPBackend {
    struct Request { let time: TimeInterval; let userAgent: String; let peer: String; let path: String }
    private let descriptor: Int32
    private let lock = NSLock()
    private let done = DispatchGroup()
    private var closed = false
    private var received: [Request] = []
    let port: UInt16
    var requests: [Request] { lock.holding { received } }
    var url: String { "http://127.0.0.1:\(port)/" }

    init() throws {
        #if os(Linux)
        let stream = Int32(SOCK_STREAM.rawValue)
        #else
        let stream = SOCK_STREAM
        #endif
        let fd = socket(AF_INET, stream, 0)
        guard fd >= 0 else { throw TestFailure(description: "fixture socket failed") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var address = sockaddr_in()
        #if os(macOS)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET); address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 32) == 0 else { _ = close(fd); throw TestFailure(description: "fixture bind/listen failed") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { _ = close(fd); throw TestFailure(description: "fixture port discovery failed") }
        descriptor = fd; port = UInt16(bigEndian: address.sin_port)
        done.enter()
        DispatchQueue(label: "RBN.core-tests.http").async { [self] in defer { done.leave() }; serve() }
    }

    func stop() {
        let shouldClose = lock.holding { () -> Bool in guard !closed else { return false }; closed = true; return true }
        if shouldClose { _ = shutdown(descriptor, Int32(SHUT_RDWR)); _ = close(descriptor) }
        _ = done.wait(timeout: .now() + 4)
    }

    private func serve() {
        while !lock.holding({ closed }) {
            var peer = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let fd = withUnsafeMutablePointer(to: &peer) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(descriptor, $0, &length) }
            }
            if fd < 0 { if errno == EINTR { continue }; return }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            _ = withUnsafePointer(to: &timeout) { setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size)) }
            handle(fd, peer: String(cString: inet_ntoa(peer.sin_addr)))
            _ = close(fd)
        }
    }

    private func handle(_ fd: Int32, peer: String) {
        var bytes: [UInt8] = [], buffer = [UInt8](repeating: 0, count: 4096)
        while bytes.count <= 16384 {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count <= 0 { return }; bytes += buffer.prefix(count)
            if String(decoding: bytes, as: UTF8.self).contains("\r\n\r\n") { break }
        }
        let lines = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\r\n")
        let fields = (lines.first ?? "").split(separator: " ")
        guard fields.count >= 2 else { return }
        let method = String(fields[0]), path = String(fields[1]).components(separatedBy: "?")[0]
        let agent = lines.first { $0.lowercased().hasPrefix("user-agent:") }.map { String($0.dropFirst(11)).trimmingCharacters(in: .whitespaces) } ?? ""
        lock.holding { received.append(Request(time: Date().timeIntervalSince1970, userAgent: agent, peer: peer, path: path)) }
        let body = path == "/" ? "<html><body><a href=\"one.bin\">one.bin</a><a href=\"two.bin\">two.bin</a><a href=\"three.bin\">three.bin</a></body></html>" : "sample"
        let header = "HTTP/1.1 200 OK\r\nContent-Type: \(path == "/" ? "text/html" : "application/octet-stream")\r\nContent-Length: \(body.utf8.count)\r\nLast-Modified: Tue, 14 Nov 2023 22:13:20 GMT\r\nConnection: close\r\n\r\n"
        let response = Array((header + (method == "HEAD" ? "" : body)).utf8)
        _ = response.withUnsafeBytes { raw in
            #if os(Linux)
            return send(fd, raw.baseAddress, raw.count, Int32(MSG_NOSIGNAL))
            #else
            var noSignal: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            return send(fd, raw.baseAddress, raw.count, 0)
            #endif
        }
    }
}

private final class CoreTestSuite {
    var passed = 0
    var failed = 0
    var skipped = 0
    let root: URL
    let rclone: String?
    init(root: URL, rclone: String?) throws { self.root = root; self.rclone = rclone; try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func test(_ name: String, _ body: () throws -> Void) {
        do { try body(); passed += 1; print("PASS \(name)") }
        catch { failed += 1; print("FAIL \(name): \(error)") }
        fflush(stdout)
    }
    func skip(_ name: String, reason: String = "provide an absolute rclone executable as argument 1 or RBN_TEST_RCLONE") {
        skipped += 1; print("SKIP \(name) — \(reason)")
    }
    func folder(_ name: String) throws -> URL {
        let target = root.appendingPathComponent(name); try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true); return target
    }
    func file(_ folder: URL, _ name: String, _ data: Data = Data("rclone browser test\n".utf8)) throws {
        let target = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
    }
    func modified(_ folder: URL, _ name: String, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: folder.appendingPathComponent(name).path)
    }
    func engine(_ name: String, aliases: [String: URL] = [:], useRclone: Bool = true) throws -> RcloneEngine {
        let area = try folder(name)
        let value = try RcloneEngine(stateDirectory: area.appendingPathComponent("state"), defaultRcloneDirectory: area.appendingPathComponent("Tools/rclone"))
        if useRclone, let rclone = rclone {
            let config = area.appendingPathComponent("rclone.conf")
            let text = aliases.keys.sorted().map { "[\($0)]\ntype = alias\nremote = \(aliases[$0]!.path)\n" }.joined(separator: "\n")
            try Data(text.utf8).write(to: config)
            var settings = value.settingsSnapshot(); settings["rclonePath"] = rclone; settings["configPath"] = config.path
            let environment = try value.invoke("saveSettings", arguments: [settings]) as! [String: Any]
            try expect(environment["available"] as? Bool == true, "real rclone could not start: \(environment["error"] ?? "unknown")")
        }
        return value
    }
    func endpoint(_ path: URL, remote: String? = nil) -> [String: Any] { ["remote": remote as Any? ?? NSNull(), "path": remote == nil ? path.path : ""] }
    func request(_ from: URL, _ to: URL, mode: String = "copy", dryRun: Bool = false,
                 selection: [[String: Any]] = [], options: [String: Any] = [:], sourceRemote: String? = nil, destinationRemote: String? = nil) -> [String: Any] {
        ["source": endpoint(from, remote: sourceRemote), "destination": endpoint(to, remote: destinationRemote), "mode": mode,
         "options": EngineTransferOptions.defaults.merging(options) { _, new in new }, "selection": selection, "dryRun": dryRun]
    }
    func submit(_ engine: RcloneEngine, _ request: [String: Any]) throws -> String {
        let job = try engine.invoke("startTransfer", arguments: [request]) as! [String: Any]; return job["id"] as! String
    }
    func job(_ engine: RcloneEngine, _ id: String) throws -> [String: Any] {
        let jobs = try engine.invoke("listJobs", arguments: []) as! [[String: Any]]
        guard let job = jobs.first(where: { $0["id"] as? String == id }) else { throw TestFailure(description: "missing job \(id)") }; return job
    }
    func wait(_ engine: RcloneEngine, _ id: String, seconds: TimeInterval = 35) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let value = try job(engine, id)
            if EngineJob.terminal.contains(value["status"] as? String ?? "") { return value }
            Thread.sleep(forTimeInterval: 0.03)
        }
        throw TestFailure(description: "job timeout: \(try job(engine, id))")
    }
    func completed(_ engine: RcloneEngine, _ request: [String: Any]) throws -> [String: Any] {
        let value = try wait(engine, submit(engine, request))
        try expect(value["status"] as? String == "completed", "job did not complete: \(value["error"] ?? value["status"] ?? "unknown")")
        return value
    }

    func run() {
        test("local browsing and file operations work without rclone") {
            let area = try folder("local-files"), engine = try self.engine("local-engine", useRclone: false)
            defer { engine.shutdown() }
            try file(area, "read me.txt", Data("12345".utf8)); try file(area, "keep.txt", Data("123".utf8))
            let endpoint = endpoint(area)
            _ = try engine.invoke("mkdir", arguments: [endpoint, "資料夾"])
            let entries = try engine.invoke("list", arguments: [endpoint]) as! [[String: Any]]
            try expect(entries.count == 3 && entries.first?["isDir"] as? Bool == true, "local listing or directory ordering")
            _ = try engine.invoke("rename", arguments: [endpoint, "read me.txt", "重命名.txt", false])
            try rejects("rename overwrote an existing file") { _ = try engine.invoke("rename", arguments: [endpoint, "重命名.txt", "keep.txt", false]) }
            let size = try engine.invoke("size", arguments: [endpoint]) as! [String: Any]
            try expect((size["count"] as? NSNumber)?.intValue == 2 && (size["bytes"] as? NSNumber)?.intValue == 8, "local size")
            _ = try engine.invoke("remove", arguments: [endpoint, [["name": "重命名.txt", "isDir": false]]])
            try expect(!FileManager.default.fileExists(atPath: area.appendingPathComponent("重命名.txt").path), "delete failed")
            try expect(FileManager.default.fileExists(atPath: area.appendingPathComponent("keep.txt").path), "delete changed unselected file")
        }

        test("unsafe paths, flags and sync selections are rejected") {
            try rejects("relative local path accepted") { _ = try EngineEndpoint(["remote": NSNull(), "path": "../unsafe"]) }
            try rejects("connection-string flags accepted") { _ = try EngineEndpoint(["remote": ":local,copy_links=true", "path": ""]) }
            try rejects("remote traversal accepted") { _ = try EngineEndpoint(["remote": "drive", "path": "a/../b"]) }
            try rejects("invalid bandwidth accepted") { _ = try EngineTransferOptions(["bandwidth": "1M --delete-excluded"]) }
            try rejects("integer used as boolean") { _ = try EngineTransferOptions(["updateOnly": 1]) }
            let from = try folder("validation-from"), to = try folder("validation-to")
            try rejects("sync accepted selected files") { _ = try EngineTransferRequest(request(from, to, mode: "sync", selection: [["name": "one", "isDir": false]])) }
            let escaped = EngineTransferRequest.escapeFilter(" a[1]*?{b}\\ ")
            try expect(escaped == "[ ]a\\[1\\]\\*\\?\\{b\\}\\\\[ ]", "literal filter escaping")
        }

        test("all comparison modes and transfer controls produce bounded shell-free arguments") {
            let from = try folder("argument-from"), to = try folder("argument-to")
            let compareFlags: Set<String> = ["--checksum", "--ignore-size", "--size-only", "--ignore-times"]
            for (mode, expected) in [("default", [String]()), ("checksum", ["--checksum"]), ("modtime", ["--ignore-size"]),
                                      ("size", ["--size-only"]), ("checksum-only", ["--checksum", "--ignore-size"]), ("none", ["--ignore-times"])] {
                let args = try EngineTransferRequest(request(from, to, options: ["comparison": mode])).arguments()
                try expect(Set(args.filter { compareFlags.contains($0) }) == Set(expected), "comparison flags for \(mode)")
                try expect(Array(args.suffix(3)) == ["--", from.path, to.path], "endpoints were not isolated from option parsing")
            }
            let options: [String: Any] = ["deleteMode": "during", "deleteExcluded": true, "checkFirst": true, "fastList": true,
                                         "oneFileSystem": true, "noUpdateModtime": true, "preserveMetadata": true, "minSize": "1K", "maxSize": "2M",
                                         "minAge": "1h", "maxAge": "2d", "maxDepth": 4, "connectTimeout": "20s", "ioTimeout": "3m",
                                         "lowLevelRetries": 5, "retrySleep": "2s", "modifyWindow": "1s", "extraArgs": ["--buffer-size=4M", "--use-mmap"]]
            let args = try EngineTransferRequest(request(from, to, mode: "sync", options: options)).arguments()
            for flag in ["--delete-during", "--delete-excluded", "--check-first", "--fast-list", "--one-file-system", "--no-update-modtime",
                         "--metadata", "--min-size=1K", "--max-size=2M", "--min-age=1h", "--max-age=2d", "--max-depth=4", "--contimeout=20s",
                         "--timeout=3m", "--low-level-retries=5", "--retries-sleep=2s", "--modify-window=1s", "--buffer-size=4M", "--use-mmap"] {
                try expect(args.contains(flag), "missing enabled transfer control \(flag)")
            }
            for invalid: [String: Any] in [["comparison": "none", "skipExisting": true], ["comparison": "none", "updateOnly": true],
                                           ["comparison": "checksum", "localHashPolicy": "none"], ["minSize": "2M", "maxSize": "1K"],
                                           ["minAge": "3d", "maxAge": "1h"], ["connectTimeout": "3s --rc"], ["maxDepth": -2]] {
                try rejects("invalid transfer option combination accepted: \(invalid)") { _ = try EngineTransferOptions(invalid) }
            }
            try rejects("sync silently ignored no-traverse") { _ = try EngineTransferRequest(request(from, to, mode: "sync", options: ["noTraverse": true])) }
            try rejects("copy accepted destination exclusion deletion") { _ = try EngineTransferRequest(request(from, to, options: ["deleteExcluded": true])) }
            try rejects("move could remove a skipped newer source") { _ = try EngineTransferRequest(request(from, to, mode: "move", options: ["updateOnly": true])) }
            try rejects("unsupported MB SizeSuffix accepted") { _ = try EngineTransferOptions(["minSize": "10MB"]) }
            try rejects("bare KiB size comparison was treated as bytes") { _ = try EngineTransferOptions(["minSize": "2", "maxSize": "3B"]) }
            for argument in ["--dry-run=false", "--rc", "--stats=0", "--use-json-log=false", "--log-file=/tmp/leak", "--filter=+ **",
                             "--config=/tmp/other", "--password-command=anything", "--metadata-mapper=anything", "--max-delete=-1", "--ignore-errors",
                             "--backup-dir=/tmp/outside", "--sftp-pass=secret", "--dump=headers", "--buffer-size=1M --rc", "-P", "sync", "/tmp/other"] {
                try rejects("extra argv escaped safeguards: \(argument)") { _ = try EngineTransferOptions(["extraArgs": [argument]]) }
            }
        }

        test("system language resolves Chinese variants and Japanese consistently with bootstrap") {
            for language in ["zh", "zh-TW", "zh-Hant-TW", "zh-Hans-CN", "zh_CN", "ZH_hk"] {
                try expect(RBNLanguageResolver.resolve("system", preferredLanguages: [language]) == "zh-TW", "Chinese system language \(language)")
            }
            for language in ["ja", "ja-JP", "ja_JP"] {
                try expect(RBNLanguageResolver.resolve("system", preferredLanguages: [language]) == "ja", "Japanese system language \(language)")
            }
            for languages in [[String](), ["fr-FR", "ja"], ["en-GB"], ["ko-KR"]] {
                try expect(RBNLanguageResolver.resolve("system", preferredLanguages: languages) == "en", "unsupported primary language must use English")
            }
            for language in ["zh-TW", "en", "ja"] {
                try expect(RBNLanguageResolver.resolve(language, preferredLanguages: ["fr-FR"]) == language, "explicit language was overridden")
            }
            let engine = try self.engine("system-language", useRclone: false); defer { engine.shutdown() }
            let settings = engine.settingsSnapshot()
            try expect(settings["language"] as? String == "system" && settings["theme"] as? String == "purple-dark" && settings["maxConcurrentJobs"] as? Int == 0, "new installation defaults")
            let bootstrap = try engine.invoke("bootstrap", arguments: []) as! [String: Any]
            try expect(bootstrap["resolvedLanguage"] as? String == RBNLanguageResolver.resolve("system"), "bootstrap and native resolver disagree")
            _ = try engine.invoke("saveSettings", arguments: [["language": "ja"]])
            let japanese = try engine.invoke("bootstrap", arguments: []) as! [String: Any]
            try expect(japanese["resolvedLanguage"] as? String == "ja", "explicit language did not update bootstrap")
        }

        test("0.4 migration removes the old default queue limit once and preserves explicit choices") {
            for (index, limit, schema, expected) in [(0, 2, 0, 0), (1, 1, 0, 1), (2, 4, 0, 4), (3, 2, 4, 2)] {
                let area = try folder("migrate-v04/\(index)"), state = try folder("migrate-v04/\(index)/state")
                var previous: [String: Any] = ["language": "en", "theme": "blue-light", "maxConcurrentJobs": limit,
                                                "skippedRcloneVersion": "v99.1.0", "defaultTransferOptions": ["connectTimeout": "1m", "ioTimeout": "5m", "comparison": "size"],
                                                "defaultRcloneOptions": ["--tpslimit=2.5", "--tpslimit-burst=3", "--disable-http2", "--buffer-size=2M"]]
                if schema > 0 {
                    previous["settingsSchemaVersion"] = schema
                    previous["defaultRcloneOptions"] = ["--buffer-size=2M"]
                }
                try EngineStorage.atomicJSON(previous, to: state.appendingPathComponent("settings.json"))
                let engine = try RcloneEngine(stateDirectory: state, defaultRcloneDirectory: area.appendingPathComponent("rclone"))
                let settings = engine.settingsSnapshot()
                try expect(settings["settingsSchemaVersion"] as? Int == 4 && settings["maxConcurrentJobs"] as? Int == expected, "wrong limit migration")
                try expect(settings["language"] as? String == "en" && settings["theme"] as? String == "blue-light" && settings["skippedRcloneVersion"] as? String == "v99.1.0", "migration changed independent preferences")
                if schema == 0 {
                    let network = settings["networkOptions"] as! [String: Any]
                    try expect(network["tpsLimit"] as? Double == 2.5 && network["tpsBurst"] as? Int == 3 && network["disableHTTP2"] as? Bool == true, "old network flags were lost")
                    try expect(settings["defaultRcloneOptions"] as? [String] == ["--buffer-size=2M"], "network flags were duplicated in global extras")
                    let options = settings["defaultTransferOptions"] as! [String: Any]
                    try expect(options["connectTimeout"] as? String == "" && options["ioTimeout"] as? String == "" && options["comparison"] as? String == "size", "old default timeouts did not inherit unchanged common values")
                }
                _ = try engine.invoke("saveSettings", arguments: [["maxConcurrentJobs": 2]])
                engine.shutdown()
                let reopened = try RcloneEngine(stateDirectory: state, defaultRcloneDirectory: area.appendingPathComponent("rclone"))
                try expect(reopened.settingsSnapshot()["maxConcurrentJobs"] as? Int == 2, "explicit 0.4 choice of 2 migrated again")
                reopened.shutdown()
            }
        }

        test("remembered workspace round-trips every option atomically without selecting files or starting jobs") {
            let area = try folder("workspace-v04"), missing = area.appendingPathComponent("not-created")
            let engine = try self.engine("workspace-v04", useRclone: false)
            let options = try EngineTransferOptions(["transfers": 7, "checkers": 9, "bandwidth": "2M", "comparison": "default", "skipExisting": true,
                                                      "createEmptyDirs": false, "exclude": ["*.tmp", "folder/**"], "include": ["*.bin"], "retries": 4,
                                                      "maxDelete": -1, "preserveMetadata": true, "driveSharedWithMe": true, "deleteMode": "during",
                                                      "deleteExcluded": true, "ignoreChecksum": true, "modifyWindow": "2s", "checkFirst": true, "fastList": true,
                                                      "oneFileSystem": true, "noUpdateModtime": true, "minSize": "1B", "maxSize": "10M", "minAge": "1h", "maxAge": "3d",
                                                      "maxDepth": 7, "connectTimeout": "11s", "ioTimeout": "2m", "lowLevelRetries": 8,
                                                      "retrySleep": "2s", "extraArgs": ["--buffer-size=1M"], "localHashPolicy": "none"]).json
            let workspace: [String: Any] = ["left": endpoint(missing), "right": ["remote": "NAS-not-configured", "path": "backup/写真"],
                                             "direction": "rl", "mode": "sync", "options": options]
            let oldLocations: [String: Any] = ["left": endpoint(area)]
            _ = try engine.invoke("saveSettings", arguments: [["initialLocations": oldLocations]])
            let results = TestConcurrentResults(), group = DispatchGroup()
            for patch: [String: Any] in [["savedWorkspace": workspace], ["language": "ja"], ["theme": "blue-dark"], ["showHiddenFiles": false]] {
                group.enter()
                DispatchQueue.global().async { defer { group.leave() }; results.capture { _ = try engine.invoke("saveSettings", arguments: [patch]) } }
            }
            try expect(group.wait(timeout: .now() + 10) == .success && results.errors.isEmpty, "workspace/appearance patches raced")
            let saved = engine.settingsSnapshot()
            try expect(try EngineJSON.data(saved["savedWorkspace"]!) == EngineJSON.data(workspace), "workspace did not keep the full option snapshot")
            try expect(saved["language"] as? String == "ja" && saved["theme"] as? String == "blue-dark" && saved["showHiddenFiles"] as? Bool == false, "workspace overwrote appearance")
            for invalidPatch: [String: Any] in [["direction": "backwards"], ["left": ["remote": NSNull(), "path": "relative"]],
                                                ["mode": "delete"], ["selection": [["name": "stale", "isDir": false]]], ["options": ["comparison": "checksum", "localHashPolicy": "none"]]] {
                let invalid = workspace.merging(invalidPatch) { _, new in new }
                try rejects("invalid workspace accepted") { _ = try engine.invoke("saveSettings", arguments: [["savedWorkspace": invalid]]) }
            }
            try rejects("partial workspace snapshot accepted") { _ = try engine.invoke("saveSettings", arguments: [["savedWorkspace": ["direction": "lr"]]]) }
            try expect(try EngineJSON.data(engine.settingsSnapshot()["savedWorkspace"]!) == EngineJSON.data(workspace), "invalid workspace changed previous snapshot")
            engine.shutdown()
            let reopened = try RcloneEngine(stateDirectory: area.appendingPathComponent("state"), defaultRcloneDirectory: area.appendingPathComponent("Tools/rclone"))
            defer { reopened.shutdown() }
            let bootstrap = try reopened.invoke("bootstrap", arguments: []) as! [String: Any]
            try expect(try EngineJSON.data((bootstrap["settings"] as! [String: Any])["savedWorkspace"]!) == EngineJSON.data(workspace), "workspace changed after restart")
            try expect((bootstrap["jobs"] as! [[String: Any]]).isEmpty && !reopened.hasActiveJobs, "remembering a workspace started a transfer")
            try expect(!FileManager.default.fileExists(atPath: missing.path), "workspace validation created or browsed a missing directory")
            _ = try reopened.invoke("saveSettings", arguments: [["savedWorkspace": NSNull(), "initialLocations": [String: Any]()]])
            try expect(reopened.settingsSnapshot()["savedWorkspace"] is NSNull && (reopened.settingsSnapshot()["initialLocations"] as! [String: Any]).isEmpty, "forget environment did not clear both new and legacy locations")
        }

        test("location discovery exposes available folders and mounted-volume metadata without creating folders") {
            let home = try folder("location-catalog/home"), downloads = try folder("location-catalog/downloads"), mount = try folder("location-catalog/Volumes/NAS")
            let missing = root.appendingPathComponent("location-catalog/missing"), volumesRoot = mount.deletingLastPathComponent()
            let nonFolder = home.appendingPathComponent("not-a-folder")
            try file(home, nonFolder.lastPathComponent)
            let locations = EngineLocationCatalog.makeLocations(home: home, folders: [("downloads", downloads), ("documents", missing), ("music", nonFolder), ("desktop", downloads)],
                                                                 volumes: [.init(url: mount, name: "家の NAS", isLocal: false, isRemovable: false)], volumesRoot: volumesRoot)
            try expect(locations.count == 4 && locations[0]["kind"] as? String == "home", "available locations were duplicated or missing")
            try expect(locations.contains { $0["kind"] as? String == "volumes" && $0["path"] as? String == volumesRoot.path }, "Volumes entry absent")
            try expect(locations.contains { $0["name"] as? String == "家の NAS" && $0["group"] as? String == "network" && $0["isRemovable"] as? Bool == false }, "network volume classification or name changed")
            try expect(!FileManager.default.fileExists(atPath: missing.path), "discovering a standard folder created it")
            for type in ["smb", "sftp", "ftp"] { try expect(EngineLocationCatalog.remoteGroup(type: type) == "network", "network protocol classification") }
            for type in ["drive", "dropbox", "onedrive"] { try expect(EngineLocationCatalog.remoteGroup(type: type) == "cloud", "known cloud provider classification") }
            for type in ["webdav", "http", "alias", "crypt", "union", "s3", "unknown"] { try expect(EngineLocationCatalog.remoteGroup(type: type) == "other", "ambiguous hosting type was guessed") }
        }

        test("rclone network settings validate real flags and preserve independent nested patches") {
            let engine = try self.engine("network-validation", useRclone: false); defer { engine.shutdown() }
            _ = try engine.invoke("saveSettings", arguments: [["networkOptions": ["bindMode": "ipv6", "connectTimeout": "9s", "tpsLimit": 2.5, "userAgent": "RBN/0.4 \"quoted\""]]])
            _ = try engine.invoke("saveSettings", arguments: [["networkOptions": ["tpsBurst": 3, "disableHTTP2": true]]])
            let options = try EngineNetworkOptions(engine.settingsSnapshot()["networkOptions"])
            for argument in ["--bind=::0", "--contimeout=9s", "--timeout=5m", "--tpslimit=2.5", "--tpslimit-burst=3", "--disable-http2=true", "--user-agent=RBN/0.4 \"quoted\""] {
                try expect(options.arguments.contains(argument), "missing network argv \(argument)")
            }
            try expect(try EngineNetworkOptions(["bindMode": "ipv4"]).arguments.contains("--bind=0.0.0.0"), "IPv4 did not use rclone bind")
            for address in ["127.0.0.1", "::1", "2001:db8::1234"] {
                try expect(try EngineNetworkOptions(["bindMode": "address", "bindAddress": address]).arguments.contains("--bind=\(address)"), "literal address changed")
            }
            for invalid: [String: Any] in [["bindMode": "address", "bindAddress": "en0"], ["bindMode": "address", "bindAddress": "127.0.0.1:8080"],
                                           ["bindMode": "address", "bindAddress": "localhost"], ["bindMode": "address", "bindAddress": ""], ["bindMode": "other"],
                                           ["dns": "8.8.8.8"], ["tpsLimit": true], ["tpsLimit": "3"], ["tpsLimit": -1], ["tpsBurst": 1.5],
                                           ["tpsBurst": 0], ["userAgent": "bad\r\nAuthorization: secret"], ["disableHTTP2": 1], ["connectTimeout": "1s --rc"]] {
                try rejects("invalid network setting accepted") { _ = try EngineNetworkOptions(invalid) }
            }
            for argument in ["--tpslimit=2", "--tpslimit-burst=3", "--disable-http2"] {
                try rejects("structured global flag duplicated in extras") { _ = try engine.invoke("saveSettings", arguments: [["defaultRcloneOptions": [argument]]]) }
                _ = try EngineTransferOptions(["extraArgs": [argument]]) // per-task override remains available
            }
        }

        test("settings migrate old themes and preserve language, path, skip and both pane widths across patches") {
            let engine = try self.engine("settings-patches", useRclone: false); defer { engine.shutdown() }
            try expect(engine.settingsSnapshot()["theme"] as? String == "purple-dark", "new theme default")
            _ = try engine.invoke("saveSettings", arguments: [["theme": "dark"]])
            try expect(engine.settingsSnapshot()["theme"] as? String == "blue-dark", "legacy dark did not migrate")
            _ = try engine.invoke("saveSettings", arguments: [["theme": "system"]])
            try expect(engine.settingsSnapshot()["theme"] as? String == "purple-dark", "legacy system did not migrate")
            _ = try engine.invoke("saveSettings", arguments: [["language": "ja", "skippedRcloneVersion": "v99.1.0"]])
            let tools = try folder("settings-patches/chosen-tools")
            _ = try engine.invoke("saveSettings", arguments: [["rcloneDirectory": tools.path, "rclonePath": ""]])
            _ = try engine.invoke("saveSettings", arguments: [["paneColumnWidths": ["left": ["name": 280, "size": 88, "modified": 155]]]])
            _ = try engine.invoke("saveSettings", arguments: [["paneColumnWidths": ["right": ["name": 320, "size": 92, "modified": 160]]]])
            _ = try engine.invoke("saveSettings", arguments: [["paneColumnWidths": ["left": ["size": 104]]]])
            _ = try engine.invoke("saveSettings", arguments: [["defaultTransferOptions": ["comparison": "size", "checkFirst": true]]])
            _ = try engine.invoke("saveSettings", arguments: [["defaultTransferOptions": ["transfers": 6]]])
            let snapshot = engine.settingsSnapshot(), widths = snapshot["paneColumnWidths"] as! [String: [String: Any]]
            try expect(snapshot["language"] as? String == "ja" && snapshot["skippedRcloneVersion"] as? String == "v99.1.0", "unrelated preference was reset")
            try expect(snapshot["rclonePath"] as? String == tools.appendingPathComponent("rclone").path, "selected folder did not identify one executable")
            try rejects("missing selected engine silently fell back to system PATH") { _ = try engine.resolvedRclonePath() }
            try expect(widths["left"]?["name"] as? Int == 280 && widths["left"]?["size"] as? Int == 104 && widths["right"]?["name"] as? Int == 320, "pane width patch discarded another column or side")
            let defaults = snapshot["defaultTransferOptions"] as! [String: Any]
            try expect(defaults["comparison"] as? String == "size" && defaults["checkFirst"] as? Bool == true && defaults["transfers"] as? Int == 6, "transfer defaults patch was not merged")
            let startLocations: [String: Any] = ["left": endpoint(tools), "right": ["remote": "not-connected-yet", "path": ""]]
            _ = try engine.invoke("saveSettings", arguments: [["initialLocations": startLocations]])
            _ = try engine.invoke("saveSettings", arguments: [["theme": "blue-light"]])
            let persistedLocations = engine.settingsSnapshot()["initialLocations"] as! [String: Any]
            try expect(try EngineJSON.data(persistedLocations) == EngineJSON.data(startLocations), "starting locations changed across an unrelated settings patch")
            let savedSettings = try EngineJSON.object(Data(contentsOf: engine.stateDirectory.appendingPathComponent("settings.json"))) as! [String: Any]
            try expect(try EngineJSON.data(savedSettings["initialLocations"]!) == EngineJSON.data(startLocations), "starting locations did not round-trip through disk")
            for invalid: [String: Any] in [["left": ["remote": NSNull(), "path": ""]], ["left": ["remote": NSNull(), "path": "relative"]],
                                           ["right": ["remote": "drive", "path": "a/../b"]], ["right": ["remote": "drive", "path": "bad\u{0000}name"]],
                                           ["other": ["remote": NSNull(), "path": tools.path]]] {
                try rejects("invalid startup location accepted") { _ = try engine.invoke("saveSettings", arguments: [["initialLocations": invalid]]) }
            }
            try expect(try EngineJSON.data(engine.settingsSnapshot()["initialLocations"]!) == EngineJSON.data(startLocations), "invalid startup location changed previous choices")
            _ = try engine.invoke("saveSettings", arguments: [["initialLocations": [String: Any]()]])
            try expect((engine.settingsSnapshot()["initialLocations"] as? [String: Any])?.isEmpty == true, "empty startup locations did not clear both panes")
            var stale = engine.settingsSnapshot(); stale["language"] = "en"
            _ = try engine.invoke("saveSettings", arguments: [["theme": "purple-dark"]])
            try rejects("stale full settings snapshot overwrote newer values") { _ = try engine.invoke("saveSettings", arguments: [stale]) }
            for invalid: [String: Any] in [["paneColumnWidths": ["left": ["size": 2]]], ["maxConcurrentJobs": -1], ["maxConcurrentJobs": 129], ["theme": "pink"],
                                           ["httpProxy": "http://user:secret@127.0.0.1:1234"], ["defaultRcloneOptions": ["--rc"]]] {
                try rejects("invalid settings accepted") { _ = try engine.invoke("saveSettings", arguments: [invalid]) }
            }
        }

        test("concurrent settings patches are serialized and failed persistence never publishes a partial change") {
            let engine = try self.engine("settings-concurrent", useRclone: false); defer { engine.shutdown() }
            let results = TestConcurrentResults(), group = DispatchGroup()
            let patches: [[String: Any]] = [["language": "ja"], ["theme": "purple-dark"], ["skippedRcloneVersion": "v99.9.0"],
                                          ["paneColumnWidths": ["left": ["name": 350, "size": 85, "modified": 170]]],
                                          ["paneColumnWidths": ["right": ["name": 240, "size": 90, "modified": 190]]], ["showHiddenFiles": false]]
            for patch in patches {
                group.enter()
                DispatchQueue.global().async { defer { group.leave() }; results.capture { _ = try engine.invoke("saveSettings", arguments: [patch]) } }
            }
            try expect(group.wait(timeout: .now() + 10) == .success, "concurrent settings deadlocked")
            try expect(results.errors.isEmpty, "concurrent settings errors: \(results.errors)")
            let snapshot = engine.settingsSnapshot()
            try expect(snapshot["language"] as? String == "ja" && snapshot["theme"] as? String == "purple-dark" && snapshot["skippedRcloneVersion"] as? String == "v99.9.0", "racing patches lost a value")
            try expect((snapshot["paneColumnWidths"] as? [String: Any])?.count == 2 && snapshot["showHiddenFiles"] as? Bool == false, "concurrent nested or bool patch lost")
            try expect(snapshot["settingsRevision"] as? Int == patches.count, "settings revisions not monotonic")
            let settingsPath = engine.stateDirectory.appendingPathComponent("settings.json")
            let savedBytes = try Data(contentsOf: settingsPath)
            try expect(try EngineJSON.data(EngineJSON.object(savedBytes)) == EngineJSON.data(snapshot), "disk and memory settings differ")
            try FileManager.default.removeItem(at: settingsPath)
            try FileManager.default.createDirectory(at: settingsPath, withIntermediateDirectories: false)
            try rejects("settings accepted failed atomic replacement") { _ = try engine.invoke("saveSettings", arguments: [["language": "en"]]) }
            try expect(try EngineJSON.data(engine.settingsSnapshot()) == EngineJSON.data(snapshot), "failed persistence changed in-memory settings")
            try FileManager.default.removeItem(at: settingsPath)
            try savedBytes.write(to: settingsPath)
        }

        test("same, ancestor and symlink-overlapping local endpoints are rejected") {
            let from = try folder("overlap/source"), other = try folder("overlap/other")
            let link = other.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: from)
            for destination in [from, from.appendingPathComponent("child"), from.deletingLastPathComponent(), link.appendingPathComponent("new")] {
                try rejects("unsafe overlap accepted: \(destination.path)") { try EngineStorage.validatePair(EngineTransferRequest(request(from, destination))) }
            }
            try EngineStorage.validatePair(EngineTransferRequest(request(from, other.appendingPathComponent("safe-new"))))
        }

        test("JSON statistics keep unknown ETA and growing scan totals") {
            let first: [String: Any] = ["bytes": 1024, "totalBytes": 2048, "speed": 512, "eta": NSNull(), "totalTransfers": 2,
                                       "transferring": [["name": "file.bin", "size": 2048, "bytes": 1024, "speed": 512, "speedAvg": 500, "eta": NSNull()]]]
            let a = EngineStatistics.parse(first)
            try expect(a["eta"] is NSNull, "unknown ETA became zero")
            let b = EngineStatistics.parse(["bytes": 1536, "totalBytes": 8192, "totalTransfers": 7, "eta": 13, "speed": -1], previous: a)
            try expect(EngineJSON.number(b["totalBytes"]) == 8192 && EngineJSON.number(b["totalTransfers"]) == 7, "scan totals did not grow")
            try expect(EngineJSON.number(b["speed"]) == 0 && EngineJSON.number(b["eta"]) == 13, "invalid speed or valid ETA")
            let file = (a["transferring"] as! [[String: Any]])[0]
            try expect(EngineJSON.number(file["percentage"]) == 50 && file["eta"] is NSNull, "per-file progress")
        }

        test("saved tasks import atomically with new identities; restart never starts jobs") {
            let from = try folder("task-from"), to = try folder("task-to")
            let area = try folder("task-engine")
            let engine = try self.engine("task-engine", useRclone: false)
            let task = try engine.invoke("saveTask", arguments: ["每日備份", request(from, to)]) as! [String: Any]
            let exported = try engine.invoke("exportTasks", arguments: []) as! [String: Any]
            let imported = try engine.invoke("importTasks", arguments: [exported]) as! [[String: Any]]
            try expect(imported.count == 2 && Set(imported.compactMap { $0["id"] as? String }).count == 2, "import reused task identity")
            try rejects("partial invalid import accepted") { _ = try engine.invoke("importTasks", arguments: [[task, ["name": "bad"]]]) }
            try expect((try engine.invoke("listTasks", arguments: []) as! [[String: Any]]).count == 2, "invalid import partially changed tasks")
            let saved = EngineJob(request: try EngineTransferRequest(request(from, to)), command: "test fixture")
            saved.status = "running"
            engine.shutdown()
            try EngineStorage.atomicJSON([saved.json], to: area.appendingPathComponent("state/jobs.json"))
            let restarted = try RcloneEngine(stateDirectory: area.appendingPathComponent("state"), defaultRcloneDirectory: area.appendingPathComponent("Tools/rclone"))
            defer { restarted.shutdown() }
            try expect((try restarted.invoke("listTasks", arguments: []) as! [[String: Any]]).count == 2, "tasks lost on restart")
            let history = try restarted.invoke("listJobs", arguments: []) as! [[String: Any]]
            try expect(history.count == 1 && history[0]["status"] as? String == "interrupted" && !restarted.hasActiveJobs, "restart resumed pending work")
        }

        test("editing saved tasks preserves identity and the full request including direction and selection") {
            let from = try folder("task-snapshot/from"), to = try folder("task-snapshot/to")
            let engine = try self.engine("task-snapshot-engine", useRclone: false); defer { engine.shutdown() }
            var original = request(from, to, selection: [["name": "写真 [1].bin", "isDir": false]],
                                   options: ["comparison": "size", "transfers": 6, "checkers": 11, "skipExisting": true, "createEmptyDirs": false,
                                             "exclude": ["*.tmp"], "include": ["*.bin"], "minSize": "2B", "maxSize": "2M", "minAge": "1h", "maxAge": "7d",
                                             "preserveMetadata": true, "oneFileSystem": true, "connectTimeout": "11s", "ioTimeout": "3m",
                                             "maxDepth": 5, "localHashPolicy": "none", "extraArgs": ["--buffer-size=1M"]])
            original["direction"] = "rl"; original["label"] = "task metadata"
            let task = try engine.invoke("saveTask", arguments: ["完整設定", original]) as! [String: Any]
            try expect(try EngineJSON.data(task["request"]!) == EngineJSON.data(original), "save dropped request metadata or options")
            _ = try engine.invoke("saveSettings", arguments: [["defaultTransferOptions": ["comparison": "checksum", "transfers": 1]]])
            var edited = task["request"] as! [String: Any]
            var options = edited["options"] as! [String: Any]; options["bandwidth"] = "3M"; edited["options"] = options
            let updated = try engine.invoke("saveTask", arguments: ["修改後", edited, task["id"]!]) as! [String: Any]
            try expect(updated["id"] as? String == task["id"] as? String && updated["createdAt"] as? String == task["createdAt"] as? String, "task editing created a new identity or creation date")
            try expect(try EngineJSON.data(updated["request"]!) == EngineJSON.data(edited), "editing inherited unrelated defaults or dropped a field")
            let exported = try engine.invoke("exportTasks", arguments: []) as! [String: Any]
            let imported = try engine.invoke("importTasks", arguments: [exported]) as! [[String: Any]]
            try expect(imported.count == 2 && Set(imported.compactMap { $0["id"] as? String }).count == 2, "task import did not create a separate identity")
            for saved in imported { try expect(try EngineJSON.data(saved["request"]!) == EngineJSON.data(edited), "export/import lost the full request") }
            let args = try EngineTransferRequest(edited).arguments()
            try expect(!args.contains("rl") && Array(args.suffix(3)) == ["--", from.path, to.path], "arrangement metadata changed actual transfer endpoints")
        }

        test("legacy move-update tasks remain visible with an error and retain their original choices after restart") {
            let from = try folder("legacy-task/source"), to = try folder("legacy-task/destination")
            let engine = try self.engine("legacy-task-engine", useRclone: false)
            let value: [String: Any] = ["id": UUID().uuidString.lowercased(), "name": "舊版移動設定", "createdAt": EngineJSON.now(), "updatedAt": EngineJSON.now(),
                                        "request": request(from, to, mode: "move", options: ["updateOnly": true])]
            let imported = try engine.invoke("importTasks", arguments: [[value]]) as! [[String: Any]]
            try expect(imported.count == 1 && imported[0]["validationError"] is String, "legacy unsafe task disappeared or lacked an explanation")
            let importedRequest = imported[0]["request"] as! [String: Any], importedOptions = importedRequest["options"] as! [String: Any]
            try expect(importedRequest["mode"] as? String == "move" && importedOptions["updateOnly"] as? Bool == true, "legacy task options changed silently")
            engine.shutdown()
            let area = root.appendingPathComponent("legacy-task-engine")
            let reopened = try RcloneEngine(stateDirectory: area.appendingPathComponent("state"), defaultRcloneDirectory: area.appendingPathComponent("Tools/rclone"))
            defer { reopened.shutdown() }
            let tasks = try reopened.invoke("listTasks", arguments: []) as! [[String: Any]]
            try expect(tasks.count == 1 && tasks[0]["validationError"] is String, "restart discarded a task needing correction")
            var correctedRequest = tasks[0]["request"] as! [String: Any]
            var correctedOptions = correctedRequest["options"] as! [String: Any]; correctedOptions["updateOnly"] = false
            correctedRequest["options"] = correctedOptions
            let corrected = try reopened.invoke("saveTask", arguments: ["修正後", correctedRequest, tasks[0]["id"]!]) as! [String: Any]
            try expect(corrected["id"] as? String == tasks[0]["id"] as? String && corrected["createdAt"] as? String == tasks[0]["createdAt"] as? String && corrected["validationError"] == nil, "invalid task could not be repaired in place")
        }

        test("maintenance excludes rclone calls but permits local browsing") {
            let folder = try self.folder("maintenance-local")
            let engine = try self.engine("maintenance-engine", useRclone: false); defer { engine.shutdown() }
            if let rclone = rclone {
                try rejects("updater committed without its maintenance lock") { try engine.commitRcloneUpdate(path: rclone) }
            }
            try engine.setMaintenance(true)
            try rejects("double maintenance lock accepted") { try engine.setMaintenance(true) }
            try rejects("rclone environment process admitted in maintenance") { _ = try engine.invoke("environment", arguments: []) }
            _ = try engine.invoke("list", arguments: [endpoint(folder)])
            if let rclone = rclone {
                var options = engine.settingsSnapshot(); options["skippedRcloneVersion"] = "v1.75.2"
                _ = try engine.invoke("saveSettings", arguments: [options])
                try engine.commitRcloneUpdate(path: rclone)
                try expect(engine.settingsSnapshot()["rclonePath"] as? String == rclone, "update path not committed")
                try expect(try engine.resolvedRclonePath() == rclone, "updated executable not resolved")
            }
            try engine.setMaintenance(false)
            let settings = engine.settingsSnapshot()
            try expect(settings["autoCheckUpdates"] as? Bool == true && settings["skippedRcloneVersion"] as? String == "", "update preferences defaults")
        }

        guard let rclone = rclone else {
            for name in ["local and alias remote endpoint matrix", "real rclone dry run and literal selection", "selection/include intersection", "sync semantics", "move and alias directory operations", "stale selection guard", "progress/queue/cancel/maintenance", "password and inherited environment isolation",
                         "real comparison decisions", "NAS local hash policy", "NAS kernel read instrumentation", "sync deletion modes", "age/size/depth filters", "skip rules and modification times",
                         "settings wait for reads", "updater/settings serialization", "proxy/global options/default transfer settings",
                         "network loopback fixture", "unlimited queue and history retention", "saved task dry run snapshot", "confirmed request default snapshot"] { skip(name) }
            return
        }
        print("Integration executable: \(rclone)")

        test("real rclone networking honors loopback binding, user agent, TPS pacing and per-task overrides") {
            let server = try TestHTTPBackend(); defer { server.stop() }
            let area = try folder("network-real"), target = try folder("network-real/destination")
            let config = area.appendingPathComponent("rclone.conf")
            try Data("[httpfixture]\ntype = http\nurl = \(server.url)\n".utf8).write(to: config)
            let engine = try self.engine("network-real-engine"); defer { engine.shutdown() }
            let userAgent = "RBN/0.4 fixture \"literal\""
            _ = try engine.invoke("saveSettings", arguments: [["configPath": config.path, "proxyMode": "manual", "httpProxy": "", "httpsProxy": "", "noProxy": "127.0.0.1",
                                                              "networkOptions": ["bindMode": "address", "bindAddress": "127.0.0.1", "connectTimeout": "2s", "ioTimeout": "3s",
                                                                                   "tpsLimit": 2.0, "tpsBurst": 1, "userAgent": userAgent, "disableHTTP2": true]]])
            let remote: [String: Any] = ["remote": "httpfixture", "path": ""]
            let entries = try engine.invoke("list", arguments: [remote]) as! [[String: Any]]
            try expect(entries.count == 3 && Set(entries.compactMap { $0["name"] as? String }) == Set(["one.bin", "two.bin", "three.bin"]), "real HTTP listing failed")
            let recorded = server.requests
            try expect(recorded.count >= 4 && recorded.allSatisfy { $0.userAgent == userAgent && $0.peer == "127.0.0.1" }, "rclone lost the literal User-Agent or source bind")
            try expect(recorded.last!.time - recorded.first!.time >= 0.9, "TPS pacing was not applied to real HTTP requests")
            let context = try engine.auxiliaryContext()
            try expect(context.arguments.contains("--contimeout=2s") && context.arguments.contains("--timeout=3s") && context.arguments.contains("--disable-http2=true"), "tools do not share common rclone network options")
            var transfer = request(area, target, selection: [["name": "one.bin", "isDir": false]],
                                   options: ["connectTimeout": "7s", "ioTimeout": "", "extraArgs": ["--tpslimit=0", "--disable-http2=false"]])
            transfer["source"] = remote
            let copied = try completed(engine, transfer)
            try expect(try String(contentsOf: target.appendingPathComponent("one.bin"), encoding: .utf8) == "sample", "real HTTP transfer contents")
            let command = copied["command"] as! String
            try expect(command.contains("--contimeout=7s") && !command.contains("--contimeout=2s") && command.contains("--timeout=3s"), "per-task timeout inheritance/override")
            try expect(command.contains("--tpslimit=0") && !command.contains("--tpslimit=2.0") && command.contains("--disable-http2=false") && !command.contains("--disable-http2=true"), "per-task network extra did not replace the common flag")
        }

        test("unlimited scheduling is immediate and 200 ended jobs never block or evict active jobs or saved tasks") {
            let from = try folder("history-limit/source"), area = try folder("history-limit-engine")
            let state = try folder("history-limit-engine/state"), destinations = try (0..<3).map { try folder("history-limit/target-\($0)") }
            try file(from, "large.bin", Data(repeating: 0x6a, count: 4 * 1024 * 1024))
            // Keep these jobs active while checking queue and history behavior;
            // APFS clones can finish immediately despite the bandwidth limit.
            let activeOptions: [String: Any] = ["bandwidth": "1K", "extraArgs": ["--local-no-clone"]]
            let savedRequest = try EngineTransferRequest(request(from, destinations[0], options: activeOptions))
            let task = EngineTask(id: UUID().uuidString.lowercased(), name: "不受歷史上限影響", request: savedRequest,
                                  createdAt: "2023-01-01T00:00:00Z", updatedAt: "2023-01-01T00:00:00Z")
            let old = (0..<202).map { index -> EngineJob in
                let job = EngineJob(request: savedRequest, command: "history fixture")
                job.status = "completed"; job.endedAt = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(1600000000 + index)))
                return job
            }
            try EngineStorage.atomicJSON(old.map(\.json), to: state.appendingPathComponent("jobs.json"))
            try EngineStorage.atomicJSON([task.json], to: state.appendingPathComponent("tasks.json"))
            let engine = try RcloneEngine(stateDirectory: state, defaultRcloneDirectory: area.appendingPathComponent("rclone"))
            defer { engine.shutdown() }
            _ = try engine.invoke("saveSettings", arguments: [["rclonePath": rclone, "maxConcurrentJobs": 1]])
            let retained = try engine.invoke("listJobs", arguments: []) as! [[String: Any]]
            try expect(retained.count == 200 && !retained.contains { $0["id"] as? String == old[0].id || $0["id"] as? String == old[1].id }, "wrong ended-history retention")
            let ids = try destinations.map { try submit(engine, request(from, $0, options: activeOptions)) }
            let pending = try engine.invoke("listJobs", arguments: []) as! [[String: Any]]
            try expect(pending.count == 203 && pending.filter { $0["status"] as? String == "queued" }.count == 2, "history cap blocked or evicted pending jobs")
            _ = try engine.invoke("saveSettings", arguments: [["maxConcurrentJobs": 0]])
            for id in ids { try expect(try job(engine, id)["status"] as? String == "running", "unlimited setting did not immediately launch every queued job") }
            let tasks = try engine.invoke("listTasks", arguments: []) as! [[String: Any]]
            try expect(tasks.count == 1 && tasks[0]["id"] as? String == task.id, "history retention changed saved tasks")
            engine.shutdown()
            let finalHistory = try EngineJSON.object(Data(contentsOf: state.appendingPathComponent("jobs.json"))) as! [[String: Any]]
            try expect(finalHistory.count == 200 && Set(ids).isSubset(of: Set(finalHistory.compactMap { $0["id"] as? String })), "newly ended jobs were not retained")
        }

        test("running a saved task as a dry run preserves the saved request and its direction") {
            let from = try folder("task-dry-run/source"), to = try folder("task-dry-run/destination")
            try file(from, "keep.bin")
            let engine = try self.engine("task-dry-run-engine", aliases: ["source": from]); defer { engine.shutdown() }
            var value = request(from, to, selection: [["name": "keep.bin", "isDir": false]], options: ["comparison": "size", "localHashPolicy": "none"], sourceRemote: "source")
            value["direction"] = "rl"
            let task = try engine.invoke("saveTask", arguments: ["預演不改作業", value]) as! [String: Any]
            var trial = task["request"] as! [String: Any]; trial["dryRun"] = true
            let result = try completed(engine, trial)
            try expect((result["request"] as! [String: Any])["direction"] as? String == "rl" && (result["command"] as! String).contains("--dry-run"), "dry-run job lost task metadata")
            try expect(try FileManager.default.contentsOfDirectory(atPath: to.path).isEmpty, "task dry run wrote files")
            let saved = try engine.invoke("listTasks", arguments: []) as! [[String: Any]]
            try expect(try EngineJSON.data(saved[0]["request"]!) == EngineJSON.data(task["request"]!), "dry-run execution changed the saved task")
        }

        test("a confirmed full request keeps its deletion limit and filters after global defaults change") {
            let from = try folder("confirmation-snapshot/source"), to = try folder("confirmation-snapshot/destination")
            try file(from, "current.bin"); try file(to, "obsolete.bin"); try file(to, "protected.keep")
            let engine = try self.engine("confirmation-snapshot-engine"); defer { engine.shutdown() }
            _ = try engine.invoke("saveSettings", arguments: [["defaultTransferOptions": ["maxDelete": -1, "exclude": ["*.keep"]]]])
            var partial = request(from, to, mode: "sync")
            partial["options"] = ["deleteMode": "before"]
            let confirmed = try engine.normalizedRequest(partial)
            try expect(confirmed.options.integer("maxDelete") == -1 && confirmed.options.excludes == ["*.keep"], "native confirmation did not resolve current defaults")
            _ = try engine.invoke("saveSettings", arguments: [["defaultTransferOptions": ["maxDelete": 0, "exclude": [String](), "deleteMode": "after"]]])
            try expect(try engine.normalizedRequest(partial).options.integer("maxDelete") == 0, "fixture did not change defaults during confirmation")
            let preview = try engine.invoke("previewTransfer", arguments: [confirmed.json]) as! [String: Any]
            try expect((preview["warnings"] as! [String]).contains { $0.contains("未設定刪除數量上限") }, "preview reread newer defaults")
            let result = try completed(engine, confirmed.json)
            try expect(try EngineJSON.data(result["request"]!) == EngineJSON.data(confirmed.json), "submission changed the confirmed request snapshot")
            try expect((result["command"] as! String).contains("--max-delete=-1") && (result["command"] as! String).contains("--delete-before"), "confirmed deletion choices did not reach rclone")
            try expect(!FileManager.default.fileExists(atPath: to.appendingPathComponent("obsolete.bin").path) && FileManager.default.fileExists(atPath: to.appendingPathComponent("protected.keep").path), "real sync did not preserve the confirmed deletion limit and exclusions")
        }

        test("five comparison choices and explicit retransfer make distinct real copy decisions") {
            let sourceDate = Date(timeIntervalSince1970: 1700000000), oldDate = Date(timeIntervalSince1970: 1600000000)
            let cases: [(String, String, String, Bool, Bool)] = [
                ("default", "ABCDEF", "UVWXYZ", false, true), ("size", "ABCDEF", "UVWXYZ", false, false),
                ("modtime", "ABCDEF", "short", true, false), ("default", "ABCDEF", "short", true, true),
                ("checksum", "ABCDEF", "UVWXYZ", true, true), ("checksum-only", "ABCDEF", "UVWXYZ", true, true),
                ("none", "ABCDEF", "ABCDEF", true, true)
            ]
            for (index, specification) in cases.enumerated() {
                let (comparison, sourceContent, targetContent, sameDate, expectedCopy) = specification
                let from = try folder("comparisons/\(index)/source"), to = try folder("comparisons/\(index)/destination")
                try file(from, "sample.txt", Data(sourceContent.utf8)); try file(to, "sample.txt", Data(targetContent.utf8))
                try modified(from, "sample.txt", sourceDate); try modified(to, "sample.txt", sameDate ? sourceDate : oldDate)
                let engine = try self.engine("comparison-engine-\(index)", aliases: ["target": to]); defer { engine.shutdown() }
                let job = try completed(engine, request(from, to, options: ["comparison": comparison], destinationRemote: "target"))
                try expect(try String(contentsOf: to.appendingPathComponent("sample.txt"), encoding: .utf8) == (expectedCopy ? sourceContent : targetContent), "wrong copy decision for \(comparison)")
                let stats = job["stats"] as! [String: Any]
                try expect((EngineJSON.number(stats["transfers"]) > 0) == expectedCopy, "wrong transfer counter for \(comparison)")
            }
        }

        test("NAS local-hash policy detects same-size newer changes and skips unchanged repeat without forcing size-only") {
            let from = try folder("nas-policy/source"), to = try folder("nas-policy/destination")
            let current = Data(repeating: 0x41, count: 4096), old = Data(repeating: 0x42, count: 4096)
            try file(from, "backup.bin", current); try file(to, "backup.bin", old)
            try modified(from, "backup.bin", Date(timeIntervalSince1970: 1700000000)); try modified(to, "backup.bin", Date(timeIntervalSince1970: 1600000000))
            let engine = try self.engine("nas-policy-engine", aliases: ["target": to]); defer { engine.shutdown() }
            let options: [String: Any] = ["comparison": "default", "localHashPolicy": "none"]
            let copied = try completed(engine, request(from, to, options: options, destinationRemote: "target"))
            try expect(try Data(contentsOf: to.appendingPathComponent("backup.bin")) == current, "NAS preset missed equal-size changed content")
            let command = copied["command"] as! String
            try expect(command.contains("--local-hashes=none") && !command.contains("--size-only") && !command.contains("--local-no-check-updated"), "NAS preset disabled the wrong checks")
            let repeated = try completed(engine, request(from, to, options: options, destinationRemote: "target"))
            try expect(EngineJSON.number((repeated["stats"] as! [String: Any])["transfers"]) == 0, "unchanged NAS repeat copied again")
        }

        #if os(Linux)
        test("actual engine argv avoids NAS-content read with local-hashes none; ignore-checksum alone still reads") {
            for (index, specification) in [([String: Any](), true, true), (["ignoreChecksum": true], true, true),
                                            (["localHashPolicy": "none"], false, true), (["comparison": "size"], false, false)].enumerated() {
                let (options, shouldRead, shouldTransfer) = specification
                let from = try folder("nas-read/\(index)/source"), to = try folder("nas-read/\(index)/destination")
                try file(from, "sample.bin", Data(repeating: 0x41, count: 1024 * 1024)); try file(to, "sample.bin", Data(repeating: 0x42, count: 1024 * 1024))
                try modified(from, "sample.bin", Date(timeIntervalSince1970: 1700000000)); try modified(to, "sample.bin", Date(timeIntervalSince1970: 1600000000))
                let engine = try self.engine("nas-read-engine-\(index)", aliases: ["target": to]); defer { engine.shutdown() }
                let monitor = try TestFileReadMonitor(to.appendingPathComponent("sample.bin").path)
                let job = try completed(engine, request(from, to, dryRun: true, options: options, destinationRemote: "target"))
                let mask = monitor.masks()
                try expect(((mask & UInt32(IN_ACCESS)) != 0) == shouldRead, "unexpected destination read for \(options): mask=\(mask)")
                if !shouldRead { try expect(mask & UInt32(IN_OPEN) == 0, "hash-free scan still opened destination contents") }
                try expect((EngineJSON.number((job["stats"] as! [String: Any])["transfers"]) > 0) == shouldTransfer, "wrong dry-run copy decision for \(options)")
            }
        }
        #else
        skip("NAS kernel read instrumentation", reason: "Linux inotify is unavailable; the portable NAS transfer/compare test still runs")
        #endif

        test("sync honors before, during and after deletion plus explicit delete-excluded") {
            for timing in ["before", "during", "after"] {
                let from = try folder("delete-modes/\(timing)/source"), to = try folder("delete-modes/\(timing)/destination")
                try file(from, "current.txt"); try file(to, "obsolete.txt"); try file(to, "excluded.tmp")
                let engine = try self.engine("delete-mode-engine-\(timing)", aliases: ["target": to]); defer { engine.shutdown() }
                _ = try completed(engine, request(from, to, mode: "sync", options: ["deleteMode": timing, "exclude": ["*.tmp"]], destinationRemote: "target"))
                try expect(FileManager.default.fileExists(atPath: to.appendingPathComponent("current.txt").path) && !FileManager.default.fileExists(atPath: to.appendingPathComponent("obsolete.txt").path), "sync \(timing) copy/deletion failed")
                try expect(FileManager.default.fileExists(atPath: to.appendingPathComponent("excluded.tmp").path), "sync \(timing) deleted an excluded file without permission")
                _ = try completed(engine, request(from, to, mode: "sync", options: ["deleteMode": timing, "exclude": ["*.tmp"], "deleteExcluded": true], destinationRemote: "target"))
                try expect(!FileManager.default.fileExists(atPath: to.appendingPathComponent("excluded.tmp").path), "sync \(timing) ignored delete-excluded")
            }
        }

        test("real min/max size, age and depth filters restrict both local and alias-backed transfers") {
            let from = try folder("range-filters/source"), to = try folder("range-filters/destination")
            for (name, bytes, age) in [("take.bin", 12, 7200.0), ("small.bin", 2, 7200.0), ("large.bin", 30, 7200.0),
                                       ("too-new.bin", 12, 30.0), ("too-old.bin", 12, 900000.0), ("sub/deep.bin", 12, 7200.0)] {
                try file(from, name, Data(repeating: 0x33, count: bytes)); try modified(from, name, Date().addingTimeInterval(-age))
            }
            let engine = try self.engine("range-filter-engine", aliases: ["source": from]); defer { engine.shutdown() }
            _ = try completed(engine, request(from, to, options: ["minSize": "8B", "maxSize": "20B", "minAge": "1h", "maxAge": "2d", "maxDepth": 1,
                                                               "createEmptyDirs": false, "checkFirst": true, "fastList": true, "noTraverse": true, "oneFileSystem": true, "extraArgs": ["--buffer-size=1M"]], sourceRemote: "source"))
            try expect(try FileManager.default.contentsOfDirectory(atPath: to.path) == ["take.bin"], "range or depth filters widened transfer")
        }

        test("skip existing preserves source moves; skip newer is copy-only; no-update-modtime preserves unchanged dates") {
            let from = try folder("skip-options/source"), to = try folder("skip-options/destination")
            try file(from, "existing.txt", Data("source".utf8)); try file(to, "existing.txt", Data("target".utf8))
            try file(from, "newer.txt", Data("source".utf8)); try file(to, "newer.txt", Data("target".utf8))
            try modified(from, "newer.txt", Date(timeIntervalSince1970: 1600000000)); try modified(to, "newer.txt", Date(timeIntervalSince1970: 1700000000))
            let engine = try self.engine("skip-option-engine"); defer { engine.shutdown() }
            _ = try completed(engine, request(from, to, mode: "move", selection: [["name": "existing.txt", "isDir": false]], options: ["skipExisting": true]))
            try rejects("unsafe move/update entered the queue") { _ = try submit(engine, request(from, to, mode: "move", selection: [["name": "newer.txt", "isDir": false]], options: ["updateOnly": true])) }
            _ = try completed(engine, request(from, to, selection: [["name": "newer.txt", "isDir": false]], options: ["updateOnly": true]))
            for name in ["existing.txt", "newer.txt"] {
                try expect(FileManager.default.fileExists(atPath: from.appendingPathComponent(name).path), "skipped source move removed \(name)")
                try expect(try String(contentsOf: to.appendingPathComponent(name), encoding: .utf8) == "target", "skip overwrote \(name)")
            }
            try file(from, "same.txt", Data("same".utf8)); try file(to, "same.txt", Data("same".utf8))
            let old = Date(timeIntervalSince1970: 1600000000), recent = Date(timeIntervalSince1970: 1700000000)
            try modified(from, "same.txt", recent); try modified(to, "same.txt", old)
            _ = try completed(engine, request(from, to, selection: [["name": "same.txt", "isDir": false]], options: ["noUpdateModtime": true]))
            let retained = try FileManager.default.attributesOfItem(atPath: to.appendingPathComponent("same.txt").path)[.modificationDate] as! Date
            try expect(abs(retained.timeIntervalSince(old)) < 1, "no-update-modtime updated an unchanged destination")
        }

        test("choosing an engine waits for an in-flight operation and refreshes its environment in the same save") {
            let engine = try self.engine("settings-wait", useRclone: false); defer { engine.shutdown() }
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
            let results = TestConcurrentResults(), group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                results.capture { try engine.withAuxiliaryOperation { entered.signal(); _ = release.wait(timeout: .now() + 5) } }
            }
            try expect(entered.wait(timeout: .now() + 3) == .success, "test operation did not enter")
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave(); finished.signal() }
                results.capture {
                    let environment = try engine.invoke("saveSettings", arguments: [["rclonePath": rclone]]) as! [String: Any]
                    try expect(environment["available"] as? Bool == true && environment["rclonePath"] as? String == rclone, "save returned stale missing engine")
                }
            }
            try expect(finished.wait(timeout: .now() + 0.1) == .timedOut, "engine changed before operation completed")
            release.signal()
            try expect(group.wait(timeout: .now() + 15) == .success && results.errors.isEmpty, "engine-selection transaction failed: \(results.errors)")
        }

        test("updater commit and concurrent appearance patches cannot clear the selected engine or restore a skipped version") {
            let engine = try self.engine("settings-update", useRclone: false); defer { engine.shutdown() }
            _ = try engine.invoke("saveSettings", arguments: [["skippedRcloneVersion": "v99.0.0"]])
            try engine.setMaintenance(true)
            let group = DispatchGroup(), results = TestConcurrentResults()
            group.enter()
            DispatchQueue.global().async { defer { group.leave() }; results.capture { try engine.commitRcloneUpdate(path: rclone) } }
            for patch in [["theme": "purple-dark"], ["language": "ja"]] {
                group.enter()
                DispatchQueue.global().async { defer { group.leave() }; results.capture { _ = try engine.invoke("saveSettings", arguments: [patch]) } }
            }
            try expect(group.wait(timeout: .now() + 10) == .success && results.errors.isEmpty, "update/settings race failed: \(results.errors)")
            try engine.setMaintenance(false)
            let settings = engine.settingsSnapshot()
            try expect(settings["rclonePath"] as? String == rclone && settings["skippedRcloneVersion"] as? String == "", "appearance reset updater result")
            try expect(settings["theme"] as? String == "purple-dark" && settings["language"] as? String == "ja", "updater reset appearance")
        }

        test("manual proxy context, safe global options and persisted transfer defaults use the selected process context") {
            let from = try folder("defaults/source"), to = try folder("defaults/destination")
            try file(from, "take.txt", Data("AAAA".utf8)); try file(to, "take.txt", Data("BBBB".utf8))
            let engine = try self.engine("defaults-engine", aliases: ["source": from]); defer { engine.shutdown() }
            _ = try engine.invoke("saveSettings", arguments: [["proxyMode": "manual", "httpProxy": "http://127.0.0.1:7890", "httpsProxy": "socks5://127.0.0.1:7891", "noProxy": "localhost,127.0.0.1",
                                                              "defaultRcloneOptions": ["--buffer-size=2M", "--multi-thread-streams=0"], "defaultTransferOptions": ["comparison": "size"]]])
            let context = try engine.auxiliaryContext()
            try expect(context.binary == rclone && context.environment["HTTP_PROXY"] == "http://127.0.0.1:7890" && context.environment["HTTPS_PROXY"] == "socks5://127.0.0.1:7891", "manual proxy was not passed only through process environment")
            try expect(context.arguments.contains("--buffer-size=2M") && !context.arguments.joined().contains("7890"), "global tuning/proxy argv context")
            var configuredRequest = request(from, to); configuredRequest["options"] = ["extraArgs": ["--buffer-size=1M"]]
            let job = try completed(engine, configuredRequest)
            try expect(try String(contentsOf: to.appendingPathComponent("take.txt"), encoding: .utf8) == "BBBB", "persisted size-only default was ignored")
            let command = job["command"] as! String
            try expect(command.contains("--buffer-size=1M") && !command.contains("--buffer-size=2M") && command.contains("--size-only") && !command.contains("7890"), "job override did not replace one global tuning flag")
            let size = try engine.invoke("size", arguments: [endpoint(from, remote: "source")]) as! [String: Any]
            try expect(EngineJSON.number(size["bytes"]) == 4, "global options broke browsing/size commands")
        }

        test("real copies cover local/local, local/remote, remote/local and remote/remote endpoints") {
            let combinations: [(String?, String?)] = [(nil, nil), (nil, "target"), ("source", nil), ("source", "target")]
            let filename = "照片與文件 [1].txt", payload = Data("endpoint matrix — exact bytes\n".utf8)
            for (index, pair) in combinations.enumerated() {
                let from = try folder("matrix/\(index)/source"), to = try folder("matrix/\(index)/destination")
                try file(from, filename, payload); try file(from, "not-selected.txt")
                let engine = try self.engine("matrix-engine-\(index)", aliases: ["source": from, "target": to])
                defer { engine.shutdown() }
                _ = try completed(engine, request(from, to, selection: [["name": filename, "isDir": false]],
                                                   sourceRemote: pair.0, destinationRemote: pair.1))
                try expect(try Data(contentsOf: to.appendingPathComponent(filename)) == payload, "matrix \(index) did not copy exact content")
                try expect(!FileManager.default.fileExists(atPath: to.appendingPathComponent("not-selected.txt").path), "matrix \(index) widened selection")
                try expect(FileManager.default.fileExists(atPath: from.appendingPathComponent(filename).path), "copy unexpectedly removed source")
            }
        }

        test("real dry run changes no files; literal special names copy precisely") {
            let from = try folder("literal/source"), to = try folder("literal/destination")
            let names = ["report[1]*?{a}.txt", " leading and trailing ", "literal\\name.txt"]
            for name in names { try file(from, name) }
            try file(from, "report1other.txt"); try file(from, "unselected.txt"); try file(from, ".DS_Store")
            let empty = from.appendingPathComponent("empty[1]"); try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            let engine = try self.engine("literal-engine"); defer { engine.shutdown() }
            let selection = names.map { ["name": $0, "isDir": false] as [String: Any] } + [["name": "empty[1]", "isDir": true]]
            _ = try completed(engine, request(from, to, dryRun: true, selection: selection))
            try expect(try FileManager.default.contentsOfDirectory(atPath: to.path).isEmpty, "dry run changed destination")
            let job = try completed(engine, request(from, to, selection: selection))
            for name in names + ["empty[1]"] { try expect(FileManager.default.fileExists(atPath: to.appendingPathComponent(name).path), "literal selection missing \(name)") }
            try expect(!FileManager.default.fileExists(atPath: to.appendingPathComponent("unselected.txt").path), "selection widened")
            try expect(!FileManager.default.fileExists(atPath: to.appendingPathComponent("report1other.txt").path), "literal metacharacters treated as globs")
            let path = try engine.invoke("getLogPath", arguments: [job["id"]!]) as! String
            let log = try String(contentsOfFile: path, encoding: .utf8)
            try expect(log.contains("\"stats\"") && log.contains("Copied"), "real JSON statistics/log missing")
        }

        test("selected folders intersect include/exclude rules without widening") {
            let from = try folder("intersection/source"), to = try folder("intersection/destination")
            try file(from, "take[1]/keep.txt"); try file(from, "take[1]/skip.bin"); try file(from, "take[1]/excluded.txt")
            try file(from, "take1/other.txt"); try file(from, "outside.txt")
            let engine = try self.engine("intersection-engine"); defer { engine.shutdown() }
            _ = try completed(engine, request(from, to, selection: [["name": "take[1]", "isDir": true]], options: ["include": ["*.txt"], "exclude": ["excluded.txt"]]))
            try expect(FileManager.default.fileExists(atPath: to.appendingPathComponent("take[1]/keep.txt").path), "included selected file missing")
            for name in ["take[1]/skip.bin", "take[1]/excluded.txt", "take1/other.txt", "outside.txt"] {
                try expect(!FileManager.default.fileExists(atPath: to.appendingPathComponent(name).path), "unexpected intersection file: \(name)")
            }
        }

        test("real sync previews deletion, obeys max-delete and preserves exclusions") {
            let from = try folder("sync/source"), to = try folder("sync/destination")
            try file(from, "current.txt"); try file(to, "obsolete.txt"); try file(to, ".DS_Store")
            let engine = try self.engine("sync-engine"); defer { engine.shutdown() }
            _ = try completed(engine, request(from, to, mode: "sync", dryRun: true))
            try expect(FileManager.default.fileExists(atPath: to.appendingPathComponent("obsolete.txt").path), "sync dry run deleted file")
            let limited = try wait(engine, submit(engine, request(from, to, mode: "sync", options: ["maxDelete": 0])))
            try expect(limited["status"] as? String == "failed", "max-delete=0 did not stop deletion")
            try expect(FileManager.default.fileExists(atPath: to.appendingPathComponent("obsolete.txt").path), "max-delete=0 removed file")
            let unlimitedRequest = request(from, to, mode: "sync", options: ["maxDelete": -1])
            let preview = try engine.invoke("previewTransfer", arguments: [unlimitedRequest]) as! [String: Any]
            let warnings = preview["warnings"] as! [String]
            try expect(warnings.contains { $0.contains("未設定刪除數量上限") } && !warnings.contains { $0.contains("最多刪除 -1") }, "unlimited deletion warning is misleading")
            let unlimited = try completed(engine, unlimitedRequest)
            try expect((unlimited["command"] as! String).contains("--max-delete=-1"), "unlimited delete did not reach real rclone")
            try expect(!FileManager.default.fileExists(atPath: to.appendingPathComponent("obsolete.txt").path), "sync did not delete extra file")
            try expect(FileManager.default.fileExists(atPath: to.appendingPathComponent(".DS_Store").path), "excluded destination file deleted")
        }

        test("real move and remote alias rename preserve empty folders") {
            let from = try folder("move/source"), to = try folder("move/destination"), alias = try folder("move/remote")
            try file(from, "move me.txt"); try file(from, "keep.txt")
            try FileManager.default.createDirectory(at: alias.appendingPathComponent("old/empty/deep"), withIntermediateDirectories: true)
            let engine = try self.engine("move-engine", aliases: ["testremote": alias]); defer { engine.shutdown() }
            _ = try completed(engine, request(from, to, mode: "move", selection: [["name": "move me.txt", "isDir": false]]))
            try expect(!FileManager.default.fileExists(atPath: from.appendingPathComponent("move me.txt").path) && FileManager.default.fileExists(atPath: to.appendingPathComponent("move me.txt").path), "move semantics")
            try expect(FileManager.default.fileExists(atPath: from.appendingPathComponent("keep.txt").path), "move touched unselected file")
            let endpoint = self.endpoint(alias, remote: "testremote")
            _ = try engine.invoke("rename", arguments: [endpoint, "old", "new", true])
            try expect(FileManager.default.fileExists(atPath: alias.appendingPathComponent("new/empty/deep").path), "remote rename lost empty folders")
            _ = try engine.invoke("mkdir", arguments: [endpoint, "created"])
            _ = try engine.invoke("remove", arguments: [endpoint, [["name": "created", "isDir": true]]])
            try expect(!FileManager.default.fileExists(atPath: alias.appendingPathComponent("created").path), "remote remove failed")
        }

        test("stale selections fail instead of copying the whole source") {
            let from = try folder("stale/source"), to = try folder("stale/destination")
            try file(from, "unselected.txt")
            let engine = try self.engine("stale-engine"); defer { engine.shutdown() }
            let value = try wait(engine, submit(engine, request(from, to, selection: [["name": "missing.txt", "isDir": false]])))
            try expect(value["status"] as? String == "failed", "missing selection did not fail")
            try expect(try FileManager.default.contentsOfDirectory(atPath: to.path).isEmpty, "stale selection widened to source directory")
        }

        test("real rate-limited jobs report speed/ETA; queue=2; cancel and maintenance are exclusive") {
            let from = try folder("queue/source"), toA = try folder("queue/a"), toB = try folder("queue/b"), toC = try folder("queue/c")
            try file(from, "large.bin", Data(repeating: 0x5a, count: 8 * 1024 * 1024))
            let engine = try self.engine("queue-engine", aliases: ["testremote": from]); defer { engine.shutdown() }
            _ = try engine.invoke("saveSettings", arguments: [["maxConcurrentJobs": 2]])
            let eventLock = NSLock(); var observedSpeed = false, observedETA = false, observedBytes = false, peakRunning = 0
            engine.onJobUpdate = { job in
                if let stats = job["stats"] as? [String: Any] {
                    eventLock.holding {
                        observedSpeed = observedSpeed || EngineJSON.number(stats["speed"]) > 0
                        observedETA = observedETA || (stats["eta"] is NSNumber && EngineJSON.number(stats["eta"]) > 0)
                        observedBytes = observedBytes || EngineJSON.number(stats["bytes"]) > 0
                    }
                }
            }
            // APFS clones finish without streaming bytes, so bandwidth limits
            // cannot produce the progress events this test needs to observe.
            // Force real byte copies only for this progress/cancellation fixture.
            let progressOptions: [String: Any] = ["bandwidth": "512K", "extraArgs": ["--local-no-clone"]]
            let a = try submit(engine, request(from, toA, options: progressOptions, sourceRemote: "testremote"))
            let b = try submit(engine, request(from, toB, options: progressOptions))
            let c = try submit(engine, request(from, toC, options: progressOptions))
            try expect(try job(engine, c)["status"] as? String == "queued", "third transfer did not queue")
            try rejects("maintenance started with running jobs") { try engine.setMaintenance(true) }
            var changed = engine.settingsSnapshot(); changed["rcloneDirectory"] = try folder("queue/new-tools").path; changed["rclonePath"] = ""
            try rejects("engine path changed while jobs run") { _ = try engine.invoke("saveSettings", arguments: [changed]) }
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline && !eventLock.holding({ observedSpeed && observedBytes && observedETA }) {
                let jobs = try engine.invoke("listJobs", arguments: []) as! [[String: Any]]
                peakRunning = max(peakRunning, jobs.filter { ["running", "cancelling"].contains($0["status"] as? String ?? "") }.count)
                Thread.sleep(forTimeInterval: 0.05)
            }
            try expect(eventLock.holding { observedSpeed && observedBytes && observedETA }, "real progress event lacked nonzero speed, bytes or ETA")
            try expect(peakRunning <= 2, "queue exceeded two active jobs")
            _ = try engine.invoke("cancelJob", arguments: [c])
            try expect(try FileManager.default.contentsOfDirectory(atPath: toC.path).isEmpty, "cancelled queued job wrote data")
            let start = Date()
            _ = try engine.invoke("cancelJob", arguments: [a]); _ = try engine.invoke("cancelJob", arguments: [b])
            try expect(Date().timeIntervalSince(start) < 8, "active cancellation too slow")
            try expect(try job(engine, a)["status"] as? String == "cancelled" && job(engine, b)["status"] as? String == "cancelled", "active jobs not cancelled")
            try engine.setMaintenance(true)
            try rejects("remote browsing ran during update") { _ = try engine.invoke("list", arguments: [endpoint(from, remote: "testremote")]) }
            try rejects("transfer ran during update") { _ = try engine.invoke("startTransfer", arguments: [request(from, toA)]) }
            try engine.setMaintenance(false)
            let logPath = try engine.invoke("getLogPath", arguments: [a]) as! String
            try expect((try String(contentsOfFile: logPath, encoding: .utf8)).contains("\"stats\""), "cancelled job lost raw statistics")
        }

        test("config passwords stay in memory; inherited RCLONE flags cannot change transfer semantics") {
            let from = try folder("environment/source"), to = try folder("environment/destination")
            try file(from, "real.txt")
            let engine = try self.engine("environment-engine"); defer { engine.shutdown() }
            let sentinel = "test-password-should-never-be-on-disk-\(UUID().uuidString)"
            _ = try engine.invoke("unlockConfig", arguments: [sentinel])
            let oldDryRun = ProcessInfo.processInfo.environment["RCLONE_DRY_RUN"]
            let oldLog = ProcessInfo.processInfo.environment["RCLONE_LOG_FILE"]
            setenv("RCLONE_DRY_RUN", "true", 1); setenv("RCLONE_LOG_FILE", root.appendingPathComponent("inherited-log-must-not-exist").path, 1)
            defer {
                if let oldDryRun = oldDryRun { setenv("RCLONE_DRY_RUN", oldDryRun, 1) } else { unsetenv("RCLONE_DRY_RUN") }
                if let oldLog = oldLog { setenv("RCLONE_LOG_FILE", oldLog, 1) } else { unsetenv("RCLONE_LOG_FILE") }
            }
            _ = try completed(engine, request(from, to))
            try expect(FileManager.default.fileExists(atPath: to.appendingPathComponent("real.txt").path), "inherited dry-run changed real transfer")
            try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("inherited-log-must-not-exist").path), "inherited log path escaped state folder")
            engine.shutdown()
            let iterator = FileManager.default.enumerator(at: root.appendingPathComponent("environment-engine/state"), includingPropertiesForKeys: [.isRegularFileKey])!
            for case let url as URL in iterator {
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    try expect(!(try String(contentsOf: url, encoding: .utf8)).contains(sentinel), "password persisted in \(url.lastPathComponent)")
                }
            }
        }
    }
}

@main
private enum CoreTests {
    static func main() {
        do {
            let arguments = CommandLine.arguments
            let rclone = arguments.count > 1 && !arguments[1].isEmpty ? arguments[1] : ProcessInfo.processInfo.environment["RBN_TEST_RCLONE"]
            if let rclone = rclone, !rclone.hasPrefix("/") || !FileManager.default.isExecutableFile(atPath: rclone) {
                throw TestFailure(description: "rclone must be an absolute executable path")
            }
            let base = arguments.count > 2 ? URL(fileURLWithPath: arguments[2]) : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build-cache/tests/work")
            let root = base.appendingPathComponent("run-" + UUID().uuidString.lowercased())
            let suite = try CoreTestSuite(root: root, rclone: rclone)
            print("Rclone Browser Next Lite — Foundation core tests")
            print("Test files: \(root.path)")
            suite.run()
            print("RESULT: \(suite.passed) passed, \(suite.failed) failed, \(suite.skipped) skipped")
            if suite.failed > 0 { exit(1) }
        } catch { fputs("TEST ERROR: \(error)\n", stderr); exit(1) }
    }
}
