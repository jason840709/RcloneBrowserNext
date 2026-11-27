#if os(macOS)
import Foundation
import CryptoKit
import Darwin

/// Runs as either the client regression suite or its own pipe-only fake engine.
/// Large JSON values are generated in memory and never materialized as fixtures.
@main struct MacEngineTransportTests {
    static let mebibyte = 1024 * 1024
    static let pattern = Data(String(repeating: "0123456789abcdef", count: 4096).utf8)
    static let tail = "end-🌲-\"-\\-line\nend"
    static var passed = 0
    static var failed = 0
    struct Failure: Error, CustomStringConvertible { let description: String }
    final class Events {
        let lock = NSLock()
        let signal = DispatchSemaphore(value: 0)
        var values = [[String: Any]]()
        func append(_ value: [String: Any]) { lock.holding { values.append(value) }; signal.signal() }
        func snapshot() -> [[String: Any]] { lock.holding { values } }
    }
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }
    static func check(_ title: String, _ body: () throws -> Void) {
        do { try autoreleasepool(invoking: body); passed += 1; print("PASS \(title)") }
        catch { failed += 1; print("FAIL \(title): \(error)") }
    }
    static func waitFor(_ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline { if predicate() { return true }; Thread.sleep(forTimeInterval: 0.01) }
        return predicate()
    }
    static func validatePayload(_ result: [String: Any], expectedSize: Int? = nil) throws {
        guard let payload = result["payload"] as? String,
              let declared = result["payloadBytes"] as? Int else { throw Failure(description: "missing payload") }
        let bytes = Data(payload.utf8)
        try expect(bytes.count == declared, "complete payload length")
        if let expectedSize = expectedSize { try expect(bytes.count == expectedSize, "requested payload length") }
        var hash = SHA256()
        for _ in 0..<(declared / pattern.count) { hash.update(data: pattern) }
        hash.update(data: pattern.prefix(declared % pattern.count))
        try expect(SHA256.hash(data: bytes) == hash.finalize(), "SHA256 of every payload byte")
        try expect(result["tail"] as? String == tail, "complete escaped Unicode tail")
    }
    static func withClient(_ root: URL, _ name: String,
                           _ body: (RBNEngineClient, URL) throws -> Void) throws {
        let state = root.appendingPathComponent(name + "-" + UUID().uuidString, isDirectory: true)
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let client = try RBNEngineClient(stateDirectory: state,
            defaultRcloneDirectory: state.appendingPathComponent("tools"), helperURL: executable, isolated: true)
        defer { if client.isRunning { try? client.shutdown() } }
        try body(client, state)
    }
    static func main() {
        if CommandLine.arguments.dropFirst().first == "--state-dir" { fakeEngine(); return }
        guard CommandLine.arguments.count == 2 else { fputs("Expected an isolated transport work directory\n", stderr); exit(2) }
        let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let root = base.appendingPathComponent("transport-" + UUID().uuidString, isDirectory: true)
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { fputs("FAIL transport fixture: \(error)\n", stderr); exit(1) }
        defer { try? FileManager.default.removeItem(at: root) }

        check("Reply above32MiB preserves every byte, later requests and events") {
            try withClient(root, "large-reply") { client, _ in
                let events = Events(); client.onEvent = events.append
                let size = 33 * mebibyte + 17
                guard let result = try client.invoke("largeReply", arguments: [size], timeout: 30) as? [String: Any] else { throw Failure(description: "reply type") }
                try validatePayload(result, expectedSize: size)
                try expect((result["wireBytes"] as? Int ?? 0) > 32 * mebibyte, "wire reply really exceeds old cap")
                try expect(events.signal.wait(timeout: .now() + 3) == .success, "event after large reply")
                try expect(events.snapshot().last?["type"] as? String == "after-large", "following event content")
                let next = try client.invoke("echo", arguments: ["after-large-か\u{3099}-🌲"], timeout: 3)
                try expect(next as? String == "after-large-か\u{3099}-🌲" && client.isRunning, "next request stays connected")
            }
        }
        check("Exactly32MiB JSON line preserves the old line-boundary case") {
            try withClient(root, "boundary") { client, _ in
                guard let result = try client.invoke("boundaryReply", arguments: [], timeout: 30) as? [String: Any] else { throw Failure(description: "boundary reply type") }
                try expect(result["wireBytes"] as? Int == 32 * mebibyte, "exact wire boundary")
                try expect((result["payloadBytes"] as? Int ?? 0) > 32 * mebibyte - 512, "boundary payload length")
                try validatePayload(result)
                let next = try client.invoke("echo", arguments: ["boundary-next"], timeout: 3)
                try expect(next as? String == "boundary-next" && client.isRunning, "boundary leaves next reply readable")
            }
        }
        check("Event above32MiB preserves content and its following reply") {
            try withClient(root, "large-event") { client, _ in
                let events = Events(); client.onEvent = events.append
                let size = 33 * mebibyte + 29
                let reply = try client.invoke("largeEvent", arguments: [size], timeout: 30)
                try expect(reply as? Bool == true, "reply after a large event")
                try expect(events.signal.wait(timeout: .now() + 3) == .success, "large event delivered")
                guard let event = events.snapshot().first, let data = event["data"] as? [String: Any] else { throw Failure(description: "event type") }
                try expect(event["type"] as? String == "bulk", "large event type")
                try validatePayload(data, expectedSize: size)
                let next = try client.invoke("echo", arguments: ["event-next"], timeout: 3)
                try expect(next as? String == "event-next" && client.isRunning, "next request after event")
            }
        }
        check("Fragmented UTF8 and coalesced event/reply lines retain framing") {
            try withClient(root, "fragments") { client, _ in
                let events = Events(); client.onEvent = events.append
                let text = "é-e\u{0301}-か\u{3099}-🌲-quote\"-line\nend"
                let value = try client.invoke("fragments", arguments: [text], timeout: 3)
                try expect((value as? String).map { Array($0.utf8) } == Array(text.utf8), "original UTF8 bytes")
                try expect(events.signal.wait(timeout: .now() + 3) == .success && events.signal.wait(timeout: .now() + 3) == .success, "both coalesced events")
                try expect(events.snapshot().compactMap { $0["type"] as? String } == ["first", "second"], "ordered event frames")
                let next = try client.invoke("echo", arguments: ["after-fragments"], timeout: 3)
                try expect(next as? String == "after-fragments", "coalesced duplicate did not corrupt following reply")
            }
        }
        check("Out of order and duplicate replies keep request correlation") {
            try withClient(root, "correlation") { client, _ in
                let held = try client.submit("hold", arguments: [])
                let released = try client.submit("release", arguments: [])
                let fast = try client.wait(released, timeout: 3)
                let slow = try client.wait(held, timeout: 3)
                try expect(fast as? String == "fast" && slow as? String == "held", "out of order values")
                let next = try client.invoke("echo", arguments: ["after-duplicate"], timeout: 3)
                try expect(next as? String == "after-duplicate", "duplicate reply ignored")
            }
        }
        check("Malformed JSON fails pending requests and closes owned stdin") {
            try withClient(root, "malformed") { client, state in
                let held = try client.submit("hold", arguments: [])
                let broken = try client.submit("malformed", arguments: [])
                var errors = 0
                for request in [held, broken] { do { _ = try client.wait(request, timeout: 3) } catch { errors += 1 } }
                try expect(errors == 2 && !client.isRunning, "all pending requests failed")
                try expect(waitFor { FileManager.default.fileExists(atPath: state.appendingPathComponent("eof-observed").path) }, "fake child observed stdin EOF")
                let starts = try String(contentsOf: state.appendingPathComponent("starts"), encoding: .utf8)
                try expect(starts == "start\n", "no automatic restart")
            }
        }
        check("EOF mid JSON fails pending requests without restarting") {
            try withClient(root, "eof") { client, state in
                let held = try client.submit("hold", arguments: [])
                let partial = try client.submit("partialEOF", arguments: [])
                var errors = 0
                for request in [held, partial] { do { _ = try client.wait(request, timeout: 3) } catch { errors += 1 } }
                try expect(errors == 2 && !client.isRunning, "EOF fails pending requests")
                var rejected = false
                do { _ = try client.invoke("echo", arguments: ["no restart"], timeout: 3) } catch { rejected = true }
                try expect(rejected, "stopped client rejects new requests")
                let starts = try String(contentsOf: state.appendingPathComponent("starts"), encoding: .utf8)
                try expect(starts == "start\n", "one helper start")
            }
        }
        check("EOF without final newline does not deliver an unframed reply") {
            try withClient(root, "no-newline") { client, _ in
                var rejected = false
                do { _ = try client.invoke("noNewlineEOF", arguments: [], timeout: 3) } catch { rejected = true }
                try expect(rejected && !client.isRunning, "unframed final packet rejected")
            }
        }
        check("Nonobject JSON remains a protocol failure") {
            try withClient(root, "nonobject") { client, state in
                var rejected = false
                do { _ = try client.invoke("array", arguments: [], timeout: 3) } catch { rejected = true }
                try expect(rejected && !client.isRunning, "array packet rejected")
                try expect(waitFor { FileManager.default.fileExists(atPath: state.appendingPathComponent("eof-observed").path) }, "array failure closes stdin")
            }
        }
        print("Transport checks: \(passed) passed; \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    static func json(_ value: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
    }
    static func quoted(_ text: String) -> String { String(decoding: json(text), as: UTF8.self) }
    static func write(_ data: Data) {
        do { try FileHandle.standardOutput.write(contentsOf: data) }
        catch { Darwin._exit(75) }
    }
    static func reply(_ id: String, _ value: Any) { var data = json(["id": id, "result": value]); data.append(10); write(data) }
    static func event(_ type: String) -> Data { var data = json(["event": ["type": type]]); data.append(10); return data }
    static func emitLarge(_ id: String, payload requested: Int, exactWire: Int? = nil, asEvent: Bool = false) {
        let prefix = asEvent ? "{\"event\":{\"type\":\"bulk\",\"data\":{\"payload\":\"" : "{\"id\":" + quoted(id) + ",\"result\":{\"payload\":\""
        var count = requested
        var wire = exactWire ?? 0
        var suffix = ""
        while true {
            suffix = "\",\"payloadBytes\":\(count),\"wireBytes\":\(wire),\"tail\":" + quoted(tail) + (asEvent ? "}}}\n" : "}}\n")
            let nextCount = exactWire.map { $0 - prefix.utf8.count - suffix.utf8.count + 1 } ?? count
            let nextWire = exactWire ?? (prefix.utf8.count + count + suffix.utf8.count - 1)
            if nextCount == count && nextWire == wire { break }
            count = nextCount; wire = nextWire
        }
        write(Data(prefix.utf8))
        for _ in 0..<(count / pattern.count) { write(pattern) }
        write(Data(pattern.prefix(count % pattern.count)))
        var finish = Data(suffix.utf8)
        if asEvent { var data = json(["id": id, "result": true]); data.append(10); finish.append(data) }
        else { finish.append(event("after-large")) }
        write(finish)
    }
    static func fakeEngine() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--state-dir"), arguments.indices.contains(index + 1) else { Darwin._exit(72) }
        let state = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        try? Data("start\n".utf8).write(to: state.appendingPathComponent("starts"))
        let writer = DispatchQueue(label: "test.fake-engine-writes")
        var held: String?
        while let line = readLine() {
            guard let bytes = line.data(using: .utf8), let request = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let id = request["id"] as? String, let method = request["method"] as? String,
                  let args = request["args"] as? [Any] else { Darwin._exit(73) }
            switch method {
            case "_preferences", "_state":
                let value: [String: Any] = ["settings": ["settingsRevision": 0, "language": "en", "theme": "purple-light", "interfaceScale": 100], "resolvedLanguage": "en", "activeJobs": false, "activeTools": false]
                writer.async { reply(id, value) }
            case "largeReply": let count = args[0] as! Int; writer.async { emitLarge(id, payload: count) }
            case "boundaryReply": writer.async { emitLarge(id, payload: 32 * mebibyte, exactWire: 32 * mebibyte) }
            case "largeEvent": let count = args[0] as! Int; writer.async { emitLarge(id, payload: count, asEvent: true) }
            case "fragments":
                let text = args[0] as! String
                writer.async {
                    var first = json(["id": id, "result": text]); first.append(10)
                    for byte in first { write(Data([byte])); usleep(1000) }
                    var rest = event("first"); rest.append(event("second")); rest.append(json(["id": id, "result": "duplicate"])); rest.append(10); write(rest)
                }
            case "hold": held = id
            case "release":
                let earlier = held; held = nil
                writer.async { reply(id, "fast"); if let earlier = earlier { reply(earlier, "held"); reply(earlier, "duplicate") } }
            case "malformed": writer.async { write(Data("{broken\n".utf8)) }
            case "array": writer.async { write(Data("[]\n".utf8)) }
            case "partialEOF": writer.async { write(Data("{\"id\":".utf8)); Darwin._exit(7) }
            case "noNewlineEOF": writer.async { write(json(["id": id, "result": true])); Darwin._exit(0) }
            case "_shutdown": writer.sync { reply(id, true) }; Darwin._exit(0)
            default: let value = args.first ?? NSNull(); writer.async { reply(id, value) }
            }
        }
        // EOF is also observed while a writer is blocked: a failed client must
        // never leave this owned test child waiting on an unread giant pipe.
        try? Data("eof\n".utf8).write(to: state.appendingPathComponent("eof-observed"))
        Darwin._exit(0)
    }
}
#endif
