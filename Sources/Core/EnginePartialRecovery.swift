#if os(macOS)
import Foundation
import CoreFoundation
import CryptoKit
import Darwin

/// A report-scoped, content-verified recovery for local rclone partial files.
/// Reports and plans are data. Neither can supply commands, extra target paths,
/// or permission changes. Preview/apply never write to the source or delete
/// a file. Separately confirmed cleanup can remove only a receipt-bound,
/// retained partial after verifying source and rebuilt final again.
enum EnginePartialRecovery {
    private struct Failure: LocalizedError {
        let message: String
        let code: Int32?
        var errorDescription: String? { message }
        init(_ message: String, code: Int32? = nil) { self.message = message; self.code = code }
    }

    private struct UnsupportedExclusiveRename: LocalizedError {
        let code: Int32
        var errorDescription: String? {
            "此磁碟不支援原子且不覆寫的改名（errno \(code): \(String(cString: strerror(code)))）。"
        }
    }

    /// A journal failure must stop the entire run, including failures that
    /// occur after a new output has been created. Never continue after a torn
    /// append or failed fsync.
    private struct JournalStorageFailure: LocalizedError {
        let underlying: Error
        var errorDescription: String? {
            "修復日誌無法繼續保存，已停止。若已建立新檔，該檔尚未確認完成，請查看最後一筆日誌；原暫存檔保留。\(underlying.localizedDescription)"
        }
    }

    /// Test-only injection is a Swift call, never a report/plan/environment or
    /// application CLI option. Production always supplies nil.
    struct TestOptions {
        var forceUnsupportedRename = false
        var beforeExclusiveCreate: (() throws -> Void)?
        var afterDurableProgress: (() -> Void)?
    }

    private final class Descriptor {
        let raw: Int32
        init(_ raw: Int32) { self.raw = raw }
        deinit { Darwin.close(raw) }
    }

    private struct NodeIdentity: Codable, Equatable {
        let device: Int64
        let inode: UInt64
        init(_ value: stat) {
            device = Int64(value.st_dev)
            inode = UInt64(value.st_ino)
        }
    }

    private struct Snapshot: Codable, Equatable {
        let node: NodeIdentity
        let size: Int64
        let mode: UInt32
        let links: UInt64
        let user: UInt32
        let group: UInt32
        let flags: UInt32
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(_ value: stat) {
            node = NodeIdentity(value)
            size = Int64(value.st_size)
            mode = UInt32(value.st_mode)
            links = UInt64(value.st_nlink)
            user = UInt32(value.st_uid)
            group = UInt32(value.st_gid)
            flags = value.st_flags
            modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
            changedSeconds = Int64(value.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
        }

        /// Clearing a file flag and renaming can update ctime. They must not
        /// change content, ownership, permissions, link count, or modification time.
        func sameContentState(as other: Snapshot) -> Bool {
            node == other.node && size == other.size && mode == other.mode &&
                links == other.links && user == other.user && group == other.group &&
                modifiedSeconds == other.modifiedSeconds &&
                modifiedNanoseconds == other.modifiedNanoseconds
        }
    }

    /// Holds every traversed directory open, starting at "/", and checks each
    /// name-to-inode binding without following symbolic links.
    private struct DirectoryChain {
        struct Node {
            let descriptor: Descriptor
            let name: String
            let identity: NodeIdentity
        }
        let nodes: [Node]
        var fd: Int32 { nodes.last!.descriptor.raw }
        var identity: NodeIdentity { nodes.last!.identity }

        static func absolute(_ path: String) throws -> DirectoryChain {
            let components = try absoluteComponents(path)
            let descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard descriptor >= 0 else { throw systemFailure("無法開啟根目錄") }
            let root = Descriptor(descriptor)
            let value = try directoryStat(root.raw)
            return try DirectoryChain(nodes: [
                Node(descriptor: root, name: "/", identity: NodeIdentity(value))
            ]).appending(components)
        }

        func appending(_ components: [String]) throws -> DirectoryChain {
            var result = nodes
            for name in components {
                let descriptor = Darwin.openat(result.last!.descriptor.raw, name,
                                               O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard descriptor >= 0 else {
                    throw systemFailure("目錄不存在、無法讀取或含有符號連結：\(name)")
                }
                let handle = Descriptor(descriptor)
                let value = try directoryStat(handle.raw)
                result.append(Node(descriptor: handle, name: name, identity: NodeIdentity(value)))
            }
            let chain = DirectoryChain(nodes: result)
            try chain.validate()
            return chain
        }

        func validate() throws {
            for (index, node) in nodes.enumerated() {
                guard NodeIdentity(try directoryStat(node.descriptor.raw)) == node.identity else {
                    throw Failure("目錄在檢查期間改變，已停止處理。")
                }
                if index > 0 {
                    var current = stat()
                    guard Darwin.fstatat(nodes[index - 1].descriptor.raw, node.name, &current,
                                         AT_SYMLINK_NOFOLLOW) == 0,
                          current.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                          NodeIdentity(current) == node.identity else {
                        throw Failure("目錄路徑被替換或改成符號連結，已停止處理。")
                    }
                }
            }
        }
    }

    private struct BoundFile {
        let parent: DirectoryChain
        let leaf: String
        let descriptor: Descriptor

        init(parent: DirectoryChain, leaf: String) throws {
            try parent.validate()
            let descriptor = Darwin.openat(parent.fd, leaf,
                                           O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw systemFailure("檔案不存在、無法讀取或是符號連結：\(leaf)")
            }
            self.parent = parent
            self.leaf = leaf
            self.descriptor = Descriptor(descriptor)
            _ = try validate()
        }

        init(parent: DirectoryChain, leaf: String, descriptor: Descriptor) throws {
            self.parent = parent
            self.leaf = leaf
            self.descriptor = descriptor
            _ = try validate()
        }

        func validate(expected: Snapshot? = nil) throws -> Snapshot {
            try parent.validate()
            var opened = stat()
            var named = stat()
            guard Darwin.fstat(descriptor.raw, &opened) == 0,
                  opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  opened.st_size >= 0, opened.st_nlink > 0 else {
                throw Failure("只接受仍存在的一般檔案：\(leaf)")
            }
            guard Darwin.fstatat(parent.fd, leaf, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  named.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  Snapshot(opened) == Snapshot(named) else {
                throw Failure("檔案在檢查期間被替換或改變：\(leaf)")
            }
            let current = Snapshot(opened)
            if let expected = expected, current != expected {
                throw Failure("檔案已與預覽時不同，請重新預覽：\(leaf)")
            }
            return current
        }
    }

    private struct Candidate: Codable, Equatable {
        let id: String
        let relativePath: String
        let temporaryRelativePath: String
        let renameSequence: Int
    }
    private struct Excluded: Codable {
        let sequence: Int
        let temporaryRelativePath: String
        let reason: String
    }
    private struct Report {
        let path: String
        let sha256: String
        let sourceRoot: String
        let destinationRoot: String
        let candidates: [Candidate]
        let excluded: [Excluded]
    }
    private struct Item: Codable {
        let candidate: Candidate
        var status: String
        var message: String
        var source: Snapshot?
        var temporary: Snapshot?
        var sourceParent: NodeIdentity?
        var destinationParent: NodeIdentity?
        var sha256: String?
    }
    private struct Plan: Codable {
        let schemaVersion: Int
        let kind: String
        let createdAt: String
        let reportPath: String
        let reportSHA256: String
        let sourceRoot: String
        let destinationRoot: String
        let sourceRootIdentity: NodeIdentity
        let destinationRootIdentity: NodeIdentity
        let items: [Item]
        let excluded: [Excluded]
        let counts: [String: Int]
    }
    private struct Outcome: Codable, Equatable {
        let candidate: Candidate
        let status: String
        let message: String
        let clearedUserImmutable: Bool?
        let method: String?
        let partialRetained: Bool?
        let renameErrno: Int32?
        let errorCode: Int32?
        let newOutput: Snapshot?
        let bytesWritten: Int64?
        let retainedPartial: Snapshot?

