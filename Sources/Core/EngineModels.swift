import Foundation
import CoreFoundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct EngineError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension NSRecursiveLock {
    func holding<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }; return try body()
    }
}

extension NSLock {
    func holding<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }; return try body()
    }
}

enum EngineJSON {
    static func text(_ value: Any?, _ name: String, maximum: Int = 4096) throws -> String {
        guard let result = value as? String, result.utf8.count <= maximum,
              !result.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw EngineError("\(name) 格式不正確，不能包含控制字元。")
        }
        return result
    }

    static func bool(_ value: Any?, _ name: String) throws -> Bool {
        guard let value = value, let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw EngineError("\(name) 必須為開啟或關閉。")
        }
        return number.boolValue
    }

    static func integer(_ value: Any?, _ name: String, _ range: ClosedRange<Int>) throws -> Int {
        guard let value = value, let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
              number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= Double(range.lowerBound), number.doubleValue <= Double(range.upperBound) else {
            throw EngineError("\(name) 必須介於 \(range.lowerBound) 與 \(range.upperBound)。")
        }
        return number.intValue
    }

    static func number(_ value: Any?, fallback: Double = 0) -> Double {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0 else { return fallback }
        return number.doubleValue
    }

    static func seconds(_ value: Any?) -> Any {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0 else { return NSNull() }
        return number.doubleValue
    }

    static func now() -> String { ISO8601DateFormatter().string(from: Date()) }
    static func dictionary(_ value: Any?, _ message: String) throws -> [String: Any] {
        guard let result = value as? [String: Any] else { throw EngineError(message) }; return result
    }
    static func validID(_ value: String) -> Bool { UUID(uuidString: value) != nil }
    static func object(_ data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
    static func data(_ value: Any, pretty: Bool = false) throws -> Data {
        guard JSONSerialization.isValidJSONObject(value) else { throw EngineError("資料無法儲存成 JSON。") }
        return try JSONSerialization.data(withJSONObject: value, options: pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys])
    }
}

struct EngineEndpoint {
    let remote: String?
    let path: String
    var json: [String: Any] { ["remote": remote as Any? ?? NSNull(), "path": path] }
    var argument: String { remote.map { "\($0):\(path)" } ?? path }

    init(_ value: Any?) throws {
        let raw = try EngineJSON.dictionary(value, "請選擇位置。")
        let location = try EngineJSON.text(raw["path"], "路徑", maximum: 32768)
        if raw["remote"] is NSNull {
            guard location.hasPrefix("/"), !location.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw EngineError("本機位置必須是完整的絕對路徑。")
            }
            remote = nil
            path = URL(fileURLWithPath: location).standardizedFileURL.path
        } else {
            let name = try EngineJSON.text(raw["remote"], "遠端連線名稱", maximum: 512)
            guard !name.trimmingCharacters(in: .whitespaces).isEmpty,
                  name.rangeOfCharacter(from: CharacterSet(charactersIn: ":/\\,[]")) == nil else {
                throw EngineError("遠端連線名稱格式不正確。")
            }
            let components = location.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.contains("..") else { throw EngineError("遠端路徑不能包含「..」。") }
            let normalized = components.filter { !$0.isEmpty && $0 != "." }.joined(separator: "/")
            remote = name
            path = (location.hasPrefix("/") ? "/" : "") + normalized
        }
    }

    private init(remote: String?, path: String) { self.remote = remote; self.path = path }
    func child(_ name: String) throws -> EngineEndpoint {
        let name = try Self.validName(name)
        if remote == nil { return EngineEndpoint(remote: nil, path: URL(fileURLWithPath: path).appendingPathComponent(name).path) }
        return EngineEndpoint(remote: remote, path: path.isEmpty ? name : path + (path.hasSuffix("/") ? "" : "/") + name)
    }

    static func validName(_ value: Any?) throws -> String {
        let name = try EngineJSON.text(value, "名稱")
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw EngineError("名稱不能留白、使用「.」「..」或包含斜線。")
        }
        return name
    }
}

