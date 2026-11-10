import Foundation

/// How a transfer recovers from errors.
///
/// rclone's own `--retries` repeats the entire command after any error: every
/// file is listed and compared again, so one unreadable folder triples the
/// time of a large sync. A 2026-11-09 NAS-to-card sync of 239,921 files was
/// compared three times (about 706,000 checks) because 52 folders could not be
/// read, and both repeats hit exactly the same 52 folders.
///
/// In the `failed` scope (the default) rclone runs a single pass at a time and
/// the app decides what the next pass covers:
/// - errors that fail the same way again (not found, permission, unsupported
///   name, full disk) are not retried;
/// - individual files are retried by name with `--files-from-raw`;
/// - anything that cannot be scoped safely (folder listing errors, errors
///   without a path, `--delete-excluded`, very many failures) repeats the
///   complete transfer, exactly like rclone would.
/// The `full` scope keeps rclone's behaviour unchanged.
enum EngineRetryScope: String {
    case failed, full
    static let settingKey = "retryScope"
    static let defaultValue = EngineRetryScope.failed.rawValue

    static func validated(_ value: Any?) throws -> String {
        guard let text = value as? String, EngineRetryScope(rawValue: text) != nil else { throw EngineError("重試方式設定不正確。") }
        return text
    }
}

/// One error rclone reported during a pass, as recorded in the per-file report.
struct EngineRetryFailure: Equatable {
    let path: String?
    let objectType: String?
    let message: String
}

enum EngineRetryDecision: Equatable {
    /// Stop. The message, when present, explains why in the job log.
    case finish(String?)
    /// Retry exactly these paths, relative to the transfer roots.
    case files([String])
    /// Repeat the complete transfer. The message explains why.
    case full(String)
}

struct EngineRetryOutcome: Equatable {
    var decision: EngineRetryDecision
    /// Errors that are not retried because they would fail the same way.
    var permanent: [EngineRetryFailure]
    /// rclone postponed deletions in this pass because of errors.
    var deletionDeferred: Bool
}

enum EngineRetryPlan {
    /// Larger lists still work, but a full pass is then the simpler choice.
    static let maximumScopedFiles = 50_000
    /// The report keeps at most this many errors per pass for planning.
    static let maximumRecordedFailures = maximumScopedFiles + 1

    // MARK: Classification

    private static let summaryPrefixes = ["Attempt ", "Fatal error received", "Can't retry any of the errors",
                                          "Failed to sync", "Failed to copy", "Failed to move", "Failed to bisync"]
    private static let deferralMessages: Set<String> = ["not deleting files as there were IO errors",
                                                        "not deleting directories as there were IO errors"]

    /// rclone's own end-of-run summaries repeat errors that were already
    /// reported with their path. They carry no path of their own.
    static func isSummary(_ failure: EngineRetryFailure) -> Bool {
        failure.path == nil && summaryPrefixes.contains { failure.message.hasPrefix($0) }
    }

    static func isDeletionDeferral(_ failure: EngineRetryFailure) -> Bool { deferralMessages.contains(failure.message) }

    /// Known temporary conditions are checked first: Google reports rate limits
    /// as 403, which would otherwise read as a permission error.
    private static let temporaryMarkers = [
        "ratelimit", "rate limit", "too many requests", "429", "quota exceeded for quota metric",
        "timeout", "timed out", "connection reset", "connection refused", "broken pipe", "unexpected eof",
        "tls handshake", "no such host", "network is unreachable", "temporarily", "try again",
        "internal error", "internalerror", "backenderror", "service unavailable", "bad gateway",
        "500", "502", "503", "504", "source file is being updated", "sizes differ", "corrupted on transfer"
    ]
    private static let permanentMarkers = [
        "directory not found", "object not found", "file not found", "no such file or directory",
        "permission denied", "operation not permitted", "access is denied", "insufficientpermissions",
        "file name too long", "name too long", "path too long", "illegal byte sequence", "invalid utf-8",
        "invalid argument", "not a directory", "is a directory", "no space left on device",
        "storagequotaexceeded", "insufficient storage", "storage quota", "can't follow symlink",
        "can't transfer non file/directory"
    ]

    /// An error is permanent only when it is recognised as one. Unknown errors
    /// are retried: retrying one file costs little, missing a recoverable one
    /// leaves the copy incomplete.
    static func isPermanent(_ message: String) -> Bool {
        let text = message.lowercased()
        if temporaryMarkers.contains(where: { text.contains($0) }) { return false }
        return permanentMarkers.contains { text.contains($0) }
    }

