<p align="center"><img src="docs/assets/icon.png" width="112" alt="Rclone Browser Next icon"></p>
<h1 align="center">Rclone Browser Next</h1>
<p align="center"><strong>讓 rclone 的檔案管理，跟上現在的 Mac。</strong></p>
<p align="center">Apple Silicon 原生建置 · 全新雙面板介面 · 本機、雲端與 NAS</p>
<p align="center">
  <a href="https://github.com/jason840709/RcloneBrowserNext/releases/latest">下載 0.4.0</a> ·
  <a href="README.en.md">English</a> ·
  <a href="docs/USER_GUIDE.zh-TW.md">使用手冊</a> ·
  <a href="https://github.com/jason840709/RcloneBrowserNext/issues">回報問題</a>
</p>

![Rclone Browser Next 0.4.0：深色雙面板介面，中央設定傳輸方向、操作方式與 Dry Run，下方顯示工作佇列](docs/assets/rclone-browser-next-macos.png)

**Rclone Browser Next 是給 macOS 使用的 rclone 圖形介面。** 把本機資料夾、雲端空間或 NAS 放在左右兩側，確認方向，選擇複製、移動或同步，再開始傳輸。你可以在同一個視窗瀏覽檔案、預演變更、查看進度，並把常用設定存成作業。

## 為什麼做這個版本

[rclone](https://rclone.org/) 能連接許多儲存服務；[Rclone Browser](https://github.com/kapitainsky/RcloneBrowser) 則讓人透過圖形介面使用這些能力。這些前人的工作，是 Next 的出發點。

我想延續這種使用方式，也希望它能更適合現在的 Mac：在 Apple Silicon 上原生執行，讓來源、目標和傳輸方向更容易核對，並重新整理每天會用到的操作。因此，Rclone Browser Next 以 Swift／AppKit 和 macOS 內建的 WebKit 建立新的應用程式與介面。

— Jason Chen

## 這次改了什麼

### 為 Apple Silicon 建置

支援 **macOS 13 以上**。M1、M2、M3、M4 等 Apple Silicon Mac 可建立原生 arm64 App；也保留 Intel 的 x86_64 建置方式。本機建置會依硬體選擇架構，arm64 App 不需要透過 Rosetta 執行。

### 從選位置到開始傳輸，都在眼前

左右面板各自瀏覽資料夾，也各自保留分頁。中央把傳輸方向、複製／移動／同步、來源與目標摘要放在一起，讓你在按下開始前先確認「從哪裡，傳到哪裡」。

搜尋、路徑列、檔案選取與可調整的欄寬，讓瀏覽更接近熟悉的檔案管理工具。下方工作佇列銜接傳輸進度與記錄；上方的「檔案／傳輸／作業」則讓你在不同工作之間切換。深淺兩種底色搭配紫色或藍色，共有四種外觀，並提供繁體中文、English、日本語。

### 預演一次，常用設定留下來

- **Dry Run 預演**：先查看 rclone 預計進行的動作，再決定是否正式執行。
- **儲存作業**：保留來源、目標、操作和傳輸選項，下次可以編輯、預演或執行。
- **記住工作環境**：重新開啟時還原兩側位置與傳輸設定，接續操作；還原本身不會啟動傳輸。
- **NAS 比較選項**：針對掛載的 SMB／NAS，可選擇以大小與修改時間比較，避免只為計算本機雜湊而讀回完整檔案。它也可能漏掉大小、時間都沒變的內容修改，詳見 [NAS 比較說明](docs/NAS_COMPARISON.zh-TW.md)。

### 用 Mac 已有的系統元件

App 使用 Swift、AppKit 與系統 WebKit，介面以 React 建立。應用程式不另外打包 Electron、Chromium 或 Qt；rclone 也獨立安裝，方便沿用既有引擎與帳號設定。

## 與原版的關係

| 面向 | Rclone Browser（kapitainsky） | Rclone Browser Next |
| --- | --- | --- |
| 平台 | macOS、Windows、Linux／BSD | 目前專注 macOS 13 以上 |
| 應用程式架構 | C++／Qt | Swift／AppKit＋系統 WebKit，React 介面 |
| Mac 架構 | 舊版 Mac 發行方式 | 依硬體建立 arm64 或 x86_64 App |
| 日常操作 | Remotes、Jobs、Tasks | 參考這些流程，重新安排成雙面板、中央傳輸控制與工作佇列 |
| 傳輸引擎 | rclone | 同樣使用獨立的 rclone |

Next 的重點是 Mac 架構支援與操作介面的重新設計。原版已有工作、作業、深色模式等功能；這些概念在 Next 中獲得延續。完整保留項目與差異請看 [功能對照](docs/FEATURE_MATRIX.zh-TW.md)。

## 開始使用

目前提供 **0.4.0 來源建置包**。需要 Mac 已有可用的 Xcode 或 Apple Command Line Tools；rclone 另行準備。App 尚無 Developer ID 簽章與 Apple 公證，建議在自己的 Mac 建置。

1. 從 [Releases](https://github.com/jason840709/RcloneBrowserNext/releases/latest) 下載來源包，完整解壓縮。
2. 雙擊 `Build-on-Mac.command`，在該資料夾產生 App。建置不會自行安裝開發工具、Node.js 或 rclone。
3. 開啟 App，在設定選擇 rclone 的位置；透過「帳號設定（Config）」加入需要的遠端連線。
4. 選好左右位置、方向與操作，先按「預演 · Dry Run」，確認後再開始。

**同步可能刪除目標端檔案；移動會在傳送成功後移除對應來源。** 第一次使用請先以測試資料預演。

[完整使用手冊](docs/USER_GUIDE.zh-TW.md) · [Mac 建置說明](docs/BUILD_MAC.zh-TW.md) · [開發說明](docs/DEVELOPMENT.md) · [驗證範圍](docs/VALIDATION.zh-TW.md)

## 致謝與授權

Rclone Browser Next 由 **Jason Chen** 開發，以 [MIT License](LICENSE) 發布。它承接 Rclone Browser 系列的使用構想與工作流程，以新的 Mac 架構實作；並非原專案的官方新版，也不代表原作者參與或背書。

- [rclone](https://rclone.org/) 與其開發者：提供實際連接儲存服務與傳輸檔案的引擎。
- [mmozeiko／RcloneBrowser](https://github.com/mmozeiko/RcloneBrowser)：早期 Rclone Browser 專案。
- [kapitainsky／RcloneBrowser](https://github.com/kapitainsky/RcloneBrowser) 及其貢獻者：延續原專案，提供 Next 研究的功能分類與操作流程。
- [downer08tutti／RcloneBrowser2](https://github.com/downer08tutti/RcloneBrowser2)：另一個延續開發的專案，亦為本版參考來源。
- ForkLift：雙面板操作與版面參考；本專案未散布它的程式碼或私有資源。

圖示由 Jason Chen 提供。第三方前端套件聲明隨 [Web 資源](Resources/Web/THIRD_PARTY_NOTICES.txt) 附上。更多來源關係見 [致謝說明](docs/ACKNOWLEDGMENTS.md)。
