# 在 Mac 建置 Rclone Browser Next

這份原始碼包含 Mac 視窗、Rust 傳輸引擎，以及已經打包好的介面。建置前需要 Apple 開發工具、Rust 1.90 以上及 Python 3.11 以上；腳本會使用現有工具，不會代為安裝或更新。

第一次編譯時，Rust 會下載尚未快取的套件。介面資源已經附在原始碼中，一般建置不需要 Node.js，也不需要重新編譯介面。

## 建置步驟

1. 將完整原始碼解壓縮到本機可寫入的資料夾。
2. 雙擊建置入口。完成後會產生並開啟 App，不會替換「應用程式」裡的正式版。
3. 在新 App 的設定中選擇 rclone 執行檔，或將 rclone 下載到指定位置。

支援 macOS 13 以上、Apple 晶片與 Intel。預設建置目前這台 Mac 的架構。若只想編譯，請使用附錄的「不自動開啟」指令。

建置完成前，腳本會先驗證 App 結構、架構與簽章。需要重新建置同一份 App 時，先結束那份 App；若建置失敗，原本的成品會保留。

## 簽章與首次開啟

這份 App 使用本機簽章，尚未經 Apple 公證。傳給另一台 Mac 後，首次開啟可能需要到「系統設定 → 隱私權與安全性」按「強制打開」。修改 App 裡面的檔案會使簽章失效。

## 測試

先建置，再執行測試入口並提供測試用 rclone 的完整位置。核心測試使用 Rust；Mac 視窗、啟動畫面、圖示、導航、完成提醒、雙擊縮放與部分檔案修復仍由原生測試檢查。

測試使用獨立狀態資料夾和合成檔案。實際傳輸測試會使用明確提供的 rclone，不使用日常的雲端帳號設定。歷次結果見[驗證紀錄](VALIDATION.zh-TW.md)。

## 遇到問題時

建置或測試失敗時，先看終端機印出的紀錄位置，從第一個錯誤開始查看。若提示已有同一份建置在執行，先確認前次程序是否已結束；不要略過鎖定繼續建置。

## 附錄：入口、指令與檔案位置

建置、驗證與測試入口分別為 `Build-on-Mac.command`、`Verify-App.command`、`Test-on-Mac.command`。

```bash
/bin/bash "/原始碼位置/Build-on-Mac.command" --no-launch
/bin/bash "/原始碼位置/Verify-App.command"
/bin/bash "/原始碼位置/Test-on-Mac.command" "/測試工具位置/rclone"
```

指定架構時，對應的 Rust target 必須已安裝。這台電腦的建置腳本不會自動下載 target：

```bash
RBN_BUILD_ARCH=arm64 /bin/bash "/原始碼位置/Build-on-Mac.command" --no-launch
# Intel：RBN_BUILD_ARCH=x86_64
```

若套件已下載完整，可用 `RBN_CARGO_OFFLINE=1` 限制 Cargo 不連網。原生介面單獨驗證可加 `RBN_NATIVE_TESTS_ONLY=1`。

下表的根目錄：一般解壓縮資料夾就是原始碼根目錄；若原始碼位於 `01_原始碼`，則採用它的上一層。

| 根目錄下的位置 | 內容 |
| --- | --- |
| `.build/mac/products/Rclone Browser Next.app` | 完成的 App |
| `.build/mac/distribution` | App ZIP 與 SHA-256 校驗檔 |
| `.build/mac/logs` | 建置與驗證紀錄 |
| `.build/mac/tests` | Rust 與原生測試結果及合成資料 |
| `.build/mac/backups` | 被同一份新建置替換前的 App |
| `.build/swift-shell` | Swift 與 Clang 模組快取 |
| `.build/release` | Rust 引擎與建置輸出 |
| `.tmp` | 建置暫存 |

日常設定資料夾維持 `~/Library/Application Support/Rclone Browser Next Lite`；rclone 本身與其帳號設定檔仍使用設定中指定的位置。公開原始碼不應包含日常帳號、憑證或私人紀錄。

詳細測試對照見 `Tests/rust-test-map.json`；建置與橋接實作見[開發說明](DEVELOPMENT.md)，Windows／Linux 見[相容版建置](BUILD_COMPATIBILITY.md)。
