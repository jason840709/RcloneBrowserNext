import Foundation
import CoreFoundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// An append-only account of evidence emitted by rclone, not a second directory
/// scan. Comparison decisions and successful operations deliberately remain
/// separate: retries can repeat a path, and a successful copy during a move can
/// still be followed by a failure to delete the source.
final class EngineTransferReport {
    /// A fixed schema avoids validating and sorting a generic object graph for
    /// every file. JSONEncoder still handles all string escaping, including
    /// literal newlines and Unicode, without hand-written JSON concatenation.
    private struct Record: Encodable {
        let sequence: Int64
        let time: String
        let timeKind: String?
        let status: String
        let action: String
        let level: String?
        let evidence: String
        let message: String
        let object: String?
        let objectType: String?
        let path: String?
        let size: Int64?
        let sigil: String?

        init(_ value: [String: Any], sequence: Int64) {
            self.sequence = sequence
            time = value["time"] as! String; timeKind = value["timeKind"] as? String
            status = value["status"] as! String; action = value["action"] as! String
            level = value["level"] as? String; evidence = value["evidence"] as! String
            message = value["message"] as! String; object = value["object"] as? String
            objectType = value["objectType"] as? String; path = value["path"] as? String
            size = EngineTransferReport.validCounter(value["size"]); sigil = value["sigil"] as? String
        }
    }

    private final class Output {
        let handle: FileHandle
        private var pending = Data()
        init(_ handle: FileHandle) { self.handle = handle }
        func append(_ data: Data) throws {
            pending.append(data)
            if pending.count >= 64 * 1024 { try makeVisible() }
        }
        func makeVisible() throws {
            if !pending.isEmpty { try handle.write(contentsOf: pending); pending.removeAll(keepingCapacity: true) }
        }
        func finish() throws { try makeVisible(); try handle.synchronize() }
        deinit { try? makeVisible(); try? handle.close() }
    }

    private static let suffixes: [String: String] = [
        "all": ".report.jsonl", "success": ".report.success.jsonl",
        "errors": ".report.errors.jsonl", "skipped": ".report.skipped.jsonl",
        "comparison": ".report.comparison.jsonl", "raw": ".comparison.log"
    ]
    private static let counterKeys = [
        "eventCount", "successEvents", "copiedEvents", "movedEvents", "deletedEvents",
        "errorEvents", "unattributedErrors", "plannedEvents", "informationEvents",
        "comparisonEvents", "matchedEvents", "skippedEvents", "candidateEvents", "missingSourceEvents",
        "comparisonErrorEvents", "comparisonMalformed", "comparisonPendingBytes"
    ]
    private static let maximumRecordBytes = 2 * 1024 * 1024
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let directory: URL
    private let id: String
    private var outputs: [String: Output] = [:]
    private var counts = Dictionary(uniqueKeysWithValues: EngineTransferReport.counterKeys.map { ($0, Int64(0)) })
    private var lastVisible = ProcessInfo.processInfo.systemUptime
    private var observedTime = EngineJSON.now()
    private var observedSecond = Int(ProcessInfo.processInfo.systemUptime)
    private var comparisonComplete = false

    var comparisonPath: String { directory.appendingPathComponent(id + Self.suffixes["raw"]!).path }

