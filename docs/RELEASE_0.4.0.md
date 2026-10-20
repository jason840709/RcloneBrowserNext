# Rclone Browser Next 0.4.0

讓 rclone 的檔案管理，跟上現在的 Mac。

這一版以新的雙面板介面，將本機、雲端及 NAS／伺服器瀏覽放在同一個視窗，並提供 Apple Silicon 原生 arm64 與 Intel x86_64 的本機建置方式。

## 主要特色

- 左右獨立位置與分頁，中央確認方向、來源、目標及複製／移動／同步。
- Dry Run 預演、工作進度與記錄、完整儲存及編輯作業。
- 記住兩側資料夾與傳輸設定；下次開啟時還原，不會自行開始傳輸。
- 深紫、淺紫、深藍、淺藍四種外觀；繁體中文、English、日本語。
- 掛載 NAS 的大小與修改時間比較選項，以及獨立的 App／rclone 更新檢查。
- Swift／AppKit＋系統 WebKit，不另包 Electron、Chromium、Qt 或 rclone。

## 下載與使用

下載 **RcloneBrowserNext-0.4.0-source.zip**，完整解壓縮，再雙擊 `Build-on-Mac.command`。需要 macOS 13 以上與已有的 Xcode 或 Apple Command Line Tools。rclone 另外安裝，於 App 設定指定位置。

這份下載是來源建置包。產生的 App 使用 ad-hoc 本機簽章，沒有 Developer ID 簽章與 Apple 公證。來源 ZIP 的 SHA-256 列在同頁的 `SHA256SUMS.txt`。

第一次請用測試資料執行 Dry Run。同步可能刪除目標檔案；移動成功後會移除對應來源。

This release provides a **source build package**, requiring macOS 13+ and an existing Xcode or Apple Command Line Tools installation. Extract the full ZIP and run `Build-on-Mac.command`. Apple Silicon and Intel builds are supported. Install rclone separately and select it in Settings. Builds are ad-hoc signed, not Developer ID signed or Apple notarized.

## 來源與驗證

Next 由 Jason Chen 獨立開發，參考 rclone、mmozeiko／RcloneBrowser、kapitainsky／RcloneBrowser 及 downer08tutti／RcloneBrowser2；並非上述專案的官方新版。詳見首頁與致謝。

原交付的測試結果與限制保留在 `docs/VALIDATION.zh-TW.md`，其數字不代表本次重新執行測試。此次發布整理以文件、圖示、截圖、來源完整性與連結檢查為主；實際 CI 狀態請查看 Actions。
