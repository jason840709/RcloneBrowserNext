#if os(macOS)
import Foundation
@preconcurrency import AppKit
@preconcurrency import WebKit

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
        cover = RBNStartupCover(appearance: appearance, icon: icon, message: message)
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
        await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
        const root = document.getElementById('root');
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
        return color.alphaComponent > 0.95 && [expected.redComponent, toolbar].contains { component in
            abs(color.redComponent - component) < 0.025 &&
            abs(color.greenComponent - component) < 0.025 &&
            abs(color.blueComponent - component) < 0.025
        }
    }
}

private final class RBNStartupCover: NSView {
    private let mark = NSImageView()
    private let title = NSTextField(labelWithString: "Rclone Browser Next")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let retryButton = NSButton(title: "", target: nil, action: nil)
    private var canvas: NSColor
    var onRetry: (() -> Void)?

    init(appearance: RBNWebAppearance, icon: NSImage?, message: String) {
        canvas = appearance.backgroundColor
        super.init(frame: .zero)
        wantsLayer = true
        mark.imageScaling = .scaleProportionallyUpOrDown
        mark.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 22, weight: .medium)
        status.font = .systemFont(ofSize: 14)
        status.alignment = .center
        retryButton.bezelStyle = .rounded
        retryButton.target = self
        retryButton.action = #selector(retry)
        let stack = NSStackView(views: [mark, title, status, retryButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -70),
            mark.widthAnchor.constraint(equalToConstant: 64),
            mark.heightAnchor.constraint(equalToConstant: 64),
            status.widthAnchor.constraint(lessThanOrEqualToConstant: 580)
        ])
        applyAppearance(appearance, icon: icon)
        setMessage(message, retryTitle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) { canvas.setFill(); dirtyRect.fill() }

    func applyAppearance(_ appearance: RBNWebAppearance, icon: NSImage?) {
        canvas = appearance.backgroundColor
        layer?.backgroundColor = canvas.cgColor
        self.appearance = NSAppearance(named: appearance.isDark ? .darkAqua : .aqua)
        mark.image = icon
        title.textColor = appearance.isDark ? .white : .black
        status.textColor = appearance.isDark ? NSColor(white: 0.68, alpha: 1) : NSColor(white: 0.38, alpha: 1)
        needsDisplay = true
    }

    func setMessage(_ message: String, retryTitle: String?) {
        status.stringValue = message
        retryButton.isHidden = retryTitle == nil
        retryButton.title = retryTitle ?? ""
    }

    @objc private func retry() { onRetry?() }
}
#endif