    init(directory: URL, id: String) throws {
        try Self.validateID(id)
        self.directory = directory; self.id = id
        var created: [URL] = []
        do {
            for (kind, suffix) in Self.suffixes {
                let url = directory.appendingPathComponent(id + suffix)
                let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
                guard fd >= 0 else { throw Self.fileError("無法建立逐檔記錄") }
                created.append(url)
                outputs[kind] = Output(FileHandle(fileDescriptor: fd, closeOnDealloc: true))
            }
        } catch {
            outputs.removeAll()
            for url in created { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    /// Call outside the engine state lock. Only the already-decoded stderr JSON
    /// is consumed; the one-second statistics remain the engine's responsibility.
    func consume(_ raw: [String: Any], dryRun: Bool) throws {
        guard raw["stats"] == nil, raw["app"] as? Bool != true else { return }
        let level = (raw["level"] as? String ?? "info").lowercased()
        let message = raw["msg"] as? String ?? raw["error"] as? String ?? ""
        let object = raw["object"] as? String
        let objectType = raw["objectType"] as? String
        let isFilesystem = objectType?.hasSuffix(".Fs") == true || objectType?.hasSuffix(".fs") == true
        let path = object.flatMap { !$0.isEmpty && !isFilesystem ? $0 : nil }
        // cmd.Run logs a successful high-level retry with Errorf. It is not an
        // actual failure and must not become a spurious row in the error list.
        let retrySucceeded = message.hasPrefix("Attempt ") && message.hasSuffix(" succeeded")
        let isError = ["error", "fatal", "alert", "emergency"].contains(level) && !retrySucceeded
        let skipped = raw["skipped"] as? String
        // Object-free startup/version messages are already in the ordinary log.
        guard object != nil || isError || skipped != nil else { return }

        var status = "info", action = "information"
        if isError { status = "error"; action = Self.errorAction(message) }
        else if let skipped = skipped {
            status = dryRun ? "planned" : "skipped"; action = skipped
        } else if message.hasPrefix("Copied (") || message.hasPrefix("Multi-thread Copied (") {
            status = dryRun ? "planned" : "success"; action = "copy"
        } else if message == "Moved (server-side)" || message.hasPrefix("Moved (server-side) to: ") {
            status = dryRun ? "planned" : "success"; action = "move"
        } else if message == "Deleted" {
            status = dryRun ? "planned" : "success"; action = "delete"
        } else if message == "Moved into backup dir" {
            status = dryRun ? "planned" : "success"; action = "backup"
        }

        var record: [String: Any] = [
            "time": raw["time"] as? String ?? EngineJSON.now(), "status": status,
            "action": action, "level": level, "evidence": "json-log", "message": message
        ]
        if let object = object { record["object"] = object }
        if let path = path { record["path"] = path }
        if let objectType = objectType { record["objectType"] = objectType }
        if let size = Self.validCounter(raw["size"]) { record["size"] = size }
        try lock.holding {
            var destinations = ["all"]
            if status == "success" { destinations.append("success") }
            if status == "error" { destinations.append("errors") }
            if status == "skipped" { destinations.append("skipped") }
            try append(record, destinations: destinations)
            if status == "success" {
                increment("successEvents")
                if action == "copy" { increment("copiedEvents") }
                if action == "move" { increment("movedEvents") }
                if action == "delete" { increment("deletedEvents") }
            } else if status == "error" {
                increment("errorEvents"); if path == nil { increment("unattributedErrors") }
            } else if status == "planned" { increment("plannedEvents") }
            else if status == "skipped" { increment("skippedEvents") }
            else { increment("informationEvents") }
            try periodicallyMakeVisible()
        }
    }

    /// Pass stdout from `--combined=-` separately from stderr. Passing a file to
    /// rclone would let each high-level retry truncate it (os.Create). We own this
    /// append stream instead, preserving every attempt and the original text.
    /// Paths in this stream are evidence only and are never used for filesystem
    /// operations. A false `terminated` marks an incomplete final pipe fragment.
    func consumeComparisonLine(_ line: String, terminated: Bool = true) throws {
        try lock.holding {
            let bytes = Data((line + (terminated ? "\n" : "")).utf8)
            try outputs["raw"]!.append(bytes)
            comparisonComplete = false
            let scalars = line.unicodeScalars
            let valid = terminated && line.utf8.count <= Self.maximumRecordBytes &&
                line.utf8.count >= 3 && line.dropFirst().first == " " &&
                !scalars.contains(where: { $0.value < 32 || $0.value == 127 })
            let sigil = line.first
            guard valid, let sigil = sigil, "=+*-!".contains(sigil) else {
                increment("comparisonMalformed")
                // Keep one visible diagnostic for a malformed run, with its raw
                // text in the unabridged comparison export. Never invent a path.
                if counts["comparisonMalformed"] == 1 {
                    try append(["time": comparisonTime(), "status": "info", "action": "unparsed-comparison",
                                "evidence": "comparison", "message": "部分比對紀錄無法辨識，請查看原始比對記錄。"], destinations: ["all", "comparison"])
                }
                try periodicallyMakeVisible(); return
            }
            let path = String(line.dropFirst(2))
            let status: String, action: String, message: String
            var destinations = ["all", "comparison"]
            switch sigil {
            case "=":
                status = "matched"; action = "match"; message = "依目前比對或略過規則，不需複製。"
                destinations.append("skipped")
            case "+": status = "candidate"; action = "missing-destination"; message = "目的地缺少此檔案；這是比對結果，尚非傳輸成功紀錄。"
            case "*": status = "candidate"; action = "different"; message = "來源與目的不同；這是比對結果，尚非傳輸成功紀錄。"
            case "-": status = "comparison"; action = "missing-source"; message = "只有目的地有此檔案；是否刪除依工作模式與設定而定。"
            default:
                status = "comparison-error"; action = "comparison-error"; message = "rclone 回報 ! 比對狀態；實際錯誤原因請查看錯誤紀錄。"
                destinations.append("errors")
            }
            try append(["time": comparisonTime(), "timeKind": "observed", "status": status, "action": action,
                        "evidence": "comparison", "path": path, "sigil": String(sigil), "message": message], destinations: destinations)
            increment("comparisonEvents")
            if sigil == "=" { increment("matchedEvents") }
            else if sigil == "+" || sigil == "*" { increment("candidateEvents") }
            else if sigil == "-" { increment("missingSourceEvents") }
            else { increment("comparisonErrorEvents") }
            try periodicallyMakeVisible()
        }
    }

    /// Retained as the engine's low-frequency visibility hook. stdout is already
    /// parsed once in memory; no polling, directory scan or second file read is
    /// performed. `final` means the process pipes have finished draining.
    func pollComparisons(final: Bool = false) throws {
        try lock.holding {
            if final { comparisonComplete = true; try makeVisible() }
            else { try periodicallyMakeVisible() }
        }
    }

    func flushVisible() throws { try lock.holding { try makeVisible() } }
    func flush() throws { try lock.holding { for output in outputs.values { try output.finish() } } }

    var summary: [String: Any] {
        lock.holding {
            var value: [String: Any] = counts.mapValues { $0 as Any }
            value["available"] = true; value["formatVersion"] = 1
            value["comparisonComplete"] = comparisonComplete
            // These are event ledgers, not a deduplicated final-state database.
            value["skippedFiles"] = NSNull(); value["failedFiles"] = NSNull()
            return value
        }
    }

    static func normalizedSummary(_ value: Any?) -> [String: Any]? {
        guard let raw = value as? [String: Any], raw["available"] as? Bool == true else { return nil }
        var result: [String: Any] = ["available": true, "formatVersion": 1,
                                   "comparisonComplete": raw["comparisonComplete"] as? Bool ?? false,
                                   "skippedFiles": NSNull(), "failedFiles": NSNull()]
        for key in counterKeys { result[key] = validCounter(raw[key]) ?? 0 }
        return result
    }

    /// Cursors are byte offsets into a selected append-only ledger, not paths or
    /// row numbers. At most 200 records / roughly 1 MiB are returned in one page.
    static func page(directory: URL, id: String, category: String = "all", cursor: Int64 = 0, limit: Int = 100) throws -> [String: Any] {
        try validateID(id)
        guard category != "raw", let suffix = suffixes[category], (1...200).contains(limit), cursor >= 0 else {
            throw EngineError("逐檔記錄的分頁參數不正確。")
        }
        let url = directory.appendingPathComponent(id + suffix)
        guard let reader = try readerIfPresent(url) else {
            return ["available": false, "items": [[String: Any]](), "nextCursor": NSNull(), "category": category]
        }
        defer { try? reader.close() }
        let length = try reader.seekToEnd()
        guard UInt64(cursor) <= length else { throw EngineError("逐檔記錄的分頁位置已失效。") }
        if cursor > 0 {
            try reader.seek(toOffset: UInt64(cursor - 1))
            guard try reader.read(upToCount: 1) == Data([10]) else { throw EngineError("逐檔記錄的分頁位置不正確。") }
        }
        try reader.seek(toOffset: UInt64(cursor))
        var buffer = Data(), consumed = UInt64(cursor), items: [[String: Any]] = []
        var pageBytes = 0, incomplete = false
        while items.count < limit && (pageBytes < 1024 * 1024 || items.isEmpty) {
            if let newline = buffer.firstIndex(of: 10) {
                let data = Data(buffer.prefix(upTo: newline))
                guard let record = try? EngineJSON.object(data) as? [String: Any], record["sequence"] != nil else {
                    throw EngineError("逐檔記錄內容不完整，請匯出原始記錄查看。")
                }
                let count = buffer.distance(from: buffer.startIndex, to: newline) + 1
                buffer.removeSubrange(...newline); consumed += UInt64(count); pageBytes += count
                items.append(record); continue
            }
            guard buffer.count <= maximumRecordBytes else { throw EngineError("單筆逐檔記錄過大。") }
            let position = try reader.offset()
            guard position < length else { incomplete = !buffer.isEmpty; break }
            if let bytes = try reader.read(upToCount: Int(min(UInt64(64 * 1024), length - position))), !bytes.isEmpty { buffer.append(bytes) }
            else { incomplete = !buffer.isEmpty; break }
        }
        let next: Any = consumed < length ? consumed : NSNull()
        return ["available": true, "items": items, "nextCursor": next, "category": category,
                "incompleteTail": incomplete, "cursor": cursor]
    }

    /// Capture a complete prefix while holding the writer lock, then copy that
    /// prefix outside the lock. A save panel can stay open while the transfer
    /// continues; the returned snapshot never gains later or half-written rows.
    func exportPath(format: String = "jsonl") throws -> String {
        let captured: (FileHandle, UInt64) = try lock.holding {
            try makeVisible()
            return try Self.capture(directory: directory, id: id, format: format)
        }
        return try Self.snapshot(captured, directory: directory, id: id, format: format)
    }

    /// Use the instance method for a live report, and this method for saved jobs.
    static func exportPath(directory: URL, id: String, format: String = "jsonl") throws -> String {
        let captured = try capture(directory: directory, id: id, format: format)
        return try snapshot(captured, directory: directory, id: id, format: format)
    }

    /// Only app-owned UUID filenames are removed. A reported source/destination
    /// path is never passed here, and symlinks are unlinked without being followed.
    static func remove(directory: URL, id: String) throws {
        try validateID(id)
        for suffix in suffixes.values {
            let path = directory.appendingPathComponent(id + suffix).path
            if unlink(path) != 0 && errno != ENOENT { throw fileError("無法移除逐檔記錄") }
        }
        // Export snapshots are generated exclusively by this class. Validate the
        // complete name before unlinking; do not match arbitrary prefix siblings.
        let prefix = id + ".report-export-"
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) where name.hasPrefix(prefix) {
            let tail = String(name.dropFirst(prefix.count))
            guard let dot = tail.lastIndex(of: "."), ["jsonl", "txt"].contains(String(tail[tail.index(after: dot)...])),
                  UUID(uuidString: String(tail[..<dot])) != nil else { continue }
            let path = directory.appendingPathComponent(name).path
            if unlink(path) != 0 && errno != ENOENT { throw fileError("無法移除逐檔記錄快照") }
        }
    }

    private func append(_ value: [String: Any], destinations: [String]) throws {
        let record = Record(value, sequence: counts["eventCount"]! + 1)
        var data = try encoder.encode(record)
        guard data.count <= Self.maximumRecordBytes else { throw EngineError("單筆逐檔記錄過大，無法完整儲存。") }
        data.append(10)
        for destination in destinations { try outputs[destination]!.append(data) }
        increment("eventCount")
    }

    private func increment(_ key: String) { counts[key, default: 0] += 1 }
    private func periodicallyMakeVisible() throws {
        if ProcessInfo.processInfo.systemUptime - lastVisible >= 1 { try makeVisible() }
    }
    private func makeVisible() throws {
        for output in outputs.values { try output.makeVisible() }
        lastVisible = ProcessInfo.processInfo.systemUptime
    }
    private func comparisonTime() -> String {
        let second = Int(ProcessInfo.processInfo.systemUptime)
        if second != observedSecond { observedSecond = second; observedTime = EngineJSON.now() }
        return observedTime
    }
    private static func errorAction(_ message: String) -> String {
        if message.hasPrefix("Failed to copy:") || message.hasPrefix("Not deleting source as copy failed:") { return "copy" }
        if message.hasPrefix("Couldn't move:") { return "move" }
        if message.hasPrefix("Couldn't delete:") { return "delete" }
        if message.hasPrefix("partial file rename failed:") { return "rename" }
        return "operation"
    }
    private static func validCounter(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue <= 9_007_199_254_740_991 else { return nil }
        return number.int64Value
    }
    private static func validateID(_ id: String) throws {
        guard EngineJSON.validID(id) else { throw EngineError("工作編號格式不正確。") }
    }
    private static func readerIfPresent(_ url: URL) throws -> FileHandle? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw fileError("無法讀取逐檔記錄")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        #if canImport(Darwin)
        let typeMask = mode_t(Darwin.S_IFMT), regularFile = mode_t(Darwin.S_IFREG)
        #else
        let typeMask = mode_t(Glibc.S_IFMT), regularFile = mode_t(Glibc.S_IFREG)
        #endif
        guard fstat(fd, &info) == 0, (info.st_mode & typeMask) == regularFile else {
            try? handle.close(); throw EngineError("逐檔記錄必須是一般檔案。")
        }
        return handle
    }
    private static func capture(directory: URL, id: String, format: String) throws -> (FileHandle, UInt64) {
        try validateID(id)
        let key: String
        if format == "jsonl" { key = "all" }
        else if format == "comparison" { key = "raw" }
        else { throw EngineError("不支援這個逐檔記錄格式。") }
        let url = directory.appendingPathComponent(id + suffixes[key]!)
        guard let reader = try readerIfPresent(url) else { throw EngineError("這項工作尚未產生逐檔記錄。") }
        do {
            var length = try reader.seekToEnd()
            if format == "jsonl" && length > 0 {
                // A saved ledger may end with an interrupted write. Export only
                // complete JSONL records, without loading the whole report.
                var position = length, found = false
                while position > 0 && !found {
                    guard length - position <= UInt64(maximumRecordBytes) else { throw EngineError("逐檔記錄內容不完整，請查看原始記錄。") }
                    let begin = position > UInt64(64 * 1024) ? position - UInt64(64 * 1024) : 0
                    try reader.seek(toOffset: begin)
                    let bytes = try reader.read(upToCount: Int(position - begin)) ?? Data()
                    if let newline = bytes.lastIndex(of: 10) {
                        length = begin + UInt64(bytes.distance(from: bytes.startIndex, to: newline) + 1); found = true
                    } else { position = begin }
                }
                if !found { length = 0 }
            }
            try reader.seek(toOffset: 0)
            return (reader, length)
        } catch { try? reader.close(); throw error }
    }
    private static func snapshot(_ captured: (FileHandle, UInt64), directory: URL, id: String, format: String) throws -> String {
        let (reader, length) = captured
        defer { try? reader.close() }
        let ext = format == "jsonl" ? "jsonl" : "txt"
        let url = directory.appendingPathComponent(id + ".report-export-" + UUID().uuidString.lowercased() + "." + ext)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw fileError("無法建立逐檔記錄快照") }
        let writer = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var remaining = length
        do {
            while remaining > 0 {
                guard let data = try reader.read(upToCount: Int(min(remaining, UInt64(64 * 1024)))), !data.isEmpty else {
                    throw EngineError("逐檔記錄在匯出時發生變更，請重新匯出。")
                }
                try writer.write(contentsOf: data); remaining -= UInt64(data.count)
            }
            try writer.synchronize(); try writer.close(); return url.path
        } catch {
            try? writer.close(); try? FileManager.default.removeItem(at: url); throw error
        }
    }
    private static func fileError(_ message: String) -> EngineError {
        EngineError("\(message)：\(String(cString: strerror(errno)))")
    }
}
