#if os(macOS)
@preconcurrency import AppKit

/// Applies the selected family to the running application's Dock icon.
/// Finder and a stopped Dock item continue to use the fixed bundle icon.
enum RBNAppIconAppearance {
    /// A custom file icon adds Finder metadata that fails strict code-signature
    /// verification, so appearance changes only the in-memory AppKit image.
    @discardableResult
    static func apply(_ image: NSImage) -> Bool {
        guard image.isValid else { return false }
        NSApplication.shared.applicationIconImage = image
        return true
    }
}
#endif
