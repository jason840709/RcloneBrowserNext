import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main
struct SMBTests {
    static func main() throws {
        let binary = CommandLine.arguments[1]
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let names = ["引用‛？/か\u{3099}.txt", "全形／記号/空白 .txt", "か\u{3099}/kept.txt", "plain.txt"]
        for name in names {
            let file = source.appendingPathComponent(name)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(("fixture: " + name).utf8).write(to: file)
        }
        let config = root.appendingPathComponent("rclone.conf")
        try Data("[nas]\ntype = alias\nremote = \(source.path)\n\n[cloud]\ntype = alias\nremote = \(source.path)\n".utf8).write(to: config)
        let wrapper = root.appendingPathComponent("rclone-wrapper")
        let quoted = "'" + binary.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        try Data("#!/bin/sh\nliteral=\nfor argument do\n if [ \"$argument\" = \"--smb-encoding=Slash,Ctl,Del,Dot\" ]; then literal=--local-encoding=Slash,Ctl,Del,Dot; fi\n if [ \"$argument\" = listremotes ]; then\n  printf '%s\\n' '[{\"name\":\"nas\",\"type\":\"smb\"},{\"name\":\"cloud\",\"type\":\"drive\"}]'\n  exit 0\n fi\ndone\nif [ -n \"$literal\" ]; then exec \(quoted) \"$literal\" \"$@\"; fi\nexec \(quoted) \"$@\"\n".utf8).write(to: wrapper)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let engine = try RcloneEngine(stateDirectory: root.appendingPathComponent("state"), defaultRcloneDirectory: root)
        defer { engine.shutdown() }
        _ = try engine.invoke("saveSettings", arguments: [["rclonePath": wrapper.path, "configPath": config.path, "autoCheckUpdates": false]])
        func request(_ remote: String) -> [String: Any] {
            ["source": ["remote": remote, "path": ""], "destination": ["remote": NSNull(), "path": target.path],
             "mode": "copy", "dryRun": false, "selection": [],
             "options": EngineTransferOptions.defaults.merging(["retries": 1, "lowLevelRetries": 1]) { _, new in new }]
        }
        var failed = 0, passed = 0
        func check(_ name: String, _ body: () throws -> Bool) {
            do { guard try body() else { throw EngineError(name) }; passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error.localizedDescription)") }
            fflush(stdout)
        }
        check("SMB to local preview owns literal SMB and local filename flags") {
            let value = try engine.invoke("previewTransfer", arguments: [request("nas")]) as! [String: Any]
            let command = value["command"] as! String
            return command.contains("--smb-encoding=Slash,Ctl,Del,Dot") && command.contains("--local-encoding=Slash,Ctl,Del,Dot")
        }
        check("SMB browsing retains literal names used by selections") {
            let values = try engine.invoke("list", arguments: [["remote": "nas", "path": ""]]) as! [[String: Any]]
            return Set(values.compactMap { $0["name"] as? String }) == ["引用‛？", "全形／記号", "か\u{3099}", "plain.txt"]
        }
        check("SMB copy keeps quoted and decomposed paths and their exact bytes") {
            let submitted = try engine.invoke("startTransfer", arguments: [request("nas")]) as! [String: Any]
            let id = submitted["id"] as! String, deadline = Date().addingTimeInterval(45)
            var job: [String: Any] = [:]
            repeat {
                job = (try engine.invoke("listJobs", arguments: []) as! [[String: Any]]).first { $0["id"] as? String == id }!
                if EngineJob.terminal.contains(job["status"] as? String ?? "") { break }
                Thread.sleep(forTimeInterval: 0.03)
            } while Date() < deadline
            guard job["status"] as? String == "completed" else { throw EngineError("Job did not complete: \(job["error"] ?? "timeout")") }
            return try names.allSatisfy { try Data(contentsOf: target.appendingPathComponent($0)) == Data(contentsOf: source.appendingPathComponent($0)) }
        }
        check("Cloud commands keep their existing encoding policy") {
            let value = try engine.invoke("previewTransfer", arguments: [request("cloud")]) as! [String: Any]
            return !(value["command"] as! String).contains("--smb-encoding") && !(value["command"] as! String).contains("--local-encoding")
        }
        for included in [false, true] {
            check("SMB selected sync handles canonical name differences with include=\(included)") {
                let selected = target.appendingPathComponent("か\u{3099}")
                let stale = selected.appendingPathComponent("stale.txt"), empty = selected.appendingPathComponent("empty")
                let untouched = target.appendingPathComponent("unselected.txt")
                try Data("stale".utf8).write(to: stale)
                try Data("unselected".utf8).write(to: untouched)
                try fm.createDirectory(at: empty, withIntermediateDirectories: true)
                var value = request("nas"); value["mode"] = "sync"
                value["selection"] = [["name": "が", "isDir": true]]
                if included {
                    var options = value["options"] as! [String: Any]; options["include"] = ["*.txt"]; value["options"] = options
                }
                let submitted = try engine.invoke("startTransfer", arguments: [value]) as! [String: Any]
                let id = submitted["id"] as! String, deadline = Date().addingTimeInterval(45)
                var job: [String: Any] = [:]
                repeat {
                    job = (try engine.invoke("listJobs", arguments: []) as! [[String: Any]]).first { $0["id"] as? String == id }!
                    if EngineJob.terminal.contains(job["status"] as? String ?? "") { break }
                    Thread.sleep(forTimeInterval: 0.03)
                } while Date() < deadline
                let unchanged = try Data(contentsOf: untouched) == Data("unselected".utf8)
                return job["status"] as? String == "completed" && !fm.fileExists(atPath: stale.path) &&
                    !fm.fileExists(atPath: empty.path) && fm.fileExists(atPath: selected.appendingPathComponent("kept.txt").path) &&
                    unchanged
            }
        }
        check("Windows commands retain the existing encoding behavior") {
            let original = ["copy", "--", "nas:path", "C:/target"]
            return EngineSMBNames.arguments(original, types: ["nas": "smb"], platform: "win32") == original
        }
        check("Only OS-mounted network locations receive a mount label") {
            let locations: [[String: Any]] = [["name": "NAS", "group": "network"], ["name": "Disk", "group": "local"]]
            let mac = EngineSMBNames.locations(locations, platform: "darwin")
            let linux = EngineSMBNames.locations(locations, platform: "linux")
            return mac[0]["connection"] as? String == "mac-mounted" && mac[1]["connection"] == nil && linux[0]["connection"] as? String == "system-mounted"
        }
        print("RESULT \(passed) passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
