# Rclone Browser Next 0.6.0

這一版重整了工作紀錄與停止傳輸流程，新增逐檔傳輸報告、六種常用備份方案、部分資料夾同步，以及綠色主題與五段介面縮放。

## 工作紀錄與停止傳輸

- 在「已結束」分頁可清除已完成、失敗、取消或中斷的紀錄；在「全部」或「進行中」分頁點擊垃圾桶時，可選擇「終止進行中並清除」或「只清除已完成」。
- 點擊停止後會顯示「正在停止」，先送出 `SIGINT` 請 rclone 正常收尾，逾 10 秒未結束才依序升級為 `SIGTERM` 與 `SIGKILL`，等程序確實退出後才更新狀態（不會復原已完成的複製、移動或刪除；詳見 [停止傳輸研究](https://github.com/jason840709/RcloneBrowserNext/blob/v0.6.0/docs/RESEARCH_0.6.0.md)）。
- 重開 App 時會自動清除上次成功完成的紀錄，並保留失敗、取消與中斷的工作供檢查或重試（已儲存作業 Tasks 不受影響）。

## 逐檔傳輸報告

- 工作摘要分開顯示需傳輸、已傳輸、已檢查（Checks）、略過紀錄與錯誤次數。
- 「詳細資料與紀錄」提供**全部、比對、略過、已完成、錯誤**分頁，可查看每筆檔案的時間、動作與錯誤原因，並支援匯出完整 JSONL 報告與原始比對紀錄。

## 備份方案、比對與部分資料夾同步

- 擴充為六種方案：本機 → 本機、本機 → NAS、NAS → 雲端、本機 → 雲端、雲端 → 雲端、雲端 → 本機／NAS（上傳雲端採 7 傳 10 檢；寫入本機或 NAS 採 1 傳 10 檢並停用單檔分段並行）。
- 僅在來源側顯示勾選框；勾選一或多個資料夾即可同步至目標的同名子資料夾，目標裡未勾選的其他資料夾完全不受影響。
- 「時間容許誤差」留空時，Mac 會自動讀取本機磁碟格式（FAT 為 2 秒、HFS+ 為 1 秒、exFAT 為 10 毫秒）套用對應容差，減少因時間精度捨入造成的重複傳檔。

## 外觀、圖示與介面縮放

- 新增黑綠、淺綠主題（共六色主題），執行中的 Dock 與選單列圖示會隨主題變色。
- 新增 **80%、90%、100%、110%、125%** 五段介面縮放，拖放與滑鼠側鍵座標同步適配。

## 下載與驗證

需 **macOS 13 以上**（支援 Apple Silicon 與 Intel）。可至 [最新發布頁](https://github.com/jason840709/RcloneBrowserNext/releases/latest) 下載預編譯版，或使用原始碼包執行 `Build-on-Mac.command`（詳見 [Mac 建置說明](https://github.com/jason840709/RcloneBrowserNext/blob/v0.6.0/docs/BUILD_MAC.zh-TW.md)）。

本版通過 Swift Core（56 項）、逐檔報告（15 項）、正式介面（140 項）與 Mac 雙架構原生測試（各 137 項通過），完整數據見 [驗證記錄](https://github.com/jason840709/RcloneBrowserNext/blob/v0.6.0/docs/VALIDATION.zh-TW.md) 與 [Actions](https://github.com/jason840709/RcloneBrowserNext/actions)。

作者：**Jason Chen**（MIT 授權）。感謝 rclone、mmozeiko／RcloneBrowser 與 kapitainsky／RcloneBrowser 開發團隊。
