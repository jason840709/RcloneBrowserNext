# Rclone Browser Next 0.5.0 驗證記錄

驗證日期：2026-10-20 UTC。本記錄對應 0.5.0 的 Swift 來源、正式 Web 資源與本機建置腳本；先前版本的執行結果不列入本次通過數。

## 結果與範圍

**Linux 六套 Swift 測試共 101 項通過；介面有 86 個不同案例通過。Apple Silicon 與 Intel 的 macOS CI 也已完成，各為 100 項通過、0 失敗、1 項略過。** 不同平台執行同一批案例，分開列出，沒有加總成更多不同的測試。

Linux 各套取本輪最後一次成功執行的結果，初次測試和後續修正回歸不重複計數。Core 與另外五套測試核對的是同一份最終 Core 產品來源；Linux 全部無失敗、略過或編譯警告。macOS 的略過原因與既有 API 警告見下方 CI 記錄。正式介面的執行組成、測試資料與交付資源雜湊保留在 JSON 記錄。

Swift 環境是 Linux x86_64、Swift 6.0.3（Swift 5 語言模式），使用經官方校驗值核對的 rclone v1.75.2。測試只使用獨立暫存檔案、alias 遠端與 loopback HTTP 回應，沒有接觸日常備份、真實 NAS 或雲端帳號。

| 測試套件 | 通過 | 主要範圍 |
| --- | ---: | --- |
| CoreTests | 43 | 真實傳輸、完整作業與環境、schema 5 遷移、60 秒速度估算、NAS 旗標、網路參數、佇列及確認快照 |
| UpdaterTests | 20 | rclone 版本、校驗、備份／替換／復原、代理與失敗後重試 |
| ToolsTests | 12 | 目錄樹、清單匯出、串流、停止與失敗清理 |
| NativeMessagesTests | 13 | 三語原生提示，保留檔名、路徑與後端診斷 |
| FinderDropTests | 5 | 檔案 URL、來源範圍、類型與符號連結驗證 |
| AppReleaseTests | 8 | App 正式版比較、回應邊界、來源限制、未發布與代理錯誤 |

[驗證摘要 JSON](verification/0.5.0.json) 保留各套退出碼、來源雜湊與測試範圍。[SOURCE_MANIFEST.json](../SOURCE_MANIFEST.json) 可核對交付包內各檔案的大小與 SHA-256；manifest 本身不自我雜湊。

## 核心：真正執行的行為

CoreTests 會啟動真正的 rclone，驗證結果與檔案內容，並非只檢查指令文字。

- 本機到本機、本機到 alias、alias 到本機、alias 到 alias 的複製。alias 指向測試目錄，不能代替各家雲端服務的相容性測試。
- 原版 Compare 選項、全部重傳與 NAS 配置，包含同大小但內容變更、第二次備份、修改時間與略過檔案。
- 用 Linux inotify 觀察目的檔案開啟／讀取，驗證 `--local-hashes none` 可避免單純為 local 雜湊讀回內容。測試在獨立的 `/tmp` fixture 執行，沒有放寬「不讀取目的端內容」的判斷。條件與限制見 [NAS 比對](NAS_COMPARISON.zh-TW.md)。
- 同步三種刪除時機、刪除上限（包括 `-1` 不限）、排除規則、大小／日期／深度篩選與勾選範圍。Dry Run 確認來源及目的端沒有檔案變動。
- 移動、重新命名、保留空目錄、略過已存在檔案，以及拒絕可能誤刪來源的 Move 與 skip-newer 組合。
- 特殊檔名逐字傳入 argv；拒絕重疊來源／目標、失效選取與會不當擴大範圍的參數。
- 真實限速工作產生速度與 ETA；未知 ETA 保持未知。驗證佇列、取消、更新維護互斥，預設不限制同時執行的工作。
- 舊版預設工作上限 2 一次性遷移為不限，明確選用的其他上限仍保留；新版 schema 的值 2 不會再被當作舊預設清除。
- 完整儲存／編輯／還原傳輸 request 與啟動環境；`savedWorkspace` 不會自行啟動傳輸。系統語言依第一順位的系統語言解析。
- rclone 來源 IP、連線／閒置逾時、TPS、User-Agent 與 HTTP/2 參數；Task 自己的明確設定優先，空白逾時沿用全域值。
- 設定 partial patch 依序保存、失敗回復、位置切換與查詢互斥，更新與外觀設定交錯時不清空引擎路徑。

