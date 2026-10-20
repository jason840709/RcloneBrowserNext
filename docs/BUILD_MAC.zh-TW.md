# 在 Mac 建立 Rclone Browser Next

這份交付包包含 Swift 來源、已建好的介面、圖示、測試與建置腳本。它會在你的 Mac 直接產生 `.app`，rclone 與 App 分開。一般建置只使用這台 Mac 已有的 Apple 工具，不下載 Electron、Node.js、npm、Go、Homebrew、SwiftPM 套件或其他執行環境。

本機建置與 GitHub CI 使用同一套腳本。此版的實際編譯、測試結果及尚未實測的環節列在 [驗證記錄](VALIDATION.zh-TW.md)。

## 第一次建立

1. 解壓縮整個來源包，放在要保留且可寫入的資料夾。
2. 若 Next 正在執行，先完成帳號設定或匯出，停止傳輸、串流與掛載，再結束 App。
3. 雙擊 `Build-on-Mac.command`。
4. 成功後，同一個資料夾會出現並開啟 `Rclone Browser Next.app`。
5. 在 App「設定」確認外部 rclone 的位置；已有相容引擎便可直接沿用，沒有才選自己的資料夾並下載。

目標為 macOS 13 以上，預設依實際硬體建立 arm64 或 x86_64。Apple Silicon 即使從 Rosetta Terminal 執行，也優先按實際硬體判斷。既有 Xcode 或 Apple Command Line Tools 必須提供可用 Swift 編譯器與 macOS SDK；缺少時腳本會停止並說明，不代為安裝或升級。

若 Finder 阻擋下載的 command，確認是這份來源包後，可開啟「終端機」，輸入 `/bin/bash `（最後留空白），將 `Build-on-Mac.command` 拖進去再按 Return。這只是明確使用系統 Bash 執行腳本，不停用 Gatekeeper、不清空整個來源資料夾的隔離屬性，也不修改系統信任。

## 保持建置離線

**建置本身不連線下載。** 預設成功後會啟動 App；App 的啟動版本檢查或已保存的遠端瀏覽可能連線。若要整段建置流程都不啟動這些行為，在終端機執行：

```bash
/bin/bash "/你的專案資料夾/Build-on-Mac.command" --no-launch
```

把路徑換成實際位置。此方式只產生及驗證 App，不自動開啟。建置沒有替你安裝 Apple 工具；若系統缺少 SDK，仍需先準備好既有工具。

一般使用者不必重建 React。選擇自行修改介面時，額外的 npm／測試瀏覽器下載屬於開發流程，另見 [開發說明](DEVELOPMENT.md)，不會由 Build-on-Mac 自動執行。

## 檔案位置

| 位置 | 內容 |
| --- | --- |
| 專案內 `Rclone Browser Next.app` | 在這台 Mac 建好的 App |
| 專案內 `.build-cache` | Swift／Clang module cache、編譯暫存、記錄、六套 Swift 測試資料 |
| 專案內 `Distribution` | 本機 App ZIP 與 SHA-256 校驗檔 |
| 專案內 `Backups` | 重新建置前的 App |
| 所選 rclone 資料夾 | 外部引擎、引擎更新暫存及備份 |
| `~/Library/Application Support/Rclone Browser Next Lite` | App 設定、任務、工作記錄與輔助工具暫存／VFS cache |
| 所選 rclone.conf 或 rclone 預設位置 | 雲端帳號設定與權杖 |

建置與測試的依賴、快取、輸出留在專案內，不改 shell 設定，不安裝全域套件，不使用 sudo，也不自動把 App 搬到「應用程式」。App 的正常設定資料仍使用 Application Support；**這不等於完整 portable mode**。macOS 本身的系統記錄、權限資料與開發工具仍由作業系統管理，不能承諾完全沒有任何作業系統記錄。

建置與測試停止後，可以刪除 `.build-cache` 回收空間；下次會重建必要快取。Distribution 和 Backups 可自行保留。不要在 App 有工作時搬動 rclone、掛載快取或目前操作的資料夾。若搬移 `.app`，已保存的 rclone 絕對路徑不會自動跟著改變。

## 重新建置與本機簽章

