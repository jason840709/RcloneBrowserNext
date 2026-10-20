import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@main
struct UpdaterTests {
    static var passed = 0
    static var failures = 0
    static var root = URL(fileURLWithPath: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ".build-cache/updater-tests").standardizedFileURL
    static var rclone = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""

    static func assert(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw RBNUpdateError(message) }
    }
    static func rejects(_ operation: () throws -> Void, _ message: String) throws {
        do { try operation() } catch { return }
        throw RBNUpdateError(message)
    }
    static func test(_ name: String, _ operation: () throws -> Void) {
        do { try operation(); passed += 1; print("PASS \(name)") }
        catch { failures += 1; print("FAIL \(name): \(error)") }
    }
    static func directory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name + "-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func put(_ data: Data, _ url: URL) throws { try data.write(to: url) }
    static func bytes(_ string: String) -> Data { Data(string.utf8) }
    static func u32(_ n: UInt32, big: Bool = false) -> Data {
        let shifts = big ? [24, 16, 8, 0] : [0, 8, 16, 24]
        return Data(shifts.map { UInt8((n >> UInt32($0)) & 255) })
    }
    static func macho(cpu: UInt32 = 0x0100000c, minimum: UInt32 = 0x000d0000, platform: UInt32 = 1) -> Data {
        var data = Data()
        for n in [0xfeedfacf, cpu, 0, 2, 1, 24, 0, 0, 0x32, 24, platform, minimum, minimum, 0] as [UInt32] { data.append(u32(n)) }
        return data
    }
    static func main() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        test("semantic version ordering and strict stable input") {
            try assert(RcloneRelease("rclone v1.9.10")! < RcloneRelease("1.10.0")!, "numeric ordering")
            try assert(RcloneRelease("2.0.0")! > RcloneRelease("1.99.99")!, "major ordering")
            for invalid in ["", "1.2", "1.2.3-beta", "1.2.3; rm", "https://evil", "1.2.3\n9.9.9"] {
                try assert(RcloneRelease(invalid) == nil, "reject " + invalid)
            }
        }
        test("SHA-256 independent published vectors") {
            try assert(RBNSHA256.hex(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "empty")
            try assert(RBNSHA256.hex(bytes("abc")) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "abc")
            try assert(RBNSHA256.hex(bytes("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")) == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1", "multi block")
            try assert(RBNSHA256.hex(Data(repeating: 97, count: 1_000_000)) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0", "million a")
        }
        test("exact archive checksum lookup and duplicate rejection") {
            let hash = RBNSHA256.hex(bytes("archive")), name = "rclone-v1.75.2-osx-arm64.zip"
            let sums = bytes("-----BEGIN PGP SIGNED MESSAGE-----\nHash: SHA256\n\n\(hash)  \(name)\n-----BEGIN PGP SIGNATURE-----\n")
            try assert(try RcloneUpdater.checksum(for: name, in: sums) == hash, "signed-text lookup")
            try rejects({ _ = try RcloneUpdater.checksum(for: "wrong.zip", in: sums) }, "unknown archive")
            try rejects({ _ = try RcloneUpdater.checksum(for: name, in: bytes("\(hash)  \(name)\n\(hash)  \(name)\n")) }, "duplicate archive")
        }
        test("HTTP errors remain distinct from download limits and unsafe redirects") {
            let url = URL(string: "https://downloads.rclone.org/version.txt")!
            let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": "16"])!
            try RBNDownloadPolicy.validate(ok, maximum: 1024)
            let unknown = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:])!
            try RBNDownloadPolicy.validate(unknown, maximum: 1024)
            for status in [403, 404, 429, 503] {
                do {
                    try RBNDownloadPolicy.validate(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: [:])!, maximum: 1024)
                    throw RBNUpdateError("HTTP error accepted")
                } catch let error as RBNDownloadError {
                    try assert(error.message.contains("HTTP \(status)") && error.message.contains("version.txt"), "diagnostic includes actual status and resource")
                    try assert(error.retryable == [429,503].contains(status), "only temporary server errors retry")
                }
            }
            try rejects({ try RBNDownloadPolicy.validate(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": "2048"])!, maximum: 1024) }, "size limit")
            try rejects({ try RBNDownloadPolicy.validate(HTTPURLResponse(url: URL(string: "https://example.org/version.txt")!, statusCode: 200, httpVersion: nil, headerFields: [:])!, maximum: 1024) }, "off-site response")
            try assert(RBNDownloadPolicy.canRetry(URLError(.networkConnectionLost)), "network loss can retry")
            try assert(!RBNDownloadPolicy.canRetry(URLError(.serverCertificateUntrusted)), "TLS validation must not be weakened")
        }
        test("temporary update failure recovers in the same app session") {
            let folder = try directory("retry")
            var attempts = 0
            let updater = try RcloneUpdater(workDirectory: folder) { _, _ in
                attempts += 1
                if attempts == 1 { throw RBNDownloadError(message: "HTTP 503", retryable: true) }
                return bytes("rclone v9.8.7\n")
            }
            var phases = [String]()
            updater.onStatus = { if let phase = $0["phase"] as? String { phases.append(phase) } }
            let result = try updater.check(currentPath: nil, skippedVersion: "", manual: true)
            try assert(attempts == 2 && result["status"] as? String == "notInstalled", "second attempt succeeds without relaunch")
            try assert(phases.contains("retrying") && phases.last == "idle", "retry progress reaches completion")
        }
        test("permanent update failure does not poison the next check") {
            let folder = try directory("retry-permanent")
            var attempts = 0
            let updater = try RcloneUpdater(workDirectory: folder) { _, _ in
                attempts += 1
                if attempts == 1 { throw RBNDownloadError(message: "HTTP 403", retryable: false) }
                return bytes("rclone v9.8.7\n")
            }
            try rejects({ _ = try updater.check(currentPath: nil, skippedVersion: "", manual: true) }, "403 surfaces immediately")
            try assert(attempts == 1, "403 does not loop")
            let result = try updater.check(currentPath: nil, skippedVersion: "", manual: true)
            try assert(attempts == 2 && result["latestVersion"] as? String == "v9.8.7", "manual retry in same process succeeds")
        }
        test("selected executable and folder define one update destination") {
            let chosen = "/Applications/rclone/rclone"
            try assert(try RcloneUpdater.defaultTarget(settings: ["rcloneDirectory": "/different", "rclonePath": chosen], resolvedPath: "/opt/homebrew/bin/rclone") == chosen, "explicit path wins")
            try assert(try RcloneUpdater.defaultTarget(settings: ["rcloneDirectory": "/new-folder", "rclonePath": ""], resolvedPath: "/opt/homebrew/bin/rclone") == "/new-folder/rclone", "empty selected folder installs at selection")
            try assert(try RcloneUpdater.validatedTarget(chosen).path == chosen, "writable external Applications folder is not an app bundle")
        }
        test("update subprocess uses the same manual proxy policy without rclone credentials") {
            let environment = RcloneUpdater.proxyEnvironment(["proxyMode": "manual",
                "httpProxy": "http://127.0.0.1:8118", "httpsProxy": "http://127.0.0.1:8119", "noProxy": "localhost,.lan"])
            try assert(environment["HTTP_PROXY"] == "http://127.0.0.1:8118", "HTTP proxy retained")
            try assert(environment["HTTPS_PROXY"] == "http://127.0.0.1:8119", "HTTPS proxy retained")
            try assert(environment["NO_PROXY"] == "localhost,.lan", "exceptions retained")
            let http = try RcloneUpdater.httpsProxyDictionary(["proxyMode": "manual", "httpsProxy": "http://127.0.0.1:8119", "noProxy": "localhost,.lan"])!
            try assert(http["HTTPSEnable"] as? Int == 1 && http["HTTPSPort"] as? Int == 8119, "HTTPS resource uses CONNECT proxy field")
            try assert(http["ExceptionsList"] as? [String] == ["localhost", ".lan"], "native exceptions retained")
            for scheme in ["socks5", "socks5h"] {
                let socks = try RcloneUpdater.httpsProxyDictionary(["proxyMode": "manual", "httpsProxy": scheme + "://127.0.0.1:1088"])!
                try assert(socks["SOCKSEnable"] as? Int == 1 && socks["SOCKSPort"] as? Int == 1088, "native SOCKS field mapping")
                try assert(socks["HTTPSEnable"] as? Int == 0 && socks["HTTPSProxy"] == nil, "SOCKS is not misidentified as HTTP CONNECT")
            }
            try assert(try RcloneUpdater.httpsProxyDictionary(["proxyMode": "system"]) == nil, "default URLSession system policy preserved")
            try assert(!environment.keys.contains { $0.uppercased().hasPrefix("RCLONE_") }, "configuration credentials excluded")
            let direct = RcloneUpdater.proxyEnvironment(["proxyMode": "manual", "httpProxy": "", "httpsProxy": "", "noProxy": ""])
            try assert(!direct.keys.contains { ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"].contains($0.uppercased()) }, "empty manual fields do not retain inherited proxy")
            let folder = try directory("proxy-subprocess")
            let result = try RcloneUpdater.run("/usr/bin/env", [], directory: folder, timeout: 10, environment: environment)
            try assert(result.code == 0 && result.output.contains("HTTPS_PROXY=http://127.0.0.1:8119"), "child receives selected HTTPS proxy")
            try assert(result.output.contains("TMPDIR=" + folder.path), "update temporary files stay in work directory")
        }
        test("native updates reject TLS-to-proxy without weakening rclone or HTTP CONNECT and SOCKS settings") {
            let message = "更新檢查目前不支援 https:// 代理位址。請改用 http:// 或 socks5://；rclone 傳輸仍可使用 https:// 代理。"
            for address in ["https://127.0.0.1:443", "HTTPS://proxy.example:8443"] {
                let settings: [String: Any] = ["proxyMode": "manual", "httpsProxy": address]
                do {
                    try RcloneUpdater.validateNativeProxy(settings)
                    throw RBNUpdateError("TLS-to-proxy was accepted")
                } catch {
                    try assert(error.localizedDescription == message && !RBNDownloadPolicy.canRetry(error), "unsupported proxy must have a clear nonretryable diagnostic")
                }
                try rejects({ _ = try RcloneUpdater.httpsProxyDictionary(settings) }, "dictionary silently discarded the proxy TLS scheme")
                try assert(RcloneUpdater.proxyEnvironment(settings)["HTTPS_PROXY"] == address, "rclone's supported HTTPS proxy was changed")
            }
            for settings: [String: Any] in [[:], ["proxyMode": "system", "httpsProxy": "https://127.0.0.1:443"],
                                            ["proxyMode": "manual", "httpsProxy": ""], ["proxyMode": "manual", "httpsProxy": "http://127.0.0.1:443"],
                                            ["proxyMode": "manual", "httpsProxy": "socks5://127.0.0.1:1080"], ["proxyMode": "manual", "httpsProxy": "socks5h://127.0.0.1:1080"],
                                            ["proxyMode": "manual", "httpProxy": "https://127.0.0.1:443", "httpsProxy": "http://127.0.0.1:8080"]] {
                try RcloneUpdater.validateNativeProxy(settings)
                _ = try RcloneUpdater.httpsProxyDictionary(settings)
            }
            let updater = try RcloneUpdater(workDirectory: directory("native-proxy-rejection"))
            updater.connectionSettings = { ["proxyMode": "manual", "httpsProxy": "https://127.0.0.1:443"] }
            // Exercise the real native-fetch entry point: rejection occurs
            // before any URLSession request or local version process can start.
            do {
                _ = try updater.check(currentPath: nil, skippedVersion: "", manual: true)
                throw RBNUpdateError("native fetch bypassed the proxy validation")
            } catch { try assert(error.localizedDescription == message, "native fetch did not use the same proxy guard") }
        }

        test("thin Mach-O architecture and minimum OS gate") {
            let d = try directory("macho"), file = d.appendingPathComponent("rclone")
            try put(macho(), file)
            try assert(try RBNMachO.verify(file, architecture: "arm64", systemVersion: [13,0,0]) == "13.0.0", "compatible thin")
            try rejects({ _ = try RBNMachO.verify(file, architecture: "amd64", systemVersion: [26,0,0]) }, "wrong architecture")
            try put(macho(minimum: 0x001a0000), file)
            try rejects({ _ = try RBNMachO.verify(file, architecture: "arm64", systemVersion: [13,0,0]) }, "new OS rejection")
            try assert(try RBNMachO.verify(file, architecture: "arm64", systemVersion: [26,0,0]) == "26.0.0", "new OS match")
            try put(macho(platform: 2), file)
            try rejects({ _ = try RBNMachO.verify(file, architecture: "arm64", systemVersion: [26,0,0]) }, "wrong platform")
        }
        test("universal Mach-O slice selection and truncation") {
            let d = try directory("fat"), file = d.appendingPathComponent("rclone")
            var fat = Data()
            for n in [0xcafebabe, 2, 0x01000007, 0, 64, 56, 0, 0x0100000c, 0, 128, 56, 0] as [UInt32] { fat.append(u32(n, big: true)) }
            fat.append(Data(repeating: 0, count: 64 - fat.count)); fat.append(macho(cpu: 0x01000007))
            fat.append(Data(repeating: 0, count: 128 - fat.count)); fat.append(macho())
            try put(fat, file)
            for arch in ["amd64", "arm64"] { try assert(try RBNMachO.verify(file, architecture: arch, systemVersion: [13,0,0]) == "13.0.0", "fat " + arch) }
            try put(fat.prefix(140), file)
            try rejects({ _ = try RBNMachO.verify(file, architecture: "arm64", systemVersion: [13,0,0]) }, "truncated fat")
            try put(Data(repeating: 0, count: 256), file)
            try rejects({ _ = try RBNMachO.verify(file, architecture: "arm64", systemVersion: [13,0,0]) }, "invalid header")
        }
        test("managed-path and symbolic-link update rejection") {
            for path in ["relative/rclone", "/usr/local/bin/rclone", "/opt/homebrew/bin/rclone", "/Applications/Example.app/Contents/Resources/rclone", "/tmp/a\nrclone"] {
                try rejects({ _ = try RcloneUpdater.validatedTarget(path) }, "unsafe " + path)
            }
            let d = try directory("links"), a = d.appendingPathComponent("real"), link = d.appendingPathComponent("rclone")
            try put(bytes("old"), a); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: a)
            try rejects({ _ = try RcloneUpdater.validatedTarget(link.path) }, "symlink executable")
        }
        test("atomic replacement retains exact previous bytes") {
            let d = try directory("commit"), target = d.appendingPathComponent("rclone"), stage = d.appendingPathComponent(".rbn-update-test")
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
            let candidate = stage.appendingPathComponent("rclone")
            try put(bytes("old bytes"), target); try put(bytes("new bytes"), candidate)
            let backup = try RcloneUpdater.commit(candidate: candidate, target: target) { file in
                try assert(try Data(contentsOf: file) == bytes("new bytes"), "installed content")
            }
            try assert(try Data(contentsOf: target) == bytes("new bytes"), "new target")
            try assert(try Data(contentsOf: URL(fileURLWithPath: backup!)) == bytes("old bytes"), "backup content")
        }
        test("failed post-install check restores old version") {
            let d = try directory("rollback"), target = d.appendingPathComponent("rclone"), stage = d.appendingPathComponent(".rbn-update-test")
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
            let candidate = stage.appendingPathComponent("rclone")
            try put(bytes("working version"), target); try put(bytes("broken version"), candidate)
            try rejects({ try RcloneUpdater.commit(candidate: candidate, target: target) { _ in throw RBNUpdateError("probe failed") } }, "probe must fail")
            try assert(try Data(contentsOf: target) == bytes("working version"), "rollback exact bytes")
        }
        test("rollback failure reports the backup location without claiming restoration") {
            let d = try directory("rollback-failure"), target = d.appendingPathComponent("rclone")
            let stage = d.appendingPathComponent(".rbn-update-test")
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
            let candidate = stage.appendingPathComponent("rclone")
            try put(bytes("old"), target); try put(bytes("new"), candidate)
            var backupPath = ""
            do {
                try RcloneUpdater.commit(candidate: candidate, target: target) { _ in
                    let backups = try FileManager.default.contentsOfDirectory(at: d.appendingPathComponent("Backups"), includingPropertiesForKeys: nil)
                    let backup = backups[0].appendingPathComponent("rclone")
                    backupPath = backup.path
                    try FileManager.default.removeItem(at: backup)
                    throw RBNUpdateError("post-install probe failed")
                }
                throw RBNUpdateError("failed rollback must throw")
            } catch {
                try assert(!backupPath.isEmpty && error.localizedDescription.contains(backupPath), "backup location is visible")
                try assert(error.localizedDescription.contains("自動還原也未完成"), "failed restoration reported accurately")
            }
            try assert(try Data(contentsOf: target) == bytes("new"), "unrestored target matches reported state")
        }
        test("first-install validation failure leaves no executable") {
            let d = try directory("first"), target = d.appendingPathComponent("rclone"), stage = d.appendingPathComponent(".rbn-update-test")
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
            let candidate = stage.appendingPathComponent("rclone"); try put(bytes("broken"), candidate)
            try rejects({ try RcloneUpdater.commit(candidate: candidate, target: target) { _ in throw RBNUpdateError("invalid") } }, "bad first install")
            try assert(!FileManager.default.fileExists(atPath: target.path), "failed initial file removed")
        }
        test("backup symlink cannot redirect writes out of folder") {
            let d = try directory("backup-symlink"), outside = try directory("outside"), target = d.appendingPathComponent("rclone")
            try FileManager.default.createSymbolicLink(at: d.appendingPathComponent("Backups"), withDestinationURL: outside)
            let stage = d.appendingPathComponent(".rbn-update-test"); try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
            let candidate = stage.appendingPathComponent("rclone"); try put(bytes("old"), target); try put(bytes("new"), candidate)
            try rejects({ try RcloneUpdater.commit(candidate: candidate, target: target) { _ in } }, "backup redirect")
            try assert(try Data(contentsOf: target) == bytes("old"), "old untouched")
            try assert(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty, "outside untouched")
        }
        test("backup retention keeps two owned backups and unrelated files") {
            let d = try directory("retention"), target = d.appendingPathComponent("rclone")
            let backupRoot = d.appendingPathComponent("Backups")
            try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
            let unrelated = backupRoot.appendingPathComponent("notes.txt"); try put(bytes("keep me"), unrelated)
            try put(bytes("0"), target)
            for i in 1...4 {
                let stage = d.appendingPathComponent(".rbn-update-\(i)"); try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
                let candidate = stage.appendingPathComponent("rclone"); try put(bytes(String(i)), candidate)
                try RcloneUpdater.commit(candidate: candidate, target: target) { _ in }
            }
            let kept = try FileManager.default.contentsOfDirectory(atPath: backupRoot.path).filter { $0.hasPrefix("rbn-") }
            try assert(kept.count == 2, "two backups")
            try assert(try Data(contentsOf: unrelated) == bytes("keep me"), "unrelated kept")
        }
        if !rclone.isEmpty {
            test("check, skip, manual override and future-version comparison") {
                let d = try directory("check")
                let probe = try RcloneUpdater(workDirectory: d)
                let actual = try probe.versionOf(rclone)
                guard let current = RcloneRelease(actual), current.patch < 99999 else {
                    throw RBNUpdateError("Version-comparison tests require a stable rclone version: \(actual)")
                }
                let latest = "v\(current.major).\(current.minor).\(current.patch + 1)"
                var requested: [String] = []
                let up = try RcloneUpdater(workDirectory: d) { url, max in
                    requested.append(url.absoluteString)
                    try assert(max == 1024, "version request bounded")
                    return bytes("rclone \(latest)\n")
                }
                let hidden = try up.check(currentPath: rclone, skippedVersion: latest, manual: false)
                try assert(hidden["status"] as? String == "skipped", "skip persists for matching version")
                let manual = try up.check(currentPath: rclone, skippedVersion: latest, manual: true)
                try assert(manual["status"] as? String == "available", "manual override")
                let newer = try up.check(currentPath: rclone, skippedVersion: current.version, manual: false)
                try assert(newer["status"] as? String == "available", "later release shown")
                let missing = try up.check(currentPath: nil, skippedVersion: "", manual: false)
                try assert(missing["status"] as? String == "notInstalled", "first install explicit")
                try assert(requested.count == 4 && requested.allSatisfy { $0 == "https://downloads.rclone.org/version.txt" }, "check only fetches version")
                let older = try RcloneUpdater(workDirectory: d) { _,_ in bytes("rclone v0.0.0\n") }
                try assert(try older.check(currentPath: rclone, skippedVersion: "", manual: true)["status"] as? String == "current", "no downgrade")
            }
            test("real rclone version process and invalid release response") {
                let d = try directory("version")
                let up = try RcloneUpdater(workDirectory: d) { _,_ in bytes("<html>error</html>") }
                let actual = try up.versionOf(rclone)
                try assert(actual.hasPrefix("v") && actual.count < 120, "actual process returned a version")
                print("INFO actual rclone version: \(actual)")
                try rejects({ _ = try up.check(currentPath: rclone, skippedVersion: "", manual: true) }, "invalid remote metadata")
            }
        } else { print("SKIP real rclone version/check cases: pass an executable path") }
        print("Updater: \(passed) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }
}
