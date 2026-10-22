# Rclone Browser Next 0.9.1

Mac、Windows 與 Linux 統一為 0.9.1 正式版。Windows 已納入 0.9.0 修正版 1 的本機檔案讀取、磁碟位置、大檔案與根目錄處理，不再需要另外尋找預發布版本。

## 完成傳輸的 Dock 提示

Mac 在背景完成或失敗時，會讓 Dock 圖示短暫跳動，不會搶走目前視窗的焦點。此功能預設開啟，可在「設定 → 介面 → 背景執行」關閉；與原有的系統通知開關分開，不需要先允許通知橫幅。前景操作、預演與取消工作不會觸發；短時間多項工作完成會合併提示。

## 看得見的讀取進度

開始掃描與比對、尚未取得總量時，原本靜止的條紋改成沿進度軌道來回移動的色塊。取得可計算總量後，改用實際百分比；完成、失敗或取消後停止動畫。等待排隊的工作不會冒充正在掃描。系統開啟減少動態效果時，保留固定色塊與狀態文字。

Mac、Windows 與 Linux 使用同一份進度介面。動畫只改變顯示，不增加檔案讀取、不另外計算雜湊，也不改變傳輸參數。

## 下載與升級

- Apple Silicon Mac：`Rclone_Browser_Next_0.9.1_macOS_arm64.zip`
- Intel Mac：`Rclone_Browser_Next_0.9.1_macOS_x86_64.zip`
- Windows x64：`Rclone_Browser_Next_0.9.1_Windows_x64_Setup.exe`
- Linux amd64（Ubuntu 24.04）：`Rclone_Browser_Next_0.9.1_Linux_amd64.deb`
- 三平台原始碼與 Mac 本機建置：`Rclone_Browser_Next_0.9.1_Source.zip`

原有的 rclone 位置、帳號設定、儲存作業與工作區沿用；rclone 仍是外部引擎。Mac 需要 macOS 13 以上。Mac 使用 ad-hoc 簽章，Windows 安裝程式未具 Authenticode 簽章；校驗值在同頁的 `SHA256SUMS_0.9.1.txt`。

## English

Version 0.9.1 brings macOS, Windows and Linux back to one stable release. It includes the Windows filesystem fixes from 0.9.0 revision 1.

On macOS, a completed or failed background transfer briefly bounces the Dock icon without stealing focus. This has its own setting, enabled by default, independent of notification banner permission. Foreground jobs, previews and cancellations do not bounce; closely timed completions share one prompt.

Across all platforms, an unknown total now displays a moving segment instead of static stripes. It switches to measured progress when totals are available and stops when work ends. Queued jobs remain clearly queued, and reduced-motion preferences are respected. Transfer behavior and existing saved settings are preserved.
