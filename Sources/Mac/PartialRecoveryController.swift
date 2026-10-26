#if os(macOS)
import Foundation
@preconcurrency import AppKit
import UniformTypeIdentifiers

/// A native, report-scoped recovery flow. Preview is read-only; apply always
/// revalidates the saved plan and uses the core's exclusive, no-overwrite rename.
final class RBNPartialRecoveryController {
    typealias Localize = (String, String, String) -> String
    private let window: NSWindow
    private let directory: URL
    private let local: Localize
    private let finished: () -> Void
    private var progress: NSPanel?

    init(window: NSWindow, directory: URL, localize: @escaping Localize, finished: @escaping () -> Void) {
        self.window = window; self.directory = directory; self.local = localize; self.finished = finished
    }

    func start() {
        let panel = NSOpenPanel()
        panel.title = local("選擇完整傳輸報告", "Choose the full transfer report", "完全な転送レポートを選択")
        panel.message = local("選擇從工作明細匯出的 JSONL。會先逐檔比對來源與暫存檔的內容，再讓你確認修復。",
                              "Choose the JSONL exported from the job details. File contents are checked before you review and approve recovery.",
                              "処理の詳細から書き出した JSONL を選択します。元のファイルと一時ファイルの内容を照合してから、復元を確認できます。")
        panel.allowedContentTypes = [UTType(filenameExtension: "jsonl") ?? .data]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [self] response in
            guard response == .OK, let report = panel.url else { finished(); return }
            preview(report)
        }
    }

    private func preview(_ report: URL) {
        showProgress(local("正在比對來源與暫存檔內容…", "Comparing source and temporary file contents…", "元のファイルと一時ファイルの内容を照合しています…"))
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let plan = directory.appendingPathComponent("recovery-plan.json")
                let result = try EnginePartialRecovery.preview(report: report, plan: plan)
                DispatchQueue.main.async { [self] in hideProgress(); confirm(result, plan: plan) }
            } catch {
                DispatchQueue.main.async { [self] in hideProgress(); showError(error) }
            }
        }
    }

    private func confirm(_ result: [String: Any], plan: URL) {
        let counts = result["counts"] as? [String: Any] ?? [:]
        let ready = (counts["ready"] as? NSNumber)?.intValue ?? 0
        let existing = (counts["existing"] as? NSNumber)?.intValue ?? 0
        let mismatch = (counts["mismatch"] as? NSNumber)?.intValue ?? 0
        let blocked = (counts["blocked"] as? NSNumber)?.intValue ?? 0
        let source = result["sourceRoot"] as? String ?? ""
        let destination = result["destinationRoot"] as? String ?? ""
        let alert = NSAlert()
        alert.messageText = local("可修復 \(ready) 個暫存檔", "\(ready) temporary files are ready to recover", "\(ready) 個の一時ファイルを復元できます")
        alert.informativeText = local(
            "來源：\(source)\n目的：\(destination)\n\n內容完全一致：\(ready)\n正式檔名已存在：\(existing)\n內容不一致：\(mismatch)\n無法核對：\(blocked)\n\n修復會解除已核對暫存檔的鎖定，並還原正式檔名。來源檔案保持原樣；已存在或無法核對的項目會略過。",
            "Source: \(source)\nDestination: \(destination)\n\nIdentical contents: \(ready)\nFinal name already exists: \(existing)\nDifferent contents: \(mismatch)\nCould not verify: \(blocked)\n\nRecovery unlocks only verified temporary files and restores their final names. Source files stay unchanged; existing or unverified items are skipped.",
            "元：\(source)\n先：\(destination)\n\n内容一致：\(ready)\n正式名が存在：\(existing)\n内容不一致：\(mismatch)\n照合できない項目：\(blocked)\n\n照合済みの一時ファイルだけをロック解除し、正式名に戻します。元のファイルは変更せず、既存または未確認の項目はスキップします。")
        if ready > 0 { alert.addButton(withTitle: local("修復 \(ready) 個檔案", "Recover \(ready) files", "\(ready) 個を復元")) }
        alert.addButton(withTitle: local("關閉", "Close", "閉じる"))
        alert.addButton(withTitle: local("查看核對報告", "Show verification report", "照合レポートを表示"))
        alert.beginSheetModal(for: window) { [self] response in
            if ready > 0, response == .alertFirstButtonReturn { apply(plan); return }
            let showReport = ready > 0 ? NSApplication.ModalResponse.alertThirdButtonReturn : .alertSecondButtonReturn
            if response == showReport { NSWorkspace.shared.activateFileViewerSelecting([plan]) }
            finished()
        }
    }

    private func apply(_ plan: URL) {
        showProgress(local("正在重新核對並修復檔名…", "Rechecking files and recovering their names…", "再照合してファイル名を復元しています…"))
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                let receipt = directory.appendingPathComponent("recovery-result.json")
                let result = try EnginePartialRecovery.apply(plan: plan, receipt: receipt)
                DispatchQueue.main.async { [self] in
                    hideProgress()
                    let counts = result["counts"] as? [String: Any] ?? [:]
                    let recovered = (counts["recovered"] as? NSNumber)?.intValue ?? 0
                    let skipped = (counts["skipped"] as? NSNumber)?.intValue ?? 0
                    let failed = (counts["failed"] as? NSNumber)?.intValue ?? 0
                    let alert = NSAlert()
                    alert.messageText = local("已修復 \(recovered) 個檔案", "Recovered \(recovered) files", "\(recovered) 個のファイルを復元しました")
                    alert.informativeText = local("略過：\(skipped)\n未完成：\(failed)\n\n逐檔結果已保存。回到檔案清單後按重新整理，即可查看正式檔名。",
                                                 "Skipped: \(skipped)\nNot recovered: \(failed)\n\nPer-file results have been saved. Refresh the file list to see the recovered names.",
                                                 "スキップ：\(skipped)\n未完了：\(failed)\n\n各ファイルの結果を保存しました。ファイル一覧を更新すると、復元した名前が表示されます。")
                    alert.alertStyle = failed > 0 ? .warning : .informational
                    alert.addButton(withTitle: local("完成", "Done", "完了"))
                    alert.addButton(withTitle: local("查看結果", "Show results", "結果を表示"))
                    alert.beginSheetModal(for: window) { [self] response in
                        if response == .alertSecondButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([receipt]) }
                        finished()
                    }
                }
            } catch {
                DispatchQueue.main.async { [self] in hideProgress(); showError(error) }
            }
        }
    }

    private func showProgress(_ text: String) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 100),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = local("修復未完成的本機複製", "Recover unfinished local copies", "未完了のローカルコピーを復元")
        let indicator = NSProgressIndicator(frame: NSRect(x: 22, y: 36, width: 24, height: 24))
        indicator.style = .spinning; indicator.controlSize = .regular; indicator.startAnimation(nil)
        let label = NSTextField(wrappingLabelWithString: text)
        label.frame = NSRect(x: 62, y: 24, width: 354, height: 48)
        label.font = .systemFont(ofSize: 13); label.maximumNumberOfLines = 3
        panel.contentView?.addSubview(indicator); panel.contentView?.addSubview(label)
        progress = panel; window.beginSheet(panel)
    }

    private func hideProgress() {
        if let panel = progress { window.endSheet(panel); panel.orderOut(nil) }
        progress = nil
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = local("本次修復未完成", "Recovery did not finish", "復元が完了しませんでした")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: local("好", "OK", "OK"))
        alert.beginSheetModal(for: window) { [self] _ in finished() }
    }
}