再次執行 `Build-on-Mac.command` 即可。腳本先在專案內建立 staging App，編譯全部 Core／Mac Swift 檔案，複製 Info.plist、v2 圖示、Web 資源與授權，完成後才簽署整個 App 並驗證。通過後保存舊 App，再換上新版；前半段失敗不覆蓋舊 App。

簽章包含主執行檔、Info.plist 與完整資源。建好後不要直接修改 `.app` 內容；要修改就改來源再重建。rclone 在 App 外，更新引擎不會破壞 App 的資源簽章。

這是 **ad-hoc 本機簽章，沒有 Developer ID，也未經 Apple 公證**。簽章完整與 Gatekeeper 信任不是同一項檢查，不能保證把本機 ZIP 傳給另一台 Mac 就完全不會遇到阻擋。腳本不遞迴移除隔離標籤、不關閉 Gatekeeper、不修改系統安全設定。

## 驗證 App 與執行六套測試

`Verify-App.command` 檢查同資料夾 App 的版本、架構、最低 macOS、依賴、資源及簽章。它不登入雲端、不驗證 Finder 拖放或實際傳輸。

`Test-on-Mac.command` 分別建立、簽署並執行以下六套 Swift 測試：

| 測試 | 用途 |
| --- | --- |
| CoreTests | 檔案／傳輸、選項、任務、設定與取消 |
| UpdaterTests | 版本、下載回應、校驗、備份／替換／還原 |
| ToolsTests | 目錄樹、清單、串流 pipe、停止與失敗清理 |
| NativeMessagesTests | 原生提示翻譯，保留檔名與後端診斷 |
| FinderDropTests | 檔案 URL、來源範圍、類型與符號連結處理 |
| AppReleaseTests | App 正式版本比較、回應驗證、下載頁邊界與錯誤後重試 |

這些測試的資料都在專案 `.build-cache/tests`，不使用日常備份、雲端帳號、現有掛載或既有播放器。完整 rclone 案例需要提供可執行、與本機相容的引擎：

```bash
/bin/bash "/你的專案資料夾/Test-on-Mac.command" "/你選擇的資料夾/rclone"
```

沒有提供 rclone 時，需要真實引擎的案例會清楚標示略過，不代表全部案例通過。NativeMessagesTests 驗證文字邊界，不是 AppKit 視窗測試；FinderDropTests 是檔案資料驗證，不是真正從 Finder 拖動滑鼠。

每次發行的通過數量、測試版本與實際執行平台列在 [驗證記錄](VALIDATION.zh-TW.md)。Web 介面的開發測試是獨立流程，一般 Mac 建置不下載測試瀏覽器。

## 指定架構

需要建立特定架構時，可使用：

```bash
RBN_BUILD_ARCH=arm64 /bin/bash "/你的專案資料夾/Build-on-Mac.command" --no-launch
```

Intel 目標將 arm64 改為 x86_64。這需要目前 Apple SDK 支援該目標；跨架構編譯不代替在相應硬體實際啟動。這份腳本不下載另一份工具鏈來繞過相容性問題。

## 建置失敗時

Terminal 會顯示 `.build-cache/logs` 中本次記錄的路徑。先看第一個編譯或驗證錯誤，後面的「建置未完成」只是結果。腳本遇到錯誤不會自行安裝編譯器或更新系統。

若提示另一份 App 還在執行，請確認已真正結束，不只是關閉視窗；Next 關窗會隱藏，Command-Q 才是結束。若提示另一次建置，先確認沒有其他 Terminal 正在建置。前次強制中止留下 `.build-cache/build.lock` 時，確認沒有建置程序後可移除該空資料夾再試。

rclone 缺少、不是可執行檔或版本不相容，屬於 App 設定中的引擎問題，不是必須重裝整個 App。更新器會在覆蓋前檢查新引擎架構與最低 macOS，不因「有新版」就保證那個官方執行檔適合所有 macOS 13 以上系統。

## 官方資料

- [Apple：Command Line Tools](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools)
- [Apple：macOS 簽章與資源封存](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)
- [Apple：Gatekeeper 與執行階段保護](https://support.apple.com/guide/security/gatekeeper-and-runtime-protection-sec5599b66df/web)
- [rclone 官方下載](https://rclone.org/downloads/)
