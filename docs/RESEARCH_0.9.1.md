# 0.9.1 設計筆記：完成提醒、未知總量進度與三平台版本整合

## 1. Mac 背景完成 Dock 跳動提醒

原版 Rclone Browser（`src/main_window.cpp`）在工作完成時會呼叫 Qt 的 `qApp->alert(this)` 讓 macOS Dock 圖示跳動：

- [原版 `src/main_window.cpp`](https://github.com/kapitainsky/RcloneBrowser/blob/45bf7411839b0919c488a3e3a0a5272b50c9fc7b/src/main_window.cpp)
- [Qt 5 `QApplication::alert`](https://doc.qt.io/archives/qt-5.15/qapplication.html#alert)
- [Apple `NSApplication.RequestUserAttentionType`](https://developer.apple.com/documentation/appkit/nsapplication/requestuserattentiontype/informationalrequest)

Next 在 `Sources/Mac/CompletionAttention.swift` 直接透過 AppKit 呼叫 `NSApplication.requestUserAttention`：

- 「在背景完成或失敗時，讓 Dock 圖示跳動提示」預設開啟（可於「設定 → 介面 → 背景執行」關閉），不需請求系統橫幅通知權限。
- 僅在背景完成或失敗時觸發；視窗已在前景、預演（Dry Run）或手動取消的工作不會觸發，一秒內多項工作同時結束也會自動合併提醒。

## 2. 未知總量時的進度條動畫

當工作剛開始掃描比對、尚未算出總位元組數與總檔案數時，進度條會顯示一段 1/4 軌道寬度的色塊以 1.6 秒週期來回移動（純 CSS `transform` 動畫）；一旦取得總量即切換為實際百分比，排隊中或已結束的工作則不顯示動畫（開啟系統「減少動態效果」時改為固定色塊）。

## 3. 統一三平台版本號

自 0.9.1 起，Mac、Windows 與 Linux 重新統一為單一版本號，將 Windows `0.9.0+1`（R1）的原生本機目錄列舉、64 位元檔案大小與磁碟根路徑修正正式併入主線，並由 `Scripts/verify-version.py` 與跨平台 CI 統一驗證。
