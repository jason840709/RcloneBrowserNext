import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Tests the native display boundary, independent of rclone or a GUI. User file
/// names and provider diagnostics must survive localization byte for byte.
@main struct NativeMessagesTests {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static var passed = 0
    private static var failed = 0

    private static func expect(_ actual: String, _ expected: String) throws {
        guard Array(actual.utf8) == Array(expected.utf8) else {
            throw Failure(description: "expected \(String(reflecting: expected)), got \(String(reflecting: actual))")
        }
    }

    private static func test(_ name: String, _ body: () throws -> Void) {
        do { try body(); passed += 1; print("PASS \(name)") }
        catch { failed += 1; print("FAIL \(name): \(error)") }
    }

    static func main() {
        test("Traditional Chinese and unsupported language preserve original bytes") {
            for original in ["找不到 rclone。", "來源：/作業/好\n目標：NAS:取消", "ERROR : 更新.txt: denied", "e\u{301} / é"] {
                try expect(RBNNativeStrings.translate(original, language: "zh-TW"), original)
                try expect(RBNNativeStrings.translate(original, language: "unsupported"), original)
            }
        }

        test("Settings, transfer, tools, updater and Finder errors have English and Japanese") {
            let cases: [(String, String, String)] = [
                ("設定已在其他操作中更新，請重新整理後再試。", "Another operation updated the settings. Refresh and try again.", "別の操作で設定が更新されました。再読み込みしてからお試しください。"),
                ("同步需要列出目的地，不能使用「不掃描目的地」。", "Sync needs a destination listing. Turn off 'Do not scan destination'.", "同期には転送先の一覧が必要です。「転送先を走査しない」をオフにしてください。"),
                ("公開連結只適用於支援分享功能的雲端位置。", "Public links are available only for cloud locations that support sharing.", "公開リンクは、共有に対応するクラウドでのみ作成できます。"),
                ("下載檔的 SHA-256 不符，已停止安裝。", "The download SHA-256 does not match. Installation stopped.", "ダウンロードしたファイルの SHA-256 が一致しないため、インストールを停止しました。"),
                ("更新檢查目前不支援 https:// 代理位址。請改用 http:// 或 socks5://；rclone 傳輸仍可使用 https:// 代理。", "Update checks do not currently support https:// proxy addresses. Use http:// or socks5:// for updates; rclone transfers can still use an https:// proxy.", "更新確認では現在 https:// のプロキシアドレスに対応していません。更新には http:// または socks5:// を使用してください。rclone の転送では引き続き https:// プロキシを使用できます。"),
                ("請拖入原始檔案或資料夾；拖放不會跟隨符號連結。", "Drag the original file or folder. Drag and drop does not follow symbolic links.", "元のファイルまたはフォルダをドラッグしてください。ドラッグ＆ドロップではシンボリックリンクをたどりません。"),
                ("同步會刪除目的地中來源沒有的檔案；本次未設定刪除數量上限。", "Sync deletes destination files absent from the source. No deletion limit is set for this run.", "同期では転送元に存在しない転送先のファイルを削除します。今回は削除数の上限を設定していません。")
            ]
            for (source, english, japanese) in cases {
                try expect(RBNNativeStrings.translate(source, language: "en"), english)
                try expect(RBNNativeStrings.translate(source, language: "ja"), japanese)
                try expect(RBNNativeStrings.translate(source, language: "zh-TW"), source)
            }
        }

        test("Source and destination preserve Japanese, quotes, braces and newlines") {
            let source = "/Volumes/作業/好 \"見本\"/[1] {} $/改行\n次の行/e\u{301}"
            let destination = "NAS:取消/資料 '2026'\\v2\n新規"
            let message = "來源：\(source)\n目標：\(destination)"
            try expect(RBNNativeStrings.translate(message, language: "en"), "Source: \(source)\nDestination: \(destination)")
            try expect(RBNNativeStrings.translate(message, language: "ja"), "転送元：\(source)\n転送先：\(destination)")
            try expect(RBNNativeStrings.translate("來源：好\n目標：取消", language: "en"), "Source: 好\nDestination: 取消")
        }

        test("Captured file names never recursively become translated app labels") {
            try expect(RBNNativeStrings.translate("無法寫入 取消。", language: "en"), "Could not write 取消.")
            try expect(RBNNativeStrings.translate("無法寫入 設定檔。", language: "ja"), "設定檔 に書き込めません。")
            try expect(RBNNativeStrings.translate("「好」已不存在或類型已改變，請重新整理。", language: "ja"), "「好」が存在しないか、種類が変更されています。一覧を更新してください。")
            try expect(RBNNativeStrings.translate("找不到遠端連線「更新」，請重新整理。", language: "en"), "Remote '更新' was not found. Refresh the list.")
            try expect(RBNNativeStrings.translate("不支援的操作：取消", language: "en"), "Unsupported operation: 取消")
        }

        test("Only explicit field labels and missing-version status translate inside captures") {
            try expect(RBNNativeStrings.translate("介面比例 必須介於 80 與 125。", language: "en"), "Interface scale must be between 80 and 125.")
            try expect(RBNNativeStrings.translate("平行傳輸數 必須介於 1 與 64。", language: "en"), "Parallel transfers must be between 1 and 64.")
            try expect(RBNNativeStrings.translate("欄寬 必須介於 76 與 400。", language: "ja"), "列幅は 76 から 400 の範囲で指定してください。")
            try expect(RBNNativeStrings.translate("設定檔必須使用絕對路徑。", language: "ja"), "設定ファイルには絶対パスを指定してください。")
            let message = "目前：尚未安裝\n新版：v1.75.2\n\n存放位置：尚未安裝"
            try expect(RBNNativeStrings.translate(message, language: "en"), "Current: Not installed\nLatest: v1.75.2\n\nLocation: 尚未安裝")
            try expect(RBNNativeStrings.translate(message, language: "ja"), "現在：未インストール\n最新：v1.75.2\n\n保存先：尚未安裝")
        }

        test("HTTP codes, download counts and macOS versions remain exact") {
            let archive = "rclone-v1.75.2-osx-arm64-更新.zip"
            try expect(RBNNativeStrings.translate("rclone 官方下載站回傳 HTTP 429（\(archive)）。請稍後重試。", language: "en"), "The official rclone server returned HTTP 429 (\(archive)). Try again later.")
            try expect(RBNNativeStrings.translate("rclone 官方下載站回傳 HTTP 503（\(archive)）。請稍後重試。", language: "ja"), "rclone 公式サーバーから HTTP 503（\(archive)）が返されました。しばらくしてから再試行してください。")
            try expect(RBNNativeStrings.translate("下載回應超過允許大小（536870913 bytes；上限 536870912 bytes）。已停止下載。", language: "en"), "Download exceeds the size limit (536870913 bytes; limit 536870912 bytes). Download stopped.")
            try expect(RBNNativeStrings.translate("這個官方 rclone 執行檔需要 macOS 15.4.1，高於目前系統。原本的 rclone 保持不變；你可以選擇另一個相容版本。", language: "ja"), "この公式 rclone 実行ファイルには、現在のシステムより新しい macOS 15.4.1 が必要です。既存の rclone は変更していません。対応する別のバージョンを選択できます。")
        }

        test("Unknown provider diagnostics keep embedded file names and JSON verbatim") {
            let diagnostics = [
                "ERROR : 取消: Failed to copy: permission denied",
                "2026/10/20 01:02:03 ERROR : 無法寫入 取消。: Failed to open file",
                "{\"level\":\"error\",\"msg\":\"好\",\"object\":\"設定檔\"}\n",
                "Failed to read \"/日本語/找不到 rclone。\": permission denied\nmore details",
                "GET https://example.invalid/更新?q=取消 returned 403",
                "provider says: 來源：好\n目標：取消"
            ]
            for diagnostic in diagnostics {
                for language in ["zh-TW", "en", "ja"] {
                    try expect(RBNNativeStrings.translate(diagnostic, language: language), diagnostic)
                }
            }
        }

        test("Engine wrappers localize while multiline backend output remains literal") {
            let diagnostic = "ERROR : \"/日本語/取消\": denied\n找不到 rclone。\n好\n"
            let message = "rclone 執行失敗（代碼 3）：\n\(diagnostic)"
            try expect(RBNNativeStrings.translate(message, language: "en"), "rclone failed (code 3):\n\(diagnostic)")
            try expect(RBNNativeStrings.translate(message, language: "ja"), "rclone の実行に失敗しました（コード 3）：\n\(diagnostic)")
            try expect(RBNNativeStrings.translate("無法啟動 rclone：找不到 rclone。", language: "en"), "Could not start rclone: 找不到 rclone。")
        }

        test("Specific tool wrappers win over code-only variants without changing stderr") {
            let detail = "好\nERROR : 取消: denied\n找不到 rclone。"
            let message = "讀取目錄樹失敗（代碼 3）。\n\(detail)"
            try expect(RBNNativeStrings.translate(message, language: "en"), "Could not read the directory tree (code 3).\n\(detail)")
            try expect(RBNNativeStrings.translate(message, language: "ja"), "ディレクトリツリーを読み取れませんでした（コード 3）。\n\(detail)")
            try expect(RBNNativeStrings.translate("建立公開連結失敗（代碼 7）。", language: "ja"), "公開リンクを作成できませんでした（コード 7）。")
        }

        test("Deletion confirmation preserves every selected filename") {
            let location = "NAS:/日本語/好"
            let names = "取消\n見本 \"01\".txt\n更新"
            let message = "位置：\(location)\n\n\(names)\n\n將刪除 3 個選取項目。這項操作不會移到垃圾桶。"
            try expect(RBNNativeStrings.translate(message, language: "en"), "Location: \(location)\n\n\(names)\n\nDelete 3 selected items. Items are not moved to Trash.")
            try expect(RBNNativeStrings.translate(message, language: "ja"), "場所：\(location)\n\n\(names)\n\n選択した 3 個の項目を削除します。ゴミ箱には移動しません。")
        }

        test("Ambiguous path separators preserve the complete original message") {
            let source = "/資料/第一行\n目標：這也是檔名"
            let message = "來源：\(source)\n目標：NAS:/備份"
            try expect(RBNNativeStrings.translate(message, language: "en"), message)
            try expect(RBNNativeStrings.translate(message, language: "ja"), message)
            let wrapped = "讀取目錄樹失敗（代碼 3）。\nfilename）。\n找不到 rclone。"
            try expect(RBNNativeStrings.translate(wrapped, language: "en"), wrapped)
        }

        test("Absolute anchors do not partially translate trailing or prefixed diagnostics") {
            for message in ["已跳過 v1.75.2。\n", "prefix 已跳過 v1.75.2。", "rclone 正在更新。\n", "已跳過 v1.75.2。suffix"] {
                try expect(RBNNativeStrings.translate(message, language: "en"), message)
                try expect(RBNNativeStrings.translate(message, language: "ja"), message)
            }
        }

        test("Unknown and oversized messages use stable fallback") {
            let huge = "無法啟動 rclone：" + String(repeating: "日本語\n", count: 20000)
            try expect(RBNNativeStrings.translate(huge, language: "ja"), huge)
            try expect(RBNNativeStrings.japanese("Unknown provider diagnostic", fallback: "English fallback"), "English fallback")
            try expect(RBNNativeStrings.japanese("選擇 rclone 執行檔", fallback: "English fallback"), "rclone 実行ファイルを選択")
        }

        print("\nNativeMessagesTests: \(passed) passed, \(failed) failed, 0 skipped")
        if failed > 0 { exit(1) }
    }
}
