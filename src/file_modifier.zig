// file_modifier.zig
//
// 這個檔案定義了一個 `FileModifier` struct，它提供了一系列用於安全地修改本地檔案內容的功能。
// 這些功能包括讀取檔案、寫入檔案、搜尋並刪除指定文字、在指定行插入文字，以及儲存修改後的內容。
//
// 主要考量：
// - 記憶體安全：所有記憶體分配和釋放都透過傳入的 `std.mem.Allocator` 進行管理，確保資源的正確釋放。
// - 錯誤處理：所有可能失敗的操作都使用 Zig 的錯誤傳播機制 (`!`) 進行處理，確保錯誤能夠被呼叫者捕獲和處理。
// - 慣用 Zig 寫法：遵循 Zig 語言的慣例，例如使用 `defer` 確保資源釋放，以及明確的錯誤類型。

const std = @import("std");

pub const FileModifier = struct {
    // `allocator` 是一個記憶體分配器，用於管理 `FileModifier` 內部所有動態記憶體分配。
    // 這是 Zig 中處理記憶體安全的核心機制，確保所有分配的記憶體都能被追蹤和釋放。
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) FileModifier {
        // `init` 函數是 `FileModifier` struct 的建構子。
        // 它接收一個 `std.mem.Allocator` 實例，並將其儲存在 struct 的 `allocator` 欄位中。
        // 所有的動態記憶體操作都將使用這個分配器。
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: FileModifier) void {
        // `deinit` 函數是 `FileModifier` struct 的解構子。
        // 在 Zig 中，通常不需要為簡單的 struct 實現 `deinit`，
        // 因為它們不直接擁有動態分配的資源。
        // 然而，如果 `FileModifier` 內部有直接分配的緩衝區或其他資源，
        // 則需要在這裡使用 `self.allocator.free()` 進行釋放，以避免記憶體洩漏。
        // 目前，`_ = self;` 僅用於避免編譯器警告 `self` 未被使用。
        _ = self; // Mark as used
    }

    /// Reads the entire content of a file into a dynamically allocated buffer.
    /// The caller is responsible for freeing the returned buffer using `self.allocator.free()`。
    ///
    /// 原理：
    /// 1. 開啟檔案：使用 `std.fs.cwd().openFile` 開啟指定路徑的檔案，模式為唯讀。
    ///    `try` 關鍵字用於錯誤傳播，如果開啟失敗，函數會立即返回錯誤。
    /// 2. 延遲關閉：`defer file.close();` 確保無論函數如何退出（成功或失敗），檔案都會被關閉，防止資源洩漏。
    /// 3. 獲取檔案大小：`file.stat()` 獲取檔案的元數據，包括大小。`@intCast` 用於安全地將 `u64` 轉換為 `usize`。
    /// 4. 分配緩衝區：使用 `self.allocator.alloc(u8, buffer_size)` 分配一個足夠大的記憶體緩衝區來儲存檔案內容。
    /// 5. 錯誤延遲釋放：`errdefer self.allocator.free(buffer);` 是一個關鍵的記憶體安全機制。
    ///    它確保如果 `try` 表達式（例如 `file.readAll`）失敗，已分配的 `buffer` 會被自動釋放。
    ///    如果函數成功返回，`errdefer` 不會執行。
    /// 6. 讀取內容：`file.readAll(buffer)` 嘗試將整個檔案內容讀取到緩衝區中。
    /// 7. 完整性檢查：檢查實際讀取的位元組數是否與預期的檔案大小相符，如果不符，則返回 `error.IncompleteRead`。
    /// 8. 返回緩衝區：成功讀取後，返回包含檔案內容的緩衝區。呼叫者有責任在不再需要時釋放這個緩衝區。
    pub fn read_file_content(self: FileModifier, file_path: []const u8) ![]u8 {
        const file = try std.fs.cwd().openFile(file_path, .{ .mode = std.fs.File.OpenMode.read_only });
        defer file.close();

        const file_stat = try file.stat();
        const buffer_size: usize = @intCast(file_stat.size);
        const buffer = try self.allocator.alloc(u8, buffer_size);

        errdefer self.allocator.free(buffer); // Free on error

        const bytes_read = try file.readAll(buffer);
        if (bytes_read != buffer_size) {
            return error.IncompleteRead;
        }

        return buffer;
    }

    /// Writes the given content to a file.
    ///
    /// 原理：
    /// 1. 建立檔案：使用 `std.fs.cwd().createFile` 建立或截斷指定路徑的檔案。
    ///    如果檔案不存在，則建立；如果存在，則清空其內容。
    ///    `createFile` 預設以寫入模式開啟檔案，因此不需要額外的 `mode` 參數。
    /// 2. 延遲關閉：`defer file.close();` 確保無論函數如何退出，檔案都會被關閉。
    /// 3. 寫入內容：`file.writeAll(content)` 將提供的內容寫入檔案。
    pub fn write_file_content(self: FileModifier, file_path: []const u8, content: []const u8) !void {
        _ = self; // Mark as used
        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();

        try file.writeAll(content);
    }

    /// Searches for and deletes all occurrences of `text_to_delete` from `original_content`.
    /// Returns a new buffer with the modified content.
    /// The caller is responsible for freeing the returned buffer using `self.allocator.free()`。
    ///
    /// 原理：
    /// 1. 初始化 `ArrayList`：使用 `std.ArrayList(u8).init(self.allocator)` 建立一個可變長度的位元組列表。
    ///    這個列表將用於儲存刪除指定文字後的內容。
    /// 2. 延遲釋放：`defer list.deinit();` 確保 `ArrayList` 在函數退出時被正確釋放，避免記憶體洩漏。
    /// 3. 迭代搜尋：使用 `while` 迴圈和 `std.mem.indexOf` 在 `original_content` 中搜尋 `text_to_delete` 的所有出現。
    ///    `indexOf` 返回找到的索引或 `null`。
    /// 4. 拼接內容：
    ///    - 如果找到 `text_to_delete`：將 `text_to_delete` 之前的部分 (`original_content[current_pos .. current_pos + idx]`) 附加到 `list` 中。
    ///      然後更新 `current_pos` 跳過 `text_to_delete` 的長度，繼續搜尋。
    ///    - 如果未找到：將 `original_content` 的剩餘部分 (`original_content[current_pos..]`) 附加到 `list` 中，並結束迴圈。
    /// 5. 返回新切片：`list.toOwnedSlice()` 將 `ArrayList` 的內容轉換為一個新的切片並返回。
    ///    呼叫者有責任釋放這個新的切片。
    pub fn delete_text(self: FileModifier, original_content: []const u8, text_to_delete: []const u8) ![]u8 {
        var list = std.ArrayList(u8).init(self.allocator);
        defer list.deinit();

        var current_pos: usize = 0;
        while (current_pos < original_content.len) {
            const found_index = std.mem.indexOf(u8, original_content[current_pos..], text_to_delete);
            if (found_index) |idx| {
                try list.appendSlice(original_content[current_pos .. current_pos + idx]);
                current_pos += idx + text_to_delete.len;
            } else {
                try list.appendSlice(original_content[current_pos..]);
                current_pos = original_content.len;
            }
        }
        return list.toOwnedSlice();
    }

    /// Inserts `text_to_insert` at the specified `line_number` (1-based) in `original_content`.    /// Returns a new buffer with the modified content.    /// The caller is responsible for freeing the returned buffer using `self.allocator.free()`。    ///    /// 原理：    /// 1. 錯誤檢查：如果 `line_number` 為 0，則返回 `error.InvalidLineNumber`，因為行號是從 1 開始的。    /// 2. 初始化 `ArrayList`：用於儲存修改後的內容。    /// 3. 建立緩衝讀取器：    ///    - `std.io.fixedBufferStream(original_content)` 將原始內容包裝成一個固定緩衝區流。    ///    - `std.io.bufferedReader(fbs.reader())` 建立一個緩衝讀取器，從固定緩衝區流中讀取。    ///    - `line_reader` 是實際用於逐行讀取的讀取器。    /// 4. 逐行處理：    ///    - 迴圈遍歷 `original_content` 的每一行。    ///    - 如果當前行號 `current_line` 等於目標 `line_number`，則將 `text_to_insert` 插入到 `list` 中。    ///      如果插入的文字沒有以換行符結尾，則自動添加一個換行符，以確保行格式正確。    ///    - `line_reader.readUntilDelimiterOrEof` 讀取一行直到遇到換行符或檔案結束。    ///    - 處理讀取的行：將讀取的行附加到 `list` 中。如果該行後面有換行符（即使被 `readUntilDelimiterOrEof` 消耗），也將其附加到 `list` 中。    /// 5. 處理檔案末尾插入：如果 `line_number` 大於檔案的總行數，則在迴圈結束後將 `text_to_insert` 附加到 `list` 的末尾。    /// 6. 返回新切片：`list.toOwnedSlice()` 將 `ArrayList` 的內容轉換為一個新的切片並返回。    ///    呼叫者有責任釋放這個新的切片。    pub fn insert_text_at_line(self: FileModifier, original_content: []const u8, line_number: usize, text_to_insert: []const u8) ![]u8 {        if (line_number == 0) {            return error.InvalidLineNumber;        }        var list = std.ArrayList(u8).init(self.allocator);        defer list.deinit();        var fbs = std.io.fixedBufferStream(original_content);        var line_stream = std.io.bufferedReader(fbs.reader());        var line_reader = line_stream.reader();        var current_line: usize = 1;        while (true) {            if (current_line == line_number) {                try list.appendSlice(text_to_insert);                if (text_to_insert.len > 0 and text_to_insert[text_to_insert.len - 1] != '
