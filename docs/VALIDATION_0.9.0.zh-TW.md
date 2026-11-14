# Rclone Browser Next 0.9.0 驗證記錄

0.9.0 Web 回歸、五平台 CI 與公開發布均已完成。建置來源為 [`ed76a5c269660fe919b7ffe664820baadff6790f`](https://github.com/jason840709/RcloneBrowserNext/commit/ed76a5c269660fe919b7ffe664820baadff6790f)（[CI run 39530803169](https://github.com/jason840709/RcloneBrowserNext/actions/runs/39530803169)），正式發布於 [0.9.0 Release](https://github.com/jason840709/RcloneBrowserNext/releases/tag/v0.9.0)。

## 驗證結果

| 項目 | 結果 |
| --- | --- |
| 正式 Web 介面 | 189 通過、0 失敗、0 略過 |
| 本輪新增 Web 回歸 | 8 通過、0 失敗 |
| [macOS 15 Apple Silicon](https://github.com/jason840709/RcloneBrowserNext/actions/runs/39530803169/job/118995977857)（12 套） | 204 通過、0 失敗、1 略過 |
| [macOS 15 Intel](https://github.com/jason840709/RcloneBrowserNext/actions/runs/39530803169/job/118995977675)（12 套） | 204 通過、0 失敗、1 略過 |
| [macOS 26 Apple Silicon 原生介面](https://github.com/jason840709/RcloneBrowserNext/actions/runs/39530803169/job/118995977762)（4 套） | 53 通過、0 失敗、0 略過 |
| [Windows x64](https://github.com/jason840709/RcloneBrowserNext/actions/runs/39530803169/job/118995977486) | Rust 5、Platform 9、helper 10、安裝後原生 UI 1，全部通過 |
| [Linux amd64](https://github.com/jason840709/RcloneBrowserNext/actions/runs/39530803169/job/118995977511) | Rust 5、Platform 10、helper 9、封裝後原生 UI 1，全部通過 |

- **啟動畫面與原生測試**：三個 Mac 環境的 `MacStartupTests`（各 12 項）比對六色主題與不同縮放比例下，原生載入層與 Web 載入畫面的圖示位置、字級與防白閃交接。
- **Web 介面與工具列**：驗證三語工具列、儲存工作區／儲存作業並排與提示、六色主題上淺下深排列，以及複製／同步／移動說明與限速顯示。

詳細數據保存於 [原生與發布 JSON](verification/0.9.0-native.json)、[Web 驗證說明](../WebSource/tests/VERIFICATION.zh-TW.md) 與 [Web 機器可讀紀錄](../WebSource/tests/verification.json)。

歷史紀錄：[0.8.1 原始驗證文件](VALIDATION_0.8.1.zh-TW.md) · [0.8.1 Web 紀錄](../WebSource/tests/history/0.8.1/verification.json) · [0.8.0 完整驗證](VALIDATION_0.8.0.zh-TW.md) · [0.8.0 原生與發布紀錄](verification/0.8.0-native.json)
