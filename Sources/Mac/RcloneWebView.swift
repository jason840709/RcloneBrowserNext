#if os(macOS)
import Foundation
@preconcurrency import AppKit
@preconcurrency import WebKit

enum RBNInterfaceScale {
    /// 100% is one CSS pixel per point, the same scale as Finder and System Settings.
    static func zoom(_ displayedScale: Int) -> CGFloat { CGFloat(displayedScale) / 100 }
}

/// Use the same canvas as the bundled CSS before WebKit has a document to draw.
/// A theme is "<accent>-<mode>"; mode "auto" follows the system appearance.
struct RBNWebAppearance {
    let theme: String
    let isDark: Bool

    init(theme: String?, systemIsDark: Bool = RBNWebAppearance.systemIsDark) {
        let resolved: String
        switch theme {
        case "dark": resolved = "blue-dark"
        case "light": resolved = "blue-light"
        case let value? where RBNWebAppearance.isTheme(value): resolved = value
        default: resolved = "purple-auto"
        }
        self.theme = resolved
        isDark = resolved.hasSuffix("-dark") || (resolved.hasSuffix("-auto") && systemIsDark)
    }

    static func isTheme(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        return parts.count == 2 && ["purple", "blue", "green"].contains(parts[0]) && ["dark", "light", "auto"].contains(parts[1])
    }

    /// The system-wide choice, independent of any appearance this app forces.
    static var systemIsDark: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.caseInsensitiveCompare("Dark") == .orderedSame
    }

    var followsSystem: Bool { theme.hasSuffix("-auto") }
    var family: String { String(theme.prefix { $0 != "-" }) }
    /// Identity for change detection: an auto theme repaints when the system flips.
    var key: String { "\(theme)|\(isDark)" }
    /// The window and canvas color (--window in styles/tokens.css).
    var backgroundColor: NSColor {
        let component: CGFloat = isDark ? 37.0 / 255 : 237.0 / 255
        return NSColor(srgbRed: component, green: component, blue: component, alpha: 1)
    }
    var documentStartScript: String {
        // Theme is selected from the fixed list above, never interpolated from
        // an arbitrary saved string. The page's early script consumes this
        // before its stylesheet and React bootstrap can show a different theme.
        "window.__rbnInitialAppearance = {theme: '\(theme)'}; document.documentElement.dataset.theme = '\(theme)';"
    }
}

/// WebKit's private content views need not forward navigation events up the
/// responder chain. Route mouse buttons and driver-generated swipes first.
final class RcloneBrowserWindow: NSWindow {
    weak var browserView: RcloneWebView?

    override func sendEvent(_ event: NSEvent) {
        if let browser = browserView ?? contentView as? RcloneWebView,
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
    var hostScript: String?
    private var pressedHistoryEvents = [Int: Int]()
    private struct HistoryEventID: Equatable {
        let type: NSEvent.EventType
        let button: Int
        let timestamp: TimeInterval
        let number: Int
        let phase: NSEvent.Phase
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
        guard appliedTheme != appearance.key else { return }
        appliedTheme = appearance.key
        underPageBackgroundColor = appearance.backgroundColor
        wantsLayer = true
        layer?.backgroundColor = appearance.backgroundColor.cgColor
        let controller = configuration.userContentController
        let retained = controller.userScripts.filter { $0 !== appearanceScript }
        controller.removeAllUserScripts()
        retained.forEach { controller.addUserScript($0) }
        let script = WKUserScript(source: (hostScript ?? "") + appearance.documentStartScript,
                                  injectionTime: .atDocumentStart, forMainFrameOnly: true)
        appearanceScript = script
        controller.addUserScript(script)
    }

    func revealInitialDocument() { isHidden = false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopHistoryMonitoring()
        guard window != nil else { return }
        // Logi Options translates MX Master Back/Forward into .swipe events;
        // they never produce otherMouseDown or a DOM mouse event. Handle this
        // AppKit route too, scoped to this window, without global input access.
        historyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .otherMouseUp, .swipe]) { [weak self] event in
            self?.handleHistoryEvent(event) == true ? nil : event
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        if !handleHistoryEvent(event) { super.otherMouseDown(with: event) }
    }

    override func otherMouseUp(with event: NSEvent) {
        if !handleHistoryEvent(event) { super.otherMouseUp(with: event) }
    }

    override func swipe(with event: NSEvent) {
        if !handleHistoryEvent(event) { super.swipe(with: event) }
    }

    // WebKit's default actions navigate its HTML back-forward list. This app
    // has one document and keeps folder history inside each pane instead.
    override func goBack(_ sender: Any?) { navigateHistoryCommand("back") }
    override func goForward(_ sender: Any?) { navigateHistoryCommand("forward") }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(goBack(_:)) || item.action == #selector(goForward(_:)) {
            return historyNavigationAllowed
        }
        return super.validateUserInterfaceItem(item)
    }

    private var historyNavigationAllowed: Bool {
        guard let window = window else { return false }
        return window.attachedSheet == nil && NSApp.modalWindow == nil &&
            acceptsHistoryNavigation?() == true && onHistoryNavigation != nil
    }

    private func navigateHistoryCommand(_ direction: String) {
        guard historyNavigationAllowed else { return }
        // Commands use the active pane. The web handler preserves text-editing
        // shortcuts and applies the same modal guards as the mouse route.
        onHistoryNavigation?(direction, CGPoint(x: -1, y: -1), Date().timeIntervalSince1970 * 1000, "command")
    }

    func handleHistoryEvent(_ event: NSEvent, routedByWindow: Bool = false) -> Bool {
        let isSwipe = event.type == .swipe
        if isSwipe {
            guard event.deltaX.isFinite, event.deltaY.isFinite,
                  abs(event.deltaX) > abs(event.deltaY) else { return false }
        } else {
            guard event.type == .otherMouseDown || event.type == .otherMouseUp,
                  event.buttonNumber == 3 || event.buttonNumber == 4 else { return false }
        }
        guard let window = window, historyNavigationAllowed else { return false }
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
        // A Logitech swipe commonly arrives only as .ended. Do not require a
        // preceding .began and do not confuse it with horizontal wheel scroll.
        // If a driver supplies intermediate/cancelled phases, consume them
        // without turning an unfinished gesture into folder navigation.
        if isSwipe && event.phase != [] && !event.phase.contains(.ended) { return true }
        let button = isSwipe ? (event.deltaX > 0 ? 3 : 4) : event.buttonNumber
        let identity = HistoryEventID(type: event.type, button: button,
                                      timestamp: event.timestamp, number: isSwipe ? 0 : event.eventNumber,
                                      phase: isSwipe ? event.phase : [])
        if handledHistoryEvents.contains(identity) { return true }
        handledHistoryEvents.append(identity)
        if handledHistoryEvents.count > 16 { handledHistoryEvents.removeFirst() }
        let eventTime = (Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime + event.timestamp) * 1000
        if isSwipe {
            onHistoryNavigation?(button == 3 ? "back" : "forward", documentPoint(from: location), eventTime, "swipe")
            return true
        }
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
