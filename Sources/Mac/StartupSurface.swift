#if os(macOS)
import Foundation
@preconcurrency import AppKit
@preconcurrency import WebKit

/// The native cover and the HTML loading page use these exact raster files.
/// ICNS selects optical profiles by representation size, so it is deliberately
/// reserved for the Dock rather than used for one side of the loading handoff.
enum RBNStartupArtwork {
    static func filename(theme: String) -> String {
        let family = theme.hasPrefix("blue-") ? "blue" : theme.hasPrefix("green-") ? "green" : "purple"
        return "startup-\(family).png"
    }

    static func image(resources: URL, theme: String) -> NSImage? {
        NSImage(contentsOf: resources.appendingPathComponent("Web", isDirectory: true)
            .appendingPathComponent(filename(theme: theme)))
    }
}

/// Keep an opaque, native loading view in front of WebKit while its first
/// document is being painted. didFinish alone is not a presentation barrier.
final class RBNStartupSurface: NSView {
    let browserView: RcloneWebView
    private let cover: RBNStartupCover
    private var webAppearance: RBNWebAppearance
    private var generation = 0
    private var revealWatchdog: DispatchWorkItem?
    private(set) var isCoverVisible = true
    var onLoadTimeout: (() -> Void)?
    var onRetry: (() -> Void)? {
        didSet { cover.onRetry = onRetry }
    }

    init(browserView: RcloneWebView, appearance: RBNWebAppearance,
         icon: NSImage?, message: String) {
        self.browserView = browserView
        self.webAppearance = appearance
        cover = RBNStartupCover(appearance: appearance, icon: icon, message: message,
                                zoom: browserView.pageZoom)
        super.init(frame: browserView.frame)
        wantsLayer = true
        layer?.backgroundColor = appearance.backgroundColor.cgColor
        browserView.frame = bounds
        browserView.autoresizingMask = [.width, .height]
        cover.frame = bounds
        cover.autoresizingMask = [.width, .height]
        addSubview(browserView)
        addSubview(cover, positioned: .above, relativeTo: browserView)
        // Hidden WebKit views can postpone drawing until they are revealed.
        // Let this one render at full opacity underneath the native cover.
        browserView.isHidden = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        webAppearance.backgroundColor.setFill()
        dirtyRect.fill()
    }

    func applyAppearance(_ appearance: RBNWebAppearance, icon: NSImage?) {
        self.webAppearance = appearance
        layer?.backgroundColor = appearance.backgroundColor.cgColor
        cover.applyAppearance(appearance, icon: icon)
        needsDisplay = true
    }

    func applyZoom(_ zoom: CGFloat) {
        cover.applyZoom(zoom)
    }

