# Rclone Browser Next 0.9.0 驗證記錄

正式 Web 回歸、五個平台工作與公開發布均已完成。發布來源為 [`ed76a5c269660fe919b7ffe664820baadff6790f`](https://github.com/jason840709/RcloneBrowserNext/commit/ed76a5c269660fe919b7ffe664820baadff6790f)；同一個 [CI run](https://github.com/jason840709/RcloneBrowserNext/actions/runs/39530803169) 驗證 macOS 15 的兩個架構、macOS 26 原生介面、Windows x64 與 Linux amd64。正式發布時間為 2026-10-21T02:17:47Z。

## 驗證結果

| 項目 | 實際結果 |
| --- | --- |
| 正式 Web 介面 | 189 通過、0 失敗、0 略過、0 重試後通過 |
| 本輪新增 Web 回歸另跑 | 8 通過、0 失敗、0 略過、0 重試後通過 |
| [macOS 15 Apple Silicon](https://github.com/jason840709/RcloneBrowserNext/actions/runs/39530803169/job/118995977857)，12 套 | 204 通過、0 失敗、1 略過 |
| [macOS 15 Intel](https://github.com/jason840709/RcloneBrowserNext/actions/runs/39530803169/job/118995977675)，12 套 | 204 通過、0 失敗、1 略過 |
| [macOS 26 Apple Silicon 原生介面](https://github.com/jason840709/RcloneBrowserNext/actions/runs/39530803169/job/118995977762)，4 套 | 53 通過、0 失敗、0 略過 |
| [Windows x64](https://github.com/jason840709/RcloneBrowserNext/actions/runs/39530803169/job/118995977486) | Rust 5、Platform 9、helper 10；封裝後原生 UI receipt 1 次成功 |
| [Linux amd64](https://github.com/jason840709/RcloneBrowserNext/actions/runs/39530803169/job/118995977511) | Rust 5、Platform 10、helper 9；封裝後原生 UI receipt 1 次成功 |

Mac 各架構分開計數；macOS 15 各略過的 Linux inotify 讀取計數案例，不影響已執行的可攜式 NAS 傳輸與比較測試。詳細 skip 原因與逐套計數保存在 [原生與發布 JSON](verification/0.9.0-native.json)。

Windows／Linux 的 Rust、Platform、helper 與原生 UI 使用不同計數單位，沒有加成單一測試總數。原生 UI receipt 表示一次成功的整體執行，不將內部斷言數重複計算。未獨立輸出的 failed／skipped 欄位在 JSON 保持 `null`：Platform 未回報 skipped，helper 未回報 failed／skipped，原生 UI receipt 未回報 skipped；不由 job 成功推成零。

## 啟動畫面與既有原生行為

三個 Mac 環境的 `MacStartupTests` 各 12 項通過，使用實際 AppKit 視窗、WKWebView 與正式 React 成品。六個主題冷啟動比對原生載入層與 Web 載入畫面的圖示／文字 frame、字級、色值與共用圖像；80%、125% 和保留的 135% 設定另驗證 zoom 後的實際幾何，也檢查已建立的載入層更新比例。

兩個仍呈白色的 WebKit fixture 驗證載入層持續遮住白畫面，等主題畫面形成後才交接；另一案例確認載入失敗時保留相同主題與可操作的重試入口。這些是實際 WebKit 與原生視窗的結果，不以 Chromium 的 CSS 值比對代替。

保留的 `MacInterfaceTests` 以受控 HTML 驗證 AppKit 事件與 WebKit 回執；`MacNavigationIntegrationTests` 另將原生導航事件接到正式 React 與真實 rclone 目錄。`MacIconTests` 驗證圖示、透明幾何、應用程式副本及簽章完整性。實體滑鼠、使用者雲端帳號及使用者電腦的 Dock 外觀不列為這次 CI 自動化涵蓋範圍。

## 正式 Web 介面

完整回歸於 2026-10-21T01:56:29.695Z 開始，耗時 173.3 秒；本輪新增的 8 個案例另跑通過，並已包含在完整 189 個案例中。測試使用正式 `Resources/Web` 成品、Chromium 與可重現的原生 bridge fixtures，測試前後來源和成品雜湊一致。

本輪確認三語工具列、設定齒輪與帳號按鈕對齊、儲存工作區／作業的不同保存語意與說明提示、六主題上淺下深的紫綠藍排列、複製／同步／移動的中性自然換行說明，以及可讀的限速摘要。既有側鍵去重、窗格與分頁歷史、介面比例和作業操作一併執行。

逐項結果、來源雜湊及環境見 [Web 驗證說明](../WebSource/tests/VERIFICATION.zh-TW.md) 與 [Web 機器可讀紀錄](../WebSource/tests/verification.json)。Chromium 回歸與原生 Mac 測試各自記錄，沒有把其中一套當成另一平台的執行證據。

## Windows／Linux 與發布檔

兩個相容版均使用封裝內的 Swift runtime，執行真實 rclone 的 dry run、複製、重複同步、取消、報表、作業與重新啟動檢查；Windows 另涵蓋帳號設定啟動器。安裝或解出套件後開啟原生視窗，驗證正式介面的兩個檔案窗格、bridge、已保存的 green-dark 主題、英文介面、比例變更與視窗寬度恢復。Windows／Linux 公開發布檔的雜湊與完成原生 UI smoke 的套件一致。

[0.9.0 Release](https://github.com/jason840709/RcloneBrowserNext/releases/tag/v0.9.0) 的六個公開檔案均已下載，核對 GitHub digest、大小與公開 SHA-256 清單。公開來源 ZIP 逐檔比對發布 commit；Mac ZIP 核對 0.9.0／build 90、架構、最低 macOS 13.0、主程式雜湊與 Web／圖示資源。Windows 解析安裝器 PE／版本資訊，Linux 核對 Debian 套件 metadata。六個檔案的 SHA-256、下載網址、CI job 與原始日誌雜湊集中在 [原生與發布 JSON](verification/0.9.0-native.json)。

Mac CI 執行 `codesign --verify --deep --strict`，使用 ad-hoc 簽章；沒有 Developer ID 簽章或 Apple notarization。下載 helper 只確認簽章封裝與 Mach-O 簽章欄位存在，**不執行 macOS 密碼學簽章驗證**；該項結果以 Mac CI 為準。Windows 安裝器的 x86 stub 也不代表安裝內容的架構，原生執行範圍以 Windows CI 為準。

執行中的 Dock 圖示可隨主題更新；退出後仍使用固定紫色 bundle 圖示。0.9.0 沒有重新引入會寫入 Finder metadata 的持久化方式，也沒有宣稱使用者看到的系統底板樣式已獲修正。

## 歷史紀錄

[0.8.1 原始驗證文件](VALIDATION_0.8.1.zh-TW.md) · [0.8.1 Web 紀錄](../WebSource/tests/history/0.8.1/verification.json) · [0.8.0 完整驗證](VALIDATION_0.8.0.zh-TW.md) · [0.8.0 原生與發布紀錄](verification/0.8.0-native.json)

歷史文件保留當時記錄的狀態；不把舊版結果或仍標示待 CI 的段落補算成本版驗證。
