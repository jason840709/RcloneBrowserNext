import Foundation
#if canImport(Darwin)
import Darwin
#elseif os(Windows)
import ucrt
#else
import Glibc
#endif

enum EngineStorage {
    static func privateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: EnginePlatform.permissions(0o700))
        try FileManager.default.setAttributes(EnginePlatform.permissions(0o700), ofItemAtPath: url.path)
    }

    static func atomicData(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: EnginePlatform.permissions(0o600)) else {
            throw EngineError("無法寫入 \(url.lastPathComponent)。")
        }
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        try EnginePlatform.replaceFile(temporary.path, url.path)
        try FileManager.default.setAttributes(EnginePlatform.permissions(0o600), ofItemAtPath: url.path)
    }

    static func atomicJSON(_ value: Any, to url: URL) throws {
        var bytes = try EngineJSON.data(value, pretty: true); bytes.append(10); try atomicData(bytes, to: url)
    }

    static func readJSON(_ url: URL, fallback: Any) -> Any {
        guard FileManager.default.fileExists(atPath: url.path) else { return fallback }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 32 * 1024 * 1024 else { throw EngineError("儲存資料過大。") }
            return try EngineJSON.object(Data(contentsOf: url))
        } catch {
            let backup = URL(fileURLWithPath: url.path + ".unreadable-" + UUID().uuidString.lowercased())
            try? FileManager.default.moveItem(at: url, to: backup)
            return fallback
        }
    }

    static func canonicalLocal(_ input: String) throws -> String {
        var candidate = URL(fileURLWithPath: input).standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { throw EngineError("無法解析本機路徑。") }
            missing.append(candidate.lastPathComponent); candidate = parent
        }
        var result = candidate.resolvingSymlinksInPath()
        for component in missing.reversed() { result.appendPathComponent(component) }
        // Conservatively refuse case-only overlaps on macOS and Windows.
        return EnginePlatform.canonicalComparisonPath(result.standardizedFileURL.path)
    }

    static func overlaps(_ first: String, _ second: String) -> Bool {
        let a = first.hasSuffix("/") ? first : first + "/"
        let b = second.hasSuffix("/") ? second : second + "/"
        return first == second || a.hasPrefix(b) || b.hasPrefix(a)
    }

    static func validatePair(_ request: EngineTransferRequest) throws {
        let source = request.source, destination = request.destination
        if source.remote == nil {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: source.path, isDirectory: &directory), directory.boolValue else {
                throw EngineError("來源資料夾不存在或無法讀取。")
            }
        }
        if destination.remote == nil {
            guard !EnginePlatform.isFilesystemRoot(destination.path) else { throw EngineError("請選擇根目錄之下的目的資料夾。") }
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: destination.path, isDirectory: &directory), !directory.boolValue {
                throw EngineError("目的位置已存在同名檔案，請選擇資料夾。")
            }
        }
        if source.remote == nil && destination.remote == nil {
            guard !overlaps(try canonicalLocal(source.path), try canonicalLocal(destination.path)) else {
                throw EngineError("來源與目的地不能相同，也不能互為上層／子目錄（包含符號連結）。")
            }
        } else if source.remote != nil && source.remote == destination.remote {
            let first = source.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let second = destination.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !first.isEmpty, !second.isEmpty, !overlaps(first, second) else {
                throw EngineError("同一遠端的來源與目的地不能相同，也不能互為上層／子目錄。")
            }
        }
    }
}

/// Sidebar locations come from Foundation's user directories and the mounted
/// volume table. Discovery never creates a folder or enumerates its contents.
enum EngineLocationCatalog {
    struct Volume {
        let url: URL
        let name: String
        let isLocal: Bool?
        let isRemovable: Bool?
    }

