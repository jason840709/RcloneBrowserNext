import Foundation

/// An append-only account of evidence emitted by rclone, not a second directory
/// scan. Comparison decisions and successful operations deliberately remain
/// separate: retries can repeat a path, and a successful copy during a move can
/// still be followed by a failure to delete the source.
final class EngineTransferReport {
    /// Used only once for a job's configuration (or a few bounded metadata
    /// chunks for very large selections), never for the per-file hot path.
    private indirect enum ConfigurationValue: Encodable {
        case null, boolean(Bool), number(Double), string(String)
        case array([ConfigurationValue]), object([String: ConfigurationValue])
        init(_ raw: Any) throws {
            if raw is NSNull { self = .null }
            else if let number = raw as? NSNumber {
                if EngineJSON.isBoolean(number) { self = .boolean(number.boolValue) }
                else if number.doubleValue.isFinite { self = .number(number.doubleValue) }
                else { throw EngineError("傳輸設定格式不正確。") }
            } else if let text = raw as? String { self = .string(text) }
            else if let values = raw as? [Any] { self = .array(try values.map { try ConfigurationValue($0) }) }
            else if let values = raw as? [String: Any] { self = .object(try values.mapValues { try ConfigurationValue($0) }) }
            else { throw EngineError("傳輸設定格式不正確。") }
        }
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .null: try container.encodeNil()
            case .boolean(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            case .string(let value): try container.encode(value)
            case .array(let value): try container.encode(value)
            case .object(let value): try container.encode(value)
            }
        }
    }
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
        let issue: String?
        let sourceSize: Int64?
        let destinationSize: Int64?
        let relatedPath: String?
        let attempt: Int64?
        let attemptLimit: Int64?
        let configuration: ConfigurationValue?

        init(_ value: [String: Any], sequence: Int64) {
            self.sequence = sequence
            time = value["time"] as! String; timeKind = value["timeKind"] as? String
            status = value["status"] as! String; action = value["action"] as! String
            level = value["level"] as? String; evidence = value["evidence"] as! String
            message = value["message"] as! String; object = value["object"] as? String
            objectType = value["objectType"] as? String; path = value["path"] as? String
            size = EngineTransferReport.validCounter(value["size"]); sigil = value["sigil"] as? String
            issue = value["issue"] as? String
            sourceSize = EngineTransferReport.validCounter(value["sourceSize"])
            destinationSize = EngineTransferReport.validCounter(value["destinationSize"])
            relatedPath = value["relatedPath"] as? String
            attempt = EngineTransferReport.validCounter(value["attempt"])
            attemptLimit = EngineTransferReport.validCounter(value["attemptLimit"])
            configuration = value["configuration"] as? ConfigurationValue
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
    private static let detailCounterKeys = [
        "copiedBytes", "failedCopyBytes", "copySizeMissingEvents", "sizeMismatchEvents", "growingSourceEvents",
        "retryFailures", "lastAttempt", "maxAttempts", "cleanupEvents", "cleanupFailureEvents"
    ]
    private static let maximumRecordBytes = 2 * 1024 * 1024
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let directory: URL
    private let id: String
    private var outputs: [String: Output] = [:]
    private var counts = Dictionary(uniqueKeysWithValues: (EngineTransferReport.counterKeys + EngineTransferReport.detailCounterKeys).map { ($0, Int64(0)) })
    private var lastVisible = ProcessInfo.processInfo.systemUptime
    private var observedTime = EngineJSON.now()
    private var observedSecond = Int(ProcessInfo.processInfo.systemUptime)
    private var comparisonComplete = false
    // Only failures need this short history. It is independent of the number of
    // files in a transfer and performs no filesystem reads or content hashing.
    private struct SizeObservation { let source: Int64; let destination: Int64; let sequence: Int64 }
    private var recentSizeFailures: [String: SizeObservation] = [:]
    private static let maximumSizeHistory = 256

    var comparisonPath: String { directory.appendingPathComponent(id + Self.suffixes["raw"]!).path }

    init(directory: URL, id: String) throws {
        try Self.validateID(id)
        self.directory = directory; self.id = id
        var created: [URL] = []
        do {
            for (kind, suffix) in Self.suffixes {
                let url = directory.appendingPathComponent(id + suffix)
                let handle = try EnginePlatform.createExclusiveFile(url)
                created.append(url)
                outputs[kind] = Output(handle)
            }
        } catch {
            outputs.removeAll()
            for url in created { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    /// Export the validated request with the engine version and the exact
    /// modify-window argument used for this run. Credentials, config contents
    /// and the process environment are outside this snapshot.
    func recordConfiguration(_ request: EngineTransferRequest, engineVersion: String?, effectiveModifyWindow: String?) throws {
        var metadata: [String: Any] = ["kind": "complete", "schemaVersion": 1,
                                       "request": request.json, "engineVersion": engineVersion as Any? ?? NSNull(),
                                       "effectiveModifyWindow": effectiveModifyWindow as Any? ?? NSNull()]
        var records: [[String: Any]] = []
        if try EngineJSON.data(metadata).count <= Self.maximumRecordBytes / 2 { records = [metadata] }
        else {
            // A large, valid selection must not fail just because a single
            // metadata row would exceed the report's normal record/page limit.
            var basic = request.json, options = request.options.json
            var collections: [(String, [Any])] = [("request.selection", request.selection.map(\.json))]
            basic.removeValue(forKey: "selection")
            for key in ["include", "exclude", "extraArgs"] {
                collections.append(("request.options." + key, options.removeValue(forKey: key) as? [Any] ?? []))
            }
            basic["options"] = options
            metadata["kind"] = "header"; metadata["request"] = basic
            metadata["collections"] = Dictionary(uniqueKeysWithValues: collections.map { ($0.0, $0.1.count) })
            records.append(metadata)
            for (name, items) in collections {
                for start in stride(from: 0, to: items.count, by: 32) {
                    records.append(["kind": "collection", "name": name, "offset": start,
                                    "items": Array(items[start..<min(start + 32, items.count)])])
                }
            }
        }
        let values = try records.map { try ConfigurationValue($0) }
        try lock.holding {
            counts["maxAttempts"] = Int64(request.options.integer("retries"))
            for value in values {
                try append(["time": EngineJSON.now(), "status": "info", "action": "configuration",
                            "evidence": "app-configuration", "message": "傳輸設定", "configuration": value], destinations: ["all"])
                increment("informationEvents")
            }
            try makeVisible()
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
        // cmd.Run emits attempt summaries at error level, including successful
        // retries. Preserve these as retry records, separate from file failures.
        let retry = Self.retryDetails(message)
        let cleanupFailed = message.hasPrefix("Failed to remove failed copy:") || message.hasPrefix("Failed to remove failed partial copy:")
        let isError = (["error", "fatal", "alert", "emergency"].contains(level) && retry == nil) || cleanupFailed
        let skipped = raw["skipped"] as? String
        // Object-free startup/version messages are already in the ordinary log.
        guard object != nil || isError || skipped != nil || retry != nil else { return }

        var status = "info", action = "information", issue: String?
        if retry != nil { action = "retry" }
        else if isError { status = "error"; action = Self.errorAction(message) }
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
        } else if message == "Can't follow symlink without -L/--copy-links" {
            status = "skipped"; action = "symlink"; issue = "symlink-ignored"
        } else if message == "Can't transfer non file/directory" {
            status = "skipped"; action = "special"; issue = "special-ignored"
        }
        if cleanupFailed { issue = "cleanup-failed"; action = "cleanup" }
        else if message == "Removing failed copy" { action = "cleanup" }
        else if message == "not deleting directories as there were IO errors" || message == "not deleting files as there were IO errors" {
            issue = "deletion-deferred"
        } else if isError && message.contains("can't copy - source file is being updated") { issue = "source-changed" }

        var record: [String: Any] = [
            "time": raw["time"] as? String ?? EngineJSON.now(), "status": status,
            "action": action, "level": level, "evidence": "json-log", "message": message
        ]
        if let object = object { record["object"] = object }
        if let path = path { record["path"] = path }
        if let objectType = objectType { record["objectType"] = objectType }
        if let size = Self.validCounter(raw["size"]) { record["size"] = size }
        try lock.holding {
            counts["lastAttempt"] = max(counts["lastAttempt"]!, 1)
            if let retry = retry {
                record["attempt"] = retry.attempt; record["attemptLimit"] = retry.limit
                counts["lastAttempt"] = max(counts["lastAttempt"]!, retry.attempt)
                counts["maxAttempts"] = max(counts["maxAttempts"]!, retry.limit)
                if retry.failed { increment("retryFailures") }
            }
            // Only the direct per-file verification message contributes bytes.
            // Attempt summaries repeat its text, but are deliberately excluded.
            if isError, let path = path, let sizes = Self.sizeMismatch(message) {
                issue = "size-mismatch"; record["action"] = "copy"
                record["sourceSize"] = sizes.source; record["destinationSize"] = sizes.destination
                increment("sizeMismatchEvents"); increment("failedCopyBytes", by: sizes.destination)
                let related = Self.localOriginalPath(path, objectType: objectType)
                if let related = related { record["relatedPath"] = related }
                let key = related ?? path
                if let previous = recentSizeFailures[key], sizes.destination > sizes.source,
                   previous.destination > previous.source, sizes.source > previous.source,
                   sizes.source >= previous.destination {
                    issue = "source-growing"; increment("growingSourceEvents")
                }
                if recentSizeFailures[key] == nil, recentSizeFailures.count >= Self.maximumSizeHistory,
                   let oldest = recentSizeFailures.min(by: { $0.value.sequence < $1.value.sequence })?.key {
                    recentSizeFailures.removeValue(forKey: oldest)
                }
                recentSizeFailures[key] = SizeObservation(source: sizes.source, destination: sizes.destination, sequence: counts["eventCount"]!)
            }
            if let issue = issue { record["issue"] = issue }
            var destinations = ["all"]
            if status == "success" { destinations.append("success") }
            if status == "error" { destinations.append("errors") }
            if status == "skipped" { destinations.append("skipped") }
            try append(record, destinations: destinations)
            if status == "success" {
                increment("successEvents")
                if action == "copy" {
                    increment("copiedEvents")
                    if let size = Self.validCounter(raw["size"]) { increment("copiedBytes", by: size) }
                    else { increment("copySizeMissingEvents") }
                }
                if action == "move" { increment("movedEvents") }
                if action == "delete" { increment("deletedEvents") }
            } else if status == "error" {
                increment("errorEvents"); if path == nil { increment("unattributedErrors") }
            } else if status == "planned" { increment("plannedEvents") }
            else if status == "skipped" { increment("skippedEvents") }
            else { increment("informationEvents") }
            if message == "Removing failed copy" { increment("cleanupEvents") }
            if cleanupFailed { increment("cleanupFailureEvents") }
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
            if counts["lastAttempt"] == 0 { counts["lastAttempt"] = 1 }
            let status: String, action: String, message: String
            var destinations = ["all", "comparison"]
            switch sigil {
            case "=":
                status = "matched"; action = "match"; message = "依本次比對與略過設定，無需更新。"
                destinations.append("skipped")
            case "+": status = "candidate"; action = "missing-destination"; message = "目標缺少此檔案，已列入傳輸清單。"
            case "*": status = "candidate"; action = "different"; message = "檔案有變更，已列入傳輸清單。"
            case "-": status = "comparison"; action = "missing-source"; message = "只有目標有此檔案。"
            default:
                status = "comparison-error"; action = "comparison-error"; message = "此檔案處理失敗，原因列於錯誤紀錄。"
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
            value["available"] = true; value["formatVersion"] = 2
            value["comparisonComplete"] = comparisonComplete
            value["copyByteTotalsAvailable"] = counts["copySizeMissingEvents"] == 0
            // These are event ledgers, not a deduplicated final-state database.
            value["skippedFiles"] = NSNull(); value["failedFiles"] = NSNull()
            return value
        }
    }

    static func normalizedSummary(_ value: Any?) -> [String: Any]? {
        guard let raw = value as? [String: Any], raw["available"] as? Bool == true else { return nil }
        let version = min(validCounter(raw["formatVersion"]) ?? 1, 2)
        var result: [String: Any] = ["available": true, "formatVersion": version,
                                   "comparisonComplete": raw["comparisonComplete"] as? Bool ?? false,
                                   "skippedFiles": NSNull(), "failedFiles": NSNull()]
        for key in counterKeys { result[key] = validCounter(raw[key]) ?? 0 }
        if version >= 2 {
            for key in detailCounterKeys { result[key] = validCounter(raw[key]) ?? 0 }
            result["copyByteTotalsAvailable"] = raw["copyByteTotalsAvailable"] as? Bool == true && validCounter(raw["copiedBytes"]) != nil && validCounter(raw["failedCopyBytes"]) != nil
        }
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
            try EnginePlatform.removeFileIfPresent(path)
        }
        // Export snapshots are generated exclusively by this class. Validate the
        // complete name before unlinking; do not match arbitrary prefix siblings.
        let prefix = id + ".report-export-"
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) where name.hasPrefix(prefix) {
            let tail = String(name.dropFirst(prefix.count))
            guard let dot = tail.lastIndex(of: "."), ["jsonl", "txt"].contains(String(tail[tail.index(after: dot)...])),
                  UUID(uuidString: String(tail[..<dot])) != nil else { continue }
            let path = directory.appendingPathComponent(name).path
            try EnginePlatform.removeFileIfPresent(path)
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

    private func increment(_ key: String, by value: Int64 = 1) {
        // Match JavaScript's exact integer range when publishing counters.
        counts[key] = min(9_007_199_254_740_991, counts[key, default: 0] + value)
    }
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
    private static func retryDetails(_ message: String) -> (attempt: Int64, limit: Int64, failed: Bool)? {
        guard message.hasPrefix("Attempt ") else { return nil }
        let parts = message.dropFirst(8).split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let numbers = parts[0].split(separator: "/", omittingEmptySubsequences: false)
        guard numbers.count == 2, let attempt = Int64(numbers[0]), let limit = Int64(numbers[1]),
              attempt > 0, limit >= attempt, limit <= 1_000_000 else { return nil }
        let result = parts[1]
        guard result == "succeeded" || result.hasPrefix("failed with ") else { return nil }
        return (attempt, limit, result != "succeeded")
    }
    private static func sizeMismatch(_ message: String) -> (source: Int64, destination: Int64)? {
        guard message.utf8.count <= 65536, message.hasPrefix("corrupted on transfer: sizes differ src("),
              let separator = message.range(of: " vs dst(", options: .backwards) else { return nil }
        func trailingSize(_ text: Substring) -> Int64? {
            guard let marker = text.range(of: ") ", options: .backwards) else { return nil }
            let raw = text[marker.upperBound...]
            guard !raw.isEmpty, raw.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let value = Int64(raw), value <= 9_007_199_254_740_991 else { return nil }
            return value
        }
        guard let source = trailingSize(message[..<separator.lowerBound]),
              let destination = trailingSize(message[separator.upperBound...]), source != destination else { return nil }
        return (source, destination)
    }
    private static func localOriginalPath(_ path: String, objectType: String?) -> String? {
        // The app owns partial-file flags and clears RCLONE_* environment flags.
        // Local copies use rclone's default .<8 hex>.partial suffix. For an
        // original leaf above 100 bytes, rclone replaces its last 17 bytes;
        // UTF-8 boundary repair can shorten that result by up to 3 more bytes.
        // A reported leaf of 98+ bytes may therefore already be truncated.
        // This derived label is used for display/correlation, never file access.
        guard objectType == "*local.Object", let leaf = path.split(separator: "/", omittingEmptySubsequences: false).last,
              leaf.utf8.count <= 97, leaf.utf8.count > 17, path.hasSuffix(".partial") else { return nil }
        let beforePartial = path.dropLast(8)
        guard beforePartial.count >= 9 else { return nil }
        let suffix = beforePartial.suffix(9)
        guard suffix.first == ".", suffix.dropFirst().utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }) else { return nil }
        return String(beforePartial.dropLast(9))
    }
    private static func errorAction(_ message: String) -> String {
        if message.hasPrefix("Failed to copy:") || message.hasPrefix("Not deleting source as copy failed:") || message.hasPrefix("corrupted on transfer:") { return "copy" }
        if message.hasPrefix("Couldn't move:") { return "move" }
        if message.hasPrefix("Couldn't delete:") { return "delete" }
        if message.hasPrefix("partial file rename failed:") { return "rename" }
        return "operation"
    }
    private static func validCounter(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, !EngineJSON.isBoolean(number),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue <= 9_007_199_254_740_991 else { return nil }
        return number.int64Value
    }
    private static func validateID(_ id: String) throws {
        guard EngineJSON.validID(id) else { throw EngineError("工作編號格式不正確。") }
    }
    private static func readerIfPresent(_ url: URL) throws -> FileHandle? {
        try EnginePlatform.readRegularFile(url)
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
        let writer = try EnginePlatform.createExclusiveFile(url)
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
}