    /// Folder-level errors cover an unknown set of files; only a complete pass
    /// can list that folder again.
    static func isDirectory(_ failure: EngineRetryFailure) -> Bool {
        let text = failure.message.lowercased()
        if ["error reading source directory", "error reading destination directory", "error listing",
            "failed to make directory", "failed to read directory", "couldn't list"].contains(where: { text.contains($0) }) { return true }
        guard let type = failure.objectType else { return false }
        return type.hasSuffix("Directory") || type.hasSuffix(".Dir") || type.hasSuffix(".Fs") || type.hasSuffix(".fs")
    }

    // MARK: Planning

    /// - Parameters:
    ///   - lastPassScoped: the pass that just ended retried a file list.
    ///   - deferredEarlier: an earlier pass postponed deletions.
    ///   - outstanding: permanent errors still unresolved from earlier passes.
    static func decide(failures: [EngineRetryFailure], overflow: Bool, exitCode: Int32, cancelled: Bool,
                       attempt: Int, limit: Int, request: EngineTransferRequest,
                       fatal: Bool, retryable: Bool?, lastPassScoped: Bool, deferredEarlier: Bool,
                       outstanding: Int) -> EngineRetryOutcome {
        var permanent: [EngineRetryFailure] = [], files: [String] = [], seen = Set<String>()
        var fullReason: String?, deferred = false, meaningful = 0
        for failure in failures {
            if isDeletionDeferral(failure) { deferred = true; continue }
            if isSummary(failure) { continue }
            meaningful += 1
            if isPermanent(failure.message) { permanent.append(failure); continue }
            guard let path = failure.path, !path.isEmpty, isDirectory(failure) == false else {
                fullReason = fullReason ?? (failure.path == nil ? noPathReason : folderReason)
                continue
            }
            guard !path.contains("\n"), !path.contains("\r") else { fullReason = fullReason ?? noPathReason; continue }
            if seen.insert(path).inserted { files.append(path) }
        }
        if overflow { fullReason = manyReason }
        var outcome = EngineRetryOutcome(decision: .finish(nil), permanent: permanent, deletionDeferred: deferred)
        let isSync = request.mode == "sync"
        if exitCode == 0 && meaningful == 0 {
            // A scoped pass succeeded. Deletions postponed by an earlier error
            // still need one complete pass, as rclone itself would have done.
            if isSync, !request.dryRun, lastPassScoped, deferredEarlier, outstanding == 0 {
                outcome.decision = attempt < limit ? .full(completionReason) : .finish(completionSkipped)
            }
            return outcome
        }
        if cancelled { return outcome }
        if request.dryRun { outcome.decision = .finish(nil); return outcome }
        if fatal { outcome.decision = .finish(fatalNote); return outcome }
        if meaningful == 0 && exitCode != 0 { fullReason = fullReason ?? exitReason }
        let work = fullReason != nil || !files.isEmpty
        if !work {
            outcome.decision = .finish(permanent.isEmpty ? nil : fill(permanentNote, permanent.count))
            return outcome
        }
        if retryable == false { outcome.decision = .finish(notRetryableNote); return outcome }
        if attempt >= limit { outcome.decision = .finish(fill(limitNote, limit)); return outcome }
        if isSync && request.options.flag("deleteExcluded") && fullReason == nil { fullReason = deleteExcludedReason }
        if fullReason == nil && files.count > maximumScopedFiles { fullReason = manyReason }
        outcome.decision = fullReason.map { .full($0) } ?? .files(files)
        return outcome
    }

    /// Replaces each `{}` in order, the placeholder NativeMessages translates.
    static func fill(_ template: String, _ values: Int...) -> String {
        var text = template
        for value in values {
            guard let range = text.range(of: "{}") else { break }
            text.replaceSubrange(range, with: String(value))
        }
        return text
    }

