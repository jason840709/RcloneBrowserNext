# Rclone Browser Next 0.7.0 驗證記錄

**0.7.0 已通過 Apple Silicon Mac、Intel Mac、Windows x64 與 Linux x64 四平台原生建置與測試，並正式發布。**（舊版結果見 [0.6.0 驗證記錄](VALIDATION_0.6.0.zh-TW.md)。）

## 本機驗證結果（Linux x86_64）

| 範圍 | 結果 | 驗證內容 |
| --- | --- | --- |
| Web 介面 | 163／163 通過 | 位置選單向下展開與內部捲動、五段縮放、三語視窗、傳輸報告與各平台入口 |
| CoreTests | 56／56 通過 | 檔案操作、複製與同步、選取範圍、停止與佇列控制、設定與作業保存 |
| NativeMessagesTests | 13／13 通過 | 三語原生訊息、操作範圍與錯誤文字格式 |
| TransferReportTests | 25／25 通過 | 比對與傳輸結果分列、重試事件、成功與失敗副本大小、第二次同步與符號連結 |
| Linux 相容版 helper | 8／8 通過 | 啟動、檔案清單、預演、複製、第二次同步、報告匯出、取消與重啟狀態 |

詳細紀錄保存於 [Web 驗證記錄](../WebSource/tests/VERIFICATION.zh-TW.md) 與 [0.7.0 本機驗證摘要](verification/0.7.0-local.json)。

## 四平台原生 CI 結果

建置來源為 [commit `5f60aab8874dece2913f54467c23c841736e987b`](https://github.com/jason840709/RcloneBrowserNext/commit/5f60aab8874dece2913f54467c23c841736e987b)，對應 [Actions run 39454908404](https://github.com/jason840709/RcloneBrowserNext/actions/runs/39454908404) 與 [發布工作](https://github.com/jason840709/RcloneBrowserNext/actions/runs/39454908404/job/118745373113)，於 2026-10-20 16:21:39 UTC 發布 [v0.7.0](https://github.com/jason840709/RcloneBrowserNext/releases/tag/v0.7.0)（完整數據見 [0.7.0 原生 CI 驗證 JSON](verification/0.7.0-native.json)）。

| 平台與 CI 工作 | CI 環境 | 結果 |
| --- | --- | --- |
| [macOS arm64](https://github.com/jason840709/RcloneBrowserNext/actions/runs/39454908404/job/118739108177) | `macos-15` | 建置、簽章與九套測試通過（**157 通過、0 失敗、1 略過**） |
| [macOS x86_64](https://github.com/jason840709/RcloneBrowserNext/actions/runs/39454908404/job/118739107893) | `macos-15-intel` | 建置、簽章與九套測試通過（**157 通過、0 失敗、1 略過**） |
| [Windows x86_64](https://github.com/jason840709/RcloneBrowserNext/actions/runs/39454908404/job/118739108088) | Windows Server 2025 | NSIS 安裝包建置、安裝、檔案操作、傳輸與原生視窗檢查通過 |
| [Linux x86_64](https://github.com/jason840709/RcloneBrowserNext/actions/runs/39454908404/job/118739108222) | Ubuntu 24.04 | `.deb` 建置、檔案操作、傳輸與原生視窗檢查通過 |

### macOS 九套測試明細（通過／失敗／略過）

| 測試套件 | arm64 | x86_64 |
| --- | ---: | ---: |
| CoreTests | 55／0／1 | 55／0／1 |
| UpdaterTests | 20／0／0 | 20／0／0 |
| ToolsTests | 12／0／0 | 12／0／0 |
| NativeMessagesTests | 13／0／0 | 13／0／0 |
| FinderDropTests | 5／0／0 | 5／0／0 |
| AppReleaseTests | 8／0／0 | 8／0／0 |
| TransferReportTests | 25／0／0 | 25／0／0 |
| PlatformTests | 10／0／0 | 10／0／0 |
| MacInterfaceTests | 9／0／0 | 9／0／0 |
| **合計** | **157／0／1** | **157／0／1** |

相關建置說明見 [Mac 建置說明](BUILD_MAC.zh-TW.md) 與 [相容版安裝說明](BUILD_COMPATIBILITY.md)。
