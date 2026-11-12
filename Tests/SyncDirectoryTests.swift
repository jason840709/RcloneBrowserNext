import Foundation

private struct SyncTestFailure: Error, CustomStringConvertible { let description: String }

@main
struct SyncDirectoryTests {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 3 || args.count == 5 else { throw SyncTestFailure(description: "rclone and work directory required") }
        let binary = args[1], work = URL(fileURLWithPath: args[2])
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        if args.count == 5 && args[3] == "--plan-existing" {
            let input = URL(fileURLWithPath: args[4])
            let raw = try Data(contentsOf: input)
            let plan = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
            let source = URL(fileURLWithPath: plan["source"] as! String)
            let target = URL(fileURLWithPath: plan["destination"] as! String)
            var planned: [String] = []
            let count = try EngineLocalSyncDirectories.prune(source: source, destination: target,
                candidates: plan["candidates"] as! [String], maximum: -1, dryRun: true, cancelled: { false },
                record: { path, _ in planned.append(path) })
            let result: [String: Any] = ["dryRun": true, "plannedDirectoryCount": count, "plannedDirectories": planned]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: work.appendingPathComponent("directory-plan.json"))
            print("READ-ONLY DIRECTORY PLAN: \(count) empty source-absent directories; no changes made")
            return
        }
        var failures = 0
        func expect(_ value: @autoclosure () throws -> Bool, _ text: String) throws {
            if try !value() { throw SyncTestFailure(description: text) }
        }
        func directory(_ base: URL, _ name: String) throws -> URL {
            let value = base.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
            return value
        }
        func write(_ base: URL, _ name: String, _ value: String = "fixture") throws {
            let path = base.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(value.utf8).write(to: path)
        }
        func exists(_ base: URL, _ name: String) -> Bool { FileManager.default.fileExists(atPath: base.appendingPathComponent(name).path) }
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        func request(_ from: URL, _ to: URL, mode: String = "sync", dry: Bool = false,
                     options: [String: Any] = [:], selection: [[String: Any]] = []) -> [String: Any] {
            ["source": ["remote": NSNull(), "path": from.path], "destination": ["remote": NSNull(), "path": to.path],
             "mode": mode, "dryRun": dry, "selection": selection,
             "options": EngineTransferOptions.defaults.merging(["retries": 1, "lowLevelRetries": 1]) { _, v in v }.merging(options) { _, v in v }]
        }
        func run(_ area: URL, _ input: [String: Any], injectDirectoryFailure: Bool = false) throws -> [String: Any] {
            var executable = binary
            if injectDirectoryFailure {
                // Real copies, but deterministic partial-sync completion: the
                // NTFS test volume cannot reliably enforce unreadable folders.
                // All probes/listings still run the real rclone unchanged.
                let from = (input["source"] as! [String: Any])["path"] as! String
                let to = (input["destination"] as! [String: Any])["path"] as! String
                let wrapper = area.appendingPathComponent("wrapper-rclone")
                let script = """
                #!/bin/sh
                case " $* " in *" --combined=- "*)
                  case " $* " in *" --dry-run "*) echo '{"level":"error","msg":"error reading source directory: directory not found","object":"kept/unreadable","objectType":"string"}' >&2; exit 1;; esac
                  \(quote(binary)) copy --config=/dev/null --local-no-clone --local-encoding=Raw --create-empty-src-dirs -- \(quote(from)) \(quote(to))
                  echo '{"level":"error","msg":"error reading source directory: directory not found","object":"kept/unreadable","objectType":"string"}' >&2
                  echo '{"level":"error","msg":"not deleting directories as there were IO errors","objectType":"*local.Fs","object":"destination"}' >&2
                  exit 1;;
                *) exec \(quote(binary)) "$@";; esac
                """
                try Data(script.utf8).write(to: wrapper)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
                executable = wrapper.path
            }
            let engine = try RcloneEngine(stateDirectory: area.appendingPathComponent("state"), defaultRcloneDirectory: area.appendingPathComponent("unused-engine"))
            defer { engine.shutdown() }
            _ = try engine.invoke("saveSettings", arguments: [["rclonePath": executable, "autoCheckUpdates": false]])
            let submitted = try engine.invoke("startTransfer", arguments: [input]) as! [String: Any]
            let id = submitted["id"] as! String, deadline = Date().addingTimeInterval(50)
            while Date() < deadline {
                let jobs = try engine.invoke("listJobs", arguments: []) as! [[String: Any]]
                if let job = jobs.first(where: { $0["id"] as? String == id }), EngineJob.terminal.contains(job["status"] as? String ?? "") { return job }
                Thread.sleep(forTimeInterval: 0.03)
            }
            throw SyncTestFailure(description: "job did not terminate")
        }
        func test(_ name: String, _ body: (URL, URL, URL) throws -> Void) {
            do {
                let area = try directory(work, name), from = try directory(area, "source"), to = try directory(area, "target")
                try body(area, from, to)
                print("PASS \(name)")
            } catch { failures += 1; print("FAIL \(name): \(error)") }
        }

        test("literal-local-names") { area, from, to in
            for name in ["quote‛？", "quote‛‛：", "slash／", "fullwidth：？｜＊", "kanaか\u{3099}", "é", "space end "] {
                try write(from, name + "/file‛？.txt", "content for " + name)
            }
            _ = try directory(from, "legitimate-empty")
            let job = try run(area, request(from, to))
            try expect(job["status"] as? String == "completed", "literal-name sync failed: \(job["error"] ?? "unknown")")
            try expect(Set(FileManager.default.contentsOfDirectory(atPath: from.path)) == Set(FileManager.default.contentsOfDirectory(atPath: to.path)), "directory names changed")
            for name in ["quote‛？", "quote‛‛：", "slash／", "fullwidth：？｜＊", "kanaか\u{3099}", "é", "space end "] {
                try expect(Data(contentsOf: from.appendingPathComponent(name + "/file‛？.txt")) == Data(contentsOf: to.appendingPathComponent(name + "/file‛？.txt")), "file name or content changed")
            }
        }

        test("selected-literal-name-with-includes") { area, from, to in
            try write(from, "chosen‛？/photo.txt")
            try write(from, "chosen‛？/skip.bin")
            try write(to, "not-selected/keep.txt")
            let job = try run(area, request(from, to, options: ["include": ["*.txt"]], selection: [["name": "chosen‛？", "isDir": true]]))
            try expect(job["status"] as? String == "completed", "selected source name could not be read: \(job["error"] ?? "unknown")")
            try expect(exists(to, "chosen‛？/photo.txt") && !exists(to, "chosen‛？/skip.bin") && exists(to, "not-selected/keep.txt"), "selection/include intersection changed")
        }

        test("prune-only-orphan-empty-directories-after-error") { area, from, to in
            _ = try directory(from, "kept/unreadable")
            _ = try directory(from, "legitimate-empty")
            try write(to, "kept/unreadable/protected.txt")
            try write(to, "nonempty/not-forced-away.txt")
            _ = try directory(to, "obsolete/deep/empty")
            _ = try directory(to, "old-empty")
            _ = try directory(to, "old‛？")
            let job = try run(area, request(from, to), injectDirectoryFailure: true)
            try expect(job["status"] as? String == "failed", "unreadable source was disguised as successful sync")
            try expect((job["error"] as? String ?? "").contains("來源資料夾"), "a folder read failure was presented as an unexplained missing file")
            try expect(!exists(to, "obsolete") && !exists(to, "old-empty"), "unrelated read error left orphan empty directories")
            try expect(!exists(to, "old‛？"), "directory cleanup used an escaped filename")
            try expect(exists(to, "legitimate-empty") && exists(to, "kept/unreadable/protected.txt") && exists(to, "nonempty/not-forced-away.txt"), "cleanup removed source-present directories or files")
            let report = job["report"] as? [String: Any] ?? [:]
            try expect(EngineJSON.number(report["directoryDeletedEvents"]) == 5 && EngineJSON.number(report["deletedEvents"]) == 0, "directory cleanup was missing from the report or inflated file deletions")
        }

        test("pruning-respects-exclusions") { area, from, to in
            _ = try directory(from, "kept/unreadable")
            _ = try directory(to, "protected")
            _ = try directory(to, "obsolete")
            _ = try run(area, request(from, to, options: ["exclude": ["/protected/**"]]), injectDirectoryFailure: true)
            try expect(exists(to, "protected") && !exists(to, "obsolete"), "directory cleanup ignored the transfer exclusion")
        }

        test("pruning-respects-selected-folder") { area, from, to in
            _ = try directory(from, "selected/kept/unreadable")
            _ = try directory(to, "selected/obsolete")
            _ = try directory(to, "unselected")
            _ = try run(area, request(from, to, selection: [["name": "selected", "isDir": true]]), injectDirectoryFailure: true)
            try expect(!exists(to, "selected/obsolete") && exists(to, "unselected"), "cleanup crossed or missed the selected folder")
        }

        test("pruning-never-runs-for-copy-or-dry-run-or-zero-delete-limit") { area, from, to in
            _ = try directory(from, "kept/unreadable")
            _ = try directory(to, "obsolete")
            _ = try run(area, request(from, to, mode: "copy"), injectDirectoryFailure: true)
            try expect(exists(to, "obsolete"), "copy pruned a destination-only directory")
            // Use different state roots for independent jobs.
            let dryArea = try directory(area, "dry-state"), limitArea = try directory(area, "limit-state")
            _ = try run(dryArea, request(from, to, dry: true), injectDirectoryFailure: true)
            try expect(exists(to, "obsolete"), "dry run deleted a directory")
            _ = try run(limitArea, request(from, to, options: ["maxDelete": 0]), injectDirectoryFailure: true)
            try expect(exists(to, "obsolete"), "zero-delete limit was bypassed")
        }

        test("listed-but-unopenable-source-protects-destination") { _, from, to in
            try FileManager.default.createSymbolicLink(atPath: from.appendingPathComponent("listed").path, withDestinationPath: "/nonexistent-rbn-test-directory")
            _ = try directory(to, "listed/empty")
            let count = try EngineLocalSyncDirectories.prune(source: from, destination: to, candidates: ["listed/empty", "listed"], maximum: -1,
                dryRun: false, cancelled: { false }, record: { _, _ in })
            try expect(count == 0 && exists(to, "listed/empty"), "a listed but inaccessible source entry was mistaken for absence")
        }

        test("directory-prune-never-follows-target-symlinks") { area, from, to in
            let outside = try directory(area, "outside/empty").deletingLastPathComponent()
            try FileManager.default.createSymbolicLink(atPath: to.appendingPathComponent("link").path, withDestinationPath: outside.path)
            let count = try EngineLocalSyncDirectories.prune(source: from, destination: to, candidates: ["link/empty", "link"], maximum: -1,
                dryRun: false, cancelled: { false }, record: { _, _ in })
            try expect(count == 0 && exists(outside, "empty"), "cleanup followed a target directory symlink")
        }

        test("file-arriving-during-prune-is-not-deleted") { _, from, to in
            _ = try directory(to, "old")
            var checks = 0
            let count = try EngineLocalSyncDirectories.prune(source: from, destination: to, candidates: ["old"], maximum: -1,
                dryRun: false, cancelled: {
                    checks += 1
                    if checks == 2 { try! write(to, "old/arrived.txt", "must survive") }
                    return false
                }, record: { _, _ in })
            try expect(count == 0 && exists(to, "old/arrived.txt"), "cleanup recursively deleted a file that arrived after inspection")
        }

        test("replacement-source-root-stops-cleanup") { area, from, to in
            _ = try directory(to, "old")
            var checks = 0, rejected = false
            do {
                _ = try EngineLocalSyncDirectories.prune(source: from, destination: to, candidates: ["old"], maximum: -1,
                    dryRun: false, cancelled: {
                        checks += 1
                        if checks == 2 {
                            try! FileManager.default.moveItem(at: from, to: area.appendingPathComponent("source-before-replacement"))
                            _ = try! directory(area, "source")
                        }
                        return false
                    }, record: { _, _ in })
            } catch { rejected = true }
            try expect(rejected && exists(to, "old"), "source root replacement authorized cleanup")
        }

        test("prune-validates-all-paths-before-removal") { _, from, to in
            _ = try directory(to, "old")
            var rejected = false
            do {
                _ = try EngineLocalSyncDirectories.prune(source: from, destination: to, candidates: ["old", "../outside"], maximum: -1,
                    dryRun: false, cancelled: { false }, record: { _, _ in })
            } catch { rejected = true }
            try expect(rejected && exists(to, "old"), "invalid candidate path was accepted or earlier directories were already removed")
        }

        test("prune-limit-and-cancellation-are-enforced") { _, from, to in
            _ = try directory(to, "a"); _ = try directory(to, "b")
            let count = try EngineLocalSyncDirectories.prune(source: from, destination: to, candidates: ["a", "b"], maximum: 1,
                dryRun: false, cancelled: { false }, record: { _, _ in })
            try expect(count == 1 && exists(to, "b"), "directory deletion exceeded its remaining limit")
            let stopped = try EngineLocalSyncDirectories.prune(source: from, destination: to, candidates: ["b"], maximum: -1,
                dryRun: false, cancelled: { true }, record: { _, _ in })
            try expect(stopped == 0 && exists(to, "b"), "cancelled cleanup removed a directory")
        }

        test("dry-run-plans-nested-orphans-without-changing-them") { _, from, to in
            _ = try directory(to, "old/child")
            let count = try EngineLocalSyncDirectories.prune(source: from, destination: to, candidates: ["old", "old/child"], maximum: -1,
                dryRun: true, cancelled: { false }, record: { _, preview in try expect(preview, "dry-run report claimed a real deletion") })
            try expect(count == 2 && exists(to, "old/child"), "nested preview count was wrong or changed the destination")
        }
        print("SyncDirectoryTests: \(failures) failures")
        if failures != 0 { exit(1) }
    }
}
