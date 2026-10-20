# Rclone Browser Next 0.4.0 驗證記錄

> 以下保留原 0.4.0 交付時的測試結果與當時狀態，不代表本次重新執行。GitHub 發布整理與目前狀態請看 [發布整理紀錄](PUBLICATION.zh-TW.md)；原交付 manifest 保留在 `archive/0.4.0/SOURCE_MANIFEST.original.json`。

驗證日期：2026-10-20 UTC。本記錄對應 0.4.0 的 Swift 來源、正式 Web 資源與本機建置腳本；先前版本的測試數字不列入。

## 結果與範圍

**六套 Swift 測試共 95 項通過，正式介面完整回歸 62 項通過。** 介面最後的比對說明與更新狀態修正另補驗 3 項，全部通過。Swift 各套取本輪最後一次成功執行的結果，初次完整測試和後續修正回歸不重複計數。後續回歸補驗確認快照、原生代理限制及其翻譯。列出的 Swift 測試均無失敗、略過或編譯警告。

Swift 環境是 Linux x86_64、Swift 6.0.3（Swift 5 語言模式），使用經官方校驗值核對的 rclone v1.75.2。測試只使用獨立暫存檔案、alias 遠端與 loopback HTTP 回應，沒有接觸日常備份、真實 NAS 或雲端帳號。

| 測試套件 | 通過 | 主要範圍 |
| --- | ---: | --- |
| CoreTests | 37 | 真實傳輸、完整作業與環境、設定遷移、網路參數、佇列及確認快照 |
| UpdaterTests | 20 | rclone 版本、校驗、備份／替換／復原、代理與失敗後重試 |
| ToolsTests | 12 | 目錄樹、清單匯出、串流、停止與失敗清理 |
| NativeMessagesTests | 13 | 三語原生提示，保留檔名、路徑與後端診斷 |
| FinderDropTests | 5 | 檔案 URL、來源範圍、類型與符號連結驗證 |
| AppReleaseTests | 8 | App 正式版比較、回應邊界、來源限制、未發布與代理錯誤 |

[驗證摘要 JSON](verification/0.4.0.json) 保留各套退出碼、來源雜湊與測試範圍。[SOURCE_MANIFEST.json](../SOURCE_MANIFEST.json) 可核對交付包內各檔案的大小與 SHA-256；manifest 本身不自我雜湊。

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

本輪另加一個實際同步 regression：確認前解析完整 request，確認期間變更全域刪除上限與排除規則，最後執行仍必須使用原確認快照。結果保留被排除檔案，按確認的刪除規則處理 obsolete 檔案。

Linux inotify 只驗證該測試條件下的本機後端讀取。在 Mac 執行時此案例會明確略過；不能把預期通過數當成實際 Mac 結果。

## 更新器與輔助工具

引擎更新器測試版本排序、SHA-256 公開向量與校驗檔解析、暫時失敗恢復、同程序再次檢查、Mach-O 架構與最低 macOS 版本。檔案案例涵蓋原子替換、備份、替換後失敗還原、還原失敗如實回報、首次安裝失敗不留殘缺執行檔、備份符號連結防護及自有備份數量。

App 更新器獨立檢查配置專案的 GitHub 正式版，涵蓋數值版本比較、拒絕 draft／prerelease／不完整 JSON、512 KiB 大小界限、禁止轉址、下載頁必須屬於同一專案、HTTP 錯誤及失敗後再試。404 回報沒有可取得的正式版本，不把它當成「已經是最新版」。

原生更新使用 macOS URLSession 的代理設定。手動 HTTP CONNECT 與 SOCKS5 保留支援；代理位址本身若以 `https://` 開頭，目前會在建立連線前明確拒絕，避免把 HTTPS-to-proxy 悄悄當成普通 HTTP 代理。rclone 傳輸不受這項原生限制影響。

**沒有在 Mac 下載並替換真實使用中的 rclone，也未實測 Mac 的 HTTP CONNECT、SOCKS 握手或代理 DNS 行為。** 下載回應與 Mac 執行檔標頭使用可控制的 fixture。

ToolsTests 使用真正的 rclone 驗證有上限的目錄樹、CSV／TXT 匯出、失敗保留既有報告與符號連結防護。串流以 `rclone cat` 傳送固定內容到測試播放器程序，核對完整位元組，並驗證停止與錯誤清理。公開連結只驗證回應解析與 URL 限制；掛載只驗證參數契約。沒有建立真實雲端分享連結、啟動 FUSE 掛載、操作播放器 GUI 或驗證 Mac 卸載。