        init(candidate: Candidate, status: String, message: String, clearedUserImmutable: Bool?,
             method: String? = nil, partialRetained: Bool? = nil, renameErrno: Int32? = nil,
             errorCode: Int32? = nil, newOutput: Snapshot? = nil, bytesWritten: Int64? = nil,
             retainedPartial: Snapshot? = nil) {
            self.candidate = candidate; self.status = status; self.message = message
            self.clearedUserImmutable = clearedUserImmutable; self.method = method
            self.partialRetained = partialRetained; self.renameErrno = renameErrno
            self.errorCode = errorCode; self.newOutput = newOutput; self.bytesWritten = bytesWritten
            self.retainedPartial = retainedPartial
        }
    }
    private struct Receipt: Codable {
        let schemaVersion: Int
        let kind: String
        let startedAt: String
        var finishedAt: String?
        let planPath: String
        let planSHA256: String
        let journalPath: String
        let reportPath: String
        let reportSHA256: String
        let sourceRoot: String
        let destinationRoot: String
        let excluded: [Excluded]
        var items: [Outcome]
        var counts: [String: Int]
    }
    private struct JournalEvent: Codable {
        let event: String
        let time: String
        let candidate: Candidate?
        let outcome: Outcome?
        let counts: [String: Int]?
    }
    private struct CleanupReceipt: Codable {
        let schemaVersion: Int
        let kind: String
        let startedAt: String
        var finishedAt: String?
        let recoveryReceiptPath: String
        let recoveryReceiptSHA256: String
        let journalPath: String
        let planPath: String
        let planSHA256: String
        let reportPath: String
        let reportSHA256: String
        let sourceRoot: String
        let destinationRoot: String
        var items: [Outcome]
        var counts: [String: Int]
    }

    /// Preview only reads card files. Its output must be a new file outside
    /// both transfer trees. It never clears flags or changes transfer names.
    static func preview(report reportURL: URL, plan planURL: URL) throws -> [String: Any] {
        let report = try parseReport(reportURL)
        let roots = try openRoots(report)
        let output = try ExclusiveOutput(planURL, outside: report, roots: roots)
        var items: [Item] = []
        for candidate in report.candidates {
            var item = Item(candidate: candidate, status: "blocked", message: "",
                            source: nil, temporary: nil, sourceParent: nil,
                            destinationParent: nil, sha256: nil)
            do {
                let original = try relativeComponents(candidate.relativePath)
                let temporary = try relativeComponents(candidate.temporaryRelativePath)
                let destinationParent = try roots.destination.appending(Array(temporary.dropLast()))
                if try exists(parent: destinationParent, leaf: original.last!) {
                    item.status = "existing"
                    item.message = "正式檔名已存在，保留原檔，不覆寫。"
                } else {
                    let sourceParent = try roots.source.appending(Array(original.dropLast()))
                    let source = try BoundFile(parent: sourceParent, leaf: original.last!)
                    let partial = try BoundFile(parent: destinationParent, leaf: temporary.last!)
                    let sourceState = try source.validate()
                    let partialState = try partial.validate()
                    try validatePair(sourceState, partialState)
                    try requireStableEmptyFileIdentity(source, snapshot: sourceState)
                    try requireStableEmptyFileIdentity(partial, snapshot: partialState)
                    if sourceState.size != partialState.size {
                        item.status = "mismatch"
                        item.message = "來源與暫存檔大小不同，不改名。"
                    } else {
                        let sourceHash = try stableHash(source)
                        let partialHash = try stableHash(partial)
                        _ = try source.validate(expected: sourceHash.snapshot)
                        _ = try partial.validate(expected: partialHash.snapshot)
                        if sourceHash.digest != partialHash.digest {
                            item.status = "mismatch"
                            item.message = "來源與暫存檔的 SHA-256 不同，不改名。"
                        } else {
                            item.status = "ready"
                            item.message = "大小與完整 SHA-256 一致，可恢復正式檔名。"
                            item.source = sourceHash.snapshot
                            item.temporary = partialHash.snapshot
                            item.sourceParent = sourceParent.identity
                            item.destinationParent = destinationParent.identity
                            item.sha256 = sourceHash.digest
                        }
                    }
                }
            } catch { item.message = error.localizedDescription }
            items.append(item)
        }
        try roots.source.validate()
        try roots.destination.validate()
        var counts = ["total": items.count + report.excluded.count, "ready": 0,
                      "existing": 0, "mismatch": 0, "blocked": report.excluded.count]
        for item in items { counts[item.status, default: 0] += 1 }
        let plan = Plan(schemaVersion: 1, kind: "local-partial-recovery-plan",
                        createdAt: now(), reportPath: report.path, reportSHA256: report.sha256,
                        sourceRoot: report.sourceRoot, destinationRoot: report.destinationRoot,
                        sourceRootIdentity: roots.source.identity,
                        destinationRootIdentity: roots.destination.identity,
                        items: items, excluded: report.excluded, counts: counts)
        try output.write(plan)
        return try object(plan)
    }

    /// Reparse the original report and recheck every planned identity and hash
    /// before changing one of its verified partials. A plan cannot add targets.
    static func apply(plan planURL: URL, receipt receiptURL: URL) throws -> [String: Any] {
        try apply(plan: planURL, receipt: receiptURL, testOptions: nil)
    }

    static func testApply(plan planURL: URL, receipt receiptURL: URL,
                          options: TestOptions) throws -> [String: Any] {
        try apply(plan: planURL, receipt: receiptURL, testOptions: options)
    }

