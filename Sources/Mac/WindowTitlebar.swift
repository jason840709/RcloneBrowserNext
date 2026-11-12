#if os(macOS)
import Foundation
@preconcurrency import AppKit

/// Native titlebar zoom, leaving document events, controls and dragging alone.
enum RBNTitlebarInteraction {
    static func standardFrame(for window: NSWindow, fallback: NSRect) -> NSRect {
        window.screen?.visibleFrame ?? fallback
    }

    static func handle(_ event: NSEvent, in window: NSWindow, enabled: Bool = true) -> Bool {
        guard enabled, window.attachedSheet == nil,
              event.type == .leftMouseDown, event.clickCount == 2,
              event.windowNumber == window.windowNumber else { return false }
        let point = event.locationInWindow
        guard NSRect(origin: .zero, size: window.frame.size).contains(point),
              point.y > window.contentLayoutRect.maxY else { return false }

        // A custom toolbar group may contain padding as well as NSButtons.
        // Its whole view belongs to the control, including that padding.
        for item in window.toolbar?.items ?? [] {
            if let view = item.view, view.window === window, !view.isHidden,
               view.convert(view.bounds, to: nil).contains(point) { return false }
        }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let button = window.standardWindowButton(kind),
               button.convert(button.bounds, to: nil).contains(point) { return false }
        }
        if let frameView = window.contentView?.superview {
            var hit = frameView.hitTest(frameView.convert(point, from: nil))
            while let view = hit, view !== frameView {
                if view is NSControl { return false }
                hit = view.superview
            }
        }
        window.performZoom(nil)
        return true
    }
}
#endif
