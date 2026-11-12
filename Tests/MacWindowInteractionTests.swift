#if os(macOS)
import Foundation
@preconcurrency import AppKit

@main @MainActor struct MacWindowInteractionTests {
    private struct Failure: Error { let message: String }
    private static var passed = 0, failed = 0
    private final class ZoomDelegate: NSObject, NSWindowDelegate {
        func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame: NSRect) -> NSRect {
            RBNTitlebarInteraction.standardFrame(for: window, fallback: defaultFrame)
        }
    }
    private final class ToolbarDelegate: NSObject, NSToolbarDelegate {
        let identifier = NSToolbarItem.Identifier("test-padding")
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [identifier, .flexibleSpace] }
        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [identifier, .flexibleSpace] }
        func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                     willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
            guard itemIdentifier == identifier else { return nil }
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = content
            return item
        }
    }
    private final class Fixture {
        let window: RcloneBrowserWindow
        let delegate = ZoomDelegate()
        init() {
            window = RcloneBrowserWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 420),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.delegate = delegate
            window.center(); window.makeKeyAndOrderFront(nil)
            NSApp.updateWindows()
        }
        func close() { window.orderOut(nil); window.close() }
    }
    private static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }
    private static func approximately(_ a: NSRect, _ b: NSRect) -> Bool {
        abs(a.minX-b.minX) < 1 && abs(a.minY-b.minY) < 1 && abs(a.width-b.width) < 1 && abs(a.height-b.height) < 1
    }
    private static func waitForFrame(_ expected: NSRect, window: NSWindow) throws {
        let until = Date().addingTimeInterval(2)
        while !approximately(window.frame, expected) && Date() < until {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
            NSApp.updateWindows()
        }
        try require(approximately(window.frame, expected), "Unexpected window frame: \(window.frame), expected \(expected)")
    }
    private static func point(in window: NSWindow) -> NSPoint {
        NSPoint(x: window.frame.width * 0.55, y: (window.contentLayoutRect.maxY + window.frame.height) / 2)
    }
    private static func event(_ window: NSWindow, clicks: Int = 2, at position: NSPoint? = nil,
                              type: NSEvent.EventType = .leftMouseDown) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: position ?? point(in: window), modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 1, clickCount: clicks, pressure: 1)!
    }
    private static func test(_ name: String, _ body: () throws -> Void) {
        do { try body(); passed += 1; print("PASS \(name)") }
        catch { failed += 1; print("FAIL \(name): \(error)") }
        fflush(stdout)
    }
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching(); app.activate(ignoringOtherApps: true)
        test("Titlebar double-click fills the usable screen and restores the original frame") {
            let fixture = Fixture(); defer { fixture.close() }
            let window = fixture.window, original = window.frame
            let target = window.screen!.visibleFrame
            try require(RBNTitlebarInteraction.handle(event(window), in: window), "Blank titlebar double-click was not handled")
            try waitForFrame(target, window: window)
            try require(!window.styleMask.contains(.fullScreen), "Zoom unexpectedly entered a separate full-screen space")
            try require(RBNTitlebarInteraction.handle(event(window), in: window), "Second double-click was not handled")
            try waitForFrame(original, window: window)
        }
        test("Single clicks and clicks inside the document remain available to dragging and file controls") {
            let fixture = Fixture(); defer { fixture.close() }
            let window = fixture.window, original = window.frame
            try require(!RBNTitlebarInteraction.handle(event(window, clicks: 1), in: window), "Single click was consumed")
            try require(!RBNTitlebarInteraction.handle(event(window, at: NSPoint(x: 300, y: 200)), in: window), "Document double-click was consumed")
            try require(!RBNTitlebarInteraction.handle(event(window, type: .rightMouseDown), in: window), "Right click was consumed")
            try require(approximately(window.frame, original), "A non-titlebar action resized the window")
        }
        test("The browser window routes titlebar double-clicks through zoom and restore") {
            let fixture = Fixture(); defer { fixture.close() }
            let window = fixture.window, original = window.frame
            window.sendEvent(event(window))
            try waitForFrame(window.screen!.visibleFrame, window: window)
            window.sendEvent(event(window))
            try waitForFrame(original, window: window)
        }
        test("Titlebar buttons keep their own double-click behavior") {
            let fixture = Fixture(); defer { fixture.close() }
            let window = fixture.window, original = window.frame
            let root = window.contentView!.superview!
            let position = point(in: window)
            let button = NSButton(frame: NSRect(x: position.x-30, y: position.y-8, width: 60, height: 16))
            root.addSubview(button, positioned: .above, relativeTo: nil)
            try require(!RBNTitlebarInteraction.handle(event(window, at: position), in: window), "Button double-click zoomed the window")
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                let systemButton = window.standardWindowButton(kind)!
                let rect = systemButton.convert(systemButton.bounds, to: nil)
                try require(!RBNTitlebarInteraction.handle(event(window, at: NSPoint(x: rect.midX, y: rect.midY)), in: window), "System window button was intercepted")
            }
            try require(approximately(window.frame, original), "A titlebar button resized the window")
        }
        test("A modal disables titlebar zoom without changing the window") {
            let fixture = Fixture(); defer { fixture.close() }
            let original = fixture.window.frame
            try require(!RBNTitlebarInteraction.handle(event(fixture.window), in: fixture.window, enabled: false), "A blocked titlebar action was consumed")
            try require(approximately(fixture.window.frame, original), "A blocked action resized the window")
        }
        test("Padding inside a custom toolbar group belongs to that group") {
            let fixture = Fixture(); defer { fixture.close() }
            let window = fixture.window, delegate = ToolbarDelegate()
            let toolbar = NSToolbar(identifier: "test-titlebar")
            toolbar.delegate = delegate; toolbar.displayMode = .iconOnly
            window.toolbar = toolbar
            window.displayIfNeeded(); NSApp.updateWindows()
            let rect = delegate.content.convert(delegate.content.bounds, to: nil)
            let position = NSPoint(x: rect.midX, y: rect.midY)
            try require(delegate.content.window === window && position.y > window.contentLayoutRect.maxY,
                        "The custom toolbar fixture was not in the titlebar")
            try require(!RBNTitlebarInteraction.handle(event(window, at: position), in: window),
                        "Padding inside a custom toolbar item zoomed the window")
        }
        print("RESULT \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
#endif
