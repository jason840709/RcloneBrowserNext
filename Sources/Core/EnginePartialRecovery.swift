#if os(macOS)
import Foundation
import CoreFoundation
import CryptoKit
import Darwin

/// A report-scoped, content-verified recovery for local rclone partial files.
/// Reports and plans are data. Neither can supply commands, extra target paths,
/// or permission changes. No operation writes to the source or deletes a file.
enum EnginePartialRecovery {
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        init(_ message: String) { self.message = message }
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
    private struct Outcome: Codable {
        let candidate: Candidate
        let status: String
        let message: String
        let clearedUserImmutable: Bool?
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
                                       "recovered": 0, "skipped": report.excluded.count, "failed": 0])
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
                        let unlocked = try commit(partial: partial, expected: expectedPartial,
                                                  finalLeaf: original.last!)
                        outcome = Outcome(candidate: item.candidate, status: "recovered",
                                          message: "已核對完整內容並恢復正式檔名。", clearedUserImmutable: unlocked)
                    }
                } catch {
                    outcome = Outcome(candidate: item.candidate, status: "failed",
                                      message: error.localizedDescription, clearedUserImmutable: nil)
                }
            }
            receipt.items.append(outcome)
            receipt.counts[outcome.status, default: 0] += 1
            try journal.append(JournalEvent(event: "outcome", time: now(),
                                            candidate: item.candidate, outcome: outcome, counts: nil))
        }
        receipt.finishedAt = now()
        try journal.append(JournalEvent(event: "finished", time: now(),
                                        candidate: nil, outcome: nil, counts: receipt.counts))
        try output.write(receipt)
        return try object(receipt)
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
    private static func commit(partial: BoundFile, expected: Snapshot, finalLeaf: String) throws -> Bool {
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
            // RENAME_EXCL is required. There is deliberately no fallback to
            // rename(), FileManager.moveItem, shell mv, or deletion.
            let status = Darwin.renameatx_np(partial.parent.fd, partial.leaf,
                                            partial.parent.fd, finalLeaf, UInt32(RENAME_EXCL))
            if status != 0 {
                if errno == ENOTSUP || errno == EINVAL || errno == ENOSYS {
                    throw Failure("此磁碟不支援原子且不覆寫的改名；保留暫存檔，不使用覆寫方式繼續。")
                }
                throw systemFailure("正式檔名已存在或無法原子改名")
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
    private static func systemFailure(_ operation: String) -> Failure {
        Failure("\(operation)：\(String(cString: strerror(errno)))")
    }
}
#endif
