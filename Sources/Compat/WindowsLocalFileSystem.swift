#if os(Windows)
import Foundation
import WinSDK

/// The Windows compatibility host avoids Foundation's URL resource-value path:
/// Swift 6.1.2 narrows file sizes to a signed 32-bit _off_t in _statxFile.
/// Remote browsing and transfers continue to use the shared rclone engine.
enum WindowsLocalFileSystem {
    private static let directory = DWORD(FILE_ATTRIBUTE_DIRECTORY)
    private static let reparsePoint = DWORD(FILE_ATTRIBUTE_REPARSE_POINT)
    private static let nameSurrogate = DWORD(0x20000000)

    private struct Entry {
        let name: String
        let attributes: DWORD
        let reparseTag: DWORD
        let bytes: UInt64
        let modified: UInt64

        var isDirectory: Bool { attributes & WindowsLocalFileSystem.directory != 0 }
        // Cloud placeholders can also be reparse points. Only name-surrogate
        // tags (including junctions and symbolic links) redirect traversal.
        var isLink: Bool {
            attributes & WindowsLocalFileSystem.reparsePoint != 0 && reparseTag & WindowsLocalFileSystem.nameSurrogate != 0
        }

        func json(formatter: ISO8601DateFormatter) throws -> [String: Any] {
            guard isDirectory || bytes <= UInt64(Int64.max) else { throw EngineError("檔案大小超出支援範圍。") }
            let date = Date(timeIntervalSince1970: Double(modified) / 10_000_000 - 11_644_473_600)
            return ["name": name, "path": name, "size": isDirectory ? Int64(-1) : Int64(bytes),
                    "modified": formatter.string(from: date), "isDir": isDirectory, "isLink": isLink]
        }
    }

    private final class OwnedHandle {
        let value: HANDLE
        private var closed = false
        init(_ value: HANDLE) { self.value = value }
        func close() {
            if !closed { closed = true; CloseHandle(value) }
        }
        deinit { close() }
    }

    private enum RemovalStep {
        case visit(String, Bool)
        case finish(String, OwnedHandle)
    }

    /// EngineEndpoint has already rejected relative paths, device namespaces
    /// and control characters. Preserve UNC shares and drive roots when adding
    /// the extended prefix; never use MAX_PATH-sized buffers for full paths.
    private static func windowsPath(_ path: String) -> String {
        var value = path.replacingOccurrences(of: "/", with: "\\")
        let bytes = Array(value.utf8.prefix(4))
        if bytes.count == 4, bytes[0] == 92,
           ((65...90).contains(bytes[1]) || (97...122).contains(bytes[1])), bytes[2] == 58, bytes[3] == 92 {
            value.removeFirst() // Foundation's RFC8089 /C:/... representation.
        }
        // The public endpoint was required to be absolute. If Foundation
        // presents a drive root without its separator, retain root semantics.
        if value.utf8.count == 2, value.last == ":" { value += "\\" }
        if value.hasPrefix("\\\\?\\") { return value }
        if value.hasPrefix("\\\\") { return "\\\\?\\UNC\\" + value.dropFirst(2) }
        return "\\\\?\\" + value
    }

    private static func childPath(_ parent: String, _ name: String) -> String {
        parent + (parent.hasSuffix("/") || parent.hasSuffix("\\") ? "" : "\\") + name
    }

    private static func error(_ operation: String, _ path: String, _ code: DWORD) -> EngineError {
        var buffer = [WCHAR](repeating: 0, count: 2048)
        let length = FormatMessageW(DWORD(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS),
                                    nil, code, DWORD(0), &buffer, DWORD(buffer.count), nil)
        let message = length > 0
            ? String(decoding: buffer.prefix(Int(length)), as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines)
            : "Windows filesystem operation failed."
        return EngineError("\(operation): \(path) — \(message) (Windows \(code))")
    }

    private static func attributes(_ path: String, allowMissing: Bool = false) throws -> DWORD? {
        let result = windowsPath(path).withCString(encodedAs: UTF16.self, GetFileAttributesW)
        if result != INVALID_FILE_ATTRIBUTES { return result }
        let code = GetLastError()
        if allowMissing && (code == DWORD(ERROR_FILE_NOT_FOUND) || code == DWORD(ERROR_PATH_NOT_FOUND)) { return nil }
        throw error("Read attributes", path, code)
    }

    private static func requireDirectory(_ path: String) throws {
        guard let value = try attributes(path), value & directory != 0 else {
            throw error("Open directory", path, DWORD(ERROR_DIRECTORY))
        }
    }

