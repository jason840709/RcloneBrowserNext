#if os(macOS)
import Foundation
@preconcurrency import AppKit
@preconcurrency import WebKit

/// Finder supplies file URLs directly to the native host. Dropping only prepares
/// a selection in the interface; the usual transfer confirmation remains separate.
final class RcloneWebView: WKWebView {
    var acceptsFileDrop: (() -> Bool)?
    var onFileDrop: (([URL], CGPoint) -> Void)?

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dropOperation(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dropOperation(sender) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !dropOperation(sender).isEmpty }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard !dropOperation(sender).isEmpty,
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        let location = convert(sender.draggingLocation, from: nil)
        let point = CGPoint(x: location.x, y: isFlipped ? location.y : bounds.height - location.y)
        onFileDrop?(urls, point)
        return true
    }

    private func dropOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsFileDrop?() == true, sender.draggingSourceOperationMask.contains(.copy),
              sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) else { return [] }
        return .copy
    }
}
#endif
