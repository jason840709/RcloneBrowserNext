# 活動檔案為什麼會重複傳輸

## rclone 以「整個檔案」為單位重傳

rclone 比對發現檔案需要更新時，會重新傳送整個檔案，而不是只傳變動的幾 KB 區塊（[rclone FAQ](https://rclone.org/faq/#why-doesnt-rclone-support-partial-transfers-binary-diffs-like-rsync)）。

如果某個大型日誌或資料庫檔案在備份過程中持續被其他程式寫入，複製完成後的檔案大小就會跟複製前不一致，導致 rclone 大小驗證失敗並觸發重試（預設最多嘗試 3 次，[官方說明](https://rclone.org/docs/#retries-int)）。

## 如何備份執行中的程式資料夾

- **最穩妥的做法**：備份前先關閉正在寫入該資料夾的程式，或使用檔案系統快照／資料庫專用的備份功能（例如 SQLite 的 Online Backup API 或 `VACUUM INTO`，見 [SQLite 官方備份說明](https://www.sqlite.org/backup.html)）。
- **先傳其他檔案**：在 0.10.4 以後，預設「只重試出錯的檔案」會盡量只處理失敗項目；資料夾讀取錯誤等無法安全局部重試的情況，仍會重新檢查全部檔案；若連變動中的大檔都不想在當下重試，也可將傳輸選項中的「整個傳輸重試」設為 1。

## 0.7.0 報告欄位與符號連結

- **複製成功資料量／大小檢查失敗資料量**：分別累計成功傳完與因大小變動而驗證失敗的資料量，方便看出是否有大型活動檔案在反覆重傳。
- **保留符號連結**：勾選後會使用 `--links` 保存連結本身與指向路徑（在雲端存為 `.rclonelink` 檔，下載時同樣勾選保留即可還原，不會順著連結把外部資料夾整個抓進來；見 [rclone 連結說明](https://rclone.org/local/#local-links-links-l)）。
