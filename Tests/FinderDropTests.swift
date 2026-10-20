import Foundation

@main
struct FinderDropTests {
    static var passed = 0
    static var failures = 0
    static func require(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        if try !value() { throw EngineError(label) }
    }
    static func rejects(_ action: () throws -> Void) throws {
        do { try action() } catch { return }
        throw EngineError("Invalid drop was accepted")
    }
    static func test(_ label: String, _ action: () throws -> Void) {
        do { try action(); passed += 1; print("PASS \(label)") }
        catch { failures += 1; print("FAIL \(label): \(error.localizedDescription)") }
    }
    static func main() throws {
        let base = URL(fileURLWithPath: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ".build-cache/finder-tests")
            .appendingPathComponent("run-" + UUID().uuidString, isDirectory: true)
        let source = base.appendingPathComponent("測試 ' folder", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("写真 ' [1].txt")
        let folder = source.appendingPathComponent("Backup 2026", isDirectory: true)
        try Data("kept".utf8).write(to: file)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        test("Finder files preserve exact names and folder selection without transferring") {
            let result = try RBNFinderDrop(urls: [file, folder])
            try require(result.source.remote == nil && result.source.path == source.path, "source parent")
            try require(result.selection.count == 2, "selection count")
            try require(result.selection[0].name == "写真 ' [1].txt" && !result.selection[0].isDir, "exact filename")
            try require(result.selection[1].isDir, "directory metadata")
            try require(try String(contentsOf: file, encoding: .utf8) == "kept", "drop does not modify files")
        }
        test("duplicate Finder URLs select each item once") {
            let result = try RBNFinderDrop(urls: [file, file, folder, folder])
            try require(result.selection.count == 2, "de-duplicate")
        }
        test("mixed parents and non-file URLs are rejected before any transfer") {
            let other = base.appendingPathComponent("other.txt")
            try Data("other".utf8).write(to: other)
            try rejects { _ = try RBNFinderDrop(urls: [file, other]) }
            try rejects { _ = try RBNFinderDrop(urls: [URL(string: "https://example.org/file")!]) }
            try rejects { _ = try RBNFinderDrop(urls: [URL(string: "file://other-host/tmp/example")!]) }
            try require(FileManager.default.fileExists(atPath: other.path), "rejected drop retained original")
        }
        test("empty, missing, root, oversized and control-character drops fail clearly") {
            try rejects { _ = try RBNFinderDrop(urls: []) }
            try rejects { _ = try RBNFinderDrop(urls: [source.appendingPathComponent("missing.txt")]) }
            try rejects { _ = try RBNFinderDrop(urls: [URL(fileURLWithPath: "/")]) }
            try rejects { _ = try RBNFinderDrop(urls: Array(repeating: file, count: 10001)) }
            let invalidName = source.appendingPathComponent("line\nbreak.txt")
            try Data("test".utf8).write(to: invalidName)
            try rejects { _ = try RBNFinderDrop(urls: [invalidName]) }
        }
        test("symbolic links are rejected rather than promising a default-skipped transfer") {
            let link = source.appendingPathComponent("folder-link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
            try rejects { _ = try RBNFinderDrop(urls: [link]) }
            try require(FileManager.default.fileExists(atPath: folder.path), "link target is unchanged")
        }
        print("\(passed) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