    private static func apply(plan planURL: URL, receipt receiptURL: URL,
                              testOptions: TestOptions?) throws -> [String: Any] {
        let planData = try readDocument(planURL, maximum: 32 * 1024 * 1024)
        let plan = try JSONDecoder().decode(Plan.self, from: planData)
        guard plan.schemaVersion == 1, plan.kind == "local-partial-recovery-plan" else {
            throw Failure("這不是支援的暫存檔修復計畫。")
        }
        let report = try parseReport(URL(fileURLWithPath: plan.reportPath))
        guard report.sha256 == plan.reportSHA256,
              report.sourceRoot == plan.sourceRoot,
              report.destinationRoot == plan.destinationRoot else {
            throw Failure("原始報表或來源／目的路徑已改變，請重新預覽。")
        }
        let allowed = Dictionary(uniqueKeysWithValues: report.candidates.map { ($0.id, $0) })
        var seen = Set<String>()
        for item in plan.items {
            guard allowed[item.candidate.id] == item.candidate,
                  seen.insert(item.candidate.id).inserted,
                  ["ready", "existing", "mismatch", "blocked"].contains(item.status) else {
                throw Failure("修復計畫含有重複、未列在原始報表或不支援的項目。")
            }
        }
        let roots = try openRoots(report)
        guard roots.source.identity == plan.sourceRootIdentity,
              roots.destination.identity == plan.destinationRootIdentity else {
            throw Failure("來源或目的目錄已被替換，請重新預覽。")
        }
        let output = try ExclusiveOutput(receiptURL, outside: report, roots: roots)
        let journalURL = URL(fileURLWithPath: try documentPath(receiptURL) + ".journal.jsonl")
        let journal = try ExclusiveOutput(journalURL, outside: report, roots: roots, appendOnly: true)
        var receipt = Receipt(schemaVersion: 1, kind: "local-partial-recovery-receipt",
                              startedAt: now(), finishedAt: nil,
                              planPath: try documentPath(planURL), planSHA256: digest(planData),
                              journalPath: journalURL.path,
                              reportPath: report.path, reportSHA256: report.sha256,
                              sourceRoot: report.sourceRoot, destinationRoot: report.destinationRoot,
                              excluded: report.excluded, items: [],
                              counts: ["total": plan.items.count + report.excluded.count,
                                       "recovered": 0, "skipped": report.excluded.count, "failed": 0,
                                       "renamed": 0, "rebuilt": 0, "retainedPartials": 0, "failedNewOutputs": 0])
        // Confirm that durable receipt storage works before touching a card.
        try output.write(receipt)
        try journal.append(receipt)
        for item in plan.items {
            let outcome: Outcome
            if item.status != "ready" {
                outcome = Outcome(candidate: item.candidate, status: "skipped",
                                  message: "預覽未列為可修復：\(item.message)", clearedUserImmutable: false)
            } else {
                // Journal storage failures are fatal, not per-file failures.
                // Do not append another record after a partial write or
                // failed fsync, and never continue to a later file.
                try journal.append(JournalEvent(event: "intent", time: now(),
                                                candidate: item.candidate, outcome: nil, counts: nil))
                do {
                    guard let expectedSource = item.source, let expectedPartial = item.temporary,
                          let expectedSourceParent = item.sourceParent,
                          let expectedDestinationParent = item.destinationParent,
                          let expectedHash = item.sha256, validHash(expectedHash) else {
                        throw Failure("修復計畫缺少原始身分或內容校驗值。")
                    }
                    let original = try relativeComponents(item.candidate.relativePath)
                    let temporary = try relativeComponents(item.candidate.temporaryRelativePath)
                    let destinationParent = try roots.destination.appending(Array(temporary.dropLast()))
                    guard destinationParent.identity == expectedDestinationParent else {
                        throw Failure("目的父目錄已被替換，請重新預覽。")
                    }
                    if try exists(parent: destinationParent, leaf: original.last!) {
                        outcome = Outcome(candidate: item.candidate, status: "skipped",
                                          message: "正式檔名已存在，保留原檔，不覆寫。",
                                          clearedUserImmutable: false)
                    } else {
                        let sourceParent = try roots.source.appending(Array(original.dropLast()))
                        guard sourceParent.identity == expectedSourceParent else {
                            throw Failure("來源父目錄已被替換，請重新預覽。")
                        }
                        let source = try BoundFile(parent: sourceParent, leaf: original.last!)
                        let partial = try BoundFile(parent: destinationParent, leaf: temporary.last!)
                        let sourceState = try source.validate(expected: expectedSource)
                        let partialState = try partial.validate(expected: expectedPartial)
                        try validatePair(sourceState, partialState)
                        try requireStableEmptyFileIdentity(source, snapshot: sourceState)
                        try requireStableEmptyFileIdentity(partial, snapshot: partialState)
                        let sourceHash = try stableHash(source)
                        let partialHash = try stableHash(partial)
                        guard sourceHash.digest == expectedHash, partialHash.digest == expectedHash else {
                            throw Failure("來源或暫存內容已改變，請重新預覽；未改名。")
                        }
                        _ = try source.validate(expected: expectedSource)
                        _ = try partial.validate(expected: expectedPartial)
                        do {
                            let unlocked = try commit(partial: partial, expected: expectedPartial,
                                                      finalLeaf: original.last!,
                                                      forceUnsupported: testOptions?.forceUnsupportedRename == true)
                            outcome = Outcome(candidate: item.candidate, status: "recovered",
                                              message: "已核對完整內容並以原子改名恢復正式檔名。",
                                              clearedUserImmutable: unlocked, method: "atomic-rename",
                                              partialRetained: false)
                        } catch let unavailable as UnsupportedExclusiveRename {
                            // An unsupported syscall is eligible for rebuilding
                            // only after the old name and all original flags
                            // have been verified through the still-held file.
                            let restored = try partial.validate()
                            guard restored.sameContentState(as: expectedPartial),
                                  restored.flags == expectedPartial.flags else {
                                throw Failure("改名未受支援，但無法確認原暫存檔與旗標已還原；不建立新檔。")
                            }
                            outcome = try rebuild(candidate: item.candidate, source: source,
                                                  expectedSource: expectedSource, partial: partial,
                                                  expectedPartial: restored, expectedHash: expectedHash,
                                                  finalLeaf: original.last!, renameErrno: unavailable.code,
                                                  journal: journal, testOptions: testOptions)
                        }
                    }
                } catch let storage as JournalStorageFailure {
                    throw storage
                } catch {
                    outcome = Outcome(candidate: item.candidate, status: "failed",
                                      message: error.localizedDescription, clearedUserImmutable: nil,
                                      errorCode: (error as? Failure)?.code)
                }
            }
            receipt.items.append(outcome)
            receipt.counts[outcome.status == "failed-new-output" ? "failed" : outcome.status, default: 0] += 1
            if outcome.status == "recovered" {
                receipt.counts[outcome.method == "atomic-rename" ? "renamed" : "rebuilt", default: 0] += 1
            }
            if outcome.partialRetained == true { receipt.counts["retainedPartials", default: 0] += 1 }
            if outcome.status == "failed-new-output" { receipt.counts["failedNewOutputs", default: 0] += 1 }
            try journal.append(JournalEvent(event: "outcome", time: now(),
                                            candidate: item.candidate, outcome: outcome, counts: nil))
        }
        receipt.finishedAt = now()
        try journal.append(JournalEvent(event: "finished", time: now(),
                                        candidate: nil, outcome: nil, counts: receipt.counts))
        try output.write(receipt)
        return try object(receipt)
    }

