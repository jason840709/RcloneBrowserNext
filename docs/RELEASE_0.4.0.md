# Rclone Browser Next 0.4.0

讓 rclone 的檔案管理跟上現在的 Mac。

這一版採用雙面板介面，將本機、雲端與 NAS／伺服器瀏覽整合在同一個視窗，並提供 Apple Silicon（`arm64`）與 Intel（`x86_64`）原生建置。

## 主要特色

- 左右獨立位置與分頁，從中央指定方向、執行複製／移動／同步。
- 支援預演（Dry Run）、即時進度與工作紀錄、儲存與編輯作業（Tasks）。
- 可記住兩側資料夾與傳輸設定，下次啟動自動還原（不會自行開始傳輸）。
- 深紫、淺紫、深藍、淺藍四色主題；支援繁體中文、English、日本語。
- 內建適合掛載 NAS 的「大小與修改時間（不計算本機雜湊）」比對模式，以及 App／rclone 獨立更新檢查。
- 採用 Swift／AppKit 與系統內建 WebKit，不內嵌 Electron、Chromium 或 Qt。

## 下載與使用

下載 **RcloneBrowserNext-0.4.0-source.zip** 並完整解壓縮，雙擊 `Build-on-Mac.command` 即可建置。需 macOS 13 以上並已安裝 Xcode 或 Apple Command Line Tools；外部 rclone 請另行安裝並在「設定」中指定位置。

產生的 App 使用本機 ad-hoc 簽章（未具 Developer ID 與 Apple 公證），檔案 SHA-256 校驗值列於同頁的 `SHA256SUMS.txt`。首次使用建議先拿測試資料執行 Dry Run 預演。

This release provides a **source build package**, requiring macOS 13+ and an existing Xcode or Apple Command Line Tools installation. Extract the full ZIP and run `Build-on-Mac.command`. Apple Silicon and Intel builds are supported. Install rclone separately and select it in Settings. Builds are ad-hoc signed, not Developer ID signed or Apple notarized.

## 來源與驗證

Next 由 Jason Chen 獨立開發，參考 rclone、mmozeiko／RcloneBrowser 與 kapitainsky／RcloneBrowser，詳細測試結果請見 `docs/VALIDATION.zh-TW.md`。
