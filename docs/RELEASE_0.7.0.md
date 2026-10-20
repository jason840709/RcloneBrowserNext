# Rclone Browser Next 0.7.0

這次修正位置選單的展開方式，重新整理三種語言的介面文字，讓傳輸報告能分清成功複製、失敗重試及持續變動的檔案，並加入 Windows 與 Linux 安裝包。

## 位置選單

左右面板的位置選單固定在圖示下方展開。切到清單底部的雲端位置、重新開啟選單或用鍵盤移動時，只捲動選單內容，位置列與整個視窗維持原位。長清單的高度依可用空間調整，支援五種介面大小。

## 文字與操作確認

- 略過原因改為「依本次比對與略過設定，無需更新」，並在工作中顯示使用的比對方式。
- 繁中、英文、日文一起整理按鈕、欄位、提示及錯誤訊息。選項名稱與錯誤中的引用對齊；工作嘗試次數明確包含首次執行。
- 移動前說明來源檔案何時會刪除，包含目標已有依設定無需更新的副本。部分資料夾同步會在最後確認列出範圍。
- 發生錯誤時，訊息提供檔案、原因或可執行的下一步。只有目標存在的比對紀錄只描述檔案位置；實際刪除另由成功紀錄呈現。

## 傳輸報告

新增成功複製大小、大小驗證失敗的副本大小，以及工作嘗試次數。來源持續增長、符號連結、socket 等特殊檔案、重試摘要與清理結果分開記錄。

位元組統計依 rclone 的逐檔事件累計。同一檔案重試時可以出現多次，因此成功複製大小和失敗副本大小都代表操作累計；它們不是不重複檔案的總容量，也不是網卡流量。報告保留本次來源、目標、傳輸選項與 rclone 版本，方便確認比較方式及重試條件。

如果大型紀錄檔在備份期間持續增加，rclone 會重傳整個檔案，大小驗證仍失敗時再依設定重試。完整備份這類資料夾，應在寫入程式停止後執行，或使用一致性快照。只想先完成其他檔案時，可將「工作嘗試次數」設為 1，之後再備份仍在變動的檔案。[原因與處理方式](https://github.com/jason840709/RcloneBrowserNext/blob/v0.7.0/docs/RESEARCH_0.7.0.md)

新增「符號連結」選項，可略過或保留連結。保留時儲存連結本身與指向路徑，雲端用 `.rclonelink` 檔案保存；下載還原時也選「保留符號連結」。

## 安裝檔

| 系統 | 下載檔案 |
| --- | --- |
| Apple Silicon Mac | `Rclone_Browser_Next_0.7.0_macOS_arm64.zip` |
| Intel Mac | `Rclone_Browser_Next_0.7.0_macOS_x86_64.zip` |
| Mac 本機建置及完整原始碼 | `Rclone_Browser_Next_0.7.0_Mac_Local_Build.zip` |
| Windows x64 | `Rclone_Browser_Next_0.7.0_Windows_x64_Setup.exe` |
| Linux amd64，Ubuntu 24.04 | `Rclone_Browser_Next_0.7.0_Linux_amd64.deb` |

Mac 仍是主要開發平台，使用 AppKit 與系統 WebKit，最低 macOS 13。Windows／Linux 使用相同介面與 Swift 傳輸核心，視窗分別使用系統 WebView2／WebKitGTK，安裝包包含所需 Swift 執行階段。rclone 維持外部安裝，可在設定中選取或下載。

Windows 安裝程式安裝到目前使用者；缺少 WebView2 時會引導安裝。Linux 套件以 Ubuntu 24.04 建置並宣告系統相依套件。相容版提供檔案瀏覽、複製、移動、單向同步、預演、作業及報告；macOS 專用的 Finder 拖放、狀態列及掛載整合保留在 Mac 版。[相容版安裝與建置](https://github.com/jason840709/RcloneBrowserNext/blob/v0.7.0/docs/BUILD_COMPATIBILITY.md)

Mac 使用 ad-hoc 簽章，Windows 安裝檔尚無程式碼簽章。下載後請依作業系統提示開啟；SHA-256 校驗表隨發布附上。

發布流程會先完成兩種 Mac 架構的建置、簽章與核心／WebKit 測試，以及 Windows／Linux 的建置、實際本機傳輸和原生視窗檢查，再產生正式發布。[建置結果](https://github.com/jason840709/RcloneBrowserNext/actions) · [驗證記錄](https://github.com/jason840709/RcloneBrowserNext/blob/main/docs/VALIDATION.zh-TW.md)

作者：Jason Chen。感謝 rclone、mmozeiko／RcloneBrowser 與 kapitainsky／RcloneBrowser 的開發者。
