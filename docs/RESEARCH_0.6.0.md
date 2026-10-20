# rclone 研究：停止傳輸、時間比對與逐檔報告

本文件核對 **rclone v1.75.2 官方原始碼**及官方服務文件，供 Rclone Browser Next 的停止流程、比對預設、提示文字與測試設計使用。原始碼檢閱能確認程式會走哪些處理，但不等於已在所有 Mac、NAS 與雲端服務上完成實測。

## 先釐清「停止」的意思

停止是要求 rclone 結束目前工作。**已完成的複製、移動與同步刪除不會因此復原。** 尚未完成的檔案或上傳區塊，交由 rclone 已註冊的清理程序處理；能否完成，取決於使用的傳輸路徑、儲存服務及當時的連線狀態。

App 可以確認「程序仍在執行」或「程序已結束」，但不能只憑停止訊號或結束代碼，就宣稱所有儲存位置都沒有殘留。介面應保留「正在停止」狀態，直到收到程序結束事件。

同步本身只修改目標；移動則會在成功傳輸後刪除來源。這些已完成的動作與取消後的清理是不同的事。參見官方 [sync](https://rclone.org/commands/rclone_sync/) 與 [move](https://rclone.org/commands/rclone_move/) 說明。

## SIGINT 與 SIGTERM 並不是兩次優雅清理

rclone 的 [`atexit`](https://github.com/rclone/rclone/blob/v1.75.2/lib/atexit/atexit.go) 套件在第一次註冊清理函式時，開始監聽退出訊號。Unix 對應的訊號與代碼定義見 [`atexit_unix.go`](https://github.com/rclone/rclone/blob/v1.75.2/lib/atexit/atexit_unix.go)。

| 動作 | 官方程式的行為 | App 應如何理解 |
| --- | --- | --- |
| 首次收到 SIGINT | 停止訊號攔截，執行已註冊的清理函式，再退出 | 可用來先給 rclone 清理機會；仍需等程序結束 |
| 首次收到 SIGTERM | 與 SIGINT 共用相同處理 | 若第一個訊號就是 SIGTERM，也會嘗試執行清理 |
| 清理期間再送 SIGTERM | 第一次處理時已呼叫 `signal.Stop`，後續訊號可能直接終止程序 | 屬於升級終止，不應稱為「再做一次優雅清理」 |
| SIGKILL | 無法執行應用層清理函式 | 只適合程序無法結束時的最後手段，可能留下未完成資料 |

`Run()` 會依序執行已登錄的清理函式；函式的登錄容器是 map，執行次序不固定，也沒有全域清理逾時。**官方沒有提供一個能保證所有後端都完成清理的寬限秒數。** App 設定等待多久再升級終止，是產品對等待時間的選擇，不能寫成 rclone 的安全保證。

如果訊號確實經過這個處理器，SIGINT／SIGTERM 對應的退出代碼為 130／143。但程序可能尚未登錄任何清理函式，或在之後被強制終止；Foundation 也可能回報原始訊號與 `uncaughtSignal`。工作是否由使用者取消，應以 App 的停止請求與真正的程序結束事件共同判定，不能只比對 130 或 143。

反過來說，收到 130 或 143 也不代表清理成功：部分清理失敗只會記錄錯誤，再照原定流程退出。

## CLI 與 Remote Control 的取消方式不同

一般 CLI 的 [`cmd.Run`](https://github.com/rclone/rclone/blob/v1.75.2/cmd/cmd.go) 使用背景 context；上述訊號處理器負責執行退出清理，並沒有替所有 copy／sync 工作建立一個統一取消的 context。

Remote Control 的工作則經過 [`jobs.NewJob`](https://github.com/rclone/rclone/blob/v1.75.2/fs/rc/jobs/job.go)，為工作建立可取消的 context。[`job/stop`](https://rclone.org/rc/#job-stop) 會取消該工作，但回應停止請求不等於工作函式已經返回；仍需檢查工作的實際完成狀態。

單純在 CLI copy／sync 加上 `--rc`，不會自動把主要傳輸變成有 job ID 的 RC 工作。若日後要改用 RC 取消，需要連同工作啟動、查詢、端點存取及生命週期一起設計，不能把 `job/stop` 直接套在現有程序上。

## 本機與 NAS 的暫存檔

### 正常完成後才替換最終檔名

[`fs/operations/copy.go`](https://github.com/rclone/rclone/blob/v1.75.2/fs/operations/copy.go) 的 `checkPartial` 會先確認目標支援移動與 `PartialUploads`，且沒有啟用 `--inplace`，再使用暫存名稱。Local 與原生 SMB 後端都有宣告支援；不是所有雲端後端都走相同流程。來源分別見 [`backend/local/local.go`](https://github.com/rclone/rclone/blob/v1.75.2/backend/local/local.go) 與 [`backend/smb/smb.go`](https://github.com/rclone/rclone/blob/v1.75.2/backend/smb/smb.go)。

暫存名稱含來源指紋與名稱計算出的後綴，預設以 `.partial` 結尾；遇到很長的檔名還會縮短名稱。因此 App 不應自行由最終檔名猜測暫存路徑。

在這條一般傳輸路徑中，rclone 先完成複製與設定所要求的驗證，再把暫存檔改成最終名稱。原本存在的最終檔案，在此之前通常仍保留。`manualCopy` 會註冊退出清理，使用 rclone 自己持有的**確切暫存路徑**嘗試移除未完成檔案。這個註冊在 `manualCopy` 回傳時就解除，不能由此推論後續驗證與改名期間也有相同的訊號清理保護。

清理仍可能因為 NAS 斷線、權限變更、強制終止或系統故障而失敗。檔案大小也不能用來判定是否完成：某些寫入方式會預先配置完整容量，內容卻尚未寫完。

### `--inplace` 會改變既有檔案的保護

[`--inplace`](https://rclone.org/docs/#inplace) 讓資料直接寫入最終檔名。Local 後端開啟檔案時使用截斷模式；如果目標已有同名檔案，舊內容可能在新檔案完成前就被取代，失敗路徑也可能刪除這個最終檔案。

因此不應為了讓使用者看不到 `.partial` 而自動開啟 `--inplace`。它既不提供停止後的復原能力，也不保證停止後更容易清理。

### Mac 系統複製與 APFS clone 的例外

macOS 的 [`backend/local/clone_darwin.go`](https://github.com/rclone/rclone/blob/v1.75.2/backend/local/clone_darwin.go) 可以使用系統複製；支援時採 APFS clone，否則可退回系統的完整資料複製。這段 `Clone` 呼叫沒有接收 Go context，也沒有自行註冊暫存檔的退出清理。

上層會先嘗試 `serverSideCopy`，成功使用這條路徑時，不會進入有清理註冊的 `manualCopy`。由原始碼可推論：**在這條系統複製路徑中中斷程序，可能留下暫存檔。** 這是待 Mac 實機驗證的風險，不能寫成已重現於所有 APFS 傳輸的問題。

[`--local-no-clone`](https://rclone.org/local/#local-no-clone) 可以停用這個後端能力，讓 rclone 改用一般複製，但會失去 APFS clone／系統複製的效能優勢。不能只為了統一進度或清理行為，就預設把加速功能關掉。

## 多路傳輸與雲端上傳

[`fs/operations/multithread.go`](https://github.com/rclone/rclone/blob/v1.75.2/fs/operations/multithread.go) 與 [`lib/multipart/multipart.go`](https://github.com/rclone/rclone/blob/v1.75.2/lib/multipart/multipart.go) 會為部分傳輸註冊退出處理。處理時先取消上傳的子 context，再依後端呼叫 `Abort`；若設定為錯誤時保留區塊，或傳輸已完成，就不做相同的清理。

`Abort` 的意思由各後端實作決定，不能一律解釋為「刪掉目標檔案」。

| 後端 | v1.75.2 的清理方式 | 仍需保留的限制 |
| --- | --- | --- |
| S3 | 使用本次 upload ID 呼叫 `AbortMultipartUpload` | 可設定錯誤時保留區塊；服務端仍在處理的區塊可能需要後續確認，API 請求也可能失敗 |
| Backblaze B2 | 使用本次大檔案 ID 呼叫 `b2_cancel_large_file` | 需成功連到服務；這不等於刪除所有既有檔案版本 |
| OneDrive | 退出處理嘗試對本次 upload session URL 發出 DELETE | 連線或 API 錯誤可能使取消失敗 |
| Azure Blob | 清除尚未提交的區塊，並依情況保留既有已提交區塊及 metadata | 為避免破壞既有內容，特定區塊 ID 重疊情況會拒絕清理 |
| Google Drive | Resumable upload 的這條實作沒有同樣的退出 session abort | 不能承諾程序退出時立即清除雲端上傳工作階段 |

對應原始碼：[S3](https://github.com/rclone/rclone/blob/v1.75.2/backend/s3/s3.go)、[B2](https://github.com/rclone/rclone/blob/v1.75.2/backend/b2/upload.go)、[OneDrive](https://github.com/rclone/rclone/blob/v1.75.2/backend/onedrive/onedrive.go)、[Azure Blob](https://github.com/rclone/rclone/blob/v1.75.2/backend/azureblob/azureblob.go)、[Google Drive](https://github.com/rclone/rclone/blob/v1.75.2/backend/drive/upload.go)。

AWS 的 [AbortMultipartUpload 官方文件](https://docs.aws.amazon.com/AmazonS3/latest/API/API_AbortMultipartUpload.html) 明確提醒：取消時仍在進行的區塊可能成功或失敗，必要時需再次取消，並用 `ListParts` 確認沒有區塊。Google 的 [resumable upload 文件](https://developers.google.com/workspace/drive/api/guides/manage-uploads#perform_a_resumable_upload) 則說明 session URI 有效期限；URI 失效不應被延伸解讀成 App 已驗證所有服務端資料立即刪除。

這也說明為什麼 App 不應在取消後自動執行廣泛清理：其他工作可能正在使用相同遠端，或刻意保留可恢復的上傳區塊。

## Direct I/O 與停止清理無關

v1.75.2 的 `--direct-io` 定義在 [`cmd/mountlib/mount.go`](https://github.com/rclone/rclone/blob/v1.75.2/cmd/mountlib/mount.go)，屬於 Mount 選項，用來調整掛載的資料快取。它不是一般 copy／sync 的暫存檔或取消開關，也與 `--inplace` 的最終檔名寫入行為不同。

NAS 掛載、檔案系統與網路本身仍可能有尚未完成的 I/O；改變快取方式不能提供取消時的交易或復原保證。

## Next 應做到、也能驗證的事

1. 使用者按下停止後，立即顯示「正在停止」，保留工作與進度資訊。
2. 首先給 rclone 訊號與清理時間；若採取升級終止，明確把它當作等待逾時後的強制措施。
3. 只有在收到真正的程序結束事件後，才把執行中工作移出活動狀態；不能在按鈕事件當下就宣告完成。
4. 不猜測、不掃描刪除目的檔案，也不使用涵蓋其他工作或使用者資料的萬用字元清理。
5. 重複停止、尚未啟動便停止、退出 App 時停止、程序先自行完成等時序，都必須保持同一個工作只有一次結束處理。
6. 記錄強制終止與清理錯誤，讓使用者能分辨正常完成、使用者停止與傳輸失敗。

程序生命週期、測試用子程序與受控本機傳輸可以放進自動化驗證；APFS 系統複製中斷、真實 SMB 斷線、不同雲端上傳區塊的清理，必須另列實際測試範圍。本節的中斷限制屬於來源研究；本輪測試結果以 [發布紀錄](RELEASE_0.6.0.md) 與 [驗證記錄](VALIDATION.zh-TW.md) 為準。

## 第二次同步仍大量重傳：先核對修改時間

使用者回報本機資料夾同步到外接硬碟後，第二次似乎又大量傳輸。單憑磁碟品牌與命令，無法判定外接硬碟是 APFS、exFAT 或其他格式，也不能排除檔案在兩次執行之間確實改變。以下是能從官方原碼確認的原因鏈。

### 本機精度探測不一定在目的磁碟上

v1.75.2 的 [`local.Fs.readPrecision`](https://github.com/rclone/rclone/blob/v1.75.2/backend/local/local.go) 使用 `os.CreateTemp("", "rclone")` 建立測試檔，依序設定更細的修改時間，判斷本機檔案系統的精度。這個空字串指定的是**系統暫存目錄**，不是該 Local 後端的實際根目錄。

因此，若系統暫存目錄位於高精度磁碟，但目標磁碟只能保存較粗的時間，傳輸後的目標修改時間可能被捨入，rclone 得到的本機精度卻仍過細。[`GetModifyWindow`](https://github.com/rclone/rclone/blob/v1.75.2/fs/fs.go) 會取使用者容差和兩端後端精度的較大值；後端回報失準時，這一步不會自動知道真正目的磁碟的限制。

[`operations.equal`](https://github.com/rclone/rclone/blob/v1.75.2/fs/operations/operations.go) 的一般判定順序是：大小不同就傳；大小相同且修改時間差小於容差就略過；時間不符時，才嘗試可用的共同雜湊。**沒有共同雜湊且未開啟 `--refresh-times` 時，rclone 會保守地重新傳輸。** 所以 `--local-hashes=none` 搭配時間捨入，確實可能讓未改內容的檔案再次傳送。

### 按實際掛載格式調整，保留手動優先

Next 的處理是讀取 macOS 實際掛載的檔案系統類型，不建立測試檔，也不依磁碟名稱猜測格式。目標尚未建立時，查詢最近存在的父目錄；權限錯誤不能當成「不存在」。只在使用者未填修改時間容差時，針對已知格式套用以下下限；兩端都有已知限制時取較大值。

| 實際檔案系統 | 自動容差 | 依據 |
| --- | --- | --- |
| FAT／`msdos` | 2 秒 | Microsoft [File Times](https://learn.microsoft.com/en-us/windows/win32/sysinfo/file-times) 說明 FAT 的寫入時間為 2 秒精度 |
| HFS+／`hfs` | 1 秒 | Apple [TN1150：HFS Plus Dates](https://developer.apple.com/library/archive/technotes/tn/tn1150.html) 定義日期為整數秒 |
| `exfat` | 10 毫秒 | Microsoft [exFAT 規格](https://learn.microsoft.com/en-us/windows/win32/fileio/exfat-specification) §7.4.6–9：修改時間有 2 秒基底及 10 毫秒增量 |
| APFS、未知格式、Finder 已掛載的 `smbfs` | 不自動覆寫 | 保留 rclone 的正常判定或使用者手動容差；不能由協定名稱推定伺服器底層磁碟精度 |

exFAT 並不是所有時間都只能保存到 2 秒；直接把它一律放寬到 2 秒會增加漏掉快速同大小修改的範圍。原生 [`smb`](https://github.com/rclone/rclone/blob/v1.75.2/backend/smb/smb.go) 後端自報 1 毫秒，但這不能直接套用到所有 Finder 掛載的 SMB 伺服器。

容差越大，同大小檔案在容差內的修改越可能不被辨識。這是 metadata 比對本身的取捨，不能稱為完整內容校驗。也不自動開啟以下選項來掩蓋重傳：

- `--local-no-set-modtime` 會讓 Local 回報不支援修改時間，可能降成只比大小。
- `--no-update-modtime` 不會修正「無雜湊、時間不同就重新傳」的判定。
- `--refresh-times` 在無共同雜湊時可能直接接受同大小並更新目的時間，不能據此證明內容一致。
- `--local-no-clone` 會失去 Mac 系統複製／APFS clone 的效能；Apple 的 [`COPYFILE_CLONE`](https://github.com/apple-oss-distributions/copyfile/blob/main/copyfile.3) 包含 STAT metadata，沒有證據支持為了解決此回報而全面關閉它。

正在使用的 SQLite、日誌或其他資料檔也可能確實持續更新。SQLite 官方 [備份時的交易一致性說明](https://www.sqlite.org/howtocorrupt.html#_backup_or_restore_while_a_transaction_is_active) 指出，一般檔案複製可能取得跨交易狀態；應在適當時機關閉寫入端，或使用應用程式匯出／資料庫備份機制。不能藉由排除 `-wal` 或 journal 檔來假裝重傳問題已修好。

## 選取部分資料夾時，同步的刪除範圍

rclone 的 [篩選規則](https://rclone.org/filtering/) 同時作用於來源和目的地。若只選取來源下的 A、B 兩個資料夾，正常同步應只處理目的下的 A、B 子樹；未選取的 C 及其他目的項目應保留。

只有選取範圍與排除規則時，可先排除指定內容，再允許 `+ /A/**`、`+ /B/**`，最後 `- **`。資料夾名稱必須依 rclone filter 的語法轉義，不能直接當成萬用字元。**部分選取同步拒絕 `--delete-excluded`**，因為它會讓同步刪除被篩選排除的目的項目；來源選取範圍因而不再能保護選外的資料。

搭配包含規則時，不能把「選到資料夾」與「符合包含規則」寫成兩組獨立允許規則，否則會成為聯集。也不能只列來源檔名再做精確白名單：目的端多出、但符合規則的檔案不在來源白名單裡，反而不會被同步刪除。

Next 對此情況取得**兩端符合既有篩選規則的名稱清單**，再取其中落在選取資料夾內的路徑聯集，作為精確同步範圍。這會多列一次 metadata，但不讀取檔案內容；只在選取加包含規則的組合使用。目的地明確不存在時可視為空清單，其他列目錄錯誤必須停止。這是一次範圍快照，不能承諾執行期間新加入的檔案也都納入這次同步。

上游依據：[`sync.go`](https://github.com/rclone/rclone/blob/v1.75.2/fs/sync/sync.go) 的 `DstIncludeAll`、[`march.go`](https://github.com/rclone/rclone/blob/v1.75.2/fs/march/march.go) 的目的端遍歷，以及 [`filter.go`](https://github.com/rclone/rclone/blob/v1.75.2/fs/filter/filter.go) 的首條相符規則判定。

## 逐檔報告：哪些數字可以確定？

統計來源是既有 `--use-json-log --stats=1s` 的 JSON，定義可查 [`accounting/stats.go`](https://github.com/rclone/rclone/blob/v1.75.2/fs/accounting/stats.go) 與官方 [core/stats](https://rclone.org/rc/#core-stats)。

| 欄位 | v1.75.2 的意義 | 不能如何解讀 |
| --- | --- | --- |
| `checks` | `DoneChecking` 已完成的檢查；刪除等流程也使用 checking transfer | 不是「已略過」檔案數，也不能減去 transfers 後就當略過數 |
| `totalChecks` | 已完成檢查＋目前排隊與正在檢查的數量 | 邊列目錄邊變動，不一定是開頭已知的固定總量 |
| `listed` | 已列出的目錄項目數量 | 不是全部都需要上傳的檔案數 |
| `transfers` | 成功結束的 transfer 計數；Dry Run 也會做模擬 accounting | 必須連同是否預演顯示，不能在 Dry Run 宣稱真傳輸 |
| `totalTransfers` | 已完成 transfer＋排隊及進行中的 transfer | 不包含略過項目，也不是最後所有失敗候選檔案的固定總數 |
| `errors` | rclone 計入的錯誤數；高階重試之間會重設錯誤計數 | 不等於不重複的最終失敗檔案數，也不等於 ERROR 等級記錄行數 |

[`copy`](https://rclone.org/commands/rclone_copy/)、[`move`](https://rclone.org/commands/rclone_move/) 和 [`sync`](https://rclone.org/commands/rclone_sync/) 都支援比較 logger。`= path` 表示依當前規則不需要複製，也可能來自 `--ignore-existing` 或保留較新目的檔的設定，不能固定稱為逐位元相同。`+` 和 `*` 是目的缺少或有差異的比對結果，尚不是傳輸完成；`-` 也不等於已刪除。

真正複製完成以 INFO JSON 的 `Copied (...)` 或 `Multi-thread Copied (...)` 紀錄為準；在 [`copy.go`](https://github.com/rclone/rclone/blob/v1.75.2/fs/operations/copy.go) 中，這些紀錄位在所設定的驗證與最終改名成功之後。移動可能先複製成功，再刪除來源失敗，兩個事件應分開保留。`Moved (server-side)`、`Deleted` 等也依其實際動作記錄，不全都算成上傳。

還有兩個容易誤判的上游細節：[`cmd.Run`](https://github.com/rclone/rclone/blob/v1.75.2/cmd/cmd.go) 用 `Errorf` 寫出「Attempt … succeeded」，它不是失敗；[`pairChecker`](https://github.com/rclone/rclone/blob/v1.75.2/fs/sync/sync.go) 的特定移動路徑會用 `TransferError` logger 回報刪除結果，即使 error 為 nil。因此 `!` 比對紀錄也與真正的 JSON 錯誤訊息分開計數，不直接推成最終失敗檔案。

### 為什麼接標準輸出，再由 App 保存？

[`operationsflags.ConfigureLoggers`](https://github.com/rclone/rclone/blob/v1.75.2/fs/operations/operationsflags/operationsflags.go) 對報告路徑使用 `os.Create`；copy／move／sync 的 command 將此初始化放在高階 retry closure 裡。直接指定同一個報告檔再每秒讀取，可能在還沒讀完上一輪之前，就被下一輪重試清空。

Next 因此使用 `--combined=-`，獨立讀取 stdout，並自行追加到專屬原始報告。stderr 的 JSON 記錄由另一條 pipe 處理；兩者不能用「這一行看起來是不是 JSON」來猜來源。App 不為報告增加掃描或雜湊，不把輸出的路徑拿去執行命令、刪檔或更改同步範圍。

上游 [`logger.go`](https://github.com/rclone/rclone/blob/v1.75.2/fs/operations/logger.go) 以 `%c %s\n` 寫比較紀錄；`--csv` 只影響 `--dest-after`，不能把 `--combined` 轉成 CSV。`--dest-after` 本身也是預測目的內容，並不提供可代替成功紀錄的結果清單。一般 rclone [Standard 編碼](https://github.com/rclone/rclone/blob/v1.75.2/lib/encoder/standard.go) 會把檔名中的換行轉成可見字元；若紀錄不符合格式，App 明示解析異常並保留原文，不編造檔名或精確結論。

JSONL 報告以正式 JSON 編碼器處理文字，能保留 JSON 來源中真正的換行、引號及 Unicode 檔名。它是一份事件紀錄：重試可能出現同一路徑多次；成功後也可能仍保留先前錯誤。UI 將這些數字標為紀錄次數，未知的不重複「略過檔案數」與「最終失敗檔案數」不補成零。

### 記錄成本與分頁邊界

新增的報告 writer 不保存全量檔名陣列。每種輸出以固定大小 buffer 合併追加寫入；摘要只保留少量計數，逐檔資料在使用者打開詳情時分頁讀取。JSON 統計及摘要沿用每秒更新，不因為每個略過檔案而重建工作列表。使用者匯出時先固定完整的位元組邊界，再於 writer lock 外流式製作快照，傳輸可繼續進行。

2026-10-20 以 Linux、Swift 6.0.3 的 `-O` 建置，將 **100,000 筆**合成 `= path` 輸入實際 writer，包含最後的 flush。一般字典 JSON 驗證與排序版本耗時 **10.00 秒**；改用重用的固定結構 `JSONEncoder` 後耗時 **1.562 秒**，約 **64,005 筆／秒**。檔名仍交由正式 JSON 編碼器處理，沒有改成手工串接未轉義的 JSON。

兩次輸出同為 **78,582,245 bytes**：原始比對 3,678,890 bytes，以及完整、比對、略過三份分類 ledger，各 24,967,785 bytes；其他分類在這組情境為空。分類 ledger 保留了直接分頁讀取的簡單結構，代價是部分紀錄在磁碟上重複保存。寫入 buffer 的分批門檻為 64 KiB，單筆 JSON 記錄上限 2 MiB；正常分頁最多 200 筆，讀到約 1 MiB 即停止追加，匯出使用 64 KiB 的串流區塊。這些邊界不會隨工作累積的檔案數無限增長。

這是合成記錄路徑的成本證據，不是 NAS 或雲端滿速保證，也不加入容易受 CI 機器負載影響的效能通過門檻。優化後的 15 項獨立報告測試全數通過，涵蓋 JSON 檔名轉義、重試、預演、分頁、匯出快照與真實 rclone 的受控本機 copy／sync；Mac 和完整 App 的結果仍以本輪 [驗證記錄](VALIDATION.zh-TW.md) 為準。
