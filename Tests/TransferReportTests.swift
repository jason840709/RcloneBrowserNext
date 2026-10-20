import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private struct ReportTestFailure: Error, CustomStringConvertible { let description: String }
private func reportExpect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw ReportTestFailure(description: message) }
}

@main struct TransferReportTests {
    static var passed = 0, failed = 0, skipped = 0

    static func main() {
        let arguments = CommandLine.arguments
        if arguments.dropFirst().first == "--benchmark" { benchmark(arguments.count > 2 ? arguments[2] : NSTemporaryDirectory()); return }
        let base = URL(fileURLWithPath: arguments.count > 2 ? arguments[2] : NSTemporaryDirectory())
            .appendingPathComponent("transfer-report-tests-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            func fresh() throws -> (EngineTransferReport, String) {
                let id = UUID().uuidString.lowercased()
                return (try EngineTransferReport(directory: base, id: id), id)
            }
            func rows(_ id: String, _ category: String = "all") throws -> [[String: Any]] {
                try EngineTransferReport.page(directory: base, id: id, category: category)["items"] as? [[String: Any]] ?? []
            }
            func count(_ report: EngineTransferReport, _ key: String) -> Int { (report.summary[key] as? NSNumber)?.intValue ?? -1 }

            test("Comparison candidates never count as completed transfers") {
                let (report, id) = try fresh()
                for line in ["= same.txt", "+ new.txt", "* changed.txt", "- extra.txt", "! unreadable.txt"] {
                    try report.consumeComparisonLine(line)
                }
                try report.pollComparisons(final: true)
                try reportExpect(count(report, "successEvents") == 0, "candidate counted as success")
                try reportExpect(count(report, "matchedEvents") == 1 && count(report, "candidateEvents") == 2, "comparison counters wrong")
                try reportExpect(count(report, "comparisonErrorEvents") == 1 && count(report, "errorEvents") == 0, "comparison error counted as JSON error")
                try reportExpect(try rows(id, "skipped").count == 1, "matched row absent")
                try reportExpect(try rows(id, "comparison").count == 5, "comparison rows missing")
                try reportExpect(report.summary["skippedFiles"] is NSNull && report.summary["failedFiles"] is NSNull, "fabricated unique file counts")
            }
            test("Successful copy and later move-source deletion failure remain separate") {
                let (report, id) = try fresh()
                try report.consume(["time": "2026-10-20T00:00:00Z", "level": "info", "object": "file.txt", "objectType": "*local.Object", "msg": "Copied (new)", "size": 42], dryRun: false)
                try report.consume(["level": "error", "object": "file.txt", "msg": "Couldn't delete: permission denied"], dryRun: false)
                try report.flush()
                let success = try rows(id, "success"), errors = try rows(id, "errors")
                try reportExpect(success.count == 1 && success[0]["action"] as? String == "copy", "copy not recorded")
                try reportExpect(count(report, "movedEvents") == 0 && errors.count == 1, "failed move reported complete")
                try reportExpect(errors[0]["path"] as? String == "file.txt", "error lost filename")
            }
            test("Retries retain error evidence and do not pretend events are unique files") {
                let (report, id) = try fresh()
                try report.consumeComparisonLine("+ repeat.txt")
                try report.consume(["level": "error", "object": "repeat.txt", "msg": "Failed to copy: network reset"], dryRun: false)
                try report.consumeComparisonLine("+ repeat.txt")
                try report.consume(["level": "info", "object": "repeat.txt", "msg": "Multi-thread Copied (new)"], dryRun: false)
                try report.consume(["level": "error", "msg": "Attempt 2/3 succeeded"], dryRun: false)
                try report.flush()
                try reportExpect(count(report, "candidateEvents") == 2 && count(report, "copiedEvents") == 1, "retry events collapsed")
                try reportExpect(try rows(id, "errors").count == 1, "recovered error evidence removed")
                let path = try report.exportPath(format: "comparison")
                try reportExpect(try String(contentsOfFile: path) == "+ repeat.txt\n+ repeat.txt\n", "raw retry history truncated")
            }
            test("JSONL preserves quotes, Unicode and literal newlines in reported filenames") {
                let (report, id) = try fresh()
                let name = "資料/line\nbreak,\"quoted\".txt"
                try report.consume(["level": "error", "object": name, "msg": "read failed\nsecond line"], dryRun: false)
                try report.flush()
                let data = try Data(contentsOf: URL(fileURLWithPath: report.exportPath()))
                try reportExpect(data.filter { $0 == 10 }.count == 1, "embedded newline broke JSONL framing")
                try reportExpect(try rows(id, "errors").first?["path"] as? String == name, "filename altered")
            }
            test("Dry Run actions are planned and statistics never create file rows") {
                let (report, id) = try fresh()
                try report.consume(["level": "warning", "object": "dry.txt", "skipped": "copy", "size": 12, "msg": "Skipped copy as --dry-run is set (size 12)"], dryRun: true)
                try report.consume(["level": "info", "stats": ["checks": 9, "transfers": 4, "totalTransfers": 7, "errors": 3]], dryRun: true)
                try report.flush()
                try reportExpect(count(report, "eventCount") == 1 && count(report, "plannedEvents") == 1 && count(report, "successEvents") == 0, "dry run looked complete")
                try reportExpect(try rows(id).first?["status"] as? String == "planned", "planned status missing")
            }
            test("Unknown comparison lines and an incomplete tail are visible without invented paths") {
                let (report, id) = try fresh()
                try report.consumeComparisonLine("not a comparison")
                try report.consumeComparisonLine("= half", terminated: false)
                try report.pollComparisons(final: true)
                try reportExpect(count(report, "comparisonMalformed") == 2 && count(report, "matchedEvents") == 0, "malformed row treated as skip")
                let all = try rows(id)
                try reportExpect(all.count == 1 && all[0]["path"] == nil, "invented malformed path or many duplicate diagnostics")
                try reportExpect(try String(contentsOfFile: report.exportPath(format: "comparison")) == "not a comparison\n= half", "raw fragment was changed")
            }
            test("Reported paths cannot trigger file operations") {
                let (report, id) = try fresh()
                let untouched = base.appendingPathComponent("untouched.txt")
                try Data("keep".utf8).write(to: untouched)
                try report.consumeComparisonLine("- " + untouched.path)
                try report.consumeComparisonLine("= ../../escape;$(command).txt")
                try report.flush(); try EngineTransferReport.remove(directory: base, id: id)
                try reportExpect(try String(contentsOf: untouched) == "keep", "report touched a described file")
            }
            test("Filesystem and global errors remain visible without a fake filename") {
                let (report, id) = try fresh()
                try report.consume(["level": "error", "object": "Local file system at /fixture", "objectType": "*local.Fs", "msg": "error listing"], dryRun: false)
                try report.consume(["level": "error", "msg": "Failed to sync: network unavailable"], dryRun: false)
                try report.flush()
                try reportExpect(count(report, "unattributedErrors") == 2, "global error misattributed")
                try reportExpect(try rows(id, "errors").allSatisfy { $0["path"] == nil }, "fake path added")
            }
            test("Page cursors retain stable row boundaries and enforce small pages") {
                let (report, id) = try fresh()
                for number in 0..<1003 { try report.consumeComparisonLine("= file-\(number).txt") }
                try report.pollComparisons(final: true)
                var cursor: Int64 = 0, seen = 0, sequences = Set<Int>()
                repeat {
                    let page = try EngineTransferReport.page(directory: base, id: id, category: "skipped", cursor: cursor, limit: 73)
                    let items = page["items"] as? [[String: Any]] ?? []
                    try reportExpect(items.count <= 73, "unbounded page")
                    for item in items { sequences.insert((item["sequence"] as? NSNumber)?.intValue ?? -1) }
                    seen += items.count
                    guard let next = page["nextCursor"] as? NSNumber else { break }
                    try reportExpect(next.int64Value > cursor, "non-advancing cursor")
                    cursor = next.int64Value
                } while true
                try reportExpect(seen == 1003 && sequences.count == 1003, "pagination duplicated or lost records")
                try mustThrow { _ = try EngineTransferReport.page(directory: base, id: id, cursor: 2) }
                try mustThrow { _ = try EngineTransferReport.page(directory: base, id: id, limit: 100000) }
            }
            test("Saved summaries allow known finite counters and keep uncertain counts unknown") {
                let parsed = EngineTransferReport.normalizedSummary(["available": true, "eventCount": 5, "successEvents": true, "errorEvents": Double.infinity, "matchedEvents": -2, "skippedFiles": 999, "secret": "drop"])
                try reportExpect((parsed?["eventCount"] as? NSNumber)?.intValue == 5, "valid summary count lost")
                try reportExpect((parsed?["successEvents"] as? NSNumber)?.intValue == 0 && (parsed?["matchedEvents"] as? NSNumber)?.intValue == 0, "invalid numeric counter accepted")
                try reportExpect(parsed?["skippedFiles"] is NSNull && parsed?["secret"] == nil, "unsafe fields restored")
            }
            test("Legacy or queued jobs without a ledger return an unavailable empty page") {
                let page = try EngineTransferReport.page(directory: base, id: UUID().uuidString)
                try reportExpect(page["available"] as? Bool == false && (page["items"] as? [[String: Any]])?.isEmpty == true, "missing ledger fabricated")
                try mustThrow { _ = try EngineTransferReport.page(directory: base, id: "../escape") }
            }
            test("Both export formats are immutable snapshots while the live job grows") {
                let (report, _) = try fresh()
                try report.consumeComparisonLine("= before.txt")
                let firstJSON = try report.exportPath(), firstRaw = try report.exportPath(format: "comparison")
                let jsonBytes = try Data(contentsOf: URL(fileURLWithPath: firstJSON))
                try report.consumeComparisonLine("= after.txt")
                try report.flush()
                try reportExpect(try Data(contentsOf: URL(fileURLWithPath: firstJSON)) == jsonBytes, "JSON snapshot gained live rows")
                try reportExpect(try String(contentsOfFile: firstRaw) == "= before.txt\n", "raw snapshot gained live rows")
                try reportExpect(try report.exportPath() != firstJSON, "second export reused a mutable snapshot")
            }
            test("Static JSON export omits a crash-truncated final JSON record") {
                let (report, id) = try fresh()
                try report.consumeComparisonLine("= complete.txt"); try report.flush()
                let ledger = base.appendingPathComponent(id + ".report.jsonl")
                let writer = try FileHandle(forWritingTo: ledger)
                _ = try writer.seekToEnd(); try writer.write(contentsOf: Data("{\"sequence\":".utf8)); try writer.close()
                let path = try EngineTransferReport.exportPath(directory: base, id: id)
                let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
                try reportExpect(bytes.last == 10 && bytes.filter { $0 == 10 }.count == 1, "snapshot included partial JSON")
            }
            test("Cleanup removes only owned reports and snapshots; readers reject symlinks") {
                let (report, id) = try fresh()
                try report.consumeComparisonLine("= a.txt")
                let snapshot = try report.exportPath()
                let neighbor = base.appendingPathComponent(id + ".report-export-not-a-uuid.jsonl")
                try Data("keep".utf8).write(to: neighbor)
                try EngineTransferReport.remove(directory: base, id: id)
                try reportExpect(!FileManager.default.fileExists(atPath: snapshot) && FileManager.default.fileExists(atPath: neighbor.path), "cleanup crossed ownership boundary")
                let other = UUID().uuidString.lowercased(), symlink = base.appendingPathComponent(other + ".report.jsonl")
                try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: neighbor)
                try mustThrow { _ = try EngineTransferReport.page(directory: base, id: other) }
            }