    // App log texts. Each has English and Japanese in NativeMessages.swift.
    // `.full` reasons contain one `{}` for the number of the next pass.
    static let scopedMessage = "第 {} 輪：只重試上一輪出錯的 {} 個檔案，其他檔案不重新檢查。"
    static let noPathReason = "第 {} 輪：重新檢查全部檔案，因為有錯誤沒有對應到特定檔案。"
    static let folderReason = "第 {} 輪：重新檢查全部檔案，因為有資料夾讀取失敗，需要重新列出。"
    static let manyReason = "第 {} 輪：重新檢查全部檔案，因為出錯的檔案太多。"
    static let deleteExcludedReason = "第 {} 輪：重新檢查全部檔案，因為已開啟「刪除排除項目」，只重試部分檔案會刪除其他檔案。"
    static let completionReason = "第 {} 輪：重新檢查全部檔案，補做先前因錯誤而暫停的刪除。"
    static let exitReason = "第 {} 輪：重新檢查全部檔案，因為 rclone 異常結束，沒有留下可對應的錯誤。"
    static let permanentNote = "有 {} 個錯誤重試也會一樣（例如找不到、沒有權限、檔名不支援），不重試，也不重新檢查其他檔案。"
    static let fatalNote = "rclone 回報無法繼續的錯誤，不再重試。"
    static let notRetryableNote = "rclone 判斷這些錯誤重試也不會改善，不再重試。"
    static let limitNote = "已用完 {} 輪的嘗試次數，仍有錯誤。"
    static let completionSkipped = "錯誤已在重試中解決，但嘗試次數已用完；先前因錯誤而暫停的刪除沒有補做，下次同步會處理。"

    // MARK: Arguments

    /// Flags that select files. `--files-from-raw` cannot be combined with any
    /// of them, and `--delete-excluded` would delete everything outside the
    /// list. Retried files already passed these filters in the earlier pass.
    private static let scopeFlags: Set<String> = [
        "--filter", "--filter-from", "--include", "--include-from", "--exclude", "--exclude-from",
        "--files-from", "--files-from-raw", "--min-size", "--max-size", "--min-age", "--max-age",
        "--max-depth", "--exclude-if-present", "--delete-excluded"
    ]

    private static func key(_ argument: String) -> String { String(argument.split(separator: "=", maxSplits: 1)[0]) }

    /// One rclone pass; the app plans any further passes.
    static func singlePass(_ arguments: [String]) -> [String] {
        arguments.map { $0.hasPrefix("--retries=") ? "--retries=1" : $0 }
    }

    /// A pass that processes only the listed files.
    static func scoped(_ arguments: [String], listPath: String) -> [String] {
        guard let boundary = arguments.firstIndex(of: "--") else { return singlePass(arguments) }
        let flags = singlePass(Array(arguments[..<boundary])).filter { !scopeFlags.contains(key($0)) }
        return flags + ["--files-from-raw=\(listPath)"] + Array(arguments[boundary...])
    }

    /// rclone durations such as "10s", "1m30s" or "500ms", in seconds.
    static func seconds(_ text: String) -> Double? {
        guard !text.isEmpty else { return nil }
        let units: [(String, Double)] = [("ms", 0.001), ("h", 3600), ("m", 60), ("s", 1)]
        var rest = Substring(text), total = 0.0
        while !rest.isEmpty {
            let number = rest.prefix { $0.isNumber || $0 == "." }
            guard !number.isEmpty, let value = Double(number) else { return nil }
            rest = rest.dropFirst(number.count)
            guard let unit = units.first(where: { rest.hasPrefix($0.0) }) else { return nil }
            total += value * unit.1; rest = rest.dropFirst(unit.0.count)
        }
        return total.isFinite ? total : nil
    }

    // MARK: Statistics

    private static let cumulativeKeys = ["bytes", "checks", "transfers", "deletes", "deletedDirs", "renames", "listed",
                                         "elapsedTime", "transferTime", "serverSideCopies", "serverSideCopyBytes",
                                         "serverSideMoves", "serverSideMoveBytes"]
    private static let totalKeys = [("totalBytes", "bytes"), ("totalChecks", "checks"), ("totalTransfers", "transfers")]

    /// Each rclone process starts its counters at zero. Present one job: add
    /// the counters of earlier passes, and keep errors that were not retried.
    static func accumulate(_ raw: [String: Any], base: [String: Any]?, carriedErrors: Int) -> [String: Any] {
        var value = raw
        if let base = base {
            for key in cumulativeKeys where raw[key] != nil || base[key] != nil {
                value[key] = EngineJSON.number(base[key]) + EngineJSON.number(raw[key])
            }
            for (total, done) in totalKeys where raw[total] != nil {
                value[total] = EngineJSON.number(base[done]) + EngineJSON.number(raw[total])
            }
        }
        if carriedErrors > 0 { value["errors"] = EngineJSON.number(raw["errors"]) + Double(carriedErrors) }
        return value
    }
}