') {                    try list.append('
'); // Ensure newline after inserted text                }            }            var line_buffer: [1024]u8 = undefined; // Temporary buffer for reading lines            const line = line_reader.readUntilDelimiterOrEof(&line_buffer, '
') catch |err| {                if (err == error.EndOfStream) break;                return err;            };            if (line.len > 0) {                try list.appendSlice(line);                if (line_reader.buffer.peek(1) catch null == '
') { // Check if newline was consumed                    _ = line_reader.readByte() catch {}; // Consume the newline                    try list.append('
');                }            } else if (line_reader.buffer.peek(1) catch null == '
') { // Handle empty lines                _ = line_reader.readByte() catch {};                try list.appendByte('
');            }            current_line += 1;        }        // If line_number is beyond the end of the file, append at the end        if (line_number >= current_line) {            try list.appendSlice(text_to_insert);            if (text_to_insert.len > 0 and text_to_insert[text_to_insert.len - 1] != '
') {                try list.appendByte('
');            }        }        return list.toOwnedSlice();    }

    /// Saves the `modified_content` to `original_file_path` or `new_file_path`.
    /// If `new_file_path` is null, it overwrites `original_file_path`。
    ///
    /// 原理：
    /// 1. 判斷目標路徑：如果 `new_file_path` 不為 `null`，則使用 `new_file_path` 作為儲存路徑；
    ///    否則，使用 `original_file_path`，這意味著將覆蓋原始檔案。
    /// 2. 寫入內容：呼叫 `self.write_file_content` 將 `modified_content` 寫入到確定的目標路徑。
    pub fn save_content(self: FileModifier, original_file_path: []const u8, new_file_path: ?[]const u8, modified_content: []const u8) !void {
        const target_path = if (new_file_path) |path| path else original_file_path;
        try self.write_file_content(target_path, modified_content);
    }
};

