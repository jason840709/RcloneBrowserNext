# 在 Mac 建置 Rclone Browser Next

本原始碼包內含 Swift 原始碼、已編譯好的前端資源、圖示、測試與建置腳本，可直接在你的 Mac 上編譯出 `Rclone Browser Next.app`。建置過程只使用 Mac 內建的 Xcode 或 Apple Command Line Tools，完全離線，不會下載 Node.js、Homebrew 或任何外部套件。

## 第一次建置

1. 解壓縮完整原始碼包到一般可寫入的資料夾。
2. 若舊版 App 正在執行，請先停止所有傳輸與掛載，並按 `Command + Q` 完全結束 App。
3. 雙擊 `Build-on-Mac.command`。
4. 建置完成後，同一資料夾會產生並自動打開 `Rclone Browser Next.app`。
5. 在 App「設定」中指定外部 `rclone` 位置（可選取已安裝的 rclone 或直接下載）。

支援 **macOS 13 以上**，會依你的 Mac 硬體自動編譯為 Apple Silicon（`arm64`）或 Intel（`x86_64`）原生版本。

若 Finder 擋下剛下載的 `.command` 腳本，可打開「終端機」，輸入 `/bin/bash `（後面留一個空白），把 `Build-on-Mac.command` 拖進終端機視窗後按 Return 執行。

## 不自動啟動 App／指定架構

若只想編譯與驗證 App、不要在完成後自動啟動，可在終端機加上 `--no-launch`：

```bash
/bin/bash "/你的專案資料夾/Build-on-Mac.command" --no-launch
```

若需指定編譯架構（例如在 Apple Silicon 上編譯 Intel 版），可加上 `RBN_BUILD_ARCH`（`arm64` 或 `x86_64`）：

```bash
RBN_BUILD_ARCH=arm64 /bin/bash "/你的專案資料夾/Build-on-Mac.command" --no-launch
```

註：前端畫面已預先打包在 `Resources/Web` 中，一般建置不需重編 React；若想修改前端程式碼，請見 [開發說明](DEVELOPMENT.md)。

## 相關檔案位置

| 位置 | 內容 |
| --- | --- |
| 專案內 `Rclone Browser Next.app` | 編譯完成的應用程式 |
| 專案內 `.build-cache` | 編譯快取、日誌與測試暫存（建置完成後可隨時刪除回收空間） |
| 專案內 `Distribution` | 打包好的本機 App ZIP 與 SHA-256 校驗檔 |
| 專案內 `Backups` | 重新建置前自動備份的舊版 App |
| 所選 rclone 資料夾 | 外部 rclone 執行檔與更新備份 |
| `~/Library/Application Support/Rclone Browser Next Lite` | App 設定、已儲存作業、工作紀錄與暫存 |
| `rclone.conf`（預設或自訂路徑） | rclone 雲端帳號設定與授權權杖 |

## 重新建置與本機簽章

需要重編時再次執行 `Build-on-Mac.command` 即可。腳本會先在暫存區完成編譯、封裝與簽章驗證，全部通過後才備份舊版並換上新版；若中途失敗不會覆蓋原本可用的 App。

產生的 App 採用 **本機 ad-hoc 簽章**（未具 Apple Developer ID 與公證），在本機可直接執行；若將打包好的 ZIP 傳給另一台 Mac，首次開啟可能需在「系統設定 → 隱私權與安全性」中點擊「強制打開」。請勿手動修改 `.app` 內部檔案，否則簽章會失效。

## 驗證與執行測試

- **檢查 App 結構與簽章**：雙擊 `Verify-App.command`，會檢查版本、架構、最低系統需求、資源完整性與 `codesign` 簽章。
- **執行完整自動化測試**：先建置好 App，再執行 `Test-on-Mac.command`（可傳入本機 `rclone` 路徑以執行包含真實傳輸的整合測試）：

```bash
/bin/bash "/你的專案資料夾/Build-on-Mac.command" --no-launch
/bin/bash "/你的專案資料夾/Test-on-Mac.command" "/你選擇的資料夾/rclone"
```

`Test-on-Mac.command` 會編譯並執行 核心、原生介面與本機修復等 Swift 測試（實際執行項目依平台與是否提供 rclone 而定；只跑原生相關測試時，可在指令前加上 `RBN_NATIVE_TESTS_ONLY=1`）：

| 測試套件 | 測試內容 |
| --- | --- |
| AccountsTests | 帳號設定、暫存修改與登入流程 |
| SyncDirectoryTests | 同步範圍與空資料夾清理 |
| SMBTests | SMB 直連與檔名處理 |
| ListingTests | 資料夾列舉與取消 |
| CoreTests | 檔案瀏覽、傳輸選項、作業管理、設定與取消流程 |
| UpdaterTests | rclone 版本檢查、校驗碼驗證、更新替換與失敗還原 |
| ToolsTests | 目錄樹、清單匯出、外部播放器串流與清理 |
| NativeMessagesTests | 原生訊息三語翻譯與錯誤文字格式 |
| FinderDropTests | Finder 拖放路徑解析、來源範圍與符號連結檢查 |
| AppReleaseTests | GitHub 正式版更新檢查與下載頁連結驗證 |
| TransferReportTests | 逐檔報告、失敗重試、來源檔案變動與大清單分頁 |
| PlatformTests | 跨平台路徑、檔案操作與子程序管理 |
| MacLocalCopyTests | 本機複製、鎖定來源與取消 |
| MacPartialRecoveryTests | 暫存檔核對、修復與收據清理 |
| MacCompletionTests | 背景完成提醒 |
| MacWindowInteractionTests | 視窗拖曳與雙擊縮放 |
| MacInterfaceTests | WebKit 主題載入、五段縮放、滑鼠側鍵與圖示 |
| MacStartupTests | 六色主題冷啟動、原生載入畫面交接與防白閃 |
| MacIconTests | 三色圖示透明度、執行中 Dock 變色與 App 簽章驗證 |
| MacNavigationIntegrationTests | 原生滑鼠事件、React 介面與真實 rclone 的資料夾導覽整合測試 |

所有測試皆在 `.build-cache/tests` 隔離目錄中執行，不會動到你的真實雲端帳號或日常檔案。歷次發布的測試結果請見 [驗證記錄](VALIDATION.zh-TW.md)。

## 常見問題排除

- **建置失敗**：請查看終端機印出的 `.build-cache/logs` 日誌路徑，從第一個編譯錯誤開始排查（請先確認既有 Xcode 或 Command Line Tools 的安裝與選用設定）。
- **提示 App 仍在執行**：關閉視窗只會隱藏到背景，請按 `Command + Q` 完全退出 App 再重新建置。
- **提示已有另一個建置正在進行**：只有確認前次建置程序已結束、鎖屬於該次建置時，才能移除 `.build-cache/build.lock` 空資料夾即可重試。

## 參考連結

- [Apple：安裝 Command Line Tools](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools)
- [Apple：macOS 程式碼簽章指南](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)
- [Apple：Gatekeeper 與安全性說明](https://support.apple.com/guide/security/gatekeeper-and-runtime-protection-sec5599b66df/web)
- [rclone 官方下載頁](https://rclone.org/downloads/)