    func beginLoading(message: String) {
        revealWatchdog?.cancel()
        generation += 1
        let token = generation
        isCoverVisible = true
        cover.isHidden = false
        cover.setMessage(message, retryTitle: nil)
        browserView.isHidden = false
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self = self, self.generation == token, self.isCoverVisible else { return }
            self.generation += 1
            self.onLoadTimeout?()
        }
        revealWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: watchdog)
    }

    func showFailure(_ message: String, retryTitle: String) {
        revealWatchdog?.cancel()
        generation += 1
        isCoverVisible = true
        cover.isHidden = false
        cover.setMessage(message, retryTitle: retryTitle)
    }

    /// A rendered document and a snapshot of its actual pixels must both be
    /// ready before the cover is removed. No timer exposes an unpainted view.
    func revealWhenReady(onFailure: @escaping (Error) -> Void) {
        generation += 1
        let token = generation
        let deadline = Date().addingTimeInterval(20)
        revealWatchdog?.cancel()
        let watchdog = DispatchWorkItem { [weak self] in
            self?.failReveal(token: token, onFailure: onFailure)
        }
        revealWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: watchdog)
        checkDocument(token: token, deadline: deadline, onFailure: onFailure)
    }

    private func checkDocument(token: Int, deadline: Date,
                               onFailure: @escaping (Error) -> Void) {
        guard token == generation, isCoverVisible else { return }
        guard Date() < deadline else {
            failReveal(token: token, onFailure: onFailure)
            return
        }
        let script = """
        const root = document.getElementById('root');
        const mark = root?.querySelector('.startup .app-mark');
        if (mark && (!mark.complete || mark.naturalWidth === 0)) return false;
        if (mark) { try { await mark.decode(); } catch { return false; } }
        await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
        return document.readyState !== 'loading' &&
          (root ? root.childElementCount > 0 : document.body.childElementCount > 0);
        """
        browserView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self = self, self.generation == token else { return }
            guard case .success(let value) = result, value as? Bool == true,
                  self.browserView.bounds.width > 0, self.browserView.bounds.height > 0 else {
                self.retry(token: token, deadline: deadline, onFailure: onFailure)
                return
            }
            let configuration = WKSnapshotConfiguration()
            configuration.rect = self.browserView.bounds
            configuration.snapshotWidth = 128
            configuration.afterScreenUpdates = true
            self.browserView.takeSnapshot(with: configuration) { [weak self] image, _ in
                guard let self = self, self.generation == token else { return }
                guard let image = image, Self.hasPaintedCanvas(image, appearance: self.webAppearance) else {
                    self.retry(token: token, deadline: deadline, onFailure: onFailure)
                    return
                }
                // Keep the handoff in one main-thread update; the live WebKit
                // layer underneath has already drawn the expected canvas.
                self.cover.isHidden = true
                self.isCoverVisible = false
                self.revealWatchdog?.cancel()
            }
        }
    }

    private func retry(token: Int, deadline: Date, onFailure: @escaping (Error) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
            self?.checkDocument(token: token, deadline: deadline, onFailure: onFailure)
        }
    }

    private func failReveal(token: Int, onFailure: @escaping (Error) -> Void) {
        guard token == generation, isCoverVisible else { return }
        generation += 1
        revealWatchdog?.cancel()
        onFailure(NSError(domain: "RcloneBrowserNext.Startup", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The interface did not finish drawing."]))
    }

    static func hasPaintedCanvas(_ image: NSImage, appearance: RBNWebAppearance) -> Bool {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let color = NSBitmapImageRep(cgImage: cgImage).colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB) else { return false }
        // The top-left pixel is the loading canvas or the main toolbar. Their
        // colors differ slightly; accept either without accepting WebKit's
        // default white frame, including when the selected theme is light.
        let expected = appearance.backgroundColor.usingColorSpace(.sRGB)!
        let toolbar: CGFloat = appearance.isDark ? 41.0 / 255 : 233.0 / 255
        guard color.alphaComponent > 0.95 else { return false }
        func matches(_ component: CGFloat) -> Bool {
            let redDifference: CGFloat = abs(color.redComponent - component)
            let greenDifference: CGFloat = abs(color.greenComponent - component)
            let blueDifference: CGFloat = abs(color.blueComponent - component)
            let tolerance: CGFloat = 0.025
            return redDifference < tolerance && greenDifference < tolerance && blueDifference < tolerance
        }
        return matches(expected.redComponent) || matches(toolbar)
    }
}

private final class RBNStartupCover: NSView {
    private let mark = NSImageView()
    private let title = NSTextField(labelWithString: "Rclone Browser Next")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let retryButton = NSButton(title: "", target: nil, action: nil)
    private var canvas: NSColor
    private var zoom: CGFloat = 1
    var onRetry: (() -> Void)?

