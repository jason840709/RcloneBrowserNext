# Rclone Browser Next 0.9.2

## 帳號設定改為圖形介面

工具列的「帳號設定」可新增、編輯及移除 rclone 帳號。旁邊的文字入口 `config` 保留傳統終端機設定。服務清單、問題、必填條件、預設值與可選答案，皆由目前選用的 rclone 提供；不依賴終端機選項編號或題目排版。

設定先寫入同一設定檔目錄的暫存副本，按「儲存」才套用。取消會停止設定程序並清除暫存副本；移除帳號只改設定，不刪除雲端或本機資料。原檔在設定期間被其他程式變更時，會拒絕覆寫。設定期間暫停新的傳輸及引擎／設定檔切換，避免兩個流程同時寫入。

Google Drive、OneDrive 等服務仍由 rclone 開啟系統瀏覽器進行登入。需要自訂 Google OAuth client ID 時，畫面會顯示必填欄位與官方建立說明；圖形介面不會繞過服務端的授權要求。已儲存的密碼不會回填到介面，可選擇保留原值。

## Mac Dock 提醒持續到返回程式

0.9.1 的短暫提醒改為原版 Rclone Browser／Qt 在 macOS 採用的持續提醒方式。背景傳輸完成或失敗後，Dock 圖示持續依系統節奏跳動，直到主視窗回到前景。視窗被遮住、隱藏或最小化都不必先手動縮小才生效；提醒不會把程式強制切到前景。

多個工作密集完成只保留一個待確認提醒。預演、取消與舊紀錄不觸發，設定中的 Dock 提醒開關仍可關閉此功能。具體跳動節奏由 macOS 決定。

## 相容性與既有修復

Mac Apple Silicon／Intel、Windows x64、Linux amd64 共用 0.9.2 來源。Windows R1 的原生檔案存取、大檔案與磁碟路徑修復保持不變，仍有來源雜湊及回歸檢查。帳號圖形介面會先檢查 rclone 是否支援 JSON 設定；不相容時保留傳統 config 入口。

Mac 需要 macOS 13 以上；Linux 套件以 Ubuntu 24.04 amd64 為基準。rclone 仍由使用者指定或透過程式下載，不內嵌在 App 中。Mac 使用本機 ad-hoc 簽章，Windows 安裝程式未附 Authenticode 簽章。

---

## English

Accounts now has a graphical, provider-driven setup flow. The separate `config` text control retains terminal setup. Changes are staged until Save; cancellation leaves the original configuration unchanged, and removing an account never deletes its files. Google/Microsoft sign-in remains in the system browser through rclone. Required OAuth client credentials remain the user's responsibility.

On macOS, background completion or failure now requests persistent Dock attention, matching the original Rclone Browser's Qt implementation. Returning to the main window acknowledges the reminder. macOS controls the bounce cadence; the app does not steal focus.

The verified Windows filesystem implementation is retained. All supported platforms use the same 0.9.2 source. See `docs/ACCOUNT_SETUP.md` for protocol details and verification boundaries.
