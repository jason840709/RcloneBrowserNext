import Foundation
#if os(Windows)
import WinSDK
import ucrt
#elseif canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// OS differences stay below the shared transfer and validation rules.
enum EnginePlatform {
    #if os(Windows)
    static let rcloneName = "rclone.exe"
    static let identifier = "win32"
    #elseif os(macOS)
    static let rcloneName = "rclone"
    static let identifier = "darwin"
    #else
    static let rcloneName = "rclone"
    static let identifier = "linux"
    #endif

    static func absoluteLocalPath(_ path: String, windows: Bool = identifier == "win32") -> Bool {
        guard !path.isEmpty, !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return false }
        if !windows { return path.hasPrefix("/") }
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        // Reject drive-relative paths and device namespaces. UNC needs both a
        // server and a share; a bare server is not a transfer destination.
        if normalized.hasPrefix("//") {
            let parts = normalized.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false)
            return parts.count >= 2 && !parts[0].isEmpty && !parts[1].isEmpty &&
                !["?", ".", ".."].contains(String(parts[0])) && ![".", ".."].contains(String(parts[1]))
        }
        let bytes = Array(normalized.utf8.prefix(3))
        return bytes.count == 3 && ((65...90).contains(bytes[0]) || (97...122).contains(bytes[0])) && bytes[1] == 58 && bytes[2] == 47
    }

    static func isFilesystemRoot(_ path: String, windows: Bool = identifier == "win32") -> Bool {
        if !windows { return path == "/" }
        let value = path.replacingOccurrences(of: "\\", with: "/")
        if value.hasPrefix("//") { return value.dropFirst(2).split(separator: "/").count <= 2 }
        return value.count == 3 && value.hasSuffix(":/")
    }

    static func executableCandidates(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        #if os(Windows)
        let entries = environment.first(where: { $0.key.caseInsensitiveCompare("PATH") == .orderedSame })?.value ?? ""
        return entries.split(separator: ";").map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .filter { absoluteLocalPath($0) }.map { URL(fileURLWithPath: $0).appendingPathComponent(rcloneName).path }
        #else
        let common = identifier == "darwin" ? ["/opt/homebrew/bin/rclone", "/usr/local/bin/rclone", "/usr/bin/rclone"] : ["/usr/local/bin/rclone", "/usr/bin/rclone"]
        return common + (environment["PATH"] ?? "").split(separator: ":").filter { $0.hasPrefix("/") }.map { String($0) + "/rclone" }
        #endif
    }

    static func canonicalComparisonPath(_ path: String) -> String {
        #if os(Windows)
        return path.replacingOccurrences(of: "\\", with: "/").lowercased()
        #elseif os(macOS)
        return path.lowercased()
        #else
        return path
        #endif
    }

    static func permissions(_ mode: Int) -> [FileAttributeKey: Any] {
        #if os(Windows)
        // Files inherit the user's profile ACL; POSIX mode bits have no ACL
        // equivalent in Foundation on Windows.
        return [:]
        #else
        return [.posixPermissions: mode]
        #endif
    }

    static func systemArchiveTool() -> String {
        #if os(Windows)
        var buffer = [WCHAR](repeating: 0, count: 32768)
        let count = GetSystemDirectoryW(&buffer, UINT(buffer.count))
        guard count > 0 && Int(count) < buffer.count else { return "" }
        return String(decoding: buffer.prefix(Int(count)), as: UTF16.self) + "\\tar.exe"
        #else
        return "/usr/bin/unzip"
        #endif
    }

    /// Foundation's Windows Process.interrupt force-terminates a process. The
    /// small launcher gives each child a console group and a cleanup signal.
    static func prepare(_ process: Process) throws {
        #if os(Windows)
        guard let executable = process.executableURL else { throw EngineError("缺少執行檔。") }
        let launcher = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("rbn-process-launcher.exe")
        guard FileManager.default.isExecutableFile(atPath: launcher.path) else { throw EngineError("缺少 Windows 程序啟動元件，請重新安裝。") }
        process.arguments = [executable.path] + (process.arguments ?? [])
        process.executableURL = launcher
        #endif
    }

    @discardableResult static func signal(_ pid: Int32, _ signal: Int32) -> Int32 {
        #if os(Windows)
        if signal == SIGINT || signal == SIGTERM {
            let name = "Local\\RcloneBrowserNext.Stop.\(pid)"
            // A cancel can arrive immediately after Process.run, before the
            // launcher has created its event. This bounded wait is off the UI.
            for _ in 0..<30 {
                let event = name.withCString(encodedAs: UTF16.self) { OpenEventW(DWORD(EVENT_MODIFY_STATE), false, $0) }
                if let event = event { defer { CloseHandle(event) }; return SetEvent(event) ? 0 : -1 }
                Thread.sleep(forTimeInterval: 0.01)
            }
            return -1
        }
        guard let handle = OpenProcess(DWORD(PROCESS_TERMINATE), false, DWORD(bitPattern: pid)) else { return -1 }
        defer { CloseHandle(handle) }
        return TerminateProcess(handle, UINT(signal)) ? 0 : -1
        #elseif canImport(Darwin)
        return Darwin.kill(pid, signal)
        #else
        return Glibc.kill(pid, signal)
        #endif
    }

    static func createExclusiveFile(_ url: URL) throws -> FileHandle {
        #if os(Windows)
        return try windowsFile(url, create: true)!
        #else
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw posixError() }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        #endif
    }

    static func readRegularFile(_ url: URL) throws -> FileHandle? {
        #if os(Windows)
        return try windowsFile(url, create: false)
        #else
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { if errno == ENOENT { return nil }; throw posixError() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        #if canImport(Darwin)
        let mask = mode_t(Darwin.S_IFMT), regular = mode_t(Darwin.S_IFREG)
        #else
        let mask = mode_t(Glibc.S_IFMT), regular = mode_t(Glibc.S_IFREG)
        #endif
        guard fstat(fd, &info) == 0, info.st_mode & mask == regular else { try? handle.close(); throw EngineError("逐檔記錄必須是一般檔案。") }
        return handle
        #endif
    }

    static func replaceFile(_ source: String, _ target: String) throws {
        #if os(Windows)
        let succeeded = windowsPath(source).withCString(encodedAs: UTF16.self) { src in
            windowsPath(target).withCString(encodedAs: UTF16.self) { dst in
                MoveFileExW(src, dst, DWORD(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
            }
        }
        guard succeeded else { throw windowsError() }
        #else
        guard rename(source, target) == 0 else { throw posixError() }
        #endif
    }

    static func removeFileIfPresent(_ path: String) throws {
        #if os(Windows)
        if !windowsPath(path).withCString(encodedAs: UTF16.self, DeleteFileW) {
            let code = GetLastError()
            if code != ERROR_FILE_NOT_FOUND && code != ERROR_PATH_NOT_FOUND { throw windowsError(code) }
        }
        #else
        if unlink(path) != 0 && errno != ENOENT { throw posixError() }
        #endif
    }

    static func readAvailable(_ handle: FileHandle, maximum: Int = 32768) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maximum)
        #if os(Windows)
        let raw = HANDLE(bitPattern: _get_osfhandle(handle.fileDescriptor))
        var count: DWORD = 0
        let ok = buffer.withUnsafeMutableBytes { ReadFile(raw, $0.baseAddress, DWORD(maximum), &count, nil) }
        if !ok { let code = GetLastError(); if code == ERROR_BROKEN_PIPE { return Data() }; throw windowsError(code) }
        return Data(buffer.prefix(Int(count)))
        #else
        while true {
            let count = buffer.withUnsafeMutableBytes { read(handle.fileDescriptor, $0.baseAddress, maximum) }
            if count >= 0 { return Data(buffer.prefix(count)) }
            if errno != EINTR { throw posixError() }
        }
        #endif
    }

    static func waitReadable(_ handle: FileHandle) throws -> Bool {
        #if os(Windows)
        let raw = HANDLE(bitPattern: _get_osfhandle(handle.fileDescriptor))
        var available: DWORD = 0
        if !PeekNamedPipe(raw, nil, 0, nil, &available, nil) {
            let code = GetLastError()
            if code == ERROR_BROKEN_PIPE { return true }
            throw windowsError(code)
        }
        if available > 0 { return true }
        Thread.sleep(forTimeInterval: 0.1)
        return false
        #else
        var request = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
        let available = poll(&request, 1, 100)
        if available < 0 { if errno == EINTR { return false }; throw posixError() }
        return available > 0
        #endif
    }

    #if os(Windows)
    private static func windowsPath(_ path: String) -> String {
        let value = path.replacingOccurrences(of: "/", with: "\\")
        if value.hasPrefix("\\\\?\\") { return value }
        if value.hasPrefix("\\\\") { return "\\\\?\\UNC\\" + value.dropFirst(2) }
        return "\\\\?\\" + value
    }
    private static func windowsError(_ code: DWORD = GetLastError()) -> NSError { NSError(domain: "Win32", code: Int(code)) }
    private static func windowsFile(_ url: URL, create: Bool) throws -> FileHandle? {
        let raw = windowsPath(url.path).withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(create ? GENERIC_WRITE : GENERIC_READ), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE), nil,
                        DWORD(create ? CREATE_NEW : OPEN_EXISTING), DWORD(FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT), nil)
        }
        guard let raw = raw, raw != INVALID_HANDLE_VALUE else {
            let code = GetLastError()
            if !create && (code == ERROR_FILE_NOT_FOUND || code == ERROR_PATH_NOT_FOUND) { return nil }
            throw windowsError(code)
        }
        var information = BY_HANDLE_FILE_INFORMATION()
        guard GetFileType(raw) == DWORD(FILE_TYPE_DISK), GetFileInformationByHandle(raw, &information),
              information.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT) == 0 else {
            CloseHandle(raw); throw EngineError("逐檔記錄必須是一般檔案。")
        }
        let fd = _open_osfhandle(Int(bitPattern: raw), Int32(_O_BINARY | (create ? _O_WRONLY : _O_RDONLY)))
        guard fd >= 0 else { CloseHandle(raw); throw windowsError() }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    #else
    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    #endif
}

#if os(Windows)
// Windows has no POSIX SIGKILL. This value is only the shared controller's
// force-stop selector; the platform adapter uses TerminateProcess for it.
let SIGKILL: Int32 = 9
#endif
