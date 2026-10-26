import Foundation
import Darwin

private struct LocalCopyFailure: Error, CustomStringConvertible { let description: String }
private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw LocalCopyFailure(description: message) }
}

/// All fixtures live under a newly created private directory. Disk images are
/// created by this test and attached only at its own explicit mountpoints.
private final class LocalCopyFixture {
    struct ProcessResult { let status: Int32; let text: String }
    let root: URL
    let rclone: String
    private var counter = 0

    init(root: URL, rclone: String) throws {
        self.root = root; self.rclone = rclone
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    func folder(_ name: String, in parent: URL? = nil) throws -> URL {
        let target = (parent ?? root).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 45) throws -> ProcessResult {
        counter += 1
        let log = root.appendingPathComponent("process-\(counter).log")
        try Data().write(to: log)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let process = Process(), done = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.uppercased().hasPrefix("RCLONE_") }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = output
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 3) == .timedOut {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 3)
            }
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            throw LocalCopyFailure(description: "process deadline exceeded: \(executable) \(arguments)\n\(text)")
        }
        return ProcessResult(status: process.terminationStatus, text: try String(contentsOf: log, encoding: .utf8))
    }

    func info(_ path: URL) throws -> Darwin.stat {
        var value = Darwin.stat()
        guard path.path.withCString({ Darwin.lstat($0, &value) }) == 0 else {
            throw LocalCopyFailure(description: "lstat failed: \(path.path), errno \(errno)")
        }
        return value
    }

    func lock(_ path: URL) throws -> UInt32 {
        let original = try info(path).st_flags
        let flags = original | UInt32(UF_IMMUTABLE)
        guard path.path.withCString({ Darwin.chflags($0, flags) }) == 0 else {
            throw LocalCopyFailure(description: "fixture chflags uchg failed: \(path.path), errno \(errno)")
        }
        try require(try info(path).st_flags & UInt32(UF_IMMUTABLE) != 0, "fixture did not become Finder locked")
        return try info(path).st_flags
    }

    func unlockOwnedTree(_ path: URL) throws {
        let prefix = root.standardizedFileURL.path + "/"
        try require(path.standardizedFileURL.path.hasPrefix(prefix), "fixture cleanup escaped its private root")
        let iterator = FileManager.default.enumerator(at: path, includingPropertiesForKeys: [.isSymbolicLinkKey])
        var items = [path]
        if let iterator = iterator {
            for case let item as URL in iterator {
                if (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                    iterator.skipDescendants(); continue
                }
                items.append(item)
            }
        }
        for item in items {
            let value = try info(item)
            if value.st_flags & UInt32(UF_IMMUTABLE) != 0 {
                let flags = value.st_flags & ~UInt32(UF_IMMUTABLE)
                guard item.path.withCString({ Darwin.chflags($0, flags) }) == 0 else {
                    throw LocalCopyFailure(description: "could not unlock owned fixture: \(item.path)")
                }
            }
        }
    }

    func makeEngine(_ name: String) throws -> RcloneEngine {
        let area = try folder(name)
        let config = area.appendingPathComponent("rclone.conf")
        try Data().write(to: config)
        let engine = try RcloneEngine(stateDirectory: area.appendingPathComponent("state"), defaultRcloneDirectory: area.appendingPathComponent("tools"))
        do {
            let status = try engine.invoke("saveSettings", arguments: [["rclonePath": rclone, "configPath": config.path,
                "defaultRcloneOptions": ["--local-no-clone=false"]]]) as! [String: Any]
            try require(status["available"] as? Bool == true, "rclone engine unavailable: \(status["error"] ?? "unknown")")
            return engine
        } catch { engine.shutdown(); throw error }
    }

    func request(_ source: URL, _ destination: URL, metadata: Bool = false, mode: String = "copy",
                 options: [String: Any] = [:]) -> [String: Any] {
        let defaults: [String: Any] = ["preserveMetadata": metadata, "transfers": 1, "checkers": 1,
                                      "retries": 1, "lowLevelRetries": 1, "localHashPolicy": "none",
                                      "exclude": [String](),
                                      "extraArgs": ["--local-no-clone=false", "--multi-thread-streams=0"]]
        return ["source": ["remote": NSNull(), "path": source.path], "destination": ["remote": NSNull(), "path": destination.path],
                "mode": mode, "selection": [], "dryRun": false,
                "options": EngineTransferOptions.defaults.merging(defaults) { _, new in new }.merging(options) { _, new in new }]
    }

    func job(_ engine: RcloneEngine, _ id: String) throws -> [String: Any] {
        let jobs = try engine.invoke("listJobs", arguments: []) as! [[String: Any]]
        guard let value = jobs.first(where: { $0["id"] as? String == id }) else { throw LocalCopyFailure(description: "missing fixture job") }
        return value
    }

    func wait(_ engine: RcloneEngine, _ id: String, seconds: TimeInterval = 35) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let value = try job(engine, id)
            if EngineJob.terminal.contains(value["status"] as? String ?? "") { return value }
            Thread.sleep(forTimeInterval: 0.03)
        }
        _ = try? engine.invoke("cancelJob", arguments: [id])
        throw LocalCopyFailure(description: "transfer deadline exceeded: \(try job(engine, id))")
    }

    func complete(_ engine: RcloneEngine, _ request: [String: Any]) throws -> [String: Any] {
        let preview = try engine.invoke("previewTransfer", arguments: [request]) as! [String: Any]
        let command = preview["command"] as? String ?? ""
        try require(command.components(separatedBy: "--local-no-clone").count == 2 && !command.contains("--local-no-clone=false"), "preview did not normalize task/default clone overrides")
        let submitted = try engine.invoke("startTransfer", arguments: [request]) as! [String: Any]
        let result = try wait(engine, submitted["id"] as! String)
        try require(result["status"] as? String == "completed", "transfer failed: \(result["error"] ?? "unknown")\n\(result["logs"] ?? "")")
        try require(result["command"] as? String == command, "effective command differed from preview")
        let saved = result["request"] as! [String: Any]
        try require(try EngineJSON.data(saved) == EngineJSON.data(try EngineTransferRequest(request).json), "policy changed the stored request")
        return result
    }

    func rawControl(_ source: URL, _ destination: URL) throws {
        let result = try run(rclone, ["copy", "--config=/dev/null", "--retries=1", "--low-level-retries=1", "--transfers=1", "--checkers=1",
                                     "--local-hashes=none", "--use-json-log", "--log-level=INFO", "--", source.path, destination.path])
        try require(result.status != 0 && result.text.contains("partial file rename failed:") && result.text.contains("operation not permitted"),
                    "unmodified rclone did not reproduce locked partial rename failure:\n\(result.text)")
        let names = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        try require(names.count == 1 && names[0].hasPrefix("locked.txt.") && names[0].hasSuffix(".partial"), "control did not leave its expected partial")
        let partial = destination.appendingPathComponent(names[0])
        try require(try info(partial).st_flags & UInt32(UF_IMMUTABLE) != 0, "raw copy did not inherit the immutable flag")
        try require(try RBNSHA256.hex(Data(contentsOf: partial)) == RBNSHA256.hex(Data(contentsOf: source.appendingPathComponent("locked.txt"))), "control partial contents differed")
        print("LOCAL_COPY_RAW_CONTROL: " + String(decoding: try EngineJSON.data(["exitCode": result.status, "renameDenied": true,
            "immutablePartial": true, "partialSHA256Matches": true, "log": result.text]), as: UTF8.self))
    }

    func verifyCopy(_ source: URL, _ destination: URL, metadata: Bool, label: String) throws {
        let original = source.appendingPathComponent("locked.txt")
        let before = try info(original), digest = try RBNSHA256.hex(Data(contentsOf: original))
        let engine = try makeEngine("engine-" + label); defer { engine.shutdown() }
        let value = request(source, destination, metadata: metadata, mode: "sync")
        let first = try complete(engine, value)
        let final = destination.appendingPathComponent("locked.txt")
        try require(try RBNSHA256.hex(Data(contentsOf: final)) == digest, "destination bytes changed")
        try require(try info(final).st_flags & UInt32(UF_IMMUTABLE) == 0, "streaming copy inherited Finder lock")
        try require(try info(original).st_flags == before.st_flags && RBNSHA256.hex(Data(contentsOf: original)) == digest, "source flags or bytes changed")
        try require(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["locked.txt"], "successful copy left temporary data")
        let again = try complete(engine, value)
        let stats = again["stats"] as! [String: Any]
        try require(EngineJSON.number(stats["bytes"]) == 0 && EngineJSON.number(stats["transfers"]) == 0, "repeat sync recopied unchanged content")
        print("LOCAL_COPY_FIXED: " + String(decoding: try EngineJSON.data(["case": label, "metadata": metadata, "sha256": digest,
            "sourceFlags": before.st_flags, "destinationFlags": try info(final).st_flags, "unchangedBytes": stats["bytes"]!,
            "effectiveCommand": first["command"]!]), as: UTF8.self))
    }
}

