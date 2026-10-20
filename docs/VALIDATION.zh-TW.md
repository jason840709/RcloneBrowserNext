# Rclone Browser Next 0.7.0 驗證記錄

**0.7.0 已通過 Apple Silicon Mac、Intel Mac、Windows x64 與 Linux x64 的原生建置及驗證，並完成正式發布。** 以下保留本機驗證與本輪四平台 CI 結果；過去版本的結果見 [0.6.0 驗證記錄](VALIDATION_0.6.0.zh-TW.md)。

## 已完成的本機驗證

2026-10-20 在 Linux x86_64 完成下列測試。Web 測試載入正式 bundle；Swift 測試使用 Swift 6.0.3，傳輸案例使用真實 rclone 1.75.2。

| 範圍 | 結果 | 已驗證的行為 |
| --- | --- | --- |
| Web 介面 | 163／163 通過 | 位置選單固定在圖示下方、長清單內部捲動、鍵盤與輸入法、五段縮放、三語視窗、傳輸報告及各平台功能入口 |
| CoreTests | 56／56 通過 | 檔案操作、複製與同步、選取範圍、停止與佇列控制、設定與工作保存 |
| NativeMessagesTests | 13／13 通過 | 三語訊息、操作範圍，以及檔名與外部診斷內容的保存 |
| TransferReportTests | 25／25 通過 | 比對與傳輸結果分列、重試事件、成功與失敗副本大小、報告匯出、第二次同步及符號連結 |
| Linux 相容版 helper | 8／8 通過 | 啟動與檔案清單、預覽、複製、第二次同步、報告與工作匯入匯出、取消及重新啟動後的狀態 |

Web 的型別檢查與正式建置也已通過；163 個案例沒有略過或重試。CoreTests、NativeMessagesTests 與 TransferReportTests 均為 0 失敗、0 略過。各組本機紀錄保存執行當時的原始碼雜湊與對應提交；後續跨平台修正由原生 CI 驗證。

穩定資料回歸使用三個測試檔：第一次複製傳輸兩個檔案，第二次同步傳輸 **0 個檔案**，三個檔案均比對相符，並刪除一個僅存在於目標的測試檔。符號連結案例驗證本機連結保存，以及用本機後端模擬 `.rclonelink` 檔案的儲存與還原。

介面案例與正式 bundle 雜湊見 [Web 驗證記錄](../WebSource/tests/VERIFICATION.zh-TW.md)；各組結果與證據雜湊見 [0.7.0 本機驗證摘要](verification/0.7.0-local.json)。

## 四平台原生 CI 結果

