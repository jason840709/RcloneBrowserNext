# Rclone Browser Next 0.9.4

## 雲端資料夾快取與重新整理

- **工作階段快取**：左右窗格會各自快取本次使用期間讀過的雲端資料夾（本機資料夾仍每次即時讀取），返回、前進或切回同一資料夾時可立即顯示，不必重複等待網路讀取。
- **重新整理**：點擊某一側的「重新整理」會清除該窗格所有層級、分頁與帳號的快取並重讀目前目錄（不影響另一側窗格與瀏覽歷史）。
- **變更後自動更新**：在 App 內新增、改名、刪除檔案，或完成、取消正式傳輸後，兩側受影響資料夾的快取都會自動失效並更新。

## 可隨時取消的資料夾載入與固定捲軸

- **取消載入**：讀取資料夾時，清單中央會顯示小型讀取圓環與目標位置；滑鼠移到圓環上（或用鍵盤聚焦）會出現取消符號 **×**，點擊即可終止該次遠端讀取並退回上一個位置，不影響另一側或進行中的傳輸。
- **固定捲軸軌道**：檔案清單固定保留右側垂直捲軸寬度與底色，清單不足一頁時只隱藏滑塊，避免長短資料夾切換時版面左右跳動。
- **加速遠端瀏覽**：省去每次列目錄前重複執行的 `listremotes` 檢查與未使用的 MIME type 查詢。

詳細測試範圍請見 [驗證說明](VALIDATION.zh-TW.md)。

---

## English

0.9.4 adds a bounded session cache for remote folders in each pane. Native local folders are read afresh on every navigation. Revisiting a cached location avoids another listing request. Refresh clears every cached location in that pane across folder depths, tabs and accounts, then reads the current location again. The opposite pane and navigation history are preserved. There is no periodic network refresh.

Folder loading keeps the previous successful listing visible under a subtle overlay. A small central ring offers cancellation on hover or keyboard focus, with a static alternative for reduced motion. A successful response commits the new path and history. Cancel stops the associated remote listing process and preserves the last successful location, listing and history without stopping the other pane or transfers. Stale responses cannot overwrite the current view or repopulate invalidated cache entries.

The file list always reserves the vertical scrollbar area and its opaque track, including empty folders and searches with no matches. Short lists hide only the thumb, keeping a solid dark track in dark themes and the same content width; alternating row backgrounds stop before the scrollbar area.

File mutations and completed, failed or cancelled non-Dry-Run transfers invalidate affected locations in both panes; moves include their source. Account or connection changes clear both caches. Browsing skips the redundant `listremotes` preflight and unused MIME type lookup while keeping file size and modification time. First-time cloud loading still depends on the network and provider.

If a transfer changes the displayed folder while another folder is loading, cancelling that navigation or a failed load refreshes the original folder without changing its path or navigation history.

Windows upgrade coverage adds 0.9.3 to the existing 0.9.0, 0.9.0-r1 and 0.9.2 baselines. Release requires the complete CI for the exact source commit, including real listing cancellation and shared Chromium/WebKit navigation checks.
