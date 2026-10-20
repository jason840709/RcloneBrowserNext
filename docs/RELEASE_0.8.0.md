# Rclone Browser Next 0.8.0

這一版修正啟動與資料夾切換的閃爍、補齊滑鼠側鍵事件，並調整介面大小的標準。

## 啟動與資料夾切換

- 開啟視窗時立即使用已保存的主題底色，再進入載入畫面與主畫面。
- 進入資料夾、返回或前進時，保留原清單直到新資料載入完成，再一次更新內容。載入期間暫停舊列的檔案操作。
- 快速切換多個資料夾時，只採用最後一次導覽的結果。

## 滑鼠側鍵

側鍵的後退與前進會操作滑鼠所在的窗格；滑鼠在窗格外時，操作目前啟用的窗格。左右窗格及各分頁分別保存瀏覽歷史。

Mac 從主視窗接收側鍵，再傳給介面；也處理只收到按下或放開的事件。同一次按鍵經過多條事件路徑時只執行一次，連續按鍵則逐次處理。Windows 與 Linux 共用介面的側鍵處理。

## 介面大小

| 0.7.0 的大小 | 0.8.0 顯示為 |
| --- | --- |
| 90% | **100%，新的標準大小** |
| 100% | **110%** |

新安裝預設為新的 100%。升級時會轉換已保存的比例，保留原本的視覺大小；原有較大的設定也會保留。

## 下載

| 平台 | 檔案 |
| --- | --- |
| Apple Silicon Mac | `Rclone_Browser_Next_0.8.0_macOS_arm64.zip` |
| Intel Mac | `Rclone_Browser_Next_0.8.0_macOS_x86_64.zip` |
| 完整原始碼與 Mac 本機建置 | `Rclone_Browser_Next_0.8.0_Mac_Local_Build.zip` |
| Windows x64 | `Rclone_Browser_Next_0.8.0_Windows_x64_Setup.exe` |
| Linux amd64，Ubuntu 24.04 | `Rclone_Browser_Next_0.8.0_Linux_amd64.deb` |

macOS 仍是主要開發平台。完整原始碼包也包含 Windows 與 Linux 的建置腳本及相依套件鎖定檔。

[Mac 建置](BUILD_MAC.zh-TW.md) · [Windows／Linux 安裝與建置](BUILD_COMPATIBILITY.md) · [驗證記錄](VALIDATION.zh-TW.md)
