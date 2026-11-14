# 功能對照與架構

Rclone Browser Next 延續原版 Rclone Browser 的位置瀏覽、傳輸設定、工作監控與作業（Tasks）四大模組，改為左右雙面板介面與 Swift／AppKit 原生架構。

## 原版與 Next 的模組對照

| 原版 Rclone Browser | 職責 | Next |
|---|---|---|
| `remote_widget.cpp`、`item_model.cpp` | 瀏覽位置、列出檔案與檔案操作 | `BrowserPane.tsx`、`useBrowser.ts`、`RcloneEngine.swift` |
| `transfer_dialog.cpp/.ui` | 傳輸設定表單 | 主畫面傳輸選項與完整作業編輯器 |
| `job_options.cpp/.h` | 保存選項、產生 rclone 參數 | `EngineTransferOptions`、`EngineTransferRequest` |
| `MainWindow::addTransfer` | 建立獨立傳輸程序 | `RcloneEngine` 工作管理與 `Process` |
| `job_widget.cpp` | 進度、工作紀錄、停止工作 | `Jobs.tsx` 與 rclone JSON 統計 |
| `list_of_job_options.cpp` | 儲存與載入作業（Tasks） | `EngineStorage` JSON 與作業管理介面 |
| `preferences_dialog.cpp/.ui` | 執行檔路徑、介面與預設設定 | `Settings.tsx`、原子寫入、即時套用 |

原版 `MainWindow::addTransfer` 直接啟動 `QProcess` 且不限制同時工作數；Next 同樣預設不限同時工作數，並額外提供並行工作上限設定（單一工作的 `--transfers` 與 `--checkers` 則各自獨立運作）。

公開參考：[原版原始碼](https://github.com/kapitainsky/RcloneBrowser/tree/45bf7411839b0919c488a3e3a0a5272b50c9fc7b)。

## 傳輸與作業（Tasks）

| 功能 | Next 的實作 |
|---|---|
| Copy / Move / Sync | 支援左到右、右到左；來源與目標皆可為本機或遠端連線 |
| 常用方案 | 內建本機→本機、本機→NAS、NAS→雲端、本機→雲端、雲端→雲端、雲端→本機／NAS 六種方案，可隱藏與還原 |
| Dry Run | 主畫面與作業列表皆可直接預演（執行 rclone `--dry-run`） |
| 比對方式 | 大小＋修改時間、大小＋雜湊、僅時間、僅大小、僅雜湊、全部重傳，以及 NAS 不計算本機雜湊模式 |
| 略過條件 | 略過已存在檔案、略過目標較新檔案（與移動衝突的組合會預先攔截） |
| 同步刪除 | 傳輸前／期間／後刪除、刪除數量上限、刪除排除項目 |
| 篩選規則 | 包含／排除規則、檔案大小、修改時間與目錄深度篩選 |
| 選取範圍 | 僅來源側顯示勾選框；勾選資料夾可同步至目標同名子資料夾，不影響目標其他資料夾 |
| 磁碟時間精度 | Mac 版時間容差留空時，依本機 FAT／HFS+／exFAT 格式自動套用對應容差；手動設定優先 |
| 傳輸控制 | 速度上限、平行傳輸／檢查數、失敗重試（預設只重試失敗檔案）、逾時、時間容差等 |
| 額外參數 | 透過白名單驗證並以獨立參數陣列（argv）傳入，不經過 shell 展開 |
| 作業保存與操作 | 完整儲存來源、目標、方向、模式、選項與勾選範圍；列表直接提供預演、執行、編輯、刪除與匯入／匯出 |
| 工作紀錄與報告 | 即時速度與剩餘時間、檔案去向統計（不用傳、已略過、已刪除、錯誤）、白話錯誤燈號、逐檔報告分頁與 JSONL 匯出 |
| 工作清理與停止 | 啟動時自動清除已完成紀錄；停止時先送中斷訊號等待 rclone 收尾，程序確實結束後才更新狀態 |

註：同步功能為 rclone 單向 `sync`，不含雙向 `bisync`。

## 瀏覽、設定與輔助工具

| 功能 | Next 的實作 |
|---|---|
| 雙面板與分頁 | 左右獨立位置與分頁，各自保留返回／前進歷史與快取 |
| 滑鼠側鍵與導覽 | 支援滑鼠側鍵、觸控板手勢與鍵盤快捷鍵，依游標所在面板切換上一頁／下一頁 |
| 位置選單 | 自動列出 Mac 常用資料夾、已掛載磁碟、雲端與 NAS／伺服器（標示 Mac 掛載或 SMB 直連） |
| 檔案操作 | 新增資料夾、重新命名、刪除、計算資料夾大小、Finder 拖放帶入來源 |
| 帳號設定 | 內建圖形化「快速設定」與「詳細設定」，並保留 `config` 終端機設定入口 |
| rclone 路徑與更新 | 單一安裝位置設定，支援官方版本檢查、架構與校驗碼驗證、自動替換與失敗還原 |
| App 更新檢查 | 查詢本專案 GitHub Releases 最新正式版並提供下載連結 |
| 儲存工作區 | 記住左右位置、方向、操作與傳輸選項，下次啟動自動還原 |
| 外觀、縮放與語言 | 自動／淺色／深色搭配紫、綠、藍強調色；80%～125% 五段縮放；繁中、英文、日文與跟隨系統 |
| 網路設定 | 代理伺服器、IPv4／IPv6、來源 IP、逾時、TPS、User-Agent、停用 HTTP/2 |
| 輔助工具 | 目錄樹（tree）、匯出檔案清單（TXT／CSV）、建立公開連結（link）、掛載／卸載（mount）、外部播放器串流（cat） |
| 通知與結束確認 | 支援選單列圖示、系統通知、Mac 背景完成 Dock 跳動提醒；有未完成工作時關閉 App 會先確認 |

## 與原版的差異說明

- 「儲存工作區」會還原左右目前位置與傳輸設定，不會跨重啟還原所有分頁與瀏覽歷史。
- 設定與工作紀錄存放於系統 Application Support，並非整個資料夾帶著走的完全可攜模式（portable mode）。
- Google Drive「與我共用」整合在傳輸選項中，未在瀏覽面板另設獨立切換開關。

各平台的實際測試範圍請見 [驗證記錄](VALIDATION.zh-TW.md)。
