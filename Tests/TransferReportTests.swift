import Foundation
#if canImport(Darwin)
import Darwin
#elseif os(Windows)
import ucrt
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

            test("Symbolic links are skipped by default and preserved only by explicit choice") {
                let raw: [String: Any] = ["source": ["remote": NSNull(), "path": base.appendingPathComponent("from").path],
                                          "destination": ["remote": NSNull(), "path": base.appendingPathComponent("to").path],
                                          "mode": "copy", "selection": [[String: Any]](), "dryRun": false, "options": [String: Any]()]
                let normal = try EngineTransferRequest(raw)
                try reportExpect(normal.options.text("symlinkMode") == "skip" && !normal.arguments().contains("--links"), "legacy request changed link behavior")
                var preserve = raw; preserve["options"] = ["symlinkMode": "preserve"]
                let args = try EngineTransferRequest(preserve).arguments()
                try reportExpect(args.contains("--links") && !args.contains("--copy-links"), "preserve followed targets")
                try mustThrow { _ = try EngineTransferOptions(["symlinkMode": "follow"]) }
                try mustThrow { _ = try EngineTransferOptions(["extraArgs": ["--copy-links"]]) }
            }
            test("Exports retain the actual comparison settings and engine version without environment data") {
                let (report, id) = try fresh()
                let raw: [String: Any] = ["source": ["remote": NSNull(), "path": base.appendingPathComponent("from").path],
                                          "destination": ["remote": "archive", "path": "backup"], "mode": "sync",
                                          "selection": [["name": "資料", "isDir": true]], "dryRun": false,
                                          "options": ["comparison": "size", "symlinkMode": "preserve", "modifyWindow": "1s", "transfers": 1, "checkers": 10]]
                let request = try EngineTransferRequest(raw)
                try report.recordConfiguration(request, engineVersion: "rclone v1.75.2", effectiveModifyWindow: "1s")
                let item = try rows(id).first
                let context = item?["configuration"] as? [String: Any], saved = context?["request"] as? [String: Any]
                let options = saved?["options"] as? [String: Any]
                try reportExpect(item?["action"] as? String == "configuration" && context?["engineVersion"] as? String == "rclone v1.75.2", "version metadata missing")
                try reportExpect(context?["effectiveModifyWindow"] as? String == "1s" && options?["comparison"] as? String == "size" && options?["symlinkMode"] as? String == "preserve", "actual comparison settings not retained")
                try reportExpect(context?["environment"] == nil && context?["configContents"] == nil && context?["password"] == nil, "unrelated private process configuration exported")
                try reportExpect(EngineJSON.number(report.summary["maxAttempts"]) == 3 && count(report, "copiedEvents") == 0, "configuration changed outcomes")
            }
            test("A large valid selection is split into bounded, reconstructable configuration records") {
                let (report, id) = try fresh()
                let names = (0..<400).map { "資料-\($0)-" + String(repeating: "a", count: 3000) }
                let raw: [String: Any] = ["source": ["remote": NSNull(), "path": base.appendingPathComponent("from").path],
                                          "destination": ["remote": "archive", "path": "backup"], "mode": "copy",
                                          "selection": names.map { ["name": $0, "isDir": false] as [String: Any] }, "dryRun": false,
                                          "options": [String: Any]()]
                try report.recordConfiguration(EngineTransferRequest(raw), engineVersion: "rclone v1.75.2", effectiveModifyWindow: nil)
                let path = try report.exportPath()
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                let items = try data.split(separator: 10).map { try EngineJSON.object(Data($0)) as! [String: Any] }
                let configurations = items.compactMap { $0["configuration"] as? [String: Any] }
                try reportExpect(configurations.first?["kind"] as? String == "header", "oversized metadata was not split")
                let chunks = configurations.filter { $0["name"] as? String == "request.selection" }
                let restored = chunks.flatMap { ($0["items"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String } }
                try reportExpect(restored == names, "configuration chunks lost or reordered selected paths")
                try reportExpect(data.split(separator: 10).allSatisfy { $0.count < 1024 * 1024 }, "configuration row exceeds normal page size")
                try reportExpect(try rows(id).count < items.count, "large first page ignored byte bound")
            }
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
            test("Growing-file retries separate completed bytes from failed size-verification bytes") {
                let (report, id) = try fresh()
                func mismatch(_ source: Int, _ destination: Int, _ suffix: String) throws {
                    try report.consume(["level": "error", "object": "logs/live.jsonl.\(suffix).partial", "objectType": "*local.Object",
                                        "msg": "corrupted on transfer: sizes differ src(Local file system at /source) \(source) vs dst(Local file system at /backup) \(destination)"], dryRun: false)
                }
                try report.consume(["level": "info", "object": "database.sqlite", "msg": "Copied (server-side copy)", "size": 40], dryRun: false)
                try mismatch(100, 110, "aabbcc01")
                try report.consume(["level": "error", "msg": "Attempt 1/3 failed with 1 errors and: corrupted on transfer: sizes differ src(Local file system at /source) 100 vs dst(Local file system at /backup) 110"], dryRun: false)
                try report.consume(["level": "info", "object": "database.sqlite", "msg": "Copied (server-side copy)", "size": 40], dryRun: false)
                try mismatch(110, 120, "aabbcc02")
                try report.consume(["level": "error", "msg": "Attempt 2/3 failed with 1 errors"], dryRun: false)
                try mismatch(120, 150, "aabbcc03")
                try report.consume(["level": "error", "msg": "Attempt 3/3 failed with 1 errors"], dryRun: false)
                try report.flush()
                try reportExpect(count(report, "copiedBytes") == 80 && count(report, "failedCopyBytes") == 380, "byte accounting double-counted an attempt summary or deduplicated actual copies")
                try reportExpect(count(report, "copiedEvents") == 2 && count(report, "sizeMismatchEvents") == 3, "operation counts are wrong")
                try reportExpect(count(report, "retryFailures") == 3 && count(report, "lastAttempt") == 3 && count(report, "maxAttempts") == 3, "retry progress missing")
                try reportExpect(count(report, "growingSourceEvents") == 2, "continued source growth not identified")
                let errors = try rows(id, "errors")
                try reportExpect(errors.count == 3 && errors[0]["issue"] as? String == "size-mismatch" && errors[1]["issue"] as? String == "source-growing", "attempt summaries obscured file failures")
                try reportExpect(errors[2]["relatedPath"] as? String == "logs/live.jsonl" && errors[2]["path"] as? String == "logs/live.jsonl.aabbcc03.partial", "original evidence or display label altered")
                try reportExpect((errors[2]["sourceSize"] as? NSNumber)?.intValue == 120 && (errors[2]["destinationSize"] as? NSNumber)?.intValue == 150, "size evidence lost")
            }
            test("A successful retry stays out of the error list and missing copy sizes stay explicit") {
                let (report, id) = try fresh()
                try report.consume(["level": "info", "object": "known.txt", "msg": "Copied (new)", "size": 12], dryRun: false)
                try report.consume(["level": "info", "object": "unknown.txt", "msg": "Copied (new)"], dryRun: false)
                try report.consume(["level": "error", "msg": "Attempt 2/3 succeeded"], dryRun: false)
                try report.flush()
                try reportExpect(report.summary["copyByteTotalsAvailable"] as? Bool == false && count(report, "copiedBytes") == 12, "partial size sum presented as complete")
                try reportExpect(try rows(id, "errors").isEmpty && count(report, "lastAttempt") == 2, "successful attempt counted as failure")
                try reportExpect(try rows(id).last?["action"] as? String == "retry", "successful attempt record dropped")
            }
            test("Ignored links and special files are discoverable in skipped records") {
                let (report, id) = try fresh()
                try report.consume(["level": "notice", "object": "link", "msg": "Can't follow symlink without -L/--copy-links"], dryRun: false)
                try report.consume(["level": "notice", "object": "ipc.sock", "msg": "Can't transfer non file/directory"], dryRun: false)
                try report.flush()
                let skipped = try rows(id, "skipped")
                try reportExpect(skipped.count == 2 && count(report, "errorEvents") == 0, "ignored entries missing or mislabeled errors")
                try reportExpect(skipped.map { $0["issue"] as? String } == ["symlink-ignored", "special-ignored"], "skip reason missing")
            }
            test("Denied local partial renames retain the original error and do not claim completed copies") {
                let (report, id) = try fresh()
                let message = "partial file rename failed: rename /destination/book.txt.1234abcd.partial /destination/book.txt: operation not permitted"
                try report.consume(["level": "error", "object": "book.txt.1234abcd.partial", "objectType": "*local.Object", "msg": message], dryRun: false)
                try report.consume(["level": "error", "object": "other.txt.1234abcd.partial", "objectType": "*local.Object", "msg": "partial file rename failed: no space left on device"], dryRun: false)
                try report.consume(["level": "error", "object": "cloud.txt.1234abcd.partial", "objectType": "*drive.Object", "msg": message], dryRun: false)
                try report.flush()
                let errors = try rows(id, "errors")
                try reportExpect(errors.count == 3 && errors[0]["issue"] as? String == "partial-rename-denied", "local rename denial was not identified")
                try reportExpect(errors[0]["message"] as? String == message && errors[0]["path"] as? String == "book.txt.1234abcd.partial" && errors[0]["relatedPath"] as? String == "book.txt", "rename evidence was changed or lost")
                try reportExpect(errors[1]["issue"] == nil && errors[2]["issue"] == nil, "unrelated failures were diagnosed as local permission errors")
                try reportExpect(count(report, "successEvents") == 0 && count(report, "copiedBytes") == 0, "rename failure reported completed data")
            }
            test("Cleanup failures are visible even when rclone logs them at info level") {
                let (report, id) = try fresh()
                try report.consume(["level": "info", "object": "unfinished.partial", "msg": "Removing failed copy"], dryRun: false)
                try report.consume(["level": "info", "object": "unfinished.partial", "msg": "Failed to remove failed copy: access denied"], dryRun: false)
                try report.consume(["level": "error", "object": "Local file system at /backup", "objectType": "*local.Fs", "msg": "not deleting directories as there were IO errors"], dryRun: false)
                try report.flush()
                let errors = try rows(id, "errors")
                try reportExpect(count(report, "cleanupEvents") == 1 && count(report, "cleanupFailureEvents") == 1, "cleanup request confused with success")
                try reportExpect(errors.count == 2 && errors[0]["issue"] as? String == "cleanup-failed", "cleanup failure hidden in info logs")
                try reportExpect(errors[1]["issue"] as? String == "deletion-deferred" && errors[1]["path"] == nil, "consequential directory error misattributed")
            }
            test("Size diagnostics reject malformed numbers and never reconstruct truncated names") {
                let (report, id) = try fresh()
                let longName = String(repeating: "a", count: 110) + ".1234abcd.partial"
                try report.consume(["level": "error", "object": longName, "objectType": "*local.Object", "msg": "corrupted on transfer: sizes differ src(Local) 3 vs dst(Local) 4"], dryRun: false)
                // A 101-byte original ending in a multibyte boundary can yield
                // this 99-byte partial name after rclone's UTF-8 truncation.
                let truncatedUnicodeName = String(repeating: "a", count: 82) + ".1234abce.partial"
                try report.consume(["level": "error", "object": truncatedUnicodeName, "objectType": "*local.Object", "msg": "corrupted on transfer: sizes differ src(Local) 4 vs dst(Local) 5"], dryRun: false)
                for message in ["corrupted on transfer: sizes differ src(Local) -1 vs dst(Local) 3", "corrupted on transfer: sizes differ src(Local) 3 vs dst(Local) 9007199254740992", "corrupted on transfer: sizes differ src(Local) 3 vs dst(Local) 3"] {
                    try report.consume(["level": "error", "object": "file", "msg": message], dryRun: false)
                }
                try report.flush()
                try reportExpect(count(report, "sizeMismatchEvents") == 2 && count(report, "failedCopyBytes") == 9, "invalid diagnostic numbers counted")
                try reportExpect(try rows(id, "errors").allSatisfy { $0["relatedPath"] == nil }, "long or unsupported filename reconstructed")
            }
            test("Size-failure history remains bounded during large error sets") {
                let (report, _) = try fresh()
                for index in 0...256 {
                    try report.consume(["level": "error", "object": "file-\(index).1234abcd.partial", "objectType": "*local.Object", "msg": "corrupted on transfer: sizes differ src(Local) 3 vs dst(Local) 4"], dryRun: false)
                }
                try report.consume(["level": "error", "object": "file-0.1234abce.partial", "objectType": "*local.Object", "msg": "corrupted on transfer: sizes differ src(Local) 4 vs dst(Local) 5"], dryRun: false)
                try reportExpect(count(report, "growingSourceEvents") == 0 && count(report, "sizeMismatchEvents") == 258, "old failure retained beyond bounded history")
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
                try reportExpect(parsed?["copiedBytes"] == nil && parsed?["copyByteTotalsAvailable"] == nil, "legacy bytes fabricated as zero")
                let current = EngineTransferReport.normalizedSummary(["available": true, "formatVersion": 2, "copyByteTotalsAvailable": true, "copiedBytes": 15, "failedCopyBytes": 24, "lastAttempt": 3, "maxAttempts": 3])
                try reportExpect(current?["copyByteTotalsAvailable"] as? Bool == true && (current?["copiedBytes"] as? NSNumber)?.intValue == 15 && (current?["lastAttempt"] as? NSNumber)?.intValue == 3, "current summary details lost")
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
            test("Real rclone preserves symbolic links locally and round-trips cloud-style link files", available: FileManager.default.isExecutableFile(atPath: binary)) {
                let source = base.appendingPathComponent("links-source"), local = base.appendingPathComponent("links-local")
                let archive = base.appendingPathComponent("links-archive"), restored = base.appendingPathComponent("links-restored")
                for directory in [source, local, archive, restored] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
                let outside = base.appendingPathComponent("link-target.txt")
                try Data("The linked content stays at its original location.".utf8).write(to: outside)
                try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("link.txt").path, withDestinationPath: "../link-target.txt")
                let (localReport, _) = try fresh()
                _ = try runRclone(binary, mode: "copy", source: source, destination: local, report: localReport, additionalArguments: ["--links"])
                try reportExpect(try FileManager.default.destinationOfSymbolicLink(atPath: local.appendingPathComponent("link.txt").path) == "../link-target.txt", "local backup followed or lost the link")
                let (archiveReport, _) = try fresh()
                // Enable translation only at the source to model a cloud
                // backend storing ordinary .rclonelink objects. The global
                // --links flag intentionally enables it at every local endpoint.
                _ = try runRclone(binary, mode: "copy", source: source, destination: archive, report: archiveReport,
                                  sourceArgument: ":local,links=true:" + source.path)
                try reportExpect(try String(contentsOf: archive.appendingPathComponent("link.txt.rclonelink")) == "../link-target.txt", "cloud-style representation contains file content instead of its link target")
                let (restoreReport, _) = try fresh()
                _ = try runRclone(binary, mode: "copy", source: archive, destination: restored, report: restoreReport,
                                  destinationArgument: ":local,links=true:" + restored.path)
                try reportExpect(try FileManager.default.destinationOfSymbolicLink(atPath: restored.appendingPathComponent("link.txt").path) == "../link-target.txt", "link restore did not reproduce the original target")
                try reportExpect(try String(contentsOf: outside) == "The linked content stays at its original location.", "link backup modified its external target")
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
    private static func runRclone(_ binary: String, mode: String, source: URL, destination: URL, report: EngineTransferReport,
                                  additionalArguments: [String] = [], sourceArgument: String? = nil, destinationArgument: String? = nil) throws -> [String: Any] {
        let process = Process(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [mode, "--combined=-", "--use-json-log", "--stats=1s", "--stats-log-level=INFO", "--log-level=INFO",
                             "--local-hashes=none", "--transfers=1", "--checkers=10", "--retries=1", "--multi-thread-streams=0",
                             "--ask-password=false"] + additionalArguments + ["--", sourceArgument ?? source.path, destinationArgument ?? destination.path]
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
