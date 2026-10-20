#if os(macOS)
import Foundation
@preconcurrency import AppKit
@preconcurrency import WebKit

/// The production React document, native history routes and Core engine run
/// together. Only the input device is a test double; no listing or bridge reply
/// is fabricated. These are not physical MX Master / Logi Options hardware tests.
@main @MainActor struct MacNavigationIntegrationTests {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private enum Side: String, CaseIterable { case left, right }
    private static var passed = 0
    private static var failed = 0

    private final class Host: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let engine: RcloneEngine
        let tools: RcloneTools
        let indexURL: URL
        let queue = DispatchQueue(label: "RcloneBrowser.navigation-integration")
        weak var view: RcloneWebView?
        var loaded = false
        var loadError: Error?
        var errors = [String]()
        var methods = [String]()
        var listedPaths = [String]()
        var listingNames = [String: [String]]()
        var pendingRequests = 0
        var pendingNavigation = 0

        init(engine: RcloneEngine, tools: RcloneTools, indexURL: URL) {
            self.engine = engine; self.tools = tools; self.indexURL = indexURL
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            (webView as? RcloneWebView)?.revealInitialDocument()
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loadError = error }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { loadError = error }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "rclone", message.webView === view, message.frameInfo.isMainFrame,
                  message.frameInfo.request.url?.standardizedFileURL == indexURL,
                  let body = message.body as? [String: Any], let id = body["id"] as? String,
                  let method = body["method"] as? String, let arguments = body["args"] as? [Any] else {
                errors.append("Invalid native bridge request"); return
            }
            methods.append(method); pendingRequests += 1
            let engine = engine, tools = tools
            queue.async {
                // Match AppMain's asynchronous request boundary. Blocking
                // rclone work must never stop WebKit's main-thread run loop.
                precondition(!Thread.isMainThread)
                var reply: [String: Any] = ["id": id]
                var requestError: String?
                do {
                    switch method {
                    case "bootstrap", "list": reply["result"] = try engine.invoke(method, arguments: arguments)
                    case "listToolSessions": reply["result"] = tools.listSessions()
                    default: throw Failure(description: "Unexpected integration request: \(method)")
                    }
                } catch {
                    requestError = String(describing: error)
                    reply["error"] = error.localizedDescription
                }
                let result: Result<String, Error> = Result {
                    String(decoding: try JSONSerialization.data(withJSONObject: reply), as: UTF8.self)
                }
                let completedError = requestError
                let completedNames = (reply["result"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
                DispatchQueue.main.async {
                    if let error = completedError { self.errors.append(error) }
                    if completedError == nil, method == "list",
                       let endpoint = arguments.first as? [String: Any], let path = endpoint["path"] as? String {
                        self.listedPaths.append(path)
                        self.listingNames[path] = completedNames
                    }
                    do {
                        let json = try result.get()
                        guard let view = self.view else { throw Failure(description: "The bridge lost its WebKit view") }
                        view.evaluateJavaScript("window.__rbnReply(\(json))") { _, error in
                            if let error = error { self.errors.append(error.localizedDescription) }
                            self.pendingRequests -= 1
                        }
                    } catch {
                        self.errors.append(String(describing: error)); self.pendingRequests -= 1
                    }
                }
            }
        }

        func navigate(_ direction: String, point: CGPoint, time: TimeInterval, phase: String) {
            let packet: [String: Any] = ["type": "navigateHistory", "data": [
                "direction": direction, "x": point.x, "y": point.y, "eventTime": time, "phase": phase]]
            do {
                let json = String(decoding: try JSONSerialization.data(withJSONObject: packet), as: UTF8.self)
                guard let view = view else { throw Failure(description: "Missing navigation WebKit view") }
                pendingNavigation += 1
                view.evaluateJavaScript("window.__rbnEvent(\(json))") { _, error in
                    if let error = error { self.errors.append(error.localizedDescription) }
                    self.pendingNavigation -= 1
                }
            } catch { errors.append(String(describing: error)) }
        }
    }

