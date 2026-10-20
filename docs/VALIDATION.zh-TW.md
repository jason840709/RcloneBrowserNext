# Rclone Browser Next 0.8.1 驗證記錄

0.8.1 的完整 Web 回歸已完成，181 項全部通過。Mac 原生測試與 Windows／Linux 封裝驗證待本版 CI 結果；完成後將補上受測 commit、平台通過數量及發布檔校驗值。

## 本版驗證範圍

| 項目 | 檢查內容 | 狀態 |
| --- | --- | --- |
| 正式 Web 介面 | 左右窗格歷史、驅動命令、編輯與對話框保護、既有主題與比例 | 181 通過，0 失敗、略過、重試 |
| macOS 15 arm64／x86_64 | Core、WebKit 原生事件、啟動交接、圖示保存、完整 React 導覽 | 待 CI |
| macOS 26 arm64 | 同一套原生啟動、圖示與導覽測試 | 待 CI |
| Windows x64 | helper、結束政策、原生介面、安裝包 | 待 CI |
| Linux amd64 | helper、結束政策、原生介面、DEB | 待 CI |
| 發布檔 | 版本 0.8.1／build 81、架構、簽章、來源與 SHA-256 | 待建置及發布 |

Mac 新增三套測試：`MacStartupTests` 使用正式 Web 成品與原生載入層檢查主題交接；`MacIconTests` 在已簽章 App 的副本保存圖示，結束設定圖示的程序後重新讀取，並核對資源與簽章；`MacNavigationIntegrationTests` 將原生事件接到正式 React 介面與真實 rclone 目錄。

Web 完整測試於 2026-10-20T19:10:20.142Z 開始，耗時 166.4 秒，正式成品與來源雜湊在測試前後一致。逐項結果見 [Web 驗證紀錄](../WebSource/tests/VERIFICATION.zh-TW.md)。其餘原生與封裝項目待 CI；實體 MX Master 3S 操作不計入自動化結果。

## 歷史紀錄

[0.8.0 完整驗證](VALIDATION_0.8.0.zh-TW.md) · [0.8.0 Web 紀錄](../WebSource/tests/history/0.8.0/verification.json) · [0.8.0 原生及發布紀錄](verification/0.8.0-native.json) · [0.7.0 完整驗證](VALIDATION_0.7.0.zh-TW.md)
