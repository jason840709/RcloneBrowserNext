# 0.5.0：傳輸統計與 NAS 比對的設計依據

本文件整理 rclone 1.75.2 原始碼與官方文件的行為細節，說明 0.5.0 速度算法與 NAS 比對預設值的設計原因。

## 1. 為什麼已傳輸容量在增加，rclone 回報的速度卻是 0？

rclone 的 `--use-json-log` 每秒會輸出一筆 `stats` JSON（包含 `bytes`、`totalBytes`、`speed`、`eta` 等欄位）[1]。然而在 rclone 1.75.2 中有兩條不同的流量統計路徑 [2][3]：

- **一般串流傳輸**：呼叫 `StatsInfo.Bytes`，同時更新已傳容量與速度。
- **伺服器端複製／系統原生複製**：呼叫 `StatsInfo.BytesNoNetwork`，只更新已傳容量，不計入 `speed`（因此 `speed` 為 `0`、`eta` 為 `null`）[4][5]。

在 macOS 本機複製時，rclone 預設會呼叫系統 `CopyFile`（優先嘗試 APFS clone），這條路徑被歸類在 `BytesNoNetwork`；因此本機複製時常會看到容量一直增加，但速度卻顯示 0。此外，0.4.0 在工作完成時會把速度歸零，導致完成後看不到平均速度。

### 0.5.0 的解法

0.5.0 改用每秒 `stats` 的累計容量差值，計算最近 60 秒的平均處理速度與剩餘時間，並在工作結束後保留全程平均速度（後續在 0.10.0～0.10.3 進一步細化為 10 秒即時速度與實際傳檔時間 `transferTime`）[6]。

## 2. 電腦、NAS 與雲端之間該怎麼選比對方式？

### 建議預設值：大小與修改時間（不計算本機雜湊）

此選項對應 rclone 預設的大小與修改時間比對，並加上 `--local-hashes=none` [7][8]。

透過 Finder 掛載的 SMB 資料夾對 rclone 而言屬於本機磁碟（local backend）。當檔案大小相同、但修改時間不同時，一般模式會讀取整個檔案來算雜湊確認內容是否相同；在 SMB 掛載上這會造成把整份 NAS 檔案讀回電腦的額外網路流量。加上 `--local-hashes=none` 後，本機後端不提供雜湊，遇到修改時間不同的檔案就會直接重傳，不再為了比對而讀回整份目標檔案（若使用 rclone 原生 SMB 連線，其後端本身就不提供雜湊 [9]）。

| 比對選項 | 適用情境 | 取捨與限制 |
| --- | --- | --- |
| 大小與修改時間（不計算本機雜湊） | 本機外接硬碟、Finder 掛載 NAS、日常增量備份 | 不做本機端雜湊檢查；若僅時間戳改變也會重傳 |
| 一般大小與修改時間 | 兩端讀取雜湊成本低，想在時間不同時先比對雜湊 | 時間不同時會讀取整份本機／掛載 NAS 檔案算雜湊 |
| 只比對大小 | 目標端無法保留修改時間 | 內容改過但檔案大小剛好沒變時會被漏掉 |
| 大小與雜湊 | 需要嚴格核對檔案內容一致性 | 兩端須有共同雜湊；本機與掛載 NAS 可能需讀取完整內容，無共同雜湊時只比大小 |
| 只比對雜湊 | 目標端回報的檔案大小不可靠，且兩端有共同雜湊 | 忽略大小與時間；若兩端無共同雜湊，已存在檔案會被略過；傳後也不檢查大小 |
| 只比對修改時間 | 特殊用途且時間戳完全可靠 | 忽略檔案大小；時間不同時仍可能讀雜湊 |
| 全部重新傳送 | 強制覆寫目標所有檔案 | 每次都重傳全部檔案 |

註：若從 Mac 將 NAS 資料傳往雲端，確定需要更新的檔案本身仍會經由 Mac 讀取並上傳；不計算本機雜湊省下的是「原本不用傳、卻為了比對而讀回整份檔案」的額外流量 [6]。

## 3. 常用方案與單向同步設定

- **本機 → NAS 方案**：預設同時傳輸 1 個檔案、檢查 10 個檔案，並加上 `--multi-thread-streams=0` 停用單一檔案分段並行寫入，減少對 NAS 硬碟的隨機競爭讀寫 [1][9][15]。
- **排除 Mac 系統暫存檔**：預設排除 `.DS_Store`、`._*`、`.Spotlight-V100/**`、`.Trashes/**`、`.fseventsd/**`、`.TemporaryItems/**`，不會排除一般以 `.` 開頭的隱藏設定檔（若需保留 `._*` AppleDouble 延伸屬性，可手動移除該條規則）[10][11]。
- **單向同步（`rclone sync`）**：以來源為準更新目標，會刪除目標多出的檔案（預設不開啟 `--delete-excluded`，並在傳輸期間同步刪除多餘檔案）[12][13]。

## 參考來源

1. [rclone 官方文件：JSON 記錄、同時檢查、刪除時機](https://rclone.org/docs/)
2. [rclone 1.75.2：`fs/accounting/stats.go`](https://github.com/rclone/rclone/blob/v1.75.2/fs/accounting/stats.go)
3. [rclone 1.75.2：`fs/accounting/accounting.go`](https://github.com/rclone/rclone/blob/v1.75.2/fs/accounting/accounting.go)
4. [rclone 1.75.2：`backend/local/clone_darwin.go`](https://github.com/rclone/rclone/blob/v1.75.2/backend/local/clone_darwin.go)
5. [rclone 1.75.2：`fs/operations/copy.go`](https://github.com/rclone/rclone/blob/v1.75.2/fs/operations/copy.go)
6. [rclone FAQ：跨服務傳輸與總容量變動](https://rclone.org/faq/)
7. [rclone 1.75.2：`fs/operations/operations.go`](https://github.com/rclone/rclone/blob/v1.75.2/fs/operations/operations.go)
8. [rclone 1.75.2：`backend/local/local.go`](https://github.com/rclone/rclone/blob/v1.75.2/backend/local/local.go)
9. [rclone 1.75.2：`backend/smb/smb.go`](https://github.com/rclone/rclone/blob/v1.75.2/backend/smb/smb.go)
10. [Apple：調整 SMB 瀏覽行為](https://support.apple.com/102064)
11. [RFC 1740：Macintosh 檔案與 AppleDouble](https://www.rfc-editor.org/rfc/rfc1740)
12. [rclone sync 官方說明](https://rclone.org/commands/rclone_sync/)
13. [rclone 篩選與 delete-excluded](https://rclone.org/filtering/)
14. [原版 Rclone Browser：`src/job_widget.cpp`](https://github.com/kapitainsky/RcloneBrowser/blob/45bf7411839b0919c488a3e3a0a5272b50c9fc7b/src/job_widget.cpp)
15. [rclone 1.75.2：`fs/operations/multithread.go`](https://github.com/rclone/rclone/blob/v1.75.2/fs/operations/multithread.go)