    // AppKit exposes no public .swipe factory. Like Chromium's native swipe
    // tests, supply the NSEvent properties and use the real NSWindow route.
    private final class SwipeEvent: NSEvent {
        var horizontal: CGFloat = 0
        var eventTime: TimeInterval = 0
        var eventLocation: CGPoint = .zero
        weak var eventWindow: NSWindow?
        override var type: NSEvent.EventType { .swipe }
        override var deltaX: CGFloat { horizontal }
        override var deltaY: CGFloat { 0 }
        override var phase: NSEvent.Phase { .ended }
        override var timestamp: TimeInterval { eventTime }
        override var locationInWindow: NSPoint { eventLocation }
        override var window: NSWindow? { eventWindow }
        override var windowNumber: Int { eventWindow?.windowNumber ?? 0 }
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }
    private static func pumpAppKit() {
        // A Foundation run loop services IPC and JavaScript callbacks but does
        // not dispatch AppKit's queued window events or update its windows.
        // Exercise the same event/update cycle as NSApplication.run so WebKit
        // can present frames and Virtuoso can receive real ResizeObserver/rAF
        // callbacks. Do not substitute timers for the document's animation API.
        autoreleasepool {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01),
                                           inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            NSApp.updateWindows()
        }
    }
    private static func wait(_ condition: () -> Bool, seconds: TimeInterval = 15) throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline {
            pumpAppKit()
        }
        try require(condition(), "Timed out waiting for native/WebKit integration")
    }
    private static func evaluate(_ script: String, in view: WKWebView) throws -> Any? {
        var result: Result<Any?, Error>?
        view.evaluateJavaScript(script) { value, error in
            result = error.map { .failure($0) } ?? .success(value)
        }
        try wait { result != nil }
        return try result!.get()
    }
    private static func waitForScript(_ script: String, in view: WKWebView, seconds: TimeInterval = 15) throws {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if try evaluate(script, in: view) as? Bool == true { return }
            pumpAppKit()
        } while Date() < deadline
        let state = try? evaluate("""
        JSON.stringify({visibility:document.visibilityState, viewport:[innerWidth,innerHeight],
          panes:[...document.querySelectorAll('[data-testid$="-pane"]')].map(p=>({
            id:p.dataset.testid,path:p.querySelector('.path-form input')?.value,
            busy:p.querySelector('.file-list')?.getAttribute('aria-busy'),
            names:[...p.querySelectorAll('.file-name')].map(x=>x.title),
            footer:p.querySelector('.pane-footer')?.textContent,
            bounds:p.getBoundingClientRect().toJSON(),
            listBounds:p.querySelector('.file-list')?.getBoundingClientRect().toJSON(),
            tableViewport:p.querySelector('[data-viewport-type]')?.getBoundingClientRect().toJSON()})),
          alerts:[...document.querySelectorAll('[role=alert]')].map(x=>x.textContent),
          errors:window.__rbnIntegrationErrors})
        """, in: view)
        let native = "windowVisible=\(view.window?.isVisible ?? false), windowOcclusion=\(view.window?.occlusionState.rawValue ?? 0), viewHidden=\(view.isHidden), viewFrame=\(view.frame)"
        throw Failure(description: "Timed out: \(script); page state: \(String(describing: state)); \(native)")
    }
    private static func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
    }
    private static func pane(_ side: Side) -> String { "document.querySelector('[data-testid=\"\(side.rawValue)-pane\"]')" }
    private static func path(_ side: Side, root: URL, depth: Int) -> URL {
        let base = root.appendingPathComponent(side.rawValue, isDirectory: true)
        if depth == 0 { return base }
        if depth == 1 { return base.appendingPathComponent("One", isDirectory: true) }
        return base.appendingPathComponent("One/Two", isDirectory: true)
    }
    private static func marker(_ side: Side, depth: Int) -> String { "\(side.rawValue)-level-\(depth).txt" }
    private static func expectPath(_ side: Side, depth: Int, root: URL, in view: RcloneWebView, host: Host) throws {
        let expected = path(side, root: root, depth: depth).path
        let row = ".file-name[title=\"\(marker(side, depth: depth))\"]"
        do {
            try waitForScript("(()=>{const p=\(pane(side));return p?.querySelector('.path-form input')?.value===\(try json(expected)) && p.querySelector('.file-list')?.getAttribute('aria-busy')==='false' && !!p.querySelector(\(try json(row)));})()", in: view)
        } catch {
            throw Failure(description: "\(error); Core listing names=\(host.listingNames[expected] ?? []); methods=\(host.methods); pendingRequests=\(host.pendingRequests); bridgeErrors=\(host.errors)")
        }
        try require(host.listedPaths.contains(expected), "Displayed path never came from a successful Core listing: \(expected)")
        try require(host.listingNames[expected]?.contains(marker(side, depth: depth)) == true,
                    "The displayed marker was absent from Core's real listing: \(expected)")
    }
    private static func openFolder(_ name: String, side: Side, in view: RcloneWebView) throws {
        let selector = ".file-name[title=\"\(name)\"]"
        try waitForScript("!!\(pane(side))?.querySelector(\(try json(selector)))", in: view)
        try require(try evaluate("(()=>{const row=\(pane(side)).querySelector(\(try json(selector)))?.closest('tr');if(!row)return false;row.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true}));row.dispatchEvent(new MouseEvent('dblclick',{bubbles:true,cancelable:true}));return true;})()", in: view) as? Bool == true,
                    "Could not double-click \(side.rawValue)/\(name) in the production file table")
    }
    private static func activate(_ side: Side, in view: RcloneWebView) throws {
        _ = try evaluate("document.activeElement?.blur();\(pane(side)).querySelector('.pane-heading').dispatchEvent(new PointerEvent('pointerdown',{bubbles:true}));true", in: view)
        try waitForScript("\(pane(side)).classList.contains('pane-active')", in: view)
    }
    private static func swipe(_ side: Side, forward: Bool = false, time: TimeInterval? = nil, in view: RcloneWebView) throws -> SwipeEvent {
        guard let window = view.window,
              let point = try evaluate("(()=>{const r=\(pane(side)).getBoundingClientRect();return [r.left+35,r.top+45];})()", in: view) as? [NSNumber], point.count == 2 else {
            throw Failure(description: "Could not locate the actual browser pane")
        }
        let x = CGFloat(point[0].doubleValue) * view.pageZoom
        let y = CGFloat(point[1].doubleValue) * view.pageZoom
        let native = CGPoint(x: view.bounds.minX + x, y: view.isFlipped ? view.bounds.minY + y : view.bounds.maxY - y)
        let event = SwipeEvent()
        event.horizontal = forward ? -1 : 1
        event.eventTime = time ?? ProcessInfo.processInfo.systemUptime
        event.eventLocation = view.convert(native, to: nil)
        event.eventWindow = window
        return event
    }
    private static func menuCommand(forward: Bool, in view: RcloneWebView) throws {
        guard let window = view.window else { throw Failure(description: "Missing command window") }
        let menu = NSMenu(title: "Go")
        let item = NSMenuItem(title: forward ? "Forward" : "Back",
                             action: forward ? #selector(RcloneWebView.goForward(_:)) : #selector(RcloneWebView.goBack(_:)),
                             keyEquivalent: forward ? "]" : "[")
        item.target = view; item.keyEquivalentModifierMask = [.command]
        menu.addItem(item)
        guard let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                        context: nil, characters: item.keyEquivalent, charactersIgnoringModifiers: item.keyEquivalent,
                                        isARepeat: false, keyCode: forward ? 30 : 33) else {
            throw Failure(description: "Could not create native Command-[ / Command-] event")
        }
        try require(menu.performKeyEquivalent(with: key), "The native history menu did not accept its keyboard equivalent")
    }
    private static func settle(_ host: Host, in view: RcloneWebView) throws {
        try wait { host.pendingNavigation == 0 && host.pendingRequests == 0 }
        _ = try evaluate("window.__rbnIntegrationSettled=false;requestAnimationFrame(()=>requestAnimationFrame(()=>{window.__rbnIntegrationSettled=true}));true", in: view)
        try waitForScript("window.__rbnIntegrationSettled===true", in: view)
        try wait { host.pendingNavigation == 0 && host.pendingRequests == 0 }
        try require(host.errors.isEmpty, "Native bridge errors: \(host.errors)")
        try require(try evaluate("window.__rbnIntegrationErrors.length===0", in: view) as? Bool == true,
                    "The production document reported a JavaScript error")
    }
    @discardableResult private static func test(_ title: String, _ body: () throws -> Void) -> Bool {
        do { try body(); passed += 1; print("PASS \(title)"); return true }
        catch { failed += 1; print("FAIL \(title): \(error)"); return false }
    }

    private static func run(resources: URL, rclone: URL, work: URL) throws {
        try require(FileManager.default.isExecutableFile(atPath: rclone.path), "A real executable rclone is required")
        let indexURL = resources.appendingPathComponent("Web/index.html").resolvingSymlinksInPath().standardizedFileURL
        try require(FileManager.default.fileExists(atPath: indexURL.path), "Missing production Resources/Web/index.html")
        let root = work.appendingPathComponent("navigation-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for side in Side.allCases {
            for depth in 0...2 {
                let directory = path(side, root: root, depth: depth)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data("\(side.rawValue) fixture level \(depth)\n".utf8).write(to: directory.appendingPathComponent(marker(side, depth: depth)))
            }
        }
        let config = root.appendingPathComponent("rclone.conf")
        try Data().write(to: config)
        let engine = try RcloneEngine(stateDirectory: root.appendingPathComponent("state", isDirectory: true),
                                      defaultRcloneDirectory: root.appendingPathComponent("Tools/rclone", isDirectory: true))
        let tools = try RcloneTools(workDirectory: root.appendingPathComponent("tools-work", isDirectory: true))
        defer { engine.shutdown(); try? tools.shutdown() }
        let host = Host(engine: engine, tools: tools, indexURL: indexURL)
        defer {
            print("Integration fixture: \(root.path)")
            print("Native bridge: \(host.methods.count) real requests; \(host.listedPaths.count) successful local Core listings")
        }
        let settings: [String: Any] = ["rclonePath": rclone.path, "configPath": config.path,
            "language": "en", "theme": "blue-dark", "interfaceScale": 100, "autoCheckUpdates": false,
            "initialLocations": ["left": ["remote": NSNull(), "path": path(.left, root: root, depth: 0).path],
                                 "right": ["remote": NSNull(), "path": path(.right, root: root, depth: 0).path]]]
        var configured: Result<Any, Error>?
        host.queue.async {
            let result = Result { try engine.invoke("saveSettings", arguments: [settings]) }
            DispatchQueue.main.async { configured = result }
        }
        try wait { configured != nil }
        let environment = try configured!.get() as? [String: Any]
        try require(environment?["available"] as? Bool == true, "The pinned rclone could not start: \(String(describing: environment))")

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(host, name: "rclone")
        configuration.userContentController.addUserScript(WKUserScript(source: "window.__rbnIntegrationErrors=[];window.addEventListener('error',e=>window.__rbnIntegrationErrors.push(e.message));window.addEventListener('unhandledrejection',e=>window.__rbnIntegrationErrors.push(String(e.reason)));", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = RcloneWebView(frame: NSRect(x: 0, y: 0, width: 1060, height: 680), configuration: configuration)
        view.pageZoom = RBNInterfaceScale.zoom(100)
        view.prepareForInitialLoad(RBNWebAppearance(theme: "blue-dark"))
        host.view = view; view.navigationDelegate = host
        view.acceptsHistoryNavigation = { host.loaded && view.url?.standardizedFileURL == indexURL }
        view.onHistoryNavigation = { direction, point, time, phase in host.navigate(direction, point: point, time: time, phase: phase) }
        let window = RcloneBrowserWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // The startup cover uses a container in the app. Exercise the explicit
        // browser reference instead of relying on contentView's concrete type.
        let container = NSView(frame: view.frame)
        container.addSubview(view); view.autoresizingMask = [.width, .height]
        window.contentView = container; window.browserView = view
        window.backgroundColor = RBNWebAppearance(theme: "blue-dark").backgroundColor
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer {
            view.stopLoading(); view.stopHistoryMonitoring()
            view.acceptsHistoryNavigation = nil; view.onHistoryNavigation = nil
            configuration.userContentController.removeScriptMessageHandler(forName: "rclone")
            window.close()
        }
        view.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())

        guard test("Production React bootstraps through Core and double-clicks enter real folders in both panes", {
            try wait { host.loaded || host.loadError != nil }
            if let error = host.loadError { throw error }
            try waitForScript("!!document.querySelector('.app-statusbar .status-dot.ready')", in: view)
            for side in Side.allCases {
                try expectPath(side, depth: 0, root: root, in: view, host: host)
                try openFolder("One", side: side, in: view)
                try expectPath(side, depth: 1, root: root, in: view, host: host)
                try openFolder("Two", side: side, in: view)
                try expectPath(side, depth: 2, root: root, in: view, host: host)
            }
            try settle(host, in: view)
            try require(host.methods.contains("bootstrap") && host.methods.contains("listToolSessions"), "The production startup did not use its native APIs")
            try require(!view.canGoBack && !view.canGoForward, "The test accidentally created HTML page history")
        }) else { return }

        test("Ended-only Logi-style swipes change the pointed pane's real path and preserve both forward histories") {
            try activate(.left, in: view)
            let before = host.listedPaths.count
            window.sendEvent(try swipe(.right, in: view))
            try expectPath(.right, depth: 1, root: root, in: view, host: host)
            try expectPath(.left, depth: 2, root: root, in: view, host: host)
            window.sendEvent(try swipe(.left, in: view))
            try expectPath(.left, depth: 1, root: root, in: view, host: host)
            window.sendEvent(try swipe(.right, forward: true, in: view))
            try expectPath(.right, depth: 2, root: root, in: view, host: host)
            window.sendEvent(try swipe(.left, forward: true, in: view))
            try expectPath(.left, depth: 2, root: root, in: view, host: host)
            try settle(host, in: view)
            try require(host.listedPaths.count == before + 4, "A swipe was lost or caused extra Core listings")
        }

        test("Duplicate window/responder delivery navigates once while two rapid swipes visit two actual ancestors") {
            let time = ProcessInfo.processInfo.systemUptime
            let first = try swipe(.left, time: time, in: view)
            let second = try swipe(.left, time: time + 0.01, in: view)
            let before = host.listedPaths.count
            window.sendEvent(first); window.sendEvent(first); view.swipe(with: first)
            window.sendEvent(second)
            try expectPath(.left, depth: 0, root: root, in: view, host: host)
            try expectPath(.right, depth: 2, root: root, in: view, host: host)
            try settle(host, in: view)
            try require(Array(host.listedPaths.dropFirst(before)) == [path(.left, root: root, depth: 1).path, path(.left, root: root, depth: 0).path],
                        "Duplicate/rapid swipe handling did not produce exactly the two ancestor listings")
            window.sendEvent(try swipe(.left, forward: true, in: view))
            try expectPath(.left, depth: 1, root: root, in: view, host: host)
            window.sendEvent(try swipe(.left, forward: true, in: view))
            try expectPath(.left, depth: 2, root: root, in: view, host: host)
        }

        test("Native menu Command-[ / Command-] actions navigate the active pane rather than the HTML page") {
            for side in Side.allCases {
                try activate(side, in: view)
                try menuCommand(forward: false, in: view)
                try expectPath(side, depth: 1, root: root, in: view, host: host)
                try expectPath(side == .left ? .right : .left, depth: 2, root: root, in: view, host: host)
                try menuCommand(forward: true, in: view)
                try expectPath(side, depth: 2, root: root, in: view, host: host)
            }
            try settle(host, in: view)
            try require(view.url?.standardizedFileURL == indexURL && !view.canGoBack, "A folder command navigated the bundled document")
        }

        test("Native history commands preserve path editing while a mouse swipe can still target the other pane") {
            _ = try evaluate("\(pane(.left)).querySelector('.path-form input').focus();true", in: view)
            try waitForScript("document.activeElement===\(pane(.left)).querySelector('.path-form input')", in: view)
            let before = host.listedPaths.count
            try menuCommand(forward: false, in: view)
            try menuCommand(forward: true, in: view)
            try settle(host, in: view)
            try expectPath(.left, depth: 2, root: root, in: view, host: host)
            try require(host.listedPaths.count == before, "A native history command hijacked focused text editing")
            window.sendEvent(try swipe(.right, in: view))
            try expectPath(.right, depth: 1, root: root, in: view, host: host)
            try expectPath(.left, depth: 2, root: root, in: view, host: host)
            window.sendEvent(try swipe(.right, forward: true, in: view))
            try expectPath(.right, depth: 2, root: root, in: view, host: host)
        }

        test("The production operation dialog blocks native swipes and commands until it closes") {
            _ = try evaluate("document.querySelector('.options-button').click();true", in: view)
            try waitForScript("!!document.querySelector('.options-dialog[open]')", in: view)
            let before = host.listedPaths.count
            window.sendEvent(try swipe(.right, in: view))
            try menuCommand(forward: false, in: view)
            try settle(host, in: view)
            try expectPath(.left, depth: 2, root: root, in: view, host: host)
            try expectPath(.right, depth: 2, root: root, in: view, host: host)
            try require(host.listedPaths.count == before, "Navigation escaped the open operation dialog")
            _ = try evaluate("document.querySelector('.options-dialog .dialog-header button').click();true", in: view)
            try waitForScript("!document.querySelector('dialog[open]')", in: view)
            window.sendEvent(try swipe(.right, in: view))
            try expectPath(.right, depth: 1, root: root, in: view, host: host)
            window.sendEvent(try swipe(.right, forward: true, in: view))
            try expectPath(.right, depth: 2, root: root, in: view, host: host)
            try settle(host, in: view)
            try require(Set(host.methods).isSubset(of: ["bootstrap", "list", "listToolSessions"]), "Navigation unexpectedly mutated engine data")
        }
    }

    static func main() {
        guard CommandLine.arguments.count == 4 else {
            print("FAIL Usage: MacNavigationIntegrationTests Resources RcloneExecutable WorkDir"); exit(1)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching(); app.activate(ignoringOtherApps: true)
        do {
            try run(resources: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true),
                    rclone: URL(fileURLWithPath: CommandLine.arguments[2]),
                    work: URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true).resolvingSymlinksInPath().standardizedFileURL)
        } catch { failed += 1; print("FAIL Integration setup: \(error)") }
        print("Mac navigation integration tests: \(passed) passed, \(failed) failed, 0 skipped")
        exit(failed == 0 ? 0 : 1)
    }
}
#endif
