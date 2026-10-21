# Rclone Browser Next 0.9.0 — Windows revision 1

這是 **Windows x64 專用修正版**，修正 Windows 本機檔案瀏覽與大型檔案處理。Mac 維持既有 0.9.0，原安裝檔、共用 Web 介面與 Mac 程式碼不變。

## Windows 修正

- 本機位置選單加入 C:、D:、可移除磁碟及映射磁碟，常用資料夾使用 Windows Known Folders 取得。
- 本機檔案清單改用 Windows 原生目錄資訊，避免使用者資料夾內的受限項目或失效 junction 讓整份清單讀取失敗。
- 檔案大小使用完整 64 位元數值，避開原版 Swift 6.1.2 在 Windows 讀取大型檔案資訊時的溢位與引擎退出問題。
- 新增、改名、刪除與容量統計使用同一套 Windows 檔案處理。改名拒絕覆寫同名目的地；刪除 junction／symlink 時保留其指向的目標。
- Windows 安裝版本為 `0.9.0+1`，系統數字版本為 `0.9.0.1`；「關於」顯示 Windows 修正版 1。

## 安裝與驗證

下載並執行 `Rclone_Browser_Next_0.9.0_Windows_r1_x64_Setup.exe`。這是同一個應用程式識別碼的更新，升級保留原有設定、工作區與已儲存作業。執行前先關閉原本的 Rclone Browser Next。

發布流程只接受同一份原始碼在 Windows 專屬 CI 完成建置、安裝、升級及產品案例驗證的安裝檔。測試包含真正安裝後的 helper、超過 2 GiB／4 GiB 的稀疏檔、中文長路徑、junction 邊界、左右 remote 選單，以及一般視窗與 125% 介面大小。remote 測試使用本機 alias 與真實 rclone，不包含第三方使用者的雲端帳號。

此 release 標記為 prerelease，讓既有 Mac 的正式更新檢查繼續指向 `v0.9.0`。舊 Windows 版本也不會透過原本的正式版本檢查自動提示這次平台修正版，請使用這個發布頁的直接下載。安裝檔尚無 Authenticode 簽章；可用隨附的 `SHA256SUMS.txt` 核對下載內容。

詳細問題證據與平台邊界：[Windows 修正說明](https://github.com/jason840709/RcloneBrowserNext/blob/windows-v0.9.0-r1/docs/WINDOWS_0.9.0_R1.md)。同頁附件的 verification JSON 提供精確來源 commit、通過的 Windows CI 連結與安裝檔 SHA-256。

## English

This is a **Windows x64 repair of 0.9.0**. The existing Mac 0.9.0 application, assets, source inputs and stable update target are unchanged.

Windows local browsing now uses native filesystem enumeration and 64-bit sizes. It includes drive entries and Windows known folders, handles directory listings containing inaccessible or broken-link entries, and avoids the Swift 6.1.2 Windows metadata failure reproduced with large files. Local rename, removal and folder-size operations use the same Windows implementation, with collision checks and junction-target preservation.

Run `Rclone_Browser_Next_0.9.0_Windows_r1_x64_Setup.exe` after closing the app. The installed version is `0.9.0+1` / Windows numeric version `0.9.0.1`. The upgrade preserves existing settings, workspace and saved tasks.

The installer is published only after the exact candidate passes Windows build, clean installation, upgrade, filesystem, mutation, transfer and real WebView2 interaction checks. Remote selection is tested using synthetic local aliases through the real rclone executable; the original reporter's cloud account is unavailable for testing.

This platform release is marked prerelease so the stable Mac update endpoint remains `v0.9.0`. Existing Windows installations require this direct download as well. The installer is unsigned; verify it with the supplied SHA-256 checksums. The verification attachment identifies the exact source commit and successful Windows CI run.
