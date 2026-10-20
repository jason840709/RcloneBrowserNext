# Rclone Browser Next 0.7.0 驗證記錄

0.7.0 的驗證來源分成正式 Web 介面、共用 Swift 核心，以及各平台原生建置。過去版本的結果保留於 [0.6.0 驗證記錄](VALIDATION_0.6.0.zh-TW.md)，不計入本版通過數。

## 驗證流程

| 範圍 | 方法 |
| --- | --- |
| 位置選單與介面 | 從正式 bundle 檢查長清單、五段縮放、三語視窗、鍵盤選取及傳輸報告 |
| 核心傳輸 | 使用真實 rclone 與獨立測試資料夾，檢查複製、同步、移動、重試、停止與設定保存 |
| 報告 | 檢查設定快照、重試分類、成功／失敗副本的大小、連結與活動來源；穩定檔案第二次同步應為 0 傳輸 |
| Mac arm64／x86_64 | 各自原生編譯、完整 App 簽章檢查、八套 Swift 測試及 WKWebView 實測 |
| Windows／Linux | 各自原生建置安裝檔，檢查基本檔案操作、本機傳輸及取消，開啟原生視窗驗證正式介面的橋接 |

正式發布由 [GitHub Actions](https://github.com/jason840709/RcloneBrowserNext/actions) 的四平台建置共同把關。介面案例和雜湊保留於 [Web 驗證記錄](../WebSource/tests/VERIFICATION.zh-TW.md)，相容版測試結果與執行階段清單保留在每次 Actions artifacts。

測試資料使用獨立本機資料夾、alias 遠端、loopback 回應與示意介面資料；使用者的 NAS 及雲端帳號不參與自動化測試。
