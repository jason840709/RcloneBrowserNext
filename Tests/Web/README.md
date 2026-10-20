# 介面與原生橋接契約測試

這是選用的開發測試。一般使用者雙擊 Mac 建構腳本時，不會下載 Node.js、Playwright、瀏覽器或中文字型，也不會執行此測試。

測試直接從 `file://` 讀取建好的 `Resources/Web/index.html`、IIFE 與正式的 `renderer/bridge.ts`。測試專用 host fixture 接收 `{ id, method, args }`，透過 `__rbnReply` / `__rbnEvent` 回覆；正式介面沒有假資料或檔案系統模擬。

測試程式集中在 `WebSource/tests`，以便直接使用 `WebSource` 內的相依套件：

| 檔案 | 用途 |
| --- | --- |
| `WebSource/tests/ui.spec.ts` | 既有 UI／橋接契約與語言、主題、尺寸回歸 |
| `WebSource/tests/revision04.spec.ts` | 0.4 設定、完整作業、記住環境、斑馬紋與提示回歸 |
| `WebSource/tests/native-fixture.ts` | 只供測試的原生回應與檔案資料 |
| `WebSource/tests/playwright.config.ts` | 測試設定 |
| `Tests/Web/run.sh` | 型別檢查、重建介面及執行測試 |

## 重跑方式

需要已安裝的 Node.js，以及 `WebSource` 的開發相依套件。以下指令都在專案根目錄執行，下載與 npm 快取留在專案內：

```sh
npm --prefix WebSource ci --cache "$PWD/.build-cache/npm"
PLAYWRIGHT_BROWSERS_PATH="$PWD/.build-cache/test-browsers" \
  node WebSource/node_modules/playwright/cli.js install chromium --only-shell
bash Tests/Web/run.sh
```

若要使用既有的相容 Chrome／Chromium，指定執行檔即可，不必再下載瀏覽器：

```sh
RBN_TEST_BROWSER="/你的瀏覽器執行檔路徑" bash Tests/Web/run.sh
```

Linux 的視覺檢查需要中文字型；可透過 `FONTCONFIG_FILE` 指向專案內的 fontconfig、字型及快取。Mac 使用系統字型，不需要另裝字型。`RBN_TEST_OUTPUT` 可指定其他測試輸出目錄；預設為 `.build-cache/web-test-results`。

## 驗證範圍

涵蓋：未安裝 rclone 時的本機瀏覽、資料夾／執行檔選擇、啟動更新開關、略過版本後的手動檢查、原生回覆及事件、特殊檔名轉義、雙面板方向與選取範圍、傳輸數量與進度更新、繁中／英文／日文、淺紫／黑紫／淺藍／黑藍，以及 1060 × 680 和 1440 × 900 的主要操作按鈕。

另外涵蓋設定 partial patch 保存與失敗復原、更新失敗後同程序重試、舊 bootstrap 競態、Config 刷新、NAS 與五種原版 Compare、同步刪除細項、欄寬保存、每面板分頁與選取隔離、Finder 拖入事件只準備不執行，以及目錄樹／匯出／掛載／串流入口。0.4 再加入完整作業編輯與 Dry Run、系統語言、記住環境、網路設定、未發布版本提示及四種配色的整列斑馬紋像素檢查；實際通過數目列在 [本版驗證記錄](../../docs/VALIDATION.zh-TW.md)。

所有傳輸資料與原生回應都是固定的測試資料。這套測試不等於 Mac App 實機測試，也沒有驗證 AppKit／WKWebView、Gatekeeper、真實雲端帳號、實際傳輸或原生更新器。這些部分需另外使用 Core 測試、更新器測試及 Mac 實機檢查。

測試截圖只是暫存檢查資料，不放入 App 或發行套件。
