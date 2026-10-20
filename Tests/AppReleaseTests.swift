import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@main
struct AppReleaseTests {
    static var passed = 0
    static var failures = 0
    static let repository = "example-owner/example-app"
    static let endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw RBNAppUpdateError(message) }
    }
    static func rejects(_ operation: () throws -> Void, _ message: String) throws {
        do { try operation() } catch { return }
        throw RBNAppUpdateError(message)
    }
    static func test(_ name: String, _ operation: () throws -> Void) {
        do { try operation(); passed += 1; print("PASS \(name)") }
        catch { failures += 1; print("FAIL \(name): \(error)") }
    }
    static func release(_ tag: String = "v0.5.0", patch: [String: Any] = [:]) throws -> Data {
        var value: [String: Any] = ["tag_name": tag, "draft": false, "prerelease": false,
                                    "published_at": "2026-10-20T10:00:00Z",
                                    "html_url": "https://github.com/\(repository)/releases/tag/\(tag)"]
        value.merge(patch) { _, new in new }
        return try JSONSerialization.data(withJSONObject: value)
    }
    static func reply(_ data: Data, status: Int = 200, url: URL = endpoint, declaredSize: Int? = nil) -> RBNAppReleaseChecker.Reply {
        var headers = ["Content-Type": "application/json"]
        if let size = declaredSize { headers["Content-Length"] = String(size) }
        return .init(data: data, response: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
    static func checker(_ response: RBNAppReleaseChecker.Reply) throws -> RBNAppReleaseChecker {
        try RBNAppReleaseChecker(repository: repository) { _, _, _ in response }
    }

    static func main() {
        test("numeric stable versions reject suffixes, whitespace and shell-like input") {
            try expect(RBNAppReleaseChecker.stableVersion("0.9.9")! < RBNAppReleaseChecker.stableVersion("v0.10.0")!, "numeric version ordering")
            for invalid in ["01.2.3", "0.4", "0.4.0-beta", "0.4.0+build", "rclone v0.4.0", "0.4.0\n", " 0.4.0", "0.4.0; echo x", "1.2.100000"] {
                try expect(RBNAppReleaseChecker.stableVersion(invalid) == nil, "reject invalid version: " + invalid)
            }
        }
        test("only a newer full release reports an update") {
            let newer = try checker(reply(release("v0.10.0"))).check(currentVersion: "0.9.9")
            try expect(newer.status == .available && newer.latest == "0.10.0", "newer version")
            for published in ["v0.4.0", "v0.3.9"] {
                let result = try checker(reply(release(published))).check(currentVersion: "0.4.0")
                try expect(result.status == .current && result.current == "0.4.0", "never suggest downgrades")
            }
        }
        test("a new repository without releases returns an actionable unpublished state") {
            let result = try checker(reply(Data("{}".utf8), status: 404)).check()
            try expect(result.status == .unpublished && result.latest == nil, "no fabricated latest version")
            try expect(result.releaseURL.absoluteString == "https://github.com/\(repository)/releases", "project release listing")
        }
        test("drafts, prereleases and incomplete release data are rejected") {
            let patches: [[String: Any]] = [["draft": true], ["prerelease": true], ["draft": 0], ["published_at": NSNull()], ["published_at": "not a date"], ["tag_name": "v0.5.0-beta"]]
            for patch in patches {
                try rejects({ _ = try checker(reply(release(patch: patch))).check() }, "invalid release accepted")
            }
            try rejects({ _ = try checker(reply(Data("not JSON".utf8))).check() }, "invalid JSON")
        }
        test("release links cannot leave the selected project") {
            for url in ["http://github.com/\(repository)/releases/tag/v0.5.0", "https://github.com.evil.invalid/\(repository)/releases/tag/v0.5.0", "https://github.com/another/app/releases/tag/v0.5.0", "https://github.com/\(repository)/releases/tag/v0.5.0?next=elsewhere", "https://github.com/\(repository)/releases/tag/v0.6.0", "https://name@github.com/\(repository)/releases/tag/v0.5.0"] {
                try rejects({ _ = try checker(reply(release(patch: ["html_url": url]))).check() }, "unsafe release URL")
            }
            for repo in ["", "a/b/c", "name/repo\n", "name/repo?token=x", "name/../repo", "https://github.com/name/repo"] {
                try rejects({ _ = try RBNAppReleaseChecker(repository: repo) }, "invalid repository accepted")
            }
        }
        test("HTTP errors, redirects and both declared and streamed size bounds remain distinct") {
            for status in [403, 429, 500] {
                try rejects({ _ = try checker(reply(Data(), status: status)).check() }, "HTTP error accepted")
            }
            try rejects({ _ = try checker(reply(release(), url: URL(string: "https://example.invalid/releases/latest")!)).check() }, "off-site response")
            try rejects({ _ = try checker(reply(release(), declaredSize: RBNAppReleaseChecker.maximumResponseBytes + 1)).check() }, "declared size")
            try rejects({ _ = try checker(reply(Data(repeating: 0, count: RBNAppReleaseChecker.maximumResponseBytes + 1))).check() }, "streamed size")
        }
        test("manual checks forward chosen proxy settings and recover after a failed attempt") {
            var attempts = 0
            let settings: [String: Any] = ["proxyMode": "manual", "httpsProxy": "socks5://127.0.0.1:1080"]
            let checker = try RBNAppReleaseChecker(repository: repository) { url, maximum, received in
                attempts += 1
                try expect(url == endpoint && maximum == RBNAppReleaseChecker.maximumResponseBytes, "bounded public endpoint")
                try expect(received["httpsProxy"] as? String == settings["httpsProxy"] as? String, "selected proxy forwarded")
                if attempts == 1 { throw URLError(.timedOut) }
                return reply(try release())
            }
            try rejects({ _ = try checker.check(settings: settings) }, "timeout swallowed")
            try expect(try checker.check(settings: settings).status == .available && attempts == 2, "next manual check recovers")
        }
        test("native app update fetch rejects a TLS-to-proxy address before opening a connection") {
            let checker = try RBNAppReleaseChecker(repository: repository)
            do {
                _ = try checker.check(settings: ["proxyMode": "manual", "httpsProxy": "https://127.0.0.1:1"])
                throw RBNAppUpdateError("TLS-to-proxy address unexpectedly accepted")
            } catch {
                try expect(error.localizedDescription == "更新檢查目前不支援 https:// 代理位址。請改用 http:// 或 socks5://；rclone 傳輸仍可使用 https:// 代理。", "app update fetch must preserve the shared proxy explanation")
            }
        }
        print("App release tests: \(passed) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }
}