    /// This is a separate, explicitly confirmed operation. It never scans a
    /// directory or infers ownership from a suffix. Only completed rebuild
    /// outcomes, bound to their original plan/report and journal, can remove
    /// a partial after all three complete file contents are checked again.
    static func cleanup(receipt receiptURL: URL, result resultURL: URL) throws -> [String: Any] {
        let receiptData = try readDocument(receiptURL, maximum: 32 * 1024 * 1024)
        let receipt = try JSONDecoder().decode(Receipt.self, from: receiptData)
        guard receipt.schemaVersion == 1, receipt.kind == "local-partial-recovery-receipt",
              receipt.finishedAt != nil else { throw Failure("只接受完整完成的修復收據；中斷作業不能授權清理。") }
        let planData = try readDocument(URL(fileURLWithPath: receipt.planPath), maximum: 32 * 1024 * 1024)
        guard digest(planData) == receipt.planSHA256 else { throw Failure("修復計畫已改變，不清理暫存檔。") }
        let plan = try JSONDecoder().decode(Plan.self, from: planData)
        let report = try parseReport(URL(fileURLWithPath: plan.reportPath))
        guard plan.schemaVersion == 1, plan.kind == "local-partial-recovery-plan",
              report.sha256 == plan.reportSHA256, report.sha256 == receipt.reportSHA256,
              report.path == receipt.reportPath, report.sourceRoot == plan.sourceRoot,
              report.destinationRoot == plan.destinationRoot,
              report.sourceRoot == receipt.sourceRoot, report.destinationRoot == receipt.destinationRoot else {
            throw Failure("收據、計畫與原始報表不一致，不清理暫存檔。")
        }
        let allowed = Dictionary(uniqueKeysWithValues: report.candidates.map { ($0.id, $0) })
        var planned: [String: Item] = [:]
        for item in plan.items {
            guard allowed[item.candidate.id] == item.candidate, planned[item.candidate.id] == nil,
                  ["ready", "existing", "mismatch", "blocked"].contains(item.status) else {
                throw Failure("計畫含有未列入原始報表的項目，不清理暫存檔。")
            }
            planned[item.candidate.id] = item
        }
        var seen = Set<String>()
        for item in receipt.items {
            guard planned[item.candidate.id]?.candidate == item.candidate,
                  seen.insert(item.candidate.id).inserted else {
                throw Failure("收據插入了重複或未列入計畫的項目，不清理暫存檔。")
            }
        }
        try verifyRecoveryJournal(receipt)
        let roots = try openRoots(report)
        guard roots.source.identity == plan.sourceRootIdentity,
              roots.destination.identity == plan.destinationRootIdentity else {
            throw Failure("來源或目的根目錄已改變，不清理暫存檔。")
        }
        let output = try ExclusiveOutput(resultURL, outside: report, roots: roots)
        let journalURL = URL(fileURLWithPath: try documentPath(resultURL) + ".journal.jsonl")
        let journal = try ExclusiveOutput(journalURL, outside: report, roots: roots, appendOnly: true)
        var result = CleanupReceipt(schemaVersion: 1, kind: "local-partial-cleanup-receipt",
                                    startedAt: now(), finishedAt: nil,
                                    recoveryReceiptPath: try documentPath(receiptURL),
                                    recoveryReceiptSHA256: digest(receiptData), journalPath: journalURL.path,
                                    planPath: receipt.planPath, planSHA256: receipt.planSHA256,
                                    reportPath: report.path, reportSHA256: report.sha256,
                                    sourceRoot: report.sourceRoot, destinationRoot: report.destinationRoot,
                                    items: [], counts: ["total": receipt.items.count, "removed": 0, "skipped": 0, "failed": 0])
        try output.write(result)
        try journal.append(result)
        for recovered in receipt.items {
            let outcome: Outcome
            if recovered.status != "recovered" || recovered.method != "verified-exclusive-copy" ||
                recovered.partialRetained != true {
                outcome = Outcome(candidate: recovered.candidate, status: "skipped",
                                  message: "此項目不是完整驗證且保留暫存檔的重建結果，不清理。",
                                  clearedUserImmutable: false, method: "verified-partial-cleanup")
            } else {
                try journal.append(JournalEvent(event: "cleanup-intent", time: now(),
                                                candidate: recovered.candidate, outcome: nil, counts: nil))
                do {
                    guard let item = planned[recovered.candidate.id], item.status == "ready",
                          let expectedSource = item.source, let originalPartial = item.temporary,
                          let expectedPartial = recovered.retainedPartial, let expectedFinal = recovered.newOutput,
                          let sourceParentIdentity = item.sourceParent,
                          let destinationParentIdentity = item.destinationParent,
                          let hash = item.sha256, validHash(hash),
                          expectedPartial.sameContentState(as: originalPartial),
                          expectedPartial.flags == originalPartial.flags,
                          expectedFinal.size == originalPartial.size,
                          recovered.bytesWritten == originalPartial.size else {
                        throw Failure("收據缺少可驗證的新檔或原暫存檔身分，不清理。")
                    }
                    let original = try relativeComponents(item.candidate.relativePath)
                    let temporary = try relativeComponents(item.candidate.temporaryRelativePath)
                    let sourceParent = try roots.source.appending(Array(original.dropLast()))
                    let destinationParent = try roots.destination.appending(Array(temporary.dropLast()))
                    guard sourceParent.identity == sourceParentIdentity,
                          destinationParent.identity == destinationParentIdentity else {
                        throw Failure("清理目錄已改變，原暫存檔保留。")
                    }
                    let source = try BoundFile(parent: sourceParent, leaf: original.last!)
                    let partial = try BoundFile(parent: destinationParent, leaf: temporary.last!)
                    let final = try BoundFile(parent: destinationParent, leaf: original.last!)
                    _ = try source.validate(expected: expectedSource)
                    _ = try partial.validate(expected: expectedPartial)
                    _ = try final.validate(expected: expectedFinal)
                    try validatePair(expectedSource, expectedPartial)
                    guard expectedFinal.links == 1, expectedFinal.node != expectedPartial.node,
                          expectedFinal.node != expectedSource.node else {
                        throw Failure("正式檔與其他檔案連結或身分重疊，不清理。")
                    }
                    guard try stableHash(source).digest == hash,
                          try stableHash(partial).digest == hash,
                          try stableHash(final).digest == hash else {
                        throw Failure("來源、暫存檔或正式檔的完整 SHA-256 不符，原暫存檔保留。")
                    }
                    _ = try source.validate(expected: expectedSource)
                    _ = try partial.validate(expected: expectedPartial)
                    _ = try final.validate(expected: expectedFinal)
                    let cleared = try removeVerifiedPartial(partial, expected: expectedPartial,
                                                            source: source, expectedSource: expectedSource,
                                                            final: final, expectedFinal: expectedFinal)
                    outcome = Outcome(candidate: recovered.candidate, status: "removed",
                                      message: "已重新核對來源與本次重建正式檔的完整內容，並清理這一個原暫存檔。",
                                      clearedUserImmutable: cleared, method: "verified-partial-cleanup",
                                      partialRetained: false)
                } catch {
                    outcome = Outcome(candidate: recovered.candidate, status: "failed",
                                      message: error.localizedDescription, clearedUserImmutable: nil,
                                      method: "verified-partial-cleanup", errorCode: (error as? Failure)?.code)
                }
            }
            result.items.append(outcome)
            result.counts[outcome.status, default: 0] += 1
            try journal.append(JournalEvent(event: "outcome", time: now(), candidate: recovered.candidate,
                                            outcome: outcome, counts: nil))
        }
        result.finishedAt = now()
        try journal.append(JournalEvent(event: "finished", time: now(), candidate: nil,
                                        outcome: nil, counts: result.counts))
        try output.write(result)
        return try object(result)
    }

