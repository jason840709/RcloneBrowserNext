# Rclone Browser Next 0.9.1

0.9.1 將 Mac、Windows 與 Linux 重新整合為同一個正式版號（已包含 Windows 0.9.0 r1 的磁碟與大檔案修正）。

## 更新重點

- **Mac 背景完成 Dock 跳動提醒**：背景傳輸完成或失敗時，Mac 的 Dock 圖示會跳動提醒（不會搶走目前視窗焦點）。此功能預設開啟，可在「設定 → 介面 → 背景執行」關閉，且不需另外開啟系統通知橫幅權限。
- **未知總量進度動畫**：剛開始掃描比對、尚未算出總容量時，進度條會顯示來回移動的色塊；算出總量後即切換為實際百分比，工作結束後停止（開啟系統「減少動態效果」時會改為靜態色塊）。

## 下載與升級

- Apple Silicon Mac：`Rclone_Browser_Next_0.9.1_macOS_arm64.zip`
- Intel Mac：`Rclone_Browser_Next_0.9.1_macOS_x86_64.zip`
- Windows x64：`Rclone_Browser_Next_0.9.1_Windows_x64_Setup.exe`
- Linux amd64（Ubuntu 24.04）：`Rclone_Browser_Next_0.9.1_Linux_amd64.deb`
- 完整原始碼與 Mac 本機建置：`Rclone_Browser_Next_0.9.1_Source.zip`

直接升級即可沿用原有的 rclone 位置、帳號設定、作業與工作區。

## English

Version 0.9.1 brings macOS, Windows and Linux back to one stable release. It includes the Windows filesystem fixes from 0.9.0 revision 1.

On macOS, a completed or failed background transfer briefly bounces the Dock icon without stealing focus. This has its own setting, enabled by default, independent of notification banner permission. Foreground jobs, previews and cancellations do not bounce; closely timed completions share one prompt.

Across all platforms, an unknown total now displays a moving segment instead of static stripes. It switches to measured progress when totals are available and stops when work ends. Queued jobs remain clearly queued, and reduced-motion preferences are respected. Transfer behavior and existing saved settings are preserved.
