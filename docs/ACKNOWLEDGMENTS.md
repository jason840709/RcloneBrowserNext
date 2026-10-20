# 來源與致謝 / Acknowledgments

Rclone Browser Next 的起點是 Rclone Browser 系列所建立的圖形化 rclone 使用方式。原 0.4.0 文件將本版描述為研究既有功能與流程後，以 Swift／AppKit 及 WebKit 重新實作的 Mac 應用程式。本次發布整理保留這項說明；沒有將 Next 標為原 Qt 儲存庫的直接程式碼 fork。

## 參考專案

- **rclone 與其開發者** — https://rclone.org/ · https://github.com/rclone/rclone。Next 呼叫外部 rclone 完成後端存取與傳輸；rclone 不隨本 App 一起打包。
- **mmozeiko／RcloneBrowser** — https://github.com/mmozeiko/RcloneBrowser。早期 Rclone Browser 專案；kapitainsky 的 README 亦說明其延續背景。
- **kapitainsky／RcloneBrowser 及貢獻者** — https://github.com/kapitainsky/RcloneBrowser。Next 參考其 Remotes／Jobs／Tasks、檔案操作和傳輸選項等功能與流程。原版已包含工作、作業及深色模式等概念，不能將它們全部列為 Next 的原創。
- **downer08tutti／RcloneBrowser2** — https://github.com/downer08tutti/RcloneBrowser2。原 0.4.0 文件列出的另一參考專案。該專案本身也介紹 Apple Silicon 支援；Next 不主張自己是第一個提供此支援的 Rclone Browser 衍生專案。
- **ForkLift** — 雙面板互動與版面參考。依原交付文件，本專案未散布其程式碼或私有資源。

Next 由 Jason Chen 開發並獨立發布。上述連結表示來源與致謝，不表示原作者參與、認可或為 Next 提供支援。各原始專案的授權與著作權聲明以該專案為準。

## 本專案與第三方資源

- 本專案程式：[MIT License](../LICENSE)。
- 應用圖示：Jason Chen 提供的 v2 圖示；本次整理未重新繪製。
- 首頁截圖：Jason Chen 提供的 0.4.0 Mac 畫面，介面語言為繁體中文。
- 前端套件：[正式 Web 聲明](../Resources/Web/THIRD_PARTY_NOTICES.txt) 與 [開發來源聲明](../WebSource/THIRD_PARTY_NOTICES.txt)。

本頁依本次可讀取的原始碼、原 0.4.0 文件與公開專案說明整理。保留原授權檔與套件聲明；本次文件整理未另外完成逐行程式碼來源鑑定。
