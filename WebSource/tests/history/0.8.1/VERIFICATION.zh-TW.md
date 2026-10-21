# 0.8.1 介面驗證

完整測試 **181／181 通過**，沒有失敗、略過或重試。開始時間為 **2026-10-20T19:10:20.142Z**，耗時 **166.4 秒**。執行前 TypeScript 檢查與正式 Web 建置皆通過。

本輪使用 **Linux、Chrome Headless Shell 156.0.8078.4**，直接載入正式 `Resources/Web/index.html`，由固定資料的 native bridge fixture 提供回覆。[驗證紀錄](verification.json) 包含成品與來源雜湊、全部逐項結果及截圖雜湊。正式成品與來源的雜湊在完整測試前後保持一致。

## 新增的 5 個導航案例

`revision081-navigation.spec.ts` 驗證正式 React 介面收到原生導航訊息後的行為：

- swipe 訊息操作游標所在窗格，左右窗格各自保留下一頁歷史。
- 同一訊息重複送達只退一頁；快速送出的兩個不同訊息都會執行。
- 原生命令操作目前作用中的窗格，輸入中的路徑或可編輯文字保持不變；滑鼠 swipe 仍可指定另一窗格。
- 操作選項對話框開啟時，swipe 與前進／後退命令不切換資料夾。
- 一般水平滾輪不改變資料夾歷史。

較早的導航專項測試 **16／16 通過**，包含這 5 個新案例及既有滑鼠／鍵盤回歸。該次發生在最後的圖示與版本文字重建之前；本文件記錄的正式成品雜湊，以本輪完整 181 項結果為準。

## 既有功能與畫面

完整測試保留資料夾切換的清單連續顯示、過期回覆保護、窗格與分頁的獨立歷史、六主題、三語言、緊湊視窗、位置選單下方開啟與捲動、儲存作業、傳輸選項、逐檔紀錄、佇列操作及平台入口。初始畫面案例核對 native bridge 初始化前的主題與背景色，以及最初數個動畫畫格的主題與背景色一致性。

標準介面大小為 80%、90%、100%、110%、125%，實際 WebView 比例為 `(顯示值 - 10) / 100`：100% 使用 0.90，110% 使用 1.00。已選中的舊值 120% 或 135% 仍會顯示，改選標準值後移除額外選項。

本輪產生 **79 張截圖**。其中 **6 張已直接檢視**，觀察結果及對應雜湊記錄於 JSON。兩個 100,000 檔案窗格收到 25 次進度更新時，完整清單的 map/filter/sort 次數為 **0**；本輪測得 **404.2 ms**。

## Mac 原生驗證

本 Web 紀錄產生時，Mac 原生 CI 尚待完成。`Scripts/test-mac.sh` 另外執行 `MacInterfaceTests`、`MacStartupTests`、`MacIconTests`、`MacNavigationIntegrationTests`，涵蓋 AppKit 輸入、原生啟動畫面、執行期間的主題圖示與 App 簽章，以及正式 React／WKWebView／Core 引擎的資料夾導航。原生 swipe 測試使用 `NSEvent` 測試替身；本輪 Web 測試沒有操作實體 MX Master 3S 或 Logi Options+。

[0.8.0 完整紀錄](history/0.8.0/verification.json) 已原樣保存，另保留 [0.7.0](history/0.7.0/verification.json)、[0.6.0](history/0.6.0/verification.json) 與[接續工作前的 0.7.0](history/0.7.0-before-recovery/verification.json)。重現指令見[英文說明](README.md)。瀏覽器、Playwright 版本與 Noto CJK 字型雜湊記錄於 JSON。
