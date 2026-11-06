#if os(macOS)
import Foundation
@preconcurrency import AppKit
import QuartzCore

/// Shared motion values for native chrome. They match the web tokens in
/// WebSource/renderer/styles/tokens.css (--ease-glide, --d-glide, --d-scrim-in,
/// --d-scrim-out) so the toolbar and the page move as one surface.
enum RBNMotion {
    static let glide = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
    static let glideDuration: CFTimeInterval = 0.28
    static let scrimIn: CFTimeInterval = 0.22
    static let scrimOut: CFTimeInterval = 0.16
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// The accent families of the web themes, for the few native places that use
/// colour: the selected page icon and the active-transfer count.
enum RBNAccent {
    static func text(_ family: String) -> NSColor {
        let (light, dark): (UInt32, UInt32)
        switch family {
        case "green": (light, dark) = (0x3C604A, 0xAAC6B4)
        case "blue": (light, dark) = (0x3F5878, 0xACC0D9)
        default: (light, dark) = (0x5E4E72, 0xC4B7D4)
        }
        return NSColor(name: nil) { appearance in
            hex(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        }
    }
    private static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

/// The window's native toolbar. The web interface owns the state; it mirrors
/// the current page, active transfer count and which save actions are allowed
/// through the `setChrome` bridge call, and the toolbar sends user actions back
/// as ordinary menu actions. While a web dialog is open the toolbar is covered
/// by the same scrim as the page instead of being disabled, so nothing in the
/// chrome blinks when a sheet opens or closes.
final class RBNMainToolbar: NSObject, NSToolbarDelegate, NSMenuItemValidation, NSToolbarItemValidation {
    struct State: Equatable {
        var loaded = false
        var page = "files"
        var activeJobs = 0
        var ready = false
        var canRememberWorkspace = false
        var canSaveTask = false
        var modalOpen = false

        init() {}
        /// Parses the renderer's ChromeState. Unknown pages fall back to files.
        init(json: [String: Any]) {
            loaded = true
            let requested = json["page"] as? String ?? "files"
            page = ["files", "jobs", "tasks"].contains(requested) ? requested : "files"
            activeJobs = max(0, min(9999, (json["activeJobs"] as? NSNumber)?.intValue ?? 0))
            ready = json["ready"] as? Bool ?? false
            canRememberWorkspace = json["canRememberWorkspace"] as? Bool ?? false
            canSaveTask = json["canSaveTask"] as? Bool ?? false
            modalOpen = json["modalOpen"] as? Bool ?? false
        }
    }

    private enum ID {
        static let pages = NSToolbarItem.Identifier("rbn.pages")
        static let account = NSToolbarItem.Identifier("rbn.account")
        static let save = NSToolbarItem.Identifier("rbn.save")
        static let settings = NSToolbarItem.Identifier("rbn.settings")
    }
    private static let pageKeys = ["files", "jobs", "tasks"]

    let toolbar = NSToolbar(identifier: "RcloneBrowserNext.Main")
    let pages = RBNPageSwitcher(symbols: ["folder", "arrow.up.arrow.down", "bookmark"])
    let scrim = RBNTitlebarScrim()
    private var items: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private var rememberItem: NSMenuItem?
    private var saveTaskItem: NSMenuItem?
    private(set) var state = State()
    private let localize: (String, String, String) -> String
    /// Called with "page:<key>", "configureRemotes", "rememberWorkspace", "saveTask", "settings" or "dismissModal".
    var onAction: ((String) -> Void)?

    init(localize: @escaping (String, String, String) -> String) {
        self.localize = localize
        super.init()
        pages.onSelect = { [weak self] index in
            guard let self = self, index < Self.pageKeys.count else { return }
            // The thumb moves at once; the next setChrome confirms the page.
            self.onAction?("page:" + Self.pageKeys[index])
        }
        scrim.onClick = { [weak self] in self?.onAction?("dismissModal") }
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        if #available(macOS 13.0, *) { toolbar.centeredItemIdentifiers = [ID.pages] }
        relocalize()
        apply(State())
    }

    func install(in window: NSWindow) {
        window.toolbar = toolbar
        if #available(macOS 11.0, *) {
            window.toolbarStyle = .unified
            window.titlebarSeparatorStyle = .none
        }
        scrim.attach(to: window)
    }

    func setAccent(family: String, isDark: Bool) {
        pages.accent = RBNAccent.text(family)
        scrim.isDark = isDark
    }

    func relocalize() {
        pages.setTitles([localize("檔案", "Files", "ファイル"), localize("傳輸", "Transfers", "転送"), localize("作業", "Tasks", "タスク")])
        pages.badgeIndex = 1
        pages.badgeCount = state.activeJobs
        pages.setAccessibilityLabel(localize("主要頁面", "Main pages", "メインページ"))
        if let item = items[ID.pages] { item.label = localize("頁面", "Pages", "ページ") }
        if let item = items[ID.account] {
            item.label = localize("帳號", "Accounts", "アカウント")
            item.toolTip = localize("新增或管理雲端與 NAS 帳號", "Add or manage cloud and NAS accounts", "クラウドと NAS のアカウントを追加・管理")
        }
        if let item = items[ID.save] as? NSMenuToolbarItem {
            item.label = localize("儲存", "Save", "保存")
            item.toolTip = localize("儲存工作區或另存為作業", "Save the workspace or save as a task", "ワークスペースを保存、またはタスクとして保存")
            item.menu = saveMenu()
        }
        if let item = items[ID.settings] {
            item.label = localize("設定", "Settings", "設定")
            item.toolTip = localize("設定（⌘,）", "Settings (⌘,)", "設定（⌘,）")
        }
    }

    func apply(_ next: State) {
        let previous = state
        state = next
        if next.activeJobs != previous.activeJobs { pages.badgeCount = next.activeJobs }
        if let index = Self.pageKeys.firstIndex(of: next.page) { pages.select(index, animated: previous.loaded) }
        // Enabled state follows real availability only. A dialog never
        // disables the chrome; the scrim covers it and dismisses the dialog.
        pages.isEnabled = next.loaded
        items[ID.account]?.isEnabled = next.loaded && next.ready
        items[ID.save]?.isEnabled = next.loaded && next.page == "files" && (next.canRememberWorkspace || next.canSaveTask)
        items[ID.settings]?.isEnabled = next.loaded
        if next.modalOpen != previous.modalOpen || !previous.loaded { scrim.setVisible(next.modalOpen) }
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, ID.pages, .flexibleSpace, ID.account, ID.save, ID.settings]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item: NSToolbarItem
        switch identifier {
        case ID.pages:
            item = NSToolbarItem(itemIdentifier: identifier)
            item.view = pages
            item.visibilityPriority = .high
        case ID.account:
            item = button(identifier, symbol: "cloud", action: #selector(openAccounts))
        case ID.save:
            let menuItem = NSMenuToolbarItem(itemIdentifier: identifier)
            // A pin, not a tray-and-arrow: this keeps the current layout, it downloads nothing.
            menuItem.image = NSImage(systemSymbolName: "pin", accessibilityDescription: nil)
            menuItem.showsIndicator = true
            menuItem.menu = saveMenu()
            item = menuItem
        case ID.settings:
            item = button(identifier, symbol: "gearshape", action: #selector(openSettings))
        default:
            return nil
        }
        // AppKit's periodic validation would otherwise flip items back on and
        // off between our updates; this toolbar sets isEnabled itself.
        item.autovalidates = false
        items[identifier] = item
        relocalize()
        apply(state)
        return item
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { item.isEnabled }

    private func button(_ identifier: NSToolbarItem.Identifier, symbol: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.isBordered = true
        item.target = self
        item.action = action
        return item
    }

    private func saveMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = true
        let remember = NSMenuItem(title: localize("儲存工作區", "Save Workspace", "ワークスペースを保存"),
                                  action: #selector(rememberWorkspace), keyEquivalent: "")
        remember.target = self
        remember.toolTip = localize("下次開啟時還原左右資料夾與傳輸設定，不會自動開始傳輸。",
                                    "Restore both folders and transfer settings next time. Nothing starts automatically.",
                                    "次回起動時に左右のフォルダと転送設定を復元します。自動では開始しません。")
        let task = NSMenuItem(title: localize("儲存為作業…", "Save as Task…", "タスクとして保存…"),
                              action: #selector(saveTask), keyEquivalent: "")
        task.target = self
        task.toolTip = localize("把目前的位置、選取項目與選項存成作業，之後可以再執行。",
                                "Keep the current locations, selection and options as a task you can run again.",
                                "現在の場所、選択項目、オプションをタスクとして保存し、あとで再実行できます。")
        remember.image = NSImage(systemSymbolName: "pin", accessibilityDescription: nil)
        task.image = NSImage(systemSymbolName: "bookmark", accessibilityDescription: nil)
        menu.addItem(remember)
        menu.addItem(task)
        rememberItem = remember; saveTaskItem = task
        return menu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard state.loaded, !state.modalOpen, state.page == "files" else { return false }
        if menuItem === rememberItem { return state.canRememberWorkspace }
        if menuItem === saveTaskItem { return state.canSaveTask }
        return true
    }

    @objc private func openAccounts() { onAction?(state.modalOpen ? "dismissModal" : "configureRemotes") }
    @objc private func openSettings() { onAction?(state.modalOpen ? "dismissModal" : "settings") }
    @objc private func rememberWorkspace() { onAction?("rememberWorkspace") }
    @objc private func saveTask() { onAction?("saveTask") }
}

// MARK: - Page switcher

/// A segmented control whose selection thumb glides between pages, like the
/// web segmented controls (same curve and duration). Selection commits on
/// mouse-down so the thumb answers the click immediately.
final class RBNPageSwitcher: NSView {
    /// Handles clicks, keyboard focus and accessibility; draws nothing itself.
    /// The icon and title are plain subviews so AppKit never re-tints them
    /// (an inactive window would otherwise grey them out or hide them).
    private final class Segment: NSButton {
        let icon = NSImageView()
        let label = NSTextField(labelWithString: "")
        var selectedState = false { didSet { setAccessibilityValue(selectedState) } }
        override func mouseDown(with event: NSEvent) { if isEnabled { sendAction(action, to: target) } }
        override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
        func layoutContent() {
            let text = label.fittingSize
            let width = 16 + 4 + ceil(text.width)
            let x = floor((bounds.width - width) / 2)
            icon.frame = NSRect(x: x, y: floor((bounds.height - 16) / 2), width: 16, height: 16)
            label.frame = NSRect(x: x + 20, y: floor((bounds.height - text.height) / 2), width: ceil(text.width), height: ceil(text.height))
        }
        override func accessibilityRole() -> NSAccessibility.Role? { .radioButton }
        override var mouseDownCanMoveWindow: Bool { false }
    }

    private let symbols: [String]
    private var segments: [Segment] = []
    private let track = CALayer()
    private let thumb = CALayer()
    private var titles: [String] = []
    private var hovered: Int?
    private(set) var selectedIndex = 0
    var onSelect: ((Int) -> Void)?
    var accent: NSColor = .controlAccentColor { didSet { refreshContent(animated: false) } }
    var badgeIndex = 1
    var badgeCount = 0 { didSet { if oldValue != badgeCount { refreshContent(animated: true); invalidateIntrinsicContentSize(); needsLayout = true } } }
    var isEnabled = true { didSet { segments.forEach { $0.isEnabled = isEnabled }; alphaValue = isEnabled ? 1 : 0.5 } }

    private let height: CGFloat = 30
    private let inset: CGFloat = 2
    private let padding: CGFloat = 14

    init(symbols: [String]) {
        self.symbols = symbols
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        wantsLayer = true
        layer?.masksToBounds = false
        track.cornerCurve = .continuous
        thumb.cornerCurve = .continuous
        thumb.shadowOffset = CGSize(width: 0, height: -0.5)
        thumb.shadowRadius = 1.5
        layer?.addSublayer(track)
        layer?.addSublayer(thumb)
        for (index, _) in symbols.enumerated() {
            let segment = Segment(title: "", target: self, action: #selector(choose(_:)))
            segment.tag = index
            segment.isBordered = false
            segment.imagePosition = .noImage
            segment.focusRingType = .default
            (segment.cell as? NSButtonCell)?.highlightsBy = []
            segment.icon.imageScaling = .scaleProportionallyDown
            segment.label.lineBreakMode = .byClipping
            segment.addSubview(segment.icon)
            segment.addSubview(segment.label)
            addSubview(segment)
            segments.append(segment)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        refreshContent(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { false }

    func setTitles(_ next: [String]) {
        titles = next
        for (index, segment) in segments.enumerated() where index < next.count { segment.setAccessibilityLabel(next[index]) }
        refreshContent(animated: false)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func select(_ index: Int, animated: Bool) {
        guard index >= 0, index < segments.count else { return }
        let changed = index != selectedIndex
        selectedIndex = index
        segments.enumerated().forEach { $0.element.selectedState = $0.offset == index }
        if changed { refreshContent(animated: animated); placeThumb(animated: animated) }
    }

    @objc private func choose(_ sender: NSButton) {
        guard isEnabled, sender.tag != selectedIndex else { return }
        select(sender.tag, animated: true)
        onSelect?(sender.tag)
    }

    // MARK: Layout and drawing

    private var segmentWidth: CGFloat {
        let widths = segments.map { $0.label.fittingSize.width + 16 + 4 }
        return ceil((widths.max() ?? 60) + padding * 2)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: segmentWidth * CGFloat(segments.count) + inset * 2, height: height)
    }

    override func layout() {
        super.layout()
        let width = segmentWidth
        CATransaction.begin(); CATransaction.setDisableActions(true)
        track.frame = bounds
        track.cornerRadius = bounds.height / 2
        for (index, segment) in segments.enumerated() {
            segment.frame = NSRect(x: inset + CGFloat(index) * width, y: inset, width: width, height: bounds.height - inset * 2)
            segment.layoutContent()
        }
        CATransaction.commit()
        placeThumb(animated: false)
    }

    private func thumbFrame() -> CGRect {
        let width = segmentWidth
        return CGRect(x: inset + CGFloat(selectedIndex) * width, y: inset, width: width, height: bounds.height - inset * 2)
    }

    private func placeThumb(animated: Bool) {
        let target = thumbFrame()
        thumb.cornerRadius = target.height / 2
        CATransaction.begin()
        if animated && !RBNMotion.reduceMotion {
            // Start from the on-screen position so a quick second click redirects smoothly.
            let from = thumb.presentation()?.position ?? thumb.position
            let animation = CABasicAnimation(keyPath: "position")
            animation.fromValue = NSValue(point: from)
            animation.toValue = NSValue(point: CGPoint(x: target.midX, y: target.midY))
            animation.duration = RBNMotion.glideDuration
            animation.timingFunction = RBNMotion.glide
            CATransaction.setDisableActions(true)
            thumb.bounds = CGRect(origin: .zero, size: target.size)
            thumb.position = CGPoint(x: target.midX, y: target.midY)
            thumb.add(animation, forKey: "glide")
        } else {
            CATransaction.setDisableActions(true)
            thumb.bounds = CGRect(origin: .zero, size: target.size)
            thumb.position = CGPoint(x: target.midX, y: target.midY)
        }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshContent(animated: false)
    }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    private func refreshContent(animated: Bool) {
        let dark = isDark
        CATransaction.begin(); CATransaction.setDisableActions(true)
        track.backgroundColor = (dark ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.05)).cgColor
        thumb.backgroundColor = (dark ? NSColor(white: 1, alpha: 0.15) : NSColor(white: 1, alpha: 1)).cgColor
        thumb.shadowColor = NSColor.black.cgColor
        thumb.shadowOpacity = dark ? 0.35 : 0.14
        CATransaction.commit()
        var accentColor = accent
        effectiveAppearance.performAsCurrentDrawingAppearance { accentColor = self.accent.usingColorSpace(.sRGB) ?? self.accent }
        for (index, segment) in segments.enumerated() {
            let selected = index == selectedIndex
            var foreground: NSColor = selected ? .labelColor : (hovered == index ? .labelColor : .secondaryLabelColor)
            effectiveAppearance.performAsCurrentDrawingAppearance { foreground = foreground.usingColorSpace(.sRGB) ?? foreground }
            let title = NSMutableAttributedString(string: index < titles.count ? titles[index] : "", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: selected ? .medium : .regular), .foregroundColor: foreground])
            if index == badgeIndex && badgeCount > 0 {
                title.append(NSAttributedString(string: "  \(badgeCount)", attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: accentColor]))
            }
            let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: selected ? .semibold : .regular)
            if animated && !RBNMotion.reduceMotion {
                for layer in [segment.icon.layer, segment.label.layer] {
                    let fade = CATransition(); fade.type = .fade; fade.duration = RBNMotion.glideDuration * 0.8
                    layer?.add(fade, forKey: "content")
                }
            }
            segment.label.attributedStringValue = title
            segment.icon.image = NSImage(systemSymbolName: symbols[index], accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
            segment.icon.contentTintColor = selected ? accentColor : foreground
            segment.layoutContent()
        }
    }

    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) { if hovered != nil { hovered = nil; refreshContent(animated: true) } }
    private func updateHover(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = segments.firstIndex { $0.frame.contains(point) }
        if index != hovered { hovered = index; refreshContent(animated: true) }
    }
}

// MARK: - Title bar scrim

/// Dims the toolbar band with the same colour and timing as the web dialog
/// scrim, so an open sheet darkens the whole window evenly. Clicking it asks
/// the page to dismiss the sheet, exactly like clicking the page's backdrop.
/// The traffic-light buttons stay usable.
final class RBNTitlebarScrim: NSView {
    var onClick: (() -> Void)?
    var isDark = false { didSet { updateColor() } }
    private(set) var shown = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.opacity = 0
        isHidden = true
        autoresizingMask = [.width, .minYMargin]
        updateColor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func attach(to window: NSWindow) {
        guard let frameView = window.contentView?.superview else { return }
        frameView.addSubview(self, positioned: .above, relativeTo: nil)
        fit(in: window)
    }

    private func fit(in window: NSWindow) {
        guard let frameView = superview else { return }
        let top = window.contentLayoutRect.maxY
        frame = NSRect(x: 0, y: top, width: frameView.bounds.width, height: max(0, frameView.bounds.height - top))
    }

    private func updateColor() {
        layer?.backgroundColor = NSColor(white: 0, alpha: isDark ? 0.32 : 0.14).cgColor
    }

    func setVisible(_ visible: Bool) {
        guard visible != shown, let layer = layer else { return }
        shown = visible
        if let window = window, let frameView = superview {
            fit(in: window)
            // Stay above any titlebar view AppKit inserted since the last time.
            if frameView.subviews.last !== self { frameView.addSubview(self, positioned: .above, relativeTo: nil) }
        }
        if visible { isHidden = false }
        let target: Float = visible ? 1 : 0
        let from = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in if let self = self, !self.shown { self.isHidden = true } }
        if !RBNMotion.reduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = from
            fade.toValue = target
            fade.duration = visible ? RBNMotion.scrimIn : RBNMotion.scrimOut
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(fade, forKey: "fade")
        }
        CATransaction.setDisableActions(true)
        layer.opacity = target
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard shown, let window = window, let superview = superview else { return nil }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let button = window.standardWindowButton(kind), let parent = button.superview {
                if parent.convert(button.frame, to: superview).insetBy(dx: -4, dy: -4).contains(point) { return nil }
            }
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override var mouseDownCanMoveWindow: Bool { false }
}
#endif
