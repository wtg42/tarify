const std = @import("std");

// 在 build.zig 裡面設定 libarchive
const c = @cImport({
    @cInclude("archive.h");
    @cInclude("archive_entry.h");
});

const App = struct {
    allocator: std.mem.Allocator,
    argv: []const [:0]u8,
    list: std.ArrayList([]const u8),
    specify_dir: [:0]u8,

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
            .specify_dir = undefined,
        };
    }

    /// 解構並釋放 App 所使用的資源。
    ///
    /// 這會釋放儲存在列表中的所有字串，然後解構列表本身。
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
            const path_z = try self.allocator.dupeZ(u8, path);
            defer self.allocator.free(path_z);

            // 取得檔案的狀態 (大小、權限、時間等)
            var st: std.fs.File.Stat = undefined;
            // st = try std.fs.cwd().statFile(path_z);
            const path_z_dir = try std.fs.openDirAbsolute(path_z, .{
                .access_sub_paths = true,
                .iterate = true,
                .no_follow = true,
            });
            defer path_z_dir.close();

            st = try path_z_dir.statFile(path_z);

            const entry = c.archive_entry_new();
            if (entry == null) {
                return error.ArchiveEntryFailed;
            }
            defer c.archive_entry_free(entry);

            // 設定存檔條目的路徑名稱
            c.archive_entry_set_pathname(entry, path_z);
            // 從 stat 結構複製元數據
            c.archive_entry_copy_stat(entry, &st);

            // 寫入此檔案的標頭
            if (c.archive_write_header(a, entry) != c.ARCHIVE_OK) {
                std.debug.print("archive_write_header for {s} failed: {s}\n", .{ path, c.archive_error_string(a) });
                return error.ArchiveHeaderFailed;
            }

            // 如果是檔案 (不是目錄)，則讀取其內容並寫入存檔
            if (st.kind == .File) {
                // var file = try std.fs.cwd().openFile(path_z, .{});
                var file = try std.fs.openDirAbsolute(path_z, .{
                    .access_sub_paths = true,
                    .iterate = true,
                    .no_follow = true,
                });
                defer file.close();

                while (try file.read(&buffer)) |bytes_read| {
                    if (bytes_read > 0) {
                        const written = c.archive_write_data(a, &buffer, bytes_read);
                        if (written < 0) {
                            std.debug.print("archive_write_data for {s} failed: {s}\n", .{ path, c.archive_error_string(a) });
                            return error.ArchiveWriteFailed;
                        }
                    }
                }
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
        // Create a variable that specifies current directory path, including subdirectories.
        // Use to build the full_path_file_name.
        // [註解] 這裡的 dupe 不是必要的，scan_path 在此函式作用域內已經是有效的，可以省去一次記憶體分配。
        const base_path: []const u8 = try self.allocator.dupe(u8, scan_path);
        @breakpoint();

        // 清除可能殘留的 .tgz 檔案
        // var dir_clean = try std.fs.cwd().openDir(scan_path, .{ .iterate = true });
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
        // var dir = try std.fs.cwd().openDir(scan_path, .{ .iterate = true });
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
            // entry.name 就是只有 name 你必須自己傳入 base_path 來組合路徑
            if (entry.kind == .directory) {
                // 1. 忽略 '.' '..' 兩個目錄
                if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) {
                    continue;
                }
                std.debug.print("directory:{s}\n", .{entry.name});
                dumpEntry(entry);

                // 2. 建立正確的遞迴路徑 (例如 "src/test_dir")
                const new_path = try std.fs.path.join(
                    self.allocator,
                    &.{ scan_path, entry.name },
                );
                defer self.allocator.free(new_path);

                try self.collectFilesRecursively(new_path);

                // Jump to next loop when self.run() is done.
                continue;
            }

            // 遍歷 list 並印出所有收集到的檔案名稱
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

            // [註解] 邏輯問題：不論是檔案還是目錄，這裡都會被加入列表。這會導致目錄本身和目錄內的檔案都被重複加入。
            try self.list.append(try self.allocator.dupe(u8, full_path_file_name));
        }
    }

    /// Set up the working directory
    ///
    /// Don't use cwd() to handle your files -- it's dangerous.
    fn setTargetWorkingDirectory(self: *App, path: [:0]u8) void {
        self.specify_dir = path;
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

    var app = App.init(gpa.allocator(), argv);
    defer app.deinit();

    for (argv, 0..) |value, i| {
        if (i == 1) {
            // Make sure App.init() has already been called.
            app.setTargetWorkingDirectory(value);
        }
        std.debug.print("argv[{d}]: {s}\n", .{ i, value });
    }

    // [註解] 風險：如果命令列沒有提供路徑參數，app.specify_dir 會是 undefined，這裡會直接導致程式崩潰。應在使用前增加參數數量檢查。
    try app.collectFilesRecursively(app.specify_dir);

    for (app.list.items) |item| {
        std.debug.print("file name in list: {s}\n", .{item});
    }

    // try app.createTarArchive("tarify.tgz");
}

fn dumpEntry(entry: std.fs.Dir.Entry) void {
    std.debug.print("Entry:\n", .{});
    std.debug.print("  name: {s}\n", .{entry.name});
    std.debug.print("  kind: {s}\n", .{@tagName(entry.kind)});
}
