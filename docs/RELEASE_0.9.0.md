# Rclone Browser Next 0.9.0

這一版整理啟動畫面、外觀選項與主畫面工具列，讓常用操作和傳輸說明更清楚。

## 啟動畫面

「正在啟動」與「正在讀取 rclone 設定」共用相同圖示素材、尺寸、字級和位置。原生載入畫面跟隨已保存的介面大小，切換載入階段時只更新狀態文字。沿用 0.8.1 的繪製完成檢查，避免顯示 WebKit 尚未畫好的背景。

## 主畫面與外觀

- 外觀選項排成三欄兩排：上排淺紫、淺綠、淺藍；下排黑紫、黑綠、黑藍，同色系上下對齊。
- 移除主畫面重複的「檔案」標題，設定齒輪移到帳號設定左邊。
- 「儲存工作區」與「儲存作業」並排，中間用細線區分；旁邊的資訊提示說明兩者用途，也支援鍵盤焦點。
- 儲存工作區會記住左右位置、方向、操作和傳輸選項，供下次開啟時還原。儲存作業可命名、保留勾選範圍，供之後載入或執行。

## 傳輸說明

複製、同步與移動改用一致的中性文字，依欄寬自然換行。同步說明涵蓋將目標更新為與來源一致的完整含義；選取範圍、篩選條件及既有傳輸設定照常適用。

移除傳輸選項下方的「同時傳輸 1／7」與「∞」簡寫。平行檔案數和速度上限仍可在傳輸選項中調整；有設定速度上限時，主畫面會顯示清楚的限速文字。既有備份方案、工作區和作業的傳輸參數維持原值。

## 圖示

App 內與執行中的 Dock 圖示跟隨紫、綠、藍色系。Finder 與 App 結束後的 Dock 仍使用固定紫色圖示；切換主題不改寫已簽章的 App。

## 下載

| 平台 | 檔案 |
| --- | --- |
| Apple Silicon Mac | `Rclone_Browser_Next_0.9.0_macOS_arm64.zip` |
| Intel Mac | `Rclone_Browser_Next_0.9.0_macOS_x86_64.zip` |
| 完整原始碼與 Mac 本機建置 | `Rclone_Browser_Next_0.9.0_Mac_Local_Build.zip` |
| Windows x64 | `Rclone_Browser_Next_0.9.0_Windows_x64_Setup.exe` |
| Linux amd64，Ubuntu 24.04 | `Rclone_Browser_Next_0.9.0_Linux_amd64.deb` |

macOS 是主要開發平台。Windows／Linux 使用相同傳輸核心與 Web 介面。

[Mac 建置](BUILD_MAC.zh-TW.md) · [Windows／Linux 安裝與建置](BUILD_COMPATIBILITY.md) · [驗證記錄](VALIDATION.zh-TW.md)
