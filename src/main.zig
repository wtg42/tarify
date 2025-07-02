const std = @import("std");

pub fn main() !void {
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

    // 初始化一個 ArrayList 來儲存檔案名稱
    var list = std.ArrayList([]const u8).init(std.heap.page_allocator);
    defer list.deinit();

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
        try list.append(entry.name);
    }

    // 遍歷 list 並印出所有收集到的檔案名稱
    for (list.items) |item| {
        std.debug.print("file name in list: {s}\n", .{item});
    }
}
