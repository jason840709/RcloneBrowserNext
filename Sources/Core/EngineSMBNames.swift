import Foundation

/// Direct SMB keeps the NAS's actual Unicode names. The Unix local endpoint
/// must use the same name representation, including literal rclone quotes.
/// This never reroutes an OS-mounted path or changes a stored connection.
enum EngineSMBNames {
    static let encoding = "Slash,Ctl,Del,Dot"
    static func backendFlags(platform: String = EnginePlatform.identifier) -> [String] {
        ["darwin", "linux"].contains(platform) ? ["--smb-encoding=\(encoding)"] : []
    }

    static func localFlags(_ endpoints: [EngineEndpoint], types: [String: String],
                           platform: String = EnginePlatform.identifier) -> [String] {
        guard !backendFlags(platform: platform).isEmpty,
              endpoints.contains(where: { $0.remote.flatMap { types[$0] } == "smb" }),
              endpoints.contains(where: { $0.remote == nil }) else { return [] }
        return ["--local-encoding=\(encoding)"]
    }

    static func arguments(_ original: [String], types: [String: String],
                          platform: String = EnginePlatform.identifier) -> [String] {
        guard let boundary = original.firstIndex(of: "--"), !backendFlags(platform: platform).isEmpty else { return original }
        let endpoints = original.suffix(from: boundary + 1).compactMap { argument -> EngineEndpoint? in
            if argument.hasPrefix("/") { return try? EngineEndpoint(["remote": NSNull(), "path": argument]) }
            guard let colon = argument.firstIndex(of: ":") else { return nil }
            return try? EngineEndpoint(["remote": String(argument[..<colon]), "path": String(argument[argument.index(after: colon)...])])
        }
        guard endpoints.contains(where: { $0.remote.flatMap { types[$0] } == "smb" }) else { return original }
        let flags = backendFlags(platform: platform) + localFlags(endpoints, types: types, platform: platform)
        let keys = Set(flags.map { String($0.split(separator: "=", maxSplits: 1)[0]) })
        return original[..<boundary].filter { !keys.contains(String($0.split(separator: "=", maxSplits: 1)[0])) } + flags + Array(original[boundary...])
    }

    static func filterRules(_ original: [String], request: EngineTransferRequest,
                            types: [String: String], platform: String = EnginePlatform.identifier) -> [String] {
        guard platform == "darwin", !localFlags([request.source, request.destination], types: types, platform: platform).isEmpty else { return original }
        // macOS local volumes can expose NFD while SMB retains NFC. Filters
        // run before rclone's canonical filename matching, on both endpoints.
        return original.flatMap { rule -> [String] in
            var bytes = Set<Data>()
            return [rule, rule.precomposedStringWithCanonicalMapping, rule.decomposedStringWithCanonicalMapping]
                .filter { bytes.insert(Data($0.utf8)).inserted }
        }
    }

    static func locations(_ original: [[String: Any]], platform: String = EnginePlatform.identifier) -> [[String: Any]] {
        original.map { item in
            guard item["group"] as? String == "network" else { return item }
            var result = item
            result["connection"] = platform == "darwin" ? "mac-mounted" : "system-mounted"
            return result
        }
    }
}