## 介面、四種配色與語言

TypeScript 型別檢查與正式建置通過。Playwright 從 `file://` 載入交付用的 `Resources/Web`，透過測試專用 native host fixture 回覆訊息。正式 App 沒有範例帳號、假檔案系統或模擬傳輸。

完整回歸涵蓋三種語言、四種主題與 1060 × 680／1440 × 900 兩種尺寸，也驗證設定即時套用、失敗恢復、Config 刷新、Compare／同步細項、位置／分頁／選取隔離、欄寬保存、鍵盤選單及減少動態效果。0.4 增加：

- 系統語言解析；手動選定語言優先。
- 完整作業編輯、Run／Dry Run、另存新作業與移除。
- 記住雙面板與傳輸選項後重啟，修改預設資料夾不被舊工作環境蓋回。
- 修改作業來源時清除舊來源選取並提示，只改目標則保留有效來源選取。
- 網路 structured patch 即時保存，失敗不留下半套介面狀態。
- 四種配色的實際 PNG 像素檢查：縮短各欄後，斑馬紋仍延伸到右側剩餘空間，並填滿清單下方。
- 說明提示可由滑鼠與鍵盤叫出；未發布版本不提供無效下載入口。

80 組指定前景／背景色配對檢查通過。這是限定配色 token 的測量，不是完整 WCAG 或 VoiceOver 認證。人工另檢視四種主題、窄視窗、作業編輯器、設定與 tooltip 的邊框、分隔線及文字間距。

最後提示文案與未發布狀態修正的補驗範圍見 [Web 驗證記錄](../WebSource/tests/VERIFICATION.zh-TW.md) 及其 [JSON](../WebSource/tests/verification.json)。測試預覽只供檢查，不納入 App 或發行包。

App 的 `.icns` 與介面 SVG 圖示維持使用者提供的 v2，SHA-256 與來源相符，沒有重新繪製。

## Mac 與 GitHub：尚未完成的驗證

最終 Core／Mac Swift 來源通過 arm64、x86_64 的語法解析；shell 入口語法與 Info.plist 已檢查。Info.plist 為 0.4.0、build 40、最低 macOS 13.0、三種本地化與 v2 圖示。

**語法解析不是 Apple SDK 型別檢查。** 此環境沒有 macOS SDK，沒有完成 Mac 連結、實機啟動、codesign 或 Gatekeeper 驗證。Cmd-Q、AppKit 選單、WKWebView 橋接、Finder 拖放、Terminal Config、通知、狀態列及掛載 API 均有實作與來源審查，但仍待 Mac 實機驗證。

本輪尚未成功建立公開 GitHub 專案，也沒有執行 GitHub macOS CI。原始碼已附 Apple Silicon 與 Intel 的建置／測試 workflow；「已附 workflow」不等於「CI 已通過」。因此 App 更新目前尚無可下載的 GitHub 正式版本。

交付物是 **Mac 本機建置包**，不是宣稱在 Mac 驗證完成的預編譯 App。`Build-on-Mac.command` 使用既有 Apple 工具，編譯來源、裝入完整資源、建立 ad-hoc 本機簽章並驗證。它不安裝額外工具、不下載 Web 開發依賴、不關閉 Gatekeeper，也不把本機簽章當成 Developer ID 或 Apple 公證。

## 自行重跑

一般使用者只需本機建置。要驗證自己的 Mac，可再執行：

```bash
/bin/bash "/來源包路徑/Build-on-Mac.command" --no-launch
/bin/bash "/來源包路徑/Verify-App.command"
/bin/bash "/來源包路徑/Test-on-Mac.command" "/rclone資料夾/rclone"
```

六套測試使用專案內的獨立資料。不提供相容 rclone 時，需要引擎的項目會標示略過；不要把這種結果當成本次 95 項完整通過。Web 重跑方式在 [Tests/Web](../Tests/Web/README.md)，屬於選用開發流程，一般 Mac 建置不下載 Node.js、測試瀏覽器或字型。

原版功能與目前保留差異列在 [功能對照](FEATURE_MATRIX.zh-TW.md)。檔案體積、介面截圖與測試數量都不能單獨代表完整功能等價。
