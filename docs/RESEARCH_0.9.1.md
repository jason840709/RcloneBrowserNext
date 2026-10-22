# 0.9.1：完成提醒、讀取動畫與版本整合

## 原版怎麼提醒

檢查 kapitainsky/RcloneBrowser 的 `45bf7411839b0919c488a3e3a0a5272b50c9fc7b`，`src/main_window.cpp` 在 `JobWidget::finished` 事件內、完成通知開啟時呼叫 `qApp->alert(this)`，接著顯示系統匣訊息。

Qt 5 的 `QApplication::alert` 文件說明，macOS 會讓 Dock 圖示跳動；視窗已在前景時不提醒。Next 的 Mac 主程式使用 AppKit，因此直接呼叫 `NSApplication.requestUserAttention(.informationalRequest)`，不引入 Qt。

- [原版事件處理](https://github.com/kapitainsky/RcloneBrowser/blob/45bf7411839b0919c488a3e3a0a5272b50c9fc7b/src/main_window.cpp)
- [Qt 5 QApplication::alert](https://doc.qt.io/archives/qt-5.15/qapplication.html#alert)
- [Apple informationalRequest](https://developer.apple.com/documentation/appkit/nsapplication/requestuserattentiontype/informationalrequest)

Apple 將 informational request 定義為短暫的一秒提示。Dock 的實際呈現仍由 macOS 控制；程式不自行繪製 Dock，不切換視窗、不搶鍵盤焦點，也不使用持續跳動的 critical request。

## Next 的行為

`Sources/Mac/CompletionAttention.swift` 專門處理提醒的判斷與去重。主程式只把本次執行的引擎事件交給它，不把啟動時載入的歷史工作當成新完成事件。

- 「在背景完成或失敗時，讓 Dock 圖示跳動提示」預設開啟，僅 Mac 顯示這個開關。
- 系統橫幅與聲音仍由原有的 `notifyOnCompletion` 控制，維持原先預設關閉。Dock 不需要橫幅通知授權。
- 同一工作只處理一次；一秒內多個工作結束共用同一次提示。
- 預演、取消、暫停與結束程式過程不觸發。程式回到前景或退出時取消尚存的 attention request。
- Mac 原生測試包含可注入的請求／取消計數，以及真正 AppKit API 的呼叫；它不是 Dock 像素或使用者系統偏好設定的全面驗證。

## 未知總量進度

舊斑馬紋出現在工作沒有正的總位元組數與總傳輸檔案數時，不能當成百分比。新版保留這個判斷，執行中或停止處理中顯示四分之一軌道長的色塊，以 1.6 秒單程往返。動畫只用 CSS transform，不新增計時器、磁碟掃描或檔案內容讀取。

排隊時顯示排隊狀態而不動畫；取得總量後切回實際百分比，完成為 100.0%。失敗、取消、中斷均停止動畫。系統要求減少動態效果時，色塊留在中央，旁邊保留狀態文字。沒有可量化總量時不提供 `aria-valuenow`，避免輔助閱讀器把它讀成確定的百分比。

共用 UI 測試核對六種主題、位置邊界、往返、狀態切換及減少動態效果。Windows／Linux 的原生煙霧測試另在真正 WebView 內確認同一 CSS 動畫會改變 transform；元件狀態測試與原生 CSS 執行測試分開記錄，不把合成資料說成真實雲端傳輸。

## 單一版本來源與平台保護

公開穩定版使用 v0.9.1。Mac、Windows 與 Linux 從同一份來源與共用介面建置。Windows 不再用 `0.9.0+1` 的平台版本覆寫；`Scripts/verify-version.py` 核對版本、識別碼及已通過 R1 驗證的檔案系統程式內容。

R1 的本機列舉、64 位元大小、磁碟根路徑、改名／刪除與 junction 邊界處理保留不變。Windows 安裝測試分別從已發布的 0.9.0 與 R1 升級，檢查安裝前後設定檔位元組及啟動後重載；唯一新增預設值是 Dock 開關，Windows 不顯示也不執行它。

一次性 R1 候選／發布工作流程移出目前檔案樹，歷史標籤仍保留原件。統一工作流程要求共用 UI、兩種 Mac 架構、macOS 26、Windows 安裝與升級、Linux 建置及原生檢查全數通過才發布。
