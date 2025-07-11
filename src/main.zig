/// MSE 專案打包 CLI app
/// TODO: std.debug.print() 改成 自己包裝的 std.log + write file
const std = @import("std");

// 在 build.zig 裡面設定 libarchive
const c = @cImport({
    @cInclude("archive.h");
    @cInclude("archive_entry.h");
    @cInclude("sys/stat.h");
});

const App = struct {
    allocator: std.mem.Allocator,
    argv: []const [:0]u8,
    list: std.ArrayList([]const u8),
    specify_dir: [:0]u8,
    output_file: [:0]u8,

    /// 初始化 App 結構。
    ///
    /// @param allocator - 用於初始化 ArrayList 和複製字串的記憶體分配器。
    /// @param argv - 命令列參數。
    /// @return - 一個新的 App 實例。
    pub fn init(allocator: std.mem.Allocator, argv: []const [:0]u8) App {
        return App{
            .allocator = allocator,
            .argv = argv,
            .list = std.ArrayList([]const u8).init(allocator),
            .specify_dir = argv[1],
            .output_file = argv[2],
        };
    }

    /// 解構並釋放 App 所使用的資源。
    ///
    /// 這會釋放儲存在列表中的所有字串，然後解構列表本身。
    /// 這是必須要去一樣一樣釋放的
    pub fn deinit(self: *App) void {
        // Deallocate all the strings we duplicated.
        for (self.list.items) |item| {
            self.allocator.free(item);
        }
        self.list.deinit();
    }

    /// 使用 libarchive 建立一個 tar 存檔。
    ///
    /// @param self - App 的實例。
    /// @param out_filename - 輸出的 tar 檔案名稱 (必須是 null-terminated string)。
    pub fn createTarArchive(self: *const App, out_filename: [:0]const u8) !void {
        const a = c.archive_write_new();
        if (a == null) {
            std.debug.print("archive_write_new failed\n", .{});
            return error.ArchiveCreationFailed;
        }
        defer _ = c.archive_write_free(a);

        // 設定存檔格式為 PAX Restricted (一個現代、可移植的 tar 變體)
        if (c.archive_write_set_format_pax_restricted(a) != c.ARCHIVE_OK) {
            std.debug.print("archive_write_set_format_pax_restricted failed: {s}\n", .{c.archive_error_string(a)});
            return error.ArchiveFormatFailed;
        }

        // 開啟檔案以進行寫入
        if (c.archive_write_open_filename(a, out_filename) != c.ARCHIVE_OK) {
            std.debug.print("archive_write_open_filename failed: {s}\n", .{c.archive_error_string(a)});
            return error.ArchiveOpenFailed;
        }
        defer _ = c.archive_write_close(a);

        var buffer: [8192]u8 = undefined;

        // 遍歷要加入存檔的檔案列表
        for (self.list.items) |path| {
            // libarchive 需要一個以 null 結尾的字串
            const file_path_z = try self.allocator.dupeZ(u8, path);
            // const file_path_z = try std.fmt.allocPrintZ(
            //     self.allocator,
            //     "./{s}",
            //     .{path},
            // );

            defer self.allocator.free(file_path_z);

            // 取得檔案的狀態 (大小、權限、時間等)
            // const z_file = try std.fs.openFileAbsolute(
            //     file_path_z,
            //     .{ .mode = .read_only },
            // );
            // defer z_file.close();

            // st = try z_file.stat();
            var st: c.struct_stat = undefined;
            if (c.stat(file_path_z, &st) != 0) {
                std.debug.print("stat failed for {s}\n", .{file_path_z});
                return error.StatFailed;
            }

            const entry = c.archive_entry_new();
            if (entry == null) {
                return error.ArchiveEntryFailed;
            }
            defer c.archive_entry_free(entry);

            // 設定存檔條目的路徑名稱
            c.archive_entry_set_pathname(entry, file_path_z);
            // 從 stat 結構複製元數據
            c.archive_entry_copy_stat(entry, &st);

            // 寫入此檔案的標頭
            if (c.archive_write_header(a, entry) != c.ARCHIVE_OK) {
                std.debug.print(
                    "archive_write_header for {s} failed: {s}\n",
                    .{ path, c.archive_error_string(a) },
                );
                return error.ArchiveHeaderFailed;
            }

            // 如果是檔案 (不是目錄)，則讀取其內容並寫入存檔
            if ((st.st_mode & c.S_IFMT) == c.S_IFREG) {
                var file = try std.fs.openFileAbsolute(
                    file_path_z,
                    .{ .mode = .read_only },
                );
                defer file.close();

                while (true) {
                    const bytes_read = try file.read(&buffer);
                    if (bytes_read == 0) break;

                    const written = c.archive_write_data(a, &buffer, bytes_read);
                    if (written < 0) {
                        std.debug.print(
                            "archive_write_data for {s} failed: {s}\n",
                            .{ path, c.archive_error_string(a) },
                        );

                        return error.ArchiveWriteFailed;
                    }
                }
            }

            // ✅ 即使非必要，建議保留，不然其實 close() 也會自動呼叫
            if (c.archive_write_finish_entry(a) != c.ARCHIVE_OK) {
                std.debug.print(
                    "archive_write_finish_entry failed: {s}\n",
                    .{c.archive_error_string(a)},
                );

                return error.ArchiveFinishEntryFailed;
            }
        }

        std.debug.print("Successfully created tar archive: '{s}'\n", .{out_filename});
    }

    /// 執行應用程式的主要邏輯。
    ///
    /// 此函式會：
    /// 1. 清理當前目錄中任何殘留的 .tgz 檔案。
    /// 2. 遍歷當前目錄中的所有檔案。
    /// 3. 忽略在 `ignore_files` 列表中的檔案。
    /// 4. 將所有其他檔案的名稱（作為新分配的字串）加入到內部列表中。
    /// 5. 印出最終收集到的檔案名稱列表。
    pub fn collectFilesRecursively(self: *App, scan_path: []const u8) !void {
        // Create a variable to hold the current scan path.
        // This is used to build full paths for nested files.
        const base_path: []const u8 = try self.allocator.dupe(u8, scan_path);
        defer self.allocator.free(base_path);

        // 清除可能殘留的 .tgz 檔案
        var dir_clean = try std.fs.openDirAbsolute(scan_path, .{
            .iterate = true,
            .no_follow = true,
            .access_sub_paths = true,
        });
        defer dir_clean.close();

        var it_clean = dir_clean.iterate();
        while (try it_clean.next()) |entry| {
            if (std.mem.endsWith(u8, entry.name, ".tgz")) {
                // try std.fs.cwd().deleteFile(entry.name);
                try dir_clean.deleteFile(entry.name);
                std.debug.print("remove {s}\n", .{entry.name});
            }
        }

        // 定義要忽略的檔案列表
        const ignore_files = [_][]const u8{"INSTALL.sh"};

        // 開啟當前工作目錄
        var dir = try std.fs.openDirAbsolute(scan_path, .{
            .access_sub_paths = true,
            .iterate = true,
            .no_follow = true,
        });
        defer dir.close();

        // 建立目錄迭代器並遍歷所有條目
        var it = dir.iterate();
        while (try it.next()) |entry| {
            std.debug.print("origin file name: {s}\n", .{entry.name});

            // 檢查檔案是否在忽略清單中
            var is_ignored = false;
            for (ignore_files) |ignore_file| {
                if (std.mem.eql(u8, entry.name, ignore_file)) {
                    is_ignored = true;
                    break;
                }
            }

            // 如果檔案被忽略，則跳過此檔案
            if (is_ignored) {
                continue;
            }

            // 如果檔案是目錄，必須遞回掃描內部
            // entry.name is just the name; you must prepend base_path to form the full path.
            if (entry.kind == .directory) {
                // 1. 忽略 '.' '..' 兩個目錄
                if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) {
                    continue;
                }
                std.debug.print("directory:{s}\n", .{entry.name});

                // 2. 建立正確的遞迴路徑 (例如 "src/test_dir")
                const new_path = try std.fs.path.join(
                    self.allocator,
                    &.{ scan_path, entry.name },
                );
                defer self.allocator.free(new_path);

                try self.collectFilesRecursively(new_path);

                // Continue to the next entry after the recursive call is done.
                continue;
            }

            // 遍歷 list 並印出所有收集到的檔案名稱 之後改為 log 紀錄
            // Combine base_path and file name.
            // const full_path_file_name = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{
            //     base_path,
            //     entry.name,
            // });

            // 遍歷 list 並印出所有收集到的檔案名稱
            // Combine base_path and file name.
            const full_path_file_name = try std.fs.path.join(
                self.allocator,
                &.{
                    base_path,
                    entry.name,
                },
            );
            defer self.allocator.free(full_path_file_name);

            // 最後把需要的處理的檔名加進去
            try self.list.append(try self.allocator.dupe(u8, full_path_file_name));
        }
    }
};

