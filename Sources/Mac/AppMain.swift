#if os(macOS)
import Foundation
import CoreFoundation
@preconcurrency import AppKit
@preconcurrency import WebKit
@preconcurrency import UserNotifications
import UniformTypeIdentifiers
import Darwin

/// The web view renders bundled interface files. Only this native host can run
/// rclone, show file panels, or approve operations that remove user data.
final class BrowserAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
                                WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var startupSurface: RBNStartupSurface?
    private var startupNavigation: WKNavigation?
    private var engine: RcloneEngine!
    private var updater: RcloneUpdater!
    private var appReleaseChecker: RBNAppReleaseChecker!
    private var toolsManager: RcloneTools!
    private var statusItem: NSStatusItem?
    private var themeIcons = [String: NSImage]()
    private var currentIconFamily: String?
    private var notificationRequested = false
    private let completionAttention = RBNCompletionAttention()
    private var webRoot: URL!
    private var indexURL: URL!
    private var stateDirectory: URL!
    private var temporaryDirectory: URL!
    private let requestQueue = DispatchQueue(label: "org.rclone.browser.next.requests", qos: .userInitiated, attributes: .concurrent)
    private let activityLock = NSRecursiveLock()
    private var updateBusy = false
    private var appUpdateBusy = false
    private var updateInstalling = false
    private var configuringRemotes = false
    private var nativeConnectionChanging = false
    private var auxiliaryOperations = 0
    private var operationStarts = 0
    private var terminalTimer: DispatchSourceTimer?
    private var startupCheckScheduled = false
    private var startupCheckPerformed = false
    private var deferredAutomaticCheck = false
    private var terminationValue = false
    private var terminationStarted: Bool {
        get { activityLock.holding { terminationValue } }
        set { activityLock.holding { terminationValue = newValue } }
    }
    private var pageReady = false
    private var pendingIDs = Set<String>()
    private var queuedEvents = [[String: Any]]()
    private var returnedAccountAuthorizationID: String?

    private let permittedMethods: Set<String> = [
        "bootstrap", "list", "cancelList", "mkdir", "rename", "remove", "size", "chooseFolder", "chooseFile",
        "previewTransfer", "startTransfer", "cancelJob", "retryJob", "listJobs", "clearFinishedJobs", "clearJobs",
        "saveTask", "deleteTask", "listTasks", "saveSettings", "unlockConfig", "configureRemotes", "accountConfig", "openAccountAuthorization",
        "openExternal", "exportLog", "getJobReport", "exportJobReport", "exportTasks", "importTasks", "checkForUpdates", "checkAppUpdates", "showAbout",
        "directoryTree", "exportFileList", "publicLink", "startMount", "startStream",
        "listToolSessions", "stopToolSession", "copyText"
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let fm = FileManager.default
            let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true)
            stateDirectory = support.appendingPathComponent("Rclone Browser Next Lite", isDirectory: true)
            try fm.createDirectory(at: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            temporaryDirectory = stateDirectory.appendingPathComponent("tmp", isDirectory: true)
            try fm.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            setenv("TMPDIR", temporaryDirectory.path + "/", 1)

            let appParent = Bundle.main.bundleURL.deletingLastPathComponent()
            let defaultTools = appParent.appendingPathComponent("Tools/rclone", isDirectory: true)
            engine = try RcloneEngine(stateDirectory: stateDirectory, defaultRcloneDirectory: defaultTools)
            updater = try RcloneUpdater(workDirectory: temporaryDirectory.appendingPathComponent("updates", isDirectory: true))
            toolsManager = try RcloneTools(workDirectory: temporaryDirectory.appendingPathComponent("tools", isDirectory: true))
            toolsManager.onSessionUpdate = { [weak self] session in self?.sendEvent(type: "toolSessionUpdate", data: session) }
            engine.onJobUpdate = { [weak self] job in
                self?.sendEvent(type: "jobUpdate", data: job)
                self?.notifyFinishedJob(job)
            }
            updater.onStatus = { [weak self] status in self?.sendEvent(type: "updateStatus", data: status) }
            updater.connectionSettings = { [weak self] in self?.engine.settingsSnapshot() ?? [:] }
            appReleaseChecker = try RBNAppReleaseChecker(repository: RBNProject.repository)

            guard let resources = Bundle.main.resourceURL else { throw EngineError("App 缺少必要檔案。請重新下載並安裝 Rclone Browser Next。") }
            webRoot = resources.appendingPathComponent("Web", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
            indexURL = webRoot.appendingPathComponent("index.html")
            guard fm.fileExists(atPath: indexURL.path) else { throw EngineError("App 缺少必要檔案。請重新下載並安裝 Rclone Browser Next。") }

            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
            configuration.userContentController.add(self, name: "rclone")
            let browserView = RcloneWebView(frame: .zero, configuration: configuration)
            let initialAppearance = RBNWebAppearance(theme: engine.settingsSnapshot()["theme"] as? String)
            browserView.prepareForInitialLoad(initialAppearance)
            browserView.acceptsHistoryNavigation = { [weak self] in
                guard let self = self else { return false }
                return self.pageReady && self.startupSurface?.isCoverVisible != true && !self.terminationStarted && self.isBundledDocument(self.webView?.url)
            }
            browserView.onHistoryNavigation = { [weak self] direction, point, eventTime, phase in
                self?.sendEvent(type: "navigateHistory", data: ["direction": direction, "x": point.x, "y": point.y,
                                                               "eventTime": eventTime, "phase": phase])
            }
            browserView.acceptsFileDrop = { [weak self] in
                guard let self = self else { return false }
                return !self.terminationStarted && self.isBundledDocument(self.webView?.url)
            }
            browserView.onFileDrop = { [weak self] urls, point in
                self?.requestQueue.async { [weak self] in
                    guard let self = self, !self.terminationStarted else { return }
                    do {
                        let drop = try RBNFinderDrop(urls: urls)
                        self.sendEvent(type: "finderDrop", data: ["source": drop.source.json,
                            "selection": drop.selection.map(\.json), "x": point.x, "y": point.y])
                    } catch { self.presentError(error) }
                }
            }
            webView = browserView
            webView.navigationDelegate = self
            webView.uiDelegate = self
            webView.autoresizingMask = [.width, .height]

            window = RcloneBrowserWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
            window.title = "Rclone Browser Next"
            window.titleVisibility = .hidden
            window.contentMinSize = NSSize(width: 1060, height: 680)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.backgroundColor = initialAppearance.backgroundColor
            let initialIcon = RBNStartupArtwork.image(resources: resources, theme: initialAppearance.theme)
            let surface = RBNStartupSurface(browserView: browserView, appearance: initialAppearance,
                icon: initialIcon, message: local("正在啟動…", "Starting…", "起動中…"))
            surface.onRetry = { [weak self] in
                self?.loadStartupDocument()
            }
            surface.onLoadTimeout = { [weak self] in self?.showStartupTimeout() }
            startupSurface = surface
            window.contentView = surface
            (window as? RcloneBrowserWindow)?.browserView = browserView
            window.center()
            applyAppearance()
            installMenus()
            applyInterfacePreferences()
            loadStartupDocument()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            let alert = NSAlert()
            alert.messageText = local("無法開啟 Rclone Browser Next", "Could not open Rclone Browser Next", "Rclone Browser Next を開けません")
            alert.informativeText = localizedError(error)
            alert.alertStyle = .critical
            alert.addButton(withTitle: local("結束", "Quit", "終了"))
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    private func installMenus() {
        let menuBar = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let about = NSMenuItem(title: local("關於 Rclone Browser Next", "About Rclone Browser Next", "Rclone Browser Next について"), action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        appMenu.addItem(about)
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: local("設定…", "Settings…", "設定…"), action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self; appMenu.addItem(settings)
        let accounts = NSMenuItem(title: local("帳號設定…", "Account setup…", "アカウント設定…"), action: #selector(configureFromMenu), keyEquivalent: "")
        accounts.target = self; appMenu.addItem(accounts)
        let languageItem = NSMenuItem(title: local("語言", "Language", "言語"), action: nil, keyEquivalent: "")
        let languages = NSMenu(title: languageItem.title)
        for (title, code) in [(local("預設（跟隨系統）", "Default (System)", "デフォルト（システム）"), "system"), ("繁體中文", "zh-TW"), ("English", "en"), ("日本語", "ja")] {
            let item = NSMenuItem(title: title, action: #selector(changeLanguage(_:)), keyEquivalent: "")
            item.representedObject = code; item.target = self
            item.state = engine.settingsSnapshot()["language"] as? String == code ? .on : .off
            languages.addItem(item)
        }
        languageItem.submenu = languages; appMenu.addItem(languageItem)
        appMenu.addItem(.separator())
        let update = NSMenuItem(title: local("檢查 rclone 更新…", "Check for rclone Updates…", "rclone の更新を確認…"), action: #selector(checkUpdatesFromMenu), keyEquivalent: "")
        update.target = self
        appMenu.addItem(update)
        let appUpdate = NSMenuItem(title: local("檢查 Rclone Next 更新…", "Check for Rclone Next Updates…", "Rclone Next の更新を確認…"), action: #selector(checkAppUpdatesFromMenu), keyEquivalent: "")
        appUpdate.target = self
        appMenu.addItem(appUpdate)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: local("隱藏 Rclone Browser Next", "Hide Rclone Browser Next", "Rclone Browser Next を隠す"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: local("隱藏其他 App", "Hide Others", "ほかを隠す"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: local("顯示全部", "Show All", "すべてを表示"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: local("結束 Rclone Browser Next", "Quit Rclone Browser Next", "Rclone Browser Next を終了"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menuBar.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: local("編輯", "Edit", "編集"))
        for (title, selector, key) in [(local("復原", "Undo", "取り消す"), "undo:", "z"), (local("剪下", "Cut", "カット"), "cut:", "x"),
                                       (local("複製", "Copy", "コピー"), "copy:", "c"), (local("貼上", "Paste", "ペースト"), "paste:", "v"), (local("全選", "Select All", "すべてを選択"), "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        editItem.submenu = editMenu
        menuBar.addItem(editItem)
        let goItem = NSMenuItem()
        let goMenu = NSMenu(title: local("前往", "Go", "移動"))
        let back = NSMenuItem(title: local("上一頁", "Back", "戻る"), action: #selector(RcloneWebView.goBack(_:)), keyEquivalent: "[")
        back.target = webView
        goMenu.addItem(back)
        let forward = NSMenuItem(title: local("下一頁", "Forward", "進む"), action: #selector(RcloneWebView.goForward(_:)), keyEquivalent: "]")
        forward.target = webView
        goMenu.addItem(forward)
        goItem.submenu = goMenu
        menuBar.addItem(goItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: local("視窗", "Window", "ウインドウ"))
        windowMenu.addItem(withTitle: local("縮到最小", "Minimize", "しまう"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: local("縮放", "Zoom", "拡大／縮小"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        menuBar.addItem(windowItem)
        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: local("說明", "Help", "ヘルプ"))
        let help = NSMenuItem(title: local("Rclone Browser Next 使用說明", "Rclone Browser Next Help", "Rclone Browser Next の使い方"), action: #selector(showHelp), keyEquivalent: "?")
        help.target = self; helpMenu.addItem(help); helpItem.submenu = helpMenu; menuBar.addItem(helpItem)
        NSApp.mainMenu = menuBar
        NSApp.windowsMenu = windowMenu
        NSApp.helpMenu = helpMenu
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "Rclone Browser Next \(RBNProject.version)"
        alert.informativeText = local("作者：Jason Chen\n\n在本機、NAS 與雲端之間複製、同步及備份檔案。\n\nMIT License",
                                     "Author: Jason Chen\n\nCopy, sync and back up files between local folders, NAS and clouds.\n\nMIT License",
                                     "作者：Jason Chen\n\nローカル、NAS、クラウド間でファイルをコピー、同期、バックアップ。\n\nMIT License")
        alert.addButton(withTitle: local("好", "OK"))
        alert.addButton(withTitle: local("檢查 Rclone Next 更新…", "Check for Rclone Next Updates…", "Rclone Next の更新を確認…"))
        if alert.runModal() == .alertSecondButtonReturn { checkAppUpdatesFromMenu() }
    }

    @objc private func showSettings() { showWindow(); sendEvent(type: "menuAction", data: ["action": "settings"]) }
    @objc private func showHelp() { showWindow(); sendEvent(type: "menuAction", data: ["action": "help"]) }
    @objc private func showWindow() { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func changeLanguage(_ sender: NSMenuItem) {
        guard let language = sender.representedObject as? String, ["system", "zh-TW", "en", "ja"].contains(language) else { return }
        showWindow(); sendEvent(type: "menuAction", data: ["action": "language", "language": language])
    }
    @objc private func configureFromMenu() {
        showWindow()
        sendEvent(type: "menuAction", data: ["action": "configureRemotes"])
    }

    private func applyInterfacePreferences() {
        let settings = engine.settingsSnapshot()
        if settings["bounceDockOnCompletion"] as? Bool == false { completionAttention.cancel() }
        let zoom = RBNInterfaceScale.zoom(settings["interfaceScale"] as? Int ?? 100)
        if abs(webView.pageZoom - zoom) > 0.0001 { webView.pageZoom = zoom }
        startupSurface?.applyZoom(zoom)
        if settings["showStatusItem"] as? Bool == true {
            if statusItem == nil { statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength) }
            if let icon = NSApp.applicationIconImage?.copy() as? NSImage {
                icon.size = NSSize(width: 19, height: 19); statusItem?.button?.image = icon
            }
            statusItem?.button?.toolTip = "Rclone Browser Next"
            let menu = NSMenu()
            for (title, selector) in [(local("顯示視窗", "Show Window", "ウインドウを表示"), #selector(showWindow)),
                                       (local("設定…", "Settings…", "設定…"), #selector(showSettings)),
                                       (local("帳號設定…", "Account setup…", "アカウント設定…"), #selector(configureFromMenu))] {
                let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; menu.addItem(item)
            }
            menu.addItem(.separator())
            menu.addItem(withTitle: local("結束", "Quit", "終了"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
            statusItem?.menu = menu
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item); statusItem = nil
        }
        if settings["notifyOnCompletion"] as? Bool == true, !notificationRequested {
            notificationRequested = true
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
                if let error = error { self.sendEvent(type: "updateStatus", data: ["phase": "notice", "message": error.localizedDescription]) }
            }
        }
    }

    private func notifyFinishedJob(_ job: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let settings = self.engine.settingsSnapshot()
            guard self.completionAttention.consume(job,
                enabled: settings["bounceDockOnCompletion"] as? Bool ?? true,
                isActive: NSApp.isActive, isTerminating: self.terminationStarted),
                settings["notifyOnCompletion"] as? Bool == true,
                let id = job["id"] as? String, let state = job["status"] as? String else { return }
            // Dock attention is independent of notification authorization.
            let content = UNMutableNotificationContent()
            content.title = self.local(state == "completed" ? "傳輸完成" : "傳輸失敗", state == "completed" ? "Transfer complete" : "Transfer failed", state == "completed" ? "転送完了" : "転送に失敗しました")
            content.body = (job["request"] as? [String: Any])?["label"] as? String ?? "Rclone Browser Next"
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "transfer-" + id, content: content, trigger: nil), withCompletionHandler: nil)
        }
    }

    @objc private func checkUpdatesFromMenu() {
        requestQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let result = try self.checkForUpdates(manual: true)
                if result["status"] as? String == "current" {
                    self.presentMessage(self.local("rclone 已是最新版本", "rclone is up to date"),
                                        detail: result["latestVersion"] as? String ?? "")
                } else if result["status"] as? String == "unavailable" {
                    self.presentMessage(self.local("無法自動更新", "Automatic update unavailable"),
                                        detail: result["message"] as? String ?? "")
                }
            }
            catch { self.presentError(error) }
        }
    }

    private func checkAppUpdates() throws -> RBNAppReleaseResult {
        let reserved = activityLock.holding { () -> Bool in
            guard !appUpdateBusy, !terminationValue else { return false }
            appUpdateBusy = true
            return true
        }
        guard reserved else {
            throw EngineError(local("已在檢查 App 更新，請稍候。", "An app update check is already in progress. Please wait.", "アプリの更新を確認中です。しばらくお待ちください。"))
        }
        defer { activityLock.holding { appUpdateBusy = false } }
        return try appReleaseChecker.check(settings: engine.settingsSnapshot())
    }

    @objc private func checkAppUpdatesFromMenu() {
        requestQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let result = try self.checkAppUpdates()
                DispatchQueue.main.async {
                    guard !self.terminationStarted else { return }
                    let alert = NSAlert()
                    switch result.status {
                    case .available:
                        let latest = result.latest ?? ""
                        alert.messageText = self.local("Rclone Next 有新版本 \(latest)", "Rclone Next \(latest) is available", "Rclone Next \(latest) が利用できます")
                        alert.informativeText = self.local("目前版本：\(result.current)\n開啟 GitHub 下載頁，下載新版後依隨附說明更新。", "Installed: \(result.current)\nOpen the GitHub release page and follow the included update instructions.", "現在のバージョン：\(result.current)\nGitHub のリリースページから新しいバージョンをダウンロードし、同梱の手順で更新してください。")
                    case .current:
                        alert.messageText = self.local("Rclone Next 已是最新版本", "Rclone Next is up to date", "Rclone Next は最新です")
                        alert.informativeText = self.local("目前版本：\(result.current)\n最新正式版：\(result.latest ?? result.current)", "Installed: \(result.current)\nLatest release: \(result.latest ?? result.current)", "現在のバージョン：\(result.current)\n最新の正式版：\(result.latest ?? result.current)")
                    case .unpublished:
                        alert.messageText = self.local("目前沒有可取得的正式版本", "No published release is available", "取得できる正式版はまだありません")
                        alert.informativeText = self.local("目前版本：\(result.current)\n目前還沒有可下載的正式版本，請稍後再檢查。", "Installed: \(result.current)\nNo published version is available to download yet. Check again later.", "現在のバージョン：\(result.current)\nダウンロードできる正式版はまだありません。後でもう一度確認してください。")
                    }
                    alert.addButton(withTitle: self.local("好", "OK", "OK"))
                    if result.status != .unpublished {
                        alert.addButton(withTitle: self.local("開啟下載頁", "Open Release Page", "リリースページを開く"))
                    }
                    if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(result.releaseURL) }
                }
            } catch { if !self.terminationStarted { self.presentError(error) } }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        completionAttention.cancel()
        guard deferredAutomaticCheck, engine != nil else { return }
        deferredAutomaticCheck = false
        requestQueue.async { [weak self] in
            guard let self = self else { return }
            do { _ = try self.checkForUpdates(manual: false) }
            catch { self.sendEvent(type: "updateStatus", data: ["phase": "error", "message": error.localizedDescription]) }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard engine != nil, toolsManager != nil, window != nil else { return .terminateNow }
        if terminationStarted { return .terminateLater }
        if activityLock.holding({ updateInstalling }) {
            let alert = NSAlert()
            alert.messageText = local("rclone 正在更新", "rclone is updating")
            alert.informativeText = local("請等更新完成後再結束 App。", "Wait for the update to finish before quitting.")
            alert.addButton(withTitle: local("好", "OK"))
            alert.runModal()
            return .terminateCancel
        }
        // Reserve before the dialog: a newly submitted transfer or update must
        // not slip in after the user has read the quit confirmation.
        let reserved = activityLock.holding { () -> Bool in
            guard !updateInstalling, !nativeConnectionChanging, !configuringRemotes,
                  auxiliaryOperations == 0, operationStarts == 0 else { return false }
            terminationValue = true
            return true
        }
        guard reserved else {
            presentMessage(local("請稍候再結束", "Please wait before quitting", "少し待ってから終了してください"),
                           detail: local("請先完成帳號設定、目錄匯出或目前進行中的操作，再結束 App。", "Finish account setup, directory exports, and the current operation before quitting.", "アカウント設定、一覧の書き出し、または進行中の操作を完了してから終了してください。"))
            return .terminateCancel
        }
        let quit = engine.quitSummary()
        let hasWork = quit.activeJobs > 0 || toolsManager.hasActiveSessions
        let needsConfirmation = quit.requiresConfirmation || toolsManager.hasActiveSessions
        let approved = !needsConfirmation || confirm(
            title: hasWork ? local("停止工作並結束？", "Stop jobs and quit?", "処理を停止して終了しますか？") : local("確定結束 Rclone Browser Next？", "Quit Rclone Browser Next?", "Rclone Browser Next を終了しますか？"),
            detail: hasWork
                ? local("結束會停止傳輸、掛載與播放。未完成的工作會保留在紀錄中，下次可以重試。", "Quitting stops transfers, mounts and streams. Unfinished jobs remain in the history so you can retry them next time.", "終了すると転送、マウント、再生を停止します。未完了の処理は履歴に残り、次回再試行できます。")
                : local("還有失敗或未完成的工作。工作紀錄會保留，下次可重試。", "There are failed or unfinished jobs. Their history will be kept so you can retry them next time.", "失敗または未完了の処理があります。履歴は保存され、次回再試行できます。"),
            action: hasWork ? local("停止並結束", "Stop and quit", "停止して終了") : local("結束", "Quit", "終了"))
        guard approved else { terminationStarted = false; return .terminateCancel }
        engine.cancelListings()
        requestQueue.async { [weak self] in
            do { try self?.toolsManager.shutdown() }
            catch {
                DispatchQueue.main.async {
                    self?.terminationStarted = false
                    NSApp.reply(toApplicationShouldTerminate: false)
                    self?.presentError(error)
                }
                return
            }
            self?.engine.shutdown()
            DispatchQueue.main.async { self?.terminalTimer?.cancel(); NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        completionAttention.cancel()
        (webView as? RcloneWebView)?.stopHistoryMonitoring()
    }

    private func local(_ chinese: String, _ english: String, _ japanese: String? = nil) -> String {
        switch resolvedLanguage {
        case "en": return english
        case "ja": return japanese ?? RBNNativeStrings.japanese(chinese, fallback: english)
        default: return chinese
        }
    }

    private var resolvedLanguage: String {
        RBNLanguageResolver.resolve(engine?.settingsSnapshot()["language"] as? String ?? "system")
    }

    private func applyAppearance() {
        let appearance = RBNWebAppearance(theme: engine.settingsSnapshot()["theme"] as? String)
        let theme = appearance.theme
        NSApp.appearance = NSAppearance(named: appearance.isDark ? .darkAqua : .aqua)
        window?.backgroundColor = appearance.backgroundColor
        (webView as? RcloneWebView)?.applyAppearance(appearance)
        let family = theme.hasPrefix("green-") ? "green" : (theme.hasPrefix("blue-") || ["dark", "light"].contains(theme) ? "blue" : "purple")
        let startupIcon = Bundle.main.resourceURL.flatMap { RBNStartupArtwork.image(resources: $0, theme: theme) }
        if family == currentIconFamily {
            startupSurface?.applyAppearance(appearance, icon: startupIcon)
            return
        }
        if themeIcons[family] == nil, let resources = Bundle.main.resourceURL {
            let filename = family == "purple" ? "AppIcon.icns" : "AppIcon-\(family).icns"
            themeIcons[family] = NSImage(contentsOf: resources.appendingPathComponent(filename))
                ?? NSImage(contentsOf: resources.appendingPathComponent("AppIcon.icns"))
        }
        if let icon = themeIcons[family] {
            RBNAppIconAppearance.apply(icon)
            currentIconFamily = family
        }
        startupSurface?.applyAppearance(appearance, icon: startupIcon)
    }

    private func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }

    private func isBundledDocument(_ url: URL?) -> Bool {
        guard let url = url, url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else { return false }
        return url.resolvingSymlinksInPath().standardizedFileURL.path == indexURL?.path
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let permitted = navigationAction.targetFrame?.isMainFrame == true && isBundledDocument(navigationAction.request.url)
        decisionHandler(permitted ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === startupNavigation, isBundledDocument(webView.url) else { return }
        pageReady = true
        startupSurface?.revealWhenReady { [weak self] _ in self?.showStartupTimeout() }
        for event in queuedEvents { evaluate(function: "__rbnEvent", value: event) }
        queuedEvents.removeAll()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard navigation === startupNavigation, (error as NSError).code != NSURLErrorCancelled else { return }
        showStartupFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard navigation === startupNavigation, (error as NSError).code != NSURLErrorCancelled else { return }
        showStartupFailure(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        engine.cancelListings()
        showStartupTimeout()
    }

    private func loadStartupDocument() {
        engine.cancelListings()
        pageReady = false
        startupSurface?.beginLoading(message: local("正在啟動…", "Starting…", "起動中…"))
        startupNavigation = webView.loadFileURL(indexURL, allowingReadAccessTo: webRoot)
    }

    private func showStartupTimeout() {
        pageReady = false
        startupNavigation = nil
        startupSurface?.showFailure(
            local("畫面未能載入，請重試。", "The interface could not load. Try again.", "画面を読み込めませんでした。再試行してください。"),
            retryTitle: local("重試", "Retry", "再試行"))
    }

    private func showStartupFailure(_ error: Error) {
        pageReady = false
        startupNavigation = nil
        startupSurface?.showFailure(localizedError(error), retryTitle: local("重試", "Retry", "再試行"))
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "rclone", message.webView === webView, message.frameInfo.isMainFrame,
              !terminationStarted,
              isBundledDocument(message.frameInfo.request.url),
              let body = message.body as? [String: Any], let method = body["method"] as? String,
              let args = body["args"] as? [Any], args.count <= 16,
              let id = body["id"], let idKey = requestIdentifier(id),
              JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body), data.count <= 8 * 1024 * 1024 else { return }
        guard permittedMethods.contains(method) else {
            sendReply(id: id, error: EngineError("不支援的操作。")); return
        }
        guard pendingIDs.count < 256, pendingIDs.insert(idKey).inserted else { return }
        if method == "list" {
            do { try engine.prepareListing(options: args.count > 1 ? args[1] : nil) }
            catch {
                pendingIDs.remove(idKey)
                sendReply(id: id, error: error)
                return
            }
        }
        requestQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let result = try self.handle(method: method, arguments: args)
                self.sendReply(id: id, result: result)
                if method == "bootstrap" { self.scheduleStartupUpdateCheck() }
            } catch { self.sendReply(id: id, error: error) }
            DispatchQueue.main.async { self.pendingIDs.remove(idKey) }
        }
    }

    private func requestIdentifier(_ value: Any) -> String? {
        if let value = value as? String, !value.isEmpty, value.utf8.count <= 128 { return "s:" + value }
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
           value.doubleValue.isFinite, value.doubleValue.rounded() == value.doubleValue,
           value.doubleValue >= 0, value.doubleValue <= 9_007_199_254_740_991 { return "n:" + value.stringValue }
        return nil
    }

    private func handle(method: String, arguments: [Any]) throws -> Any {
        guard !terminationStarted else { throw EngineError(local("程式正在關閉。", "The app is closing.", "アプリを終了しています。")) }
        func argument(_ index: Int) -> Any? { arguments.indices.contains(index) ? arguments[index] : nil }
        switch method {
        case "chooseFolder":
            return chooseFolder(current: argument(0) as? String) as Any? ?? NSNull()
        case "chooseFile":
            let kind = try EngineJSON.text(argument(0), "檔案類型")
            guard ["rclone", "config", "player", "credential"].contains(kind) else { throw EngineError("檔案類型不正確。") }
            return chooseFile(kind: kind) as Any? ?? NSNull()
        case "startTransfer":
            return try withOperationStartup {
                guard let value = argument(0) else { throw EngineError("缺少操作參數。") }
                let request = try engine.normalizedRequest(value)
                guard confirmTransfer(request) else { return NSNull() as Any }
                // Submit exactly what was confirmed, even if a default changes
                // while the native dialog is open.
                return try engine.invoke(method, arguments: [request.json])
            }
        case "retryJob":
            return try withOperationStartup {
                let id = try EngineJSON.text(argument(0), "工作編號")
                guard let jobs = try engine.invoke("listJobs", arguments: []) as? [[String: Any]],
                      let job = jobs.first(where: { $0["id"] as? String == id }) else { throw EngineError("找不到這個工作。") }
                let request = try EngineTransferRequest(job["request"])
                guard confirmTransfer(request) else { return NSNull() as Any }
                return try engine.invoke(method, arguments: arguments)
            }
        case "remove":
            let endpoint = try EngineEndpoint(argument(0))
            let selection = try EngineSelection.parse(argument(1))
            guard !selection.isEmpty else { throw EngineError("請先選取要刪除的項目。") }
            let names = selection.prefix(8).map(\.name).joined(separator: "\n")
            let detail = local("位置：\(endpoint.argument)\n\n\(names)\n\n將刪除 \(selection.count) 個選取項目。這項操作不會移到垃圾桶。",
                               "Location: \(endpoint.argument)\n\n\(names)\n\nDelete \(selection.count) selected items. Items are not moved to Trash.")
            guard confirm(title: local("刪除選取項目？", "Delete selected items?"), detail: detail,
                          action: local("刪除", "Delete")) else { return false }
            return try engine.invoke(method, arguments: arguments)
        case "exportLog":
            let id = try EngineJSON.text(argument(0), "工作編號")
            guard let source = try engine.invoke("getLogPath", arguments: [id]) as? String else { throw EngineError("找不到工作記錄。") }
            guard let destination = saveFile(defaultName: "rclone-\(id).jsonl") else { return NSNull() }
            try copyExport(source: URL(fileURLWithPath: source), destination: destination)
            return destination.path
        case "exportJobReport":
            let id = try EngineJSON.text(argument(0), "工作編號")
            let format = try EngineJSON.text(argument(1) ?? "jsonl", "匯出格式")
            guard ["jsonl", "comparison"].contains(format) else { throw EngineError("匯出格式不正確。") }
            let filename = format == "comparison" ? "rclone-\(id)-comparison.txt" : "rclone-\(id)-report.jsonl"
            guard let destination = saveFile(defaultName: filename) else { return NSNull() }
            guard let source = try engine.invoke("getJobReportPath", arguments: [id, format]) as? String else {
                throw EngineError("找不到工作記錄。")
            }
            // The engine returns a closed, immutable export snapshot, never
            // the live ledger. Release it after either a successful or failed
            // copy; the original report remains with the job.
            defer { try? FileManager.default.removeItem(atPath: source) }
            try copyExport(source: URL(fileURLWithPath: source), destination: destination)
            return destination.path
        case "exportTasks":
            let tasks = try engine.invoke("exportTasks", arguments: [])
            guard let destination = saveFile(defaultName: "Rclone_Browser_Tasks.json") else { return NSNull() }
            let data = try JSONSerialization.data(withJSONObject: tasks, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: destination, options: .atomic)
            return destination.path
        case "importTasks":
            guard let source = openTaskFile() else { return NSNull() }
            let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
            guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 8 * 1024 * 1024 else { throw EngineError("作業檔超過 8 MiB，請縮小後再匯入。") }
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: source))
            return try engine.invoke("importTasks", arguments: [object])
        case "accountConfig":
            guard !toolsManager.hasActiveSessions, !activityLock.holding({ configuringRemotes || updateInstalling || terminationValue }) else { throw EngineError("請先結束終端機設定或播放，再開啟圖形帳號設定。") }
            let result = try engine.invoke(method, arguments: arguments)
            if let state = result as? [String: Any], state["authorizationStarted"] as? Bool == true,
               let phase = state["phase"] as? String, ["question", "ready", "committed", "error"].contains(phase),
               let id = state["id"] as? String {
                onMain {
                    guard self.returnedAccountAuthorizationID != id else { return }
                    self.returnedAccountAuthorizationID = id
                    self.showWindow()
                }
            }
            return result
        case "openAccountAuthorization":
            let url = try engine.accounts.authorizationURL()
            guard onMain({ NSWorkspace.shared.open(url) }) else { throw EngineError("無法開啟瀏覽器。") }
            return NSNull()
        case "configureRemotes":
            try configureRemotes()
            return NSNull()
        case "openExternal":
            let value = try EngineJSON.text(argument(0), "網址", maximum: 2048)
            guard let url = URL(string: value), permittedExternal(url) else { throw EngineError("只能開啟 rclone 官方網站與參考專案。") }
            guard onMain({ NSWorkspace.shared.open(url) }) else { throw EngineError("無法開啟瀏覽器。") }
            return NSNull()
        case "checkForUpdates":
            let manual: Bool
            if arguments.isEmpty { manual = true }
            else { manual = try EngineJSON.bool(argument(0), "更新檢查方式") }
            return try checkForUpdates(manual: manual)
        case "checkAppUpdates":
            guard arguments.isEmpty else { throw EngineError("更新檢查不需要額外參數。") }
            return try checkAppUpdates().json
        case "showAbout":
            guard arguments.isEmpty else { throw EngineError("關於視窗不需要額外參數。") }
            onMain { showAbout() }
            return NSNull()
        case "copyText":
            let value = try EngineJSON.text(argument(0), "文字", maximum: 1024 * 1024)
            onMain { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
            return NSNull()
        case "directoryTree":
            let endpoint = try EngineEndpoint(argument(0))
            let depth = try EngineJSON.integer(argument(1) ?? 4, "目錄深度", 1...64)
            return try withToolsContext { try RcloneTools.tree(context: $0, endpoint: endpoint, maxDepth: depth) }
        case "exportFileList":
            let endpoint = try EngineEndpoint(argument(0))
            let format = argument(1) as? String ?? "csv"
            guard ["csv", "txt"].contains(format) else { throw EngineError("匯出格式不正確。") }
            guard let destination = saveFile(defaultName: "Rclone_File_List." + format) else { return NSNull() }
            return try withToolsContext {
                let exported = try RcloneTools.exportList(context: $0, endpoint: endpoint, destination: destination, filenamesOnly: format == "txt")
                return exported["path"] as? String ?? destination.path
            }
        case "publicLink":
            let endpoint = try EngineEndpoint(argument(0))
            let name = try EngineJSON.text(argument(1), "檔案名稱")
            let isDir = try EngineJSON.bool(argument(2), "資料夾")
            let target = try endpoint.child(name)
            guard endpoint.remote != nil else { throw EngineError(local("請選擇支援分享功能的雲端位置。", "Choose a cloud location that supports public links.", "公開リンクに対応するクラウドを選択してください。")) }
            guard confirm(title: local("建立公開連結？", "Create a public link?", "公開リンクを作成しますか？"),
                          detail: local("\(target.argument)\n\n取得連結的人可能不需登入就能讀取內容。連結的期限與權限由雲端服務決定。", "\(target.argument)\n\nAnyone with the link may be able to read the content without signing in. Expiration and permissions depend on the provider.", "\(target.argument)\n\nリンクを知っている人は、ログインせずに内容を閲覧できる場合があります。有効期限と権限はクラウドサービスによって異なります。"),
                          action: local("建立公開連結", "Create public link", "公開リンクを作成")) else { return NSNull() }
            return try withToolsContext { try RcloneTools.publicLink(context: $0, endpoint: endpoint, name: name, isDir: isDir).absoluteString }
        case "startMount":
            let endpoint = try EngineEndpoint(argument(0))
            let options = argument(1) as? [String: Any] ?? [:]
            let readOnly = try EngineJSON.bool(options["readOnly"] ?? true, "唯讀")
            let cacheMode = options["cacheMode"] as? String ?? "writes"
            guard ["off", "minimal", "writes", "full"].contains(cacheMode) else { throw EngineError("快取模式不正確。") }
            guard let folder = chooseMountFolder() else { return NSNull() }
            let flags = (readOnly ? ["--read-only"] : []) + ["--vfs-cache-mode", cacheMode]
            return try withOperationStartup {
                try withToolsContext { try toolsManager.startMount(context: $0, endpoint: endpoint, mountPoint: URL(fileURLWithPath: folder), options: flags) }
            }
        case "startStream":
            let endpoint = try EngineEndpoint(argument(0))
            let name = try EngineJSON.text(argument(1), "檔案名稱")
            var settings = engine.settingsSnapshot()
            var player = settings["streamPlayerPath"] as? String ?? ""
            if player.isEmpty || !FileManager.default.isExecutableFile(atPath: player) {
                guard let selected = chooseFile(kind: "player") else { return NSNull() }
                player = selected
                _ = try engine.invoke("saveSettings", arguments: [["streamPlayerPath": player]])
                settings = engine.settingsSnapshot()
                sendEvent(type: "configurationChanged", data: [:])
            }
            let arguments = settings["streamPlayerArguments"] as? [String] ?? ["-"]
            return try withOperationStartup {
                try withToolsContext { try toolsManager.startStream(context: $0, endpoint: endpoint, name: name, player: URL(fileURLWithPath: player), playerArgs: arguments) }
            }
        case "listToolSessions": return toolsManager.listSessions()
        case "stopToolSession":
            let id = try EngineJSON.text(argument(0), "工作編號")
            _ = try toolsManager.stopSession(id)
            return NSNull()
        case "saveSettings":
            var connectionReserved = false
            defer { if connectionReserved { activityLock.holding { nativeConnectionChanging = false } } }
            if let patch = argument(0) as? [String: Any],
               ["rclonePath", "rcloneDirectory", "configPath", "proxyMode", "httpProxy", "httpsProxy", "noProxy", "defaultRcloneOptions", "networkOptions"].contains(where: { patch[$0] != nil }) {
                try activityLock.holding {
                    guard !terminationValue else { throw EngineError("程式正在關閉。") }
                    guard !configuringRemotes else {
                        throw EngineError(local("請先結束帳號設定，再變更 rclone 位置與連線設定。", "Finish account setup before changing rclone or connection settings.", "rclone や接続設定を変更する前に、アカウント設定を終了してください。"))
                    }
                    guard !toolsManager.hasActiveSessions, operationStarts == 0 else {
                        throw EngineError(local("請先停止掛載或播放，再更換 rclone 位置與連線設定。", "Stop mounts and streams before changing rclone or connection settings.", "rclone や接続設定を変更する前に、マウントと再生を停止してください。"))
                    }
                    guard !nativeConnectionChanging, !updateInstalling else { throw EngineError("rclone 更新或位置切換正在進行。") }
                    nativeConnectionChanging = true
                    connectionReserved = true
                }
            }
            let result = try engine.invoke(method, arguments: arguments)
            onMain { applyAppearance(); installMenus(); applyInterfacePreferences() }
            return result
        default:
            return try engine.invoke(method, arguments: arguments)
        }
    }

    private func withToolsContext<T>(_ operation: (RcloneTools.Context) throws -> T) throws -> T {
        let reserved = activityLock.holding { () -> Bool in
            guard !terminationValue, !nativeConnectionChanging, !updateInstalling else { return false }
            auxiliaryOperations += 1
            return true
        }
        guard reserved else { throw EngineError(local("請等目前的設定或更新完成，再執行工具。", "Wait for settings or the update to finish before running a tool.", "設定の適用または更新が完了してからツールを実行してください。")) }
        defer { activityLock.holding { auxiliaryOperations -= 1 } }
        return try engine.withAuxiliaryOperation {
            let snapshot = try engine.auxiliaryContext()
            return try operation(RcloneTools.Context(binary: snapshot.binary, arguments: snapshot.arguments, environment: snapshot.environment))
        }
    }

    private func withOperationStartup<T>(_ operation: () throws -> T) throws -> T {
        let reserved = activityLock.holding { () -> Bool in
            guard !updateInstalling, !nativeConnectionChanging, !terminationValue else { return false }
            operationStarts += 1; return true
        }
        guard reserved else { throw EngineError(local("請等設定、更新或結束確認完成，再開始工作。", "Finish settings, updates or the quit confirmation before starting a job.", "設定、更新、終了の確認を完了してから処理を開始してください。")) }
        defer { activityLock.holding { operationStarts -= 1 } }
        return try operation()
    }

    private func confirmTransfer(_ request: EngineTransferRequest) -> Bool {
        if request.dryRun || request.mode == "copy" { return true }
        let locations = local("來源：\(request.source.argument)\n目標：\(request.destination.argument)",
                              "Source: \(request.source.argument)\nDestination: \(request.destination.argument)")
        if request.mode == "sync" {
            let limit = request.options.integer("maxDelete")
            let scope = request.selection.isEmpty
                ? local("\n\n範圍：整個資料夾，依本次篩選規則處理。", "\n\nScope: the whole folder, using this job's filters.", "\n\n対象：フォルダ全体。この転送のフィルターを適用します。")
                : local("\n\n範圍：以下選取資料夾，依本次篩選規則處理。\n", "\n\nScope: these selected folders, using this job's filters.\n", "\n\n対象：次の選択フォルダ。この転送のフィルターを適用します。\n") + request.selection.prefix(10).map(\.name).joined(separator: "\n") + (request.selection.count > 10 ? local("\n另有 \(request.selection.count - 10) 個資料夾。", "\nAnd \(request.selection.count - 10) more folders.", "\nほか \(request.selection.count - 10) フォルダ。") : "")
            let deletionNotice = limit < 0
                ? local("\n\n上述範圍內，目標中來源沒有的檔案會被刪除。這次未設定刪除數量上限。", "\n\nWithin this scope, destination files absent from the source will be deleted. No deletion-count limit is set.", "\n\nこの範囲内で、転送元にない転送先のファイルを削除します。削除数の上限は設定されていません。")
                : local("\n\n上述範圍內，目標中來源沒有的檔案會被刪除。這次最多刪除 \(limit) 個項目。", "\n\nWithin this scope, destination files absent from the source will be deleted. Maximum deletions: \(limit).", "\n\nこの範囲内で、転送元にない転送先のファイルを削除します。削除数の上限は \(limit) 件です。")
            let excludedNotice = request.options.flag("deleteExcluded")
                ? local("\n目標中符合排除規則的檔案也會刪除。", "\nExcluded destination files will also be deleted.", "\n転送先で除外ルールに一致するファイルも削除します。") : ""
            return confirm(title: local("同步到目標？", "Sync to destination?"),
                           detail: locations + scope + deletionNotice + excludedNotice,
                           action: local("開始同步", "Start sync"))
        }
        return confirm(title: local("移動到目標？", "Move to destination?"),
                       detail: locations + local("\n\n檔案傳送成功，或目標已有依本次設定無需更新的副本時，都會刪除來源檔案。", "\n\nSource files are deleted after a successful transfer, or when the existing destination copy needs no update under this job's settings.", "\n\n転送に成功した場合、または今回の設定で転送先の既存コピーが更新不要と判定された場合、転送元のファイルを削除します。"),
                       action: local("開始移動", "Start move"))
    }

    private func confirm(title: String, detail: String, action: String) -> Bool {
        onMain {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = detail
            alert.alertStyle = .warning
            alert.addButton(withTitle: local("取消", "Cancel"))
            let proceed = alert.addButton(withTitle: action)
            proceed.keyEquivalent = ""
            alert.buttons[0].keyEquivalent = "\r"
            return alert.runModal() == .alertSecondButtonReturn
        }
    }

    private func chooseFolder(current: String?) -> String? {
        onMain {
            guard !terminationStarted else { return nil }
            let panel = NSOpenPanel()
            panel.title = local("選擇資料夾", "Choose folder")
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            if let path = current, path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) {
                panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
            }
            return panel.runModal() == .OK ? panel.url?.path : nil
        }
    }

    private func chooseFile(kind: String) -> String? {
        onMain {
            guard !terminationStarted else { return nil }
            let panel = NSOpenPanel()
            panel.title = kind == "credential" ? local("選擇憑證檔案", "Choose credential file", "認証ファイルを選択") : kind == "player" ? local("選擇播放器", "Choose player", "プレーヤーを選択") : kind == "rclone" ? local("選擇 rclone 執行檔", "Choose rclone executable") : local("選擇 rclone 設定檔", "Choose rclone configuration")
            if kind == "player" { panel.message = local("選擇已安裝的 mpv、VLC 或支援從標準輸入讀取內容的播放器。", "Choose an installed mpv, VLC, or a player that can read standard input.", "インストール済みの mpv、VLC、または標準入力に対応するプレーヤーを選択してください。") }
            panel.treatsFilePackagesAsDirectories = false
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.allowsMultipleSelection = false
            panel.showsHiddenFiles = true
            guard panel.runModal() == .OK, let url = panel.url else { return nil }
            if kind == "player" {
                let executable = url.pathExtension.lowercased() == "app" ? Bundle(url: url)?.executableURL : url
                guard let executable = executable, FileManager.default.isExecutableFile(atPath: executable.path) else {
                    presentError(EngineError(local("這個播放器沒有可用的執行檔，請選擇已安裝的播放器。", "This player has no usable executable. Choose an installed player.", "このプレーヤーには使用可能な実行ファイルがありません。インストール済みのプレーヤーを選択してください。")))
                    return nil
                }
                return executable.path
            }
            return url.path
        }
    }

    private func chooseMountFolder() -> String? {
        onMain {
            guard !terminationStarted else { return nil }
            let panel = NSOpenPanel()
            panel.title = local("選擇空的掛載資料夾", "Choose an empty mount folder", "空のマウント先フォルダを選択")
            panel.message = local("請先安裝 macFUSE 或 FUSE-T，並使用支援 mount 的 rclone。", "Install macFUSE or FUSE-T and use a version of rclone that supports mount.", "macFUSE または FUSE-T をインストールし、mount に対応する rclone を使用してください。")
            panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            return panel.runModal() == .OK ? panel.url?.path : nil
        }
    }

    private func saveFile(defaultName: String) -> URL? {
        onMain {
            guard !terminationStarted else { return nil }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = defaultName
            panel.canCreateDirectories = true
            return panel.runModal() == .OK ? panel.url : nil
        }
    }

    private func openTaskFile() -> URL? {
        onMain {
            guard !terminationStarted else { return nil }
            let panel = NSOpenPanel()
            panel.title = local("匯入作業", "Import tasks")
            panel.allowedContentTypes = [.json]
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            return panel.runModal() == .OK ? panel.url : nil
        }
    }

    private func copyExport(source: URL, destination: URL) throws {
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".rbn-export-" + UUID().uuidString)
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: source, to: staging)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staging)
        } else { try fm.moveItem(at: staging, to: destination) }
    }

    private func permittedExternal(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        if host == "rclone.org" || host == "downloads.rclone.org" { return true }
        guard host == "github.com" else { return false }
        return ["/kapitainsky/RcloneBrowser", "/rclone/rclone", "/" + RBNProject.repository].contains {
            url.path == $0 || url.path.hasPrefix($0 + "/")
        }
    }

    private func configureRemotes() throws {
        let acquired = activityLock.holding { () -> Bool in
            if configuringRemotes || updateInstalling || nativeConnectionChanging || terminationValue { return false }
            configuringRemotes = true
            return true
        }
        guard acquired else { throw EngineError("請先完成 rclone 更新或目前開啟的設定工具。") }
        do {
            let context = try engine.auxiliaryContext()
            let binary = context.binary
            let settings = engine.settingsSnapshot()
            let connection = context.environment
            var proxyCommands = ""
            if settings["proxyMode"] as? String == "manual" {
                proxyCommands = "unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy\n"
                for name in ["HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY"] {
                    if let value = connection[name], !value.isEmpty { proxyCommands += "export " + name + "=" + shellQuote(value) + "\n" }
                }
            }
            let folder = temporaryDirectory.appendingPathComponent("config-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let scriptURL = folder.appendingPathComponent("Configure-rclone.command")
            let completionURL = folder.appendingPathComponent("finished")
            let arguments = ([binary] + context.arguments + ["config"]).map(shellQuote).joined(separator: " ")
            let script = """
            #!/bin/bash
            set -uo pipefail
            RBN_CONFIG_FINISH() {
              RBN_CONFIG_STATUS=$?
              trap - EXIT
              /usr/bin/printf '%s\\n' "$RBN_CONFIG_STATUS" > \(shellQuote(completionURL.path))
            }
            trap RBN_CONFIG_FINISH EXIT
            trap 'exit 129' HUP
            trap 'exit 130' INT
            trap 'exit 143' TERM
            for RBN_VARIABLE in "${!RCLONE_@}"; do unset "$RBN_VARIABLE"; done
            \(proxyCommands)
            export TMPDIR=\(shellQuote(temporaryDirectory.path + "/"))
            \(arguments)
            RBN_CONFIG_STATUS=$?
            /usr/bin/printf '%s\\n' \(shellQuote(local("設定工具已結束，可以關閉這個視窗。", "Account setup has finished. You can close this window.", "アカウント設定が終了しました。このウインドウを閉じてください。")))
            exit "$RBN_CONFIG_STATUS"
            """ + "\n"
            try Data(script.utf8).write(to: scriptURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            let launched = onMain { NSWorkspace.shared.openFile(scriptURL.path, withApplication: "/System/Applications/Utilities/Terminal.app") }
            guard launched else {
                try? FileManager.default.removeItem(at: folder)
                throw EngineError("無法開啟 Terminal。請在終端機執行所選 rclone 的 config 指令。")
            }
            let timer = DispatchSource.makeTimerSource(queue: requestQueue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                guard let self = self, FileManager.default.fileExists(atPath: completionURL.path) else { return }
                self.activityLock.holding { self.configuringRemotes = false }
                timer.cancel()
                timer.setEventHandler {}
                DispatchQueue.main.async { self.terminalTimer = nil }
                self.sendEvent(type: "configurationChanged", data: [:])
                try? FileManager.default.removeItem(at: folder)
            }
            onMain { terminalTimer = timer }
            timer.resume()
        } catch {
            activityLock.holding { configuringRemotes = false }
            throw error
        }
    }

    private func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private func scheduleStartupUpdateCheck() {
        onMain {
            guard !startupCheckScheduled else { return }
            startupCheckScheduled = true
            requestQueue.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self = self else { return }
                do { _ = try self.checkForUpdates(manual: false) }
                catch { self.sendEvent(type: "updateStatus", data: ["phase": "error", "message": error.localizedDescription]) }
            }
        }
    }

    private func checkForUpdates(manual: Bool) throws -> [String: Any] {
        do { return try performUpdateCheck(manual: manual) }
        catch {
            sendEvent(type: "updateStatus", data: ["status": "error", "phase": "error", "message": localizedError(error)])
            throw error
        }
    }

    private func performUpdateCheck(manual: Bool) throws -> [String: Any] {
        var settings = engine.settingsSnapshot()
        if !manual && settings["autoCheckUpdates"] as? Bool == false { return ["status": "disabled"] }
        let acquired = activityLock.holding { () -> Bool in
            if updateBusy || terminationValue || (!manual && startupCheckPerformed) { return false }
            updateBusy = true
            if !manual { startupCheckPerformed = true }
            return true
        }
        guard acquired else {
            return ["status": manual ? "busy" : "disabled", "message": local("正在檢查或更新 rclone，請稍候。", "A rclone check or update is already running.", "rclone の確認または更新を実行中です。しばらくお待ちください。")]
        }
        defer { activityLock.holding { updateBusy = false; updateInstalling = false } }
        let resolved = try? engine.resolvedRclonePath()
        var target = try RcloneUpdater.defaultTarget(settings: settings, resolvedPath: resolved)
        // A manually selected empty folder should offer a download even when a
        // separate Homebrew/PATH binary is already current.
        let current = manual ? (FileManager.default.isExecutableFile(atPath: target) ? target : nil) : resolved
        if !manual && current == nil { return ["status": "notInstalled"] }
        var result = try updater.check(currentPath: current, skippedVersion: settings["skippedRcloneVersion"] as? String ?? "", manual: manual)
        let latestSettings = engine.settingsSnapshot()
        guard ["rclonePath", "rcloneDirectory", "configPath"].allSatisfy({
            (settings[$0] as? String ?? "") == (latestSettings[$0] as? String ?? "")
        }) else {
            throw EngineError(local("rclone 位置剛剛變更。已停止這次檢查，請再按一次檢查更新。", "The rclone location changed during this check. Check again to use the new location.", "確認中に rclone の場所が変更されました。新しい場所で更新を確認してください。"))
        }
        let status = result["status"] as? String ?? ""
        guard status == "available" || (status == "notInstalled" && manual) else { return result }
        if onMain({ terminationStarted }) { result["status"] = "later"; return result }
        if !manual && !onMain({ NSApp.isActive && window.isVisible }) {
            onMain { deferredAutomaticCheck = true }
            activityLock.holding { startupCheckPerformed = false }
            result["status"] = "later"
            return result
        }
        let version = result["latestVersion"] as? String ?? ""
        let initialDefault = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Tools/rclone/rclone").path
        // Only the untouched suggestion beside an installed App needs a chooser.
        // A user-selected /Applications/rclone folder is a valid external location
        // when writable; never silently redirect it or clear the selected executable.
        if current == nil && (settings["rclonePath"] as? String ?? "").isEmpty && target == initialDefault &&
            target.hasPrefix("/Applications/") {
            guard let folder = chooseFolder(current: FileManager.default.homeDirectoryForCurrentUser.path) else {
                result["status"] = "later"; return result
            }
            let patch: [String: Any] = ["rcloneDirectory": folder, "rclonePath": ""]
            target = URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent("rclone").path
            _ = try handle(method: "saveSettings", arguments: [patch])
            settings = engine.settingsSnapshot()
            sendEvent(type: "configurationChanged", data: [:])
        }
        _ = try RcloneUpdater.validatedTarget(target)
        let choice: NSApplication.ModalResponse = onMain {
            guard !terminationStarted else { return .alertSecondButtonReturn }
            let alert = NSAlert()
            alert.messageText = status == "notInstalled" ? local("下載 rclone？", "Download rclone?") : local("發現新版 rclone", "A new rclone version is available")
            let oldVersion = result["currentVersion"] as? String ?? ""
            alert.informativeText = local("目前：\(oldVersion.isEmpty ? "尚未安裝" : oldVersion)\n新版：\(version)\n\n存放位置：\(target)",
                                         "Current: \(oldVersion.isEmpty ? "Not installed" : oldVersion)\nLatest: \(version)\n\nLocation: \(target)")
            alert.addButton(withTitle: status == "notInstalled" ? local("下載", "Download") : local("更新", "Update"))
            alert.addButton(withTitle: local("稍後", "Later"))
            alert.addButton(withTitle: local("跳過此版本", "Skip this version"))
            alert.buttons[0].keyEquivalent = ""
            alert.buttons[1].keyEquivalent = "\r"
            return alert.runModal()
        }
        if choice == .alertThirdButtonReturn {
            _ = try engine.invoke("saveSettings", arguments: [["skippedRcloneVersion": version]])
            result["status"] = "skipped"
            sendEvent(type: "updateStatus", data: ["phase": "skipped", "message": local("已跳過 \(version)。", "Skipped \(version).")])
            return result
        }
        guard choice == .alertFirstButtonReturn else { result["status"] = "later"; return result }
        let confirmedSettings = engine.settingsSnapshot()
        guard ["rclonePath", "rcloneDirectory", "configPath"].allSatisfy({
            (settings[$0] as? String ?? "") == (confirmedSettings[$0] as? String ?? "")
        }) else {
            throw EngineError(local("rclone 位置已變更，已停止更新。請重新檢查。", "The rclone location changed. The update was stopped; check again.", "rclone の場所が変更されたため、更新を停止しました。もう一度確認してください。"))
        }
        guard !toolsManager.hasActiveSessions else {
            throw EngineError(local("請先停止掛載與播放，再更新 rclone。", "Stop mounts and streams before updating rclone.", "rclone を更新する前に、マウントと再生を停止してください。"))
        }
        let reserved = activityLock.holding { () -> Bool in
            guard !configuringRemotes, !nativeConnectionChanging, !terminationValue,
                  auxiliaryOperations == 0, operationStarts == 0, !toolsManager.hasActiveSessions else { return false }
            updateInstalling = true
            return true
        }
        guard reserved else { throw EngineError(local("請先完成目前的設定或工具操作，再更新 rclone。", "Finish the current settings or tool operation before updating rclone.", "設定またはツールの操作を完了してから rclone を更新してください。")) }
        try engine.setMaintenance(true)
        var maintenanceHeld = true
        defer { if maintenanceHeld { try? engine.setMaintenance(false) } }
        // A location save can finish between the dialog check and the native
        // reservation. Recheck after both gates are held, before touching bytes.
        let lockedSettings = engine.settingsSnapshot()
        guard ["rclonePath", "rcloneDirectory", "configPath"].allSatisfy({
            (settings[$0] as? String ?? "") == (lockedSettings[$0] as? String ?? "")
        }) else {
            throw EngineError(local("rclone 位置已變更，已停止更新。請重新檢查。", "The rclone location changed. The update was stopped; check again.", "rclone の場所が変更されたため、更新を停止しました。もう一度確認してください。"))
        }
        do {
            let selectedCurrent = FileManager.default.isExecutableFile(atPath: target) ? target : nil
            let updated = try updater.install(version: version, targetPath: target, currentPath: selectedCurrent)
            // Persist the installed absolute path only after the update commits.
            let path = updated["path"] as? String ?? target
            try engine.commitRcloneUpdate(path: path)
            // The renderer may refresh immediately upon this event. Release the
            // maintenance gate before any success event or reply is observable.
            try engine.setMaintenance(false)
            maintenanceHeld = false
            sendEvent(type: "updateStatus", data: ["status": "updated", "phase": "updated", "message": local("rclone 已更新為 \(version)。", "rclone updated to \(version).")])
            return updated
        } catch {
            throw error
        }
    }

    private func presentError(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.terminationStarted else { return }
            let alert = NSAlert()
            alert.messageText = self.local("操作未完成", "Could not complete the operation")
            alert.informativeText = self.localizedError(error)
            alert.alertStyle = .warning
            alert.addButton(withTitle: self.local("好", "OK"))
            alert.runModal()
        }
    }

    private func presentMessage(_ title: String, detail: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.terminationStarted else { return }
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = detail
            alert.addButton(withTitle: self.local("好", "OK"))
            alert.runModal()
        }
    }

    private func sendReply(id: Any, result: Any = NSNull(), error: Error? = nil) {
        var response: [String: Any] = ["id": id, "result": localizedResponse(result)]
        if let error = error { response["error"] = localizedError(error) }
        DispatchQueue.main.async { [weak self] in self?.evaluate(function: "__rbnReply", value: response) }
    }

    private func sendEvent(type: String, data: [String: Any]) {
        let event: [String: Any] = ["type": type, "data": localizedResponse(data)]
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.pageReady { self.evaluate(function: "__rbnEvent", value: event) }
            else {
                self.queuedEvents.append(event)
                if self.queuedEvents.count > 100 { self.queuedEvents.removeFirst() }
            }
        }
    }

    private func localizedError(_ error: Error) -> String {
        RBNNativeStrings.translate(error.localizedDescription, language: resolvedLanguage)
    }

    private func localizedResponse(_ value: Any, key: String = "") -> Any {
        if let object = value as? [String: Any] { return Dictionary(uniqueKeysWithValues: object.map { (key, item) in (key, localizedResponse(item, key: key)) }) }
        if let array = value as? [Any] { return array.map { localizedResponse($0, key: key) } }
        if ["message", "error", "warnings", "validationError"].contains(key), let text = value as? String {
            return RBNNativeStrings.translate(text, language: resolvedLanguage)
        }
        return value
    }

    private func evaluate(function: String, value: [String: Any]) {
        guard webView != nil, isBundledDocument(webView.url), JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let raw = String(data: data, encoding: .utf8) else { return }
        let json = raw.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        webView.evaluateJavaScript("if (typeof window.\(function) === 'function') window.\(function)(\(json));", completionHandler: nil)
    }
}

@main
struct RcloneBrowserNextMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = BrowserAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
#endif