回歸包含實際同步的確認快照案例：確認前解析完整 request，確認期間變更全域刪除上限與排除規則，最後執行仍必須使用原確認快照。結果保留被排除檔案，按確認的刪除規則處理 obsolete 檔案。

0.5 新增／調整的驗證包含：

- 新起始值是 `maxDelete=-1`、`deleteMode=during`、`localHashPolicy=none`。舊全域預設只遷移一次；已儲存作業與工作環境保留原本參數，稀疏的舊記錄也先補回舊預設，不因升級擴大刪除範圍。
- 本機→NAS 方案實際使用單檔傳輸、10 個檢查工作及 `--multi-thread-streams=0`。隱藏方案資料只接受三個已知 ID，去除重複並限制長度。
- rclone 回報 `speed=0`、`eta=null` 但容量持續增加時，仍可由既有統計估算速度與 ETA。測試涵蓋停滯、同秒取樣、缺少 elapsed、計數重設、不合法數值、只剩檔案數的 ETA 與完成後平均速度。
- 單一工作的速度視窗最多保留 64 個數值樣本。10,000 次純數值更新的 Linux 微型測試約 0.068 秒；這不含每檔資料列，不能當作 Mac、NAS 或整體傳輸效能實測。
- `--local-hashes=none` 的已存在檔案若修改時間不同，可能直接重傳；`--no-update-modtime` 不被誤認成停用本機雜湊的替代方案。

Linux inotify 只驗證該測試條件下的本機後端讀取。在 Mac 執行時此案例會明確略過；不能把預期通過數當成實際 Mac 結果。

## 更新器與輔助工具

引擎更新器測試版本排序、SHA-256 公開向量與校驗檔解析、暫時失敗恢復、同程序再次檢查、Mach-O 架構與最低 macOS 版本。檔案案例涵蓋原子替換、備份、替換後失敗還原、還原失敗如實回報、首次安裝失敗不留殘缺執行檔、備份符號連結防護及自有備份數量。

App 更新器獨立檢查配置專案的 GitHub 正式版，涵蓋數值版本比較、拒絕 draft／prerelease／不完整 JSON、512 KiB 大小界限、禁止轉址、下載頁必須屬於同一專案、HTTP 錯誤及失敗後再試。404 回報沒有可取得的正式版本，不把它當成「已經是最新版」。

原生更新使用 macOS URLSession 的代理設定。手動 HTTP CONNECT 與 SOCKS5 保留支援；代理位址本身若以 `https://` 開頭，目前會在建立連線前明確拒絕，避免把 HTTPS-to-proxy 悄悄當成普通 HTTP 代理。rclone 傳輸不受這項原生限制影響。

**沒有在 Mac 下載並替換真實使用中的 rclone，也未實測 Mac 的 HTTP CONNECT、SOCKS 握手或代理 DNS 行為。** 下載回應與 Mac 執行檔標頭使用可控制的 fixture。

ToolsTests 使用真正的 rclone 驗證有上限的目錄樹、CSV／TXT 匯出、失敗保留既有報告與符號連結防護。串流以 `rclone cat` 傳送固定內容到測試播放器程序，核對完整位元組，並驗證停止與錯誤清理。公開連結只驗證回應解析與 URL 限制；掛載只驗證參數契約。沒有建立真實雲端分享連結、啟動 FUSE 掛載、操作播放器 GUI 或驗證 Mac 卸載。

## 介面、四種配色與語言

