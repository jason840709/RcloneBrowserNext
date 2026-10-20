<p align="center"><img src="docs/assets/icon.png" width="112" alt="Rclone Browser Next icon"></p>
<h1 align="center">Rclone Browser Next</h1>
<p align="center"><strong>支援本機對本機、雲端對雲端傳輸的 macOS rclone 圖形介面。</strong></p>
<p align="center">Apple Silicon 原生支援 · 全新雙面板介面 · 四種傳輸組合</p>
<p align="center">
  <a href="https://github.com/jason840709/RcloneBrowserNext/releases/latest">下載 0.4.0</a> ·
  <a href="README.en.md">English</a> ·
  <a href="docs/USER_GUIDE.zh-TW.md">使用手冊</a> ·
  <a href="https://github.com/jason840709/RcloneBrowserNext/issues">回報問題</a>
</p>

![Rclone Browser Next 0.4.0：深色雙面板介面，中央設定傳輸方向、操作方式與 Dry Run，下方顯示工作佇列](docs/assets/rclone-browser-next-macos.png)

**Rclone Browser Next 是給 macOS 使用的 rclone 圖形介面。左右兩側都能自行選擇本機資料夾或雲端空間，支援本機對本機、本機對雲端、雲端對本機，以及雲端對雲端傳輸。** 也能選擇已掛載的 NAS 路徑或 rclone 設定的 NAS／伺服器連線，再依需要複製、移動或同步。

## 為什麼做這個版本

[rclone](https://rclone.org/) 能連接許多儲存服務；[Rclone Browser](https://github.com/kapitainsky/RcloneBrowser) 則讓人透過圖形介面使用這些能力。這些前人的工作，是 Next 的出發點。

原版的傳輸操作主要圍繞本機與雲端之間的上傳、下載。我希望左右兩側都能自由選擇位置，讓本機對本機、雲端對雲端也能直接從介面操作。同時，我重新設計介面，並以 Swift／AppKit 和 macOS 內建的 WebKit 建立支援 Apple Silicon 的 Mac 應用程式。

— Jason Chen

## 這次改了什麼

### 支援 Apple Silicon Mac（M1、M2、M3、M4）

支援 **macOS 13 以上**。M1、M2、M3、M4 等 Apple Silicon Mac 可建立原生 arm64 App；也保留 Intel 的 x86_64 建置方式。本機建置會依硬體選擇架構，arm64 App 不需要透過 Rosetta 執行。

### 新增本機對本機、雲端對雲端傳輸

左右兩側都能獨立選擇本機或雲端，不再將傳輸方向固定為本機上傳或下載到本機。

| 傳輸組合 | 使用範例 |
| --- | --- |
| 本機 → 本機 | 從 Mac 資料夾複製到外接硬碟或已掛載的 NAS |
| 本機 → 雲端 | 將 Mac 的資料上傳到雲端 |
| 雲端 → 本機 | 將雲端資料下載到 Mac |
| 雲端 → 雲端 | 在兩個已設定的雲端位置之間傳送資料 |

原版介面主要提供本機與雲端之間的傳輸；Next 將本機對本機、雲端對雲端也納入同一套操作方式。這是介面對傳輸組合的擴充，實際傳輸由 rclone 執行；是否能由服務端直接複製，取決於後端支援，雲端對雲端不代表一定不經過這台 Mac。

### 重新設計雙面板操作介面

左右面板各自瀏覽資料夾，也各自保留分頁。中央把傳輸方向、複製／移動／同步、來源與目標摘要放在一起，讓你在按下開始前先確認「從哪裡，傳到哪裡」。

搜尋、路徑列、檔案選取與可調整的欄寬，讓瀏覽更接近熟悉的檔案管理工具。下方工作佇列銜接傳輸進度與記錄；上方的「檔案／傳輸／作業」則讓你在不同工作之間切換。深淺兩種底色搭配紫色或藍色，共有四種外觀，並提供繁體中文、English、日本語。

## 與原版的關係

| 面向 | Rclone Browser（kapitainsky） | Rclone Browser Next |
| --- | --- | --- |
| 平台 | macOS、Windows、Linux／BSD | 目前專注 macOS 13 以上 |
| 應用程式架構 | C++／Qt | Swift／AppKit＋系統 WebKit，React 介面 |
| Mac 架構 | 舊版 Mac 發行方式 | 依硬體建立 arm64 或 x86_64 App |
| 傳輸組合 | 介面主要提供本機 → 雲端、雲端 → 本機 | 左右位置獨立選擇，另可操作本機 → 本機、雲端 → 雲端 |
| 日常操作 | Remotes、Jobs、Tasks | 參考這些流程，重新安排成雙面板、中央傳輸控制與工作佇列 |
| 傳輸引擎 | rclone | 同樣使用獨立的 rclone |

Next 的主要改進是擴充傳輸組合、支援 Apple Silicon，以及重新設計雙面板介面。Dry Run 預演、儲存作業等是沿用的既有功能，不列為本版新增。完整保留項目與差異請看 [功能對照](docs/FEATURE_MATRIX.zh-TW.md)。

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
