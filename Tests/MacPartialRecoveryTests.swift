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
             destinationParent: URL? = nil, partialExtraFlags: UInt32 = UInt32(UF_NODUMP)) throws {
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
            try bytes.write(to: original)
            try bytes.write(to: partial)
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

    static func main() {
        let arguments = CommandLine.arguments
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
                let image = try CardImage(format: format, fileSystem: fileSystem)
                var supported = false
                var verifiedHash = ""
                do {
                    try image.attach()
                    do {
                        let fixture = try Fixture(lockSource: true, destinationParent: image.mount,
                                                  partialExtraFlags: 0)
                        let sourceFlags = try flags(fixture.original)
                        let partialFlags = try flags(fixture.partial)
                        let preview = try fixture.preview()
                        try require(count(preview, "ready") == 1, "Card partial did not pass full preview")
                        verifiedHash = try RBNSHA256.hex(Data(contentsOf: fixture.original))
                        let previewItems = preview["items"] as! [[String: Any]]
                        try require(previewItems[0]["sha256"] as? String == verifiedHash, "Card SHA-256 was not verified")
                        try require(try flags(fixture.partial) == partialFlags, "Card preview changed flags")
                        let result = try fixture.apply()
                        supported = count(result, "recovered") == 1
                        if supported {
                            try require(try RBNSHA256.hex(Data(contentsOf: fixture.final)) == verifiedHash,
                                        "Recovered card bytes changed")
                            try require(try flags(fixture.final) == partialFlags & ~UInt32(UF_IMMUTABLE),
                                        "Recovered card flags differ")
                            try require(!FileManager.default.fileExists(atPath: fixture.partial.path), "Card partial name remains")
                        } else {
                            let outcomes = result["items"] as? [[String: Any]] ?? []
                            try require(count(result, "failed") == 1 &&
                                        (outcomes.first?["message"] as? String ?? "").contains("不支援原子且不覆寫"),
                                        "Card recovery failed for an unexpected reason: \(result)")
                            try require(try flags(fixture.partial) == partialFlags, "Unsupported rename did not restore flags")
                            try require(try RBNSHA256.hex(Data(contentsOf: fixture.partial)) == verifiedHash,
                                        "Unsupported rename changed card contents")
                            try require(!FileManager.default.fileExists(atPath: fixture.final.path),
                                        "Unsupported rename created a final file")
                        }
                        try require(try flags(fixture.original) == sourceFlags &&
                                    RBNSHA256.hex(Data(contentsOf: fixture.original)) == verifiedHash,
                                    "Card recovery changed source protection or content")
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
                let result: [String: Any] = ["fileSystem": fileSystem, "format": format,
                    "atomicRecovery": supported ? "supported" : "unsupported-safe-refusal",
                    "sha256": verifiedHash, "sourceUnchanged": true,
                    "finalCollisionProtected": true, "emptyFilesBlocked": true]
                print("PARTIAL_RECOVERY_FILESYSTEM: " +
                      String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
                try require(supported,
                            "\(format) must support verified in-place recovery on this CI macOS; safe refusal is not a passing recovery result")
            }
        }
        print("RESULT \(passed) passed, \(failed) failed")
        if failed > 0 { Darwin.exit(1) }
    }
}
#endif