    private static func verifyRecoveryJournal(_ receipt: Receipt) throws {
        let data = try readDocument(URL(fileURLWithPath: receipt.journalPath), maximum: 64 * 1024 * 1024)
        let lines = data.split(separator: 10, omittingEmptySubsequences: true)
        guard let first = lines.first, lines.count <= 200_000 else { throw Failure("原修復日誌不完整。") }
        let initial = try JSONDecoder().decode(Receipt.self, from: Data(first))
        guard initial.schemaVersion == receipt.schemaVersion, initial.kind == receipt.kind,
              initial.startedAt == receipt.startedAt, initial.finishedAt == nil, initial.items.isEmpty,
              initial.planPath == receipt.planPath, initial.planSHA256 == receipt.planSHA256,
              initial.reportPath == receipt.reportPath, initial.reportSHA256 == receipt.reportSHA256,
              initial.sourceRoot == receipt.sourceRoot, initial.destinationRoot == receipt.destinationRoot,
              initial.journalPath == receipt.journalPath else { throw Failure("收據與原修復日誌不一致。") }
        var completed: [String: Outcome] = [:]
        var last: JournalEvent?
        for line in lines.dropFirst() {
            let event = try JSONDecoder().decode(JournalEvent.self, from: Data(line))
            if event.event == "outcome" {
                guard let item = event.outcome, event.candidate == item.candidate,
                      completed[item.candidate.id] == nil else { throw Failure("修復日誌含有重複或不完整結果。") }
                completed[item.candidate.id] = item
            }
            last = event
        }
        guard last?.event == "finished", last?.counts == receipt.counts,
              completed.count == receipt.items.count,
              receipt.items.allSatisfy({ completed[$0.candidate.id] == $0 }) else {
            throw Failure("收據內容與已完成的原修復日誌不一致，不清理暫存檔。")
        }
    }

    private static func removeVerifiedPartial(_ partial: BoundFile, expected: Snapshot,
                                               source: BoundFile, expectedSource: Snapshot,
                                               final: BoundFile, expectedFinal: Snapshot) throws -> Bool {
        let immutable = UInt32(UF_IMMUTABLE)
        let cleared = expected.flags & immutable != 0
        if cleared && Darwin.fchflags(partial.descriptor.raw, expected.flags & ~immutable) != 0 {
            throw systemFailure("無法解除這一個已驗證暫存檔的鎖定，未清理")
        }
        do {
            let unlocked = try partial.validate()
            guard unlocked.sameContentState(as: expected), unlocked.flags == expected.flags & ~immutable else {
                throw Failure("暫存檔在解除鎖定期間改變，未清理。")
            }
            _ = try source.validate(expected: expectedSource)
            _ = try final.validate(expected: expectedFinal)
            // Darwin has no inode-conditional unlink. As with rename, the UI
            // requires other writers to stop; held parent/file descriptors
            // and immediate binding checks prevent following substitutions.
            guard Darwin.unlinkat(partial.parent.fd, partial.leaf, 0) == 0 else {
                throw systemFailure("清理指定暫存檔失敗")
            }
        } catch {
            if cleared && Darwin.fchflags(partial.descriptor.raw, expected.flags) != 0 {
                throw Failure("\(error.localizedDescription)；原暫存檔鎖定還原失敗，請檢查此檔案。")
            }
            throw error
        }
        return cleared
    }