    static func localLocations(fileManager: FileManager = .default) -> [[String: Any]] {
        let directories: [(String, FileManager.SearchPathDirectory)] = [
            ("desktop", .desktopDirectory), ("documents", .documentDirectory), ("downloads", .downloadsDirectory),
            ("pictures", .picturesDirectory), ("music", .musicDirectory), ("movies", .moviesDirectory)
        ]
        let folders = directories.compactMap { kind, directory -> (String, URL)? in
            fileManager.urls(for: directory, in: .userDomainMask).first.map { (kind, $0) }
        }
        var volumes: [Volume] = []
        var volumesRoot: URL?
        #if os(macOS)
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeIsLocalKey, .volumeIsRemovableKey]
        for url in fileManager.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? [] {
            let values = try? url.resourceValues(forKeys: keys)
            volumes.append(Volume(url: url, name: values?.volumeName ?? fileManager.displayName(atPath: url.path),
                                  isLocal: values?.volumeIsLocal, isRemovable: values?.volumeIsRemovable))
        }
        volumesRoot = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        #endif
        return makeLocations(home: fileManager.homeDirectoryForCurrentUser, folders: folders, volumes: volumes,
                             volumesRoot: volumesRoot, fileManager: fileManager)
    }

    static func makeLocations(home: URL, folders: [(String, URL)], volumes: [Volume], volumesRoot: URL? = nil,
                              fileManager: FileManager = .default) -> [[String: Any]] {
        var result: [[String: Any]] = [], seen = Set<String>()
        func add(url: URL, id: String, kind: String, name: String, group: String = "local", removable: Bool? = nil) {
            let path = url.standardizedFileURL.path
            var isDirectory: ObjCBool = false
            guard url.isFileURL, (try? EngineEndpoint(["remote": NSNull(), "path": path])) != nil,
                  fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
                  seen.insert(path).inserted else { return }
            var value: [String: Any] = ["id": id, "name": name, "path": path, "kind": kind, "group": group]
            if let removable = removable { value["isRemovable"] = removable }
            result.append(value)
        }
        add(url: home, id: "home", kind: "home", name: fileManager.displayName(atPath: home.path))
        for (kind, url) in folders {
            add(url: url, id: kind, kind: kind, name: fileManager.displayName(atPath: url.path))
        }
        if let root = volumesRoot { add(url: root, id: "volumes", kind: "volumes", name: fileManager.displayName(atPath: root.path)) }
        for volume in volumes.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            add(url: volume.url, id: "volume:" + volume.url.standardizedFileURL.path, kind: "volume", name: volume.name,
                group: volume.isLocal == false ? "network" : "local", removable: volume.isRemovable)
        }
        return result
    }

    /// Classify only clear protocol/provider types. In particular WebDAV, HTTP,
    /// alias and encrypted/combined remotes do not identify where data is hosted.
    static func remoteGroup(type: String) -> String {
        let type = type.lowercased()
        if ["smb", "sftp", "ftp"].contains(type) { return "network" }
        if ["drive", "dropbox", "onedrive", "box", "b2", "azureblob", "azurefiles", "google cloud storage", "googlecloudstorage",
            "gcs", "pcloud", "mega", "yandex", "zoho", "protondrive", "iclouddrive", "google photos", "googlephotos",
            "1fichier", "jottacloud", "koofr", "storj", "opendrive", "sugarsync", "filefabric", "sharefile"].contains(type) { return "cloud" }
        return "other"
    }
}

