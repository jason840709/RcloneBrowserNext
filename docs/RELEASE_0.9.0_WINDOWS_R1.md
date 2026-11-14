# Rclone Browser Next 0.9.0 — Windows revision 1

這是 **Windows x64 專用修正版（`0.9.0+1`）**，修復 Windows 本機磁碟瀏覽與大檔案處理問題（Mac 與 Linux 版維持既有 0.9.0 不變）。

## Windows 修正內容

- 本機位置選單加入 `C:`、`D:`、外接磁碟與網路磁碟機，常用資料夾改由 Windows Known Folders 讀取。
- 本機檔案清單改用 Windows 原生目錄列舉 API，避免使用者資料夾內的權限受限項目或失效捷徑（junction）導致整個資料夾讀取失敗。
- 檔案大小改用完整 64 位元整數讀取，修復 Swift 6.1.2 在 Windows 讀取超過 2 GB／4 GB 大檔案時發生溢位閃退的問題。
- 修正磁碟根目錄（如 `D:\`）被誤轉為相對路徑的問題，並同步改善新增資料夾、改名、刪除與容量統計的 Windows 路徑處理（刪除 junction／symlink 時不會誤刪指向目標）。

## 安裝說明

請先關閉舊版 Rclone Browser Next，再下載並執行 `Rclone_Browser_Next_0.9.0_Windows_r1_x64_Setup.exe`；原有的設定、工作區與已儲存作業都會保留。詳細排查紀錄請見 [Windows 修正說明](https://github.com/jason840709/RcloneBrowserNext/blob/windows-v0.9.0-r1/docs/WINDOWS_0.9.0_R1.md)。

## English

This is a **Windows x64 repair of 0.9.0**. The existing Mac 0.9.0 application, assets, active source code and stable update target are unchanged. Shared Core changes are limited to three pinned Windows-only conditional blocks; the source guard verifies that removing them restores the complete Mac baseline files.

Windows local browsing now uses native filesystem enumeration and 64-bit sizes. It includes drive entries and Windows known folders, handles directory listings containing inaccessible or broken-link entries, and avoids the Swift 6.1.2 Windows metadata failure reproduced with large files. Local rename, removal and folder-size operations use the same Windows implementation, with collision checks and junction-target preservation.

Drive roots also remain absolute during browsing, transfer preview and saved-request reparsing. Windows-only comparison guards preserve the existing refusal of root destinations and transfers into the source's own descendants, including destinations that do not yet exist.

Run `Rclone_Browser_Next_0.9.0_Windows_r1_x64_Setup.exe` after closing the app. The installed version is `0.9.0+1` / Windows numeric version `0.9.0.1`. The upgrade preserves existing settings, workspace and saved tasks.

The installer is published only after the exact candidate passes Windows build, clean installation, upgrade, filesystem, mutation, transfer and real WebView2 interaction checks. Remote selection is tested using synthetic local aliases through the real rclone executable; the original reporter's cloud account is unavailable for testing.

This platform release is marked prerelease so the stable Mac update endpoint remains `v0.9.0`. Existing Windows installations require this direct download as well. The installer is unsigned; verify it with the supplied SHA-256 checksums. The verification attachment identifies the exact source commit and successful Windows CI run.