    private static func parseReport(_ url: URL) throws -> Report {
        let data = try readDocument(url, maximum: 64 * 1024 * 1024)
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw Failure("報表不是有效的 UTF-8 JSONL。")
        }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard !lines.isEmpty, lines.count <= 200_000 else { throw Failure("報表筆數超出可安全處理的範圍。") }
        var rows: [[String: Any]] = []
        var previousSequence = 0
        for line in lines {
            guard line.utf8.count <= 256 * 1024,
                  let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let number = row["sequence"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue == Double(number.intValue), number.intValue > previousSequence else {
                throw Failure("報表含有無效 JSON、過長記錄或不連續遞增的 sequence。")
            }
            previousSequence = number.intValue
            rows.append(row)
        }
        guard let first = rows.first, first["action"] as? String == "configuration",
              first["evidence"] as? String == "app-configuration",
              first["sequence"] as? Int == 1,
              let configuration = first["configuration"] as? [String: Any],
              configuration["kind"] as? String == "complete",
              configuration["schemaVersion"] as? Int == 1,
              let request = configuration["request"] as? [String: Any],
              ["copy", "sync", "move"].contains(request["mode"] as? String ?? ""),
              let dryRun = request["dryRun"] as? NSNumber, CFGetTypeID(dryRun) == CFBooleanGetTypeID(),
              !dryRun.boolValue,
              let source = request["source"] as? [String: Any],
              let destination = request["destination"] as? [String: Any],
              source["remote"] == nil || source["remote"] is NSNull,
              destination["remote"] == nil || destination["remote"] is NSNull,
              let sourceText = source["path"] as? String,
              let destinationText = destination["path"] as? String,
              let selection = request["selection"] as? [[String: Any]],
              rows.filter({ $0["action"] as? String == "configuration" }).count == 1 else {
            throw Failure("只接受含完整設定的本機 copy／sync／move 正式傳輸報表。")
        }
        let sourceRoot = try normalizedRoot(sourceText)
        let destinationRoot = try normalizedRoot(destinationText)
        guard !pathsOverlap(sourceRoot, destinationRoot) else { throw Failure("來源與目的目錄不能重疊。") }
        var scope: [(String, Bool)] = []
        for entry in selection {
            guard let name = entry["name"] as? String,
                  let directory = entry["isDir"] as? NSNumber,
                  CFGetTypeID(directory) == CFBooleanGetTypeID(),
                  try relativeComponents(name).count == 1 else {
                throw Failure("報表的選取範圍格式不正確。")
            }
            scope.append((name, directory.boolValue))
        }
        func inScope(_ path: String) -> Bool {
            scope.isEmpty || scope.contains { path == $0.0 || ($0.1 && path.hasPrefix($0.0 + "/")) }
        }
        var missing = Set<String>()
        for row in rows where row["action"] as? String == "missing-destination" {
            guard row["evidence"] as? String == "comparison",
                  row["status"] as? String == "candidate", let path = row["path"] as? String else {
                throw Failure("缺少可信的來源候選路徑。")
            }
            _ = try relativeComponents(path)
            guard inScope(path) else { throw Failure("報表含有選取範圍以外的來源候選。") }
            missing.insert(path)
        }
        var candidates: [Candidate] = []
        var excluded: [Excluded] = []
        var seen = Set<String>()
        for row in rows where row["action"] as? String == "rename" && row["status"] as? String == "error" {
            guard row["evidence"] as? String == "json-log",
                  let partial = row["path"] as? String, let message = row["message"] as? String,
                  let sequence = row["sequence"] as? Int else { throw Failure("改名失敗記錄不完整。") }
            let components = try relativeComponents(partial)
            guard seen.insert(partial).inserted else { continue }
            let leaf = components.last!
            let validSuffix = leaf.range(of: #"\.[0-9a-f]{8}\.partial$"#, options: .regularExpression) != nil
            let original = validSuffix ? String(partial.dropLast(17)) : ""
            if validSuffix && !inScope(original) {
                throw Failure("報表含有選取範圍以外的暫存檔。")
            }
            let expectedMessage = "partial file rename failed: rename \(destinationRoot)/\(partial) \(destinationRoot)/\(original): operation not permitted"
            guard validSuffix, leaf.utf8.count <= 97, !original.isEmpty,
                  missing.contains(original), inScope(original), message == expectedMessage else {
                excluded.append(Excluded(sequence: sequence, temporaryRelativePath: partial,
                                         reason: "無法從原始候選與完整 rename 訊息精確配對，或屬於長名截斷／其他錯誤；不自動改名。"))
                continue
            }
            _ = try relativeComponents(original)
            let id = digest(Data((original + "\0" + partial).utf8))
            candidates.append(Candidate(id: id, relativePath: original,
                                        temporaryRelativePath: partial, renameSequence: sequence))
        }
        guard candidates.count + excluded.count <= 10_000 else { throw Failure("修復項目過多，請使用較小範圍的報表。") }
        return Report(path: try documentPath(url), sha256: digest(data),
                      sourceRoot: sourceRoot, destinationRoot: destinationRoot,
                      candidates: candidates, excluded: excluded)
    }

    private struct Roots { let source: DirectoryChain; let destination: DirectoryChain }

    private static func openRoots(_ report: Report) throws -> Roots {
        let source = try DirectoryChain.absolute(report.sourceRoot)
        let destination = try DirectoryChain.absolute(report.destinationRoot)
        guard !destination.nodes.contains(where: { $0.identity == source.identity }),
              !source.nodes.contains(where: { $0.identity == destination.identity }) else {
            throw Failure("來源與目的實際目錄重疊或指向相同位置。")
        }
        return Roots(source: source, destination: destination)
    }

    private static func validatePair(_ source: Snapshot, _ partial: Snapshot) throws {
        guard partial.links == 1, source.node != partial.node else {
            throw Failure("暫存檔是硬連結或與來源相同，不進行修復。")
        }
    }

    private static func requireStableEmptyFileIdentity(_ file: BoundFile, snapshot: Snapshot) throws {
        guard snapshot.size == 0 else { return }
        var information = statfs()
        guard Darwin.fstatfs(file.descriptor.raw, &information) == 0 else {
            throw systemFailure("無法確認空檔案所在磁碟的識別能力")
        }
        let capacity = MemoryLayout.size(ofValue: information.f_fstypename)
        let fileSystem = withUnsafePointer(to: &information.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
        // Apple's FAT driver uses a shared synthetic inode (FILENO_EMPTY)
        // for empty files with no allocated cluster. Conservatively decline
        // empty card files, rather than treating a shared number as identity.
        guard fileSystem != "msdos" && fileSystem != "exfat" else {
            throw Failure("此記憶卡格式的空檔無法保證唯一檔案身分，不自動改名。")
        }
    }

    private static func stableHash(_ file: BoundFile) throws -> (digest: String, snapshot: Snapshot) {
        let before = try file.validate()
        var hash = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        var offset: Int64 = 0
        while offset < before.size {
            let wanted = min(buffer.count, Int(min(before.size - offset, Int64(buffer.count))))
            let count = buffer.withUnsafeMutableBytes {
                Darwin.pread(file.descriptor.raw, $0.baseAddress, wanted, off_t(offset))
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw systemFailure("讀取檔案內容失敗：\(file.leaf)") }
            hash.update(data: Data(buffer.prefix(count)))
            offset += Int64(count)
        }
        _ = try file.validate(expected: before)
        return (hash.finalize().map { String(format: "%02x", $0) }.joined(), before)
    }

    /// This is an atomic no-replace rename. On failure, flags are restored
    /// through the still-open descriptor, never by reopening a possibly replaced name.
    private static func commit(partial: BoundFile, expected: Snapshot, finalLeaf: String,
                               forceUnsupported: Bool = false) throws -> Bool {
        _ = try partial.validate(expected: expected)
        guard expected.links == 1 else { throw Failure("暫存檔已變成硬連結，未改名。") }
        let immutable = UInt32(UF_IMMUTABLE)
        let cleared = expected.flags & immutable != 0
        var renamed = false
        if cleared {
            guard Darwin.fchflags(partial.descriptor.raw, expected.flags & ~immutable) == 0 else {
                throw systemFailure("無法解除這個暫存檔的鎖定")
            }
        }
        do {
            let unlocked = try partial.validate()
            guard unlocked.sameContentState(as: expected),
                  unlocked.flags == expected.flags & ~immutable else {
                throw Failure("暫存檔在解除鎖定期間改變，未改名。")
            }
            // There is never a fallback to rename(), FileManager.moveItem,
            // shell mv, or deletion. Unsupported filesystems may instead use
            // an explicitly reported, exclusive new copy after flag rollback.
            let status: Int32
            if forceUnsupported { errno = ENOTSUP; status = -1 }
            else {
                status = Darwin.renameatx_np(partial.parent.fd, partial.leaf,
                                            partial.parent.fd, finalLeaf, UInt32(RENAME_EXCL))
            }
            if status != 0 {
                let failureCode = errno
                if failureCode == ENOTSUP || failureCode == ENOSYS {
                    throw UnsupportedExclusiveRename(code: failureCode)
                }
                throw systemFailure("正式檔名已存在或無法原子改名", code: failureCode)
            }
            renamed = true
            var committed = stat()
            var held = stat()
            guard Darwin.fstatat(partial.parent.fd, finalLeaf, &committed, AT_SYMLINK_NOFOLLOW) == 0,
                  Darwin.fstat(partial.descriptor.raw, &held) == 0,
                  committed.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  NodeIdentity(committed) == expected.node,
                  Snapshot(held).sameContentState(as: expected),
                  held.st_flags == expected.flags & ~immutable else {
                throw Failure("改名後的身分或內容狀態異常。")
            }
        } catch {
            let phase = renamed ? "檔名已改動，但提交後核對未通過；請檢查正式檔名與收據。" : ""
            if cleared && Darwin.fchflags(partial.descriptor.raw, expected.flags) != 0 {
                throw Failure("\(phase)\(error.localizedDescription)；原鎖定旗標還原失敗：\(String(cString: strerror(errno)))。請檢查此檔案，未刪除任何內容。")
            }
            if renamed { throw Failure("\(phase)\(error.localizedDescription)原有鎖定旗標已保留或還原，未刪除任何內容。") }
            throw error
        }
        return cleared
    }

    /// A distinct recovery method for a filesystem without exclusive rename.
    /// The only writable descriptor comes from O_CREAT|O_EXCL. A partial
    /// output is never deleted or silently treated as recovered. Its durable
    /// journal remains conservative until the final recovered outcome exists.
    private static func rebuild(candidate: Candidate, source: BoundFile, expectedSource: Snapshot,
                                partial: BoundFile, expectedPartial: Snapshot, expectedHash: String,
                                finalLeaf: String, renameErrno: Int32, journal: ExclusiveOutput,
                                testOptions: TestOptions?) throws -> Outcome {
        var created: Descriptor?
        var output: BoundFile?
        var lastOutput: Snapshot?
        var creationIdentity: NodeIdentity?
        var initialEmptyIdentity: NodeIdentity?
        var pinnedIdentity: NodeIdentity?
        var bytesWritten: Int64 = 0

        func record(_ event: String) throws {
            let pending = Outcome(candidate: candidate,
                                  status: created == nil ? "pending-rebuild" : "failed-new-output",
                                  message: "新檔尚未確認完成；只有後續 recovered outcome 才表示完整修復。原暫存檔保留。",
                                  clearedUserImmutable: false, method: "verified-exclusive-copy",
                                  partialRetained: true, renameErrno: renameErrno,
                                  newOutput: lastOutput, bytesWritten: bytesWritten,
                                  retainedPartial: expectedPartial)
            do {
                try journal.append(JournalEvent(event: event, time: now(), candidate: candidate,
                                                outcome: pending, counts: nil))
            } catch { throw JournalStorageFailure(underlying: error) }
        }

        func validateOutput(finalizeIdentity: Bool = false) throws -> Snapshot {
            guard let output = output else { throw Failure("尚未建立新檔。") }
            let current = try output.validate()
            guard let creationIdentity = creationIdentity,
                  current.node.device == creationIdentity.device,
                  current.links == 1, current.size == bytesWritten,
                  current.node != expectedSource.node, current.node != expectedPartial.node,
                  current.flags & UInt32(UF_IMMUTABLE) == 0 else {
                throw Failure("新檔的身分、大小或保護狀態異常，未確認修復完成。")
            }
            if let pinnedIdentity = pinnedIdentity, current.node != pinnedIdentity {
                throw Failure("新檔配置內容後的檔案身分改變，未確認修復完成。")
            }
            // FAT-family drivers can retain the creation ID or report a
            // different ID only after content and metadata have been flushed.
            // Pin the first changed ID immediately. If it never changes, pin
            // the current name/held-FD binding after all our writes complete;
            // equality with the creation ID is not evidence of an empty file.
            if pinnedIdentity == nil, let empty = initialEmptyIdentity,
               current.size > 0, current.node != empty {
                pinnedIdentity = current.node
            }
            if finalizeIdentity {
                if pinnedIdentity == nil { pinnedIdentity = current.node }
                guard pinnedIdentity == current.node else {
                    throw Failure("新檔完成資料、修改時間與同步後的身分不一致，未確認修復完成。")
                }
            }
            return current
        }

        do {
            _ = try source.validate(expected: expectedSource)
            _ = try partial.validate(expected: expectedPartial)
            guard try stableHash(source).digest == expectedHash,
                  try stableHash(partial).digest == expectedHash else {
                throw Failure("開始重建前內容已改變，未建立新檔。")
            }
            _ = try source.validate(expected: expectedSource)
            _ = try partial.validate(expected: expectedPartial)
            try record("rebuild-intent")
            try testOptions?.beforeExclusiveCreate?()
            try partial.parent.validate()
            let raw = Darwin.openat(partial.parent.fd, finalLeaf,
                                    O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                                    mode_t(0o600))
            guard raw >= 0 else { throw systemFailure("無法以不覆寫方式建立正式檔名") }
            let handle = Descriptor(raw)
            created = handle
            let newFile = try BoundFile(parent: partial.parent, leaf: finalLeaf, descriptor: handle)
            output = newFile
            let initial = try newFile.validate()
            creationIdentity = initial.node
            var fileSystemInfo = statfs()
            guard Darwin.fstatfs(raw, &fileSystemInfo) == 0 else { throw systemFailure("無法確認新檔的身分配置方式") }
            let fileSystem = withUnsafeBytes(of: fileSystemInfo.f_fstypename) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
            if initial.size == 0 && ["msdos", "exfat"].contains(fileSystem) {
                initialEmptyIdentity = initial.node
            } else {
                pinnedIdentity = initial.node
            }
            lastOutput = try validateOutput()
            try record("rebuild-created")

            var hash = SHA256()
            var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
            while bytesWritten < expectedPartial.size {
                let wanted = Int(min(Int64(buffer.count), expectedPartial.size - bytesWritten))
                let readCount = buffer.withUnsafeMutableBytes {
                    Darwin.pread(partial.descriptor.raw, $0.baseAddress, wanted, off_t(bytesWritten))
                }
                if readCount < 0 && errno == EINTR { continue }
                guard readCount > 0 else { throw systemFailure("重建時無法讀取原暫存檔") }
                var consumed = 0
                while consumed < readCount {
                    let written = buffer.withUnsafeBytes {
                        Darwin.pwrite(raw, $0.baseAddress!.advanced(by: consumed), readCount - consumed,
                                      off_t(bytesWritten))
                    }
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw systemFailure("新檔寫入失敗；原暫存檔保留") }
                    consumed += written
                    bytesWritten += Int64(written)
                }
                hash.update(data: Data(buffer.prefix(readCount)))
                guard Darwin.fsync(raw) == 0 else { throw systemFailure("新檔內容無法同步至磁碟") }
                lastOutput = try validateOutput()
                _ = try source.validate(expected: expectedSource)
                _ = try partial.validate(expected: expectedPartial)
                try record("rebuild-progress")
                testOptions?.afterDurableProgress?()
            }
            let copiedHash = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard copiedHash == expectedHash else { throw Failure("重建串流的 SHA-256 不符，原暫存檔保留。") }

            let times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
                         timespec(tv_sec: Int(expectedSource.modifiedSeconds),
                                  tv_nsec: Int(expectedSource.modifiedNanoseconds))]
            let timeResult = times.withUnsafeBufferPointer { Darwin.futimens(raw, $0.baseAddress) }
            guard timeResult == 0 else { throw systemFailure("無法保留新檔修改時間") }
            guard Darwin.fsync(raw) == 0 else { throw systemFailure("新檔修改時間無法同步至磁碟") }
            lastOutput = try validateOutput(finalizeIdentity: true)
            guard let final = output, let finalState = lastOutput,
                  try modificationTimeMatches(finalState, expectedSource, descriptor: raw) else {
                throw Failure("新檔未能保留來源修改時間，未確認修復完成。")
            }
            let finalHash = try stableHash(final)
            let sourceHash = try stableHash(source)
            let partialHash = try stableHash(partial)
            guard finalHash.snapshot == finalState,
                  finalHash.digest == expectedHash, sourceHash.digest == expectedHash,
                  partialHash.digest == expectedHash else {
                throw Failure("重建後完整 SHA-256 核對未通過，原暫存檔保留。")
            }
            _ = try source.validate(expected: expectedSource)
            _ = try partial.validate(expected: expectedPartial)
            lastOutput = try final.validate(expected: finalHash.snapshot)
            return Outcome(candidate: candidate, status: "recovered",
                           message: "已建立並完整核對正式檔名的新副本；原有 .partial 及其鎖定保留，未使用原子改名。",
                           clearedUserImmutable: false, method: "verified-exclusive-copy",
                           partialRetained: true, renameErrno: renameErrno,
                           newOutput: lastOutput, bytesWritten: bytesWritten,
                           retainedPartial: expectedPartial)
        } catch let storage as JournalStorageFailure {
            throw storage
        } catch {
            // Even a zero-length or interrupted output is retained. We never
            // reopen a path for writing, truncate an existing file, or unlink.
            if let created = created {
                var value = stat()
                if Darwin.fstat(created.raw, &value) == 0 { lastOutput = Snapshot(value) }
            }
            let retained: Bool? = (try? partial.validate(expected: expectedPartial)) != nil ? true : nil
            let code = (error as? Failure)?.code
            let status = created != nil ? "failed-new-output" : code == EEXIST ? "skipped" : "failed"
            let message = created != nil
                ? "新正式檔名已建立但尚未確認完成，不能視為修復成功；保留此新檔與原 .partial，請依收據檢查。\(error.localizedDescription)"
                : "未完成新副本建立，原 .partial 保留。\(error.localizedDescription)"
            return Outcome(candidate: candidate, status: status, message: message,
                           clearedUserImmutable: false, method: "verified-exclusive-copy",
                           partialRetained: retained, renameErrno: renameErrno, errorCode: code,
                           newOutput: lastOutput, bytesWritten: bytesWritten,
                           retainedPartial: retained == true ? expectedPartial : nil)
        }
    }

