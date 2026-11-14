# Rclone Browser Next 0.8.0 驗證記錄

0.8.0 四平台 CI 與正式發布均已完成。建置來源為 [`f2435c706770f68770d7c95fadfa54e3d814a014`](https://github.com/jason840709/RcloneBrowserNext/commit/f2435c706770f68770d7c95fadfa54e3d814a014)（[CI run 39467210330](https://github.com/jason840709/RcloneBrowserNext/actions/runs/39467210330)），正式發布於 [0.8.0 release](https://github.com/jason840709/RcloneBrowserNext/releases/tag/v0.8.0)。

## 驗證結果

| 項目 | 結果 |
| --- | --- |
| 正式 Web 介面 | 176 通過，0 失敗、0 略過、0 重試 |
| macOS Apple Silicon（九套） | 168 通過，0 失敗，1 略過（Linux `inotify` 測試） |
| macOS Intel（九套） | 168 通過，0 失敗，1 略過（Linux `inotify` 測試） |
| Windows x64 | Rust 4、Platform 9、helper 9、安裝後原生介面 1，全部通過 |
| Linux amd64 | Rust 4、Platform 10、helper 8、封裝後原生介面 1，全部通過 |

- **Mac 原生側鍵與外觀**：`MacInterfaceTests` 19 項全過，涵蓋 `NSWindow.sendEvent` 側鍵完整按壓、單邊放開、快速連按、載入前主題背景與五段縮放座標定位。
- **Web 介面與縮放遷移**：驗證左右窗格與分頁歷史、載入期間保留舊清單、過期請求丟棄，以及 schema 7 縮放比例自動換算（詳見 [Web 驗證記錄](../WebSource/tests/VERIFICATION.zh-TW.md)、[Web JSON](../WebSource/tests/verification.json) 與 [原生及發布紀錄](verification/0.8.0-native.json)）。

歷史紀錄：[0.7.0 完整驗證](VALIDATION_0.7.0.zh-TW.md) · [0.6.0 驗證](VALIDATION_0.6.0.zh-TW.md)
