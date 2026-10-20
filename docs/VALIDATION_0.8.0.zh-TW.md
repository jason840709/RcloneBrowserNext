# Rclone Browser Next 0.8.0 驗證記錄

四平台 CI 與正式發布均已完成。建置來源為 [`f2435c706770f68770d7c95fadfa54e3d814a014`](https://github.com/jason840709/RcloneBrowserNext/commit/f2435c706770f68770d7c95fadfa54e3d814a014)，同一個 [CI run](https://github.com/jason840709/RcloneBrowserNext/actions/runs/39467210330) 產生兩個 Mac、Windows x64 與 Linux amd64 安裝檔。正式發布時間為 2026-10-20T17:53:46Z。

## 驗證結果

| 項目 | 結果 |
| --- | --- |
| 正式 Web 介面 | 176 通過，0 失敗、0 略過、0 重試 |
| macOS Apple Silicon，九套 | 168 通過，0 失敗，1 略過 |
| macOS Intel，九套 | 168 通過，0 失敗，1 略過 |
| Windows x64 | Rust 4、Platform 9、helper 9、安裝後原生介面 1；全部通過 |
| Linux amd64 | Rust 4、Platform 10、helper 8、封裝後原生介面 1；全部通過 |

Mac 各略過一個只適用 Linux inotify 的讀取計數案例；可跨平台執行的 NAS 傳輸與比較案例已通過。每個相容版的原生介面 smoke 算一次，內部多個斷言不重複計數。

## 本版修正的驗證

### 原生側鍵與外觀

兩個 Mac 架構的 `MacInterfaceTests` 各 19 項全部通過。測試使用實際 AppKit 視窗與正式 `RcloneWebView`，將 `NSEvent` 送入正式 `NSWindow.sendEvent` 處理器，再讀取 WebKit 回執，涵蓋完整按壓、僅放開、重送、快速連按、漏送放開及窗格座標。

同一套測試確認載入前背景與縮放、document-start 主題、light 主題重新載入、五個標準比例與兩個保留比例的左右窗格 hit testing，以及三個原生圖示。這套原生測試使用受控 HTML；完整 React 介面另由下列正式 Web 回歸驗證。

Core 測試確認 schema 7 遷移會在第一次開啟時保存，舊比例只換算一次，重新啟動及更改其他設定仍保持結果，使用者改選新版 100% 後不會再次遷移。

### 正式 Web 介面

完整測試於 2026-10-20 17:19:35 UTC 開始，耗時 174.9 秒；新增的 13 個 0.8.0 案例另有一次全部通過紀錄。TypeScript 與正式 bundle 建置成功，測試前後的 Web 成品及來源雜湊相同。

涵蓋左右窗格及分頁歷史、DOM／原生側鍵去重、僅按下／僅放開、快速連按、主題初始化、載入期間保留清單與停用舊列、過期請求排除、失敗路徑重試，以及新版比例和保留的 120%／135%。既有六主題、三語言、位置選單、任務與大型清單一併執行。

逐項結果與雜湊見 [Web 驗證記錄](../WebSource/tests/VERIFICATION.zh-TW.md) 與 [Web 機器可讀紀錄](../WebSource/tests/verification.json)。

### Windows 與 Linux 封裝

Windows 在 Windows Server 2025 執行 NSIS 安裝後啟動程式；Linux 在 Ubuntu 24.04 解出 DEB，於 Xvfb 啟動封裝內的程式。兩邊均使用包內 Swift runtime，移除建置 SDK 的 runtime 搜尋路徑。

兩個相容版都讀到儲存的 green-dark 主題與新版 100%，完成正式介面的雙窗格及 bridge 驗證。Windows viewport 由 1142 變為 894，再恢復 1142；Linux 由 1422 變為 1113，再恢復 1422，符合 100%→125%→100% 的縮放。傳輸、重複同步、取消、報表及重新啟動的 helper smoke 也已通過。

## 正式發布檔

[0.8.0 release](https://github.com/jason840709/RcloneBrowserNext/releases/tag/v0.8.0) 的六個檔案均已下載核對 GitHub digest、大小及發布的 SHA-256 清單。來源 ZIP 的所有檔案與發布 commit 一致；Mac 包的版本 0.8.0／build 80、架構、最低 macOS 13.0、主程式雜湊及 Web／圖示資源均符合驗證來源。

Mac 在兩個 runner 都通過 ad-hoc 簽章檢查。Windows 與 Linux 的正式 release 檔雜湊也與各自完成原生啟動測試的封裝一致。

詳細 suite、job、封裝、發布時間與校驗值見 [原生及發布紀錄](verification/0.8.0-native.json)。

## 歷史紀錄

[0.7.0 完整驗證](VALIDATION_0.7.0.zh-TW.md) · [0.6.0 驗證](VALIDATION_0.6.0.zh-TW.md)
