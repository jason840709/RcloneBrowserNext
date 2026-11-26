#if os(macOS)
import Foundation
import CryptoKit
import Darwin

// TEST ONLY. Original native/local-copy assertions use the production client
// and the actual Rust helper. The legacy model oracle is compiled separately
// only to retain independent expected-value calculations in those assertions.
final class RcloneEngine {
    private static let registryLock = NSLock()
    private static weak var registered: RcloneEngine?
    let client: RBNEngineClient
    init(stateDirectory: URL, defaultRcloneDirectory: URL) throws {
        client = try RBNEngineClient(stateDirectory: stateDirectory, defaultRcloneDirectory: defaultRcloneDirectory, isolated: true)
        Self.registryLock.holding { Self.registered = self }
    }
    static func current() throws -> RcloneEngine {
        try registryLock.holding {
            guard let engine = registered else { throw EngineError("The native regression has no Rust engine") }
            return engine
        }
    }
    func invoke(_ method: String, arguments: [Any]) throws -> Any { try client.invoke(method, arguments: arguments, timeout: nil) }
    func submit(_ method: String, arguments: [Any]) throws -> RBNEngineClient.Request { try client.submit(method, arguments: arguments) }
    func wait(_ request: RBNEngineClient.Request) throws -> Any { try client.wait(request, timeout: nil) }
    func shutdown() {
        guard client.isRunning else { return }
        do { try client.shutdown() }
        catch { fputs("FAIL Rust native test engine shutdown: \(error)\n", stderr); Darwin.exit(1) }
    }
}
final class RcloneTools {
    private let engine: RcloneEngine
    init(workDirectory: URL) throws { engine = try RcloneEngine.current() }
    func listSessions() -> [[String: Any]] {
        do {
            guard let sessions = try engine.invoke("listToolSessions", arguments: []) as? [[String: Any]] else {
                throw EngineError("Rust returned an invalid tool session list")
            }
            return sessions
        } catch { fputs("FAIL Rust native test tools: \(error)\n", stderr); Darwin.exit(1) }
    }
    func shutdown() throws {
        guard engine.client.isRunning else { return } // Engine shutdown already owns all tools.
        for session in listSessions() {
            guard let id = session["id"] as? String else { throw EngineError("A Rust tool session has no ID") }
            _ = try engine.invoke("stopToolSession", arguments: [id])
        }
    }
}
enum RBNSHA256 {
    static func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
#endif
