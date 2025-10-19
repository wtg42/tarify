# Repository Guidelines

## Project Structure & Modules
- `src/`：核心程式碼與測試
  - `main.zig`：CLI 進入點，負責呼叫 tar 打包流程與錯誤處理。
  - `cli_validate.zig`：解析與驗證 CLI 參數，確保輸出路徑非既有目錄。
  - `file_modifier.zig`：提供檔案處理純函式，供其他模組重用。
  - `install_script.zig`：維護 INSTALL.sh 內容轉換邏輯（標記區塊產生、備份清單輸出）。
  - `root.zig`：示例函式與內嵌測試。
- `build.zig`：建置腳本與目標設定。
- `scripts/`：CI 與開發輔助腳本（`ci.sh`, `fmt.sh`, `test_all.sh`），皆採 POSIX `sh`。
- `third_party/libarchive/`：libarchive 標頭搜尋路徑（需系統安裝 libarchive）。
- 產物輸出於 `zig-out/`。

## Build & Test Commands
- `zig build`：建置可執行檔至 `zig-out/`。
- `zig build run -- <dir> <output>`：以 CLI 將 `<dir>` 打包為 `<output>.tgz`。
- `zig build test`：執行所有 Zig `test` 區塊；CI、在地腳本皆以此指令為核心。
- `zig fmt .`：套用官方格式化。
- 依賴需求：已安裝 `libarchive` 與 `libc`。
- README 提供各平台安裝 `libarchive` 方法，變更需同步更新文件。

## Coding Style & Conventions
- 使用 `zig fmt`；維持預設 4 空白縮排。
- 檔案命名採 `snake_case`；函式與變數採 `lowerCamelCase`。
- 避免全域狀態；在 API 間明確傳遞 `allocator` 並對稱釋放。
- 錯誤以 Zig `error` 傳遞；必要時使用 `std.log.*`，避免冗長輸出。
- 公開 API 需註記參數語意、錯誤型別與所有權；改動時記得同步文件。

## Testing Guidelines
- 採 Zig 內建測試（檔內 `test "..." {}`）並以 `zig build test` 執行。
- 優先覆蓋模組：
  - `cli_validate.zig`：驗證輸入錯誤情境、既有目錄輸出等邊界條件。
  - `install_script.zig`：確認標記區塊截斷／重建與備份清單生成。
  - `file_modifier.zig`：純函式邏輯與 I/O 相關流程（可用臨時目錄）。
- 測試命名格式：`test "<module>: <behavior>"`。
- 執行管道集中於 `scripts/test_all.sh`；避免各自手寫指令造成差異。

## Scripts & Automation
- 腳本位於 `scripts/`；皆以 `#!/bin/sh`、`set -eu` 開頭，確保可攜性。
- `ci.sh`：CI 入口，依序執行格式化與測試。
- `fmt.sh`：本地格式化輔助。
- `test_all.sh`：統一觸發 `zig build test`。
- 新增腳本需附用途說明、使用範例，並避免接觸機密或執行破壞性操作。

## Commit & Pull Request Guidelines
- 小步提交、聚焦單一邏輯；建議採 Conventional Commits（`feat|fix|refactor|test|docs: ...`）。
- PR 說明需包含：
  - 變更摘要、動機與影響範圍。
  - 相容性評估與回滾策略。
  - 測試證據（指令與重點輸出）、相關 Issue 連結。
  - 涉及 I/O／壓縮流程時，記錄本地或 CI 驗證方法。
- 嚴禁提交機密或產物；遵守 `.gitignore`。

## Security & Configuration
- 嚴禁提交：`.env`, `secrets.*`, `*.pem`, `id_*`, `vendor/`, `node_modules/` 等敏感或產出檔案。
- 變更/刪除檔案需提供可重現測試與回滾說明。
- 本地需安裝 `libarchive`；若 CI 或其他環境缺依賴，請在 PR 中註記。

## Nightly 開發政策
- Zig 版本採 nightly/master；提交前以 `zig version` 確認。
- 安裝/切換建議使用 `zvm` 或官方 nightly；若語法/Std API 更新，先蒐集 Context7 或官方文件資訊後再提案。
- 相容性策略：不主動支援舊版 Zig；必要時以輕量包裝隔離差異。
- API 或語法變更流程：
  1. 提案：列出欲查詢關鍵詞、目標文件與預期影響。
  2. 最小改動修正並補齊測試，維持 TDD（先紅測再綠測）。
  3. 完成後更新相關文件與 TODO 狀態，並提供回滾方案。