struct EngineSelection {
    let name: String
    let isDir: Bool
    var json: [String: Any] { ["name": name, "isDir": isDir] }
    static func parse(_ value: Any?) throws -> [EngineSelection] {
        guard let raw = value as? [[String: Any]], raw.count <= 10000 else { throw EngineError("單次最多選取 10,000 個項目。") }
        var seen = Set<String>()
        return try raw.map {
            let name = try EngineEndpoint.validName($0["name"])
            guard seen.insert(name).inserted else { throw EngineError("選取項目不能重複。") }
            return EngineSelection(name: name, isDir: try EngineJSON.bool($0["isDir"], "項目類型"))
        }
    }
}

/// A remembered workspace is a browsing arrangement, never a pending transfer.
/// It deliberately omits selection, dryRun and any instruction to start a job.
struct EngineWorkspace {
    let left: EngineEndpoint
    let right: EngineEndpoint
    let direction: String
    let mode: String
    let options: EngineTransferOptions
    var json: [String: Any] {
        ["left": left.json, "right": right.json, "direction": direction, "mode": mode, "options": options.json]
    }
    init(_ value: Any?) throws {
        let raw = try EngineJSON.dictionary(value, "記住的環境格式不正確。")
        guard Set(raw.keys) == Set(["left", "right", "direction", "mode", "options"]) else {
            throw EngineError("記住的環境必須包含左右位置、方向、操作與傳輸選項。")
        }
        left = try EngineEndpoint(raw["left"]); right = try EngineEndpoint(raw["right"])
        direction = try EngineJSON.text(raw["direction"], "傳輸方向")
        guard ["lr", "rl"].contains(direction) else { throw EngineError("傳輸方向不正確。") }
        mode = try EngineJSON.text(raw["mode"], "傳輸模式")
        options = try EngineTransferOptions(raw["options"])
        // Validate flags together, without touching the filesystem or a remote.
        // Both panes may legitimately show the same folder while browsing.
        _ = try EngineTransferRequest(["source": direction == "lr" ? left.json : right.json,
                                       "destination": direction == "lr" ? right.json : left.json,
                                       "mode": mode, "options": options.json, "selection": [[String: Any]](), "dryRun": true])
    }
}

/// Common rclone networking flags. Updater HTTP requests are a separate native
/// client; these options apply to rclone commands and tools only.
struct EngineNetworkOptions {
    static let defaults: [String: Any] = ["bindMode": "auto", "bindAddress": "", "connectTimeout": "1m", "ioTimeout": "5m",
                                           "tpsLimit": 0.0, "tpsBurst": 1, "userAgent": "", "disableHTTP2": false]
    static let globalOwnedFlags: Set<String> = ["--tpslimit", "--tpslimit-burst", "--disable-http2"]
    let json: [String: Any]

    init(_ value: Any?) throws {
        let raw = try EngineJSON.dictionary(value, "網路設定格式不正確。")
        guard Set(raw.keys).isSubset(of: Set(Self.defaults.keys)) else { throw EngineError("網路設定包含不支援的選項。") }
        var output = Self.defaults.merging(raw) { _, new in new }
        let mode = try EngineJSON.text(output["bindMode"], "連線位址模式")
        guard ["auto", "ipv4", "ipv6", "address"].contains(mode) else { throw EngineError("連線位址模式不正確。") }
        let address = try EngineJSON.text(output["bindAddress"], "來源 IP 位址", maximum: 128).trimmingCharacters(in: .whitespaces)
        guard (mode != "address" || !address.isEmpty), address.isEmpty || Self.isIPAddress(address) else {
            throw EngineError("來源位址請填入有效的 IPv4 或 IPv6，不要填入網卡名稱、網址或連接埠。")
        }
        output["bindMode"] = mode; output["bindAddress"] = address
        for (key, label) in [("connectTimeout", "連線逾時"), ("ioTimeout", "傳輸閒置逾時")] {
            output[key] = try EngineTransferOptions.durationValue(output[key], label: label)
        }
        guard let rate = output["tpsLimit"] as? NSNumber, CFGetTypeID(rate) != CFBooleanGetTypeID(),
              rate.doubleValue.isFinite, (0...1000000).contains(rate.doubleValue) else {
            throw EngineError("每秒請求上限格式不正確。")
        }
        output["tpsLimit"] = rate.doubleValue
        output["tpsBurst"] = try EngineJSON.integer(output["tpsBurst"], "瞬間請求上限", 1...1000000)
        output["userAgent"] = try EngineJSON.text(output["userAgent"], "User-Agent", maximum: 1024)
        output["disableHTTP2"] = try EngineJSON.bool(output["disableHTTP2"], "停用 HTTP/2")
        json = output
    }

