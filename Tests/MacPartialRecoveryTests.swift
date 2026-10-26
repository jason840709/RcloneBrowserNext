#if os(macOS)
import Foundation
import Darwin

@main struct MacPartialRecoveryTests {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static var passed = 0
    private static var failed = 0
    private static var fixtureBase: URL?
    private static let bytes = Data("A synthetic book used only by the recovery tests.\n".utf8)

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }
    private static func test(_ name: String, _ body: () throws -> Void) {
        do { try body(); passed += 1; print("PASS \(name)") }
        catch { failed += 1; print("FAIL \(name): \(error)") }
    }
    private static func rejects(_ body: () throws -> Void) throws {
        var rejected = false
        do { try body() } catch { rejected = true }
        try require(rejected, "An unsafe operation was accepted")
    }
    private static func count(_ value: [String: Any], _ name: String) -> Int {
        ((value["counts"] as? [String: Any])?[name] as? NSNumber)?.intValue ?? -1
    }
    private static func flags(_ url: URL) throws -> UInt32 {
        var value = stat()
        guard Darwin.lstat(url.path, &value) == 0 else { throw Failure(description: "Cannot stat fixture") }
        return value.st_flags
    }
    private static func setFlags(_ url: URL, _ value: UInt32) throws {
        guard Darwin.chflags(url.path, value) == 0 else {
            throw Failure(description: "Cannot set fixture flags: \(String(cString: strerror(errno)))")
        }
    }
    private static func modificationTime(_ url: URL) throws -> Double {
        var value = stat()
        guard Darwin.lstat(url.path, &value) == 0 else { throw Failure(description: "Cannot stat fixture time") }
        return Double(value.st_mtimespec.tv_sec) + Double(value.st_mtimespec.tv_nsec) / 1_000_000_000
    }
    private static func outcomes(_ result: [String: Any]) -> [[String: Any]] {
        result["items"] as? [[String: Any]] ?? []
    }
    private static func journalEvents(_ receipt: URL) throws -> [[String: Any]] {
        let text = try String(contentsOfFile: receipt.path + ".journal.jsonl", encoding: .utf8)
        return try text.split(separator: "\n").map {
            guard let value = try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] else {
                throw Failure(description: "Journal event is not an object")
            }
            return value
        }
    }

    private final class Fixture {
        let root: URL
        let source: URL
        let destination: URL
        let output: URL
        let original: URL
        let partial: URL
        let final: URL
        let report: URL
        let plan: URL
        let receipt: URL
        let relative = "books/book.txt"
        let temporary = "books/book.txt.1234abcd.partial"

        init(mode: String = "sync", lockSource: Bool = false,
             destinationParent: URL? = nil, partialExtraFlags: UInt32 = UInt32(UF_NODUMP),
             contents: Data? = nil, modificationDate: Date? = nil) throws {
            // macOS /var is a symlink. Fixture roots use its resolved physical
            // path; the product itself deliberately does not resolve symlinks.
            root = (fixtureBase ?? FileManager.default.temporaryDirectory).resolvingSymlinksInPath()
                .appendingPathComponent("rbn-partial-recovery-\(UUID().uuidString)", isDirectory: true)
            source = root.appendingPathComponent("source", isDirectory: true)
            destination = destinationParent.map {
                $0.appendingPathComponent("recovery-\(UUID().uuidString)", isDirectory: true)
            } ?? root.appendingPathComponent("destination", isDirectory: true)
            output = root.appendingPathComponent("review", isDirectory: true)
            original = source.appendingPathComponent(relative)
            partial = destination.appendingPathComponent(temporary)
            final = destination.appendingPathComponent(relative)
            report = output.appendingPathComponent("report.jsonl")
            plan = output.appendingPathComponent("plan.json")
            receipt = output.appendingPathComponent("receipt.json")
            for folder in [original.deletingLastPathComponent(), partial.deletingLastPathComponent(), output] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            try (contents ?? bytes).write(to: original)
            try (contents ?? bytes).write(to: partial)
            if let modificationDate = modificationDate {
                try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: original.path)
                try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: partial.path)
            }
            try setFlags(partial, UInt32(UF_IMMUTABLE) | partialExtraFlags)
            if lockSource { try setFlags(original, UInt32(UF_IMMUTABLE)) }
            try writeRows(rows(mode: mode))
        }

        deinit {
            // Every entry is synthetic and contained in this unique fixture.
            // Never follow a fixture symlink while clearing flags for cleanup.
            let ownedTrees = destination.path.hasPrefix(root.path + "/") ? [root] : [destination, root]
            for tree in ownedTrees {
                if let enumerator = FileManager.default.enumerator(at: tree,
                                                                   includingPropertiesForKeys: nil) {
                    for case let path as URL in enumerator {
                        var value = stat()
                        if Darwin.lstat(path.path, &value) == 0 {
                            if value.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                                enumerator.skipDescendants()
                            } else { _ = Darwin.chflags(path.path, 0) }
                        }
                    }
                }
                try? FileManager.default.removeItem(at: tree)
            }
        }

        func rows(mode: String = "sync") -> [[String: Any]] {
            [
                ["sequence": 1, "action": "configuration", "status": "info",
                 "evidence": "app-configuration",
                 "configuration": [
                    "schemaVersion": 1, "kind": "complete", "engineVersion": "rclone v1.75.2",
                    "request": [
                        "mode": mode, "dryRun": false,
                        "source": ["remote": NSNull(), "path": source.path],
                        "destination": ["remote": NSNull(), "path": destination.path],
                        "selection": [["name": "books", "isDir": true]],
                        "options": ["localHashPolicy": "none", "preserveMetadata": false]
                    ]
                 ]],
                ["sequence": 2, "action": "missing-destination", "status": "candidate",
                 "evidence": "comparison", "path": relative, "sigil": "+"],
                ["sequence": 3, "action": "rename", "status": "error", "level": "error",
                 "evidence": "json-log", "path": temporary, "object": temporary,
                 "message": "partial file rename failed: rename \(partial.path) \(final.path): operation not permitted"]
            ]
        }

        func writeRows(_ value: [[String: Any]]) throws {
            var data = Data()
            for row in value {
                data.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
                data.append(10)
            }
            try data.write(to: report)
        }

        func preview() throws -> [String: Any] {
            try EnginePartialRecovery.preview(report: report, plan: plan)
        }
        func apply() throws -> [String: Any] {
            try EnginePartialRecovery.apply(plan: plan, receipt: receipt)
        }
        func apply(options: EnginePartialRecovery.TestOptions) throws -> [String: Any] {
            try EnginePartialRecovery.testApply(plan: plan, receipt: receipt, options: options)
        }
        func assertPartialUnchanged() throws {
            try require(FileManager.default.fileExists(atPath: partial.path), "Partial disappeared")
            try require(try Data(contentsOf: partial) == bytes, "Partial content changed")
            try require(try flags(partial) & UInt32(UF_IMMUTABLE) != 0, "Partial was unlocked")
        }
    }

    /// These are new, disposable disk images, never an existing mounted card.
    private final class CardImage {
        let root: URL
        let mount: URL
        let format: String
        let fileSystem: String
        private var attached = false
        private var command = 0

        init(format: String, fileSystem: String) throws {
            self.format = format
            self.fileSystem = fileSystem
            root = (fixtureBase ?? FileManager.default.temporaryDirectory).resolvingSymlinksInPath()
                .appendingPathComponent("rbn-recovery-image-\(UUID().uuidString)", isDirectory: true)
            mount = root.appendingPathComponent("mount", isDirectory: true)
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }

        private func run(_ arguments: [String], timeout: TimeInterval) throws {
            command += 1
            let log = root.appendingPathComponent("hdiutil-\(command).log")
            try Data().write(to: log)
            let output = try FileHandle(forWritingTo: log)
            defer { try? output.close() }
            let process = Process()
            let done = DispatchSemaphore(value: 0)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = output
            process.terminationHandler = { _ in done.signal() }
            try process.run()
            if done.wait(timeout: .now() + timeout) == .timedOut {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 3)
                throw Failure(description: "Owned disk-image operation exceeded its deadline")
            }
            let text = String(decoding: try Data(contentsOf: log), as: UTF8.self)
            try require(process.terminationStatus == 0, "Owned disk-image operation failed: \(text.prefix(3000))")
        }

        func attach() throws {
            let image = root.appendingPathComponent("recovery-fixture.dmg")
            // exFAT VolumeLabel permits at most 11 characters.
            try run(["create", "-size", "64m", "-fs", format, "-volname", "RBN-TEST",
                     image.path], timeout: 90)
            attached = true
            try run(["attach", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, "-plist", image.path],
                    timeout: 90)
            try require(EngineLocalTimePrecision.mountedFileSystem(mount.path) == fileSystem,
                        "Mounted recovery image has an unexpected filesystem")
        }

        func close() throws {
            guard attached else { return }
            try run(["detach", mount.path], timeout: 45)
            attached = false
        }
    }

    private static func appCLI(_ executable: URL, arguments: [String], fixture: Fixture,
                               label: String) throws -> [String: Any] {
        let stdout = fixture.output.appendingPathComponent(label + "-stdout.json")
        let stderr = fixture.output.appendingPathComponent(label + "-stderr.txt")
        try Data().write(to: stdout)
        try Data().write(to: stderr)
        let output = try FileHandle(forWritingTo: stdout)
        let errors = try FileHandle(forWritingTo: stderr)
        defer { try? output.close(); try? errors.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = fixture.output
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            let stopDeadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < stopDeadline { Thread.sleep(forTimeInterval: 0.01) }
            throw Failure(description: "App CLI did not exit within 20 seconds; it may have entered the GUI route")
        }
        process.waitUntilExit()
        try output.synchronize()
        try errors.synchronize()
        let errorText = String(decoding: try Data(contentsOf: stderr), as: UTF8.self)
        try require(process.terminationStatus == 0, "App CLI failed: \(errorText.prefix(2000))")
        guard let result = try JSONSerialization.jsonObject(with: Data(contentsOf: stdout)) as? [String: Any] else {
            throw Failure(description: "App CLI did not return a JSON object")
        }
        return result
    }

    /// Fill only a freshly created, disposable image. The last one-byte write
    /// must return real ENOSPC; this is not a simulated write failure.
    private static func fillOwnedImage(_ image: CardImage) throws -> Int64 {
        let file = image.mount.appendingPathComponent("owned-space-fixture")
        let fd = Darwin.open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw Failure(description: "Cannot create owned space fixture") }
        defer { Darwin.close(fd) }
        let bytes = [UInt8](repeating: 37, count: 64 * 1024)
        let deadline = Date().addingTimeInterval(45)
        var total: Int64 = 0
        for amount in [64 * 1024, 1024, 1] {
            while true {
                try require(Date() < deadline && total < 128 * 1024 * 1024, "Owned image did not reach ENOSPC")
                let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, amount) }
                if written < 0 && errno == EINTR { continue }
                if written < 0 && errno == ENOSPC { break }
                try require(written > 0, "Owned filler failed for a reason other than ENOSPC")
                total += Int64(written)
            }
        }
        let flushed = Darwin.fsync(fd)
        try require(flushed == 0 || errno == ENOSPC, "Owned filler could not flush")
        return total
    }

    static func main() {
        let arguments = CommandLine.arguments
        if arguments.count == 4 && arguments[1] == "--test-interrupted-rebuild" {
            var options = EnginePartialRecovery.TestOptions()
            options.forceUnsupportedRename = true
            // Parent waits for the fsynced progress record and then sends
            // SIGKILL. No production CLI exposes this test-only Swift hook.
            options.afterDurableProgress = { _ = Darwin.raise(SIGSTOP) }
            do {
                _ = try EnginePartialRecovery.testApply(plan: URL(fileURLWithPath: arguments[2]),
                                                       receipt: URL(fileURLWithPath: arguments[3]), options: options)
            } catch { print("Unexpected interruption child failure: \(error)") }
            Darwin.exit(2)
        }
        if arguments.count >= 3, arguments[2].hasPrefix("/") {
            fixtureBase = URL(fileURLWithPath: arguments[2], isDirectory: true)
        }
        test("Preview hashes a locked partial without changing flags, contents or names") {
            let fixture = try Fixture(lockSource: true)
            let sourceFlags = try flags(fixture.original)
            let partialFlags = try flags(fixture.partial)
            let result = try fixture.preview()
            try require(count(result, "ready") == 1, "Expected one verified candidate")
            try require(result["sourceRoot"] as? String == fixture.source.path, "Missing source path")
            try require(result["destinationRoot"] as? String == fixture.destination.path, "Missing destination path")
            try require(try flags(fixture.original) == sourceFlags, "Preview changed source flags")
            try require(try flags(fixture.partial) == partialFlags, "Preview changed partial flags")
            try require(!FileManager.default.fileExists(atPath: fixture.final.path), "Preview renamed a file")
            try fixture.assertPartialUnchanged()
        }
        test("Apply restores the verified filename and preserves source and other flags") {
            let fixture = try Fixture(lockSource: true)
            let sourceFlags = try flags(fixture.original)
            _ = try fixture.preview()
            let result = try fixture.apply()
            try require(count(result, "recovered") == 1 && count(result, "failed") == 0, "Recovery failed")
            try require(!FileManager.default.fileExists(atPath: fixture.partial.path), "Temporary name remained")
            try require(try Data(contentsOf: fixture.final) == bytes, "Recovered content mismatch")
            try require(try Data(contentsOf: fixture.original) == bytes, "Source content changed")
            try require(try flags(fixture.original) == sourceFlags, "Source flag changed")
            try require(try flags(fixture.final) == UInt32(UF_NODUMP), "Recovery changed unrelated flags")
            let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.receipt)) as? [String: Any]
            try require(receipt?["finishedAt"] is String, "No complete receipt")
        }
        test("Direct-local copy and move reports use the same verified recovery") {
            for mode in ["copy", "move"] {
                let fixture = try Fixture(mode: mode)
                try require(count(try fixture.preview(), "ready") == 1, "Rejected \(mode)")
                try require(count(try fixture.apply(), "recovered") == 1, "Failed \(mode)")
                try require(try Data(contentsOf: fixture.original) == bytes, "Recovery touched source for \(mode)")
            }
        }
        test("A directly selected file stays within its report scope") {
            let fixture = try Fixture()
            var rows = fixture.rows(mode: "copy")
            var configuration = rows[0]["configuration"] as! [String: Any]
            var request = configuration["request"] as! [String: Any]
            request["source"] = ["remote": NSNull(), "path": fixture.original.deletingLastPathComponent().path]
            request["destination"] = ["remote": NSNull(), "path": fixture.final.deletingLastPathComponent().path]
            request["selection"] = [["name": "book.txt", "isDir": false]]
            configuration["request"] = request
            rows[0]["configuration"] = configuration
            rows[1]["path"] = "book.txt"
            rows[2]["path"] = "book.txt.1234abcd.partial"
            rows[2]["object"] = "book.txt.1234abcd.partial"
            try fixture.writeRows(rows)
            try require(count(try fixture.preview(), "ready") == 1, "Direct-file scope rejected")
            try require(count(try fixture.apply(), "recovered") == 1, "Direct-file recovery failed")
        }
        test("Same-size content mismatch is skipped without unlocking") {
            let fixture = try Fixture()
            try setFlags(fixture.partial, 0)
            try Data(repeating: 120, count: bytes.count).write(to: fixture.partial)
            try setFlags(fixture.partial, UInt32(UF_IMMUTABLE))
            let before = try Data(contentsOf: fixture.partial)
            try require(count(try fixture.preview(), "mismatch") == 1, "Hash mismatch was accepted")
            try require(count(try fixture.apply(), "skipped") == 1, "Mismatch was not skipped")
            try require(try Data(contentsOf: fixture.partial) == before, "Mismatch content changed")
            try require(try flags(fixture.partial) & UInt32(UF_IMMUTABLE) != 0, "Mismatch was unlocked")
        }
        test("Source changed after preview is refused") {
            let fixture = try Fixture()
            _ = try fixture.preview()
            let handle = try FileHandle(forWritingTo: fixture.original)
            try handle.write(contentsOf: Data(repeating: 121, count: bytes.count))
            try handle.close()
            let result = try fixture.apply()
            try require(count(result, "failed") == 1 && count(result, "recovered") == 0, "Changed source accepted")
            try fixture.assertPartialUnchanged()
        }
        test("Partial changed after preview is refused") {
            let fixture = try Fixture()
            _ = try fixture.preview()
            try setFlags(fixture.partial, 0)
            try Data(repeating: 122, count: bytes.count).write(to: fixture.partial)
            try setFlags(fixture.partial, UInt32(UF_IMMUTABLE))
            let result = try fixture.apply()
            try require(count(result, "failed") == 1, "Changed partial accepted")
            try require(try flags(fixture.partial) & UInt32(UF_IMMUTABLE) != 0, "Changed partial unlocked")
            try require(!FileManager.default.fileExists(atPath: fixture.final.path), "Changed partial renamed")
        }
        test("Existing final name is never overwritten") {
            let fixture = try Fixture()
            let sentinel = Data("Existing final contents".utf8)
            try sentinel.write(to: fixture.final)
            try require(count(try fixture.preview(), "existing") == 1, "Final conflict missed")
            try require(count(try fixture.apply(), "skipped") == 1, "Final conflict not skipped")
            try require(try Data(contentsOf: fixture.final) == sentinel, "Existing final overwritten")
            try fixture.assertPartialUnchanged()
        }
        test("A final file created after preview remains untouched") {
            let fixture = try Fixture()
            _ = try fixture.preview()
            let sentinel = Data("Created after preview".utf8)
            try sentinel.write(to: fixture.final)
            try require(count(try fixture.apply(), "skipped") == 1, "New conflict not skipped")
            try require(try Data(contentsOf: fixture.final) == sentinel, "New final overwritten")
            try fixture.assertPartialUnchanged()
        }
        test("Atomic rename collision restores original flags through the held descriptor") {
            let fixture = try Fixture()
            let sentinel = Data("Atomic destination sentinel".utf8)
            try sentinel.write(to: fixture.final)
            let before = try flags(fixture.partial)
            try rejects {
                try EnginePartialRecovery.testAtomicCommit(directory: fixture.partial.deletingLastPathComponent(),
                                                           temporaryName: fixture.partial.lastPathComponent,
                                                           finalName: fixture.final.lastPathComponent)
            }
            try require(try flags(fixture.partial) == before, "Failed rename did not restore flags")
            try require(try Data(contentsOf: fixture.final) == sentinel, "Atomic rename overwrote a file")
            try fixture.assertPartialUnchanged()
        }
        test("Unsupported exclusive rename rebuilds verified content while retaining partial flags and modification time") {
            let fixture = try Fixture(lockSource: true,
                                      modificationDate: Date(timeIntervalSince1970: 1_700_000_000.125))
            let sourceFlags = try flags(fixture.original)
            let partialFlags = try flags(fixture.partial)
            let sourceTime = try modificationTime(fixture.original)
            _ = try fixture.preview()
            var options = EnginePartialRecovery.TestOptions()
            options.forceUnsupportedRename = true
            let result = try fixture.apply(options: options)
            try require(count(result, "recovered") == 1 && count(result, "rebuilt") == 1 &&
                        count(result, "renamed") == 0 && count(result, "retainedPartials") == 1,
                        "Exclusive rebuild counts differ: \(result)")
            let item = outcomes(result).first ?? [:]
            try require(item["method"] as? String == "verified-exclusive-copy" &&
                        item["partialRetained"] as? Bool == true &&
                        (item["renameErrno"] as? NSNumber)?.int32Value == ENOTSUP,
                        "Rebuild hid its non-atomic method or precise errno")
            try require(try Data(contentsOf: fixture.final) == bytes &&
                        Data(contentsOf: fixture.partial) == bytes && Data(contentsOf: fixture.original) == bytes,
                        "Rebuild content differs")
            try require(try flags(fixture.original) == sourceFlags && flags(fixture.partial) == partialFlags,
                        "Rebuild changed source or retained partial flags")
            try require(try flags(fixture.final) & UInt32(UF_IMMUTABLE) == 0, "New final inherited immutable flags")
            try require(try modificationTime(fixture.final) == sourceTime, "Rebuild did not preserve APFS modification time")
            let events = try journalEvents(fixture.receipt)
            let names = events.compactMap { $0["event"] as? String }
            try require(names == ["intent", "rebuild-intent", "rebuild-created", "rebuild-progress", "outcome", "finished"],
                        "Rebuild did not persist intent, identity, progress and outcome")
            try require((events.first { $0["event"] as? String == "rebuild-created" }?["outcome"] as? [String: Any])?["status"] as? String == "failed-new-output",
                        "An unverified new output was prematurely marked recovered")
        }
        test("Exclusive rebuild collision never opens or overwrites an existing final") {
            let fixture = try Fixture(lockSource: true)
            _ = try fixture.preview()
            let sentinel = Data("Created between validation and exclusive open".utf8)
            let before = try flags(fixture.partial)
            var options = EnginePartialRecovery.TestOptions()
            options.forceUnsupportedRename = true
            options.beforeExclusiveCreate = { try sentinel.write(to: fixture.final) }
            let result = try fixture.apply(options: options)
            let item = outcomes(result).first ?? [:]
            try require(count(result, "recovered") == 0 && count(result, "skipped") == 1 &&
                        (item["errorCode"] as? NSNumber)?.int32Value == EEXIST && item["newOutput"] == nil,
                        "O_EXCL did not reject the competing final: \(result)")
            try require(try Data(contentsOf: fixture.final) == sentinel && flags(fixture.partial) == before,
                        "Exclusive collision changed final content or original partial flags")
            try fixture.assertPartialUnchanged()
        }
        test("A killed rebuild retains a durable incomplete-output journal and never reports recovery") {
            let payload = Data(repeating: 83, count: 3 * 1024 * 1024)
            let fixture = try Fixture(lockSource: true, contents: payload)
            let sourceFlags = try flags(fixture.original)
            let partialFlags = try flags(fixture.partial)
            _ = try fixture.preview()
            let child = Process()
            let finished = DispatchSemaphore(value: 0)
            let childLog = fixture.output.appendingPathComponent("interruption-child.log")
            try Data().write(to: childLog)
            let childOutput = try FileHandle(forWritingTo: childLog)
            defer { try? childOutput.close() }
            child.executableURL = URL(fileURLWithPath: arguments[0])
            child.arguments = ["--test-interrupted-rebuild", fixture.plan.path, fixture.receipt.path]
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = childOutput
            child.standardError = childOutput
            child.terminationHandler = { _ in finished.signal() }
            try child.run()
            var progressSeen = false
            let deadline = Date().addingTimeInterval(20)
            while child.isRunning && Date() < deadline {
                if let events = try? journalEvents(fixture.receipt),
                   events.contains(where: { $0["event"] as? String == "rebuild-progress" }) {
                    progressSeen = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
            if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
            let exited = finished.wait(timeout: .now() + 3) == .success
            let childText = String(decoding: try Data(contentsOf: childLog), as: UTF8.self)
            try require(progressSeen && exited && child.terminationReason == .uncaughtSignal,
                        "Interruption child did not reach a durable progress checkpoint and stop: \(childText.prefix(2000))")
            let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.receipt)) as! [String: Any]
            try require(count(receipt, "recovered") == 0 && receipt["finishedAt"] == nil,
                        "Interrupted operation claimed a completed recovery")
            let events = try journalEvents(fixture.receipt)
            let pending = events.last?["outcome"] as? [String: Any] ?? [:]
            try require(events.last?["event"] as? String == "rebuild-progress" &&
                        pending["status"] as? String == "failed-new-output" && pending["newOutput"] != nil &&
                        (pending["bytesWritten"] as? NSNumber)?.intValue == 1024 * 1024,
                        "Interrupted output has no durable identity and progress")
            let newBytes = try Data(contentsOf: fixture.final)
            try require(newBytes == payload.prefix(newBytes.count) && newBytes.count == 1024 * 1024,
                        "Interrupted final was not retained as a known incomplete output")
            try require(try Data(contentsOf: fixture.original) == payload && Data(contentsOf: fixture.partial) == payload &&
                        flags(fixture.original) == sourceFlags && flags(fixture.partial) == partialFlags,
                        "Interrupted rebuild changed original data or flags")
            try rejects {
                _ = try EnginePartialRecovery.cleanup(receipt: fixture.receipt,
                    result: fixture.output.appendingPathComponent("interrupted-cleanup.json"))
            }
            print("PARTIAL_RECOVERY_INTERRUPTION: {\"newOutputIncomplete\":true,\"partialRetained\":true,\"recovered\":0,\"durableProgress\":true}")
        }
        test("Real ExFAT ENOSPC preserves original partial and reports a failed new output") {
            let image = try CardImage(format: "ExFAT", fileSystem: "exfat")
            let payload = Data(repeating: 83, count: 8 * 1024 * 1024)
            do {
                try image.attach()
                do {
                    let fixture = try Fixture(lockSource: true, destinationParent: image.mount,
                                              partialExtraFlags: 0, contents: payload)
                    let sourceFlags = try flags(fixture.original)
                    let partialFlags = try flags(fixture.partial)
                    _ = try fixture.preview()
                    let filled = try fillOwnedImage(image)
                    // ENOSPC while extending the filler does not prove a
                    // second tiny file cannot fit. Query after filler close,
                    // then require a payload larger than the remaining space.
                    let mountFD = Darwin.open(image.mount.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard mountFD >= 0 else { throw Failure(description: "Cannot inspect owned ExFAT free space") }
                    defer { Darwin.close(mountFD) }
                    var space = statfs()
                    try require(Darwin.fstatfs(mountFD, &space) == 0 && space.f_bsize > 0,
                                "Cannot measure owned ExFAT free space after filler close")
                    let available = UInt64(space.f_bavail) * UInt64(space.f_bsize)
                    print("PARTIAL_RECOVERY_ENOSPC_SETUP: {\"payloadBytes\":\(payload.count),\"availableBytesAfterFill\":\(available),\"filledBytes\":\(filled)}")
                    try require(available < UInt64(payload.count),
                                "ENOSPC fixture has \(available) bytes available for a \(payload.count)-byte payload")
                    var options = EnginePartialRecovery.TestOptions()
                    options.forceUnsupportedRename = true
                    let result = try fixture.apply(options: options)
                    let item = outcomes(result).first ?? [:]
                    try require(count(result, "recovered") == 0 && count(result, "failed") == 1 &&
                                count(result, "failedNewOutputs") == 1 &&
                                item["status"] as? String == "failed-new-output" &&
                                (item["errorCode"] as? NSNumber)?.int32Value == ENOSPC && item["newOutput"] != nil,
                                "Full ExFAT did not return a retained ENOSPC output: \(result)")
                    try require(try Data(contentsOf: fixture.original) == payload && Data(contentsOf: fixture.partial) == payload &&
                                flags(fixture.original) == sourceFlags && flags(fixture.partial) == partialFlags,
                                "ENOSPC changed original contents or flags")
                    try require(FileManager.default.fileExists(atPath: fixture.final.path), "Failed new output was silently deleted")
                    let events = try journalEvents(fixture.receipt)
                    let finalOutcome = events.first { $0["event"] as? String == "outcome" }?["outcome"] as? [String: Any]
                    try require(finalOutcome?["status"] as? String == "failed-new-output", "ENOSPC receipt omitted the incomplete new output")
                    let cleanup = try EnginePartialRecovery.cleanup(receipt: fixture.receipt,
                        result: fixture.output.appendingPathComponent("failed-output-cleanup.json"))
                    try require(count(cleanup, "removed") == 0 && count(cleanup, "skipped") == 1,
                                "Cleanup accepted an unverified new output")
                    try require(try Data(contentsOf: fixture.partial) == payload && flags(fixture.partial) == partialFlags,
                                "Refused cleanup changed the retained ENOSPC partial")
                    print("PARTIAL_RECOVERY_ENOSPC: {\"actualErrno\":\(ENOSPC),\"payloadBytes\":\(payload.count),\"availableBytesAfterFill\":\(available),\"filledBytes\":\(filled),\"newOutputRetained\":true,\"partialRetained\":true,\"recovered\":0,\"cleanupRefused\":true}")
                }
                try image.close()
            } catch {
                do { try image.close() }
                catch { throw Failure(description: "ENOSPC test failed and its owned image could not detach: \(error)") }
                throw error
            }
        }
        test("Receipt-bound cleanup removes only the verified retained partial") {
            let fixture = try Fixture(lockSource: true)
            let sourceFlags = try flags(fixture.original)
            let unrelated = fixture.destination.appendingPathComponent("unlisted.txt.87654321.partial")
            try bytes.write(to: unrelated)
            try setFlags(unrelated, UInt32(UF_IMMUTABLE))
            _ = try fixture.preview()
            var options = EnginePartialRecovery.TestOptions()
            options.forceUnsupportedRename = true
            let rebuilt = try fixture.apply(options: options)
            try require(count(rebuilt, "rebuilt") == 1, "Cleanup fixture did not rebuild")
            let finalFlags = try flags(fixture.final)
            let finalTime = try modificationTime(fixture.final)
            let result = try EnginePartialRecovery.cleanup(receipt: fixture.receipt,
                result: fixture.output.appendingPathComponent("cleanup.json"))
            try require(count(result, "removed") == 1 && count(result, "failed") == 0,
                        "Receipt-bound cleanup failed: \(result)")
            try require(!FileManager.default.fileExists(atPath: fixture.partial.path), "Verified partial was not removed")
            try require(try Data(contentsOf: fixture.final) == bytes && Data(contentsOf: fixture.original) == bytes &&
                        flags(fixture.original) == sourceFlags && flags(fixture.final) == finalFlags &&
                        modificationTime(fixture.final) == finalTime,
                        "Cleanup changed source or reconstructed final")
            try require(try Data(contentsOf: unrelated) == bytes && flags(unrelated) & UInt32(UF_IMMUTABLE) != 0,
                        "Cleanup touched an unlisted partial")
            let events = try journalEvents(fixture.output.appendingPathComponent("cleanup.json"))
            try require(events.compactMap { $0["event"] as? String } == ["cleanup-intent", "outcome", "finished"],
                        "Cleanup did not persist intent and result")
        }
        test("Cleanup refuses changes to the source, retained partial or reconstructed final") {
            for changed in ["source", "partial", "final"] {
                let fixture = try Fixture(lockSource: true)
                _ = try fixture.preview()
                var options = EnginePartialRecovery.TestOptions()
                options.forceUnsupportedRename = true
                try require(count(try fixture.apply(options: options), "rebuilt") == 1, "Change fixture did not rebuild")
                let target = changed == "source" ? fixture.original : changed == "partial" ? fixture.partial : fixture.final
                let previousFlags = try flags(target)
                try setFlags(target, previousFlags & ~UInt32(UF_IMMUTABLE))
                try Data(repeating: 71, count: bytes.count).write(to: target)
                try setFlags(target, previousFlags)
                let before = try Data(contentsOf: fixture.partial)
                let partialFlags = try flags(fixture.partial)
                let result = try EnginePartialRecovery.cleanup(receipt: fixture.receipt,
                    result: fixture.output.appendingPathComponent("changed-cleanup.json"))
                try require(count(result, "removed") == 0 && count(result, "failed") == 1,
                            "Cleanup accepted a changed \(changed)")
                try require(try Data(contentsOf: fixture.partial) == before && flags(fixture.partial) == partialFlags,
                            "Failed cleanup changed the retained partial")
            }
        }
        test("Cleanup rejects out-of-scope receipts and forged reconstructed-file identities") {
            for change in ["candidate", "identity"] {
                let fixture = try Fixture(lockSource: true)
                _ = try fixture.preview()
                var options = EnginePartialRecovery.TestOptions()
                options.forceUnsupportedRename = true
                _ = try fixture.apply(options: options)
                var receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.receipt)) as! [String: Any]
                var items = receipt["items"] as! [[String: Any]]
                if change == "candidate" {
                    var candidate = items[0]["candidate"] as! [String: Any]
                    candidate["temporaryRelativePath"] = "outside.txt.87654321.partial"
                    items[0]["candidate"] = candidate
                } else {
                    var file = items[0]["newOutput"] as! [String: Any]
                    var node = file["node"] as! [String: Any]
                    node["inode"] = 123456789
                    file["node"] = node
                    items[0]["newOutput"] = file
                }
                receipt["items"] = items
                try JSONSerialization.data(withJSONObject: receipt).write(to: fixture.receipt)
                try rejects {
                    _ = try EnginePartialRecovery.cleanup(receipt: fixture.receipt,
                        result: fixture.output.appendingPathComponent("forged-cleanup.json"))
                }
                try fixture.assertPartialUnchanged()
                try require(try Data(contentsOf: fixture.final) == bytes, "Forged receipt changed final data")
            }
        }
        test("A hard-linked partial is blocked") {
            let fixture = try Fixture()
            try setFlags(fixture.partial, 0)
            let link = fixture.destination.appendingPathComponent("linked-copy")
            try FileManager.default.linkItem(at: fixture.partial, to: link)
            try setFlags(fixture.partial, UInt32(UF_IMMUTABLE))
            try require(count(try fixture.preview(), "blocked") == 1, "Hard link was accepted")
            try require(count(try fixture.apply(), "skipped") == 1, "Hard link was not skipped")
            try fixture.assertPartialUnchanged()
        }
        test("Source file and intermediate directory symlinks are blocked") {
            do {
                let fixture = try Fixture()
                let actual = fixture.source.appendingPathComponent("actual.txt")
                try FileManager.default.moveItem(at: fixture.original, to: actual)
                try FileManager.default.createSymbolicLink(at: fixture.original, withDestinationURL: actual)
                try require(count(try fixture.preview(), "blocked") == 1, "Source symlink followed")
                try fixture.assertPartialUnchanged()
            }
            do {
                let fixture = try Fixture()
                let old = fixture.source.appendingPathComponent("books")
                let actual = fixture.source.appendingPathComponent("actual-books")
                try FileManager.default.moveItem(at: old, to: actual)
                try FileManager.default.createSymbolicLink(at: old, withDestinationURL: actual)
                try require(count(try fixture.preview(), "blocked") == 1, "Directory symlink followed")
                try fixture.assertPartialUnchanged()
            }
        }
        test("Partial and root symlinks are refused without following them") {
            do {
                let fixture = try Fixture()
                try setFlags(fixture.partial, 0)
                try FileManager.default.removeItem(at: fixture.partial)
                try FileManager.default.createSymbolicLink(at: fixture.partial, withDestinationURL: fixture.original)
                try require(count(try fixture.preview(), "blocked") == 1, "Partial symlink followed")
                try require(try Data(contentsOf: fixture.original) == bytes, "Symlink source modified")
            }
            do {
                let fixture = try Fixture()
                let alias = fixture.root.appendingPathComponent("source-alias")
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.source)
                var rows = fixture.rows()
                var configuration = rows[0]["configuration"] as! [String: Any]
                var request = configuration["request"] as! [String: Any]
                request["source"] = ["remote": NSNull(), "path": alias.path]
                configuration["request"] = request
                rows[0]["configuration"] = configuration
                try fixture.writeRows(rows)
                try rejects { _ = try fixture.preview() }
                try fixture.assertPartialUnchanged()
            }
        }
        test("Only report-listed partials are touched") {
            let fixture = try Fixture()
            let unlisted = fixture.destination.appendingPathComponent("books/unlisted.txt.deadbeef.partial")
            try bytes.write(to: unlisted)
            try setFlags(unlisted, UInt32(UF_IMMUTABLE))
            try require(count(try fixture.preview(), "ready") == 1, "Unlisted partial entered plan")
            _ = try fixture.apply()
            try require(try flags(unlisted) & UInt32(UF_IMMUTABLE) != 0, "Unlisted partial unlocked")
            try require(try Data(contentsOf: unlisted) == bytes, "Unlisted partial changed")
        }
        test("Invalid JSON, traversal, out-of-scope and remote reports are refused") {
            do {
                let fixture = try Fixture()
                try Data("{invalid json}\n".utf8).write(to: fixture.report)
                try rejects { _ = try fixture.preview() }
                try fixture.assertPartialUnchanged()
            }
            for badPath in ["../book.txt", "outside/book.txt"] {
                let fixture = try Fixture()
                var rows = fixture.rows()
                rows[1]["path"] = badPath
                try fixture.writeRows(rows)
                try rejects { _ = try fixture.preview() }
                try fixture.assertPartialUnchanged()
            }
            do {
                let fixture = try Fixture()
                var rows = fixture.rows()
                var configuration = rows[0]["configuration"] as! [String: Any]
                var request = configuration["request"] as! [String: Any]
                request["source"] = ["remote": "remote", "path": fixture.source.path]
                configuration["request"] = request
                rows[0]["configuration"] = configuration
                try fixture.writeRows(rows)
                try rejects { _ = try fixture.preview() }
                try fixture.assertPartialUnchanged()
            }
        }
        test("Overlapping roots and outputs inside card trees are refused") {
            do {
                let fixture = try Fixture()
                var rows = fixture.rows()
                var configuration = rows[0]["configuration"] as! [String: Any]
                var request = configuration["request"] as! [String: Any]
                request["destination"] = ["remote": NSNull(), "path": fixture.source.appendingPathComponent("books").path]
                configuration["request"] = request
                rows[0]["configuration"] = configuration
                try fixture.writeRows(rows)
                try rejects { _ = try fixture.preview() }
                try fixture.assertPartialUnchanged()
            }
            do {
                let fixture = try Fixture()
                try rejects {
                    _ = try EnginePartialRecovery.preview(report: fixture.report,
                                                          plan: fixture.destination.appendingPathComponent("plan.json"))
                }
                try require(!FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("plan.json").path),
                            "Created a plan inside the target card tree")
                try fixture.assertPartialUnchanged()
            }
        }
        test("Changed reports and plan-injected paths cannot authorize new targets") {
            do {
                let fixture = try Fixture()
                _ = try fixture.preview()
                let handle = try FileHandle(forWritingTo: fixture.report)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(" \n".utf8))
                try handle.close()
                try rejects { _ = try fixture.apply() }
                try fixture.assertPartialUnchanged()
            }
            do {
                let fixture = try Fixture()
                _ = try fixture.preview()
                var plan = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.plan)) as! [String: Any]
                var items = plan["items"] as! [[String: Any]]
                var candidate = items[0]["candidate"] as! [String: Any]
                candidate["relativePath"] = "books/injected.txt"
                items[0]["candidate"] = candidate
                plan["items"] = items
                try JSONSerialization.data(withJSONObject: plan).write(to: fixture.plan)
                try rejects { _ = try fixture.apply() }
                try fixture.assertPartialUnchanged()
            }
        }
        test("Incomplete or truncated-name mappings are excluded rather than guessed") {
            let fixture = try Fixture()
            var rows = fixture.rows()
            let original = "books/" + String(repeating: "a", count: 150) + ".txt"
            rows[1]["path"] = original
            rows[2]["message"] = "partial file rename failed: rename \(fixture.partial.path) \(fixture.destination.path)/\(original): operation not permitted"
            try fixture.writeRows(rows)
            let result = try fixture.preview()
            try require(count(result, "ready") == 0 && count(result, "blocked") == 1, "Truncated name guessed")
            try require(count(try fixture.apply(), "recovered") == 0, "Excluded mapping recovered")
            try fixture.assertPartialUnchanged()
        }
        test("An existing plan or receipt is not overwritten") {
            let fixture = try Fixture()
            _ = try fixture.preview()
            let originalPlan = try Data(contentsOf: fixture.plan)
            try rejects { _ = try fixture.preview() }
            try require(try Data(contentsOf: fixture.plan) == originalPlan, "Plan overwritten")
            let sentinel = Data("Existing receipt".utf8)
            try sentinel.write(to: fixture.receipt)
            try rejects { _ = try fixture.apply() }
            try require(try Data(contentsOf: fixture.receipt) == sentinel, "Receipt overwritten")
            try fixture.assertPartialUnchanged()
        }
        test("Built Mac App CLI previews and applies without entering the GUI route") {
            guard arguments.count == 4, arguments[3].hasPrefix("/"),
                  FileManager.default.isExecutableFile(atPath: arguments[3]) else {
                throw Failure(description: "Pass rclone path, test work directory and built Mac App executable")
            }
            let executable = URL(fileURLWithPath: arguments[3])
            let fixture = try Fixture(lockSource: true)
            let sourceFlags = try flags(fixture.original)
            let partialFlags = try flags(fixture.partial)
            let preview = try appCLI(executable,
                arguments: ["--repair-local-partials", "preview", "--report", fixture.report.path,
                            "--plan", fixture.plan.path], fixture: fixture, label: "preview")
            try require(count(preview, "ready") == 1, "App CLI preview did not verify the fixture")
            try require(try flags(fixture.partial) == partialFlags, "App CLI preview changed flags")
            try fixture.assertPartialUnchanged()
            let result = try appCLI(executable,
                arguments: ["--repair-local-partials", "apply", "--plan", fixture.plan.path,
                            "--receipt", fixture.receipt.path], fixture: fixture, label: "apply")
            try require(count(result, "recovered") == 1 && count(result, "failed") == 0,
                        "App CLI apply did not recover the fixture")
            try require(try Data(contentsOf: fixture.final) == bytes, "App CLI changed recovered bytes")
            try require(try Data(contentsOf: fixture.original) == bytes, "App CLI changed source bytes")
            try require(try flags(fixture.original) == sourceFlags, "App CLI changed source flags")
            try require(try flags(fixture.final) == UInt32(UF_NODUMP), "App CLI changed unrelated flags")
            let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.receipt)) as? [String: Any]
            try require(receipt?["finishedAt"] is String, "App CLI did not write its final receipt")
            let journal = URL(fileURLWithPath: fixture.receipt.path + ".journal.jsonl")
            let lines = try String(contentsOf: journal, encoding: .utf8).split(separator: "\n")
            let events = try lines.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
            try require(events.contains { $0["event"] as? String == "intent" } &&
                        events.contains { $0["event"] as? String == "outcome" } &&
                        events.last?["event"] as? String == "finished",
                        "App CLI omitted its durable recovery journal")
        }
        for (format, fileSystem) in [("MS-DOS FAT32", "msdos"), ("ExFAT", "exfat")] {
            test("\(format) real-image recovery verifies content and safely handles filesystem rename capability") {
                try require(arguments.count >= 4 && arguments[3].hasPrefix("/"), "Real card CLI test needs the built App executable")
                let executable = URL(fileURLWithPath: arguments[3])
                let image = try CardImage(format: format, fileSystem: fileSystem)
                var verifiedRecovery = false
                var method = ""
                var renameFailure: Int32?
                var verifiedCleanup = false
                var verifiedHash = ""
                do {
                    try image.attach()
                    do {
                        let fixture = try Fixture(lockSource: true, destinationParent: image.mount,
                                                  partialExtraFlags: 0,
                                                  modificationDate: Date(timeIntervalSince1970: 1_700_000_000.125))
                        let sourceFlags = try flags(fixture.original)
                        let partialFlags = try flags(fixture.partial)
                        let sourceTime = try modificationTime(fixture.original)
                        let preview = try appCLI(executable,
                            arguments: ["--repair-local-partials", "preview", "--report", fixture.report.path,
                                        "--plan", fixture.plan.path], fixture: fixture, label: "card-preview")
                        try require(count(preview, "ready") == 1, "Card partial did not pass full preview")
                        verifiedHash = try RBNSHA256.hex(Data(contentsOf: fixture.original))
                        let previewItems = preview["items"] as! [[String: Any]]
                        try require(previewItems[0]["sha256"] as? String == verifiedHash, "Card SHA-256 was not verified")
                        try require(try flags(fixture.partial) == partialFlags, "Card preview changed flags")
                        let result = try appCLI(executable,
                            arguments: ["--repair-local-partials", "apply", "--plan", fixture.plan.path,
                                        "--receipt", fixture.receipt.path], fixture: fixture, label: "card-apply")
                        verifiedRecovery = count(result, "recovered") == 1 && count(result, "failed") == 0
                        try require(verifiedRecovery, "Card recovery did not produce a verified final: \(result)")
                        let item = outcomes(result).first ?? [:]
                        method = item["method"] as? String ?? ""
                        renameFailure = (item["renameErrno"] as? NSNumber)?.int32Value
                        try require(try RBNSHA256.hex(Data(contentsOf: fixture.final)) == verifiedHash,
                                    "Recovered card bytes changed")
                        if method == "atomic-rename" {
                            try require(count(result, "renamed") == 1 && count(result, "rebuilt") == 0,
                                        "Atomic result was classified as a rebuild")
                            try require(try flags(fixture.final) == partialFlags & ~UInt32(UF_IMMUTABLE),
                                        "Recovered card flags differ")
                            try require(!FileManager.default.fileExists(atPath: fixture.partial.path), "Card partial name remains")
                        } else {
                            try require(method == "verified-exclusive-copy" && count(result, "rebuilt") == 1 &&
                                        count(result, "renamed") == 0 && count(result, "retainedPartials") == 1 &&
                                        (renameFailure == ENOTSUP || renameFailure == ENOSYS),
                                        "Rebuild did not preserve its precise method and errno: \(result)")
                            try require(try flags(fixture.partial) == partialFlags, "Rebuild did not retain partial flags")
                            try require(try RBNSHA256.hex(Data(contentsOf: fixture.partial)) == verifiedHash,
                                        "Rebuild changed retained card contents")
                            try require(try flags(fixture.final) & UInt32(UF_IMMUTABLE) == 0,
                                        "Rebuilt final inherited immutable protection")
                        }
                        let finalTime = try modificationTime(fixture.final)
                        try require(abs(finalTime - sourceTime) <= (fileSystem == "msdos" ? 2 : 0.01),
                                    "Recovered card modification time would cause avoidable recopying")
                        try require(try flags(fixture.original) == sourceFlags &&
                                    RBNSHA256.hex(Data(contentsOf: fixture.original)) == verifiedHash,
                                    "Card recovery changed source protection or content")
                        let cleanup = try appCLI(executable,
                            arguments: ["--repair-local-partials", "cleanup", "--receipt", fixture.receipt.path,
                                        "--result", fixture.output.appendingPathComponent("app-card-cleanup.json").path],
                            fixture: fixture, label: "card-cleanup")
                        verifiedCleanup = count(cleanup, "failed") == 0 &&
                            count(cleanup, "removed") == (method == "verified-exclusive-copy" ? 1 : 0) &&
                            count(cleanup, "skipped") == (method == "atomic-rename" ? 1 : 0)
                        try require(verifiedCleanup && !FileManager.default.fileExists(atPath: fixture.partial.path),
                                    "Built App CLI did not complete receipt-bound card cleanup: \(cleanup)")
                        try require(try RBNSHA256.hex(Data(contentsOf: fixture.original)) == verifiedHash &&
                                    RBNSHA256.hex(Data(contentsOf: fixture.final)) == verifiedHash &&
                                    flags(fixture.original) == sourceFlags,
                                    "Built App CLI cleanup changed source or final contents")
                    }
                    do {
                        // Exercise exclusive rebuilding and separately
                        // confirmed cleanup even if this OS can rename FAT.
                        let fixture = try Fixture(lockSource: true, destinationParent: image.mount, partialExtraFlags: 0)
                        let sourceFlags = try flags(fixture.original)
                        let preview = try fixture.preview()
                        var options = EnginePartialRecovery.TestOptions()
                        options.forceUnsupportedRename = true
                        let rebuilt = try fixture.apply(options: options)
                        if fileSystem == "msdos" && count(rebuilt, "rebuilt") != 1 {
                            var diagnosis: [String: Any] = ["fileSystem": fileSystem, "format": format,
                                                          "preview": preview, "receipt": rebuilt]
                            do { diagnosis["journal"] = try journalEvents(fixture.receipt) }
                            catch { diagnosis["journalReadError"] = String(describing: error) }
                            print("PARTIAL_RECOVERY_FORCED_REBUILD_DIAGNOSTIC: " +
                                  String(decoding: try JSONSerialization.data(withJSONObject: diagnosis, options: [.sortedKeys]),
                                         as: UTF8.self))
                        }
                        try require(count(rebuilt, "rebuilt") == 1,
                                    "Card exclusive-copy cleanup fixture did not rebuild: \(rebuilt)")
                        let result = try EnginePartialRecovery.cleanup(receipt: fixture.receipt,
                            result: fixture.output.appendingPathComponent("card-cleanup.json"))
                        verifiedCleanup = verifiedCleanup && count(result, "removed") == 1 && count(result, "failed") == 0
                        try require(verifiedCleanup && !FileManager.default.fileExists(atPath: fixture.partial.path),
                                    "Card receipt-bound cleanup failed: \(result)")
                        try require(try Data(contentsOf: fixture.original) == bytes && Data(contentsOf: fixture.final) == bytes &&
                                    flags(fixture.original) == sourceFlags,
                                    "Card cleanup changed source or final contents")
                    }
                    do {
                        let fixture = try Fixture(destinationParent: image.mount, partialExtraFlags: 0)
                        let sentinel = Data("Card destination must not be replaced".utf8)
                        try sentinel.write(to: fixture.final)
                        let before = try flags(fixture.partial)
                        try rejects {
                            try EnginePartialRecovery.testAtomicCommit(directory: fixture.partial.deletingLastPathComponent(),
                                                                       temporaryName: fixture.partial.lastPathComponent,
                                                                       finalName: fixture.final.lastPathComponent)
                        }
                        try require(try Data(contentsOf: fixture.final) == sentinel, "Card collision overwrote final content")
                        try require(try flags(fixture.partial) == before, "Card collision did not restore partial flags")
                    }
                    do {
                        let fixture = try Fixture(destinationParent: image.mount, partialExtraFlags: 0)
                        try Data().write(to: fixture.original)
                        try setFlags(fixture.partial, 0)
                        try Data().write(to: fixture.partial)
                        try setFlags(fixture.partial, UInt32(UF_IMMUTABLE))
                        let before = try flags(fixture.partial)
                        let preview = try fixture.preview()
                        try require(count(preview, "ready") == 0 && count(preview, "blocked") == 1,
                                    "A card empty file was treated as having a unique inode")
                        try require(count(try fixture.apply(), "recovered") == 0, "An ambiguous empty file was recovered")
                        try require(try flags(fixture.partial) == before, "Empty card file was unlocked")
                    }
                    try image.close()
                } catch {
                    do { try image.close() }
                    catch { throw Failure(description: "Recovery image test failed and its owned image could not detach: \(error)") }
                    throw error
                }
                var result: [String: Any] = ["fileSystem": fileSystem, "format": format,
                    "verifiedRecovery": verifiedRecovery,
                    "atomicRename": method == "atomic-rename" ? "supported" : "unsupported",
                    "method": method, "verifiedCleanup": verifiedCleanup, "builtAppCLI": true,
                    "sha256": verifiedHash, "sourceUnchanged": true,
                    "modificationTimePreserved": true, "finalCollisionProtected": true, "emptyFilesBlocked": true]
                result["renameErrno"] = renameFailure.map { $0 as Any } ?? NSNull()
                print("PARTIAL_RECOVERY_FILESYSTEM: " +
                      String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
                try require(verifiedRecovery && verifiedCleanup,
                            "\(format) must complete verified recovery and receipt-bound cleanup; safe refusal is not a passing result")
            }
        }
        print("RESULT \(passed) passed, \(failed) failed")
        if failed > 0 { Darwin.exit(1) }
    }
}
#endif
