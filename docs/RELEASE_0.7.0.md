# Rclone Browser Next 0.7.0

這一版修正位置選單展開行為、整理三語介面文字、在傳輸報告中補上成功與驗證失敗的資料量統計，並首度提供 Windows 與 Linux 安裝包。

## 位置選單與介面文字

- 左右面板的位置選單固定在圖示正下方展開，長清單只捲動選單內部，不會拉動整個視窗。
- 全面整理繁中、英文、日文的按鈕、欄位與錯誤訊息：移動前清楚說明來源刪除條件，部分資料夾同步在確認視窗列出同步範圍，「工作嘗試次數」明確標示包含首次執行。

## 傳輸報告與符號連結

- 報告新增「複製成功資料量」、「大小檢查失敗資料量」與「工作嘗試次數」，並將來源持續增長、符號連結、特殊檔案與重試摘要分開記錄。
- 若備份期間大型紀錄檔或資料庫持續寫入導致反覆重傳，建議先關閉寫入程式或將「工作嘗試次數」設為 1（詳見 [原因與處理方式](https://github.com/jason840709/RcloneBrowserNext/blob/v0.7.0/docs/RESEARCH_0.7.0.md)）。
- 新增「符號連結」選項：可選擇略過，或保留連結（在雲端存為 `.rclonelink`，下載時同樣勾選保留即可還原）。

## 安裝檔

| 系統 | 下載檔案 |
| --- | --- |
| Apple Silicon Mac | `Rclone_Browser_Next_0.7.0_macOS_arm64.zip` |
| Intel Mac | `Rclone_Browser_Next_0.7.0_macOS_x86_64.zip` |
| Mac 本機建置與完整原始碼 | `Rclone_Browser_Next_0.7.0_Mac_Local_Build.zip` |
| Windows x64 | `Rclone_Browser_Next_0.7.0_Windows_x64_Setup.exe` |
| Linux amd64（Ubuntu 24.04） | `Rclone_Browser_Next_0.7.0_Linux_amd64.deb` |

Windows 與 Linux 版共用同一套前端介面與 Swift 傳輸核心（分別搭配系統 WebView2 與 WebKitGTK），支援瀏覽、複製、移動、單向同步、預演、作業與報告；Finder 拖放、選單列與掛載則為 Mac 版專屬。[相容版安裝與建置](https://github.com/jason840709/RcloneBrowserNext/blob/v0.7.0/docs/BUILD_COMPATIBILITY.md) · [建置結果](https://github.com/jason840709/RcloneBrowserNext/actions) · [驗證記錄](https://github.com/jason840709/RcloneBrowserNext/blob/main/docs/VALIDATION.zh-TW.md)

作者：Jason Chen。感謝 rclone、mmozeiko／RcloneBrowser 與 kapitainsky／RcloneBrowser 開發團隊。