    init(appearance: RBNWebAppearance, icon: NSImage?, message: String, zoom: CGFloat) {
        canvas = appearance.backgroundColor
        super.init(frame: .zero)
        wantsLayer = true
        mark.imageScaling = .scaleProportionallyUpOrDown
        mark.identifier = NSUserInterfaceItemIdentifier("startup-mark")
        title.identifier = NSUserInterfaceItemIdentifier("startup-title")
        status.identifier = NSUserInterfaceItemIdentifier("startup-status")
        title.alignment = .center
        status.alignment = .center
        title.cell = RBNStartupTextFieldCell(textCell: title.stringValue)
        status.cell = RBNStartupTextFieldCell(textCell: status.stringValue)
        for label in [title, status] {
            label.isEditable = false
            label.isSelectable = false
            label.isBordered = false
            label.drawsBackground = false
            label.alignment = .center
        }
        title.lineBreakMode = .byClipping
        title.cell?.usesSingleLineMode = true
        status.lineBreakMode = .byWordWrapping
        status.cell?.wraps = true
        status.cell?.isScrollable = false
        status.maximumNumberOfLines = 0
        retryButton.bezelStyle = .rounded
        retryButton.target = self
        retryButton.action = #selector(retry)
        for child in [mark, title, status, retryButton] as [NSView] { addSubview(child) }
        applyZoom(zoom)
        applyAppearance(appearance, icon: icon)
        setMessage(message, retryTitle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) { canvas.setFill(); dirtyRect.fill() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // Match .startup in the bundled CSS: 64 + 20 + 29 + 20 + 23 =
        // 156 CSS px, centered in the viewport. Native points must include
        // pageZoom, including migrated 120%/135% interface preferences.
        let gap = 20 * zoom
        let width = max(0, min(580 * zoom, bounds.width - 70 * zoom))
        let titleHeight = 29 * zoom
        var statusHeight = 23 * zoom
        if !retryButton.isHidden {
            let textHeight = (status.stringValue as NSString).boundingRect(
                with: NSSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin], attributes: [.font: status.font!]).height
            statusHeight = max(statusHeight, ceil(textHeight + 4 * zoom))
        }
        let buttonSize = retryButton.isHidden ? NSSize.zero : retryButton.fittingSize
        let totalHeight = 64 * zoom + gap + titleHeight + gap + statusHeight
            + (retryButton.isHidden ? 0 : gap + buttonSize.height)
        let top = (bounds.height - totalHeight) / 2
        mark.frame = NSRect(x: (bounds.width - 64 * zoom) / 2, y: top,
                            width: 64 * zoom, height: 64 * zoom)
        title.frame = NSRect(x: (bounds.width - width) / 2, y: mark.frame.maxY + gap,
                             width: width, height: titleHeight)
        status.frame = NSRect(x: (bounds.width - width) / 2, y: title.frame.maxY + gap,
                              width: width, height: statusHeight)
        retryButton.frame = NSRect(x: (bounds.width - buttonSize.width) / 2,
                                   y: status.frame.maxY + gap, width: buttonSize.width, height: buttonSize.height)
    }

    func applyZoom(_ value: CGFloat) {
        zoom = value.isFinite && value > 0 ? value : 1
        title.font = .systemFont(ofSize: 22 * zoom, weight: .medium)
        status.font = .systemFont(ofSize: 14 * zoom)
        needsLayout = true
    }

    func applyAppearance(_ appearance: RBNWebAppearance, icon: NSImage?) {
        canvas = appearance.backgroundColor
        layer?.backgroundColor = canvas.cgColor
        self.appearance = NSAppearance(named: appearance.isDark ? .darkAqua : .aqua)
        mark.image = icon
        func gray(_ component: CGFloat) -> NSColor {
            NSColor(srgbRed: component / 255, green: component / 255, blue: component / 255, alpha: 1)
        }
        title.textColor = gray(appearance.isDark ? 240 : 37)
        status.textColor = gray(appearance.isDark ? 192 : 87)
        needsDisplay = true
    }

    func setMessage(_ message: String, retryTitle: String?) {
        status.stringValue = message
        retryButton.isHidden = retryTitle == nil
        retryButton.title = retryTitle ?? ""
        needsLayout = true
    }

    @objc private func retry() { onRetry?() }
}

/// AppKit's natural label height is not the HTML line box. Center the glyphs
/// inside the explicit 29/23 px rows instead of inheriting NSTextField padding.
private final class RBNStartupTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var drawing = super.drawingRect(forBounds: rect)
        let naturalHeight = ceil(attributedStringValue.boundingRect(
            with: NSSize(width: drawing.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]).height)
        if drawing.height > naturalHeight {
            drawing.origin.y += (drawing.height - naturalHeight) / 2
            drawing.size.height = naturalHeight
        }
        return drawing
    }
}
#endif
