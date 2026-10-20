# Rclone Browser Next 0.8.0 驗證記錄

## 已完成的介面驗證

正式 Web 成品的完整回歸測試 **176／176 通過，0 失敗、0 略過、0 重試**。測試開始於 2026-10-20 17:19:35 UTC，耗時 174.9 秒；新增的 13 個 0.8.0 案例另有一次完整通過紀錄。

測試涵蓋啟動主題、資料夾清單保留與過期請求、載入期間的舊列操作阻擋、左右窗格側鍵、僅按下／僅放開事件、快速連按、原生／DOM 去重，以及新比例與保留的 120%／135% 設定。既有六主題、三語言、位置選單、任務與大型清單案例一併執行。

TypeScript 與正式 bundle 建置通過；測試前後的 Web 成品及來源雜湊相同。逐項結果與雜湊見 [Web 驗證記錄](../WebSource/tests/VERIFICATION.zh-TW.md) 及 [機器可讀紀錄](../WebSource/tests/verification.json)。

## 原生建置

本版已加入設定 schema 7 的一次性遷移測試，以及由 `NSEvent` 經正式 Mac 視窗處理送入 WebKit 的側鍵測試。四平台 CI 使用同一份來源，建置 Apple Silicon Mac、Intel Mac、Windows x64 與 Linux amd64；完成結果將記錄於本頁。

## 歷史紀錄

[0.7.0 完整驗證](VALIDATION_0.7.0.zh-TW.md) · [0.6.0 驗證](VALIDATION_0.6.0.zh-TW.md)