    private static func isIPAddress(_ text: String) -> Bool {
        var ipv4 = in_addr(), ipv6 = in6_addr()
        return text.withCString { pointer in
            inet_pton(AF_INET, pointer, &ipv4) == 1 || inet_pton(AF_INET6, pointer, &ipv6) == 1
        }
    }

    var arguments: [String] {
        var result: [String] = []
        switch json["bindMode"] as! String {
        case "ipv4": result.append("--bind=0.0.0.0")
        case "ipv6": result.append("--bind=::0")
        case "address": result.append("--bind=\(json["bindAddress"] as! String)")
        default: break
        }
        for (key, flag) in [("connectTimeout", "--contimeout"), ("ioTimeout", "--timeout"), ("userAgent", "--user-agent")] {
            if let value = json[key] as? String, !value.isEmpty { result.append("\(flag)=\(value)") }
        }
        result += ["--tpslimit=\(json["tpsLimit"] as! Double)", "--tpslimit-burst=\(json["tpsBurst"] as! Int)",
                   "--disable-http2=\(json["disableHTTP2"] as! Bool ? "true" : "false")"]
        return result
    }
}

struct EngineTransferOptions {
    static let defaults: [String: Any] = [
        "transfers": 4, "checkers": 8, "bandwidth": "", "comparison": "default",
        "skipExisting": false, "updateOnly": false, "createEmptyDirs": true,
        "exclude": [".DS_Store", "._*"], "include": [String](), "retries": 3,
        "maxDelete": 100, "preserveMetadata": false, "driveSharedWithMe": false,
        "deleteMode": "after", "deleteExcluded": false, "ignoreChecksum": false,
        "modifyWindow": "", "checkFirst": false, "noTraverse": false, "fastList": false,
        "oneFileSystem": false, "noUpdateModtime": false,
        "minSize": "", "maxSize": "", "minAge": "", "maxAge": "", "maxDepth": -1,
        "connectTimeout": "", "ioTimeout": "", "lowLevelRetries": 10,
        "retrySleep": "", "extraArgs": [String](), "localHashPolicy": "default"
    ]
    let json: [String: Any]
    var includes: [String] { json["include"] as! [String] }
    var excludes: [String] { json["exclude"] as! [String] }
    func flag(_ key: String) -> Bool { json[key] as! Bool }
    func text(_ key: String) -> String { json[key] as! String }
    func integer(_ key: String) -> Int { json[key] as! Int }

