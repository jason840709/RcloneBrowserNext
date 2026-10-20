import Foundation

/// Validate the official download's executable format before running `version`.
/// The archive SHA-256 is checked separately by RcloneUpdater.
enum RBNNativeBinary {
    static var archiveSystem: String {
        #if os(macOS)
        return "osx"
        #elseif os(Windows)
        return "windows"
        #else
        return "linux"
        #endif
    }

    static var protectedDirectories: [String] {
        #if os(Windows)
        let environment = ProcessInfo.processInfo.environment
        return ["SystemRoot", "ProgramFiles", "ProgramFiles(x86)"].compactMap { key in
            environment.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value
        }
        #else
        return ["/System", "/Library", "/usr", "/bin", "/sbin", "/opt/homebrew", "/opt/local"]
        #endif
    }

    static func verify(_ url: URL, architecture: String, systemVersion: [Int]) throws -> String {
        #if os(macOS)
        return try RBNMachO.verify(url, architecture: architecture, systemVersion: systemVersion)
        #else
        guard let reader = try EnginePlatform.readRegularFile(url) else { throw RBNUpdateError("找不到下載的 rclone 執行檔。") }
        defer { try? reader.close() }
        let header = [UInt8](try reader.read(upToCount: 64) ?? Data())
        guard header.count == 64 else { throw RBNUpdateError("下載的 rclone 執行檔不完整。") }
        #if os(Windows)
        guard header[0] == 0x4d, header[1] == 0x5a else { throw RBNUpdateError("下載檔不是 Windows 執行檔。") }
        let offset = UInt64(header[60]) | UInt64(header[61]) << 8 | UInt64(header[62]) << 16 | UInt64(header[63]) << 24
        guard offset >= 64, offset <= 1024 * 1024 else { throw RBNUpdateError("Windows 執行檔標頭不完整。") }
        try reader.seek(toOffset: offset)
        let pe = [UInt8](try reader.read(upToCount: 26) ?? Data())
        guard pe.count == 26, Array(pe.prefix(4)) == [0x50, 0x45, 0, 0], pe[24] == 0x0b, pe[25] == 0x02 else {
            throw RBNUpdateError("下載檔不是有效的 64 位元 Windows 執行檔。")
        }
        let machine = Int(pe[4]) | Int(pe[5]) << 8
        guard machine == (architecture == "arm64" ? 0xaa64 : 0x8664) else { throw RBNUpdateError("rclone 執行檔架構與這台電腦不符。") }
        #else
        guard Array(header.prefix(4)) == [0x7f, 0x45, 0x4c, 0x46], header[4] == 2, header[5] == 1 else {
            throw RBNUpdateError("下載檔不是有效的 64 位元 Linux 執行檔。")
        }
        let machine = Int(header[18]) | Int(header[19]) << 8
        guard machine == (architecture == "arm64" ? 183 : 62) else { throw RBNUpdateError("rclone 執行檔架構與這台電腦不符。") }
        #endif
        return ""
        #endif
    }
}
