# Rclone Browser Next 0.9.2

## Mac Dock 持續提醒

當傳輸在背景完成或失敗時，Mac 的 Dock 圖示現在會持續跳動提醒，直到你切回 App 為止（與原版 Rclone Browser 的預設提醒行為一致，不會搶走目前視窗焦點）。可在「設定 → 介面 → 背景執行」隨時開關。

## 圖形化帳號設定

工具列的「帳號設定」現在直接打開圖形化設定視窗（旁邊的 `config` 仍保留傳統終端機設定入口）：

- 可直接在介面中新增、編輯與刪除雲端或伺服器連線，並查看或切換 `rclone.conf` 設定檔。
- 服務清單與設定步驟直接向目前的 rclone 查詢，支援瀏覽器 OAuth 授權、必填檢查與進階選項。
- 設定修改會先寫入暫存檔，按下「儲存」才正式寫回；若取消或遇到其他程式同時修改設定檔，不會覆蓋原檔。

註：若 Google Drive 要求填入自訂憑證，介面會標示必填的 Client ID 欄位並附上官方申請說明。

---

## English

0.9.2 adds graphical account setup on all platforms and persistent macOS Dock attention until the app is activated. The small `config` link preserves terminal setup.

The account wizard uses the selected rclone's documented non-interactive JSON questionnaire, including dynamic providers, required fields, choices, secret defaults, advanced settings and browser authorization. Changes are staged until explicitly saved; cancellation preserves the original file and concurrent external edits prevent overwrite. Existing Windows filesystem fixes are retained.

Google Drive may require your own OAuth client ID and secret; the wizard explains these fields but does not bypass Google's requirements. Validation uses isolated local fixtures and authorization-preflight questions, not a live login to a user's cloud account.
