import Foundation
#if os(Windows)
import ucrt
#elseif canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main
struct PlatformTests {
    static var passed = 0
    static var failed = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw EngineError(message) }
    }
    static func rejects(_ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw EngineError("Expected the operation to reject invalid input")
    }
    static func test(_ title: String, _ body: () throws -> Void) {
        do { try body(); passed += 1; print("PASS \(title)") }
        catch { failed += 1; print("FAIL \(title): \(error)") }
    }
    static func main() throws {
        let root = CommandLine.arguments.count > 2 ? URL(fileURLWithPath: CommandLine.arguments[2]) : FileManager.default.temporaryDirectory.appendingPathComponent("rbn-platform-" + UUID().uuidString)
        try EngineStorage.privateDirectory(root)
        test("Windows paths require an absolute drive or complete UNC share") {
            for path in ["C:/資料/備份", "D:\\Files\\Backup", "//server/share/folder", "\\\\server\\share", "C:/"] {
                try check(EnginePlatform.absoluteLocalPath(path, windows: true), "Rejected \(path)")
            }
            for path in ["C:relative", "relative", "/rooted-on-unknown-drive", "//server", "//server/", "\\\\?\\C:\\device", "\\\\.\\PhysicalDrive0", "A:/line\nbreak"] {
                try check(!EnginePlatform.absoluteLocalPath(path, windows: true), "Accepted \(path)")
            }
        }
        test("POSIX paths retain colon and backslash filename semantics") {
            try check(EnginePlatform.absoluteLocalPath("/tmp/a:b\\c", windows: false), "POSIX filename changed")
            try check(!EnginePlatform.absoluteLocalPath("C:/windows", windows: false), "Windows path accepted on POSIX")
        }
        test("destination roots include drive and UNC share roots") {
            for path in ["C:/", "C:\\", "//server/share", "//server/share/"] {
                try check(EnginePlatform.isFilesystemRoot(path, windows: true), "Root was not protected: \(path)")
            }
            for path in ["C:/Backup", "//server/share/Backup"] {
                try check(!EnginePlatform.isFilesystemRoot(path, windows: true), "Child rejected: \(path)")
            }
        }
        test("exclusive UTF-8 file creation preserves an existing file") {
            let path = root.appendingPathComponent("測試-日本語.txt")
            let writer = try EnginePlatform.createExclusiveFile(path)
            try writer.write(contentsOf: Data("original".utf8)); try writer.close()
            try rejects { _ = try EnginePlatform.createExclusiveFile(path) }
            try check(try Data(contentsOf: path) == Data("original".utf8), "Existing bytes changed")
        }
        test("regular file reader handles missing and existing files") {
            try check(try EnginePlatform.readRegularFile(root.appendingPathComponent("missing")) == nil, "Missing file wasn't absent")
            let reader = try EnginePlatform.readRegularFile(root.appendingPathComponent("測試-日本語.txt"))!
            defer { try? reader.close() }
            try check(try reader.readToEnd() == Data("original".utf8), "Reader bytes differ")
            try rejects { _ = try EnginePlatform.readRegularFile(root) }
        }
        test("atomic replacement commits complete bytes over an existing file") {
            let source = root.appendingPathComponent("new.txt"), target = root.appendingPathComponent("old.txt")
            try Data("new-data".utf8).write(to: source)
            try Data("old-data".utf8).write(to: target)
            try EnginePlatform.replaceFile(source.path, target.path)
            try check(try Data(contentsOf: target) == Data("new-data".utf8), "Replacement was not committed")
            try check(!FileManager.default.fileExists(atPath: source.path), "Staging file remains")
        }
        test("removing a missing file is harmless and removing a directory is rejected") {
            try EnginePlatform.removeFileIfPresent(root.appendingPathComponent("absent").path)
            try rejects { try EnginePlatform.removeFileIfPresent(root.path) }
            try check(FileManager.default.fileExists(atPath: root.path), "Directory was removed")
        }
        #if !os(Windows)
        test("report readers reject symlinks and unlink never follows their target") {
            let target = root.appendingPathComponent("keep.txt"), link = root.appendingPathComponent("link.txt")
            try Data("keep".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            try rejects { _ = try EnginePlatform.readRegularFile(link) }
            try EnginePlatform.removeFileIfPresent(link.path)
            try check(try Data(contentsOf: target) == Data("keep".utf8), "Symlink target changed")
        }
        #endif
        if CommandLine.arguments.count > 1 && !CommandLine.arguments[1].isEmpty {
            test("real rclone format and declared OS requirements are validated") {
                let binary = URL(fileURLWithPath: CommandLine.arguments[1])
                let os = ProcessInfo.processInfo.operatingSystemVersion
                let architecture = RcloneUpdater.hardwareArchitecture()
                let system = [os.majorVersion, os.minorVersion, os.patchVersion]
                #if os(macOS)
                // Inspect the official fixture's architecture and declared minimum first.
                // A runnable CLI fixture can still declare a newer deployment target;
                // the updater must continue to reject that installation on an older OS.
                let minimum = try RBNNativeBinary.verify(binary, architecture: architecture, systemVersion: [65535, 255, 255])
                let requirement = minimum.split(separator: ".").compactMap { Int($0) }
                try check(requirement.count == 3, "Invalid declared minimum OS")
                if system.lexicographicallyPrecedes(requirement) {
                    try rejects { _ = try RBNNativeBinary.verify(binary, architecture: architecture, systemVersion: system) }
                    print("INFO rclone declares macOS \(minimum); update eligibility correctly rejects this on \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
                } else {
                    try check(try RBNNativeBinary.verify(binary, architecture: architecture, systemVersion: system) == minimum, "Compatible fixture rejected")
                }
                #else
                _ = try RBNNativeBinary.verify(binary, architecture: architecture, systemVersion: system)
                #endif
            }
        }
        print("RESULT \(passed) passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