/// Raw JSONL: five 20 MiB segments per job, plus a temporary export when requested.
final class EngineLogWriter {
    private let lock = NSLock()
    let directory: URL
    let id: String
    private var handle: FileHandle?
    private var bytes: Int = 0
    static let segmentBytes = 20 * 1024 * 1024
    static let segmentCount = 5
    var file: URL { directory.appendingPathComponent(id + ".jsonl") }
    init(directory: URL, id: String) throws {
        self.directory = directory; self.id = id
        if !FileManager.default.fileExists(atPath: file.path) {
            guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: EnginePlatform.permissions(0o600)) else {
                throw EngineError("無法建立工作記錄。")
            }
        }
        handle = try FileHandle(forWritingTo: file)
        bytes = Int(try handle!.seekToEnd())
    }
    deinit { try? handle?.close() }

    func append(_ text: String) throws {
        try lock.holding {
            let data = Data((text.hasSuffix("\n") ? text : text + "\n").utf8)
            if bytes + data.count > Self.segmentBytes {
                try handle?.synchronize(); try handle?.close(); handle = nil
                let oldest = URL(fileURLWithPath: file.path + ".4")
                if FileManager.default.fileExists(atPath: oldest.path) { try FileManager.default.removeItem(at: oldest) }
                for index in stride(from: 3, through: 0, by: -1) {
                    let from = index == 0 ? file : URL(fileURLWithPath: file.path + ".\(index)")
                    if FileManager.default.fileExists(atPath: from.path) {
                        try FileManager.default.moveItem(at: from, to: URL(fileURLWithPath: file.path + ".\(index + 1)"))
                    }
                }
                let marker = try EngineJSON.data(["time": EngineJSON.now(), "level": "notice", "msg": "記錄輪替；每項工作保留最近 100 MiB。", "appLogRotation": true])
                guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: EnginePlatform.permissions(0o600)) else { throw EngineError("無法輪替工作記錄。") }
                handle = try FileHandle(forWritingTo: file)
                try handle!.write(contentsOf: marker + Data([10])); bytes = marker.count + 1
            }
            guard let handle = handle else { throw EngineError("工作記錄已關閉。") }
            try handle.write(contentsOf: data); bytes += data.count
        }
    }
    func flush() throws { try lock.holding { try handle?.synchronize() } }
    func exportPath() throws -> String {
        try lock.holding {
            try handle?.synchronize()
            return try Self.exportPath(directory: directory, id: id)
        }
    }
    static func exportPath(directory: URL, id: String) throws -> String {
        let base = directory.appendingPathComponent(id + ".jsonl")
        guard FileManager.default.fileExists(atPath: base.path) else { throw EngineError("這項工作尚未產生記錄。") }
        if !FileManager.default.fileExists(atPath: base.path + ".1") { return base.path }
        let target = directory.appendingPathComponent(id + ".export.jsonl")
        guard FileManager.default.createFile(atPath: target.path, contents: nil, attributes: EnginePlatform.permissions(0o600)) else { throw EngineError("無法匯出記錄。") }
        let writer = try FileHandle(forWritingTo: target)
        defer { try? writer.close() }
        try writer.truncate(atOffset: 0)
        for index in stride(from: Self.segmentCount - 1, through: 0, by: -1) {
            let segment = index == 0 ? base : URL(fileURLWithPath: base.path + ".\(index)")
            if FileManager.default.fileExists(atPath: segment.path) {
                let reader = try FileHandle(forReadingFrom: segment)
                defer { try? reader.close() }
                while let data = try reader.read(upToCount: 64 * 1024), !data.isEmpty { try writer.write(contentsOf: data) }
            }
        }
        try writer.synchronize(); return target.path
    }
}

final class EngineProcessOutput {
    private let lock = NSLock()
    private var output = Data()
    private var errorOutput = Data()
    private var totalBytes = 0
    private var storedFailure: String?
    private let maximum: Int
    init(maximum: Int) { self.maximum = maximum }
    func append(_ bytes: Data, stderr: Bool) -> Bool {
        lock.holding {
            guard storedFailure == nil else { return false }
            totalBytes += bytes.count
            guard totalBytes <= maximum else { storedFailure = "目錄資料超過單次可載入大小，請進入較小的資料夾。"; return false }
            if stderr { errorOutput.append(bytes) } else { output.append(bytes) }
            return true
        }
    }
    func fail(_ message: String) { lock.holding { if storedFailure == nil { storedFailure = message } } }
    var failure: String? { lock.holding { storedFailure } }
    var stdout: Data { lock.holding { output } }
    var stderr: Data { lock.holding { errorOutput } }
}

struct EngineProcessResult { let stdout: Data; let stderr: Data; let exitCode: Int32 }

final class EngineActiveJob {
    var cancel = false
    var child: Process?
    var failure: String?
    var log: EngineLogWriter?
    let done = DispatchGroup()
    init() { done.enter() }
}
