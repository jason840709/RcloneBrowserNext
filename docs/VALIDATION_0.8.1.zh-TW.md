# Rclone Browser Next 0.8.1 驗證記錄

0.8.1 的 Web 介面回歸測試（181 項）已全部通過；Mac 原生測試與 Windows／Linux 封裝驗證則於發布 CI 執行。

## 驗證範圍

| 項目 | 檢查內容 | 狀態 |
| --- | --- | --- |
| 正式 Web 介面 | 左右窗格歷史、滑鼠驅動命令、對話框開啟期間保護、主題與縮放比例 | 181 通過，0 失敗 |
| macOS 15 `arm64`／`x86_64` | Core、WebKit 原生事件、啟動載入畫面交接、主題圖示與簽章、React 導覽 | 由 CI 驗證 |
| macOS 26 `arm64` | 原生啟動交接、圖示與導覽測試 | 由 CI 驗證 |
| Windows x64／Linux amd64 | helper、結束確認政策、原生視窗與安裝套件 | 由 CI 驗證 |

Mac 新增 `MacStartupTests`（驗證六色主題啟動載入層交接與防白閃）、`MacIconTests`（驗證三色執行期圖示與簽章完整性）與 `MacNavigationIntegrationTests`（原生事件與真實 rclone 導覽整合）。逐項 Web 結果見 [Web 驗證紀錄](../WebSource/tests/VERIFICATION.zh-TW.md)。

歷史紀錄：[0.8.0 完整驗證](VALIDATION_0.8.0.zh-TW.md) · [0.8.0 Web 紀錄](../WebSource/tests/history/0.8.0/verification.json) · [0.8.0 原生及發布紀錄](verification/0.8.0-native.json) · [0.7.0 完整驗證](VALIDATION_0.7.0.zh-TW.md)
