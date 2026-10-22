# 0.9.1 驗證方式與結果位置

0.9.1 統一 Mac、Windows 與 Linux 的發布流程。Windows 保留已驗證的 r1 檔案系統實作；Mac 新增 Dock 提示，三平台共用讀取動畫。

正式發布必須通過同一個來源 commit 的完整 CI：Web 介面與 WebKit 新增案例、Mac arm64／Intel 核心與原生測試、macOS 26 原生測試、Linux 套件與原生視窗，以及 Windows 建置、乾淨安裝、檔案操作、真實 WebView2 互動和兩種舊版升級。

[執行紀錄](https://github.com/jason840709/RcloneBrowserNext/actions/workflows/macos.yml) 的每項工作保留結果。Windows 的 `candidate-verification.json` 逐項核對測試名稱、數量及執行檔雜湊；未完成或失敗的案例不能透過發布門檻。Web 的 JSON 報告區分 Chromium 全套回歸與 WebKit 的 0.9.1 新增案例。發布後的精確來源、工作編號與檔案校驗值另收錄在私人交接包。

## 新功能的測試範圍

Dock 測試確認背景完成／失敗、重複事件、短時間多工作完成、前景、取消、預演、關閉開關、退出與原生 API 呼叫。自動化驗證的是事件判斷及 AppKit API，不宣稱已量測每台使用者電腦上的 Dock 動畫像素。系統的 Dock 動畫偏好仍然生效。

進度測試確認六種主題、左右往返、軌道邊界、減少動態效果，以及排隊、掃描、已知總量、停止與完成的切換。Windows／Linux 的安裝後原生視窗另檢查同一份 CSS 動畫能實際播放。

Windows UI 測試以本機 alias 遠端搭配真正 rclone 執行，不含回報者的私人雲端帳號。Windows Server 2025 x64 與 Ubuntu 24.04 CI 不涵蓋所有桌面版本、裝置或雲端供應商。Mac 公開 App 為 ad-hoc 簽章，Windows 安裝程式未具 Authenticode 簽章。

歷史結果：[0.9.0](VALIDATION_0.9.0.zh-TW.md) · [Windows r1](WINDOWS_0.9.0_R1.md)。歷史紀錄不可當作 0.9.1 新測試的通過證據。
