import Foundation
#if canImport(Darwin)
import Darwin
#elseif os(Linux)
import Glibc
#endif

/// Completes only the empty-directory part of an interrupted local sync.
/// Candidates come from rclone's *filtered destination* directory listing.
/// Absence is checked against complete native source-parent listings: an SMB
/// entry that is listed but cannot be opened is present, never an orphan.
enum EngineLocalSyncDirectories {
    static let starting = "正在清理來源已不存在的空資料夾。"
    static let finished = "已清理 {} 個來源不存在的空資料夾。"
    static let planned = "預演：會清理 {} 個來源不存在的空資料夾。"
    static let removed = "已刪除來源不存在的空資料夾。"
    static let wouldRemove = "預演：會刪除來源不存在的空資料夾。"

    static func applies(to request: EngineTransferRequest) -> Bool {
        request.mode == "sync" && EngineLocalNames.applies(to: request)
    }

    static func listingFlags(for request: EngineTransferRequest, filter: URL?) -> [String] {
        var flags = EngineLocalNames.listingFlags(for: request) + ["--recursive", "--dirs-only", "--no-modtime"]
        if let filter = filter { flags.append("--filter-from=\(filter.path)") }
        if request.options.integer("maxDepth") >= 0 { flags.append("--max-depth=\(request.options.integer("maxDepth"))") }
        if request.options.flag("oneFileSystem") { flags.append("--one-file-system") }
        return flags
    }

    static func prune(source: URL, destination: URL, candidates: [String], maximum: Int,
                      dryRun: Bool, cancelled: () -> Bool, record: (String, Bool) throws -> Void) throws -> Int {
        #if os(macOS) || os(Linux)
        guard maximum != 0 else { return 0 }
        guard candidates.count <= 250_000 else { throw EngineError("空資料夾清理清單過大，已停止清理。") }
        // Validate the complete input before the first mutation.
        var seen = Set<Data>()
        var paths: [(String, [String])] = []
        for path in candidates {
            if !seen.insert(Data(path.utf8)).inserted { continue }
            let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !parts.isEmpty, parts.count <= 1024,
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.utf8.contains(0) }) else {
                throw EngineError("空資料夾清理清單含有不安全的路徑。")
            }
            paths.append((path, parts))
        }
        paths.sort { a, b in
            if a.1.count == b.1.count { return a.0 < b.0 }
            return a.1.count > b.1.count
        }
        let from = try Root(source.path), to = try Root(destination.path)
        guard from.identity != to.identity else { throw EngineError("來源與目的目錄不能相同。") }
        var count = 0, plannedPaths = Set<Data>()
        for (path, parts) in paths {
            if cancelled() { break }
            if maximum >= 0 && count >= maximum { break }
            try from.validate(); try to.validate()
            // This also protects unreadable, filtered and canonically equivalent
            // source entries. Only a positively absent component authorizes rmdir.
            guard try from.missing(parts) else { continue }
            guard let parent = try? to.chain(Array(parts.dropLast())) else { continue }
            let leaf = parts.last!
            guard let directory = try? parent.child(leaf), directory.identity.device == to.identity.device else { continue }
            let entries = try directory.names()
            let empty = entries.isEmpty || (dryRun && entries.allSatisfy { plannedPaths.contains(Data((path + "/" + $0).utf8)) })
            guard empty else { continue }
            if cancelled() { break }
            try from.validate(); try to.validate(); try parent.validate(); try directory.validate()
            guard try from.missing(parts) else { continue }
            if !dryRun {
                // AT_REMOVEDIR cannot unlink a symlink or a populated directory,
                // including a file added between our inspection and this call.
                guard unlinkat(parent.fd, leaf, AT_REMOVEDIR) == 0 else {
                    let code = errno
                    if [ENOENT, ENOTEMPTY, EEXIST, ENOTDIR].contains(code) { continue }
                    throw EngineError("無法刪除空資料夾：\(path)（\(String(cString: strerror(code)))）。")
                }
            }
            count += 1; plannedPaths.insert(Data(path.utf8))
            try record(path, dryRun)
        }
        return count
        #else
        return 0
        #endif
    }

    #if os(macOS) || os(Linux)
    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
        init(_ value: stat) { device = value.st_dev; inode = value.st_ino }
    }

    private final class Directory {
        let fd: Int32
        let identity: Identity
        let parent: Directory?
        let name: String
        init(fd: Int32, parent: Directory? = nil, name: String) throws {
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                close(fd); throw EngineError("目錄無法讀取，已停止空資料夾清理。")
            }
            self.fd = fd; identity = Identity(info); self.parent = parent; self.name = name
        }
        deinit { close(fd) }
        func child(_ name: String) throws -> Directory {
            let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw EngineError("子目錄無法讀取，保留該目錄。") }
            return try Directory(fd: next, parent: self, name: name)
        }
        func validate() throws {
            if let parent = parent {
                try parent.validate()
                var current = stat()
                guard fstatat(parent.fd, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                      current.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), Identity(current) == identity else {
                    throw EngineError("目錄路徑在清理期間改變，已停止清理。")
                }
            }
        }
        func names() throws -> [String] {
            // dup(fd) would share the directory offset and make later scans
            // falsely look empty. A fresh openat gets an independent cursor.
            let scan = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard scan >= 0 else { throw EngineError("無法完整讀取來源目錄，已停止清理。") }
            guard let stream = fdopendir(scan) else { close(scan); throw EngineError("無法完整讀取來源目錄，已停止清理。") }
            defer { closedir(stream) }
            var result: [String] = []
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw EngineError("來源目錄讀取不完整，已停止清理。") }
                    return result
                }
                var bytes = entry.pointee.d_name
                let capacity = MemoryLayout.size(ofValue: bytes)
                let name = withUnsafePointer(to: &bytes) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(validatingUTF8: $0) }
                }
                guard let name = name else { throw EngineError("來源有無法辨識的檔名，已停止清理。") }
                if name != "." && name != ".." { result.append(name) }
            }
        }
    }

    private final class Root {
        let path: String
        let directory: Directory
        var identity: Identity { directory.identity }
        init(_ path: String) throws {
            self.path = path
            let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw EngineError("同步位置無法讀取，已停止空資料夾清理。") }
            directory = try Directory(fd: fd, name: path)
            try validate()
        }
        func validate() throws {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), Identity(info) == identity else {
                throw EngineError("同步位置在清理期間改變，已停止清理。")
            }
        }
        func chain(_ parts: [String]) throws -> Directory {
            var current = directory
            for part in parts {
                current = try current.child(part)
                guard current.identity.device == identity.device else { throw EngineError("保留其他磁碟上的目錄。") }
            }
            return current
        }
        func missing(_ parts: [String]) throws -> Bool {
            var current = directory
            for (index, part) in parts.enumerated() {
                let entries = try current.names()
                if !entries.contains(part) {
                    // Case-insensitive filesystems may resolve a name whose
                    // spelling differs from the listing. Preserve that too.
                    var info = stat()
                    guard fstatat(current.fd, part, &info, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { return false }
                    try validate(); try current.validate()
                    return true
                }
                if index == parts.count - 1 { return false }
                // A listed but inaccessible source entry must protect its whole
                // destination subtree, even if openat reports ENOENT on SMB.
                guard let child = try? current.child(part), child.identity.device == identity.device else { return false }
                current = child
            }
            return false
        }
    }
    #endif
}
