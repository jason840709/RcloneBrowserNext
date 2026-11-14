# Rclone Browser Next 0.8.1

這一版進一步改善 Mac 啟動畫面交接與滑鼠手勢導覽、簡化退出確認，並讓載入畫面圖示跟隨主題變色。

## 啟動畫面與圖示配色

- 視窗開啟時先顯示套用主題色系的原生載入畫面，確認 WebKit 完成繪製後才交接，減少啟動瞬間的閃白。
- App 內、載入畫面、選單列與執行中的 Dock 圖示均會跟隨所選的紫、藍、綠色系變色；Finder 與關閉 App 後的 Dock 圖示則維持預設紫色。

## 滑鼠返回／前進與結束確認

- Mac 新增支援滑鼠驅動程式送出的水平滑動（swipe）與原生返回／前進命令，連同一般側鍵與 `Command + [`／`]` 皆可切換該面板的資料夾歷史。
- 當沒有進行中或失敗／未完成的工作時，按 `Command + Q` 會直接結束 App，不再每次跳出確認窗；若有未完成工作才會詢問並在確認後先停止工作。

## 下載

| 平台 | 檔案 |
| --- | --- |
| Apple Silicon Mac | `Rclone_Browser_Next_0.8.1_macOS_arm64.zip` |
| Intel Mac | `Rclone_Browser_Next_0.8.1_macOS_x86_64.zip` |
| 完整原始碼與 Mac 本機建置 | `Rclone_Browser_Next_0.8.1_Mac_Local_Build.zip` |
| Windows x64 | `Rclone_Browser_Next_0.8.1_Windows_x64_Setup.exe` |
| Linux amd64（Ubuntu 24.04） | `Rclone_Browser_Next_0.8.1_Linux_amd64.deb` |

[Mac 建置](BUILD_MAC.zh-TW.md) · [Windows／Linux 安裝與建置](BUILD_COMPATIBILITY.md) · [驗證記錄](VALIDATION.zh-TW.md)
