# Rclone Browser Next

**在 Mac 上，用雙面板管理本機、NAS 和雲端之間的檔案傳輸。**

繁體中文 · [English](README.en.md) · [版本與下載](https://github.com/jason840709/RcloneBrowserNext/releases) · [使用手冊](README.zh-TW.md) · [回報問題](https://github.com/jason840709/RcloneBrowserNext/issues)

![Rclone Browser Next 0.5.0：深紫主題的雙面板介面，中央選擇傳輸方向、操作方式與 Dry Run](docs/images/main-dark.png)

*0.5.0 介面，畫面使用示範資料。*

Rclone Browser Next 是由 **Jason Chen** 開發的 macOS [rclone](https://rclone.org/) 圖形介面。左右面板都能自行選擇位置：從 Mac 備份到 NAS、把 NAS 資料送到雲端，或在兩個本機資料夾之間複製，都使用同一套操作方式。

這個專案延續 Rclone Browser 的 Remotes、Jobs、Tasks 使用流程，重新安排成雙面板、中央傳輸控制和工作清單。目標是讓來源、目標與傳輸設定能在執行前看清楚，並將常用的備份方式儲存下來，之後直接使用。

## 開始使用

需要 **macOS 13 以上**，支援 **Apple Silicon 與 Intel**。在自己的 Mac 建置時，腳本會依硬體建立對應架構的 App。

1. 從 [Releases](https://github.com/jason840709/RcloneBrowserNext/releases) 選擇版本；要建置此份原始碼，也可以在專案頁選 **Code → Download ZIP**。請完整解壓縮，保留資料夾結構。
2. 雙擊 `Build-on-Mac.command`。完成後，同一個資料夾會產生並開啟 `Rclone Browser Next.app`。
3. 到設定選擇 **rclone 安裝位置**。可以使用既有的 `rclone` 執行檔，或在所選資料夾下載引擎；也能從 [rclone 官方網站](https://rclone.org/downloads/) 自行下載。
4. 點左上角 **帳號設定（Config）**，透過 rclone 的互動設定加入雲端或 NAS／伺服器連線。
5. 選好左右位置、方向和操作，按 **預演 · Dry Run** 查看預計動作，確認後再執行。

建置使用 Mac 已有的 **Xcode 或 Apple Command Line Tools**。介面資源已附在原始碼裡，一般建置不需要 Node.js 或 npm，也不會自行安裝 Homebrew、開發工具或 rclone。編譯快取、暫存與建置產物留在專案資料夾；缺少 Apple 工具時，腳本會說明並停止。

App 使用 Swift／AppKit 與 macOS 內建 WebKit；rclone 獨立放在你選的資料夾。這讓 App 不必另外攜帶瀏覽器引擎或 rclone，兩者也能分開更新。App 的體積不包含外部 rclone。

本機建置會建立並驗證 **ad-hoc 簽章**。這不是 Apple Developer ID 簽章或公證，從網路下載的 App 仍可能受到 Gatekeeper 限制。安裝方式、檔案位置及問題排查見 [Mac 建置說明](docs/BUILD_MAC.zh-TW.md)。

## 日常操作

| 功能 | 可以做什麼 |
| --- | --- |
| 雙面板與分頁 | 左右各自瀏覽本機、已掛載磁碟、雲端與 NAS／伺服器；每個分頁保留自己的返回、前進歷史，支援滑鼠側鍵 |
| 複製、移動、同步 | 自由切換左右傳輸方向，也能只處理勾選的檔案與資料夾 |
| 預演 Dry Run | 使用真正的 rclone 預演，查看依目前設定會採取的動作，不實際複製、移動或刪除資料 |
| 儲存作業 Tasks | 保存來源、目標、操作及完整傳輸選項；每個作業都有 Dry Run、Run、Edit、Delete |
| 記住工作環境 | 保存左右資料夾、方向及傳輸設定，下次開啟時還原；還原不會自動開始工作 |
| 進度與記錄 | 顯示容量、檔案數量、小數百分比、平均速度、剩餘時間和日誌，並可取消工作 |
| 外觀與語言 | 深紫、淺紫、深藍、淺藍四種主題；繁體中文、English、日本語，支援跟隨系統語言 |
| 連線設定 | 代理、IPv4／IPv6、連線與閒置逾時、請求頻率、頻寬限制及其他 rclone 傳輸選項 |

預設使用深紫主題，以中性深灰作底色，紫色標示選取與主要操作。外觀與語言變更會立即套用。「跟隨系統」會將中文系統對應到繁體中文、日文系統對應到日本語，其餘使用 English。

### 同步以來源為準

**同步只修改目標，讓目標在指定範圍內與來源一致。** 它會更新目標檔案，並刪除目標中來源已沒有的檔案；來源不會被反向改動。複製則保留目標中額外的檔案，移動會在傳送成功後移除對應來源。

排除規則、選取範圍及略過條件仍會影響結果。例如，被排除的目標檔案預設會保留；若選擇略過已存在或較新的檔案，目標也可能保留與來源不同的版本。詳見 [操作手冊](README.zh-TW.md) 與 [rclone 同步說明](https://rclone.org/commands/rclone_sync/)。

Dry Run 不改動檔案，但仍需讀取目錄和比較資訊；選擇雜湊比對時，也可能讀取檔案內容。預演後若資料有變動，正式執行的結果也會跟著改變。

## NAS 與雲端備份方案

0.5.0 在操作選單加入三種常用方案。選擇方案只套用設定，**不改變目前位置，也不開始傳輸**。不常用的方案可用 × 隱藏，之後在傳輸選項中還原。

| 方案 | 同時傳輸／檢查檔案數 | 適合的起點 |
| --- | ---: | --- |
| 電腦 → NAS | 1／10 | 減少多檔同時讀寫，並停用單一檔案的多路並行傳輸 |
| NAS → 雲端 | 1／10 | 降低 NAS 同時讀取多個檔案的負擔 |
| 電腦 → 雲端 | 4／8 | 允許多檔並行傳輸，可再依網路與服務調整 |

三個方案都採用 **單向同步、傳輸時刪除、不限刪除數**，比較方式為 **大小與修改時間，不計算本機雜湊**。這些是可調整的起始值，不保證適合每台 NAS 的最高速度；單檔傳輸也不能保證磁碟沒有碎片。

Finder 掛載的 SMB 磁碟，對 rclone 來說屬於本機檔案系統。停用本機雜湊，可避免為了計算雜湊而透過網路讀回整份檔案。不過，**大小與時間都沒變的內容修改可能被略過，本機端也不再參與傳輸後的內容雜湊驗證**。時間資訊不一致時，未改動內容的檔案也可能被重傳。這項設定只影響本機後端，沒有停用所有雲端後端的雜湊能力。[比較方式與取捨](docs/NAS_COMPARISON.zh-TW.md)

方案會排除 `.DS_Store`、`._*`、`.Spotlight-V100`、`.Trashes`、`.fseventsd`、`.TemporaryItems` 這些指定的 Mac 項目，不會一併排除所有隱藏檔。`._*` 可能帶有資源分支或延伸資料，需要保留時請移除這條排除規則。

NAS 傳到雲端、或跨雲端傳輸時，真正需要更新的資料通常仍會經過執行 rclone 的 Mac。能否由服務端直接複製取決於後端支援；減少雜湊讀取不會改變實際傳輸路徑。[rclone 跨服務傳輸說明](https://rclone.org/faq/#can-rclone-sync-directly-from-drive-to-s3)

升級到 0.5.0 後，**已儲存作業和記住的工作環境保留原本選項**。要改用新方案，請編輯作業並重新儲存。

## 0.5.0 的介面與進度調整

- **資料夾資訊更集中：** 選取的分頁與內容底色相連，位置、路徑與導覽按鈕合併成一列，每個分頁可獨立返回、前進。
- **提示不改變版面：** 目錄錯誤的圖示、說明與重試按鈕放在同一張卡片；短暫通知浮在畫面上，約五秒後收起，可手動關閉。空作業頁直接提示新增作業。
- **以容量進展估算速度：** 以既有統計估算最近 60 秒平均值，完成後保留整次平均；百分比顯示一位小數。

速度估算不另外掃描、讀取或雜湊檔案。它表示每秒處理的資料量；遇到 macOS 系統複製、APFS 或服務端複製時，不等同網路流量。剩餘時間是粗估，仍會受小檔、檢查、刪除與尚未列舉完成的目錄影響。[實作依據](docs/RESEARCH_0.5.0.md) · [完整修改記錄](docs/CHANGELOG.zh-TW.md)

## rclone 與 App 分開更新

| 選單入口 | 更新方式 |
| --- | --- |
| 檢查 rclone 更新 | 檢查官方穩定版，確認後下載、驗證並替換所選位置的引擎；支援啟動時檢查、稍後處理或跳過某個版本 |
| 檢查 Rclone Next 更新 | 檢查本專案的 GitHub 正式 Release，提供版本資訊與下載頁；不會直接覆寫正在執行的 App |

選擇新的 rclone 安裝位置後，App 會立即儲存、探測版本並刷新。引擎替換前會檢查版本與 Mac 相容性並備份舊檔；失敗時保留或還原舊版。引擎更新不需要重建整個 App。代理支援與更新限制見 [設定說明](README.zh-TW.md#設定)。

## 開發與驗證

一般使用只需在 Mac 建置 App。修改介面時才需要 `WebSource` 的開發工具；套件版本鎖定在 `package-lock.json`。本機建置使用已產生的 `Resources/Web`。詳見 [開發說明](docs/DEVELOPMENT.md)。

0.5.0 本輪已在 Linux 完成 **101 項 Swift 測試**，介面完成 **86 個不同案例**；測試使用獨立檔案、rclone 測試目錄與模擬的原生訊息，不使用私人雲端帳號。這些結果不等同 Mac 原生介面、實體 NAS 或各家雲端的實測；**本輪 0.5.0 macOS CI 結果尚待確認**。每項測試的平台、範圍與最新結果列在 [驗證記錄](docs/VALIDATION.zh-TW.md)。

要在自己的 Mac 執行測試，可使用 `Test-on-Mac.command` 並提供 rclone 路徑。沒有提供可用引擎時，需要真實 rclone 的案例會標為略過。

## 作者、致謝與授權

作者：**Jason Chen**。程式採 [MIT License](LICENSE)，圖示由 Jason Chen 提供。

[rclone](https://rclone.org/) 提供連接儲存服務與傳輸檔案的引擎；[mmozeiko／RcloneBrowser](https://github.com/mmozeiko/RcloneBrowser)、[kapitainsky／RcloneBrowser](https://github.com/kapitainsky/RcloneBrowser) 與 [RcloneBrowser2](https://github.com/downer08tutti/RcloneBrowser2) 提供本專案研究的操作流程與功能參考。Next 使用新的 Swift／AppKit host 與 React 介面，是獨立實作；與原版的保留項目及差異見 [功能對照](docs/FEATURE_MATRIX.zh-TW.md)。

ForkLift 提供雙面板操作與版面參考，本專案沒有散布它的程式碼或私有資源。第三方前端套件聲明隨 [Web 資源](Resources/Web/THIRD_PARTY_NOTICES.txt) 附上。
