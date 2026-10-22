# Rclone Browser Next 0.9.2

## Mac Dock 提醒

背景傳輸完成或失敗時，Dock 圖示會持續提醒，直到使用者重新啟用 App。不必先縮小視窗：切到其他應用程式也會收到提醒。改用與原版 Rclone Browser 的 Qt alert 預設行為相同的 AppKit 持續提醒，跳動節奏由 macOS 控制，不搶走目前視窗的焦點。

仍可在「設定 → 介面 → 背景執行」關閉 Dock 提醒。預演、取消、前景操作及重新載入的舊紀錄不觸發；多項工作密集完成共用尚未確認的提醒。

## 圖形化帳號設定

「帳號設定」現在直接開啟圖形介面，旁邊獨立的 `config` 文字保留傳統終端機入口。

- 新增、編輯與移除連線；顯示實際使用的設定檔，也能選擇既有設定檔。
- 儲存服務與每一步欄位直接取自目前選用的 rclone。支援預設值、必填欄位、選單、密碼、憑證檔案與進階問題，不依賴服務編號或終端機文字格式。
- 登入和 OAuth 交由 rclone 處理；需要瀏覽器授權時顯示等待狀態，並可重新開啟該次登入頁面或取消。
- 變更先寫入隔離的暫存設定，按下「儲存」才寫回。取消會保留原檔；其他程式若改動設定檔，儲存會停止，避免覆蓋。
- 已儲存的密碼不傳回操作畫面，可以選擇保留原值。帳號設定、傳輸與引擎更新不會同時改寫設定。

Google Drive 要求自行建立 client ID 時，圖形介面會清楚標示必填，附上 rclone 官方說明。這是應用程式的識別碼，不是 Gmail 帳號；圖形介面不能取代 Google 的授權要求。

三平台使用同一份問答核心和介面；Windows 既有磁碟、目錄與大型檔案修復保留。測試使用隔離的 alias/WebDAV 設定與 Google／OneDrive 的授權前問題，沒有使用使用者的真實雲端帳號完成登入。Dock API 與觸發條件在 Mac 原生測試中驗證；實際跳動由使用者的 macOS 設定控制。

## 安裝

Mac 請依 Apple Silicon／Intel 選擇 ZIP；Windows 使用 x64 安裝程式；Linux 套件以 Ubuntu 24.04 amd64 為基準。原有設定、作業與外部 rclone 保留。Mac 仍為本機 ad-hoc 簽章，Windows 沒有 Authenticode 簽章。

---

## English

0.9.2 adds graphical account setup on all platforms and persistent macOS Dock attention until the app is activated. The small `config` link preserves terminal setup.

The account wizard uses the selected rclone's documented non-interactive JSON questionnaire, including dynamic providers, required fields, choices, secret defaults, advanced settings and browser authorization. Changes are staged until explicitly saved; cancellation preserves the original file and concurrent external edits prevent overwrite. Existing Windows filesystem fixes are retained.

Google Drive may require your own OAuth client ID and secret; the wizard explains these fields but does not bypass Google's requirements. Validation uses isolated local fixtures and authorization-preflight questions, not a live login to a user's cloud account.
