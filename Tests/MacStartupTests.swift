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
    private static func wait(_ condition: () -> Bool, seconds: TimeInterval = 15) throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        try require(condition(), "Timed out waiting for the painted startup document")
    }
    private static func evaluate(_ script: String, in view: WKWebView) throws -> Any? {
        var result: Result<Any?, Error>?
        view.evaluateJavaScript(script) { value, error in
            result = error.map { .failure($0) } ?? .success(value)
        }
        try wait { result != nil }
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
        try wait { result != nil }
        return try result!.get()
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

    private static func fixture(theme: String, resources: URL) -> (RcloneBrowserWindow, RcloneWebView, RBNStartupSurface, Host) {
        let host = Host()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(host, name: "rclone")
        let view = RcloneWebView(frame: .zero, configuration: config)
        let appearance = RBNWebAppearance(theme: theme)
        NSApp.appearance = NSAppearance(named: appearance.isDark ? .darkAqua : .aqua)
        view.pageZoom = RBNInterfaceScale.zoom(100)
        view.prepareForInitialLoad(appearance)
        let family = theme.components(separatedBy: "-").first!
        let name = family == "purple" ? "AppIcon.icns" : "AppIcon-\(family).icns"
        let surface = RBNStartupSurface(browserView: view, appearance: appearance,
            icon: NSImage(contentsOf: resources.appendingPathComponent(name)), message: "Starting…")
        let window = RcloneBrowserWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = appearance.backgroundColor
        window.contentView = surface
        window.browserView = view
        host.surface = surface
        view.navigationDelegate = host
        window.orderFront(nil)
        return (window, view, surface, host)
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
                let appearance = RBNWebAppearance(theme: theme)
                try require(surface.isCoverVisible && !view.isHidden, "WebKit must render under an opaque cover")
                try require(view.frame == surface.bounds && view.bounds.width == 1060 && view.bounds.height == 680,
                            "The zero-frame WebKit view did not fill its native container")
                try require(RBNStartupSurface.hasPaintedCanvas(try nativeCanvas(surface), appearance: appearance),
                            "The pre-document native canvas flashed a different color")
                view.loadFileURL(web.appendingPathComponent("index.html"), allowingReadAccessTo: web)
                try wait { host.error != nil || (!surface.isCoverVisible && host.bootstrapRequests > 0) }
                if let error = host.error { throw error }
                try require(host.loaded, "The packaged document did not finish loading")
                let family = theme.components(separatedBy: "-").first!
                let expectedIcon = family == "purple" ? "favicon.svg" : "favicon-\(family).svg"
                try require(try evaluate("document.documentElement.dataset.theme === '\(theme)' && document.querySelector('.startup .app-mark')?.getAttribute('src') === '\(expectedIcon)' && !!document.querySelector('.loading-status')", in: view) as? Bool == true,
                            "The actual React loading screen lost its saved theme or icon")
                try require(RBNStartupSurface.hasPaintedCanvas(try snapshot(view), appearance: appearance),
                            "The revealed WebKit canvas has the wrong pixels")
            }
        }

        for theme in ["blue-dark", "green-light"] {
        test("\(theme): a finished but still-white WebKit document stays covered until its themed frame exists") {
            let (window, view, surface, host) = fixture(theme: theme, resources: resources)
            defer { close(window, view: view) }
            let appearance = RBNWebAppearance(theme: theme)
            view.loadHTMLString("<!doctype html><html><head><style>html,body{margin:0;background:#fff}</style></head><body><div id='root'><p>Waiting for the compositor</p></div></body></html>", baseURL: nil)
            try wait { host.loaded || host.error != nil }
            if let error = host.error { throw error }
            try require(!RBNStartupSurface.hasPaintedCanvas(try snapshot(view), appearance: appearance), "Fixture is not actually white")
            try require(surface.isCoverVisible, "didFinish exposed the deliberately white page")
            try require(RBNStartupSurface.hasPaintedCanvas(try nativeCanvas(surface), appearance: appearance), "The white page leaked through the native cover")
            let canvas = appearance.isDark ? "#1c1c1c" : "#f1f1f1"
            _ = try evaluate("document.querySelector('style').textContent='html,body{margin:0;background:\(canvas)}'", in: view)
            try wait { !surface.isCoverVisible || host.error != nil }
            if let error = host.error { throw error }
            try require(RBNStartupSurface.hasPaintedCanvas(try snapshot(view), appearance: appearance), "The cover was removed before the themed frame")
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
