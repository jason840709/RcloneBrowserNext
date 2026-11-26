#if os(macOS)
import Foundation
import Darwin

/// TEST ONLY: transports the unchanged Swift recovery test's fixtures and
/// failpoint callbacks to Rust's ignored libtest. No hook is in rbn-engine.
enum EnginePartialRecovery {
    struct TestOptions {
        var forceUnsupportedRename = false
        var beforeExclusiveCreate: (() throws -> Void)?
        var afterDurableProgress: (() -> Void)?
    }
    static func preview(report: URL, plan: URL) throws -> [String: Any] {
        try dictionary(run("preview", report.path, plan.path))
    }
    static func apply(plan: URL, receipt: URL) throws -> [String: Any] {
        try testApply(plan: plan, receipt: receipt, options: TestOptions())
    }
    static func testApply(plan: URL, receipt: URL, options: TestOptions) throws -> [String: Any] {
        try dictionary(run("apply", plan.path, receipt.path, options: options))
    }
    static func cleanup(receipt: URL, result: URL) throws -> [String: Any] {
        try dictionary(run("cleanup", receipt.path, result.path))
    }
    static func testAtomicCommit(directory: URL, temporaryName: String, finalName: String) throws {
        _ = try run("atomicCommit", directory.path, temporaryName, third: finalName)
    }
    private static func dictionary(_ value: Any) throws -> [String: Any] {
        guard let result = value as? [String: Any] else { throw EngineError("Rust recovery test returned a non-object result") }
        return result
    }
    private static func run(_ method: String, _ first: String, _ second: String, third: String? = nil,
                            options: TestOptions = TestOptions()) throws -> Any {
        guard let executable = ProcessInfo.processInfo.environment["RBN_RUST_TEST_BINARY"], executable.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: executable) else {
            throw EngineError("Set RBN_RUST_TEST_BINARY to the actual compiled Rust library test executable")
        }
        let process = Process(), input = Pipe(), output = Pipe()
        // The interruption test kills this Swift supervisor while its callback
        // is SIGSTOP'ed. The Rust child must not inherit the parent's writer:
        // EOF on that pipe is its synchronous stop-before-write instruction.
        for handle in [input.fileHandleForReading, input.fileHandleForWriting,
                       output.fileHandleForReading, output.fileHandleForWriting] {
            let descriptor = handle.fileDescriptor
            guard Darwin.fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { throw EngineError("Cannot make test bridge descriptors close on exec") }
        }
        _ = Darwin.fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--ignored", "--exact", "partial::mac::tests::swift_assertion_bridge", "--nocapture", "--test-threads=1"]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.standardError
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.uppercased().hasPrefix("RCLONE_") }
        try process.run()
        try input.fileHandleForReading.close(); try output.fileHandleForWriting.close()
        defer {
            try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        func send(_ packet: [String: Any]) throws {
            var line = try JSONSerialization.data(withJSONObject: packet, options: [.sortedKeys])
            line.append(10)
            try input.fileHandleForWriting.write(contentsOf: line)
        }
        var request: [String: Any] = ["method": method, "first": first, "second": second,
            "forceUnsupportedRename": options.forceUnsupportedRename,
            "beforeExclusiveCreate": options.beforeExclusiveCreate != nil,
            "afterDurableProgress": options.afterDurableProgress != nil]
        if let third = third { request["third"] = third }
        try send(request)
        var pending = Data(), final: Result<Any, Error>?
        var bytes = [UInt8](repeating: 0, count: 65536)
        while true {
            let amount = bytes.withUnsafeMutableBytes { Darwin.read(output.fileHandleForReading.fileDescriptor, $0.baseAddress, $0.count) }
            if amount < 0 && errno == EINTR { continue }
            guard amount >= 0 else { throw EngineError("Cannot read Rust recovery test output") }
            if amount == 0 { break }
            pending.append(contentsOf: bytes.prefix(amount))
            while let end = pending.firstIndex(of: 10) {
                let line = pending.prefix(upTo: end)
                pending.removeSubrange(...end)
                guard let text = String(data: line, encoding: .utf8), let marker = text.range(of: "RBN-TEST ") else { continue }
                guard final == nil, let packet = try JSONSerialization.jsonObject(with: Data(text[marker.upperBound...].utf8)) as? [String: Any] else {
                    throw EngineError("Invalid or duplicate Rust recovery test packet")
                }
                if let callback = packet["callback"] as? String {
                    do {
                        switch callback {
                        case "beforeExclusiveCreate":
                            guard let body = options.beforeExclusiveCreate else { throw EngineError("Unexpected before-create callback") }
                            try body()
                        case "afterDurableProgress":
                            guard let body = options.afterDurableProgress else { throw EngineError("Unexpected durable-progress callback") }
                            body()
                        default: throw EngineError("Unknown Rust recovery test callback")
                        }
                        try send(["ok": true])
                    } catch { try send(["error": error.localizedDescription]) }
                } else if let error = packet["error"] as? String { final = .failure(EngineError(error)) }
                else if let value = packet["result"] { final = .success(value) }
                else { throw EngineError("Rust recovery test packet has no result") }
            }
            guard pending.count <= 32 * 1024 * 1024 else { throw EngineError("Rust recovery test line exceeded its limit") }
        }
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0, pending.isEmpty, let result = final else {
            throw EngineError("Rust recovery test exited without a complete result (\(process.terminationStatus))")
        }
        return try result.get()
    }
}
#endif
