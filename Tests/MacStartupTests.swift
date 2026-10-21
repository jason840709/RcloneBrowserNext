#if os(macOS)
import Foundation
@preconcurrency import AppKit
@preconcurrency import WebKit

/// Uses the actual bundled React document for cold starts. A deliberately
/// white WebKit page separately exercises the native cover's presentation gate.
@main @MainActor struct MacStartupTests {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static var passed = 0
    private static var failed = 0

    private final class Host: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var surface: RBNStartupSurface?
        var loaded = false
        var error: Error?
        var bootstrapRequests = 0
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if (message.body as? [String: Any])?["method"] as? String == "bootstrap" { bootstrapRequests += 1 }
            // Leave configuration loading in progress, as on a cold launch.
            // The test must see the real loading UI rather than a test page.
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            surface?.revealWhenReady { [weak self] error in self?.error = error }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            self.error = error
            surface?.showFailure("Could not load the interface.", retryTitle: "Retry")
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            self.error = error
            surface?.showFailure("Could not load the interface.", retryTitle: "Retry")
        }
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }
    private static func pumpAppKit() {
        // Use the application's event/update cycle, including WindowServer
        // visibility changes. A Foundation-only loop can service JavaScript
        // callbacks while leaving WebKit's presentation/rAF suspended.
        autoreleasepool {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01),
                                           inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            NSApp.updateWindows()
        }
    }
    private static func wait(seconds: TimeInterval = 15, context: String = "WebKit response",
                             _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline {
            pumpAppKit()
        }
        try require(condition(), "Timed out waiting for \(context)")
    }
    private static func evaluate(_ script: String, in view: WKWebView) throws -> Any? {
        var result: Result<Any?, Error>?
        view.evaluateJavaScript(script) { value, error in
            result = error.map { .failure($0) } ?? .success(value)
        }
        try wait(context: "JavaScript evaluation") { result != nil }
        return try result!.get()
    }
    private static func snapshot(_ view: WKWebView) throws -> NSImage {
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = 128
        config.afterScreenUpdates = true
        var result: Result<NSImage, Error>?
        view.takeSnapshot(with: config) { image, error in
            if let image = image { result = .success(image) }
            else { result = .failure(error ?? Failure(description: "WebKit returned no snapshot")) }
        }
        try wait(context: "WebKit snapshot completion") { result != nil }
        return try result!.get()
    }
    private static func waitForPresentation(_ view: WKWebView) throws {
        var finished = false
        var failure: Error?
        view.callAsyncJavaScript("""
        await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
        return true;
        """, arguments: [:], in: nil, in: .page) { result in
            if case .failure(let error) = result { failure = error }
            finished = true
        }
        try wait(context: "updated WebKit viewport presentation") { finished }
        if let failure = failure { throw failure }
    }
    private static func diagnostics(_ view: WKWebView, surface: RBNStartupSurface, host: Host) -> String {
        var page = "No JavaScript diagnostic reply"
        var complete = false
        view.evaluateJavaScript("""
        JSON.stringify({ready:document.readyState,visibility:document.visibilityState,
          theme:document.documentElement.dataset.theme,rootChildren:document.getElementById('root')?.childElementCount,
          frames:window.__rbnStartupTestFrames,viewport:[innerWidth,innerHeight],
          htmlBackground:getComputedStyle(document.documentElement).backgroundColor,
          bodyBackground:document.body&&getComputedStyle(document.body).backgroundColor,
          startupIcon:document.querySelector('.startup .app-mark')?.getAttribute('src'),
          status:document.querySelector('.loading-status')?.textContent})
        """) { value, error in
            page = error.map { String(describing: $0) } ?? String(describing: value)
            complete = true
        }
        try? wait(seconds: 1, context: "failure diagnostics") { complete }
        var pixels = "No snapshot diagnostic reply"
        var sampled = false
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = 128
        // Diagnostics only: inspect the last available frame even if waiting
        // for a new presentation was the operation that timed out.
        config.afterScreenUpdates = false
        view.takeSnapshot(with: config) { image, error in
            if let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
               let color = NSBitmapImageRep(cgImage: cgImage).colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB) {
                pixels = "rgba=\([color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent])"
            } else { pixels = String(describing: error) }
            sampled = true
        }
        try? wait(seconds: 1, context: "failure snapshot diagnostics") { sampled }
        return "loaded=\(host.loaded), bootstrap=\(host.bootstrapRequests), cover=\(surface.isCoverVisible), error=\(String(describing: host.error)), windowVisible=\(view.window?.isVisible ?? false), windowOcclusion=\(view.window?.occlusionState.rawValue ?? 0), frame=\(view.frame), \(pixels), page=\(page)"
    }
    private static func nativeCanvas(_ surface: RBNStartupSurface) throws -> NSImage {
        surface.layoutSubtreeIfNeeded()
        surface.displayIfNeeded()
        guard let bitmap = surface.bitmapImageRepForCachingDisplay(in: surface.bounds) else {
            throw Failure(description: "No native canvas bitmap")
        }
        surface.cacheDisplay(in: surface.bounds, to: bitmap)
        let image = NSImage(size: surface.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }
    private static func test(_ title: String, _ body: () throws -> Void) {
        do { try body(); passed += 1; print("PASS \(title)") }
        catch { failed += 1; print("FAIL \(title): \(error)") }
    }

    private static func fixture(theme: String, resources: URL, scale: Int = 100) -> (RcloneBrowserWindow, RcloneWebView, RBNStartupSurface, Host) {
        let host = Host()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(host, name: "rclone")
        config.userContentController.addUserScript(WKUserScript(source: """
        window.__rbnStartupTestFrames=0;
        requestAnimationFrame(()=>{window.__rbnStartupTestFrames++;requestAnimationFrame(()=>{window.__rbnStartupTestFrames++})});
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let view = RcloneWebView(frame: .zero, configuration: config)
        let appearance = RBNWebAppearance(theme: theme)
        NSApp.appearance = NSAppearance(named: appearance.isDark ? .darkAqua : .aqua)
        view.pageZoom = RBNInterfaceScale.zoom(scale)
        view.prepareForInitialLoad(appearance)
        let surface = RBNStartupSurface(browserView: view, appearance: appearance,
            icon: RBNStartupArtwork.image(resources: resources, theme: theme), message: "Starting…")
        let window = RcloneBrowserWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = appearance.backgroundColor
        window.contentView = surface
        window.browserView = view
        host.surface = surface
        view.navigationDelegate = host
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return (window, view, surface, host)
    }

    private static func find(_ identifier: String, in root: NSView) -> NSView? {
        if root.identifier?.rawValue == identifier { return root }
        for child in root.subviews { if let match = find(identifier, in: child) { return match } }
        return nil
    }

    private static func verifyHandoffGeometry(view: RcloneWebView, surface: RBNStartupSurface,
                                              theme: String, resources: URL) throws {
        surface.layoutSubtreeIfNeeded()
        guard let geometry = try evaluate("""
        (() => {
          const result = {};
          for (const [key,selector] of [['mark','.startup .app-mark'],['title','.startup h1'],['status','.loading-status']]) {
            const node = document.querySelector(selector), rect = node.getBoundingClientRect(), css = getComputedStyle(node);
            result[key] = {x:rect.x,y:rect.y,width:rect.width,height:rect.height,
              fontSize:parseFloat(css.fontSize),lineHeight:parseFloat(css.lineHeight),color:css.color};
          }
          const mark = document.querySelector('.startup .app-mark');
          result.artwork = {source:mark.getAttribute('src'),complete:mark.complete,width:mark.naturalWidth,height:mark.naturalHeight};
          return result;
        })()
        """, in: view) as? [String: Any] else { throw Failure(description: "Missing loading layout") }
        let zoom = view.pageZoom
        for key in ["mark", "title", "status"] {
            guard let native = find("startup-\(key)", in: surface),
                  let web = geometry[key] as? [String: Any] else { throw Failure(description: "Missing \(key)") }
            func number(_ name: String) throws -> CGFloat {
                guard let value = web[name] as? NSNumber else { throw Failure(description: "Missing \(key).\(name)") }
                return CGFloat(value.doubleValue) * zoom
            }
            let converted = surface.convert(native.bounds, from: native)
            let top = surface.bounds.height - converted.maxY
            let webTop = try number("y")
            let webHeight = try number("height")
            let webCenterX = try number("x") + number("width") / 2
            try require(abs(top - webTop) < 1 && abs(converted.height - webHeight) < 1
                && abs(converted.midX - webCenterX) < 1,
                "\(key) jumps at zoom \(zoom): native=\(converted), nativeTop=\(top), web=\(web)")
            if key == "mark" {
                try require(abs(converted.width - number("width")) < 1, "The icon resizes during handoff")
            } else if let label = native as? NSTextField {
                try require(abs((label.font?.pointSize ?? 0) - number("fontSize")) < 0.01,
                            "\(key) uses a different native font size")
                let color = label.textColor!.usingColorSpace(.sRGB)!
                let gray = Int((color.redComponent * 255).rounded())
                try require(web["color"] as? String == "rgb(\(gray), \(gray), \(gray))",
                            "\(key) changes color at handoff")
            }
        }
        guard let mark = find("startup-mark", in: surface) as? NSImageView,
              let actualImage = mark.image,
              let expectedImage = RBNStartupArtwork.image(resources: resources, theme: theme),
              let artwork = geometry["artwork"] as? [String: Any] else {
            throw Failure(description: "Missing shared startup artwork")
        }
        let expectedName = RBNStartupArtwork.filename(theme: theme)
        try require(artwork["source"] as? String == expectedName && artwork["complete"] as? Bool == true
            && (artwork["width"] as? NSNumber)?.intValue == 256 && (artwork["height"] as? NSNumber)?.intValue == 256,
            "The Web startup mark is not the decoded shared raster")
        try require(actualImage.tiffRepresentation == expectedImage.tiffRepresentation,
                    "Native startup uses a different artwork or optical profile")
    }

    private static func close(_ window: RcloneBrowserWindow, view: RcloneWebView) {
        view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "rclone")
        view.stopHistoryMonitoring()
        window.close()
    }

    static func main() {
        guard CommandLine.arguments.count == 2 else { print("FAIL Usage: MacStartupTests Resources"); exit(1) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        app.activate(ignoringOtherApps: true)
        let resources = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let web = resources.appendingPathComponent("Web", isDirectory: true)

        for theme in ["purple-dark", "blue-dark", "green-dark", "purple-light", "blue-light", "green-light"] {
            test("\(theme) cold start covers WebKit until the bundled loading UI is painted") {
                let (window, view, surface, host) = fixture(theme: theme, resources: resources)
                defer { close(window, view: view) }
                var completed = false
                defer { if !completed { print("STARTUP DIAGNOSTIC \(theme): \(diagnostics(view, surface: surface, host: host))") } }
                let appearance = RBNWebAppearance(theme: theme)
                try require(surface.isCoverVisible && !view.isHidden, "WebKit must render under an opaque cover")
                try require(view.frame == surface.bounds && view.bounds.width == 1060 && view.bounds.height == 680,
                            "The zero-frame WebKit view did not fill its native container")
                try require(RBNStartupSurface.hasPaintedCanvas(try nativeCanvas(surface), appearance: appearance),
                            "The pre-document native canvas flashed a different color")
                view.loadFileURL(web.appendingPathComponent("index.html"), allowingReadAccessTo: web)
                // Allow the production 20-second watchdog to explain a failed
                // handoff instead of hiding it behind a shorter test timeout.
                try wait(seconds: 25, context: "bundled loading UI to be painted and revealed") {
                    host.error != nil || (!surface.isCoverVisible && host.bootstrapRequests > 0)
                }
                if let error = host.error { throw error }
                try require(host.loaded, "The packaged document did not finish loading")
                let expectedIcon = RBNStartupArtwork.filename(theme: theme)
                try require(try evaluate("document.documentElement.dataset.theme === '\(theme)' && document.querySelector('.startup .app-mark')?.getAttribute('src') === '\(expectedIcon)' && !!document.querySelector('.loading-status')", in: view) as? Bool == true,
                            "The actual React loading screen lost its saved theme or icon")
                try require(RBNStartupSurface.hasPaintedCanvas(try snapshot(view), appearance: appearance),
                            "The revealed WebKit canvas has the wrong pixels")
                try verifyHandoffGeometry(view: view, surface: surface, theme: theme, resources: resources)
                completed = true
            }
        }

        for scale in [80, 125, 135] {
            test("\(scale)% startup keeps native and Web icon/text positions at the same zoom") {
                let theme = "blue-dark"
                let (window, view, surface, host) = fixture(theme: theme, resources: resources, scale: scale)
                defer { close(window, view: view) }
                view.loadFileURL(web.appendingPathComponent("index.html"), allowingReadAccessTo: web)
                try wait(seconds: 25, context: "scaled startup handoff") {
                    host.error != nil || (!surface.isCoverVisible && host.bootstrapRequests > 0)
                }
                if let error = host.error { throw error }
                try verifyHandoffGeometry(view: view, surface: surface, theme: theme, resources: resources)
                // Preference changes/retries reuse the same native view. Check
                // that an existing cover follows the current WebKit zoom too.
                surface.beginLoading(message: "Starting…")
                view.pageZoom = RBNInterfaceScale.zoom(110)
                surface.applyZoom(view.pageZoom)
                try waitForPresentation(view)
                try verifyHandoffGeometry(view: view, surface: surface, theme: theme, resources: resources)
            }
        }

        for theme in ["blue-dark", "green-light"] {
        test("\(theme): a finished but still-white WebKit document stays covered until its themed frame exists") {
            let (window, view, surface, host) = fixture(theme: theme, resources: resources)
            defer { close(window, view: view) }
            var completed = false
            defer { if !completed { print("STARTUP DIAGNOSTIC white fixture \(theme): \(diagnostics(view, surface: surface, host: host))") } }
            let appearance = RBNWebAppearance(theme: theme)
            view.loadHTMLString("<!doctype html><html><head><style>html,body{margin:0;background:#fff}</style></head><body><div id='root'><p>Waiting for the compositor</p></div></body></html>", baseURL: nil)
            try wait(context: "white fixture didFinish") { host.loaded || host.error != nil }
            if let error = host.error { throw error }
            try require(!RBNStartupSurface.hasPaintedCanvas(try snapshot(view), appearance: appearance), "Fixture is not actually white")
            try require(surface.isCoverVisible, "didFinish exposed the deliberately white page")
            try require(RBNStartupSurface.hasPaintedCanvas(try nativeCanvas(surface), appearance: appearance), "The white page leaked through the native cover")
            let canvas = appearance.isDark ? "#1c1c1c" : "#f1f1f1"
            _ = try evaluate("document.querySelector('style').textContent='html,body{margin:0;background:\(canvas)}'", in: view)
            try wait(seconds: 25, context: "themed fixture to be painted and revealed") { !surface.isCoverVisible || host.error != nil }
            if let error = host.error { throw error }
            try require(RBNStartupSurface.hasPaintedCanvas(try snapshot(view), appearance: appearance), "The cover was removed before the themed frame")
            completed = true
        }
        }

        test("Startup failure retains its themed cover and an operable retry path") {
            let (window, view, surface, _) = fixture(theme: "green-dark", resources: resources)
            defer { close(window, view: view) }
            var retries = 0
            surface.onRetry = { retries += 1; surface.beginLoading(message: "Starting…") }
            surface.showFailure("Could not load the interface.", retryTitle: "Retry")
            func findButton(_ root: NSView) -> NSButton? {
                if let button = root as? NSButton, !button.isHidden { return button }
                for child in root.subviews { if let button = findButton(child) { return button } }
                return nil
            }
            guard let retry = findButton(surface) else { throw Failure(description: "Missing retry button") }
            retry.performClick(nil)
            try require(retries == 1 && surface.isCoverVisible && !view.isHidden, "Retry did not restart behind the cover")
        }

        print("Mac startup tests: \(passed) passed, \(failed) failed, 0 skipped")
        exit(failed == 0 ? 0 : 1)
    }
}
#endif
