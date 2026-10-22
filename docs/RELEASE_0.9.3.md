# Rclone Browser Next 0.9.3

## 帳號設定重新設計

預設使用「快速設定」。新增 Google Drive、OneDrive 或 Dropbox 時，先輸入自訂帳號名稱、選擇服務，再按「登入並新增帳號」。App 會開啟瀏覽器授權；完成後直接儲存帳號、更新清單並返回 App。OneDrive 有多個雲端空間時會再請使用者選擇。

- 常用服務優先排列，移除分開的「搜尋服務名稱」欄位。
- 只有實際遇到加密且未解鎖的設定檔才要求密碼。設定檔路徑移入次要選項。
- Client ID 與 Client Secret 放在同一個可展開區塊，明確說明一般內建登入可留白。
- 「詳細設定」提供同頁服務表單，進階欄位可展開。Google Drive 權限使用用途說明，原始欄位名稱與官方說明另行展開查看。
- 長選項會換行並隨內容增高，修正文字超出框線；保留三種語言、六種主題與鍵盤操作。
- 快速流程自動處理一般登入的預設選項，不再逐頁詢問服務帳戶、進階設定或手動授權 token。
- 修正 Google Drive 預設拒絕共用登入後，重複要求 Client ID 的路徑。登入失敗可返回修改並重試；取消會先清理目前流程再開始下一次。

WebDAV、SFTP 等服務仍會要求必要的伺服器位址與登入資料。服務新增未知必填問題時，App 會請使用者處理，不會任意猜答案。

## 儲存與相容性

「登入並新增帳號」包含授權成功後儲存；詳細設定、編輯與移除仍保留明確的儲存／確認。儲存前先檢查原設定是否被其他程式修改，再原子替換。取消與失敗不覆蓋原檔。新密碼依 rclone 要求處理，既有秘密值留在原生端，不回填操作畫面。

三平台使用同一份帳號核心及介面。保留 Mac 持續 Dock 提醒、既有讀取動畫與 Windows R1 檔案系統修正。Windows 升級驗證涵蓋 0.9.0、0.9.0-r1 與 0.9.2。

## Google 登入的實際限制

本版會使用目前 rclone 提供的內建登入方式，不在一般流程要求使用者建立應用程式憑證。rclone 已公告 Google Drive 共用識別碼將停用；若 Google 拒絕內建登入，可在同頁填入自己的 Client ID 與 Client Secret 重試。[官方說明](https://rclone.org/drive/#making-your-own-client-id)

自動化測試使用真實 rclone、隔離設定及本機 OAuth 授權入口，另以合成資料驗證畫面互動。沒有使用使用者的私人帳號完成 Google／Microsoft／Dropbox 的雲端登入，亦不宣稱可以取代供應商的授權政策。

## 安裝

Mac 請依 Apple Silicon／Intel 選擇 ZIP；Windows 使用 x64 安裝程式；Linux 套件以 Ubuntu 24.04 amd64 為基準。原有設定、作業與外部 rclone 保留。Mac 仍採本機 ad-hoc 簽章，Windows 沒有 Authenticode 簽章。

---

## English

0.9.3 redesigns account setup around a short form and browser sign-in. Quick setup is the default: enter a nickname, choose Google Drive, OneDrive or Dropbox, then sign in and add the account. Successful authorization saves the account and returns to the app; OneDrive asks which drive to use when necessary.

Popular services come first. Custom Client ID and Client Secret fields appear together in an optional section. Detailed setup groups provider options on one page, with advanced options collapsed. Configuration passwords appear only for an actually locked file. Long option text wraps correctly, and failed sign-in has clear back, retry and cancel actions.

The native core handles known configuration defaults, preserves staged writes and external-edit checks, and stops for unknown required choices. Existing Mac Dock attention, loading animation and Windows filesystem fixes remain in place. The independent `config` link still opens terminal setup.

rclone has announced retirement of its shared Google Drive client ID. Quick setup attempts the engine's built-in sign-in; if the service rejects it, custom credentials can be entered together and retried. Tests exercise real rclone and its local OAuth listener without signing in to a user's real cloud account.
