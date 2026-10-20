import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(macOS)
import Darwin
#elseif os(Windows)
import ucrt
#else
import Glibc
#endif

struct RBNUpdateError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

/// Keep HTTP failures distinct from a size limit or an invalid release. Only
/// temporary network/server failures are retried; verification failures are not.
struct RBNDownloadError: LocalizedError {
    let message: String
    let retryable: Bool
    var errorDescription: String? { message }
}

enum RBNDownloadPolicy {
    static func validate(_ response: URLResponse, maximum: Int) throws {
        guard let http = response as? HTTPURLResponse,
              http.url?.scheme == "https", http.url?.host == "downloads.rclone.org" else {
            throw RBNDownloadError(message: "更新回應並非來自 rclone 官方下載站。", retryable: false)
        }
        guard http.statusCode == 200 else {
            let name = http.url?.lastPathComponent ?? ""
            throw RBNDownloadError(message: "rclone 官方下載站回傳 HTTP \(http.statusCode)（\(name)）。請稍後重試。",
                                   retryable: [408, 429, 500, 502, 503, 504].contains(http.statusCode))
        }
        guard http.expectedContentLength < 0 || http.expectedContentLength <= Int64(maximum) else {
            throw RBNDownloadError(message: "下載回應超過允許大小（\(http.expectedContentLength) bytes；上限 \(maximum) bytes）。已停止下載。",
                                   retryable: false)
        }
    }

    static func canRetry(_ error: Error) -> Bool {
        if let error = error as? RBNDownloadError { return error.retryable }
        let error = error as NSError
        return error.domain == NSURLErrorDomain && [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
            NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed, NSURLErrorNotConnectedToInternet].contains(error.code)
    }
}

struct RcloneRelease: Comparable, Equatable {
    let major: Int
    let minor: Int
    let patch: Int
    var version: String { "v\(major).\(minor).\(patch)" }

    init?(_ text: String) {
        let first = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "rclone ", with: "")
        let pattern = "^v?([0-9]{1,5})\\.([0-9]{1,5})\\.([0-9]{1,5})$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: first, range: NSRange(first.startIndex..., in: first)),
              let ar = Range(match.range(at: 1), in: first),
              let br = Range(match.range(at: 2), in: first),
              let cr = Range(match.range(at: 3), in: first),
              let a = Int(first[ar]), let b = Int(first[br]), let c = Int(first[cr]) else { return nil }
        major = a; minor = b; patch = c
    }
    static func < (a: Self, b: Self) -> Bool {
        if a.major != b.major { return a.major < b.major }
        if a.minor != b.minor { return a.minor < b.minor }
        return a.patch < b.patch
    }
}

/// Reads only official stable releases. The host owns the single user prompt and
/// the engine maintenance lock; neither checking nor skipping downloads a binary.
final class RcloneUpdater {
    typealias Fetcher = (URL, Int) throws -> Data
    private let workDirectory: URL
    private let fetcher: Fetcher?
    var onStatus: (([String: Any]) -> Void)?
    var connectionSettings: (() -> [String: Any])?

