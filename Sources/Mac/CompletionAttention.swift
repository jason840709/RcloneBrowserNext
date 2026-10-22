#if os(macOS)
import Foundation
@preconcurrency import AppKit

/// Mirrors QApplication::alert(window, 0): AppKit owns the repeating Dock
/// cadence until activation. One outstanding request covers concurrent jobs.
/// Notification Center banners are separately controlled by notifyOnCompletion.
final class RBNCompletionAttention {
    private var seen = Set<String>()
    private var attentionID: Int?
    private let request: (NSApplication.RequestUserAttentionType) -> Int
    private let cancelRequest: (Int) -> Void

    init(request: @escaping (NSApplication.RequestUserAttentionType) -> Int = { NSApp.requestUserAttention($0) },
         cancel: @escaping (Int) -> Void = { NSApp.cancelUserAttentionRequest($0) }) {
        self.request = request; self.cancelRequest = cancel
    }

    /// Only consume live events, never restored history. isActive means the
    /// application is frontmost; no miniaturization requirement is imposed.
    func consume(_ job: [String: Any], enabled: Bool, isActive: Bool, isTerminating: Bool) -> Bool {
        precondition(Thread.isMainThread)
        guard let id = job["id"] as? String, !id.isEmpty,
              let state = job["status"] as? String, ["completed", "failed"].contains(state),
              let transfer = job["request"] as? [String: Any], transfer["dryRun"] as? Bool == false,
              seen.insert(id).inserted, !isTerminating else { return false }
        guard enabled, !isActive else { return true }
        // Do not restart the system animation when more jobs finish. The
        // persistent request has no timeout and is cleared on app activation.
        if attentionID == nil {
            let identifier = request(.criticalRequest)
            if identifier >= 0 { attentionID = identifier }
        }
        return true
    }

    func cancel() {
        precondition(Thread.isMainThread)
        if let identifier = attentionID { cancelRequest(identifier) }
        attentionID = nil
    }
}
#endif
