# Rclone Browser Next 0.9.6

## 修正 Mac 本機複製留下鎖定暫存檔的問題

修正 macOS 在本機磁碟、記憶卡或外接硬碟之間複製含有「已鎖定（uchg）」屬性的檔案時，目標端可能卡在 `原檔名.<8位識別碼>.partial` 並報錯 `partial file rename failed: ... operation not permitted` 的問題。

原因是 rclone 在 macOS 的原生快速複製（`copyfile` clone）會連同來源檔案的鎖定旗標一併複製到 `.partial` 暫存檔，導致傳輸完成後無法將暫存檔改名為正式檔名。0.9.6 起，Mac 本機對本機傳輸會加上 `--local-no-clone` 改用一般複製流程，避免複製來源的鎖定屬性而使暫存檔無法改名（同一顆 APFS 磁碟內複製大檔時會實際寫入資料，不再使用 copy-on-write 瞬間複製）。

## 修復舊版留下的 `.partial` 暫存檔

若舊版曾留下鎖定的 `.partial` 暫存檔，可從 Mac 選單列點選 **Rclone Browser Next → 修復未完成的本機複製…**，匯入該次工作的 JSONL 逐檔報告來自動修復：

1. 先停止進行中的傳輸，選擇當時匯出的 JSONL 報告檔。
2. App 會找出改名失敗的項目，逐一比對來源檔與目標 `.partial` 暫存檔的大小與完整 SHA-256 雜湊值。
3. 確認清單後開始修復：若磁碟支援不覆寫的原子改名，會直接解鎖暫存檔並改回正式檔名；若為 FAT32／exFAT 等外接記憶卡，則會另建正式檔案並核對完整 SHA-256，保留原暫存檔。重建需要額外空間；只有修復完成且收據完整的結果，才能再次核對後清理對應的 `.partial`。未完成的新檔不算修復成功。

修復計畫與逐檔收據皆保存在 App 的 `Recovery` 資料夾中，完成後可直接從畫面在 Finder 開啟查看。

## Windows 並行讀取取消修正

修正 Windows 版同時讀取多個資料夾時，子程序可能繼承其他讀取管線、導致按取消後仍卡住等待的問題。

## 技術參考與驗證

- [rclone v1.75.2：Darwin clone／copy 實作](https://github.com/rclone/rclone/blob/v1.75.2/backend/local/clone_darwin.go)
- [rclone：`--local-no-clone` 說明](https://rclone.org/local/#local-no-clone)
- [Apple：`copyfile` 屬性說明](https://github.com/apple-oss-distributions/copyfile/blob/main/copyfile.3)
- [CI 執行紀錄](https://github.com/jason840709/RcloneBrowserNext/actions/workflows/macos.yml)
