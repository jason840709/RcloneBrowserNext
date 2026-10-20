# Rclone Browser Next 0.8.1

這一版補修 0.8.0 的 Mac 啟動與滑鼠導覽，調整結束確認，並讓載入畫面的圖示跟隨主題色系。

## 啟動畫面

視窗開啟時先顯示已保存主題的原生載入畫面，圖示也使用所選色系。WebKit 完成畫面繪製後才顯示 Web 介面，避免載入提示出現前的白色畫面。載入失敗或逾時時，可從同一畫面重試。

資料夾切換沿用 0.8.0 的處理：原清單保留到新清單完成，再更新內容。

## 滑鼠前進與後退

Mac 增加水平 swipe 事件及原生返回／前進命令的接收，處理滑鼠驅動轉換後的導覽操作。一般側鍵、Command＋`[`／`]` 以及選單的上一頁／下一頁都連到資料夾歷史。

滑鼠操作使用游標所在的窗格；快捷鍵與選單使用目前啟用的窗格。左右窗格及各分頁各自保存歷史。輸入文字或開啟對話框時，保留目前操作。

## 結束 App

沒有傳輸工作，或全部工作都已成功完成時，Command-Q 直接結束。有失敗、取消、中斷或尚未完成的工作時，會先顯示確認；若仍有傳輸、串流或掛載，確認後先停止工作再結束。

## 圖示顏色

App 內、載入畫面、選單列與執行中的 Dock 圖示使用所選紫、藍或綠色。Finder 與 App 結束後的 Dock 使用固定的紫色圖示。三色圖示素材均保留透明背景與三圈造型。

## 介面大小與下載

沿用 0.8.0 的標準：新版 100% 等於 0.7.0 的 90%，新版 110% 等於原來的 100%。升級保留已保存的大小與傳輸設定。

| 平台 | 檔案 |
| --- | --- |
| Apple Silicon Mac | `Rclone_Browser_Next_0.8.1_macOS_arm64.zip` |
| Intel Mac | `Rclone_Browser_Next_0.8.1_macOS_x86_64.zip` |
| 完整原始碼與 Mac 本機建置 | `Rclone_Browser_Next_0.8.1_Mac_Local_Build.zip` |
| Windows x64 | `Rclone_Browser_Next_0.8.1_Windows_x64_Setup.exe` |
| Linux amd64，Ubuntu 24.04 | `Rclone_Browser_Next_0.8.1_Linux_amd64.deb` |

macOS 仍是主要開發平台。完整原始碼包包含三個平台的建置腳本、測試與相依套件鎖定檔。

[Mac 建置](BUILD_MAC.zh-TW.md) · [Windows／Linux 安裝與建置](BUILD_COMPATIBILITY.md) · [驗證記錄](VALIDATION.zh-TW.md)
