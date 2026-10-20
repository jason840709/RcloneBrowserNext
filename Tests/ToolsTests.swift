import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Integration tests for the auxiliary tools. Pass an existing rclone executable
/// and an empty work directory; no cloud account, player or FUSE is installed.
@main struct ToolsTests {
    static var passed = 0
    static var failed = 0
    static var skipped = 0

    static func main() {
        if CommandLine.arguments.dropFirst().first?.hasPrefix("--fixture-player") == true { runFixture("player"); return }
        if let fixture = ProcessInfo.processInfo.environment["RBN_TOOLS_FIXTURE"] { runFixture(fixture); return }
        let arguments = CommandLine.arguments
        let base = URL(fileURLWithPath: arguments.count > 2 ? arguments[2] : NSTemporaryDirectory()).appendingPathComponent("tools-tests-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let ownBinary = URL(fileURLWithPath: arguments[0]).standardizedFileURL.path
            var environment = ProcessInfo.processInfo.environment.filter { !$0.key.uppercased().hasPrefix("RCLONE_") }
            environment["RCLONE_CONFIG"] = base.appendingPathComponent("rclone.conf").path
            let engine = arguments.count > 1 ? arguments[1] : ""
            let real: RcloneTools.Context? = FileManager.default.isExecutableFile(atPath: engine)
                ? RcloneTools.Context(binary: engine, arguments: ["--config", base.appendingPathComponent("rclone.conf").path], environment: environment) : nil
            let root = base.appendingPathComponent("source")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("level1/level2/level3"), withIntermediateDirectories: true)
            try Data("one".utf8).write(to: root.appendingPathComponent("alpha.txt"))
            try Data("two".utf8).write(to: root.appendingPathComponent("name,\"中文\".txt"))
            try Data("three".utf8).write(to: root.appendingPathComponent("line\nbreak.txt"))
            let endpoint = try EngineEndpoint(["remote": NSNull(), "path": root.path])
            let remote = try EngineEndpoint(["remote": "fixture", "path": "folder"])
            func fixture(_ behavior: String) -> RcloneTools.Context {
                var env = environment; env["RBN_TOOLS_FIXTURE"] = behavior
                return RcloneTools.Context(binary: ownBinary, environment: env)
            }

            test("Tree uses real rclone, directories only, bounded depth", available: real != nil) {
                let tree = try RcloneTools.tree(context: real!, endpoint: endpoint, maxDepth: 2)
                let text = tree["text"] as? String ?? ""
                try check(text.contains("level1") && text.contains("level2") && !text.contains("level3"), "wrong tree depth")
                try check(!text.contains("alpha.txt"), "tree contains file")
                try check(tree["truncated"] as? Bool == false, "small tree truncated")
            }
            test("CSV exports true names, size, date and quoted newlines", available: real != nil) {
                let output = base.appendingPathComponent("listing.csv")
                let result = try RcloneTools.exportList(context: real!, endpoint: endpoint, destination: output)
                let text = try String(contentsOf: output, encoding: .utf8)
                try check(result["count"] as? Int == 3, "CSV record count must count quoted newlines correctly")
                try check(text.hasPrefix("Path,Size,Modified\n"), "header absent")
                try check(text.contains("\"name,\"\"中文\"\".txt\""), "CSV quotes not preserved")
                // The local backend exposes a newline as rclone's reversible
                // U+240A filename encoding, so preserve that official output.
                try check(text.contains("line␊break.txt"), "rclone filename encoding not preserved")
                try check(text.range(of: ",[0-9]+,[0-9]{4}-[0-9]{2}-[0-9]{2}", options: .regularExpression) != nil, "date or bytes absent")
                let multiline = base.appendingPathComponent("multiline.csv")
                let synthetic = try RcloneTools.exportList(context: fixture("csv-multiline"), endpoint: endpoint, destination: multiline)
                try check(synthetic["count"] as? Int == 2, "quoted newlines counted as separate CSV records")
            }
            test("Text export and export inside listed directory", available: real != nil) {
                let source = base.appendingPathComponent("plain")
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
                try Data("one".utf8).write(to: source.appendingPathComponent("quoted ' file.txt"))
                let point = try EngineEndpoint(["remote": NSNull(), "path": source.path])
                let destination = source.appendingPathComponent("files.txt")
                let result = try RcloneTools.exportList(context: real!, endpoint: point, destination: destination, filenamesOnly: true)
                let text = try String(contentsOf: destination, encoding: .utf8)
                try check(result["count"] as? Int == 1 && text == "quoted ' file.txt\n", "export included own staging file")
                try check(!((try FileManager.default.contentsOfDirectory(atPath: source.path)).contains(where: { $0.hasPrefix(".rbn-export-") })), "staging left behind")
            }
            test("Failed export preserves existing report and cleans staging") {
                let destination = base.appendingPathComponent("protected.csv")
                let previous = Data("previous report".utf8); try previous.write(to: destination)
                try mustThrow { _ = try RcloneTools.exportList(context: fixture("failure"), endpoint: endpoint, destination: destination) }
                try check(try Data(contentsOf: destination) == previous, "old report replaced on error")
                try check(!((try FileManager.default.contentsOfDirectory(atPath: base.path)).contains(where: { $0.hasPrefix(".rbn-export-") })), "failed staging left behind")
            }
            test("Export rejects symlink without changing target") {
                let original = base.appendingPathComponent("link-target.txt"), destination = base.appendingPathComponent("symlink.csv")
                try Data("unchanged".utf8).write(to: original)
                try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: original)
                try mustThrow { _ = try RcloneTools.exportList(context: fixture("failure"), endpoint: endpoint, destination: destination) }
                try check(try String(contentsOf: original) == "unchanged", "symlink target changed")
            }
            test("Tree output truncation and input bounds") {
                let tree = try RcloneTools.tree(context: fixture("tree-large"), endpoint: endpoint)
                try check(tree["truncated"] as? Bool == true, "large tree unmarked")
                try check((tree["text"] as? String ?? "").utf8.count == 1024 * 1024, "tree byte limit wrong")
                try mustThrow { _ = try RcloneTools.tree(context: fixture("tree-large"), endpoint: endpoint, maxDepth: 0) }
            }
            test("Public link parses final HTTPS line and rejects unsafe output") {
                let valid = try RcloneTools.publicLink(context: fixture("link-valid"), endpoint: remote, name: "picture.png")
                try check(valid.scheme == "https" && valid.host == "example.invalid", "valid URL lost")
                for invalid in ["link-script", "link-credentials", "link-bad"] {
                    try mustThrow { _ = try RcloneTools.publicLink(context: fixture(invalid), endpoint: remote, name: "picture.png") }
                }
                try mustThrow { _ = try RcloneTools.publicLink(context: fixture("link-valid"), endpoint: endpoint) }
                try mustThrow { _ = try RcloneTools.publicLink(context: fixture("link-valid"), endpoint: remote, name: "../escape") }
            }
            test("Mount option contract cannot enable daemon or unsafe flags") {
                try check(try RcloneTools.validatedMountOptions([]) == ["--vfs-cache-mode", "writes"], "default cache mode")
                try check(try RcloneTools.validatedMountOptions(["--read-only", "--vfs-cache-mode", "full"]) == ["--read-only", "--vfs-cache-mode", "full"], "valid options changed")
                for options in [["--daemon"], ["--allow-other"], ["--vfs-cache-mode", "invalid"], ["--read-only", "--read-only"], ["--vfs-cache-mode"]] {
                    try mustThrow { _ = try RcloneTools.validatedMountOptions(options) }
                }
                let manager = try RcloneTools(workDirectory: base.appendingPathComponent("mount-work"))
                try mustThrow { _ = try manager.startMount(context: fixture("failure"), endpoint: remote, mountPoint: root) }
                try check(!manager.hasActiveSessions, "invalid mount registered")
            }
            test("Real rclone cat streams complete bytes to external process", available: real != nil) {
                let source = base.appendingPathComponent("media"), captured = base.appendingPathComponent("captured.bin")
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
                let content = Data((0..<(1024 * 1024 + 17)).map { UInt8($0 % 251) })
                try content.write(to: source.appendingPathComponent("movie ' 中文.dat"))
                var env = environment; env["RCLONE_CONFIG_PASS"] = "test-only-do-not-forward"
                env["AWS_SECRET_ACCESS_KEY"] = "test-only-cloud-secret"; env["HTTPS_PROXY"] = "https://fixture:secret@example.invalid"
                let context = RcloneTools.Context(binary: engine, arguments: real!.arguments, environment: env)
                let manager = try RcloneTools(workDirectory: base.appendingPathComponent("stream-work"))
                let point = try EngineEndpoint(["remote": NSNull(), "path": source.path])
                let session = try manager.startStream(context: context, endpoint: point, name: "movie ' 中文.dat", player: URL(fileURLWithPath: ownBinary), playerArgs: ["--fixture-player", captured.path])
                let result = try finished(manager, id: session["id"] as! String)
                try check(result["status"] as? String == "completed", "stream did not complete: \(result)")
                try check(try Data(contentsOf: captured) == content, "media pipe bytes changed or missed EOF")
                try check(try String(contentsOf: captured.appendingPathExtension("credential-check")) == "clean", "rclone password leaked to player")
                let json = String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
                try check(!json.contains("test-only-do-not-forward"), "session leaked credentials")
                try manager.shutdown()
            }
            test("Explicit stream stop is stopped, never completed") {
                let manager = try RcloneTools(workDirectory: base.appendingPathComponent("cancel-work"))
                let session = try manager.startStream(context: fixture("stream"), endpoint: remote, name: "large.bin", player: URL(fileURLWithPath: ownBinary), playerArgs: ["--fixture-player-discard"])
                Thread.sleep(forTimeInterval: 0.15)
                let result = try manager.stopSession(session["id"] as! String)
                try check(result["status"] as? String == "stopped" && !manager.hasActiveSessions, "cancellation status incorrect")
            }
            test("Producer and player failures clean up both child processes") {
                for (mode, playerArguments) in [("stream-fail", ["--fixture-player-discard"]), ("stream", ["--fixture-player-fail"])] {
                    let manager = try RcloneTools(workDirectory: base.appendingPathComponent(UUID().uuidString))
                    let session = try manager.startStream(context: fixture(mode), endpoint: remote, name: "data.bin", player: URL(fileURLWithPath: ownBinary), playerArgs: playerArguments)
                    let result = try finished(manager, id: session["id"] as! String)
                    try check(result["status"] as? String == "failed", "failed stream reported success: \(result)")
                    try check(!manager.hasActiveSessions, "orphan session remains")
                }
            }
            test("Shutdown stops active streams; invalid player starts nothing") {
                let manager = try RcloneTools(workDirectory: base.appendingPathComponent("shutdown-work"))
                try mustThrow { _ = try manager.startStream(context: fixture("stream"), endpoint: remote, name: "x", player: base.appendingPathComponent("missing")) }
                try check(manager.listSessions().isEmpty, "invalid player registered session")
                _ = try manager.startStream(context: fixture("stream"), endpoint: remote, name: "x", player: URL(fileURLWithPath: ownBinary), playerArgs: ["--fixture-player-discard"])
                try manager.shutdown()
                try check(!manager.hasActiveSessions && manager.listSessions().first?["status"] as? String == "stopped", "shutdown leaked stream")
            }
        } catch { failed += 1; print("FAIL setup: \(error)") }
        print("\(passed) passed, \(failed) failed, \(skipped) skipped")
        exit(failed == 0 ? 0 : 1)
    }

    static func test(_ name: String, available: Bool = true, body: () throws -> Void) {
        guard available else { skipped += 1; print("SKIP \(name): pass an existing rclone executable to run this test"); return }
        do { try body(); passed += 1; print("PASS \(name)") }
        catch { failed += 1; print("FAIL \(name): \(error)") }
    }
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw EngineError(message) }
    }
    static func mustThrow(_ body: () throws -> Void) throws {
        var threw = false
        do { try body() } catch { threw = true }
        try check(threw, "expected failure")
    }
    static func finished(_ manager: RcloneTools, id: String) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let result = manager.listSessions().first(where: { $0["id"] as? String == id }), result["status"] as? String != "running" { return result }
            Thread.sleep(forTimeInterval: 0.05)
        }
        _ = try? manager.stopSession(id)
        throw EngineError("session never finished")
    }

    static func runFixture(_ mode: String) {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "lsjson", mode.hasPrefix("stream") { print("{\"Name\":\"fixture.bin\",\"IsDir\":false}"); exit(0) }
        if arguments.first == "--fixture-player-fail" { FileHandle.standardError.write(Data("player refused\n".utf8)); exit(7) }
        if arguments.first == "--fixture-player" || arguments.first == "--fixture-player-discard" {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            if arguments.first == "--fixture-player", arguments.count == 2 {
                let destination = URL(fileURLWithPath: arguments[1])
                do {
                    try data.write(to: destination)
                    let clean = ProcessInfo.processInfo.environment.keys.contains {
                        $0.uppercased().hasPrefix("RCLONE_") || $0 == "AWS_SECRET_ACCESS_KEY" || $0.uppercased() == "HTTPS_PROXY"
                    } ? "leaked" : "clean"
                    try clean.write(to: destination.appendingPathExtension("credential-check"), atomically: true, encoding: .utf8)
                } catch { exit(9) }
            }
            exit(0)
        }
        switch mode {
        case "failure":
            FileHandle.standardOutput.write(Data("partial,data\n".utf8))
            FileHandle.standardError.write(Data("fixture declined operation\n".utf8)); exit(12)
        case "tree-large": FileHandle.standardOutput.write(Data(repeating: 65, count: 1024 * 1024 + 65536))
        case "csv-multiline": FileHandle.standardOutput.write(Data("\"line\nbreak.txt\",5,2026-10-20 00:00:00\n\"quotes\"\"x\",7,2026-10-20 00:00:00\n".utf8))
        case "link-valid": print("status\nhttps://example.invalid/share/%E4%B8%AD?test=1")
        case "link-script": print("javascript:alert(1)")
        case "link-credentials": print("https://user:password@example.invalid/share")
        case "link-bad": print("not a URL")
        case "stream-fail": FileHandle.standardError.write(Data("producer failed\n".utf8)); exit(8)
        case "stream":
            let data = Data(repeating: 48, count: 32768)
            for _ in 0..<10000 { FileHandle.standardOutput.write(data); Thread.sleep(forTimeInterval: 0.002) }
        default: exit(13)
        }
        exit(0)
    }
}
