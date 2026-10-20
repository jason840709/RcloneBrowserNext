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
    var onHistoryNavigation: ((String, CGPoint) -> Void)?
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
            guard let self = self, let window = self.window,
                  event.window === window, window.attachedSheet == nil,
                  NSApp.modalWindow == nil, self.acceptsHistoryNavigation?() == true,
                  event.buttonNumber == 3 || event.buttonNumber == 4 else { return event }
            let location = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(location) else { return event }
            if event.type == .otherMouseDown {
                let point = CGPoint(x: location.x, y: self.isFlipped ? location.y : self.bounds.height - location.y)
                self.onHistoryNavigation?(event.buttonNumber == 3 ? "back" : "forward", point)
            }
            // Consume both phases so WebKit cannot navigate the bundled page
            // or send a second DOM auxiliary-click for the same press.
            return nil
        }
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
        let point = CGPoint(x: location.x, y: isFlipped ? location.y : bounds.height - location.y)
        onFileDrop?(urls, point)
        return true
    }

    private func dropOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsFileDrop?() == true, sender.draggingSourceOperationMask.contains(.copy),
              sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) else { return [] }
        return .copy
    }
}
#endif
