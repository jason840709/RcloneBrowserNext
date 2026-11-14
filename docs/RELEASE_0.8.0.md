# Rclone Browser Next 0.8.0

這一版消除啟動與切換資料夾時的畫面閃爍、完善滑鼠側鍵導覽，並調整預設介面縮放比例。

## 啟動與資料夾切換

- 開啟視窗時立即套用已儲存的主題底色，消除載入期間的白色閃爍。
- 進入資料夾或返回／前進時，保留原清單直到新資料載入完成再一次更新；快速連點多個資料夾時只顯示最後一次的結果。

## 滑鼠側鍵導覽

- 滑鼠側鍵的返回與前進會操作游標所在的面板（游標在視窗外時操作目前作用中的面板），左右面板與各分頁各自保存瀏覽歷史。
- 修正 Mac 側鍵單邊事件與多重路徑重複觸發問題。

## 介面大小調整

| 0.7.0 設定值 | 0.8.0 對應為 |
| --- | --- |
| 90% | **100%（新的標準大小）** |
| 100% | **110%** |

全新安裝預設為新的 100%；從舊版升級時會自動換算設定值，維持你原本看到的視覺大小不變。

## 下載

| 平台 | 檔案 |
| --- | --- |
| Apple Silicon Mac | `Rclone_Browser_Next_0.8.0_macOS_arm64.zip` |
| Intel Mac | `Rclone_Browser_Next_0.8.0_macOS_x86_64.zip` |
| 完整原始碼與 Mac 本機建置 | `Rclone_Browser_Next_0.8.0_Mac_Local_Build.zip` |
| Windows x64 | `Rclone_Browser_Next_0.8.0_Windows_x64_Setup.exe` |
| Linux amd64（Ubuntu 24.04） | `Rclone_Browser_Next_0.8.0_Linux_amd64.deb` |

[Mac 建置](BUILD_MAC.zh-TW.md) · [Windows／Linux 安裝與建置](BUILD_COMPATIBILITY.md) · [驗證記錄](VALIDATION.zh-TW.md)