private final class LocalCopyDiskImage {
    let fixture: LocalCopyFixture
    let directory: URL
    let mount: URL
    let format: String
    let expectedFileSystem: String
    private var attached = false

    init(fixture: LocalCopyFixture, name: String, format: String, fileSystem: String) throws {
        self.fixture = fixture; self.format = format; expectedFileSystem = fileSystem
        directory = try fixture.folder(name)
        mount = try fixture.folder("mount", in: directory)
    }

    func attach() throws {
        let image = directory.appendingPathComponent("fixture.dmg")
        let created = try fixture.run("/usr/bin/hdiutil", ["create", "-size", "64m", "-fs", format, "-volname", "RBN-TEST", "-format", "UDRW", image.path], timeout: 90)
        try require(created.status == 0, "\(format) fixture creation failed:\n\(created.text)")
        // Mark before running attach so cleanup still targets this private
        // mountpoint if hdiutil reports an error after mounting the image.
        attached = true
        let mounted = try fixture.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, "-plist", image.path], timeout: 90)
        try require(mounted.status == 0, "\(format) fixture attach failed:\n\(mounted.text)")
        try require(EngineLocalTimePrecision.mountedFileSystem(mount.path) == expectedFileSystem, "fixture mounted with an unexpected filesystem")
    }

    func close() throws {
        guard attached else { return }
        try fixture.unlockOwnedTree(mount)
        let result = try fixture.run("/usr/bin/hdiutil", ["detach", mount.path], timeout: 45)
        try require(result.status == 0, "could not detach owned test image:\n\(result.text)")
        attached = false
    }
}