test "FileModifier basic operations" {
    // 測試區塊：FileModifier 基本操作
    // 這個測試區塊驗證了 FileModifier struct 的各個函數是否按預期工作。
    // 它會建立一個測試檔案，對其進行讀取、寫入、刪除文字和插入文字等操作，
    // 並驗證結果是否正確。

    // 獲取測試專用的記憶體分配器。這是 Zig 測試框架提供的一個安全分配器。
    const test_allocator = std.testing.allocator;
    // 初始化 FileModifier 實例，傳入測試分配器。
    var fm = FileModifier.init(test_allocator);
    // 使用 defer 確保在測試函數結束時，FileModifier 的 deinit 函數會被呼叫。
    defer fm.deinit();

    // 定義測試檔案的路徑和原始內容。
    const test_file_path = "test_file.txt";
    const original_content = "Hello, world!\nThis is a test.\nAnother line.";

    // 測試 write_file_content 函數：將原始內容寫入測試檔案。
    try fm.write_file_content(test_file_path, original_content);
    // 使用 defer 確保測試檔案在測試結束時被刪除，無論測試成功或失敗。
    defer std.fs.cwd().deleteFile(test_file_path) catch {}; // Clean up

    // 測試 read_file_content 函數：讀取測試檔案的內容。
    const read_content = try fm.read_file_content(test_file_path);
    // 釋放 read_content 佔用的記憶體。
    defer test_allocator.free(read_content);
    // 驗證讀取到的內容是否與原始內容相同。
    try std.testing.expectEqualStrings(original_content, read_content);

    // 測試 delete_text 函數：從內容中刪除 "world!"。
    const content_after_delete = try fm.delete_text(read_content, "world!");
    // 釋放 content_after_delete 佔用的記憶體。
    defer test_allocator.free(content_after_delete);
    // 驗證刪除後的內容是否正確。
    try std.testing.expectEqualStrings("Hello, \nThis is a test.\nAnother line.", content_after_delete);

    // 測試 delete_text 函數：從內容中刪除所有 "a"。
    const content_after_delete_all_a = try fm.delete_text(read_content, "a");
    // 釋放 content_after_delete_all_a 佔用的記憶體。
    defer test_allocator.free(content_after_delete_all_a);
    // 驗證刪除後的內容是否正確。
    try std.testing.expectEqualStrings("Hello, world!\nThis is  test.\nAnother line.", content_after_delete_all_a);

    // 測試 insert_text_at_line 函數：在第二行插入 "Inserted line."。
    const content_after_insert = try fm.insert_text_at_line(read_content, 2, "Inserted line.");
    // 釋放 content_after_insert 佔用的記憶體。
    defer test_allocator.free(content_after_insert);
    // 驗證插入後的內容是否正確。
    try std.testing.expectEqualStrings("Hello, world!\nInserted line.\nThis is a test.\nAnother line.", content_after_insert);

    // 測試 insert_text_at_line 函數：在檔案末尾插入 "New line at end."。
    const content_after_insert_at_end = try fm.insert_text_at_line(read_content, 4, "New line at end.");
    // 釋放 content_after_insert_at_end 佔用的記憶體。
    defer test_allocator.free(content_after_insert_at_end);
    // 驗證插入後的內容是否正確。
    try std.testing.expectEqualStrings("Hello, world!\nThis is a test.\nAnother line.\nNew line at end.\n", content_after_insert_at_end);

    // 測試 insert_text_at_line 函數：在空檔案中插入 "First line."。
    const content_after_insert_at_empty_file = try fm.insert_text_at_line("", 1, "First line.");
    // 釋放 content_after_insert_at_empty_file 佔用的記憶體。
    defer test_allocator.free(content_after_insert_at_empty_file);
    // 驗證插入後的內容是否正確。
    try std.testing.expectEqualStrings("First line.\n", content_after_insert_at_empty_file);

    // 測試 save_content 函數 (覆蓋模式)：將修改後的內容覆蓋寫入原始檔案。
    const modified_content_for_save = "Modified content for save.";
    try fm.save_content(test_file_path, null, modified_content_for_save);
    // 讀取被覆蓋後的檔案內容。
    const saved_content = try fm.read_file_content(test_file_path);
    // 釋放 saved_content 佔用的記憶體。
    defer test_allocator.free(saved_content);
    // 驗證覆蓋後的內容是否正確。
    try std.testing.expectEqualStrings(modified_content_for_save, saved_content);

    // 測試 save_content 函數 (另存新檔模式)：將原始內容另存為新檔案。
    const new_file_path = "new_test_file.txt";
    try fm.save_content(test_file_path, new_file_path, original_content);
    // 使用 defer 確保新檔案在測試結束時被刪除。
    defer std.fs.cwd().deleteFile(new_file_path) catch {}; // Clean up
    // 讀取新檔案的內容。
    const new_saved_content = try fm.read_file_content(new_file_path);
    // 釋放 new_saved_content 佔用的記憶體。
    defer test_allocator.free(new_saved_content);
    // 驗證新檔案的內容是否正確。
    try std.testing.expectEqualStrings(original_content, new_saved_content);
}
