# 掛載 SMB / NAS 的檔案比較：原因、選項與驗證

## 已確認的原因

Finder 掛載的 SMB 路徑，例如 `/Volumes/NAS/Backup`，對 rclone 是 local filesystem backend。local backend 的 `Object.Hash()` 需要開啟並讀取檔案內容來計算雜湊；如果檔案在 SMB 磁碟上，這些讀取會經由網路。

rclone 的預設比較先看大小與修改時間。兩者相同時通常能直接略過；大小相同但修改時間不同時，仍可能比較雜湊，判斷只須修正時間或需要重傳。因此「未選 checksum 模式」不等於完全不讀 NAS 內容。`--ignore-checksum` 只關閉傳輸完成後的雜湊校驗，也不會關閉這個傳輸前比較分支。

這是官方 v1.75.2 原始碼中可直接追溯的路徑：

- [`fs/operations/operations.go`](https://github.com/rclone/rclone/blob/v1.75.2/fs/operations/operations.go)：`equal()` 先比較大小與時間，時間不同再呼叫 `CheckHashes()`；`CheckHashes()` 先求兩端共同支援的 hash set。
- [`backend/local/local.go`](https://github.com/rclone/rclone/blob/v1.75.2/backend/local/local.go)：`Object.Hash()` 在沒有可用的快取時 `file.Open()` 並透過 `hash.StreamTypes()` 讀內容。
- [`fs/operations/copy.go`](https://github.com/rclone/rclone/blob/v1.75.2/fs/operations/copy.go)：傳後完整性檢查與傳前 Equal 比較是不同階段。

## 提供的 NAS 比較設定

### 大小與修改時間（不計算本機雜湊）

使用預設大小／修改時間比較，加上 `--local-hashes none`。v1.75.2 的 local backend 有 `hashes` 選項，而 `hash.Type.Set()` 明確接受 `none`，使 local backend 回報空的雜湊集合。沒有共同雜湊時，修改時間不同的檔案會被當作需要傳輸，不會先讀回目標整個檔案算雜湊。

這比「只比大小」多利用了修改時間：同大小的內容變更，只要修改時間也變更，就仍會傳輸。代價是涉及本機後端的傳輸不再提供該端的內容雜湊校驗，也不能偵測內容改變而大小及修改時間完全相同的情況；兩端都屬雲端後端時，不會因此停用它們原有的雜湊能力。時間標記不穩定的 NAS 可能因時間差而多傳；可先確認 NAS 的時間與精度，再設定合適的 `--modify-window`，不能為了減少傳輸盲目放大容許誤差。

此選項只停用 local 後端的雜湊，包括 Finder 掛載的 SMB 磁碟。它不會停用雲端或伺服器後端的雜湊能力；實際傳輸仍需讀取來源內容，檔案列舉與中繼資料存取也仍會有網路流量。

此 profile 不需要再加 `--ignore-checksum`，因為已沒有共同 local hash 可供傳前或傳後校驗。切換到雜湊比較會退出 NAS 模式；核心拒絕同時停用 local 雜湊又要求雜湊比較的設定，避免 checksum 模式默默退化成大小比較。

原始碼依據：[local `Hashes()`](https://github.com/rclone/rclone/blob/v1.75.2/backend/local/local.go)、[hash parser 的 `none`](https://github.com/rclone/rclone/blob/v1.75.2/fs/hash/hash.go)。當日官網亦列出 [`--local-hashes`](https://rclone.org/local/#local-hashes)；實際 none 語義以固定版本 source 及下述 CLI 實測核對。

### 一般比較與內容完整性驗證

需要保留預設比較，或選「大小＋雜湊」。這些選擇可能讀取網路磁碟檔案內容，應讓使用者知道流量原因。若想做更強的內容驗證而不把檔案讀回 Mac，可以選擇 NAS 端能計算 hash 的協定，例如支援遠端 shell checksum 的 SFTP；需 NAS 配置與 hash 工具確實可用，不是 GUI 改一個勾選即可保證。

直接使用 rclone 的 SMB remote 是另一條路。它與 Finder 的 local mount 不同：官方 SMB backend 回報沒有 hash 支援，使用修改時間精度為毫秒。這避免 GUI 以 local backend 計算目標雜湊，但不能宣稱獲得了遠端內容 hash 保證。`--checksum` 沒有共同 hash 時還是會退回大小比較。

依據：[SMB backend `Hashes()` 與 `Precision()`](https://github.com/rclone/rclone/blob/v1.75.2/backend/smb/smb.go)、[官方 SFTP](https://rclone.org/sftp/)。本次沒有連接使用者 NAS，也沒有驗證其 SSH 權限或是否有 checksum 工具。

## 不適合拿來當 NAS 修正的旗標

| 旗標 | 實際意義 | 為何不能宣稱解決同一問題 |
|---|---|---|
| `--size-only` | 大小相同即略過 | 可能漏掉同大小的修改，精度較低 |
| `--checksum` | 改以大小和共同雜湊判斷 | local SMB mount 會讀內容；沒有共同 hash 時退回大小 |
| `--ignore-checksum` | 略過傳後 hash 驗證 | 傳前時間不同的 hash 分支仍會讀內容 |
| `--ignore-times` | 無條件重新傳送 | 不是更省流量的比較方式 |
| `--update` | 略過目標較新的檔案 | 比較較舊目標時仍可能讀 hash，且改變覆寫語義 |
| `--use-server-modtime` | 部分 object storage 用伺服器時間代替額外 metadata API | 不是 local SMB backend 的雜湊開關 |
| `--no-update-modtime` | 不修正內容相同檔案的時間 | hash 可能已經讀完才確定相同 |
| `--local-no-check-updated` | 不檢查來源檔案在傳輸中是否變動 | 不是傳前比較開關，會放棄偵測正在修改的來源 |

## 真實 CLI 驗證

測試使用官方 Linux `rclone v1.75.2`。本機建立 1 MiB 檔案，來源全為 A、目標全為 B，大小相同、時間不同。每個測試都新啟動 rclone，以 Linux inotify 監看**目標檔案本體**的 `OPEN`、`ACCESS`、`CLOSE_NOWRITE`。執行 `copy --dry-run`，不改動來源與目標。

| 選項 | 目標內容讀取事件 | rclone 判斷 |
|---|---|---|
| 預設 | OPEN + ACCESS + CLOSE_NOWRITE | 內容不同，需要傳送 |
| `--ignore-checksum` | OPEN + ACCESS + CLOSE_NOWRITE | 仍先讀內容，需要傳送 |
| `--local-hashes none` | 沒有 OPEN / ACCESS | 時間不同，需要傳送 |
| `--size-only` | 沒有 OPEN / ACCESS | 誤將同大小、不同內容視為相同 |

這組固定版本的四次執行均結束碼 0。這證明相同 rclone local backend 的內容讀取差異；不是 macOS SMB 網路量測，也沒有宣稱已在使用者群暉設備上實測速度。

這個 profile 的價值是把網路磁碟常見的「先讀回檔案雜湊」改為可解釋、可選擇的 metadata 比較，同時保留一般與內容驗證模式，讓使用者依資料的重要程度選擇。