    init(workDirectory: URL, fetcher: Fetcher? = nil) throws {
        self.workDirectory = workDirectory
        self.fetcher = fetcher
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true, attributes: EnginePlatform.permissions(0o700))
    }

    static func defaultTarget(settings: [String: Any], resolvedPath: String?) throws -> String {
        if let explicit = settings["rclonePath"] as? String, !explicit.isEmpty { return explicit }
        if let directory = settings["rcloneDirectory"] as? String, !directory.isEmpty {
            return URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(EnginePlatform.rcloneName).path
        }
        if let path = resolvedPath, !path.isEmpty { return path }
        throw RBNUpdateError("請先選擇存放 rclone 的資料夾。")
    }

    func check(currentPath: String?, skippedVersion: String, manual: Bool) throws -> [String: Any] {
        status("checking", "正在檢查 rclone 版本…")
        let data = try fetch(URL(string: "https://downloads.rclone.org/version.txt")!, maximum: 1024)
        guard let raw = String(data: data, encoding: .utf8), let latest = RcloneRelease(raw) else {
            throw RBNUpdateError("rclone 官網回傳的版本資訊無法辨識，請稍後再試。")
        }
        var local = ""
        if let path = currentPath, !path.isEmpty {
            local = try versionOf(path)
        }
        let current = RcloneRelease(local)
        let result: String
        if currentPath == nil || currentPath?.isEmpty == true { result = "notInstalled" }
        else if current == nil { result = "unavailable" }
        else if let current = current, current >= latest { result = "current" }
        else if !manual && RcloneRelease(skippedVersion) == latest { result = "skipped" }
        else { result = "available" }
        status("idle", result == "current" ? "rclone 已是最新版本。" : "版本檢查完成。")
        return ["status": result, "currentVersion": local, "latestVersion": latest.version, "path": currentPath ?? "",
                "message": result == "unavailable" ? "目前使用自訂或測試版 rclone；請手動選擇要使用的穩定版。" : ""]
    }

    func versionOf(_ path: String) throws -> String {
        let result = try Self.run(path, ["version"], directory: workDirectory, timeout: 12)
        guard result.code == 0 else { throw RBNUpdateError("無法執行這個 rclone：\n\(result.error.prefix(800))") }
        guard let first = result.output.split(separator: "\n").first,
              first.hasPrefix("rclone v"), first.count < 120 else {
            throw RBNUpdateError("所選檔案沒有回傳有效的 rclone 版本。")
        }
        return String(first).replacingOccurrences(of: "rclone ", with: "")
    }

    func install(version: String, targetPath: String, currentPath: String?) throws -> [String: Any] {
        guard let release = RcloneRelease(version) else { throw RBNUpdateError("更新版本格式不正確。") }
        let target = try Self.validatedTarget(targetPath)
        let fm = FileManager.default
        let parent = target.deletingLastPathComponent()
        let architecture = Self.hardwareArchitecture()
        let system = ProcessInfo.processInfo.operatingSystemVersion
        let systemVersion = [system.majorVersion, system.minorVersion, system.patchVersion]
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path) { _ = try versionOf(target.path) }
        let stage = parent.appendingPathComponent(".rbn-update-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: EnginePlatform.permissions(0o700))
        defer { try? fm.removeItem(at: stage) }
        let candidate = stage.appendingPathComponent(EnginePlatform.rcloneName)
        var verification = "HTTPS + SHA-256"
        status("downloading", "正在下載 rclone \(release.version)…")
        // Prefer rclone's own verifier: it checks the signed release checksum.
        // --output prevents selfupdate from touching the executable in use.
        if let current = currentPath, fm.isExecutableFile(atPath: current),
           let local = try? versionOf(current), let parsed = RcloneRelease(local),
           parsed >= RcloneRelease("1.55.0")!,
           (try? RBNNativeBinary.verify(URL(fileURLWithPath: current), architecture: architecture,
                                systemVersion: systemVersion)) != nil {
            let fetched = try Self.run(current, ["selfupdate", "--stable", "--version", release.version,
                                                  "--output", candidate.path, "--log-level", "INFO"], directory: stage, timeout: 300,
                                       environment: Self.proxyEnvironment(connectionSettings?() ?? [:]))
            guard fetched.code == 0 else {
                throw RBNUpdateError("下載未完成，原本的 rclone 保持不變。\n\(fetched.error.suffix(1600))")
            }
            verification = "rclone selfupdate: signed release checksum"
        } else {
            // An Intel rclone under Rosetta updates itself to Intel. Fetch the
            // hardware-native release here instead of installing the wrong slice.
            let archiveName = "rclone-\(release.version)-\(RBNNativeBinary.archiveSystem)-\(architecture).zip"
            let root = "https://downloads.rclone.org/\(release.version)/"
            let sums = try fetch(URL(string: root + "SHA256SUMS")!, maximum: 1024 * 1024)
            let expected = try Self.checksum(for: archiveName, in: sums)
            let archiveData = try fetch(URL(string: root + archiveName)!, maximum: 128 * 1024 * 1024)
            guard RBNSHA256.hex(archiveData) == expected else { throw RBNUpdateError("下載檔的 SHA-256 不符，已停止安裝。") }
            let archive = stage.appendingPathComponent(archiveName)
            try archiveData.write(to: archive, options: .atomic)
            let member = "rclone-\(release.version)-\(RBNNativeBinary.archiveSystem)-\(architecture)/\(EnginePlatform.rcloneName)"
            let archiveTool = EnginePlatform.systemArchiveTool()
            #if os(Windows)
            let listArguments = ["-tf", archive.path]
            let extractArguments = ["-xOf", archive.path, member]
            #else
            let listArguments = ["-Z1", archive.path]
            let extractArguments = ["-p", archive.path, member]
            #endif
            let listed = try Self.run(archiveTool, listArguments, directory: stage, timeout: 20)
            guard listed.code == 0, listed.output.split(separator: "\n").filter({ String($0) == member }).count == 1 else {
                throw RBNUpdateError("下載檔裡沒有唯一的 rclone 執行檔。")
            }
            // Extract one exact member into an already chosen path; never unpack
            // arbitrary archive paths into the user's folder.
            let extracted = try Self.run(archiveTool, extractArguments, directory: stage,
                                         timeout: 90, outputFile: candidate)
            guard extracted.code == 0 else { throw RBNUpdateError("rclone 解壓縮失敗，原本的版本保持不變。") }
        }
        guard let attributes = try? fm.attributesOfItem(atPath: candidate.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let bytes = attributes[.size] as? NSNumber, bytes.int64Value > 1024,
              bytes.int64Value < 512 * 1024 * 1024 else {
            throw RBNUpdateError("下載的 rclone 執行檔不完整。")
        }
        status("verifying", "正在檢查執行檔架構與版本…")
        let minimum = try RBNNativeBinary.verify(candidate, architecture: architecture, systemVersion: systemVersion)
        try fm.setAttributes(EnginePlatform.permissions(0o755), ofItemAtPath: candidate.path)
        let found = try versionOf(candidate.path)
        guard RcloneRelease(found) == release else { throw RBNUpdateError("下載檔回報的版本與選定版本不符，已停止更新。") }
        status("installing", "正在備份並替換 rclone…")
        let installed = try Self.commit(candidate: candidate, target: target) { path in
            guard RcloneRelease(try self.versionOf(path.path)) == release else {
                throw RBNUpdateError("更新後的版本檢查失敗。")
            }
        }
        status("complete", "已更新至 rclone \(release.version)。")
        return ["status": "updated", "version": release.version, "latestVersion": release.version,
                "currentVersion": release.version, "path": target.path, "backupPath": installed ?? "",
                "verification": verification, "minimumOS": minimum]
    }

    static func checksum(for name: String, in data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else { throw RBNUpdateError("無法讀取官方校驗資訊。") }
        let matches = text.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 2, fields[1].trimmingCharacters(in: CharacterSet(charactersIn: "*")) == name,
                  fields[0].count == 64, fields[0].allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
            return fields[0].lowercased()
        }
        guard matches.count == 1 else { throw RBNUpdateError("官方校驗表找不到唯一的對應檔案，已停止安裝。") }
        return matches[0]
    }

    static func validatedTarget(_ path: String) throws -> URL {
        guard EnginePlatform.absoluteLocalPath(path), !path.contains("\0"), !path.contains("\n"),
              !path.hasSuffix("/"), !URL(fileURLWithPath: path).lastPathComponent.isEmpty else {
            throw RBNUpdateError("請選擇有效的 rclone 執行檔或資料夾。")
        }
        let initial = URL(fileURLWithPath: path).standardizedFileURL
        let parent = initial.deletingLastPathComponent().resolvingSymlinksInPath()
        let resolved = parent.appendingPathComponent(initial.lastPathComponent)
        let components = resolved.pathComponents
        let protected = RBNNativeBinary.protectedDirectories
        guard !components.contains(where: { $0.lowercased().hasSuffix(".app") }),
              !protected.contains(where: { root in
                  let value = EnginePlatform.canonicalComparisonPath(resolved.path)
                  let root = EnginePlatform.canonicalComparisonPath(root)
                  return value == root || value.hasPrefix(root + "/")
              }) else {
            throw RBNUpdateError("這個位置由 App 或套件管理工具管理。請另選自己的 rclone 資料夾，再下載更新。")
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: initial.path) {
            guard attrs[.type] as? FileAttributeType == .typeRegular else {
                throw RBNUpdateError("不能直接替換符號連結或資料夾。請選擇獨立的 rclone 執行檔。")
            }
        }
        return resolved
    }

    /// Installation is one same-volume rename, with a verified copy retained for
    /// rollback. A failed validation restores the previous bytes before returning.
    @discardableResult
    static func commit(candidate: URL, target: URL, validate: (URL) throws -> Void) throws -> String? {
        let fm = FileManager.default
        _ = try validatedTarget(target.path)
        let parent = target.deletingLastPathComponent()
        guard candidate.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL else {
            throw RBNUpdateError("更新暫存檔不在所選 rclone 資料夾內。")
        }
        let original = fm.fileExists(atPath: target.path)
        var backup: URL?
        var originalHash: String?
        if original {
            let folder = parent.appendingPathComponent("Backups", isDirectory: true)
            if let attrs = try? fm.attributesOfItem(atPath: folder.path), attrs[.type] as? FileAttributeType != .typeDirectory {
                throw RBNUpdateError("備份位置不是一般資料夾，已停止更新。")
            }
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: EnginePlatform.permissions(0o700))
            let stamp = String(Int(Date().timeIntervalSince1970)) + "-" + UUID().uuidString
            let backupFolder = folder.appendingPathComponent("rbn-" + stamp, isDirectory: true)
            try fm.createDirectory(at: backupFolder, withIntermediateDirectories: false, attributes: EnginePlatform.permissions(0o700))
            let copy = backupFolder.appendingPathComponent(EnginePlatform.rcloneName)
            let prior = try Data(contentsOf: target)
            originalHash = RBNSHA256.hex(prior)
            try fm.copyItem(at: target, to: copy)
            guard RBNSHA256.hex(try Data(contentsOf: copy)) == originalHash else {
                throw RBNUpdateError("舊版備份驗證失敗，已停止更新。")
            }
            let manifest: [String: Any] = ["owner": "Rclone Browser Next", "target": target.path,
                                           "created": Date().timeIntervalSince1970, "sha256": originalHash!]
            try JSONSerialization.data(withJSONObject: manifest, options: .sortedKeys)
                .write(to: backupFolder.appendingPathComponent("backup.json"), options: .atomic)
            backup = copy
        }
        // Check the old file again immediately before replace. This avoids silently
        // overwriting a simultaneous manual/package-manager update.
        _ = try validatedTarget(target.path)
        if let digest = originalHash {
            guard fm.fileExists(atPath: target.path), RBNSHA256.hex(try Data(contentsOf: target)) == digest else {
                throw RBNUpdateError("rclone 在更新期間被其他程式更動，已停止替換。")
            }
        } else if fm.fileExists(atPath: target.path) {
            throw RBNUpdateError("這個位置剛出現另一個檔案，已停止替換。")
        }
        let candidateHandle = try FileHandle(forWritingTo: candidate)
        try candidateHandle.synchronize(); try candidateHandle.close()
        try EnginePlatform.replaceFile(candidate.path, target.path)
        do { try validate(target) }
        catch {
            let validationMessage = error.localizedDescription
            if let backup = backup {
                let restore = candidate.deletingLastPathComponent().appendingPathComponent("restore")
                do {
                    try fm.copyItem(at: backup, to: restore)
                    let handle = try FileHandle(forWritingTo: restore)
                    try handle.synchronize(); try handle.close()
                    try EnginePlatform.replaceFile(restore.path, target.path)
                } catch {
                    throw RBNUpdateError("更新後驗證失敗，自動還原也未完成。\n舊版備份位置：\(backup.path)\n\(error.localizedDescription)")
                }
                throw RBNUpdateError("更新後驗證失敗，已還原原本的 rclone。\n\(validationMessage)")
            }
            do {
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            } catch {
                throw RBNUpdateError("新安裝的 rclone 驗證失敗，且無法移除。\n檔案位置：\(target.path)\n\(error.localizedDescription)")
            }
            throw RBNUpdateError("新安裝的 rclone 驗證失敗，已移除。\n\(validationMessage)")
        }
        pruneBackups(parent: parent, target: target.path)
        return backup?.path
    }

    private static func pruneBackups(parent: URL, target: String) {
        let fm = FileManager.default
        let folder = parent.appendingPathComponent("Backups", isDirectory: true)
        let children = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let owned: [(URL, Double)] = children.compactMap { url in
            guard url.lastPathComponent.hasPrefix("rbn-"),
                  let attrs = try? fm.attributesOfItem(atPath: url.path), attrs[.type] as? FileAttributeType == .typeDirectory,
                  let data = try? Data(contentsOf: url.appendingPathComponent("backup.json")),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  json["owner"] as? String == "Rclone Browser Next", json["target"] as? String == target,
                  let time = json["created"] as? Double else { return nil }
            return (url, time)
        }.sorted { $0.1 > $1.1 }
        for item in owned.dropFirst(2) { try? fm.removeItem(at: item.0) }
    }

    private func status(_ phase: String, _ message: String) { onStatus?(["phase": phase, "message": message]) }

    static func hardwareArchitecture() -> String {
        #if os(macOS)
        var arm: Int32 = 0
        var length = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &arm, &length, nil, 0) == 0 && arm == 1 { return "arm64" }
        return "amd64"
        #elseif arch(arm64)
        return "arm64"
        #else
        return "amd64"
        #endif
    }

    private func fetch(_ url: URL, maximum: Int) throws -> Data {
        for attempt in 0..<3 {
            do {
                if let fetcher = fetcher { return try fetcher(url, maximum) }
                return try Self.fetchOfficial(url, maximum, settings: connectionSettings?() ?? [:])
            } catch {
                guard attempt < 2, RBNDownloadPolicy.canRetry(error) else { throw error }
                status("retrying", "連線暫時失敗，正在重試（\(attempt + 1)/2）…")
                // This is a background request queue; UI and settings remain responsive.
                Thread.sleep(forTimeInterval: Double(attempt + 1))
            }
        }
        throw RBNUpdateError("更新檢查未完成，請重試。")
    }

    private static func fetchOfficial(_ url: URL, _ maximum: Int, settings: [String: Any]) throws -> Data {
        guard url.scheme == "https", url.host == "downloads.rclone.org" else { throw RBNUpdateError("更新網址不在 rclone 官方下載站。") }
        try Self.validateNativeProxy(settings)
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let resourceTimeout: TimeInterval = maximum > 1024 * 1024 ? 240 : 45
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = resourceTimeout
        #if os(macOS)
        config.connectionProxyDictionary = try Self.httpsProxyDictionary(settings)
        #endif
        let collector = RBNDownloadCollector(maximum: maximum)
        let session = URLSession(configuration: config, delegate: collector, delegateQueue: nil)
        var request = URLRequest(url: url)
        request.setValue("RcloneBrowserNext/" + RBNProject.version, forHTTPHeaderField: "User-Agent")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task = session.dataTask(with: request)
        task.resume()
        guard collector.done.wait(timeout: .now() + resourceTimeout + 5) == .success else {
            task.cancel(); session.invalidateAndCancel()
            throw URLError(.timedOut)
        }
        session.finishTasksAndInvalidate()
        if let error = collector.error { throw error }
        return collector.data
    }

    struct CommandResult { let code: Int32; let output: String; let error: String }

    /// The macOS 13-compatible CFNetwork dictionary represents HTTP CONNECT and
    /// SOCKS proxies, but cannot preserve TLS to an https:// proxy itself. Fail
    /// before creating a native request instead of changing its transport or
    /// bypassing the chosen proxy. This restriction does not apply to rclone.
    static func validateNativeProxy(_ settings: [String: Any]) throws {
        guard settings["proxyMode"] as? String == "manual",
              let value = settings["httpsProxy"] as? String,
              URL(string: value)?.scheme?.lowercased() == "https" else { return }
        throw RBNUpdateError("更新檢查目前不支援 https:// 代理位址。請改用 http:// 或 socks5://；rclone 傳輸仍可使用 https:// 代理。")
    }

    /// All updater resources are HTTPS. Match the HTTPS proxy field, including
    /// SOCKS5, instead of treating a SOCKS address as an HTTP CONNECT endpoint.
    /// These are Apple's documented CFNetwork global proxy dictionary keys.
    static func httpsProxyDictionary(_ settings: [String: Any]) throws -> [AnyHashable: Any]? {
        try validateNativeProxy(settings)
        guard settings["proxyMode"] as? String == "manual" else { return nil }
        var proxy: [AnyHashable: Any] = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
                                       "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0]
        if let value = settings["httpsProxy"] as? String, !value.isEmpty, let url = URL(string: value),
           let host = url.host, url.user == nil, url.password == nil {
            let scheme = url.scheme?.lowercased() ?? ""
            if scheme == "socks5" || scheme == "socks5h" {
                proxy["SOCKSEnable"] = 1; proxy["SOCKSProxy"] = host; proxy["SOCKSPort"] = url.port ?? 1080
                // CFNetwork uses SOCKS5 when no version override is supplied.
            } else if scheme == "http" {
                proxy["HTTPSEnable"] = 1; proxy["HTTPSProxy"] = host
                proxy["HTTPSPort"] = url.port ?? 80
            }
        }
        if let exclusions = settings["noProxy"] as? String, !exclusions.isEmpty {
            proxy["ExceptionsList"] = exclusions.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return proxy
    }

    static func proxyEnvironment(_ settings: [String: Any]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.uppercased().hasPrefix("RCLONE_") }
        if settings["proxyMode"] as? String == "manual" {
            environment = environment.filter { !["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"].contains($0.key.uppercased()) }
            for (key, variable) in [("httpProxy", "HTTP_PROXY"), ("httpsProxy", "HTTPS_PROXY"), ("noProxy", "NO_PROXY")] {
                if let value = settings[key] as? String, !value.isEmpty { environment[variable] = value }
            }
        }
        return environment
    }

    static func run(_ executable: String, _ arguments: [String], directory: URL,
                    timeout: TimeInterval, outputFile: URL? = nil,
                    environment suppliedEnvironment: [String: String]? = nil) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = suppliedEnvironment ?? ProcessInfo.processInfo.environment.filter { !$0.key.uppercased().hasPrefix("RCLONE_") }
        environment["TMPDIR"] = directory.path; environment["TMP"] = directory.path; environment["TEMP"] = directory.path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe(), stderr = Pipe()
        var destination: FileHandle?
        if let outputFile = outputFile {
            guard FileManager.default.createFile(atPath: outputFile.path, contents: nil, attributes: EnginePlatform.permissions(0o600)) else {
                throw RBNUpdateError("無法建立更新暫存檔。")
            }
            destination = try FileHandle(forWritingTo: outputFile)
            process.standardOutput = destination
        } else { process.standardOutput = stdout }
        process.standardError = stderr
        let group = DispatchGroup()
        let result = RBNProcessOutput()
        if outputFile == nil {
            group.enter(); DispatchQueue.global().async {
                result.stdout = Self.drain(stdout.fileHandleForReading, limit: 4 * 1024 * 1024); group.leave()
            }
        }
        group.enter(); DispatchQueue.global().async {
            result.stderr = Self.drain(stderr.fileHandleForReading, limit: 4 * 1024 * 1024); group.leave()
        }
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try EnginePlatform.prepare(process); try process.run() }
        catch {
            try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
            try? destination?.close(); _ = group.wait(timeout: .now() + 2)
            throw RBNUpdateError("無法執行 \(URL(fileURLWithPath: executable).lastPathComponent)：\(error.localizedDescription)")
        }
        var timedOut = false
        if finished.wait(timeout: .now() + timeout) != .success {
            timedOut = true; EnginePlatform.signal(process.processIdentifier, SIGTERM)
            if finished.wait(timeout: .now() + 2) != .success {
                EnginePlatform.signal(process.processIdentifier, SIGKILL); _ = finished.wait(timeout: .now() + 2)
            }
        }
        try? destination?.close()
        // Closing parent's write ends lets readers see EOF even on failed startup.
        try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
        let outputFinished = group.wait(timeout: .now() + 5)
        if timedOut { throw RBNUpdateError("rclone 作業逾時，原本的版本保持不變。") }
        guard outputFinished == .success else {
            // A descendant may still own a pipe. Never read the result while a
            // reader is writing it, or treat incomplete output as a valid probe.
            throw RBNUpdateError("rclone 已結束，但輸出尚未關閉，已停止更新。")
        }
        return CommandResult(code: process.terminationStatus,
                             output: String(decoding: result.stdout, as: UTF8.self),
                             error: String(decoding: result.stderr, as: UTF8.self))
    }

    private static func drain(_ handle: FileHandle, limit: Int) -> Data {
        var result = Data()
        while true {
            let chunk = handle.readData(ofLength: 65536)
            if chunk.isEmpty { break }
            if result.count < limit { result.append(chunk.prefix(limit - result.count)) }
        }
        return result
    }
}

