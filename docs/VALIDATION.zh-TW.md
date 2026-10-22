# 0.9.2 驗證方式與結果位置

0.9.2 延續 Mac、Windows 與 Linux 的統一發布流程，加入圖形化帳號設定與 Mac 持續 Dock 提醒。Windows 保留已驗證的 r1 檔案系統實作；三平台保留 0.9.1 的讀取動畫。

正式發布必須通過同一個來源 commit 的完整 CI：Web 介面與 WebKit 新增案例、Mac arm64／Intel 核心與原生測試、macOS 26 原生測試、Linux 套件與原生視窗，以及 Windows 建置、乾淨安裝、檔案操作、真實 WebView2 互動和兩種舊版升級。

[執行紀錄](https://github.com/jason840709/RcloneBrowserNext/actions/workflows/macos.yml) 的每項工作保留結果。Windows 的 `candidate-verification.json` 逐項核對測試名稱、數量及執行檔雜湊；未完成或失敗的案例不能透過發布門檻。Web 的 JSON 報告區分 Chromium 全套回歸與 WebKit 的動畫、設定和帳號案例。應核對 `v0.9.2` 標籤所指向的來源 commit；未發布的開發執行結果不可當作正式版已通過。發布後的精確來源、工作編號與檔案校驗值另收錄在私人交接包。

## 新功能的測試範圍

Dock 測試確認背景完成／失敗使用持續提醒、重複事件去重、多工作共用尚未確認的提醒、切回後取消與再次提醒，以及前景、取消、預演、關閉開關、退出和原生 API 呼叫。自動化驗證的是事件判斷及 AppKit API，不宣稱已量測每台使用者電腦上的 Dock 動畫像素。系統的 Dock 動畫偏好仍然生效。

帳號核心測試使用真實 rclone 與隔離設定檔，涵蓋服務清單、選定路徑、暫存、儲存、取消、外部修改衝突、刪除、密碼保留、Unicode 名稱與 Google／OneDrive 授權前的問題。Windows 的設定檔路徑會先正規化再比較，並讀回內容核對，不要求兩個程式使用相同的斜線字元。介面測試另檢查 GUI 與 config 入口、必填欄位、動態問題、秘密值不回填、登入等待及取消。這些測試沒有代替帳號擁有者完成真實雲端登入。

進度測試確認六種主題、左右往返、軌道邊界、減少動態效果，以及排隊、掃描、已知總量、停止與完成的切換。Windows／Linux 的安裝後原生視窗另檢查同一份 CSS 動畫能實際播放。

Windows UI 測試以本機 alias 遠端搭配真正 rclone 執行，不含回報者的私人雲端帳號。Windows Server 2025 x64 與 Ubuntu 24.04 CI 不涵蓋所有桌面版本、裝置或雲端供應商。Mac 公開 App 為 ad-hoc 簽章，Windows 安裝程式未具 Authenticode 簽章。

歷史結果：[0.9.0](VALIDATION_0.9.0.zh-TW.md) · [Windows r1](WINDOWS_0.9.0_R1.md)。歷史紀錄不可當作 0.9.2 新測試的通過證據。
