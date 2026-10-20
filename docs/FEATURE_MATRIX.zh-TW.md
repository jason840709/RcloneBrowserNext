# 功能對照與架構

Rclone Browser Next 0.4.0 延續原版的位置瀏覽、傳輸設定、工作與 Tasks 四個責任區域，改成左右面板與 Swift／AppKit host。以下以公開來源核對功能與實作位置，不以 App 體積推論完成度。

## 原版與新版的責任分工

| 原版 Rclone Browser | 職責 | Next 0.4.0 |
|---|---|---|
| `remote_widget.cpp`、`item_model.cpp` | 瀏覽位置、列檔案與操作項目 | `BrowserPane.tsx`、`useBrowser.ts`、`RcloneEngine.swift` |
| `transfer_dialog.cpp/.ui` | 傳輸表單 | 主傳輸選項與完整 Task 編輯器 |
| `job_options.cpp/.h` | 保存選項、產生 rclone 參數 | `EngineTransferOptions`、`EngineTransferRequest` |
| `MainWindow::addTransfer` | 建立獨立傳輸程序 | `RcloneEngine` 的工作管理與 `Process` |
| `job_widget.cpp` | 進度、工作記錄、停止 | `Jobs.tsx` 與 rclone JSON 統計 |
| `list_of_job_options.cpp` | 儲存與載入 Tasks | `EngineStorage` 的 JSON 與完整 Tasks 介面 |
| `preferences_dialog.cpp/.ui` | 執行檔、路徑、介面與預設值 | `Settings.tsx`、原子保存、即時刷新 |

原版 `MainWindow::addTransfer` 直接建立 `QProcess`；`mJobCount` 用來計數，沒有整體並行上限。Next 0.4.0 預設亦不限制工作數，另提供可選上限。單一 rclone 工作的 `--transfers` 與 `--checkers` 仍各自有效。

公開參考：[原版來源](https://github.com/kapitainsky/RcloneBrowser/tree/45bf7411839b0919c488a3e3a0a5272b50c9fc7b)、[RcloneBrowser2](https://github.com/downer08tutti/RcloneBrowser2)。原始碼的分工與操作語意可對照；這不是將 Qt 程式碼直接改名的 fork。

## 傳輸與 Tasks

| 功能 | Next 的處理 |
|---|---|
| Copy / Move / Sync | 左到右、右到左；來源與目標均可為本機或 remote |
| Dry Run | 主流程與 Tasks 都有直接入口；實際執行 rclone `--dry-run` |
| 比較方式 | 大小＋修改時間、大小＋雜湊、僅時間、僅大小、僅雜湊與全部傳輸；另有 NAS metadata 模式 |
| Skip file | 略過已存在、略過目標較新；與移動語意衝突的組合會阻止執行並要求修改 |
| Sync deletion | 傳輸前／期間／後刪除，刪除數量上限，刪除被排除項目 |
| Include / Exclude | 規則、大小、年齡與深度篩選；選取項目仍須符合規則 |
| Transfer controls | 速度、平行傳輸／檢查、重試、逾時、時間容許誤差、檢查後傳輸、目標遍歷等 |
| 其他參數 | 以支援的參數白名單和獨立 argv 傳入；不經 shell 展開 |
| Task 保存 | 完整 source、destination、direction、mode、options、selection、名稱與時間 |
| Task 操作 | 列表直接提供 Dry Run、Run、Edit、Delete；編輯可保留原作業或另存副本 |
| Task 匯入／匯出 | Next JSON 格式；不會把原版 Qt 設定檔誤當成相同格式 |
| 工作記錄 | JSON 統計、速度、預計剩餘時間、數量、單檔狀態、原始記錄、重試與取消 |

同步是**單向同步**。本版沒有提供雙向 `bisync` 的衝突解決與狀態管理，不能把左右方向切換稱為自動雙向同步。

## 瀏覽、設定與輔助工具

| 功能 | Next 的處理與範圍 |
|---|---|
| 雙面板、分頁 | 每側獨立位置與分頁；本次工作階段保留返回歷史與選取 |
| 常用 Mac 目錄 | 從系統取得個人資料夾、桌面、文件、下載、圖片、音樂、影片及已掛載磁碟 |
| 位置分組 | 本機、雲端、NAS／伺服器；保留協定名稱辨識用途不明的 remote |
| 欄寬與列背景 | 可拖曳欄寬，單細線分隔，剩餘面板與空白列保留交錯底色 |
| 日期 | 修改日期顯示西元年與時間 |
| 檔案操作 | 建立資料夾、改名、刪除、資料夾大小 |
| Finder 拖放 | 驗證同一父資料夾的檔案 URL，準備來源、目的與複製選項，再由使用者開始 |
| Config | 主工具列與 App 選單均可啟動 rclone 的 Terminal 設定，結束後刷新帳號 |
| rclone 路徑 | 一個主要安裝位置入口；可選資料夾或既有執行檔，保存後即探測 |
| rclone 設定檔 | 使用預設或指定檔案；加密密碼只保留在記憶體 |
| 引擎更新 | 官方下載、版本／架構／校驗驗證、替換與失敗還原；可跳過版本 |
| App 更新 | 讀取本專案正式 GitHub release，顯示可取得的新版本與下載頁 |
| 記住 | 保存當前左右位置、方向、操作與完整傳輸選項；下次還原，不自動執行 |
| 主題與語言 | 四主題，繁中／英文／日文與跟隨系統；即時套用 |
| 網路 | 代理、IPv4／IPv6／來源 IP、逾時、TPS、User-Agent、HTTP/2 相容設定 |
| 目錄樹 | rclone tree，支援深度與有界輸出；截斷會提示 |
| 清單匯出 | TXT／CSV，暫存完成後再替換目的檔 |
| 公開連結 | 先確認才呼叫 rclone link，驗證回傳網址；依後端支援程度決定是否可用 |
| 掛載／卸載 | 使用已安裝且支援掛載的 rclone 與驅動；忙碌時不強制卸載 |
| 串流／停止 | rclone cat 管線連接既有外部播放器；不內建或下載播放器 |
| 選單列與通知 | 可選擇顯示選單列圖示、完成／失敗通知；Dry Run 不發傳輸完成通知 |
| 結束確認 | 每次 Command＋Q 都確認；有工作時清楚說明，確認後停止工作再結束 |

## 保留的差異

預設位置或「記住」只還原左右目前位置與傳輸設定，沒有跨重啟還原全部分頁與每頁瀏覽歷史。設定與工作記錄使用 macOS Application Support；建置快取留在專案內，並不代表完整 portable mode。

掛載、分享連結及播放器依賴對應後端、既有驅動或外部程式。Google Drive「與我共用」已在傳輸選項中提供；本版沒有原版遠端面板的獨立瀏覽切換。額外 rclone 旗標與掛載選項有明確支援範圍，並非任意 shell 命令輸入框。

實際測試平台與尚未操作驗證的項目見 [驗證記錄](VALIDATION.zh-TW.md)。