/// 程式進入點。
///
/// 負責設定記憶體分配器、處理命令列參數、初始化 App 結構，
/// 執行主要邏輯，並確保所有分配的資源都被正確釋放。
pub fn main() !void {
    // 先取得用戶的 argv
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // 取得用戶的 argv
    const argv = try std.process.argsAlloc(gpa.allocator());
    defer std.process.argsFree(gpa.allocator(), argv);

    // 檢查參數數量
    if (argv.len < 3) {
        std.debug.print("Usage: {s} <directory_to_archive> <output_file_path>\n", .{argv[0]});
        return;
    }

    // Validate argv[2].
    if (!try valiateOutFileName(argv[2])) {
        // valiateOutFileName returns false for an invalid path (e.g., a directory),
        // or if 'try' catches other filesystem errors.
        std.process.exit(3);
    }

    // debug message
    for (argv) |value| {
        std.debug.print("{s}\n", .{value});
    }

    var app = App.init(gpa.allocator(), argv);
    defer app.deinit();

    // Start setting App-related fields.
    for (argv, 0..) |value, i| {
        switch (i) {
            1 => app.specify_dir = value,
            2 => app.output_file = value,
            else => break,
        }
        std.debug.print("argv[{d}]: {s}\n", .{ i, value });
    }

    // 給使用者看的訊息 ++ 用法為串接字串
    std.io.getStdOut().writer().print(
        "🔧 Starting archive process...\n" ++
            "📂 Directory to archive: {s}\n" ++
            "📦 Output file path:     {s}\n",
        .{ argv[1], argv[2] },
    ) catch {
        std.process.exit(2);
    };

    // 開始收集 用戶指定路徑的檔案列表
    try app.collectFilesRecursively(app.specify_dir);

    for (app.list.items) |item| {
        std.debug.print("file name in list: {s}\n", .{item});
    }

    var env = try std.process.getEnvMap(app.allocator);
    defer env.deinit();

    try app.createTarArchive(argv[2]);
}

