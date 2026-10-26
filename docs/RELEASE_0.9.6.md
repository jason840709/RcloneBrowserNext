# Rclone Browser Next 0.9.6

## 修正 Mac 本機複製留下鎖定暫存檔

修正 macOS 在本機磁碟、記憶卡或外接磁碟間複製時，檔案可能停在 `原檔名.<8 位識別碼>.partial`，並出現 `partial file rename failed: ... operation not permitted` 的問題。

rclone 的 macOS 原生快速複製路徑會隱含複製檔案屬性，包含來源的鎖定旗標；即使未勾選「保留中繼資料」，也可能使目的暫存檔無法完成改名或清理。0.9.6 對直接本機到本機的傳輸使用一般資料複製，保留暫存檔、原本的驗證設定及完成後改名流程。預覽、實際命令與匯出的設定紀錄使用相同政策。

傳輸明細新增「暫存檔改名遭拒絕」的說明，保留原始錯誤與原始暫存檔名。重試產生的多筆錯誤仍按事件呈現，不冒充不同檔案數量。

## 修復已留下的暫存檔

Mac 選單 **Rclone Browser Next → 修復未完成的本機複製…** 可使用工作明細匯出的完整 JSONL 報告：

1. 先停止進行中的傳輸、掛載或播放，再選擇該次傳輸報告。
2. App 只核對報告中能精確對應原始檔名的改名失敗項目，逐檔比較來源與暫存檔的大小及完整 SHA-256。
3. 畫面顯示可修復、已存在、內容不一致與無法核對的數量，確認後才處理。
4. 修復時重新驗證來源、內容與檔案身分，只解除已確認暫存檔的使用者鎖定，以不覆寫的原子改名還原正式名稱。
5. 正式檔名已存在、內容不同、來源已變動、符號連結、無法確認身分或權限不足的項目會保留並列入結果。來源內容及鎖定屬性不修改，其他暫存檔不處理。

核對計畫與逐檔結果保存在 App 的 Recovery 資料夾，完成畫面可以在 Finder 開啟。僅更新 App 不會自動處理舊的鎖定暫存檔；修復完成後，重新整理清單即可查看正式檔名。

## 行為與效能

- 一般複製仍保留原來的時間比對、篩選、同步範圍、重試與取消保護，不啟用 `--inplace`。
- macOS 直接本機傳輸不再使用 APFS reflink／原生 clone 加速，因此同一 APFS 磁碟內的大檔複製會實際搬移資料，耗時和磁碟用量可能增加。
- 勾選「保留中繼資料」仍交由 rclone 標準中繼資料機制處理其支援的時間、權限、擁有者與欄位；它不等同於完整保存 Finder 屬性、所有 Mac 延伸屬性或資源分支。
- 保留 0.9.5 的同名清單修正，以及先前版本的導航快取、捲軸背景、帳號設定、進度與 Dock 提醒。

## 驗證

本版加入真正 macOS 的鎖定檔案對照、隔離 FAT32／ExFAT 測試磁碟、逐檔恢復及完整 App 修復入口測試。兩種卡片格式的原地恢復都必須實際成功，才通過正式 Mac 發布檢查。三平台統一為 0.9.6；Windows 升級驗證新增已發布的 0.9.5，並保留 0.9.0、0.9.0-r1、0.9.2、0.9.3、0.9.4。

實際結果以[同一來源提交的正式 CI](https://github.com/jason840709/RcloneBrowserNext/actions/workflows/macos.yml)及其原始測試紀錄為準。開發分支的 Mac 專項預檢不代替完整發布門檻。

## 技術依據

- [rclone v1.75.2：Darwin clone／copy 路徑](https://github.com/rclone/rclone/blob/v1.75.2/backend/local/clone_darwin.go)
- [rclone：本機檔案系統與 `--local-no-clone`](https://rclone.org/local/#local-no-clone)
- [Apple：copyfile 屬性與 clone fallback](https://github.com/apple-oss-distributions/copyfile/blob/main/copyfile.3)