    init(_ value: Any?) throws {
        let raw = try EngineJSON.dictionary(value, "傳輸選項格式不正確。")
        var output = Self.defaults.merging(raw) { _, new in new }
        for (key, label, range) in [("transfers", "平行傳輸數", 1...64), ("checkers", "平行檢查數", 1...128),
                                     ("retries", "重試次數", 1...100), ("maxDelete", "最多刪除數", -1...100000),
                                     ("lowLevelRetries", "連線重試次數", 1...100), ("maxDepth", "目錄深度", -1...100000)] {
            output[key] = try EngineJSON.integer(output[key], label, range)
        }
        for key in ["skipExisting", "updateOnly", "createEmptyDirs", "preserveMetadata", "driveSharedWithMe",
                    "deleteExcluded", "ignoreChecksum", "checkFirst", "noTraverse", "fastList", "oneFileSystem", "noUpdateModtime"] {
            output[key] = try EngineJSON.bool(output[key], "傳輸選項")
        }
        let bandwidth = try EngineJSON.text(output["bandwidth"], "限速", maximum: 32)
        guard bandwidth.isEmpty || bandwidth == "off" || Self.bytes(bandwidth) != nil else {
            throw EngineError("限速請填入 10M、512K 或 off；留白表示不限速。")
        }
        output["bandwidth"] = bandwidth
        let comparison = try EngineJSON.text(output["comparison"], "比較方式")
        guard ["default", "checksum", "modtime", "size", "checksum-only", "none"].contains(comparison) else {
            throw EngineError("檔案比較方式不正確。")
        }
        guard comparison != "none" || (output["skipExisting"] as? Bool != true && output["updateOnly"] as? Bool != true) else {
            throw EngineError("全部重新傳送不能同時略過已存在或較新的檔案。請選擇一種比對方式。")
        }
        output["comparison"] = comparison
        let deletion = try EngineJSON.text(output["deleteMode"], "刪除時機")
        guard ["before", "during", "after"].contains(deletion) else { throw EngineError("刪除時機不正確。") }
        output["deleteMode"] = deletion
        let hashPolicy = try EngineJSON.text(output["localHashPolicy"], "本機雜湊讀取")
        guard ["default", "none"].contains(hashPolicy) else { throw EngineError("本機雜湊讀取設定不正確。") }
        guard hashPolicy != "none" || !["checksum", "checksum-only"].contains(comparison) else {
            throw EngineError("停用本機雜湊讀取時，不能使用雜湊比對。")
        }
        output["localHashPolicy"] = hashPolicy
        for key in ["minSize", "maxSize"] {
            output[key] = try Self.sizeValue(output[key], label: key == "minSize" ? "最小檔案大小" : "最大檔案大小")
        }
        let minimum = Self.bytes(output["minSize"] as! String), maximum = Self.bytes(output["maxSize"] as! String)
        guard minimum == nil || maximum == nil || minimum! <= maximum! else { throw EngineError("最小檔案大小不能大於最大檔案大小。") }
        for (key, label) in [("minAge", "最小檔案年齡"), ("maxAge", "最大檔案年齡"), ("modifyWindow", "時間容許誤差"),
                             ("connectTimeout", "連線逾時"), ("ioTimeout", "傳輸閒置逾時"), ("retrySleep", "重試間隔")] {
            output[key] = try Self.durationValue(output[key], label: label)
        }
        if let minimum = Self.durationSeconds(output["minAge"] as! String), let maximum = Self.durationSeconds(output["maxAge"] as! String), minimum > maximum {
            throw EngineError("最小檔案年齡不能大於最大檔案年齡。")
        }
        for key in ["include", "exclude"] {
            guard let patterns = output[key] as? [Any], patterns.count <= 256 else { throw EngineError("最多可設定 256 條篩選規則。") }
            output[key] = try patterns.map { try EngineJSON.text($0, "篩選規則") }.filter { !$0.isEmpty }
        }
        output["extraArgs"] = try Self.validateExtraArguments(output["extraArgs"])
        // Retain only known keys; imported tasks cannot smuggle arbitrary flags.
        json = output.filter { Self.defaults[$0.key] != nil }
    }

    /// Extra options are individual argv elements, never a shell command. The
    /// allowlist deliberately excludes commands, paths, credentials, filters,
    /// deletion controls and the JSON/statistics flags owned by the host.
    static let extraBooleanFlags: Set<String> = [
        "--disable-http2", "--no-gzip-encoding", "--use-mmap", "--local-no-preallocate", "--local-no-clone",
        "--server-side-across-configs", "--drive-acknowledge-abuse", "--s3-no-check-bucket"
    ]
    static let extraSizeFlags: Set<String> = [
        "--buffer-size", "--max-buffer-memory", "--multi-thread-cutoff", "--multi-thread-chunk-size", "--multi-thread-write-buffer-size",
        "--max-transfer", "--drive-chunk-size", "--s3-chunk-size", "--s3-upload-cutoff", "--sftp-chunk-size",
        "--onedrive-chunk-size", "--b2-chunk-size", "--azureblob-chunk-size", "--azureblob-upload-cutoff"
    ]
    static let extraIntegerFlags: Set<String> = [
        "--multi-thread-streams", "--max-backlog", "--tpslimit-burst", "--drive-pacer-burst", "--s3-upload-concurrency",
        "--sftp-concurrency", "--ftp-concurrency", "--b2-upload-concurrency", "--azureblob-upload-concurrency"
    ]
    static let extraDurationFlags: Set<String> = ["--max-duration", "--drive-pacer-min-sleep", "--expect-continue-timeout"]