TypeScript 型別檢查與正式建置通過。Playwright 從 `file://` 載入交付用的 `Resources/Web`，透過測試專用 native host fixture 回覆訊息。正式 App 沒有範例帳號、假檔案系統或模擬傳輸。

第一次完整執行 81 個案例，78 個通過；另外 3 個案例仍預期舊的比對提示、舊版本 fixture 或不正確的速度小數。更正測試預期後，對這 3 個案例及 5 個新增案例補驗，8 個全部通過。兩次執行之間的正式資源未改動；總計 78＋3＋5＝86 個不同案例，不把重跑重複計數。

回歸涵蓋三種語言、四種主題與 1060 × 680／1440 × 900 兩種尺寸，也驗證設定即時套用、失敗恢復、Config 刷新、Compare／同步細項、位置／分頁／選取隔離、欄寬保存、鍵盤選單及減少動態效果。保留並重新驗證的既有範圍：

- 系統語言解析；手動選定語言優先。
- 完整作業編輯、Run／Dry Run、另存新作業與移除。
- 記住雙面板與傳輸選項後重啟，修改預設資料夾不被舊工作環境蓋回。
- 修改作業來源時清除舊來源選取並提示，只改目標則保留有效來源選取。
- 網路 structured patch 即時保存，失敗不留下半套介面狀態。
- 四種配色的實際 PNG 像素檢查：縮短各欄後，斑馬紋仍延伸到右側剩餘空間，並填滿清單下方。
- 說明提示可由滑鼠與鍵盤叫出；未發布版本不提供無效下載入口。

80 組指定前景／背景色配對檢查通過。這是限定配色 token 的測量，不是完整 WCAG 或 VoiceOver 認證。人工另檢視四種主題、窄視窗、作業編輯器、設定與 tooltip 的邊框、分隔線及文字間距。

0.5 的新案例包括整張錯誤卡片、空作業頁、懸浮通知不改變版面及自動關閉、三種方案與隱藏／還原、單向同步說明、新預設、各分頁歷史與側鍵橋接、合併導覽列、連續分頁底色、速度／ETA／小數百分比及大目錄更新成本。瀏覽器 fixture 測試原生事件訊息契約，不能代替實體滑鼠在 WKWebView 中的操作。

詳細執行數字、補驗原因與範圍見 [Web 驗證記錄](../WebSource/tests/VERIFICATION.zh-TW.md) 及其 [JSON](../WebSource/tests/verification.json)。測試預覽只供檢查，不納入 App 或發行包。

App 的 `.icns` 與介面 SVG 圖示維持使用者提供的 v2，SHA-256 與來源相符，沒有重新繪製。

## macOS CI：雙架構建置、簽章與整合測試

