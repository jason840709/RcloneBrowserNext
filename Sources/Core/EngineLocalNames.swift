import Foundation

/// Local Unix endpoints already expose their real names to the native panes.
/// Use the local backend's exact standard mask. rclone's To/FromStandardPath
/// fast path is identity for this mask, including lsjson and filter paths.
/// Raw alone still converts lsjson output to escaped standard names.
/// Keep Windows and cloud name mappings unchanged.
enum EngineLocalNames {
    static let encoding = "--local-encoding=Slash,Ctl,Del,Dot"
    static func applies(to request: EngineTransferRequest, platform: String = EnginePlatform.identifier) -> Bool {
        ["darwin", "linux"].contains(platform) && request.source.remote == nil && request.destination.remote == nil
    }

    static func listingFlags(for request: EngineTransferRequest) -> [String] {
        applies(to: request) ? [encoding] : []
    }

    static func arguments(_ original: [String], for request: EngineTransferRequest) -> [String] {
        guard applies(to: request), let boundary = original.firstIndex(of: "--") else { return original }
        let flags = original[..<boundary].filter { !$0.hasPrefix("--local-encoding=") }
        return flags + [encoding] + Array(original[boundary...])
    }
}