    static func validateExtraArguments(_ value: Any?) throws -> [String] {
        guard let values = value as? [Any], values.count <= 64 else { throw EngineError("其他選項最多 64 行，每行填入一個 --選項=值。") }
        var seen = Set<String>()
        return try values.map { value in
            let item = try EngineJSON.text(value, "其他選項", maximum: 4096).trimmingCharacters(in: .whitespaces)
            let components = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = components.first.map(String.init), key.range(of: "^--[a-z][a-z0-9-]*$", options: .regularExpression) != nil,
                  seen.insert(key).inserted else { throw EngineError("其他選項不能包含命令、路徑、短旗標或重複選項。每行請使用 --選項=值。") }
            let argument = components.count == 2 ? String(components[1]) : nil
            if extraBooleanFlags.contains(key) {
                guard argument == nil || ["true", "false"].contains(argument!) else { throw EngineError("\(key) 只接受 true 或 false。") }
            } else {
                guard let argument = argument, !argument.isEmpty else { throw EngineError("\(key) 請使用 --選項=值。") }
                if extraSizeFlags.contains(key) { _ = try sizeValue(argument, label: key) }
                else if extraIntegerFlags.contains(key) {
                    guard argument.range(of: "^[0-9]{1,7}$", options: .regularExpression) != nil else { throw EngineError("\(key) 必須是 0 至 9,999,999 的整數。") }
                } else if extraDurationFlags.contains(key) { _ = try durationValue(argument, label: key) }
                else if key == "--tpslimit" {
                    guard argument.range(of: "^[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil,
                          let rate = Double(argument), rate.isFinite, rate <= 1000000 else { throw EngineError("每秒請求上限格式不正確。") }
                } else if key == "--cutoff-mode" {
                    guard ["HARD", "SOFT", "CAUTIOUS"].contains(argument.uppercased()) else { throw EngineError("cutoff-mode 請填入 HARD、SOFT 或 CAUTIOUS。") }
                } else if key == "--order-by" {
                    guard argument.range(of: "^(size|name|modtime)(,(ascending|asc|descending|desc|mixed))?$", options: .regularExpression) != nil else { throw EngineError("order-by 格式不正確。") }
                } else { throw EngineError("\(key) 不在支援的其他選項中。請使用畫面上的對應設定；帳號與憑證請在 Config 設定。") }
            }
            return item
        }
    }

    private static func sizeValue(_ value: Any?, label: String) throws -> String {
        let text = try EngineJSON.text(value, label, maximum: 64)
        guard text.isEmpty || bytes(text) != nil else { throw EngineError("\(label)請填入 10M、512K 等大小；留白表示不限。") }
        return text
    }

    private static func bytes(_ value: String) -> Double? {
        guard !value.isEmpty, value.range(of: "^[0-9]+(?:\\.[0-9]+)?(?:[bB]|[kKmMgGtTpPeE](?:[iI]|i[bB])?)?$", options: .regularExpression) != nil else { return nil }
        let numeric = String(value.prefix { $0.isNumber || $0 == "." })
        guard let count = Double(numeric), count.isFinite else { return nil }
        let suffix = value.dropFirst(numeric.count).lowercased()
        let powers: [Character: Double] = ["b": 0, "k": 1, "m": 2, "g": 3, "t": 4, "p": 5, "e": 6]
        // rclone SizeSuffix interprets a bare number as KiB. Byte values must
        // use B; MB is not an accepted rclone suffix (M or MiB is accepted).
        let total = count * pow(1024, suffix.first.flatMap { powers[$0] } ?? 1)
        return total.isFinite && total <= Double(Int64.max) ? total : nil
    }

    static func durationValue(_ value: Any?, label: String) throws -> String {
        let text = try EngineJSON.text(value, label, maximum: 64)
        guard text.isEmpty || durationSeconds(text) != nil else { throw EngineError("\(label)請填入 30s、5m、24h、7d 等時間。") }
        return text
    }

    private static func durationSeconds(_ value: String) -> Double? {
        if value == "0" { return 0 }
        guard !value.isEmpty, value.range(of: "^(?:[0-9]+(?:\\.[0-9]+)?(?:ns|us|ms|s|m|h|d|w|M|y))+$", options: .regularExpression) != nil else { return nil }
        let expression = try! NSRegularExpression(pattern: "([0-9]+(?:\\.[0-9]+)?)(ns|us|ms|s|m|h|d|w|M|y)")
        let weights: [String: Double] = ["ns": 1e-9, "us": 1e-6, "ms": 1e-3, "s": 1, "m": 60, "h": 3600, "d": 86400, "w": 604800, "M": 2592000, "y": 31536000]
        let raw = value as NSString
        let total = expression.matches(in: value, range: NSRange(location: 0, length: raw.length)).reduce(0.0) { sum, match in
            sum + (Double(raw.substring(with: match.range(at: 1))) ?? .infinity) * (weights[raw.substring(with: match.range(at: 2))] ?? .infinity)
        }
        return total.isFinite && total <= 9e9 ? total : nil
    }

    var filterRules: [String] {
        var result = excludes.map { "- \($0)" }
        if !includes.isEmpty { result += includes.map { "+ \($0)" } + ["- **"] }
        return result
    }
}

struct EngineTransferRequest {
    let source: EngineEndpoint
    let destination: EngineEndpoint
    let mode: String
    let options: EngineTransferOptions
    let selection: [EngineSelection]
    let dryRun: Bool
    let label: String?
    // Arrangement metadata for a saved task. Actual copy semantics always use
    // source and destination; this field is never passed to rclone.
    let direction: String?
    init(_ value: Any?, validateOperationalRules: Bool = true) throws {
        let raw = try EngineJSON.dictionary(value, "傳輸設定格式不正確。")
        source = try EngineEndpoint(raw["source"])
        destination = try EngineEndpoint(raw["destination"])
        mode = try EngineJSON.text(raw["mode"], "傳輸模式")
        guard ["copy", "sync", "move"].contains(mode) else { throw EngineError("傳輸模式不正確。") }
        options = try EngineTransferOptions(raw["options"])
        selection = try EngineSelection.parse(raw["selection"])
        dryRun = try EngineJSON.bool(raw["dryRun"], "預演設定")
        label = raw["label"] == nil ? nil : try EngineJSON.text(raw["label"], "工作名稱", maximum: 800)
        direction = raw["direction"] == nil ? nil : try EngineJSON.text(raw["direction"], "傳輸方向")
        guard direction == nil || ["lr", "rl"].contains(direction!) else { throw EngineError("傳輸方向不正確。") }
        if validateOperationalRules { try validateOperation() }
    }
    func validateOperation() throws {
        guard mode != "sync" || selection.isEmpty else { throw EngineError("同步適用於整個目前目錄。請清除選取，或改用複製／移動。") }
        guard mode != "sync" || !options.flag("noTraverse") else { throw EngineError("同步需要列出目的地，不能使用「不掃描目的地」。") }
        guard mode != "move" || !options.flag("updateOnly") else {
            throw EngineError("移動時，rclone 可能刪除因目的地較新而略過的來源。請關閉「略過較新」或改用複製。")
        }
        guard mode == "sync" || !options.flag("deleteExcluded") else { throw EngineError("刪除已排除的檔案只適用於同步。") }
    }
    var json: [String: Any] {
        var value: [String: Any] = ["source": source.json, "destination": destination.json, "mode": mode,
                                  "options": options.json, "selection": selection.map(\.json), "dryRun": dryRun]
        if let label = label { value["label"] = label }
        if let direction = direction { value["direction"] = direction }
        return value
    }
    var selectionFilterRules: [String] {
        if selection.isEmpty { return options.filterRules }
        return options.excludes.map { "- \($0)" } + selection.map {
            "+ /\(Self.escapeFilter($0.name))\($0.isDir ? "/**" : "")"
        } + ["- **"]
    }
    static func escapeFilter(_ text: String) -> String {
        var output = ""
        for char in text {
            if "\\*?[]{}".contains(char) { output += "\\" }
            output += char == " " ? "[ ]" : String(char)
        }
        return output
    }
    func arguments(filterPath: String? = nil) -> [String] {
        let o = options
        var result = [mode, "--use-json-log", "--stats=1s", "--stats-log-level=INFO", "--log-level=INFO",
                      "--ask-password=false", "--transfers=\(o.integer("transfers"))", "--checkers=\(o.integer("checkers"))",
                      "--retries=\(o.integer("retries"))", "--color=NEVER"]
        if !o.text("bandwidth").isEmpty { result.append("--bwlimit=\(o.text("bandwidth"))") }
        switch o.text("comparison") {
        case "checksum": result.append("--checksum")
        case "modtime": result.append("--ignore-size")
        case "size": result.append("--size-only")
        case "checksum-only": result += ["--checksum", "--ignore-size"]
        case "none": result.append("--ignore-times")
        default: break
        }
        if o.flag("skipExisting") { result.append("--ignore-existing") }
        if o.flag("updateOnly") { result.append("--update") }
        if o.flag("createEmptyDirs") { result.append("--create-empty-src-dirs") }
        if o.flag("preserveMetadata") { result.append("--metadata") }
        if o.flag("driveSharedWithMe") { result.append("--drive-shared-with-me") }
        for (key, flag) in [("ignoreChecksum", "--ignore-checksum"), ("checkFirst", "--check-first"), ("noTraverse", "--no-traverse"),
                            ("fastList", "--fast-list"), ("oneFileSystem", "--one-file-system"), ("noUpdateModtime", "--no-update-modtime")] {
            if o.flag(key) { result.append(flag) }
        }
        for (key, flag) in [("minSize", "--min-size"), ("maxSize", "--max-size"), ("minAge", "--min-age"), ("maxAge", "--max-age"),
                            ("modifyWindow", "--modify-window"), ("connectTimeout", "--contimeout"), ("ioTimeout", "--timeout"), ("retrySleep", "--retries-sleep")] {
            if !o.text(key).isEmpty { result.append("\(flag)=\(o.text(key))") }
        }
        if o.integer("maxDepth") >= 0 { result.append("--max-depth=\(o.integer("maxDepth"))") }
        result.append("--low-level-retries=\(o.integer("lowLevelRetries"))")
        if o.text("localHashPolicy") == "none" { result.append("--local-hashes=none") }
        if mode == "sync" {
            result += ["--delete-\(o.text("deleteMode"))", "--max-delete=\(o.integer("maxDelete"))"]
            if o.flag("deleteExcluded") { result.append("--delete-excluded") }
        }
        result += o.json["extraArgs"] as! [String]
        if dryRun { result.append("--dry-run") }
        if let filterPath = filterPath { result.append("--filter-from=\(filterPath)") }
        result += ["--", source.argument, destination.argument]
        return result
    }
}

enum EngineStatistics {
    static var empty: [String: Any] {
        ["bytes": 0, "totalBytes": 0, "speed": 0, "eta": NSNull(), "transfers": 0, "totalTransfers": 0,
         "checks": 0, "totalChecks": 0, "errors": 0, "deletes": 0, "elapsedTime": 0, "transferring": [[String: Any]]()]
    }
    static func parse(_ value: Any?, previous: [String: Any] = empty) -> [String: Any] {
        guard let raw = value as? [String: Any] else { return previous }
        var result = empty
        for key in ["bytes", "totalBytes", "transfers", "totalTransfers", "checks", "totalChecks", "errors", "deletes", "elapsedTime"] {
            result[key] = EngineJSON.number(raw[key], fallback: EngineJSON.number(previous[key]))
        }
        result["speed"] = EngineJSON.number(raw["speed"])
        result["eta"] = EngineJSON.seconds(raw["eta"])
        result["transferring"] = (raw["transferring"] as? [[String: Any]] ?? []).prefix(64).map { file -> [String: Any] in
            let size = EngineJSON.number(file["size"]), bytes = EngineJSON.number(file["bytes"])
            return ["name": String((file["name"] as? String ?? "").prefix(16000)), "size": size, "bytes": bytes,
                    "percentage": min(100, EngineJSON.number(file["percentage"], fallback: size > 0 ? bytes / size * 100 : 0)),
                    "speed": EngineJSON.number(file["speed"]), "speedAvg": EngineJSON.number(file["speedAvg"]), "eta": EngineJSON.seconds(file["eta"])]
        }
        return result
    }
}

final class EngineJob {
    static let terminal: Set<String> = ["completed", "failed", "cancelled", "interrupted"]
    let id: String
    let request: EngineTransferRequest
    var status: String
    let createdAt: String
    var startedAt: String?
    var endedAt: String?
    var stats: [String: Any]
    var logs: [[String: Any]]
    var error: String?
    var exitCode: Int32?
    var command: String
    var json: [String: Any] {
        var value: [String: Any] = ["id": id, "request": request.json, "status": status, "createdAt": createdAt,
                                  "stats": stats, "logs": logs, "command": command]
        if let startedAt = startedAt { value["startedAt"] = startedAt }
        if let endedAt = endedAt { value["endedAt"] = endedAt }
        if let error = error { value["error"] = error }
        if let exitCode = exitCode { value["exitCode"] = Int(exitCode) }
        return value
    }
    init(request: EngineTransferRequest, command: String) {
        self.id = UUID().uuidString.lowercased(); self.request = request; self.command = command
        self.status = "queued"; self.createdAt = EngineJSON.now(); self.stats = EngineStatistics.empty; self.logs = []
    }
    init(saved: [String: Any]) throws {
        id = try EngineJSON.text(saved["id"], "工作編號")
        guard EngineJSON.validID(id) else { throw EngineError("工作編號格式不正確。") }
        request = try EngineTransferRequest(saved["request"], validateOperationalRules: false)
        createdAt = try EngineJSON.text(saved["createdAt"], "建立時間")
        let previous = try EngineJSON.text(saved["status"], "工作狀態")
        guard Self.terminal.contains(previous) || ["queued", "running", "cancelling"].contains(previous) else { throw EngineError("工作狀態格式不正確。") }
        status = Self.terminal.contains(previous) ? previous : "interrupted"
        stats = EngineStatistics.parse(saved["stats"])
        logs = (saved["logs"] as? [[String: Any]] ?? []).suffix(250).map {
            var line: [String: Any] = ["time": $0["time"] as? String ?? "", "level": $0["level"] as? String ?? "info",
                                     "message": String(($0["message"] as? String ?? "").prefix(16000))]
            if let object = $0["object"] as? String { line["object"] = String(object.prefix(16000)) }; return line
        }
        command = saved["command"] as? String ?? ""
        startedAt = saved["startedAt"] as? String; endedAt = saved["endedAt"] as? String; error = saved["error"] as? String
        if let code = saved["exitCode"] as? NSNumber { exitCode = code.int32Value }
        if status != previous {
            endedAt = EngineJSON.now(); error = "上次關閉時工作尚未完成，未自動重跑。"
            stats["speed"] = 0; stats["eta"] = NSNull(); stats["transferring"] = [[String: Any]]()
        }
    }
}

struct EngineTask {
    let id: String
    let name: String
    let request: EngineTransferRequest
    let createdAt: String
    let updatedAt: String
    var json: [String: Any] {
        var result: [String: Any] = ["id": id, "name": name, "request": request.json, "createdAt": createdAt, "updatedAt": updatedAt]
        do { try request.validateOperation() } catch { result["validationError"] = error.localizedDescription }
        return result
    }
    init(id: String, name: String, request: EngineTransferRequest, createdAt: String, updatedAt: String) {
        self.id = id; self.name = name; self.request = request; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
    init(_ value: Any) throws {
        let raw = try EngineJSON.dictionary(value, "作業格式不正確。")
        id = try EngineJSON.text(raw["id"], "作業編號")
        guard EngineJSON.validID(id) else { throw EngineError("作業編號格式不正確。") }
        name = try EngineJSON.text(raw["name"], "作業名稱", maximum: 800)
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw EngineError("請輸入作業名稱。") }
        // Keep a previously saved task visible even when a newer version has
        // learned that one flag combination is unsafe. Running/editing it still
        // validates the combination; the task is never silently discarded.
        request = try EngineTransferRequest(raw["request"], validateOperationalRules: false)
        createdAt = try EngineJSON.text(raw["createdAt"], "建立時間")
        updatedAt = try EngineJSON.text(raw["updatedAt"], "更新時間")
    }
}
