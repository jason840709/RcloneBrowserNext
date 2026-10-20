#if os(macOS)
import Foundation
@preconcurrency import AppKit
@preconcurrency import WebKit

/// Exercises the actual macOS WebKit viewport, rather than simulating zoom in
/// CSS. The same point conversion is used by Finder drops and mouse side keys.
@main @MainActor struct MacInterfaceTests {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private final class Loader: NSObject, WKNavigationDelegate {
        var loaded = false
        var failure: Error?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }
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

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = RcloneWebView(frame: NSRect(x: 0, y: 0, width: 1060, height: 680), configuration: configuration)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        let loader = Loader()
        view.navigationDelegate = loader
        view.loadHTMLString("""
        <!doctype html><meta charset="utf-8"><style>
        html,body{margin:0;width:100%;height:100%;overflow:hidden}
        body{display:grid;grid-template-columns:1fr 1fr}
        section{display:grid;grid-template-rows:1fr 1fr}
        #left{background:#292a2d}#right{background:#38393d}
        </style><section id="left"><div id="left-top"></div><div id="left-bottom"></div></section>
        <section id="right"><div id="right-top"></div><div id="right-bottom"></div></section>
        """, baseURL: nil)

        test("Bundled-style interface loads in macOS WebKit") {
            try wait(until: { loader.loaded || loader.failure != nil }, seconds: 20)
            if let error = loader.failure { throw error }
            try require(loader.loaded, "The document did not load")
        }
        if loader.loaded {
            for scale in [80, 90, 100, 110, 125] {
                test("\(scale)% zoom changes the viewport and preserves native pane hit testing") {
                    view.pageZoom = CGFloat(scale) / 100
                    // evaluateJavaScript crosses the WebKit process boundary;
                    // force layout before reading the actual viewport size.
                    guard let viewport = try evaluate("[document.documentElement.clientWidth, document.documentElement.clientHeight]", in: view) as? [NSNumber], viewport.count == 2 else {
                        throw Failure(description: "Missing viewport dimensions")
                    }
                    let expectedWidth = view.bounds.width / view.pageZoom
                    let expectedHeight = view.bounds.height / view.pageZoom
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