/// 驗證用戶提供的輸出路徑是否有效。
///
/// 此函式檢查 `output_file_name`。
/// - 如果路徑不存在，視為有效 (因為我們要建立新檔案)，回傳 `true`。
/// - 如果路徑存在且為一個目錄，視為無效，回傳 `false`。
/// - 如果路徑存在且為一個檔案，視為有效，回傳 `true`。
/// - 如果在檢查路徑狀態時發生 `stat` 相關錯誤 (除了 `FileNotFound` 之外)，會將錯誤向上傳播。
///
/// @param output_file_name - 要驗證的輸出檔案路徑。
/// @return - 如果路徑有效則為 `true`，如果路徑是個目錄則為 `false`，或是一個檔案系統錯誤。
fn valiateOutFileName(output_file_name: []const u8) !bool {
    const st = std.fs.cwd().statFile(output_file_name) catch |err| {
        // 如果檔案或路徑不存在，這是可接受的，因為我們將要建立它。
        if (err == error.FileNotFound) {
            return true;
        }
        // 對於任何其他類型的錯誤，我們無法繼續，所以將錯誤拋出去。
        std.log.err("無法驗證輸出路徑 '{s}': {any}", .{ output_file_name, err });
        return err;
    };

    // 如果路徑存在，檢查它是否為一個目錄。
    switch (st.kind) {
        // 如果是檔案或其他類型，我們接受它。
        // If it's a file or other type, we take it.
        .file => return true,
        else => return false,
    }
}