            let binary = arguments.count > 1 ? arguments[1] : ""
            test("Real rclone copy, repeat sync and delete produce honest checks and separate outcomes", available: FileManager.default.isExecutableFile(atPath: binary)) {
                let source = base.appendingPathComponent("real-source"), destination = base.appendingPathComponent("real-destination")
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let timestamp = Date(timeIntervalSince1970: 1_750_000_000)
                for name in ["same.txt", "new.txt", "line\nbreak.txt"] {
                    let file = source.appendingPathComponent(name)
                    try Data("fixture".utf8).write(to: file)
                    try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: file.path)
                }
                let same = destination.appendingPathComponent("same.txt")
                try Data("fixture".utf8).write(to: same)
                try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: same.path)
                let (first, firstID) = try fresh()
                let firstStats = try runRclone(binary, mode: "copy", source: source, destination: destination, report: first)
                try reportExpect(count(first, "copiedEvents") == 2 && count(first, "matchedEvents") == 1, "real copy outcomes wrong")
                try reportExpect((firstStats["transfers"] as? NSNumber)?.intValue == 2, "real transfer count wrong")
                try reportExpect(try rows(firstID, "success").contains { ($0["path"] as? String)?.contains("line␊break") == true }, "standard rclone newline encoding lost")
                try Data("extra".utf8).write(to: destination.appendingPathComponent("extra.txt"))
                let (second, _) = try fresh()
                let secondStats = try runRclone(binary, mode: "sync", source: source, destination: destination, report: second)
                try reportExpect((secondStats["transfers"] as? NSNumber)?.intValue == 0 && count(second, "matchedEvents") == 3, "unchanged files not skipped")
                try reportExpect(count(second, "deletedEvents") == 1, "real deletion absent")
                try reportExpect((secondStats["checks"] as? NSNumber)?.intValue != count(second, "matchedEvents"), "fixture failed to demonstrate checks also include deletion")
            }
        } catch { failed += 1; print("FAIL setup: \(error)") }
        print("\(passed) passed, \(failed) failed, \(skipped) skipped")
        if failed > 0 { exit(1) }
    }

    private static func test(_ name: String, available: Bool = true, _ body: () throws -> Void) {
        guard available else { skipped += 1; print("SKIP \(name)"); return }
        do { try body(); passed += 1; print("PASS \(name)") }
        catch { failed += 1; print("FAIL \(name): \(error)") }
    }
    private static func mustThrow(_ body: () throws -> Void) throws {
        do { try body() } catch { return }; throw ReportTestFailure(description: "expected rejection")
    }
    private static func benchmark(_ path: String) {
        do {
            let directory = URL(fileURLWithPath: path).appendingPathComponent("report-benchmark-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let id = UUID().uuidString.lowercased(), report = try EngineTransferReport(directory: directory, id: id)
            let start = ProcessInfo.processInfo.systemUptime
            for index in 0..<100_000 { try report.consumeComparisonLine("= synthetic/folder-\(index / 1000)/file-\(index).txt") }
            try report.pollComparisons(final: true); try report.flush()
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            var sizes: [String: Int] = [:]
            for file in files { sizes[file.lastPathComponent.replacingOccurrences(of: id, with: "job")] = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }
            let result: [String: Any] = ["records": 100_000, "seconds": elapsed, "recordsPerSecond": 100_000 / elapsed,
                                       "bytes": sizes.values.reduce(0, +), "files": sizes, "summary": report.summary,
                                       "note": "Synthetic local report path only; not a NAS throughput measurement or performance gate."]
            print(String(decoding: try EngineJSON.data(result, pretty: true), as: UTF8.self))
        } catch { print("Benchmark failed: \(error)"); exit(1) }
    }
    private static func runRclone(_ binary: String, mode: String, source: URL, destination: URL, report: EngineTransferReport) throws -> [String: Any] {
        let process = Process(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [mode, "--combined=-", "--use-json-log", "--stats=1s", "--stats-log-level=INFO", "--log-level=INFO",
                             "--local-hashes=none", "--transfers=1", "--checkers=10", "--retries=1", "--multi-thread-streams=0",
                             "--ask-password=false", "--", source.path, destination.path]
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.uppercased().hasPrefix("RCLONE_") }
        environment["RCLONE_CONFIG"] = source.deletingLastPathComponent().appendingPathComponent("empty-rclone.conf").path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice; process.standardOutput = stdout; process.standardError = stderr
        try process.run()
        // This fixture contains three tiny files, so both pipes remain far below
        // capacity. Production drains both independently in RcloneEngine.
        let comparison = stdout.fileHandleForReading.readDataToEndOfFile()
        let log = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try reportExpect(process.terminationStatus == 0, "rclone fixture failed: \(String(decoding: log, as: UTF8.self))")
        for line in String(decoding: comparison, as: UTF8.self).split(separator: "\n") { try report.consumeComparisonLine(String(line)) }
        var stats: [String: Any] = [:]
        for line in String(decoding: log, as: UTF8.self).split(separator: "\n") {
            guard let raw = try? EngineJSON.object(Data(line.utf8)) as? [String: Any] else { continue }
            if let value = raw["stats"] as? [String: Any] { stats = value }
            try report.consume(raw, dryRun: false)
        }
        try report.pollComparisons(final: true); try report.flush()
        return stats
    }
}
