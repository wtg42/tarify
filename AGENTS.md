# Repository Guidelines

## Project Structure & Module Organization
- `src/`：核心程式碼與內嵌測試
  - `main.zig`：CLI 進入點與打包流程（透過 libarchive）
  - `file_modifier.zig`：檔案讀寫與純函式工具
  - `root.zig`：示例與基本測試
- `build.zig`：建置腳本與目標/最佳化選項
- `third_party/libarchive/`：標頭搜尋路徑（需系統安裝 libarchive）
- 產物輸出於 `zig-out/`

## Build, Test, and Development Commands
- `zig build`：建置可執行檔至 `zig-out/`
- `zig build run -- <dir> <output>`：執行 CLI，壓縮 `<dir>` 並輸出 `<output>.tgz`
- `zig build test`：執行所有 `test` 區塊（建議透過 scripts/ 統一觸發，見下方）
- `zig fmt .`：套用官方格式化
- 需求：可連結 `libarchive` 與 `libc`

## Coding Style & Naming Conventions
- 使用 `zig fmt`；4 空白縮排（預設）
- 檔名 `snake_case`；函式/變數 `lowerCamelCase`
- 模組化；避免全域狀態；明確傳遞 `allocator` 並對稱釋放
- 錯誤以 Zig `error` 傳遞；必要時以 `std.log.*` 記錄，避免冗長輸出
- 公開 API 以註解說明參數/錯誤/所有權，修改時同步更新文件

## Testing Guidelines
- 使用 Zig 內建測試（檔內 `test "..." {}`）
- 優先覆蓋：
  - 純函式（如換行偵測、字串處理）
  - 檔案系統流程（以臨時目錄/檔案測試並清理）
- 命名：`test "<module>: <behavior>"`
- 執行：集中由 `scripts/` 內的 Makefile 目標或 `.sh` 腳本統一管理（例如 `make test` 或 `scripts/test_all.sh`），避免分散命令

## Scripts & Automation（集中管理）
- 位置：專案根目錄下 `scripts/`
- 原則：
  - 預設使用 POSIX `sh`（可攜性優先），避免 bash/zsh 專屬語法。
  - 所有本地/CI 測試、格式化、靜態檢查命令，皆以 `scripts/` 或 `Makefile` 封裝對外介面。
  - 腳本命名需具辨識度，例如：`test_all.sh`, `test_unit.sh`, `test_integration.sh`；對應 Make 目標：`make test`, `make test-unit`。
  - 腳本標頭：預設 `#!/bin/sh` 並加上 `set -eu`；若必須用 bash 特性，才改用 `#!/usr/bin/env bash` 並加上 `set -euo pipefail`，並在 README/CI 註明依賴。
  - 腳本內嚴禁觸碰機密與被忽略檔案，並避免破壞性操作（除非另附明確回滾）。
  - Zig 測試建議統一由腳本呼叫 `zig build test`，確保不同環境一致行為。

## Commit & Pull Request Guidelines
- 小步提交、單一邏輯；建議 Conventional Commits：`feat|fix|refactor|test|docs: ...`
- PR 需包含：
  - 變更摘要與動機、相容性/風險、回滾策略
  - 測試證據（指令與關鍵輸出）與相關 Issue 連結
  - 如涉及 I/O 或打包，說明在本機或 CI 的驗證方式
- 禁止提交機密與產物；遵守 `.gitignore`

## Security & Configuration Tips
- 請勿提交：`.env`, `secrets.*`, `*.pem`, `id_*`, `vendor/`, `node_modules/`
- 涉及檔案刪除/移動的改動，務必提供可重現測試與回滾說明
- 本地需安裝 `libarchive`；若 CI/環境缺依賴，請在 PR 描述中標註

## Nightly 開發政策與版本相容性
- Zig 版本：採用 nightly/master。最低版本以 CI 顯示為準（建議與維護者同步）。
- 安裝/切換：建議使用 `zvm` 或官方 nightly 下載；提交前以 `zig version` 確認為 nightly。
- 相容性策略：不主動維持舊版 Zig；必要時以輕量包裝函式隔離 API 差異。
- 語法/Std 變更處理流程：
  1) 以「搜尋網路與 Context7 文件」為優先來源，蒐集最新語意與 API 變更；
  2) 先提案：列出欲查詢關鍵詞、目標文件與預期影響；
  3) 最小改動修正並補齊/調整測試，保持 TDD（先紅測、再綠）。
