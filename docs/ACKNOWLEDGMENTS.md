# 來源與致謝 / Acknowledgments

Rclone Browser Next 由 **Jason Chen** 開發，延續 Rclone Browser 的位置瀏覽、傳輸選項、工作記錄與 Tasks 設計。檔案傳輸和儲存服務連線仍由外部 rclone 執行。

Next 採用 Swift／AppKit、macOS 內建 WebKit 與 React 介面，重新實作適合目前 Mac 環境的應用程式。它參考原版的功能分工與操作流程，並加入左右位置都可自由選擇的雙面板；原版已有的功能也在下方清楚列出來源。

## 參考專案

- **rclone 與其開發者** — [官方網站](https://rclone.org/) · [原始碼](https://github.com/rclone/rclone)。提供儲存後端、檔案比對與傳輸引擎；使用者可在 Next 指定及更新獨立安裝的 rclone。
- **mmozeiko／RcloneBrowser** — [早期 Rclone Browser 專案](https://github.com/mmozeiko/RcloneBrowser)。建立以圖形介面操作 rclone 的基礎。
- **kapitainsky／RcloneBrowser 及貢獻者** — [Rclone Browser 維護分支](https://github.com/kapitainsky/RcloneBrowser)。Next 參考其 Remotes／Jobs／Tasks、檔案操作、Dry Run、比對與同步選項。這些是延續的設計，不列為 Next 首創。[功能與架構對照](FEATURE_MATRIX.zh-TW.md) 說明保留項目與差異。
- **ForkLift** — [官方網站](https://binarynights.com/)。雙面板互動與版面參考；本專案沒有散布其程式碼或私有資源。

Next 由 Jason Chen 獨立發布。上述致謝不表示原作者參與、認可或為 Next 提供支援。各原始專案的授權與著作權聲明以該專案為準。

## 程式與視覺資源

- 本專案程式：[MIT License](../LICENSE)。
- 應用圖示：Jason Chen 提供的 v2 圖示，包含修正後的蛇眼睛；首頁與 App 均使用此版本。藍、綠變體沿用相同的幾何圖形與各尺寸光學調整，只改配色；生成來源位於 `WebSource/assets/icons` 與 `WebSource/tools/generate-theme-icons.py`。
- 目前首頁截圖：正式前端在測試環境中產生的中、英文畫面，使用示意帳號及路徑，不包含使用者的私人檔案資料，也不是原生 macOS 視窗截圖。
- 0.4.0 舊版截圖留作版本參考，不代表目前介面。
- 前端套件：[正式 Web 聲明](../Resources/Web/THIRD_PARTY_NOTICES.txt) 與 [開發來源聲明](../WebSource/THIRD_PARTY_NOTICES.txt)。

Next 使用獨立的 Swift／AppKit 實作，並非直接以原版 Qt 程式碼改名發布。參考功能與流程不等於宣稱原版開發者參與這個版本；各套件附帶的授權聲明均予以保留。
