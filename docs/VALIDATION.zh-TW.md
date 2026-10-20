# Rclone Browser Next 0.7.0 驗證記錄

以下為 0.7.0 已完成的本機驗證及四平台 CI 進度。過去版本的結果保留於 [0.6.0 驗證記錄](VALIDATION_0.6.0.zh-TW.md)，不計入本版通過數。

## 已完成的本機驗證

2026-10-20 在 Linux x86_64 完成下列測試。Web 測試載入正式 bundle；Swift 測試使用 Swift 6.0.3，傳輸案例使用真實 rclone 1.75.2。

| 範圍 | 結果 | 已驗證的行為 |
| --- | --- | --- |
| Web 介面 | 163／163 通過 | 位置選單固定在圖示下方、長清單內部捲動、鍵盤與輸入法、五段縮放、三語視窗、傳輸報告及各平台功能入口 |
| CoreTests | 56／56 通過 | 檔案操作、複製與同步、選取範圍、停止與佇列控制、設定與工作保存 |
| NativeMessagesTests | 13／13 通過 | 三語訊息、操作範圍，以及檔名與外部診斷內容的保存 |
| TransferReportTests | 25／25 通過 | 比對與傳輸結果分列、重試事件、成功與失敗副本大小、報告匯出、第二次同步及符號連結 |
| Linux 相容版 helper | 8／8 通過 | 啟動與檔案清單、預覽、複製、第二次同步、報告與工作匯入匯出、取消及重新啟動後的狀態 |

Web 的型別檢查與正式建置也已通過；163 個案例沒有略過或重試。CoreTests、NativeMessagesTests 與 TransferReportTests 均為 0 失敗、0 略過。Core 與 NativeMessages 的執行紀錄確認測試期間原始碼未變動；整理本頁時，也已核對 Web、Core 與相容版 helper 的原始碼雜湊。

穩定資料回歸使用三個測試檔：第一次複製傳輸兩個檔案，第二次同步傳輸 **0 個檔案**，三個檔案均比對相符，並刪除一個僅存在於目標的測試檔。符號連結案例驗證本機連結保存，以及用本機後端模擬 `.rclonelink` 檔案的儲存與還原。

介面案例與正式 bundle 雜湊見 [Web 驗證記錄](../WebSource/tests/VERIFICATION.zh-TW.md)；各組結果與證據雜湊見 [0.7.0 本機驗證摘要](verification/0.7.0-local.json)。

## 四平台 CI

[本輪 GitHub Actions](https://github.com/jason840709/RcloneBrowserNext/actions/runs/39446359319) 的建置與測試仍在進行，以下項目待完整結果：

| 平台 | 待完成的驗證 |
| --- | --- |
| macOS arm64 | 原生編譯、完整 App 簽章檢查、八套 Swift 測試及 WKWebView 實測 |
| macOS x86_64 | 原生編譯、完整 App 簽章檢查、八套 Swift 測試及 WKWebView 實測 |
| Windows x86_64 | 安裝檔建置、基本檔案操作、本機傳輸與取消、原生視窗及介面橋接 |
| Linux x86_64 | 安裝檔建置、基本檔案操作、本機傳輸與取消、原生視窗及介面橋接 |

相容版測試結果與執行階段清單保留在每次 Actions artifacts。本頁的自動化測試使用獨立本機資料夾、alias 遠端、loopback 回應與示意介面資料。
