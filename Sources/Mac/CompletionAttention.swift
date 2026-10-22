#if os(macOS)
import Foundation
@preconcurrency import AppKit

/// A short system Dock bounce for each new terminal transfer event. Banner
/// notifications remain separately controlled by notifyOnCompletion.
final class RBNCompletionAttention {
    private var seen = Set<String>()
    private var attentionID: Int?
    private var lastAttention: TimeInterval?
    private let clock: () -> TimeInterval
    private let request: (NSApplication.RequestUserAttentionType) -> Int
    private let cancelRequest: (Int) -> Void

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         request: @escaping (NSApplication.RequestUserAttentionType) -> Int = { NSApp.requestUserAttention($0) },
         cancel: @escaping (Int) -> Void = { NSApp.cancelUserAttentionRequest($0) }) {
        self.clock = clock; self.request = request; self.cancelRequest = cancel
    }

    /// Returns true exactly once for a real completed/failed job, so the host
    /// can share deduplication with its existing Notification Center message.
    /// Call only for live engine events, never for restored job history.
    func consume(_ job: [String: Any], enabled: Bool, isActive: Bool, isTerminating: Bool) -> Bool {
        precondition(Thread.isMainThread)
        guard let id = job["id"] as? String, !id.isEmpty,
              let state = job["status"] as? String, ["completed", "failed"].contains(state),
              let transfer = job["request"] as? [String: Any], transfer["dryRun"] as? Bool == false,
              seen.insert(id).inserted, !isTerminating else { return false }
        guard enabled, !isActive else { return true }
        let now = clock()
        // Several parallel jobs finishing within the same one-second system
        // bounce need one attention request, not repeatedly restarted bounces.
        if let previous = lastAttention, now - previous < 1 { return true }
        cancel()
        let identifier = request(.informationalRequest)
        if identifier >= 0 { attentionID = identifier; lastAttention = now }
        return true
    }

    func cancel() {
        precondition(Thread.isMainThread)
        if let identifier = attentionID { cancelRequest(identifier) }
        attentionID = nil
    }
}
#endif