@main
private enum MacLocalCopyTests {
    static var passed = 0
    static var failed = 0

    static func test(_ name: String, _ body: () throws -> Void) {
        do { try body(); passed += 1; print("PASS \(name)") }
        catch { failed += 1; print("FAIL \(name): \(error)") }
        fflush(stdout)
    }

    static func main() throws {
        guard CommandLine.arguments.count > 2, CommandLine.arguments[1].hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: CommandLine.arguments[1]) else {
            throw LocalCopyFailure(description: "MacLocalCopyTests requires an absolute rclone path and a private test directory")
        }
        let parent = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let root = parent.appendingPathComponent("run-" + UUID().uuidString, isDirectory: true)
        let fixture = try LocalCopyFixture(root: root, rclone: CommandLine.arguments[1])
        let payload = Data("Local-copy fixture: locked source, complete destination.\n".utf8)

        test("pinned rclone reproduces immutable partial failure and engine commits valid APFS copies with metadata off and on") {
            try require(EngineLocalTimePrecision.mountedFileSystem(root.path) == "apfs", "APFS control requires an actual APFS test workspace")
            let source = try fixture.folder("apfs-source"), raw = try fixture.folder("apfs-raw")
            defer { try? fixture.unlockOwnedTree(source); try? fixture.unlockOwnedTree(raw) }
            try payload.write(to: source.appendingPathComponent("locked.txt"))
            _ = try fixture.lock(source.appendingPathComponent("locked.txt"))
            try fixture.rawControl(source, raw)
            for metadata in [false, true] {
                let target = try fixture.folder("apfs-fixed-\(metadata)")
                try fixture.verifyCopy(source, target, metadata: metadata, label: "apfs-\(metadata)")
            }
        }

