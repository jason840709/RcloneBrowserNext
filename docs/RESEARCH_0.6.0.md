# 0.6.0 研究筆記：停止傳輸、磁碟時間精度與逐檔報告

本文件整理 **rclone v1.75.2 原始碼**在取消工作、外接磁碟時間比對、部分資料夾同步與逐檔報告上的實作細節。這是原始碼研究；實際測試範圍請見[驗證記錄](VALIDATION.zh-TW.md)。

## 1. 停止傳輸的訊號與暫存檔清理

按下「停止」時，已完成的複製（[copy](https://rclone.org/commands/rclone_copy/)）、移動（[move](https://rclone.org/commands/rclone_move/)）與同步刪除（[sync](https://rclone.org/commands/rclone_sync/)）不會復原；傳到一半的檔案則交由 rclone 的 [`atexit`](https://github.com/rclone/rclone/blob/v1.75.2/lib/atexit/atexit.go) 清理函式處理（見 [`atexit_unix.go`](https://github.com/rclone/rclone/blob/v1.75.2/lib/atexit/atexit_unix.go)，與 Remote Control 的 [`jobs.NewJob`](https://github.com/rclone/rclone/blob/v1.75.2/fs/rc/jobs/job.go)／[`job/stop`](https://rclone.org/rc/#job-stop) 機制不同）：

| 訊號階段 | rclone 行為 | Next 的處理 |
| --- | --- | --- |
| 第一次送 `SIGINT` | 攔截訊號並執行已註冊的清理函式（清除 `.partial` 或取消分段上傳）後退出 | 畫面顯示「正在停止」，給 rclone 10 秒收尾時間 |
| 逾時後送 `SIGTERM` | 第一次收到訊號時已呼叫 `signal.Stop`，第二次訊號會直接終止程序 | 10 秒後仍未退出時升級終止 |
| 再逾時送 `SIGKILL` | 作業系統強制終止，無法執行清理 | 再等 2 秒仍未退出時的最後手段，並在紀錄中標示強制停止 |

### 本機、NAS 與各雲端後端的清理行為

- **本機與 SMB 暫存檔**：[`fs/operations/copy.go`](https://github.com/rclone/rclone/blob/v1.75.2/fs/operations/copy.go) 預設會先寫入 `.partial` 暫存檔，完成驗證後才改名為正式檔名（[`backend/local/local.go`](https://github.com/rclone/rclone/blob/v1.75.2/backend/local/local.go)、[`backend/smb/smb.go`](https://github.com/rclone/rclone/blob/v1.75.2/backend/smb/smb.go)），一般串流複製在已註冊清理函式時，收到 `SIGINT` 會嘗試刪除該次持有的 `.partial` 檔；註冊解除後的驗證、改名階段不一定有相同保護，斷線或權限也可能讓清理失敗（macOS 原生複製 [`clone_darwin.go`](https://github.com/rclone/rclone/blob/v1.75.2/backend/local/clone_darwin.go)／[`COPYFILE_CLONE`](https://github.com/apple-oss-distributions/copyfile/blob/main/copyfile.3) 則由 [`--local-no-clone`](https://rclone.org/local/#local-no-clone) 控制；掛載專用的 `--direct-io` 定義於 [`mount.go`](https://github.com/rclone/rclone/blob/v1.75.2/cmd/mountlib/mount.go)）。因此 Next 不開啟 [`--inplace`](https://rclone.org/docs/#inplace)（以免覆寫破壞目標端原本的好檔案），也不會自行用萬用字元猜測刪檔。
- **雲端分段上傳**（[`multithread.go`](https://github.com/rclone/rclone/blob/v1.75.2/fs/operations/multithread.go)、[`multipart.go`](https://github.com/rclone/rclone/blob/v1.75.2/lib/multipart/multipart.go)）：[S3](https://github.com/rclone/rclone/blob/v1.75.2/backend/s3/s3.go)、[B2](https://github.com/rclone/rclone/blob/v1.75.2/backend/b2/upload.go)、[OneDrive](https://github.com/rclone/rclone/blob/v1.75.2/backend/onedrive/onedrive.go)、[Azure Blob](https://github.com/rclone/rclone/blob/v1.75.2/backend/azureblob/azureblob.go) 在支援且已註冊清理的路徑中，會嘗試透過各自 API 取消本次上傳或清理未提交區塊；保留區塊設定、既有資料保護或連線失敗可能改變結果；[Google Drive](https://github.com/rclone/rclone/blob/v1.75.2/backend/drive/upload.go) 沒有相同的退出取消流程；其上傳 session URI 有有效期限，但不能由此判定服務端未完成資料已立即清除（參見 [AWS S3 文件](https://docs.aws.amazon.com/AmazonS3/latest/API/API_AbortMultipartUpload.html)、[Google Drive 文件](https://developers.google.com/workspace/drive/api/guides/manage-uploads#perform_a_resumable_upload)）。

## 2. 外接硬碟第二次同步為何可能重複傳檔？

rclone v1.75.2 的 [`local.Fs.readPrecision`](https://github.com/rclone/rclone/blob/v1.75.2/backend/local/local.go) 使用 `os.CreateTemp("", "rclone")` 在**系統暫存目錄**建立測試檔來偵測本機時間精度，而不是在目標外接硬碟上測試。

當 Mac 系統碟是奈秒精度的 APFS，外接硬碟卻是精度較粗的 exFAT、HFS+ 或 FAT32 時，rclone 誤以為目標也支援奈秒精度（[`GetModifyWindow`](https://github.com/rclone/rclone/blob/v1.75.2/fs/fs.go)）。結果第一次複製過去的檔案時間被外接硬碟捨入，第二次同步在開啟 `--local-hashes=none` 的情況下（[`operations.equal`](https://github.com/rclone/rclone/blob/v1.75.2/fs/operations/operations.go)），就會因「微秒時間對不上、又沒有雜湊可比對」而全部重傳。

### Next 的自動時間容差

當「時間容許誤差」留空時，Next 會直接查詢 macOS 實際掛載磁碟的檔案系統格式，依兩端格式自動套用較大的容差（手動填寫優先）：

| 實際檔案系統 | 自動容差 | 規格依據 |
| --- | --- | --- |
| FAT／`msdos` | 2 秒 | Microsoft [File Times](https://learn.microsoft.com/en-us/windows/win32/sysinfo/file-times) 定義寫入時間精度為 2 秒 |
| HFS+／`hfs` | 1 秒 | Apple [TN1150：HFS Plus Dates](https://developer.apple.com/library/archive/technotes/tn/tn1150.html) 定義時間精度為 1 秒 |
| `exfat` | 10 毫秒 | Microsoft [exFAT 規格](https://learn.microsoft.com/en-us/windows/win32/fileio/exfat-specification) §7.4.6–9 定義 10 毫秒增量 |
| APFS、未知格式、已掛載 `smbfs` | 不自動覆寫 | 維持 rclone 預設判斷 |

註：若檔案本身在兩次同步之間真的被背景程式修改（如執行中的 [SQLite 資料庫](https://www.sqlite.org/howtocorrupt.html#_backup_or_restore_while_a_transaction_is_active)），仍會正常重傳。

## 3. 勾選部分資料夾時的同步範圍

rclone 的 [篩選規則](https://rclone.org/filtering/) 同時套用於來源與目標。當使用者只勾選來源下的 `A`、`B` 兩個資料夾進行同步時：

- **無包含規則時**：在排除規則後加上 `+ /A/**`、`+ /B/**` 與 `- **`，並禁止同時勾選 `--delete-excluded`，確保目標端的 `C` 資料夾不會被誤刪。
- **同時設定包含規則時**：先列出來源與目標兩端符合篩選規則的清單，取落在勾選資料夾內的路徑聯集作為同步範圍，確保目標端在 `A`、`B` 內多出的舊檔也能正確被同步刪除（依據：[`sync.go`](https://github.com/rclone/rclone/blob/v1.75.2/fs/sync/sync.go)、[`march.go`](https://github.com/rclone/rclone/blob/v1.75.2/fs/march/march.go)、[`filter.go`](https://github.com/rclone/rclone/blob/v1.75.2/fs/filter/filter.go)）。

## 4. 逐檔報告的資料來源與效能

- **統計欄位**（[`accounting/stats.go`](https://github.com/rclone/rclone/blob/v1.75.2/fs/accounting/stats.go)、[core/stats](https://rclone.org/rc/#core-stats)）：`checks` 包含刪除與資料夾檢查，不等於「不用傳的檔案數」；因此 Next 透過 `--combined=-`（[`operationsflags.go`](https://github.com/rclone/rclone/blob/v1.75.2/fs/operations/operationsflags/operationsflags.go)、[`logger.go`](https://github.com/rclone/rclone/blob/v1.75.2/fs/operations/logger.go)、[`encoder/standard.go`](https://github.com/rclone/rclone/blob/v1.75.2/lib/encoder/standard.go)）從 `stdout` 收集逐檔比對結果（`=` 不用傳、`+`/`*` 待傳、`-` 待刪），再搭配 `stderr` 的 INFO JSON 確認實際完成的複製、移動與刪除（[`copy.go`](https://github.com/rclone/rclone/blob/v1.75.2/fs/operations/copy.go)、[`cmd.go`](https://github.com/rclone/rclone/blob/v1.75.2/cmd/cmd.go)、[`sync.go`](https://github.com/rclone/rclone/blob/v1.75.2/fs/sync/sync.go)）。
- **分頁與寫入效能**：報告寫入器以 64 KiB 緩衝區批次寫入磁碟，不在記憶體累積全量陣列；實測寫入 100,000 筆略過紀錄僅需 **1.562 秒**（約 64,005 筆／秒）。詳細測試結果見 [0.6.0 發布紀錄](RELEASE_0.6.0.md) 與 [驗證記錄](VALIDATION.zh-TW.md)。

## 判讀與測試的限制

第一次訊號處理會停止攔截後續訊號；第二次終止與強制停止都可能留下未完成資料。10 秒與 2 秒是 App 的等待設定，不是 rclone 對清理成功的保證。App 會等程序確實退出才結束工作，不會依結束代碼宣稱儲存端已清乾淨。

部分資料夾搭配包含規則時，清單是開始前取得的範圍快照；執行期間新加入的檔案未必包含其中。列目錄失敗會停止，不能當作空資料夾繼續刪除。

`=` 代表依本次規則不需傳輸，不等於完整內容相同。`-` 代表目標多出項目，尚未表示刪除成功。比對紀錄、實際完成事件與錯誤次數應分開判讀。

報告寫入與分頁是線性處理；測試中的 100,000 筆耗時不能直接推算任意磁碟、NAS 或更大報告的效能。
