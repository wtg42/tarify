const std = @import("std");

const App = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayList([]const u8),

    /// 初始化 App 結構。
    ///
    /// @param allocator - 用於初始化 ArrayList 和複製字串的記憶體分配器。
    /// @return - 一個新的 App 實例。
    pub fn init(allocator: std.mem.Allocator) App {
        return App{
            .allocator = allocator,
            .list = std.ArrayList([]const u8).init(allocator),
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

    /// 執行應用程式的主要邏輯。
    ///
    /// 此函式會：
    /// 1. 清理當前目錄中任何殘留的 .tgz 檔案。
    /// 2. 遍歷當前目錄中的所有檔案。
    /// 3. 忽略在 `ignore_files` 列表中的檔案。
    /// 4. 將所有其他檔案的名稱（作為新分配的字串）加入到內部列表中。
    /// 5. 印出最終收集到的檔案名稱列表。
    pub fn run(self: *App) !void {
        // 處理用戶的 argv

        // 清除可能殘留的 .tgz 檔案
        var dir_clean = try std.fs.cwd().openDir(".", .{ .iterate = true });
        defer dir_clean.close();
        var it_clean = dir_clean.iterate();
        while (try it_clean.next()) |entry| {
            if (std.mem.endsWith(u8, entry.name, ".tgz")) {
                try std.fs.cwd().deleteFile(entry.name);
                std.debug.print("remove {s}\n", .{entry.name});
            }
        }

        // 定義要忽略的檔案列表
        const ignore_files = [_][]const u8{"INSTALL.sh"};

        // 開啟當前工作目錄
        var dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
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

            // 將未被忽略的檔案名稱加入到 list 中
            // We must duplicate the string, as `entry.name` is a slice of a buffer that will be reused.
            try self.list.append(try self.allocator.dupe(u8, entry.name));
        }

        // 遍歷 list 並印出所有收集到的檔案名稱
        for (self.list.items) |item| {
            std.debug.print("file name in list: {s}\n", .{item});
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

    const argv = try std.process.argsAlloc(gpa.allocator());
    defer std.process.argsFree(gpa.allocator(), argv);

    for (argv, 0..) |value, i| {
        std.debug.print("argv[{d}]: {s}\n", .{ i, value });
    }

    var app = App.init(gpa.allocator());
    defer app.deinit();

    try app.run();
}