private final class RBNProcessOutput: @unchecked Sendable { var stdout = Data(); var stderr = Data() }

private final class RBNDownloadCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let maximum: Int
    let done = DispatchSemaphore(value: 0)
    var data = Data()
    var error: Error?
    init(maximum: Int) { self.maximum = maximum }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https", request.url?.host == "downloads.rclone.org" else {
            error = RBNUpdateError("官方下載站轉址到未允許的位置，已停止下載。")
            completionHandler(nil); return
        }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do { try RBNDownloadPolicy.validate(response, maximum: maximum) }
        catch {
            self.error = error
            completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard data.count + chunk.count <= maximum else {
            error = RBNUpdateError("下載檔超過允許大小，已停止下載。")
            dataTask.cancel(); return
        }
        data.append(chunk)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError failure: Error?) {
        if error == nil { error = failure }
        done.signal()
    }
}

/// Minimal read-only Mach-O load-command inspection, before executing a candidate.
enum RBNMachO {
    static func verify(_ file: URL, architecture: String, systemVersion: [Int]) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let head = handle.readData(ofLength: 4096)
        guard head.count >= 32 else { throw RBNUpdateError("rclone 不是有效的 Mac 執行檔。") }
        let desired: UInt32 = architecture == "arm64" ? 0x0100000c : 0x01000007
        var offset: UInt64 = 0
        var sliceSize = size
        let magic = u32(head, 0, big: true)
        if magic == 0xcafebabe || magic == 0xcafebabf {
            let count = Int(u32(head, 4, big: true)), stride = magic == 0xcafebabf ? 32 : 20
            guard count > 0, count <= 32, head.count >= 8 + count * stride else { throw RBNUpdateError("Mac 執行檔的架構表不完整。") }
            var found = false
            for i in 0..<count {
                let at = 8 + i * stride
                if u32(head, at, big: true) == desired {
                    offset = stride == 32 ? u64(head, at + 8) : UInt64(u32(head, at + 8, big: true))
                    sliceSize = stride == 32 ? u64(head, at + 16) : UInt64(u32(head, at + 12, big: true))
                    found = true; break
                }
            }
            guard found else { throw RBNUpdateError("新版 rclone 不包含這台 Mac 的處理器架構。") }
        }
        guard offset <= size, sliceSize <= size - offset, sliceSize >= 32 else { throw RBNUpdateError("Mac 執行檔的架構範圍不正確。") }
        try handle.seek(toOffset: offset)
        let h = handle.readData(ofLength: 32)
        guard h.count == 32, u32(h, 0) == 0xfeedfacf, u32(h, 4) == desired, u32(h, 12) == 2 else {
            throw RBNUpdateError("新版 rclone 的執行檔格式或架構不符。")
        }
        let count = Int(u32(h, 16)), length = Int(u32(h, 20))
        guard count > 0, count <= 4096, length >= 8, length <= 16 * 1024 * 1024,
              UInt64(length) <= sliceSize - 32 else { throw RBNUpdateError("Mac 執行檔的載入資訊不完整。") }
        let commands = handle.readData(ofLength: length)
        guard commands.count == length else { throw RBNUpdateError("Mac 執行檔已截斷。") }
        var at = 0
        var requirement: [Int]?
        for _ in 0..<count {
            guard at + 8 <= commands.count else { throw RBNUpdateError("Mac 執行檔的載入資訊已截斷。") }
            let command = u32(commands, at), bytes = Int(u32(commands, at + 4))
            guard bytes >= 8, bytes % 4 == 0, bytes <= commands.count - at else { throw RBNUpdateError("Mac 執行檔包含無效載入指令。") }
            if command == 0x32 {
                guard bytes >= 24, u32(commands, at + 8) == 1 else { throw RBNUpdateError("新版 rclone 的目標平台不是 macOS。") }
                let v = version(u32(commands, at + 12))
                if requirement == nil || greater(v, requirement!) { requirement = v }
            } else if command == 0x24 {
                guard bytes >= 16 else { throw RBNUpdateError("macOS 最低版本資訊不完整。") }
                let v = version(u32(commands, at + 8))
                if requirement == nil || greater(v, requirement!) { requirement = v }
            }
            at += bytes
        }
        guard at == commands.count, let minimum = requirement else { throw RBNUpdateError("無法確認新版 rclone 的 macOS 需求，已保留原版。") }
        let label = minimum.map(String.init).joined(separator: ".")
        guard !greater(minimum, systemVersion) else {
            throw RBNUpdateError("這個官方 rclone 執行檔需要 macOS \(label)，高於目前系統。原本的 rclone 保持不變；你可以選擇另一個相容版本。")
        }
        return label
    }
    private static func u32(_ d: Data, _ o: Int, big: Bool = false) -> UInt32 {
        let b = (0..<4).map { UInt32(d[d.startIndex + o + $0]) }
        return big ? b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3] : b[0] | b[1] << 8 | b[2] << 16 | b[3] << 24
    }
    private static func u64(_ d: Data, _ o: Int) -> UInt64 { UInt64(u32(d, o, big: true)) << 32 | UInt64(u32(d, o + 4, big: true)) }
    private static func version(_ n: UInt32) -> [Int] { [Int(n >> 16), Int((n >> 8) & 255), Int(n & 255)] }
    private static func greater(_ a: [Int], _ b: [Int]) -> Bool {
        for i in 0..<3 { if a[i] != b[i] { return a[i] > b[i] } }; return false
    }
}

