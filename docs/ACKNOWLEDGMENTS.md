# 來源與致謝 / Acknowledgments

Rclone Browser Next 由 **Jason Chen** 開發，延續 Rclone Browser 的位置瀏覽、傳輸選項、工作紀錄與作業（Tasks）流程，底層檔案傳輸與雲端連線則由外部 rclone 執行。

Next 以 Swift／AppKit、macOS 內建 WebKit 與 React 重新編寫，在原版的操作基礎上改為左右雙面板自由選取設計。

## 參考專案

- **rclone 與開發團隊** — [官方網站](https://rclone.org/) · [原始碼](https://github.com/rclone/rclone)：提供雲端連線、檔案比對與傳輸引擎。
- **mmozeiko／RcloneBrowser** — [原始專案](https://github.com/mmozeiko/RcloneBrowser)：奠定 rclone 圖形介面的操作模式。
- **kapitainsky／RcloneBrowser 與貢獻者** — [維護分支](https://github.com/kapitainsky/RcloneBrowser)：Next 參考其 Remotes／Jobs／Tasks 架構、檔案操作、Dry Run 與同步選項（功能對照見 [FEATURE_MATRIX.zh-TW.md](FEATURE_MATRIX.zh-TW.md)）。
- **ForkLift** — [官方網站](https://binarynights.com/)：雙面板版面與操作互動參考。

Next 由 Jason Chen 獨立開發發布，與上述專案原作者無隸屬關係；各參考專案之著作權與授權條款均歸原專案所有。

## 程式與視覺資源

- **本專案程式碼**：[MIT License](../LICENSE)。
- **應用程式圖示**：由 Jason Chen 設計，藍、綠主題圖示由同一套向量圖形換色產生（位於 `WebSource/assets/icons` 與 `WebSource/tools/generate-theme-icons.py`）。
- **第三方前端套件**：授權聲明隨附於 [正式 Web 資源](../Resources/Web/THIRD_PARTY_NOTICES.txt) 與 [開發原始碼](../WebSource/THIRD_PARTY_NOTICES.txt)。