/// Also available for reproducible native integration tests and scripted use.
/// No shell interpolation or file mutation occurs before the selected action.
enum RBNPartialRecoveryCLI {
    static func runIfRequested(_ arguments: [String]) -> Int32? {
        guard arguments.first == "--repair-local-partials" else { return nil }
        do {
            guard arguments.count == 6, ["preview", "apply"].contains(arguments[1]) else {
                throw EngineError("用法：--repair-local-partials preview --report <JSONL> --plan <新檔案>，或 apply --plan <計畫> --receipt <新檔案>。")
            }
            var values: [String: URL] = [:]
            for index in stride(from: 2, to: arguments.count, by: 2) {
                guard values[arguments[index]] == nil, arguments[index + 1].hasPrefix("/") else {
                    throw EngineError("請使用不重複的參數與絕對路徑。")
                }
                values[arguments[index]] = URL(fileURLWithPath: arguments[index + 1])
            }
            let result: [String: Any]
            if arguments[1] == "preview", let report = values["--report"], let plan = values["--plan"], values.count == 2 {
                result = try EnginePartialRecovery.preview(report: report, plan: plan)
            } else if arguments[1] == "apply", let plan = values["--plan"], let receipt = values["--receipt"], values.count == 2 {
                result = try EnginePartialRecovery.apply(plan: plan, receipt: receipt)
            } else { throw EngineError("修復參數不正確。") }
            var data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            data.append(10); try FileHandle.standardOutput.write(contentsOf: data)
            let failed = ((result["counts"] as? [String: Any])?["failed"] as? NSNumber)?.intValue ?? 0
            return failed == 0 ? 0 : 1
        } catch {
            if var data = try? JSONSerialization.data(withJSONObject: ["error": error.localizedDescription], options: [.sortedKeys]) {
                data.append(10); try? FileHandle.standardError.write(contentsOf: data)
            }
            return 2
        }
    }
}
#endif