    private static func contents(_ path: String) throws -> [Entry] {
        try requireDirectory(path)
        var data = WIN32_FIND_DATAW()
        let pattern = childPath(windowsPath(path), "*")
        let handle: HANDLE = pattern.withCString(encodedAs: UTF16.self) { FindFirstFileW($0, &data) }
        if handle == INVALID_HANDLE_VALUE {
            let code = GetLastError()
            if code == DWORD(ERROR_FILE_NOT_FOUND) {
                try requireDirectory(path)
                return []
            }
            throw error("List directory", path, code)
        }
        defer { FindClose(handle) }
        var result: [Entry] = []
        while true {
            let name = withUnsafeBytes(of: data.cFileName) {
                $0.withMemoryRebound(to: WCHAR.self) { String(decodingCString: $0.baseAddress!, as: UTF16.self) }
            }
            if name != "." && name != ".." {
                guard result.count < 250000 else { throw EngineError("目錄超過 250,000 個項目，請選擇較小的資料夾。") }
                result.append(Entry(name: name, attributes: data.dwFileAttributes, reparseTag: data.dwReserved0,
                                    bytes: (UInt64(data.nFileSizeHigh) << 32) | UInt64(data.nFileSizeLow),
                                    modified: (UInt64(data.ftLastWriteTime.dwHighDateTime) << 32) | UInt64(data.ftLastWriteTime.dwLowDateTime)))
            }
            if !FindNextFileW(handle, &data) {
                let code = GetLastError()
                guard code == DWORD(ERROR_NO_MORE_FILES) else { throw error("List directory", path, code) }
                return result
            }
        }
    }

    static func list(_ endpoint: EngineEndpoint) throws -> [[String: Any]] {
        let entries = try contents(endpoint.path).sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let formatter = ISO8601DateFormatter()
        return try entries.map { try $0.json(formatter: formatter) }
    }

    static func size(_ endpoint: EngineEndpoint) throws -> [String: Any] {
        var directories = [endpoint.path]
        var count: Int64 = 0, bytes: Int64 = 0
        while let path = directories.popLast() {
            for entry in try contents(path) {
                if entry.isLink { continue }
                if entry.isDirectory {
                    directories.append(childPath(path, entry.name))
                } else {
                    guard entry.bytes <= UInt64(Int64.max), count < Int64.max else {
                        throw EngineError("資料夾容量超出支援範圍。")
                    }
                    let (total, overflow) = bytes.addingReportingOverflow(Int64(entry.bytes))
                    guard !overflow else { throw EngineError("資料夾容量超出支援範圍。") }
                    bytes = total; count += 1
                }
            }
        }
        return ["count": count, "bytes": bytes]
    }

    static func mkdir(_ endpoint: EngineEndpoint, name: String) throws {
        let child = try endpoint.child(name)
        try requireDirectory(endpoint.path)
        guard try attributes(child.path, allowMissing: true) == nil else { throw EngineError("同名項目已存在。") }
        let succeeded = windowsPath(child.path).withCString(encodedAs: UTF16.self) { CreateDirectoryW($0, nil) }
        guard succeeded else { throw error("Create directory", child.path, GetLastError()) }
    }

    /// Literal UTF-16 keys preserve distinct NTFS names that Swift String's
    /// canonical Unicode equality would otherwise consider identical.
    private static func selectedEntries(_ endpoint: EngineEndpoint, _ selection: [EngineSelection]) throws -> [(String, Entry)] {
        let paths = try selection.map { try endpoint.child($0.name).path }
        var entries: [[UInt16]: Entry] = [:]
        for entry in try contents(endpoint.path) { entries[Array(entry.name.utf16)] = entry }
        return try zip(selection, paths).map { item, path in
            guard let entry = entries[Array(item.name.utf16)], entry.isDirectory == item.isDir else {
                throw EngineError("「\(item.name)」已不存在或類型已改變，請重新整理。")
            }
            return (path, entry)
        }
    }

    static func rename(_ endpoint: EngineEndpoint, name: String, newName: String, isDirectory: Bool) throws {
        let target = try endpoint.child(newName)
        let selected = try selectedEntries(endpoint, [EngineSelection(name: name, isDir: isDirectory)])
        let source = selected[0].0
        if name.utf16.elementsEqual(newName.utf16) { return }
        guard try attributes(target.path, allowMissing: true) == nil else {
            throw EngineError("新名稱已存在，請選擇其他名稱。")
        }
        guard let current = try attributes(source), (current & directory != 0) == isDirectory else {
            throw EngineError("原項目已不存在或類型已改變。")
        }
        let succeeded = windowsPath(source).withCString(encodedAs: UTF16.self) { from in
            windowsPath(target.path).withCString(encodedAs: UTF16.self) { to in
                // The OS must also reject a target created after our check.
                MoveFileExW(from, to, DWORD(0))
            }
        }
        guard succeeded else { throw error("Rename", source, GetLastError()) }
    }

