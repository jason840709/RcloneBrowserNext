#if os(macOS)
import Foundation
@preconcurrency import AppKit
@preconcurrency import WebKit
import CoreGraphics

/// Exercises AppKit mouse delivery, document-start appearance and the actual
/// macOS WebKit viewport. No events are posted outside the test's own window.
@main @MainActor struct MacInterfaceTests {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private final class Loader: NSObject, WKNavigationDelegate {
        var loaded = false
        var failure: Error?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            (webView as? RcloneWebView)?.revealInitialDocument()
            loaded = true
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failure = error }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failure = error }
    }
    private static var passed = 0
    private static var failed = 0

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    private static func wait(until condition: () -> Bool, seconds: TimeInterval = 10) throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        try require(condition(), "Timed out waiting for macOS WebKit")
    }

    private static func evaluate(_ script: String, in view: WKWebView) throws -> Any? {
        var reply: Result<Any?, Error>?
        view.evaluateJavaScript(script) { value, error in
            if let error = error { reply = .failure(error) } else { reply = .success(value) }
        }
        try wait(until: { reply != nil })
        return try reply!.get()
    }

    private static func test(_ title: String, _ body: () throws -> Void) {
        do { try body(); passed += 1; print("PASS \(title)") }
        catch { failed += 1; print("FAIL \(title): \(error)") }
    }

    private static let document = """
    <!doctype html><html><head><meta charset="utf-8">
    <script>window.firstDocumentTheme = window.__rbnInitialAppearance?.theme;
    window.firstRootTheme = document.documentElement.dataset.theme;</script>
    <style>
    html{background:#fff}html[data-theme$="-dark"]{background:#1c1c1c}html[data-theme$="-light"]{background:#f1f1f1}
    html,body{margin:0;width:100%;height:100%;overflow:hidden}
    body{display:grid;grid-template-columns:1fr 1fr}
    section{display:grid;grid-template-rows:1fr 1fr}
    #left{background:#292a2d}#right{background:#38393d}
    </style></head><body><section id="left"><div id="left-top"></div><div id="left-bottom"></div></section>
    <section id="right"><div id="right-top"></div><div id="right-bottom"></div></section>
    <script>
    window.historyEvents=[];window.domSideEvents=0;
    window.__rbnEvent=event=>{if(event.type==='navigateHistory'){
      const data=event.data;window.historyEvents.push({...data,target:document.elementFromPoint(data.x,data.y)?.id});
    }};
    for(const type of ['mousedown','mouseup','auxclick'])document.addEventListener(type,event=>{
      if(event.button===3||event.button===4)window.domSideEvents++;
    },true);
    </script></body></html>
    """

    private static func sideEvent(button: Int, down: Bool, number: Int, time: TimeInterval,
                                  x: Double, y: Double, in view: RcloneWebView) throws -> NSEvent {
        guard let window = view.window, let primary = NSScreen.screens.first else {
            throw Failure(description: "Missing event window or screen")
        }
        let offset = view.bounds.height * CGFloat(y)
        let point = CGPoint(x: view.bounds.minX + view.bounds.width * CGFloat(x),
                            y: view.isFlipped ? view.bounds.minY + offset : view.bounds.maxY - offset)
        let screen = window.convertPoint(toScreen: view.convert(point, to: nil))
        let quartz = CGPoint(x: screen.x, y: primary.frame.maxY - screen.y)
        guard let cgEvent = CGEvent(mouseEventSource: nil,
                                    mouseType: down ? .otherMouseDown : .otherMouseUp,
                                    mouseCursorPosition: quartz, mouseButton: .center) else {
            throw Failure(description: "Could not create the auxiliary mouse event")
        }
        cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        cgEvent.setIntegerValueField(.mouseEventNumber, value: Int64(number))
        cgEvent.timestamp = UInt64(time * 1_000_000_000)
        guard let event = NSEvent(cgEvent: cgEvent) else { throw Failure(description: "Could not create NSEvent") }
        try require(event.buttonNumber == button && event.eventNumber == number && event.type == (down ? .otherMouseDown : .otherMouseUp), "NSEvent changed the button, event number, or phase")
        return event
    }

    /// AppKit has no public factory for .swipe. Use an NSEvent test double for
    /// the documented swipe properties, then send it through the production
    /// NSWindow route. Chromium uses the same approach in its Cocoa swipe tests.
    /// This is driver-event coverage, not a physical MX Master hardware test.
    private final class SwipeEvent: NSEvent {
        var horizontal: CGFloat = 0
        var vertical: CGFloat = 0
        var gesturePhase: NSEvent.Phase = .ended
        var eventTime: TimeInterval = 0
        var eventLocation: CGPoint = .zero
        weak var eventWindow: NSWindow?
        override var type: NSEvent.EventType { .swipe }
        override var deltaX: CGFloat { horizontal }
        override var deltaY: CGFloat { vertical }
        override var phase: NSEvent.Phase { gesturePhase }
        override var timestamp: TimeInterval { eventTime }
        override var locationInWindow: NSPoint { eventLocation }
        override var window: NSWindow? { eventWindow }
        override var windowNumber: Int { eventWindow?.windowNumber ?? 0 }
    }

    private static func swipeEvent(horizontal: CGFloat, vertical: CGFloat = 0,
                                   phase: NSEvent.Phase = .ended, time: TimeInterval,
                                   x: Double, y: Double, in view: RcloneWebView) throws -> SwipeEvent {
        guard let window = view.window else { throw Failure(description: "Missing swipe window") }
        let offset = view.bounds.height * CGFloat(y)
        let point = CGPoint(x: view.bounds.minX + view.bounds.width * CGFloat(x),
                            y: view.isFlipped ? view.bounds.minY + offset : view.bounds.maxY - offset)
        let event = SwipeEvent()
        event.horizontal = horizontal; event.vertical = vertical; event.gesturePhase = phase
        event.eventTime = time; event.eventWindow = window
        event.eventLocation = view.convert(point, to: nil)
        return event
    }

    private static func history(in view: WKWebView) throws -> [[String: Any]] {
        guard let result = try evaluate("window.historyEvents", in: view) as? [[String: Any]] else {
            throw Failure(description: "Missing WebKit history event receipt")
        }
        return result
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = RcloneWebView(frame: NSRect(x: 0, y: 0, width: 1060, height: 680), configuration: configuration)
        view.pageZoom = RBNInterfaceScale.zoom(100)
        let initialAppearance = RBNWebAppearance(theme: "purple-dark")
        view.prepareForInitialLoad(initialAppearance)
        let window = RcloneBrowserWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = initialAppearance.backgroundColor
        window.contentView = view
        test("Saved dark background is installed before showing the window or loading HTML") {
            try require(!window.isVisible && view.url == nil && view.isHidden, "The first WebKit frame became visible before preparation")
            try require(window.backgroundColor == initialAppearance.backgroundColor && view.underPageBackgroundColor == initialAppearance.backgroundColor,
                        "The native window and unloaded web view do not share the saved background")
            try require(abs(view.pageZoom - 0.9) < 0.0001, "New default 100% must use the former 90% size before first load")
        }
        window.orderFront(nil)
        let loader = Loader()
        view.navigationDelegate = loader
        view.loadHTMLString(document, baseURL: nil)

        test("Bundled-style interface loads in macOS WebKit") {
            try wait(until: { loader.loaded || loader.failure != nil }, seconds: 20)
            if let error = loader.failure { throw error }
            try require(loader.loaded, "The document did not load")
        }
        if loader.loaded {
            test("Document-start theme precedes page scripts and the first revealed frame") {
                try require(!view.isHidden, "The loaded document was not revealed")
                try require(try evaluate("window.firstDocumentTheme === 'purple-dark' && window.firstRootTheme === 'purple-dark' && getComputedStyle(document.documentElement).backgroundColor === 'rgb(28, 28, 28)'", in: view) as? Bool == true,
                            "The document started with the wrong theme or white background")
            }
            test("Reload uses the latest saved light theme without retaining an old startup script") {
                let appearance = RBNWebAppearance(theme: "green-light")
                view.prepareForInitialLoad(appearance)
                window.backgroundColor = appearance.backgroundColor
                try require(view.isHidden && view.underPageBackgroundColor == appearance.backgroundColor, "The light canvas was not prepared before reload")
                loader.loaded = false
                view.loadHTMLString(document, baseURL: nil)
                try wait(until: { loader.loaded || loader.failure != nil }, seconds: 20)
                if let error = loader.failure { throw error }
                try require(!view.isHidden && view.configuration.userContentController.userScripts.count == 1, "Reload kept an outdated appearance script or hid the loaded page")
                try require(try evaluate("window.firstDocumentTheme === 'green-light' && window.firstRootTheme === 'green-light' && getComputedStyle(document.documentElement).backgroundColor === 'rgb(241, 241, 241)'", in: view) as? Bool == true,
                            "Reload showed the previous theme")
                let script = view.configuration.userContentController.userScripts.first
                view.applyAppearance(appearance)
                try require(view.configuration.userContentController.userScripts.first === script,
                            "Saving unchanged appearance recreated the document-start script")
            }
            for (scale, effectiveZoom) in [(80, 0.7), (90, 0.8), (100, 0.9), (110, 1.0), (125, 1.15), (120, 1.1), (135, 1.25)] {
                test("\(scale)% zoom changes the viewport and preserves native pane hit testing") {
                    view.pageZoom = RBNInterfaceScale.zoom(scale)
                    try require(abs(Double(view.pageZoom) - effectiveZoom) < 0.0001, "Displayed scale mapped to the wrong visual size")
                    // evaluateJavaScript crosses the WebKit process boundary;
                    // force layout before reading the actual viewport size.
                    guard let viewport = try evaluate("[document.documentElement.clientWidth, document.documentElement.clientHeight]", in: view) as? [NSNumber], viewport.count == 2 else {
                        throw Failure(description: "Missing viewport dimensions")
                    }
                    let expectedWidth = view.bounds.width / CGFloat(effectiveZoom)
                    let expectedHeight = view.bounds.height / CGFloat(effectiveZoom)
                    try require(abs(viewport[0].doubleValue - expectedWidth) <= 1.1, "Viewport width did not follow pageZoom: \(viewport)")
                    try require(abs(viewport[1].doubleValue - expectedHeight) <= 1.1, "Viewport height did not follow pageZoom: \(viewport)")
                    // Points just either side of the visual divider catch the
                    // wrong-pane bug that an unscaled native coordinate causes.
                    for (fraction, side) in [(0.46, "left"), (0.54, "right")] {
                        for (fromTop, row) in [(0.24, "top"), (0.76, "bottom")] {
                            let offset = view.bounds.height * CGFloat(fromTop)
                            let native = CGPoint(x: view.bounds.minX + view.bounds.width * CGFloat(fraction),
                                y: view.isFlipped ? view.bounds.minY + offset : view.bounds.maxY - offset)
                            let point = view.documentPoint(from: native)
                            let hit = try evaluate("document.elementFromPoint(\(point.x),\(point.y))?.id", in: view) as? String
                            let expected = side + "-" + row
                            try require(hit == expected, "Native point hit \(hit ?? "nothing") instead of \(expected)")
                        }
                    }
                }
            }

            var deliveryErrors = [String]()
            view.acceptsHistoryNavigation = { true }
            view.onHistoryNavigation = { direction, point, time, phase in
                let value: [String: Any] = ["type": "navigateHistory", "data": ["direction": direction,
                    "x": point.x, "y": point.y, "eventTime": time, "phase": phase]]
                do {
                    let data = try JSONSerialization.data(withJSONObject: value)
                    let json = String(decoding: data, as: UTF8.self)
                    view.evaluateJavaScript("window.__rbnEvent(\(json))") { _, error in
                        if let error = error { deliveryErrors.append(error.localizedDescription) }
                    }
                } catch { deliveryErrors.append(error.localizedDescription) }
            }
            // This route uses the production NSWindow.sendEvent override and
            // real NSEvents. It deliberately does not invoke the handler itself
            // or depend on a globally posted input event/Accessibility access.
            test("AppKit side-button presses reach the correct WebKit panes once per press") {
                let before = try history(in: view).count
                let time = ProcessInfo.processInfo.systemUptime
                for (button, number, x, y) in [(3, 101, 0.46, 0.76), (4, 102, 0.54, 0.24)] {
                    window.sendEvent(try sideEvent(button: button, down: true, number: number, time: time, x: x, y: y, in: view))
                    window.sendEvent(try sideEvent(button: button, down: false, number: number, time: time + 0.01, x: x, y: y, in: view))
                }
                let events = Array(try history(in: view).dropFirst(before))
                try require(events.count == 2 && deliveryErrors.isEmpty, "A native press was lost or delivered more than once: \(events), \(deliveryErrors)")
                try require(events[0]["direction"] as? String == "back" && events[0]["target"] as? String == "left-bottom", "Back was sent to the wrong pane")
                try require(events[1]["direction"] as? String == "forward" && events[1]["target"] as? String == "right-top", "Forward was sent to the wrong pane")
                try require(events.allSatisfy { $0["phase"] as? String == "down" && ($0["eventTime"] as? Double ?? 0) > 1e12 }, "The native/DOM pairing metadata is missing")
                try require(try evaluate("window.domSideEvents", in: view) as? Int == 0, "A consumed native press leaked a second DOM mouse event")
            }
            test("Release-only side buttons navigate and duplicate delivery stays consumed") {
                let before = try history(in: view).count
                let event = try sideEvent(button: 3, down: false, number: 201,
                                          time: ProcessInfo.processInfo.systemUptime, x: 0.54, y: 0.76, in: view)
                window.sendEvent(event)
                window.sendEvent(event)
                let events = Array(try history(in: view).dropFirst(before))
                try require(events.count == 1 && events[0]["phase"] as? String == "up" && events[0]["target"] as? String == "right-bottom",
                            "A release-only gesture was swallowed, repeated, or sent to the wrong pane")
            }
            test("Rapid side-button presses retain separate gestures and repeated down delivery does not") {
                let before = try history(in: view).count
                let time = ProcessInfo.processInfo.systemUptime
                for index in 0..<2 {
                    let down = try sideEvent(button: 4, down: true, number: 301 + index,
                                             time: time + Double(index) * 0.015, x: 0.46, y: 0.24, in: view)
                    window.sendEvent(down)
                    window.sendEvent(down)
                    window.sendEvent(try sideEvent(button: 4, down: false, number: 301 + index,
                                                  time: time + Double(index) * 0.015 + 0.004, x: 0.46, y: 0.24, in: view))
                }
                try require(try history(in: view).count == before + 2, "Rapid presses were debounced or duplicate delivery navigated twice")
            }
            test("A lost release does not swallow a later release-only gesture in another pane") {
                let before = try history(in: view).count
                let time = ProcessInfo.processInfo.systemUptime
                window.sendEvent(try sideEvent(button: 4, down: true, number: 501,
                                              time: time, x: 0.54, y: 0.24, in: view))
                window.sendEvent(try sideEvent(button: 3, down: true, number: 502,
                                              time: time + 0.02, x: 0.46, y: 0.76, in: view))
                window.sendEvent(try sideEvent(button: 3, down: false, number: 502,
                                              time: time + 0.03, x: 0.46, y: 0.76, in: view))
                window.sendEvent(try sideEvent(button: 4, down: false, number: 503,
                                              time: time + 0.04, x: 0.46, y: 0.76, in: view))
                let events = Array(try history(in: view).dropFirst(before))
                try require(events.count == 3 && events[2]["direction"] as? String == "forward" &&
                            events[2]["phase"] as? String == "up" && events[2]["target"] as? String == "left-bottom",
                            "A missing release swallowed the next gesture or retained the previous pane: \(events)")
            }
            test("A page that rejects history navigation receives no native callback") {
                let before = try history(in: view).count
                view.acceptsHistoryNavigation = { false }
                defer { view.acceptsHistoryNavigation = { true } }
                window.sendEvent(try sideEvent(button: 3, down: false, number: 401,
                                              time: ProcessInfo.processInfo.systemUptime, x: 0.46, y: 0.24, in: view))
                try require(try history(in: view).count == before, "Navigation bypassed the host readiness guard")
            }

            test("Logitech-style ended-only swipes reach the pointed pane without any mouse button event") {
                let before = try history(in: view).count
                let time = ProcessInfo.processInfo.systemUptime
                let back = try swipeEvent(horizontal: 1, time: time, x: 0.54, y: 0.76, in: view)
                window.sendEvent(back)
                // Local monitor, window routing and responder fallback can all
                // see one event. Replaying that event must remain one action.
                window.sendEvent(back)
                view.swipe(with: back)
                window.sendEvent(try swipeEvent(horizontal: -1, time: time + 0.015, x: 0.46, y: 0.24, in: view))
                let events = Array(try history(in: view).dropFirst(before))
                try require(events.count == 2, "Ended-only swipes were lost or dispatched more than once: \(events)")
                try require(events[0]["direction"] as? String == "back" && events[0]["target"] as? String == "right-bottom",
                            "The back swipe did not use the pointed right pane")
                try require(events[1]["direction"] as? String == "forward" && events[1]["target"] as? String == "left-top",
                            "The forward swipe did not use the pointed left pane")
                try require(events.allSatisfy { $0["phase"] as? String == "swipe" }, "Swipe events were incorrectly paired as mouse button phases")
            }
            test("Rapid discrete swipes remain distinct inside a native startup container") {
                let before = try history(in: view).count
                let container = NSView(frame: view.frame)
                window.browserView = view
                window.contentView = container
                container.addSubview(view)
                defer { view.removeFromSuperview(); window.contentView = view; window.browserView = nil }
                let time = ProcessInfo.processInfo.systemUptime
                for index in 0..<2 {
                    window.sendEvent(try swipeEvent(horizontal: 1, phase: [], time: time + Double(index) * 0.01,
                                                    x: 0.46, y: 0.24, in: view))
                }
                try require(try history(in: view).count == before + 2, "A content container or time debounce swallowed a swipe")
            }
            test("Vertical swipes, cancellation and horizontal wheel scrolling do not become back commands") {
                let before = try history(in: view).count
                let time = ProcessInfo.processInfo.systemUptime
                try require(!view.handleHistoryEvent(try swipeEvent(horizontal: 0, vertical: 1, time: time, x: 0.46, y: 0.24, in: view)),
                            "A vertical swipe was captured as folder navigation")
                for phase in [NSEvent.Phase.began, .changed, .cancelled] {
                    _ = view.handleHistoryEvent(try swipeEvent(horizontal: 1, phase: phase, time: time + 0.01,
                                                              x: 0.46, y: 0.24, in: view))
                }
                guard let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                           wheel1: 0, wheel2: 30, wheel3: 0), let event = NSEvent(cgEvent: scroll) else {
                    throw Failure(description: "Could not create horizontal wheel event")
                }
                try require(!view.handleHistoryEvent(event), "Horizontal wheel scrolling was captured as folder navigation")
                try require(try history(in: view).count == before, "A cancelled or unrelated gesture navigated")
            }
            test("A swipe outside this view or from another window cannot navigate its folders") {
                let before = try history(in: view).count
                let time = ProcessInfo.processInfo.systemUptime
                let outside = try swipeEvent(horizontal: 1, time: time, x: -0.1, y: 0.24, in: view)
                try require(!view.handleHistoryEvent(outside, routedByWindow: true), "An out-of-bounds swipe was handled")
                let foreign = try swipeEvent(horizontal: 1, time: time, x: 0.46, y: 0.24, in: view)
                let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
                other.isReleasedWhenClosed = false
                defer { other.close() }
                foreign.eventWindow = other
                try require(!view.handleHistoryEvent(foreign, routedByWindow: true), "A foreign window's swipe was handled")
                try require(try history(in: view).count == before, "An unrelated window or location navigated")
            }
            test("Native menu keyboard equivalents route to folder history instead of WebKit page history") {
                let before = try history(in: view).count
                try require(!view.canGoBack && !view.canGoForward, "The test unexpectedly has HTML page history")
                let menu = NSMenu(title: "Go")
                let back = NSMenuItem(title: "Back", action: #selector(RcloneWebView.goBack(_:)), keyEquivalent: "[")
                let forward = NSMenuItem(title: "Forward", action: #selector(RcloneWebView.goForward(_:)), keyEquivalent: "]")
                back.target = view; forward.target = view
                back.keyEquivalentModifierMask = [.command]; forward.keyEquivalentModifierMask = [.command]
                menu.addItem(back); menu.addItem(forward)
                try require(view.validateUserInterfaceItem(back), "Folder history action was disabled by WebKit's empty page history")
                for (character, code) in [("[", UInt16(33)), ("]", UInt16(30))] {
                    guard let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                    context: nil, characters: character, charactersIgnoringModifiers: character,
                                                    isARepeat: false, keyCode: code) else {
                        throw Failure(description: "Could not create native history keyboard shortcut")
                    }
                    try require(menu.performKeyEquivalent(with: key), "The native menu did not accept Command-\(character)")
                }
                let events = Array(try history(in: view).dropFirst(before))
                try require(events.count == 2 && events[0]["direction"] as? String == "back" && events[1]["direction"] as? String == "forward",
                            "Native menu actions did not reach folder history")
                try require(events.allSatisfy { $0["phase"] as? String == "command" && ($0["x"] as? Double) == -1 },
                            "A native keyboard command did not select the active pane")
                view.acceptsHistoryNavigation = { false }
                defer { view.acceptsHistoryNavigation = { true } }
                try require(!view.validateUserInterfaceItem(back), "A blocked host still enabled native navigation")
                view.goBack(nil)
                _ = view.handleHistoryEvent(try swipeEvent(horizontal: 1, time: ProcessInfo.processInfo.systemUptime,
                                                           x: 0.46, y: 0.24, in: view))
                try require(try history(in: view).count == before + 2, "A blocked host accepted a command or swipe")
            }
        }

        if CommandLine.arguments.count > 1 {
            let resources = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            for name in ["AppIcon.icns", "AppIcon-blue.icns", "AppIcon-green.icns"] {
                test("macOS decodes and accepts \(name) as the running app icon") {
                    guard let image = NSImage(contentsOf: resources.appendingPathComponent(name)) else {
                        throw Failure(description: "Could not decode \(name)")
                    }
                    try require(image.isValid && !image.representations.isEmpty, "Invalid icon representations")
                    NSApp.applicationIconImage = image
                    try require(NSApp.applicationIconImage?.isValid == true, "The app icon was not applied")
                }
            }
        } else {
            failed += 1; print("FAIL Resources directory argument is required")
        }
        view.stopHistoryMonitoring()
        window.close()
        print("\nMacInterfaceTests: \(passed) passed, \(failed) failed, 0 skipped")
        if failed > 0 { exit(1) }
    }
}
#endif