    private static func modificationTimeMatches(_ actual: Snapshot, _ original: Snapshot,
                                                 descriptor: Int32) throws -> Bool {
        var info = statfs()
        guard Darwin.fstatfs(descriptor, &info) == 0 else { throw systemFailure("無法核對新檔時間精度") }
        let fileSystem = withUnsafeBytes(of: info.f_fstypename) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        if let precision = EngineLocalTimePrecision.precision(for: fileSystem) {
            let difference = Double(actual.modifiedSeconds - original.modifiedSeconds) +
                Double(actual.modifiedNanoseconds - original.modifiedNanoseconds) / 1_000_000_000
            return abs(difference) <= precision.seconds
        }
        return actual.modifiedSeconds == original.modifiedSeconds &&
            actual.modifiedNanoseconds == original.modifiedNanoseconds
    }

    /// Tests exercise the same commit path, including an already-existing
    /// destination after validation. No caller-controlled plan can invoke this
    /// primitive without the public apply() checks.
    static func testAtomicCommit(directory: URL, temporaryName: String, finalName: String) throws {
        guard try relativeComponents(temporaryName).count == 1,
              try relativeComponents(finalName).count == 1 else { throw Failure("測試檔名不合法。") }
        let parent = try DirectoryChain.absolute(try documentPath(directory))
        let partial = try BoundFile(parent: parent, leaf: temporaryName)
        _ = try commit(partial: partial, expected: partial.validate(), finalLeaf: finalName)
    }