本輪四個平台使用同一份來源：[commit 5f60aab8874dece2913f54467c23c841736e987b](https://github.com/jason840709/RcloneBrowserNext/commit/5f60aab8874dece2913f54467c23c841736e987b)，對應 [Actions run 39454908404](https://github.com/jason840709/RcloneBrowserNext/actions/runs/39454908404)。四個平台完成後，[發布工作](https://github.com/jason840709/RcloneBrowserNext/actions/runs/39454908404/job/118745373113) 也已通過，於 **2026-10-20 16:21:39 UTC** 建立 [v0.7.0](https://github.com/jason840709/RcloneBrowserNext/releases/tag/v0.7.0)。

| 平台與 CI 工作 | CI 環境 | 已完成結果 |
| --- | --- | --- |
| [macOS arm64](https://github.com/jason840709/RcloneBrowserNext/actions/runs/39454908404/job/118739108177) | `macos-15` | App 建置、簽章與 ZIP 封裝通過；九套測試共 **157 通過、0 失敗、1 略過** |
| [macOS x86_64](https://github.com/jason840709/RcloneBrowserNext/actions/runs/39454908404/job/118739107893) | `macos-15-intel` | App 建置、簽章與 ZIP 封裝通過；九套測試共 **157 通過、0 失敗、1 略過** |
| [Windows x86_64](https://github.com/jason840709/RcloneBrowserNext/actions/runs/39454908404/job/118739108088) | Windows Server 2025，10.0.26100 | NSIS 安裝包建置、安裝、檔案操作、傳輸及原生視窗檢查通過 |
| [Linux x86_64](https://github.com/jason840709/RcloneBrowserNext/actions/runs/39454908404/job/118739108222) | Ubuntu 24.04 | `.deb` 建置、檔案操作、傳輸及封裝程式的原生視窗檢查通過 |

逐套結果、封裝檔案大小、SHA-256、artifact ID 與原生視窗收據保存於 [0.7.0 原生 CI 驗證 JSON](verification/0.7.0-native.json)。既有的本機驗證 JSON 保留原始執行來源與結果。

### macOS：九套原生測試

兩個架構執行同一組案例，結果分別列出。表格數字依序為通過／失敗／略過。

| 測試套件 | arm64 | x86_64 |
| --- | ---: | ---: |
| CoreTests | 55／0／1 | 55／0／1 |
| UpdaterTests | 20／0／0 | 20／0／0 |
| ToolsTests | 12／0／0 | 12／0／0 |
| NativeMessagesTests | 13／0／0 | 13／0／0 |
| FinderDropTests | 5／0／0 | 5／0／0 |
| AppReleaseTests | 8／0／0 | 8／0／0 |
| TransferReportTests | 25／0／0 | 25／0／0 |
| PlatformTests | 10／0／0 | 10／0／0 |
| MacInterfaceTests | 9／0／0 | 9／0／0 |
| **每個架構合計** | **157／0／1** | **157／0／1** |

CoreTests 的一個略過案例使用 Linux inotify 監看檔案讀取；macOS 沒有這個介面。可攜式 NAS 傳輸、比對與再次同步案例都有執行。

MacInterfaceTests 在真正的 AppKit 視窗與 WKWebView 內載入受控 HTML，完成一項文件載入、五項縮放與窗格座標檢查（80%、90%、100%、110%、125%），以及三項 ICNS 圖示解碼與套用。正式 React 介面的 163 項回歸另列於本機驗證章節。

兩份 App 均通過 `codesign --verify --deep --strict`；ZIP 內的主程式 SHA-256 與通過驗證的建置相符。App 的最低系統宣告為 macOS 13.0，使用 ad-hoc 簽章；Developer ID 簽署與 Apple 公證尚未提供。下載後的開啟方式見 [Mac 建置說明](BUILD_MAC.zh-TW.md)。

### Windows／Linux：相容版測試與封裝視窗

表格數字依序為通過／失敗／略過；原生視窗 smoke 各計一次完整執行。

| 驗證 | Windows x86_64 | Linux x86_64 |
| --- | ---: | ---: |
| Rust host 單元測試 | 3／0／0 | 3／0／0 |
| PlatformTests | 9／0／0 | 10／0／0 |
| Swift helper smoke | 9／0／0 | 8／0／0 |
| 封裝程式原生視窗 smoke | 1／0／0 | 1／0／0 |

Rust 測試檢查介面來源、外部網站範圍與原生橋接方法。PlatformTests 涵蓋 JSON 型別、路徑與根目錄判斷、檔案建立與讀取、原子取代、刪除保護，以及 rclone 執行檔格式與系統需求。POSIX 符號連結保護案例在 Mac／Linux 執行，Windows 建置不納入該案例。

helper 的八個共通案例涵蓋啟動與 Unicode 檔案清單、帳號設定保留引擎選項及外觀立即套用、預演、保留目標既有檔案的複製、再次同步零重傳、報告與作業匯入匯出、取消時保留完成檔案及清理暫存檔，以及重新啟動後的工作狀態。Windows 另外完成帳號設定程式的啟動案例。

原生視窗測試開啟封裝內的正式介面，經實際原生橋接取得下列結果：

| 檢查 | Windows | Linux |
| --- | --- | --- |
| 窗格／按鈕數 | 2／80 | 2／80 |
| 介面回報的平台／語言 | `win32`／`en` | `linux`／`en` |
| 套用 125% 縮放前後的 viewport 寬度 | 1028 → 822 | 1280 → 1024 |
| 程序結束碼 | 0 | 0 |

Windows 由 NSIS 安裝到獨立測試目錄，再啟動安裝後的程式；測試環境的 PATH 只保留系統路徑，程式使用隨附的 Swift 執行階段。本輪確認安裝與啟動成功，卸載未另做獨立結果核對。

Linux 使用 `dpkg-deb --extract` 解開 `.deb`，再於 Xvfb 開啟封裝程式；清除建置 SDK 的 `LD_LIBRARY_PATH` 後仍成功啟動。這項封裝驗證在已安裝系統依賴的 Ubuntu 24.04 執行；套件管理器的安裝方式與其他發行版的依賴要求見 [相容版安裝說明](BUILD_COMPATIBILITY.md)。Windows 使用 WebView2，Linux 使用 WebKitGTK；相容版的驗證範圍為本頁列出的本機操作、傳輸與原生視窗案例。

本頁的自動化測試使用獨立本機資料夾、alias 遠端、loopback 回應與示意介面資料。相容版測試收據及執行階段清單另保存在該輪 Actions artifacts。
