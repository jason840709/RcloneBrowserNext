# Rclone Browser Next 0.9.4

## 資料夾快取與重新整理

左右窗格各自保留本次使用期間已讀取的雲端資料夾清單。本機資料夾每次切換仍會重新讀取。返回、前進或切回同一位置時，可直接使用仍有效的快取，減少重複讀取。快取有容量上限，優先淘汰較久未使用的資料，不會每隔幾分鐘自動讀取網路。

按下某一側的「重新整理」，會清除該窗格所有層級、分頁與帳號的清單快取，再重新讀取目前位置；另一側不受影響，瀏覽歷史也會保留。其他程式或裝置變更遠端內容後，可用這個操作取得最新清單。

在 App 內新增、重新命名或刪除項目，以及正式傳輸結束後，兩側受影響位置的快取會失效。失敗或取消的正式傳輸也可能已修改部分檔案，因此同樣處理；移動還會處理來源位置。Dry Run 不會因預演結果清除快取。帳號或連線設定變更後，兩側快取會一併清除。

開啟另一個資料夾期間，如果傳輸改動了原本顯示的位置，取消或載入失敗後會重新讀取原位置，保留原路徑與瀏覽歷史，避免繼續顯示變更前的清單。

## 可取消的資料夾載入

讀取資料夾時，檔案清單中央顯示小型圓環、正在開啟的位置與取消控制。原清單維持可見，載入期間暫停選取、開啟與檔案操作。滑鼠停留或鍵盤聚焦時，圓環中央顯示取消符號；開啟系統「減少動態效果」時使用靜態提示。

新清單成功後才更新路徑與瀏覽歷史。取消會終止該次遠端清單讀取的子程序，保留上一次成功的路徑、清單與歷史；其他窗格和傳輸工作不受影響。較早請求即使晚到，也不會覆蓋目前畫面或填回已失效的快取。取消載入與停止傳輸是兩個獨立操作。

檔案清單固定保留垂直捲軸的寬度與不透明軌道；內容不足一頁時只隱藏滑塊。空資料夾與搜尋沒有符合項目時也保留同一區域。深色主題的軌道維持深色，交錯列底色不會延伸進捲軸區，長短清單的內容邊界保持一致。

## 減少重複開銷

遠端瀏覽直接交由 `lsjson` 驗證並列出位置，省去每次讀取前額外執行 `listremotes` 的存在性檢查。清單略過介面未使用的 MIME type，保留檔案大小與修改時間；傳輸前的檢查維持原有行為。

第一次開啟尚未快取的雲端資料夾，仍取決於網路、服務回應與資料夾內容。這些調整減少重複程序及不必要資訊的開銷，不保證固定的載入秒數。

## 相容性與發布驗證

三平台維持同一版本，保留 0.9.3 的快速／詳細帳號設定、Mac Dock 提醒與 Windows R1 檔案系統修正。Windows 升級檢查新增 0.9.3，並保留 0.9.0、0.9.0-r1、0.9.2。

發布前須通過同一來源 commit 的完整 CI。新增驗證範圍包括快取容量、每窗格全深度重新整理、過期回應、取消後路徑與歷史、真實清單子程序終止，以及 Chromium／WebKit 的取消控制與減少動態效果。測試範圍、結果位置與限制見[驗證說明](VALIDATION.zh-TW.md)；本文不以開發中的本機結果代替正式 CI 通過證據。

---

## English

0.9.4 adds a bounded session cache for remote folders in each pane. Native local folders are read afresh on every navigation. Revisiting a cached location avoids another listing request. Refresh clears every cached location in that pane across folder depths, tabs and accounts, then reads the current location again. The opposite pane and navigation history are preserved. There is no periodic network refresh.

Folder loading keeps the previous successful listing visible under a subtle overlay. A small central ring offers cancellation on hover or keyboard focus, with a static alternative for reduced motion. A successful response commits the new path and history. Cancel stops the associated remote listing process and preserves the last successful location, listing and history without stopping the other pane or transfers. Stale responses cannot overwrite the current view or repopulate invalidated cache entries.

The file list always reserves the vertical scrollbar area and its opaque track, including empty folders and searches with no matches. Short lists hide only the thumb, keeping a solid dark track in dark themes and the same content width; alternating row backgrounds stop before the scrollbar area.

File mutations and completed, failed or cancelled non-Dry-Run transfers invalidate affected locations in both panes; moves include their source. Account or connection changes clear both caches. Browsing skips the redundant `listremotes` preflight and unused MIME type lookup while keeping file size and modification time. First-time cloud loading still depends on the network and provider.

If a transfer changes the displayed folder while another folder is loading, cancelling that navigation or a failed load refreshes the original folder without changing its path or navigation history.

Windows upgrade coverage adds 0.9.3 to the existing 0.9.0, 0.9.0-r1 and 0.9.2 baselines. Release requires the complete CI for the exact source commit, including real listing cancellation and shared Chromium/WebKit navigation checks.