    static func remove(_ endpoint: EngineEndpoint, selection: [EngineSelection]) throws {
        guard !selection.isEmpty else { throw EngineError("請先選取要刪除的項目。") }
        // Validate every path/type before the first mutation. Filesystem errors
        // during deletion remain errors; this does not promise a transaction.
        let selected = try selectedEntries(endpoint, selection)
        for (path, entry) in selected {
            var pending: [RemovalStep] = [.visit(path, entry.isDirectory)]
            while let step = pending.popLast() {
                switch step {
                case .visit(let path, let expectedDirectory):
                    let access = DWORD(DELETE | FILE_READ_ATTRIBUTES) | (expectedDirectory ? DWORD(FILE_LIST_DIRECTORY) : DWORD(0))
                    let raw: HANDLE = windowsPath(path).withCString(encodedAs: UTF16.self) {
                        CreateFileW($0, access, DWORD(FILE_SHARE_READ), nil, DWORD(OPEN_EXISTING),
                                    DWORD(FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS), nil)
                    }
                    guard raw != INVALID_HANDLE_VALUE else { throw error("Open for deletion", path, GetLastError()) }
                    let handle = OwnedHandle(raw)
                    var information = BY_HANDLE_FILE_INFORMATION()
                    guard GetFileInformationByHandle(raw, &information) else { throw error("Read deletion target", path, GetLastError()) }
                    let isDirectory = information.dwFileAttributes & directory != 0
                    guard isDirectory == expectedDirectory else { throw EngineError("原項目已不存在或類型已改變。") }
                    var isLink = false
                    if information.dwFileAttributes & reparsePoint != 0 {
                        var tag = FILE_ATTRIBUTE_TAG_INFO()
                        guard GetFileInformationByHandleEx(raw, FileAttributeTagInfo, &tag, DWORD(MemoryLayout<FILE_ATTRIBUTE_TAG_INFO>.size)) else {
                            throw error("Read reparse point", path, GetLastError())
                        }
                        isLink = tag.ReparseTag & nameSurrogate != 0
                    }
                    pending.append(.finish(path, handle))
                    if isDirectory && !isLink {
                        // Keep this non-reparse directory open without write or
                        // delete sharing until its children are gone. A second
                        // process cannot replace it with a junction mid-walk.
                        for child in try contents(path).reversed() {
                            pending.append(.visit(childPath(path, child.name), child.isDirectory))
                        }
                    }
                case .finish(let path, let handle):
                    var disposition = FILE_DISPOSITION_INFO()
                    disposition.DeleteFile = 1 // BOOLEAN, not Win32 BOOL.
                    guard SetFileInformationByHandle(handle.value, FileDispositionInfo, &disposition,
                                                     DWORD(MemoryLayout<FILE_DISPOSITION_INFO>.size)) else {
                        throw error("Delete", path, GetLastError())
                    }
                    // Closing this exact handle deletes the opened item. An
                    // OPEN_REPARSE_POINT handle deletes the link, not its target.
                    handle.close()
                }
            }
        }
    }

    private static func knownFolder(_ id: KNOWNFOLDERID) -> String? {
        var pointer: PWSTR?
        let status: HRESULT = withUnsafePointer(to: id) { SHGetKnownFolderPath($0, DWORD(0), nil, &pointer) }
        guard status >= 0, let pointer else { return nil }
        defer { CoTaskMemFree(pointer) }
        return String(decodingCString: pointer, as: UTF16.self).replacingOccurrences(of: "\\", with: "/")
    }

    static func bootstrap(_ original: [String: Any]) -> [String: Any] {
        var result = original, locations: [[String: Any]] = [], seen = Set<String>()
        func add(_ path: String, id: String, kind: String, name: String? = nil,
                 group: String = "local", removable: Bool? = nil, verifyDirectory: Bool = true) {
            guard EnginePlatform.absoluteLocalPath(path),
                  !verifyDirectory || ((try? attributes(path)).map { $0 & directory != 0 } ?? false),
                  seen.insert(path.replacingOccurrences(of: "\\", with: "/").lowercased()).inserted else { return }
            var item: [String: Any] = ["id": id, "kind": kind, "name": name ?? path.split(separator: "/").last.map(String.init) ?? path,
                                      "path": path, "group": group]
            if let removable { item["isRemovable"] = removable }
            locations.append(item)
        }
        if let home = knownFolder(FOLDERID_Profile) ?? original["home"] as? String {
            result["home"] = home
            add(home, id: "home", kind: "home")
        }
        let folders: [(String, KNOWNFOLDERID)] = [("desktop", FOLDERID_Desktop), ("documents", FOLDERID_Documents),
            ("downloads", FOLDERID_Downloads), ("pictures", FOLDERID_Pictures), ("music", FOLDERID_Music), ("movies", FOLDERID_Videos)]
        for (kind, id) in folders {
            if let path = knownFolder(id) { add(path, id: kind, kind: kind) }
        }
        let drives = GetLogicalDrives()
        for index in 0..<26 where drives & (DWORD(1) << index) != 0 {
            let letter = String(UnicodeScalar(65 + index)!)
            let root = letter + ":/"
            let type = (letter + ":\\").withCString(encodedAs: UTF16.self, GetDriveTypeW)
            // A disconnected mapped drive or empty removable drive still gets
            // an entry. Do not access it until the user chooses to browse it.
            add(root, id: "volume:" + root, kind: "volume", name: letter + ":",
                group: type == UINT(DRIVE_REMOTE) ? "network" : "local",
                removable: type == UINT(DRIVE_REMOVABLE) || type == UINT(DRIVE_CDROM), verifyDirectory: false)
        }
        result["localLocations"] = locations
        return result
    }
}
#endif
