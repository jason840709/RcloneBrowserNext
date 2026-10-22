#if os(macOS)
import Foundation
@preconcurrency import AppKit

@main struct MacCompletionTests {
    static var passed = 0
    static var failed = 0
    struct Failure: Error { let message: String }
    static func check(_ title: String, _ body: () throws -> Void) {
        do { try body(); passed += 1; print("PASS \(title)") }
        catch { failed += 1; print("FAIL \(title): \(error)") }
    }
    static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }
    static func job(_ id: String, _ state: String = "completed", dry: Bool = false) -> [String: Any] {
        ["id": id, "status": state, "request": ["dryRun": dry]]
    }
    static func main() {
        _ = NSApplication.shared
        var requests = [NSApplication.RequestUserAttentionType]()
        var cancellations = [Int]()
        let attention = RBNCompletionAttention(request: {
            requests.append($0); return requests.count
        }, cancel: { cancellations.append($0) })
        check("background completion requests persistent Dock attention until activation") {
            try expect(attention.consume(job("done"), enabled: true, isActive: false, isTerminating: false), "new completion")
            try expect(requests == [.criticalRequest], "must use the persistent AppKit request")
        }
        check("duplicate terminal events do not repeat attention or banners") {
            try expect(!attention.consume(job("done"), enabled: true, isActive: false, isTerminating: false), "duplicate")
            try expect(requests.count == 1, "duplicate attention")
        }
        check("parallel completions within a second share the ongoing bounce") {
            try expect(attention.consume(job("parallel"), enabled: true, isActive: false, isTerminating: false), "banner remains eligible")
            try expect(requests.count == 1, "do not restart ongoing bounce")
        }
        check("later failures share the still-unacknowledged attention request") {
            try expect(attention.consume(job("failed", "failed"), enabled: true, isActive: false, isTerminating: false), "failure")
            try expect(requests.count == 1 && cancellations.isEmpty, "do not replace the persistent request")
        }
        check("foreground completion never bounces or steals focus") {
            try expect(attention.consume(job("front"), enabled: true, isActive: true, isTerminating: false), "foreground banner")
            try expect(requests.count == 1, "foreground attention")
        }
        check("Dock switch off does not disable the independent banner path") {
            try expect(attention.consume(job("disabled"), enabled: false, isActive: false, isTerminating: false), "banner eligible")
            try expect(!attention.consume(job("disabled"), enabled: true, isActive: false, isTerminating: false), "no replay on enable")
            try expect(requests.count == 1, "disabled attention")
        }
        check("preview success and preview failure stay silent") {
            for state in ["completed", "failed"] {
                try expect(!attention.consume(job("dry-" + state, state, dry: true), enabled: true, isActive: false, isTerminating: false), "preview")
            }
        }
        check("queued running stopping cancelled interrupted and paused jobs stay silent") {
            for state in ["queued", "running", "cancelling", "cancelled", "interrupted", "paused"] {
                try expect(!attention.consume(job(state, state), enabled: true, isActive: false, isTerminating: false), state)
            }
        }
        check("quit suppression never creates a new notification") {
            try expect(!attention.consume(job("quitting"), enabled: true, isActive: false, isTerminating: true), "termination")
        }
        check("activation or termination cancels outstanding attention idempotently") {
            attention.cancel(); attention.cancel()
            try expect(cancellations == [1], "cancel once per outstanding request")
        }
        check("a new background completion can request attention after acknowledgement") {
            _ = attention.consume(job("after-activation"), enabled: true, isActive: false, isTerminating: false)
            try expect(requests == [.criticalRequest, .criticalRequest], "request again for a new job")
            attention.cancel()
        }
        check("invalid requests cannot create attention") {
            for event: [String: Any] in [[:], ["id": "bad", "status": "completed"], job("")] {
                try expect(!attention.consume(event, enabled: true, isActive: false, isTerminating: false), "invalid event")
            }
        }
        check("native AppKit attention and cancellation API can be invoked") {
            let native = RBNCompletionAttention()
            _ = native.consume(job("native-smoke"), enabled: true, isActive: false, isTerminating: false)
            native.cancel()
            // This is API execution, not an assertion about Dock pixels or
            // the host machine's user-controlled animation preference.
        }
        print("RESULT \(passed) passed, \(failed) failed")
        if failed != 0 { exit(1) }
    }
}
#endif
