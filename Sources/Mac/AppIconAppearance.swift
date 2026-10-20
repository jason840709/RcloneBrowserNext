#if os(macOS)
import Foundation
@preconcurrency import AppKit

/// Finder and a stopped Dock item read the application's file icon. Updating
/// NSApplication.applicationIconImage alone affects only the running process.
enum RBNAppIconAppearance {
    /// Assigns the same transparent artwork to the installed application's
    /// custom file icon through AppKit. Contents, Info.plist and the code
    /// signature are not rewritten. A read-only/translocated app keeps its
    /// bundled icon and can try again from its installed location next launch.
    @discardableResult
    static func persist(_ image: NSImage, at applicationURL: URL) -> Bool {
        guard image.isValid, applicationURL.isFileURL,
              applicationURL.pathExtension.lowercased() == "app",
              FileManager.default.isWritableFile(atPath: applicationURL.path),
              FileManager.default.fileExists(atPath: applicationURL.appendingPathComponent("Contents/Info.plist").path)
        else { return false }

        // Do not clear the icon at termination: this custom file icon is what
        // keeps the selected family in Finder and the Dock after the app exits.
        // The next launch reapplies it, including after an app update replaces
        // the bundle. AppKit also notifies the system's icon service of changes.
        return NSWorkspace.shared.setIcon(image, forFile: applicationURL.path, options: [])
    }
}
#endif
