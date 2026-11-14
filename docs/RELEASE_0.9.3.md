# Rclone Browser Next 0.9.3

## 帳號設定重新設計

帳號設定現在預設開啟精簡的「快速設定」：

- 新增 Google Drive、OneDrive 或 Dropbox 時，只需輸入自訂名稱、選擇服務，再按「登入並新增帳號」，在瀏覽器完成授權後就會自動存檔並回到 App（OneDrive 若有多個空間會請你挑選）。
- 常用雲端服務排在最前面；自訂 Client ID 與 Client Secret 收納在同一個可展開區塊（支援共用登入的服務可留空）。
- 「詳細設定」將該服務的所有欄位整合在同一頁表單，進階選項可按需展開；Google Drive 權限改用直白的用途說明。
- 只有在實際選到已加密且未解鎖的設定檔時，才會顯示密碼欄位。
- 若瀏覽器登入失敗，可直接返回修改或重試；取消登入會自動清理暫存程序。

註：rclone 已公告未來將停用內建的 Google Drive 共用憑證；若內建登入遭拒，可在同頁展開自訂憑證填入自己的 Client ID 與 Client Secret 重試（[官方說明](https://rclone.org/drive/#making-your-own-client-id)）。

---

## English

0.9.3 redesigns account setup around a short form and browser sign-in. Quick setup is the default: enter a nickname, choose Google Drive, OneDrive or Dropbox, then sign in and add the account. Successful authorization saves the account and returns to the app; OneDrive asks which drive to use when necessary.

Popular services come first. Custom Client ID and Client Secret fields appear together in an optional section. Detailed setup groups provider options on one page, with advanced options collapsed. Configuration passwords appear only for an actually locked file. Long option text wraps correctly, and failed sign-in has clear back, retry and cancel actions.

The native core handles known configuration defaults, preserves staged writes and external-edit checks, and stops for unknown required choices. Existing Mac Dock attention, loading animation and Windows filesystem fixes remain in place. The independent `config` link still opens terminal setup.

rclone has announced retirement of its shared Google Drive client ID. Quick setup attempts the engine's built-in sign-in; if the service rejects it, custom credentials can be entered together and retried. Tests exercise real rclone and its local OAuth listener without signing in to a user's real cloud account.
