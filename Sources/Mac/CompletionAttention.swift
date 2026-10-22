#if os(macOS)
import Foundation
@preconcurrency import AppKit

/// Matches QApplication::alert(window, 0) used by the original Rclone Browser.
/// macOS owns the repeating Dock cadence until the user returns to the window.
final class RBNCompletionAttention {
    private var seen = Set<String>()
    private var attentionID: Int?
    private var pending = false
    private let request: (NSApplication.RequestUserAttentionType) -> Int
    private let cancelRequest: (Int) -> Void
    init(request: @escaping (NSApplication.RequestUserAttentionType) -> Int = { NSApp.requestUserAttention($0) },
         cancel: @escaping (Int) -> Void = { NSApp.cancelUserAttentionRequest($0) }) {
        self.request = request; self.cancelRequest = cancel
    }
    func consume(_ job: [String: Any], enabled: Bool, isActive: Bool, isTerminating: Bool,
                 isWindowPresented: Bool? = nil) -> Bool {
        precondition(Thread.isMainThread)
        guard let id = job["id"] as? String, !id.isEmpty,
              let state = job["status"] as? String, ["completed", "failed"].contains(state),
              let transfer = job["request"] as? [String: Any], transfer["dryRun"] as? Bool == false,
              seen.insert(id).inserted, !isTerminating else { return false }
        if enabled && !(isWindowPresented ?? isActive) { pending = true }
        reconcile(enabled: enabled, isWindowPresented: isWindowPresented ?? isActive)
        return true
    }
    func reconcile(enabled: Bool, isWindowPresented: Bool, applicationActivated: Bool = false) {
        precondition(Thread.isMainThread)
        if !enabled || isWindowPresented { cancel(); return }
        if applicationActivated {
            // AppKit cancels even on menu-only activation. Keep the pending
            // result until the main window is presented, and rearm when inactive.
            cancelSystemRequest()
        }
        guard pending, attentionID == nil else { return }
        let id = request(.criticalRequest)
        if id >= 0 { attentionID = id }
    }
    private func cancelSystemRequest() {
        if let id = attentionID { cancelRequest(id) }
        attentionID = nil
    }
    func cancel() {
        precondition(Thread.isMainThread)
        cancelSystemRequest(); pending = false
    }
}
#endif