[GitHub Actions run 39408177020](https://github.com/jason840709/RcloneBrowserNext/actions/runs/39408177020) 對應來源 commit `36aef715a687b83657e5f99707cacc0c8dcc9f51`。2026-10-20，Apple Silicon、Intel 與 Release 三個工作全部完成並成功；[0.5.0 Release](https://github.com/jason840709/RcloneBrowserNext/releases/tag/v0.5.0) 已產生完整原生 App 與本機建置包。

| 測試套件 | Apple Silicon | Intel |
| --- | --- | --- |
| CoreTests | 42 通過、1 略過 | 42 通過、1 略過 |
| UpdaterTests | 20 通過 | 20 通過 |
| ToolsTests | 12 通過 | 12 通過 |
| NativeMessagesTests | 13 通過 | 13 通過 |
| FinderDropTests | 5 通過 | 5 通過 |
| AppReleaseTests | 8 通過 | 8 通過 |
| **各架構合計** | **100 通過、0 失敗、1 略過** | **100 通過、0 失敗、1 略過** |

略過的是使用 Linux inotify 的檔案讀取監測，macOS 不提供這個 API；其他可攜的 NAS 比對與傳輸案例仍實際執行。兩架構使用 macOS 15.7.9、Apple Swift 6.1.2 與 rclone 1.75.2，App 最低系統為 macOS 13.0。

- 原生 Apple SDK 編譯與連結成功，產物分別驗證為 `arm64` 及 `x86_64`，版本為 0.5.0、build 50。
- 完整資源裝入後才建立 ad-hoc 簽章；兩個架構各兩次通過 `codesign` 檢查，包含 `valid on disk` 與 `satisfies its Designated Requirement`。
- App 磁碟用量由 `du -sk` 測得為 **2.50 MiB（Apple Silicon）／2.55 MiB（Intel）**，不含獨立安裝的 rclone。它與 ZIP 大小、檔案邏輯位元組數是不同的測量。
- 兩架構各有一項既有 `NSWorkspace.openFile(_:withApplication:)` 棄用警告，位於 `Sources/Mac/AppMain.swift:850`；沒有編譯錯誤。
- 10,000 次進度數值快照，在 arm64 runner 為 0.090273 秒、Intel runner 為 0.171147 秒，最多保留 64 個樣本。這是 CI 微型量測，不能推論使用者 Mac 或實體 NAS 的整體傳輸效能。

完整結果與原生主程式 SHA-256 見 [macOS CI JSON](verification/0.5.0-macos-ci.json)。Mac 的實際結果與前述 Linux 的 101 項分開保存；本頁後續文件排版更新沒有改動該 commit 的產品來源或已發布原生 ZIP。

### 仍需要實際使用環境確認的範圍

CI 使用 `--no-launch` 建置，沒有操作互動 GUI，也沒有連線到使用者的實體 NAS 或雲端帳號。Cmd-Q、AppKit 選單、WKWebView、Finder 拖放、Terminal Config、系統通知、選單列與掛載仍需在實際桌面環境確認。ad-hoc 簽章完整性驗證不等於 Developer ID 簽章或 Apple 公證，也不保證瀏覽器下載後可直接通過 Gatekeeper。

滑鼠側鍵使用視窗內的 AppKit 事件監聽：按下時傳入左右面板座標、消耗同一側鍵的按下與放開事件，避免 WebKit 重複導航；原生或 HTML 對話框開啟時不操作歷史。監聽器在換視窗與離開時清理。已核對原生編譯、事件訊息契約及前端歷史行為，尚未用實體滑鼠或廠商自訂驅動程式驗證。

整合時保留了作者儲存庫的 Clang module cache 修正，以及兩個 APFS 測試 fixture 的串流設定；後者只影響測試，不會停用一般操作中的 APFS 複製加速。發布流程只有在兩個 Mac 工作成功且版本尚未存在時才建立 Release，既有附件不被後續文件修改取代。

### 下載與本機建置

Release 提供 Apple Silicon、Intel 原生 App，以及完整 **Mac 本機建置包**。`Build-on-Mac.command` 使用 Mac 既有的 Apple 開發工具，編譯來源、裝入完整資源、建立 ad-hoc 本機簽章並驗證。一般建置不安裝額外工具、不下載 Web 開發依賴、不關閉 Gatekeeper；編譯快取與產物放在同一專案資料夾。

## 自行重跑

一般使用者只需本機建置。要驗證自己的 Mac，可再執行：

```bash
/bin/bash "/來源包路徑/Build-on-Mac.command" --no-launch
/bin/bash "/來源包路徑/Verify-App.command"
/bin/bash "/來源包路徑/Test-on-Mac.command" "/rclone資料夾/rclone"
```

六套測試使用專案內的獨立資料。不提供相容 rclone 時，需要引擎的項目會標示略過；不要把這種結果當成本次 101 項完整通過。Web 重跑方式在 [Tests/Web](../Tests/Web/README.md)，屬於選用開發流程，一般 Mac 建置不下載 Node.js、測試瀏覽器或字型。

原版功能與目前保留差異列在 [功能對照](FEATURE_MATRIX.zh-TW.md)。檔案體積、介面截圖與測試數量都不能單獨代表完整功能等價。