/// Dependency-free SHA-256. Kept portable so checksum/rollback logic is tested
/// using the same source on Linux and macOS.
enum RBNSHA256 {
    private static let constants: [UInt32] = [
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2]
    private static func rotate(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
    static func hex(_ data: Data) -> String {
        var bytes = [UInt8](data)
        let bits = UInt64(bytes.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((bits >> UInt64(shift)) & 255)) }
        var h: [UInt32] = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]
        var w = [UInt32](repeating: 0, count: 64)
        for base in stride(from: 0, to: bytes.count, by: 64) {
            for i in 0..<16 {
                let at = base + i * 4
                w[i] = UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
            }
            for i in 16..<64 {
                let s0 = rotate(w[i-15],7) ^ rotate(w[i-15],18) ^ (w[i-15] >> 3)
                let s1 = rotate(w[i-2],17) ^ rotate(w[i-2],19) ^ (w[i-2] >> 10)
                w[i] = w[i-16] &+ s0 &+ w[i-7] &+ s1
            }
            var a=h[0],b=h[1],c=h[2],d=h[3],e=h[4],f=h[5],g=h[6],j=h[7]
            for i in 0..<64 {
                let s1=rotate(e,6)^rotate(e,11)^rotate(e,25)
                let t1=j &+ s1 &+ ((e & f) ^ (~e & g)) &+ constants[i] &+ w[i]
                let s0=rotate(a,2)^rotate(a,13)^rotate(a,22)
                let t2=s0 &+ ((a & b) ^ (a & c) ^ (b & c))
                j=g;g=f;f=e;e=d &+ t1;d=c;c=b;b=a;a=t1 &+ t2
            }
            for (i,v) in [a,b,c,d,e,f,g,j].enumerated() { h[i] = h[i] &+ v }
        }
        return h.map { String(format: "%08x", $0) }.joined()
    }
}
