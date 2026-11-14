# Rclone Browser Next 0.6.0 驗證記錄

驗證日期：2026-10-20 UTC

## 測試結果摘要

**0.6.0 已通過 Apple Silicon 與 Intel 雙架構 Mac 原生建置與測試（各 137 項通過、0 失敗、1 略過），並正式發布。**

| 驗證項目 | 結果 | 測試環境 |
| --- | --- | --- |
| CoreTests | 56 通過，0 失敗，0 略過 | Linux x86_64、Swift 6.0.3、rclone 1.75.2 |
| TransferReportTests | 15 通過，0 失敗，0 略過 | Linux x86_64、獨立報告與真實 rclone 回歸 |
| 正式 Web 介面 | 140 通過，0 失敗，0 略過 | Linux Chrome（載入正式 `file://` bundle） |
| TypeScript 與正式建置 | 通過 | 鎖定的 `WebSource` 依賴 |
| 六色主題色彩對比 | 120／120 通過 | 六種主題色彩 token 對比檢查 |
| 原生 Mac 雙架構 CI | **各 137 通過、0 失敗、1 略過** | GitHub Actions `macos-15`／`macos-15-intel`（macOS 15.7.9） |

Mac CI 執行紀錄見 [Actions run 39423143808](https://github.com/jason840709/RcloneBrowserNext/actions/runs/39423143808)（建置 commit [`4eac09b64abc272cbd3016c65be04e92d5dc015a`](https://github.com/jason840709/RcloneBrowserNext/commit/4eac09b64abc272cbd3016c65be04e92d5dc015a)，發布於 [v0.6.0](https://github.com/jason840709/RcloneBrowserNext/releases/tag/v0.6.0)）。詳細驗證數據保存於 [本機驗證 JSON](verification/0.6.0.json)、[Mac CI 驗證 JSON](verification/0.6.0-macos-ci.json)、[SOURCE_MANIFEST.json](../SOURCE_MANIFEST.json) 與 [Web 驗證記錄](../WebSource/tests/VERIFICATION.zh-TW.md)（[JSON](../WebSource/tests/verification.json)）。

## 各模組驗證重點

- **重複同步與部分資料夾選取**：驗證第二次同步零重傳（`unchangedBytes=0`）、模擬 10ms 時間精度量化後零重傳、勾選子資料夾同步時保留未選取目標資料夾，以及勾選資料夾搭配包含規則時正確清理範圍內多出的舊檔（詳見 [NAS 比對](NAS_COMPARISON.zh-TW.md)）。
- **工作清理與停止流程**：驗證啟動清除已完成紀錄、保留超過 200 筆中斷工作、批次清除範圍鎖定、真實 rclone `SIGINT` 中斷清理 `.partial` 暫存檔，以及無回應程序升級至 `SIGKILL`（詳見 [0.6.0 原碼分析](RESEARCH_0.6.0.md)）。
- **逐檔報告與效能**：驗證 281 個成功檔案分頁讀取、`--combined=-` 跨重試保留紀錄、特殊字元與 Unicode 檔名 JSON 編碼，以及 100,000 筆略過紀錄寫入效能（耗時 1.562 秒，約 64,005 筆／秒）。
- **介面、配色與縮放**：驗證三種語言、六種主題、五段縮放（80%～125%）、來源側專屬勾選框、滑鼠側鍵去重與不透明捲軸軌道。

## macOS 雙架構測試明細

| 架構與 CI 工作 | 系統／Swift 版本 | 通過／失敗／略過 | App 大小 |
| --- | --- | --- | --- |
| [Apple Silicon（arm64）](https://github.com/jason840709/RcloneBrowserNext/actions/runs/39423143808/job/118628901658) | macOS 15.7.9／Swift 6.1.2 | **137／0／1** | **3.95 MiB** |
| [Intel（x86_64）](https://github.com/jason840709/RcloneBrowserNext/actions/runs/39423143808/job/118628901742) | macOS 15.7.9／Swift 6.1.2 | **137／0／1** | **4.01 MiB** |

| 測試套件 | 通過 | 失敗 | 略過 |
| --- | --- | --- | --- |
| CoreTests | 55 | 0 | 1（Linux `inotify` 專屬測試） |
| UpdaterTests | 20 | 0 | 0 |
| ToolsTests | 12 | 0 | 0 |
| NativeMessagesTests | 13 | 0 | 0 |
| FinderDropTests | 5 | 0 | 0 |
| AppReleaseTests | 8 | 0 | 0 |
| TransferReportTests | 15 | 0 | 0 |
| MacInterfaceTests | 9 | 0 | 0 |
| **合計** | **137** | **0** | **1** |

註：首輪 [Mac CI](https://github.com/jason840709/RcloneBrowserNext/actions/runs/39422459070) 因 `statfs` 名稱衝突未過，改用 `O_EVTONLY` 搭配 `fstatfs` 後於 [修正 commit](https://github.com/jason840709/RcloneBrowserNext/commit/4eac09b64abc272cbd3016c65be04e92d5dc015a) 通過雙架構建置與 `codesign --verify --strict` 簽章驗證（本機建置說明見 [BUILD_MAC.zh-TW.md](BUILD_MAC.zh-TW.md)）。

## 實測界線

時間精度測試使用模擬量化，本輪沒有測試每一種實體 exFAT、FAT 或 NAS 裝置；雲端取消的 API 行為也不等於已逐個服務實測。Mac 原生快速複製的取消殘留、真實 SMB 斷線及各家雲端的區塊清理，須依個別測試紀錄判定。