        test("read-only APFS mode preserves explicit metadata without inheriting immutable flags") {
            let source = try fixture.folder("mode-source")
            let file = source.appendingPathComponent("locked.txt")
            defer { try? fixture.unlockOwnedTree(source) }
            try payload.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
            _ = try fixture.lock(file)
            for metadata in [false, true] {
                let target = try fixture.folder("mode-target-\(metadata)")
                try fixture.verifyCopy(source, target, metadata: metadata, label: "readonly-mode-\(metadata)")
                let mode = try fixture.info(target.appendingPathComponent("locked.txt")).st_mode & 0o777
                try require(metadata ? mode == 0o444 : mode & 0o200 != 0, "explicit metadata mode semantics changed")
            }
        }

        test("FAT32 and ExFAT image transfers commit locked-source contents and repeat without recopying") {
            let fat = try LocalCopyDiskImage(fixture: fixture, name: "fat-image", format: "MS-DOS FAT32", fileSystem: "msdos")
            let exfat = try LocalCopyDiskImage(fixture: fixture, name: "exfat-image", format: "ExFAT", fileSystem: "exfat")
            var cleanupErrors: [String] = []
            do {
                try fat.attach(); try exfat.attach()
                for (index, pair) in [(fat.mount, exfat.mount), (exfat.mount, fat.mount)].enumerated() {
                    let source = try fixture.folder("source-\(index)", in: pair.0)
                    try payload.write(to: source.appendingPathComponent("locked.txt"))
                    _ = try fixture.lock(source.appendingPathComponent("locked.txt"))
                    let raw = try fixture.folder("raw-\(index)", in: pair.1)
                    try fixture.rawControl(source, raw)
                    for metadata in [false, true] {
                        let target = try fixture.folder("fixed-\(index)-\(metadata)", in: pair.1)
                        try fixture.verifyCopy(source, target, metadata: metadata, label: "card-\(index)-\(metadata)")
                    }
                }
            } catch {
                do { try exfat.close() } catch { cleanupErrors.append(String(describing: error)) }
                do { try fat.close() } catch { cleanupErrors.append(String(describing: error)) }
                throw LocalCopyFailure(description: "\(error); cleanup: \(cleanupErrors)")
            }
            do { try exfat.close() } catch { cleanupErrors.append(String(describing: error)) }
            do { try fat.close() } catch { cleanupErrors.append(String(describing: error)) }
            try require(cleanupErrors.isEmpty, "owned volume cleanup failed: \(cleanupErrors)")
        }

        test("cancelling a locked-source streaming copy preserves the prior complete destination and source flags") {
            let source = try fixture.folder("cancel-source"), target = try fixture.folder("cancel-target")
            let sourceFile = source.appendingPathComponent("large.bin"), destinationFile = target.appendingPathComponent("large.bin")
            let original = Data("previous complete file".utf8)
            try Data(repeating: 0x57, count: 4 * 1024 * 1024).write(to: sourceFile)
            let flags = try fixture.lock(sourceFile)
            defer { try? fixture.unlockOwnedTree(source) }
            try original.write(to: destinationFile)
            let engine = try fixture.makeEngine("engine-cancel"); defer { engine.shutdown() }
            let submitted = try engine.invoke("startTransfer", arguments: [fixture.request(source, target, options: ["bandwidth": "64K"])]) as! [String: Any]
            let id = submitted["id"] as! String, deadline = Date().addingTimeInterval(10)
            var streaming = false
            while Date() < deadline {
                let value = try fixture.job(engine, id), stats = value["stats"] as? [String: Any] ?? [:]
                let names = try FileManager.default.contentsOfDirectory(atPath: target.path)
                streaming = EngineJSON.number(stats["bytes"]) > 32768 && names.contains { $0.hasSuffix(".partial") }
                if streaming { break }
                Thread.sleep(forTimeInterval: 0.04)
            }
            try require(streaming, "locked source did not enter a cancellable staged transfer")
            try require(try Data(contentsOf: destinationFile) == original, "streaming copy overwrote existing destination before commit")
            _ = try engine.invoke("cancelJob", arguments: [id])
            let stopped = try fixture.wait(engine, id)
            try require(stopped["status"] as? String == "cancelled", "transfer did not cancel")
            try require(try Data(contentsOf: destinationFile) == original && fixture.info(sourceFile).st_flags == flags, "cancellation changed destination or source protection")
            try require(try FileManager.default.contentsOfDirectory(atPath: target.path) == ["large.bin"], "cancellation left its partial")
        }

        print("RESULT: \(passed) passed, \(failed) failed")
        if failed != 0 { exit(1) }
    }
}
