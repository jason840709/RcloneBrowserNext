#if os(macOS)
import Foundation
@preconcurrency import AppKit
@preconcurrency import WebKit

/// Finder supplies file URLs directly to the native host. Dropping only prepares
/// a selection in the interface; the usual transfer confirmation remains separate.
final class RcloneWebView: WKWebView {
    var acceptsFileDrop: (() -> Bool)?
    var onFileDrop: (([URL], CGPoint) -> Void)?
    var acceptsHistoryNavigation: (() -> Bool)?
    var onHistoryNavigation: ((String, CGPoint, TimeInterval) -> Void)?
    private var historyEventMonitor: Any?

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopHistoryMonitoring()
        guard window != nil else { return }
        // WKWebView's content view can consume auxiliary buttons before the
        // responder chain reaches this view. A local monitor handles only this
        // window; it needs no global input or Accessibility permission.
        historyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .otherMouseUp]) { [weak self] event in
            self?.handleHistoryEvent(event) == true ? nil : event
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        if !handleHistoryEvent(event) { super.otherMouseDown(with: event) }
    }

    override func otherMouseUp(with event: NSEvent) {
        if !handleHistoryEvent(event) { super.otherMouseUp(with: event) }
    }

    private func handleHistoryEvent(_ event: NSEvent) -> Bool {
        guard let window = window, window.attachedSheet == nil,
              NSApp.modalWindow == nil, acceptsHistoryNavigation?() == true,
              event.type == .otherMouseDown || event.type == .otherMouseUp,
              event.buttonNumber == 3 || event.buttonNumber == 4 else { return false }
        let location: CGPoint
        if event.window === window {
            location = convert(event.locationInWindow, from: nil)
        } else if event.window == nil, window.isKeyWindow, NSApp.isActive {
            // Some mouse drivers deliver auxiliary events without a window.
            // Handle those only while this app owns the key window and the
            // pointer is actually inside its content; never monitor globally.
            location = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        } else {
            return false
        }
        guard bounds.contains(location) else { return false }
        if event.type == .otherMouseDown {
            // Match this physical press with a possible WebKit DOM fallback.
            // Epoch milliseconds avoid dropping a second fast press merely
            // because it has the same direction as the first one.
            let eventTime = (Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime + event.timestamp) * 1000
            onHistoryNavigation?(event.buttonNumber == 3 ? "back" : "forward",
                                 documentPoint(from: location), eventTime)
        }
        // Consume both phases so WebKit cannot navigate the bundled page or
        // generate a second auxiliary click for a press already handled here.
        return true
    }

    func stopHistoryMonitoring() {
        if let monitor = historyEventMonitor {
            NSEvent.removeMonitor(monitor)
            historyEventMonitor = nil
        }
    }

    deinit {
        if let monitor = historyEventMonitor { NSEvent.removeMonitor(monitor) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dropOperation(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dropOperation(sender) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !dropOperation(sender).isEmpty }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard !dropOperation(sender).isEmpty,
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        let location = convert(sender.draggingLocation, from: nil)
        let point = documentPoint(from: location)
        onFileDrop?(urls, point)
        return true
    }

    /// Native events use view points, while elementFromPoint expects CSS pixels.
    /// Keep Finder drops and mouse history in the correct pane at every zoom level.
    func documentPoint(from location: CGPoint) -> CGPoint {
        let zoom = pageZoom.isFinite && pageZoom > 0 ? pageZoom : 1
        let x = location.x - bounds.minX
        let y = isFlipped ? location.y - bounds.minY : bounds.maxY - location.y
        return CGPoint(x: x / zoom, y: y / zoom)
    }

    private func dropOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsFileDrop?() == true, sender.draggingSourceOperationMask.contains(.copy),
              sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) else { return [] }
        return .copy
    }
}
#endif
