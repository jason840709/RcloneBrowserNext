#if os(macOS)
import Foundation
@preconcurrency import AppKit
@preconcurrency import WebKit

enum RBNInterfaceScale {
    static func zoom(_ displayedScale: Int) -> CGFloat { CGFloat(displayedScale - 10) / 100 }
}

/// Use the same canvas as the bundled CSS before WebKit has a document to draw.
struct RBNWebAppearance {
    let theme: String

    init(theme: String?) {
        switch theme {
        case "dark": self.theme = "blue-dark"
        case "light": self.theme = "blue-light"
        case "purple-light", "purple-dark", "blue-light", "blue-dark", "green-light", "green-dark": self.theme = theme!
        default: self.theme = "purple-dark"
        }
    }

    var isDark: Bool { theme.hasSuffix("-dark") }
    var backgroundColor: NSColor {
        let component: CGFloat = isDark ? 28.0 / 255 : 241.0 / 255
        return NSColor(srgbRed: component, green: component, blue: component, alpha: 1)
    }
    var documentStartScript: String {
        // Theme is selected from the fixed list above, never interpolated from
        // an arbitrary saved string. The page's early script consumes this
        // before its stylesheet and React bootstrap can show a different theme.
        "window.__rbnInitialAppearance = {theme: '\(theme)'}; document.documentElement.dataset.theme = '\(theme)';"
    }
}

/// WebKit's private content views need not forward auxiliary mouse events up
/// the responder chain. Route this window's side buttons before hit testing.
final class RcloneBrowserWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if let browser = contentView as? RcloneWebView,
           browser.handleHistoryEvent(event, routedByWindow: true) { return }
        super.sendEvent(event)
    }
}

/// Finder supplies file URLs directly to the native host. Dropping only prepares
/// a selection in the interface; the usual transfer confirmation remains separate.
final class RcloneWebView: WKWebView {
    var acceptsFileDrop: (() -> Bool)?
    var onFileDrop: (([URL], CGPoint) -> Void)?
    var acceptsHistoryNavigation: (() -> Bool)?
    var onHistoryNavigation: ((String, CGPoint, TimeInterval, String) -> Void)?
    private var historyEventMonitor: Any?
    private var appearanceScript: WKUserScript?
    private var appliedTheme: String?
    private var pressedHistoryEvents = [Int: Int]()
    private struct HistoryEventID: Equatable {
        let type: NSEvent.EventType
        let button: Int
        let timestamp: TimeInterval
        let number: Int
    }
    private var handledHistoryEvents = [HistoryEventID]()

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    func prepareForInitialLoad(_ appearance: RBNWebAppearance) {
        // The window already has its final background while WebKit prepares
        // its first frame. Reveal only after the bundled document has loaded.
        isHidden = true
        applyAppearance(appearance)
    }

    func applyAppearance(_ appearance: RBNWebAppearance) {
        guard appliedTheme != appearance.theme else { return }
        appliedTheme = appearance.theme
        underPageBackgroundColor = appearance.backgroundColor
        wantsLayer = true
        layer?.backgroundColor = appearance.backgroundColor.cgColor
        let controller = configuration.userContentController
        let retained = controller.userScripts.filter { $0 !== appearanceScript }
        controller.removeAllUserScripts()
        retained.forEach { controller.addUserScript($0) }
        let script = WKUserScript(source: appearance.documentStartScript,
                                  injectionTime: .atDocumentStart, forMainFrameOnly: true)
        appearanceScript = script
        controller.addUserScript(script)
    }

    func revealInitialDocument() { isHidden = false }

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

    fileprivate func handleHistoryEvent(_ event: NSEvent, routedByWindow: Bool = false) -> Bool {
        guard event.type == .otherMouseDown || event.type == .otherMouseUp,
              event.buttonNumber == 3 || event.buttonNumber == 4 else { return false }
        guard let window = window, window.attachedSheet == nil,
              NSApp.modalWindow == nil, acceptsHistoryNavigation?() == true,
              onHistoryNavigation != nil else { return false }
        let location: CGPoint
        if event.window === window {
            location = convert(event.locationInWindow, from: nil)
        } else if event.window == nil, routedByWindow || (window.isKeyWindow && NSApp.isActive) {
            // Some mouse drivers deliver auxiliary events without a window.
            // Their locationInWindow is a screen point. Use the event's own
            // location, which stays correct if the pointer has since moved.
            location = convert(window.convertPoint(fromScreen: event.locationInWindow), from: nil)
        } else {
            return false
        }
        guard bounds.contains(location) else { return false }
        let identity = HistoryEventID(type: event.type, button: event.buttonNumber,
                                      timestamp: event.timestamp, number: event.eventNumber)
        if handledHistoryEvents.contains(identity) { return true }
        handledHistoryEvents.append(identity)
        if handledHistoryEvents.count > 16 { handledHistoryEvents.removeFirst() }
        // AppKit gives a matching down/up pair the same event number. A lost
        // release must not make a later release-only press look like that old
        // pair merely because both used the same button.
        let wasPressed = pressedHistoryEvents[event.buttonNumber] == event.eventNumber
        if event.type == .otherMouseUp { pressedHistoryEvents.removeValue(forKey: event.buttonNumber) }
        if event.type == .otherMouseDown { pressedHistoryEvents[event.buttonNumber] = event.eventNumber }
        if event.type == .otherMouseDown || !wasPressed {
            // Match this physical press with a possible WebKit DOM fallback.
            // Epoch milliseconds avoid dropping a second fast press merely
            // because it has the same direction as the first one.
            let eventTime = (Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime + event.timestamp) * 1000
            onHistoryNavigation?(event.buttonNumber == 3 ? "back" : "forward",
                                 documentPoint(from: location), eventTime,
                                 event.type == .otherMouseDown ? "down" : "up")
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
        pressedHistoryEvents.removeAll()
        handledHistoryEvents.removeAll()
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
