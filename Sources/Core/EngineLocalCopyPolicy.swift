import Foundation

/// Darwin's rclone local Copy uses COPYFILE_CLONE, whose ordinary-copy fallback
/// also inherits BSD flags even when --metadata is off. An inherited immutable
/// flag can prevent the final .partial rename and its cleanup. Use rclone's
/// streaming path for direct local transfers, retaining its staging, checks and
/// atomic commit. This deliberately trades APFS clone acceleration for correct
/// transfer semantics; remote and other-platform commands remain unchanged.
enum EngineLocalCopyPolicy {
    static let identifier = "streaming-no-clone"
    static let message = "macOS 本機傳輸使用一般複製，避免繼承來源鎖定旗標；暫存檔驗證與完成後重新命名仍會保留。"

    static func applies(to request: EngineTransferRequest, platform: String = EnginePlatform.identifier) -> Bool {
        platform == "darwin" && request.source.remote == nil && request.destination.remote == nil &&
            ["copy", "sync", "move"].contains(request.mode)
    }

    static func arguments(for request: EngineTransferRequest, filterPath: String? = nil,
                          platform: String = EnginePlatform.identifier) -> [String] {
        let original = request.arguments(filterPath: filterPath)
        guard applies(to: request, platform: platform), let boundary = original.firstIndex(of: "--") else { return original }
        // A task or common default may contain --local-no-clone=false. The
        // effective safety policy owns this key only for these local transfers;
        // leave the saved request intact and emit one authoritative true flag.
        // configuredArguments() then excludes any default with the same key.
        let flags = original[..<boundary].filter {
            String($0.split(separator: "=", maxSplits: 1)[0]) != "--local-no-clone"
        }
        return flags + ["--local-no-clone"] + Array(original[boundary...])
    }
}
