import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum RBNProject {
    static let version = "0.9.6"
    static let author = "Jason Chen"
    static let repository = "jason840709/RcloneBrowserNext"
    static var repositoryURL: URL { URL(string: "https://github.com/" + repository)! }
}

struct RBNAppUpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct RBNAppReleaseResult {
    enum Status: String { case current, available, unpublished }
    let status: Status
    let current: String
    let latest: String?
    let releaseURL: URL

    var json: [String: Any] {
        var value: [String: Any] = ["status": status.rawValue, "current": current, "releaseURL": releaseURL.absoluteString]
        if let latest = latest { value["latest"] = latest }
        return value
    }
}

/// Checks the project's public releases without a GitHub account or token.
/// It only reports versions and a verified release page; it never replaces an app.
final class RBNAppReleaseChecker {
    struct Reply { let data: Data; let response: HTTPURLResponse }
    typealias Fetcher = (URL, Int, [String: Any]) throws -> Reply
    static let maximumResponseBytes = 512 * 1024
    let repository: String
    let endpoint: URL
    let releasesURL: URL
    private let fetcher: Fetcher

    init(repository: String, fetcher: Fetcher? = nil) throws {
        guard repository.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9][A-Za-z0-9._-]{0,99}\z"#, options: .regularExpression) != nil else {
            throw RBNAppUpdateError("GitHub 專案位置不正確。")
        }
        self.repository = repository
        endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        releasesURL = URL(string: "https://github.com/\(repository)/releases")!
        self.fetcher = fetcher ?? Self.fetch
    }

    func check(currentVersion: String = RBNProject.version, settings: [String: Any] = [:]) throws -> RBNAppReleaseResult {
        guard let current = Self.stableVersion(currentVersion) else { throw RBNAppUpdateError("App 版本格式不正確。") }
        let reply = try fetcher(endpoint, Self.maximumResponseBytes, settings)
        return try decode(reply, current: current)
    }

    private func decode(_ reply: Reply, current: RcloneRelease) throws -> RBNAppReleaseResult {
        try Self.validate(reply.response, expectedURL: endpoint, maximum: Self.maximumResponseBytes)
        guard reply.data.count <= Self.maximumResponseBytes else { throw RBNAppUpdateError("GitHub 更新資訊超過允許大小。") }
        let installed = String(current.version.dropFirst())
        if reply.response.statusCode == 404 {
            return RBNAppReleaseResult(status: .unpublished, current: installed, latest: nil, releaseURL: releasesURL)
        }
        guard let object = try? JSONSerialization.jsonObject(with: reply.data) as? [String: Any],
              let draft = object["draft"] as? NSNumber, EngineJSON.isBoolean(draft), !draft.boolValue,
              let prerelease = object["prerelease"] as? NSNumber, EngineJSON.isBoolean(prerelease), !prerelease.boolValue,
              let tag = object["tag_name"] as? String, let latest = Self.stableVersion(tag),
              let published = object["published_at"] as? String, ISO8601DateFormatter().date(from: published) != nil,
              let rawURL = object["html_url"] as? String, let releaseURL = URL(string: rawURL),
              isReleaseURL(releaseURL, tag: tag) else {
            throw RBNAppUpdateError("GitHub 回傳的正式版本資訊不完整。")
        }
        return RBNAppReleaseResult(status: current < latest ? .available : .current,
                                   current: installed, latest: String(latest.version.dropFirst()), releaseURL: releaseURL)
    }

    static func stableVersion(_ value: String) -> RcloneRelease? {
        guard value.range(of: #"^v?(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})\z"#, options: .regularExpression) != nil else { return nil }
        return RcloneRelease(value)
    }

    func isReleaseURL(_ url: URL, tag: String) -> Bool {
        // Stable tags contain only digits, dots and an optional v. Exact matching
        // also rejects credentials, fragments, queries and look-alike hosts.
        url.absoluteString == "https://github.com/\(repository)/releases/tag/\(tag)"
    }

    static func validate(_ response: HTTPURLResponse, expectedURL: URL, maximum: Int) throws {
        guard response.url?.absoluteString == expectedURL.absoluteString else {
            throw RBNAppUpdateError("更新資訊轉址到其他位置，已停止檢查。")
        }
        switch response.statusCode {
        case 200, 404: break
        case 403, 429: throw RBNAppUpdateError("GitHub 暫時限制更新檢查，請稍後再試。")
        default: throw RBNAppUpdateError("GitHub 更新檢查失敗（HTTP \(response.statusCode)）。")
        }
        guard response.expectedContentLength <= Int64(maximum) else { throw RBNAppUpdateError("GitHub 更新資訊超過允許大小。") }
    }

    private static func fetch(_ url: URL, maximum: Int, settings: [String: Any]) throws -> Reply {
        try RcloneUpdater.validateNativeProxy(settings)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 35
        #if os(macOS)
        configuration.connectionProxyDictionary = try RcloneUpdater.httpsProxyDictionary(settings)
        #endif
        let collector = RBNAppReleaseCollector(expectedURL: url, maximum: maximum)
        let session = URLSession(configuration: configuration, delegate: collector, delegateQueue: nil)
        var request = URLRequest(url: url)
        request.setValue("RcloneBrowserNext/" + RBNProject.version, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task = session.dataTask(with: request)
        task.resume()
        guard collector.done.wait(timeout: .now() + 40) == .success else {
            task.cancel(); session.invalidateAndCancel()
            throw URLError(.timedOut)
        }
        session.finishTasksAndInvalidate()
        if let error = collector.error { throw error }
        guard let response = collector.response else { throw RBNAppUpdateError("GitHub 未回傳更新資訊。") }
        return Reply(data: collector.data, response: response)
    }
}

private final class RBNAppReleaseCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let expectedURL: URL
    let maximum: Int
    let done = DispatchSemaphore(value: 0)
    var data = Data()
    var response: HTTPURLResponse?
    var error: Error?

    init(expectedURL: URL, maximum: Int) { self.expectedURL = expectedURL; self.maximum = maximum }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        error = RBNAppUpdateError("更新資訊轉址到其他位置，已停止檢查。")
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let response = response as? HTTPURLResponse else { throw RBNAppUpdateError("GitHub 未回傳更新資訊。") }
            try RBNAppReleaseChecker.validate(response, expectedURL: expectedURL, maximum: maximum)
            self.response = response
            completionHandler(.allow)
        } catch { self.error = error; completionHandler(.cancel) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard data.count + chunk.count <= maximum else {
            error = RBNAppUpdateError("GitHub 更新資訊超過允許大小。")
            dataTask.cancel(); return
        }
        data.append(chunk)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError failure: Error?) {
        if error == nil { error = failure }
        done.signal()
    }
}
