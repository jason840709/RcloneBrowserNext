# 掛載 SMB／NAS 的檔案比對：原因、選項與實測

## 為什麼比對時可能會讀回 NAS 檔案內容

雜湊是依檔案內容算出的核對值。透過 Finder 掛載的 SMB 路徑（例如 `/Volumes/NAS/Backup`），對 rclone 而言屬於本機檔案系統（local backend）。當 rclone 需要計算檔案雜湊時，本機後端必須打開並讀取整份檔案；如果檔案位於 SMB 網路磁碟上，就會產生讀取整份檔案的網路流量。

rclone 預設會先比對檔案大小與修改時間：兩者相同時直接略過；但若**大小相同而修改時間不同**，rclone 會嘗試計算兩端共同支援的雜湊，確認內容是否真的改變（或只是時間戳不同）。因此就算沒選「大小＋雜湊」模式，遇到時間戳有差異的檔案時仍可能讀回整份 NAS 檔案。加上 `--ignore-checksum` 也只會關閉「傳輸後」的雜湊驗證，不會關閉「傳輸前」的比對讀取。

相關 rclone v1.75.2 原始碼路徑：

- [`fs/operations/operations.go`](https://github.com/rclone/rclone/blob/v1.75.2/fs/operations/operations.go)：`equal()` 先比大小與時間，時間不同時呼叫 `CheckHashes()` 檢查兩端共同支援的雜湊。
- [`backend/local/local.go`](https://github.com/rclone/rclone/blob/v1.75.2/backend/local/local.go)：`Object.Hash()` 會開啟檔案並讀取內容串流來計算雜湊。
- [`fs/operations/copy.go`](https://github.com/rclone/rclone/blob/v1.75.2/fs/operations/copy.go)：傳輸後的完整性檢查與傳輸前的 `equal()` 比對分屬不同階段。

## Next 提供的 NAS 比對設定

### 大小與修改時間（不計算本機雜湊）

此模式使用預設的大小與修改時間比對，並加上 `--local-hashes none`（[`backend/local/local.go`](https://github.com/rclone/rclone/blob/v1.75.2/backend/local/local.go)、[`fs/hash/hash.go`](https://github.com/rclone/rclone/blob/v1.75.2/fs/hash/hash.go)、[官方文件](https://rclone.org/local/#local-hashes)），讓本機後端回報不支援雜湊。當兩端沒有共同雜湊可用時，只要修改時間不同就會直接重傳，不會先讀回目標端的整份 NAS 檔案來算雜湊。

- **優點**：比「只看大小」多檢查了修改時間，檔案改過後就算大小沒變，只要修改時間更新就會同步。
- **取捨**：本機端（含 Finder 掛載的 SMB）不做內容雜湊驗證，也無法察覺「內容變了，但大小與修改時間完全沒變」的極端情況；若 NAS 時間戳不準，則可能因為時間差而多傳一次檔案。兩端都是雲端時，雲端原本的雜湊檢查不受影響。

### 外接磁碟的重複傳輸與時間精度

在本機或 Finder 掛載的 NAS 之間停用本機雜湊後，rclone 依賴大小與修改時間判斷（[官方說明](https://rclone.org/docs/#modify-window-duration)）。然而 rclone v1.75.2 的本機後端是在系統暫存資料夾建立測試檔來偵測時間精度（`readPrecision()`）；若 Mac 系統碟是高精度的 APFS，外接磁碟卻是時間精度較粗的 exFAT 或 FAT，複製過去的檔案時間被捨入後，下次同步就可能被誤判為時間不同而全部重傳（詳見 [0.6.0 研究說明](RESEARCH_0.6.0.md)）。

為了解決這個問題，「時間容許誤差」留空時，Next 會直接向 macOS 查詢來源與目標磁碟的檔案系統格式，自動套用兩端中較大的容差：

| 本機磁碟格式 | 自動容差 |
|---|---|
| FAT（`msdos`） | 2 秒 |
| HFS／HFS+（`hfs`） | 1 秒 |
| exFAT（`exfat`） | 10 毫秒 |
| APFS、未知格式、已掛載 SMB | 維持 rclone 預設判斷 |

若有手動輸入時間容差則以手動值為準，實際套用的容差也會顯示在指令預覽與工作紀錄中。

### 何時改用一般比對或 SMB 直連

- 若網路頻寬充足、且希望在時間戳不同時先核對雜湊，可改選一般的「大小與修改時間」或「大小＋雜湊」。
- 若透過「帳號設定」新增 **SMB 直連**（使用 rclone 原生 [SMB 後端](https://github.com/rclone/rclone/blob/v1.75.2/backend/smb/smb.go)），該後端本身不提供雜湊，並回報毫秒時間精度，能避開 Finder 掛載的雜湊讀取。使用 [SFTP](https://rclone.org/sftp/) 時，能否取得雜湊則取決於伺服器支援；它不等同 SMB 的行為。

## 其他常見旗標為何不適用

| 旗標 | 實際作用 | 為何不適合用來解決此問題 |
|---|---|---|
| `--size-only` | 大小相同即略過 | 會漏掉「改過內容但大小不變」的檔案 |
| `--checksum` | 只看大小與雜湊 | 掛載的 SMB 反而每個檔案都要讀回來算雜湊；無共同雜湊時又退回只看大小 |
| `--ignore-checksum` | 略過傳輸後的雜湊檢查 | 傳輸前遇到修改時間不同時，照樣會讀回檔案算雜湊 |
| `--ignore-times` | 無條件全部重傳 | 每次都重傳所有檔案 |
| `--update` | 略過目標較新的檔案 | 遇到目標較舊但大小相同的檔案仍會讀雜湊，且改變了同步語義 |
| `--use-server-modtime` | 雲端物件儲存改看伺服器時間 | 對本機與 SMB 掛載無效 |
| `--no-update-modtime` | 內容相同時不更新目標時間戳 | 仍須先讀完雜湊才能知道內容相同 |
| `--local-no-check-updated` | 不檢查來源檔案在傳輸途中是否變動 | 與傳輸前比對無關，且會關掉活動檔案變動警告 |

## CLI 實測對照

使用官方 Linux `rclone v1.75.2` 測試：建立兩個同為 1 MiB、修改時間不同、內容也不同的檔案（來源全為 A、目標全為 B），以 Linux `inotify` 監看目標檔案在 `rclone copy --dry-run` 期間是否被開啟讀取：

| 選項 | 目標檔案讀取事件 | rclone 判斷結果 |
|---|---|---|
| 預設 | `OPEN + ACCESS + CLOSE_NOWRITE`（有讀檔） | 內容不同，需傳送 |
| `--ignore-checksum` | `OPEN + ACCESS + CLOSE_NOWRITE`（有讀檔） | 仍先讀檔，需傳送 |
| `--local-hashes none` | 無讀取事件 | 時間不同，需傳送 |
| `--size-only` | 無讀取事件 | 誤判為相同而略過 |

實測確認 `--local-hashes none` 能在不讀取目標檔案內容的前提下，正常靠修改時間識別出需要更新的檔案。
