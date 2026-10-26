#if os(macOS)
import Foundation
@preconcurrency import AppKit
import UniformTypeIdentifiers

/// A native, report-scoped recovery flow. Preview is read-only; apply always
/// revalidates the saved plan and uses an exclusive rename or verified new-file copy.
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
            "來源：\(source)\n目的：\(destination)\n\n內容完全一致：\(ready)\n正式檔名已存在：\(existing)\n內容不一致：\(mismatch)\n無法核對：\(blocked)\n\n支援安全改名時會直接恢復；不支援時會以正確檔名建立新檔，核對完整內容，並保留原 .partial 檔案，因此需要額外空間。中斷或寫入失敗的新檔不計為已修復。來源與既有正式檔案保持原樣。修復期間請暫停其他程式對這兩個位置的寫入。",
            "Source: \(source)\nDestination: \(destination)\n\nIdentical contents: \(ready)\nFinal name already exists: \(existing)\nDifferent contents: \(mismatch)\nCould not verify: \(blocked)\n\nRecovery uses a no-overwrite rename when supported. Otherwise it creates and fully verifies a file with the correct name, keeping the original .partial file; this needs additional space. Interrupted or incomplete new files are not counted as recovered. Sources and existing final files stay unchanged. Pause writes to these locations from other apps during recovery.",
            "元：\(source)\n先：\(destination)\n\n内容一致：\(ready)\n正式名が存在：\(existing)\n内容不一致：\(mismatch)\n照合できない項目：\(blocked)\n\n安全な名前変更が可能な場合は直接復元します。対応していない場合は正式名で新しいファイルを作成し、内容全体を照合して元の .partial を残すため、追加の空き容量が必要です。中断または書き込みに失敗した新規ファイルは復元済みに数えません。元のファイルや既存の正式名ファイルは変更しません。復元中はほかのアプリから両方の場所への書き込みを停止してください。")
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
        showProgress(local("正在核對、恢復或重新建立檔案…", "Verifying, recovering or rebuilding files…", "ファイルを照合、復元または再作成しています…"))
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                let receipt = directory.appendingPathComponent("recovery-result.json")
                let result = try EnginePartialRecovery.apply(plan: plan, receipt: receipt)
                DispatchQueue.main.async { [self] in
                    hideProgress()
                    showRecoveryResult(result, receipt: receipt)
                }
            } catch {
                DispatchQueue.main.async { [self] in hideProgress(); showError(error) }
            }
        }
    }

    private func showRecoveryResult(_ result: [String: Any], receipt: URL) {
        let counts = result["counts"] as? [String: Any] ?? [:]
        let recovered = (counts["recovered"] as? NSNumber)?.intValue ?? 0
        let renamed = (counts["renamed"] as? NSNumber)?.intValue ?? 0
        let rebuilt = (counts["rebuilt"] as? NSNumber)?.intValue ?? 0
        let retained = (counts["retainedPartials"] as? NSNumber)?.intValue ?? 0
        let skipped = (counts["skipped"] as? NSNumber)?.intValue ?? 0
        let failed = (counts["failed"] as? NSNumber)?.intValue ?? 0
        let failedNewOutputs = (counts["failedNewOutputs"] as? NSNumber)?.intValue ?? 0
        let alert = NSAlert()
        alert.messageText = local("已修復 \(recovered) 個檔案", "Recovered \(recovered) files", "\(recovered) 個のファイルを復元しました")
        alert.informativeText = local("直接恢復：\(renamed)\n重新建立：\(rebuilt)\n保留暫存原檔：\(retained)\n略過：\(skipped)\n未完成：\(failed)\n\n逐檔結果已保存。回到清單後按重新整理即可查看。",
                                     "Renamed: \(renamed)\nRebuilt: \(rebuilt)\nOriginal temporary files retained: \(retained)\nSkipped: \(skipped)\nNot recovered: \(failed)\n\nPer-file results have been saved. Refresh the file list to view the results.",
                                     "直接復元：\(renamed)\n再作成：\(rebuilt)\n保持した元の一時ファイル：\(retained)\nスキップ：\(skipped)\n未完了：\(failed)\n\n各ファイルの結果を保存しました。一覧を更新して確認してください。")
        if rebuilt > 0 {
            alert.informativeText += local("\n\n重新建立的正式檔案已完成內容核對，對應的原 .partial 檔案仍會保留。",
                                           "\n\nRebuilt final files have passed full content verification; their original .partial files remain.",
                                           "\n\n再作成した正式名のファイルは内容全体を照合済みで、対応する元の .partial は保持されています。")
        }
        if failedNewOutputs > 0 {
            alert.informativeText += local("\n\n有 \(failedNewOutputs) 個新建檔案未完成，請依結果報告確認；這些項目不計入已修復，來源及暫存原檔仍保留。",
                                           "\n\n\(failedNewOutputs) newly created files are incomplete. Check the results report; they are not counted as recovered, and their sources and original temporary files remain.",
                                           "\n\n\(failedNewOutputs) 個の新規ファイルが未完了です。結果レポートを確認してください。復元済みには数えず、元のファイルと一時ファイルは保持されています。")
        }
        alert.alertStyle = failed > 0 ? .warning : .informational
        alert.addButton(withTitle: local("完成", "Done", "完了"))
        alert.addButton(withTitle: local("查看結果", "Show results", "結果を表示"))
        if rebuilt > 0 {
            alert.addButton(withTitle: local("清理已核對暫存檔…", "Clean up verified temporary files…", "照合済み一時ファイルを削除…"))
        }
        alert.beginSheetModal(for: window) { [self] response in
            if rebuilt > 0, response == .alertThirdButtonReturn {
                confirmCleanup(receipt, maximum: rebuilt)
                return
            }
            if response == .alertSecondButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([receipt])
                DispatchQueue.main.async { [self] in showRecoveryResult(result, receipt: receipt) }
                return
            }
            finished()
        }
    }

    private func confirmCleanup(_ receipt: URL, maximum: Int) {
        let alert = NSAlert()
        alert.messageText = local("清理最多 \(maximum) 個已核對暫存檔？",
                                  "Clean up up to \(maximum) verified temporary files?",
                                  "照合済み一時ファイルを最大 \(maximum) 個削除しますか？")
        alert.informativeText = local(
            "會再次核對來源、已修復的正式檔案與對應 .partial 的身分及完整內容；有變動就保留。只清理本次成功重新建立後留下的目的暫存檔，來源及正式檔案都會保留。這可避免下次同步再次嘗試刪除鎖定暫存檔而報錯。\n\n清理期間請繼續暫停其他程式對這兩個位置的寫入。",
            "Sources, recovered final files and matching .partial files will be checked again for identity and complete contents. Changed items will be kept. Only destination temporary files left by this successful rebuild will be removed; sources and final files remain. This prevents a later sync from failing while trying to delete those locked temporary files.\n\nKeep writes to these locations from other apps paused during cleanup.",
            "元のファイル、復元済みの正式名ファイル、対応する .partial の識別情報と内容全体を再照合します。変更があれば保持します。今回の再作成に成功した後に残った転送先の一時ファイルだけを削除し、元のファイルと正式名ファイルは保持します。次回の同期でロックされた一時ファイルの削除が失敗することを防ぎます。\n\n削除中も、ほかのアプリから両方の場所への書き込みを停止したままにしてください。")
        alert.addButton(withTitle: local("清理已核對暫存檔", "Clean up verified temporary files", "照合済み一時ファイルを削除"))
        alert.addButton(withTitle: local("保留暫存檔", "Keep temporary files", "一時ファイルを保持"))
        alert.beginSheetModal(for: window) { [self] response in
            if response == .alertFirstButtonReturn { cleanup(receipt) }
            else { finished() }
        }
    }

    private func cleanup(_ receipt: URL) {
        showProgress(local("正在重新核對並清理已修復的暫存檔…",
                           "Rechecking and cleaning up recovered temporary files…",
                           "復元済みの一時ファイルを再照合して削除しています…"))
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                let output = directory.appendingPathComponent("recovery-cleanup.json")
                let result = try EnginePartialRecovery.cleanup(receipt: receipt, result: output)
                DispatchQueue.main.async { [self] in
                    hideProgress()
                    let counts = result["counts"] as? [String: Any] ?? [:]
                    let removed = (counts["removed"] as? NSNumber)?.intValue ?? 0
                    let skipped = (counts["skipped"] as? NSNumber)?.intValue ?? 0
                    let failed = (counts["failed"] as? NSNumber)?.intValue ?? 0
                    let alert = NSAlert()
                    alert.messageText = local("已清理 \(removed) 個暫存檔", "Cleaned up \(removed) temporary files", "\(removed) 個の一時ファイルを削除しました")
                    alert.informativeText = local("保留／略過：\(skipped)\n未完成：\(failed)\n\n來源及已修復的正式檔案保持原樣。重新整理檔案清單即可查看結果。",
                                                 "Kept or skipped: \(skipped)\nNot completed: \(failed)\n\nSources and recovered final files remain unchanged. Refresh the file list to view the results.",
                                                 "保持・スキップ：\(skipped)\n未完了：\(failed)\n\n元のファイルと復元済みの正式名ファイルは変更していません。一覧を更新して結果を確認してください。")
                    alert.alertStyle = failed > 0 ? .warning : .informational
                    alert.addButton(withTitle: local("完成", "Done", "完了"))
                    alert.addButton(withTitle: local("查看結果", "Show results", "結果を表示"))
                    alert.beginSheetModal(for: window) { [self] response in
                        if response == .alertSecondButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([output]) }
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
        if FileManager.default.fileExists(atPath: directory.path) {
            alert.addButton(withTitle: local("查看操作紀錄", "Show recovery records", "操作記録を表示"))
        }
        alert.beginSheetModal(for: window) { [self] response in
            if response == .alertSecondButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
            finished()
        }
    }
}

/// Also available for reproducible native integration tests and scripted use.
/// No shell interpolation or file mutation occurs before the selected action.
enum RBNPartialRecoveryCLI {
    static func runIfRequested(_ arguments: [String]) -> Int32? {
        guard arguments.first == "--repair-local-partials" else { return nil }
        do {
            guard arguments.count == 6, ["preview", "apply", "cleanup"].contains(arguments[1]) else {
                throw EngineError("用法：--repair-local-partials preview --report <JSONL> --plan <新檔案>，apply --plan <計畫> --receipt <新檔案>，或 cleanup --receipt <已完成收據> --result <新檔案>。CLI 的 apply／cleanup 會直接執行，不顯示確認視窗；執行前請先停止 App 傳輸及其他程式對來源、目的位置的寫入。")
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
            } else if arguments[1] == "cleanup", let receipt = values["--receipt"], let output = values["--result"], values.count == 2 {
                result = try EnginePartialRecovery.cleanup(receipt: receipt, result: output)
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