    private final class ExclusiveOutput {
        let parent: DirectoryChain
        let leaf: String
        let descriptor: Descriptor
        let identity: NodeIdentity
        let appendOnly: Bool

        init(_ url: URL, outside report: Report, roots: Roots, appendOnly: Bool = false) throws {
            let path = try documentPath(url)
            guard !pathsOverlap(path, report.sourceRoot), !pathsOverlap(path, report.destinationRoot),
                  path != report.path else { throw Failure("計畫與收據必須儲存在來源及目的目錄以外。") }
            let components = try absoluteComponents(path)
            parent = try DirectoryChain.absolute("/" + components.dropLast().joined(separator: "/"))
            guard !parent.nodes.contains(where: { $0.identity == roots.source.identity || $0.identity == roots.destination.identity }) else {
                throw Failure("輸出目錄實際位於來源或目的目錄內。")
            }
            leaf = components.last!
            let raw = Darwin.openat(parent.fd, leaf,
                                   O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | (appendOnly ? O_APPEND : 0),
                                   mode_t(0o600))
            guard raw >= 0 else { throw systemFailure("輸出檔已存在或無法建立；請選擇新檔名") }
            descriptor = Descriptor(raw)
            var value = stat()
            guard Darwin.fstat(raw, &value) == 0, value.st_nlink == 1 else {
                throw Failure("無法確認輸出檔案身分。")
            }
            identity = NodeIdentity(value)
            self.appendOnly = appendOnly
        }

        func write<T: Encodable>(_ value: T) throws {
            guard !appendOnly else { throw Failure("附加式日誌不能覆寫。") }
            try persist(value, append: false)
        }

        func append<T: Encodable>(_ value: T) throws {
            guard appendOnly else { throw Failure("只允許對專用日誌附加紀錄。") }
            try persist(value, append: true)
        }

        private func persist<T: Encodable>(_ value: T, append: Bool) throws {
            try parent.validate()
            var opened = stat()
            var named = stat()
            guard Darwin.fstat(descriptor.raw, &opened) == 0,
                  Darwin.fstatat(parent.fd, leaf, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  named.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  opened.st_nlink == 1, named.st_nlink == 1,
                  NodeIdentity(opened) == identity, NodeIdentity(named) == identity else {
                throw Failure("輸出檔被替換或連結，已停止處理。")
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = append ? [.sortedKeys] : [.prettyPrinted, .sortedKeys]
            var data = try encoder.encode(value)
            data.append(10)
            if !append {
                guard Darwin.lseek(descriptor.raw, 0, SEEK_SET) == 0,
                      Darwin.ftruncate(descriptor.raw, 0) == 0 else { throw systemFailure("無法更新修復收據") }
            }
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(descriptor.raw, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw systemFailure("修復收據寫入失敗") }
                    offset += count
                }
            }
            guard Darwin.fsync(descriptor.raw) == 0 else { throw systemFailure("修復收據無法同步至磁碟") }
        }
    }

    private static func readDocument(_ url: URL, maximum: Int) throws -> Data {
        let parts = try absoluteComponents(documentPath(url))
        let parent = try DirectoryChain.absolute("/" + parts.dropLast().joined(separator: "/"))
        let file = try BoundFile(parent: parent, leaf: parts.last!)
        let before = try file.validate()
        guard before.size > 0, before.size <= Int64(maximum) else { throw Failure("報表或計畫大小不正確。") }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var offset: Int64 = 0
        while offset < before.size {
            let wanted = min(buffer.count, Int(before.size - offset))
            let count = buffer.withUnsafeMutableBytes {
                Darwin.pread(file.descriptor.raw, $0.baseAddress, wanted, off_t(offset))
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw systemFailure("無法讀取報表或計畫") }
            data.append(contentsOf: buffer.prefix(count))
            offset += Int64(count)
        }
        _ = try file.validate(expected: before)
        return data
    }

    private static func exists(parent: DirectoryChain, leaf: String) throws -> Bool {
        try parent.validate()
        var value = stat()
        if Darwin.fstatat(parent.fd, leaf, &value, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        guard errno == ENOENT else { throw systemFailure("無法確認正式檔名是否已存在") }
        return false
    }
    private static func directoryStat(_ fd: Int32) throws -> stat {
        var value = stat()
        guard Darwin.fstat(fd, &value) == 0,
              value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw Failure("路徑不是可讀取的一般目錄。")
        }
        return value
    }
    private static func normalizedRoot(_ text: String) throws -> String {
        var path = text
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        _ = try absoluteComponents(path)
        guard path != "/" else { throw Failure("不接受整個檔案系統作為修復根目錄。") }
        return path
    }
    private static func documentPath(_ url: URL) throws -> String {
        guard url.isFileURL else { throw Failure("只接受本機檔案路徑。") }
        let path = url.path
        guard path != "/" else { throw Failure("必須指定檔案或測試目錄，不能使用檔案系統根目錄。") }
        _ = try absoluteComponents(path)
        return path
    }
    private static func absoluteComponents(_ path: String) throws -> [String] {
        guard path.hasPrefix("/") else { throw Failure("必須使用本機絕對路徑。") }
        if path == "/" { return [] }
        return try relativeComponents(String(path.dropFirst()))
    }
    private static func relativeComponents(_ path: String) throws -> [String] {
        let parts = path.components(separatedBy: "/")
        guard !parts.isEmpty, path.utf8.count <= 16 * 1024,
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else {
            throw Failure("路徑含有空名稱、控制字元、過長名稱或目錄穿越。")
        }
        return parts
    }
    private static func pathsOverlap(_ first: String, _ second: String) -> Bool {
        let a = first.precomposedStringWithCanonicalMapping.lowercased()
        let b = second.precomposedStringWithCanonicalMapping.lowercased()
        return a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }
    private static func validHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
    }
    private static func now() -> String { ISO8601DateFormatter().string(from: Date()) }
    private static func systemFailure(_ operation: String, code: Int32 = errno) -> Failure {
        Failure("\(operation)：errno \(code)（\(String(cString: strerror(code)))）", code: code)
    }
}
#endif
