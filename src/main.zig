/// MSE 專案打包 CLI app
/// TODO: 包裝一個可以把 log 寫到特定 file 的 fn
/// TODO: 第一層的迴圈需要忽略掉所有檔案 除了 INSTALL.sh 以外
/// TODO: 在搬移 INSTALL.sh 檔案不在會爆炸 改用印出錯誤方式跳出
const std = @import("std");
const install_script = @import("install_script.zig");
const cli_validate = @import("cli_validate.zig");

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
    // 指定要打包的目的，同時也是打包完畢後存放的地方
    specify_dir: [:0]u8,
    // 打包指定的名稱 例如 project_6244_a1.tgz
    output_file: [:0]u8,

    pub const source_code_archive_name = "patch.tgz";

    /// 初始化 App 結構。
    ///
    /// @param allocator - 用於初始化 ArrayList 和複製字串的記憶體分配器。
    /// @param argv - 命令列參數。
    /// @return - 一個新的 App 實例。
    pub fn init(allocator: std.mem.Allocator, argv: []const [:0]u8) App {
        return App{
            .allocator = allocator,
            .argv = argv,
            // ArrayList no longer stores allocator; use zero-init and pass allocator per call
            .list = .{},
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
        self.list.deinit(self.allocator);
    }

    /// 使用 libarchive 建立一個 tgz 存檔。
    ///
    /// @param self - App 的實例。
    /// @param out_filename - 輸出的 tar 檔案名稱 (必須是 null-terminated string)。
    pub fn createTarArchive(self: *const App, out_filename: [:0]const u8) !void {
        const a = c.archive_write_new();
        if (a == null) {
            std.log.info("archive_write_new failed", .{});
            return error.ArchiveCreationFailed;
        }
        defer _ = c.archive_write_free(a);

        // Add a Gzip compression filter.
        if (c.archive_write_add_filter_gzip(a) != c.ARCHIVE_OK) {
            std.log.err("archive_write_add_filter_gzip failed: {s}", .{c.archive_error_string(a)});
            return error.ArchiveFilterFailed;
        }

        // 設定存檔格式為 PAX Restricted (一個現代、可移植的 tar 變體)
        if (c.archive_write_set_format_pax_restricted(a) != c.ARCHIVE_OK) {
            std.log.info("archive_write_set_format_pax_restricted failed: {s}", .{c.archive_error_string(a)});
            return error.ArchiveFormatFailed;
        }

        // 開啟檔案以進行寫入
        if (c.archive_write_open_filename(a, out_filename) != c.ARCHIVE_OK) {
            std.log.info("archive_write_open_filename failed: {s}", .{c.archive_error_string(a)});
            return error.ArchiveOpenFailed;
        }
        defer _ = c.archive_write_close(a);

        var buffer: [8192]u8 = undefined;

        // 遍歷要加入存檔的檔案列表
        for (self.list.items) |path| {
            // libarchive 需要一個以 null 結尾的字串
            const file_path_z = try self.allocator.dupeZ(u8, path);

            defer self.allocator.free(file_path_z);

            // 取得檔案的狀態 (大小、權限、時間等)
            var st: c.struct_stat = undefined;
            if (c.stat(file_path_z, &st) != 0) {
                std.log.info("stat failed for {s}", .{file_path_z});
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
                std.log.info(
                    "archive_write_header for {s} failed: {s}",
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
                        std.log.info(
                            "archive_write_data for {s} failed: {s}",
                            .{ path, c.archive_error_string(a) },
                        );

                        return error.ArchiveWriteFailed;
                    }
                }
            }

            // ✅ 即使非必要，建議保留，不然其實 close() 也會自動呼叫
            if (c.archive_write_finish_entry(a) != c.ARCHIVE_OK) {
                std.log.info(
                    "archive_write_finish_entry failed: {s}",
                    .{c.archive_error_string(a)},
                );

                return error.ArchiveFinishEntryFailed;
            }
        }

        std.log.info(
            "\x1b[34mSuccessfully created tar archive: '{s}'\x1b[0m",
            .{out_filename},
        );
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
                std.log.info("remove {s}", .{entry.name});
            }
        }

        // 定義要忽略的檔案列表
        const ignore_files = [_][]const u8{"INSTALL.sh"};

        // 開啟指定作目錄
        var dir = try std.fs.openDirAbsolute(scan_path, .{
            .access_sub_paths = true,
            .iterate = true,
            .no_follow = true,
        });
        defer dir.close();

        // 建立目錄迭代器並遍歷所有條目
        var it = dir.iterate();
        while (try it.next()) |entry| {
            std.log.info("origin file name: {s}", .{entry.name});

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
                std.log.info("directory:{s}", .{entry.name});

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
            try self.list.append(self.allocator, try self.allocator.dupe(u8, full_path_file_name));
        }
    }

    /// 輸出 source code 打包的檔名
    ///
    /// This function allocates a new buffer\
    /// that you must free by calling app.allocator.free(buffer).
    pub fn createSourceCodeFileNameAlloc(self: App) ![:0]const u8 {
        // 用戶輸入的檔案名稱 跟專案資料夾同一個位置
        const specify_dir_str = try self.allocator.dupeZ(u8, self.specify_dir);
        defer self.allocator.free(specify_dir_str);
        const tgz_file_name = try std.fs.path.joinZ(
            self.allocator,
            &.{ specify_dir_str, source_code_archive_name },
        );

        std.log.info(
            "\x1b[34mOutput file name: {s}\x1b[0m\n",
            .{tgz_file_name},
        );

        return tgz_file_name;
    }

    /// TODO: 修改 INSTALL.sh 備份部分 改為用戶要修改的清單
    pub fn modifyInstallScript(self: App) !void {
        const install_script_filename = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}",
            .{ self.specify_dir, "INSTALL.sh" },
        );
        defer self.allocator.free(install_script_filename);

        std.debug.print("\x1b[31m111111::{s}\x1b[0m\n", .{install_script_filename});

        const script_file = std.fs.openFileAbsolute(
            install_script_filename,
            .{ .mode = .read_only },
        ) catch |err| {
            std.log.err("\x1b[31mFailed to open file: {} \x1b[0m", .{err});

            // 無法修改就不用再做下去了
            std.process.exit(6);
        };
        defer script_file.close();

        const file_stat = try script_file.stat();

        std.debug.print("3333333=>{}", .{file_stat});

        const content = try script_file.readToEndAlloc(
            self.allocator,
            file_stat.size,
        );
        defer self.allocator.free(content);

        // 取出換行符號
        const newline = detectNewline(content);

        // 把文章內容利用換行符號一行一行讀取
        var it = std.mem.splitSequence(u8, content, newline);
        while (it.next()) |value| {
            std.debug.print("value--->{s}\n", .{value});
            // TODO: 比對 web update 範圍之後的部分全部都刪除
            // TODO: 額外實作寫入樣板把需要備份的檔案放進樣板後寫入 INSTALL.sh
            // TODO: 備份 specify_dir 內的資料夾跟檔案(使用 --ignore-failed-read 忽略不存在的檔案)
        }

        // Just temporary
        std.process.exit(77);
    }
};

/// 用來檢查檔案內容的換行符號屬於哪一類
fn detectNewline(data: []const u8) []const u8 {
    if (std.mem.indexOf(u8, data, "\r\n") != null) return "\r\n";
    if (std.mem.indexOf(u8, data, "\n") != null) return "\n";
    if (std.mem.indexOf(u8, data, "\r") != null) return "\r";
    return "\n";
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
        std.log.info("Usage: {s} <directory_to_archive> <output_file_path>", .{argv[0]});
        return;
    }

    // Validate argv[2].
    // valiateOutFileName returns false for an invalid path (e.g., a directory),
    // or if 'try' catches other filesystem errors.
    if (!try valiateOutFileName(argv[2])) {
        std.process.exit(2);
    }

    // debug message
    for (argv) |value| {
        std.log.info("{s}", .{value});
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
        std.log.info("argv[{d}]: {s}", .{ i, value });
    }

    // 給使用者看的訊息 ++ 用法為串接字串 (舊寫法 deprecated)
    // 用來跟下方新寫法做比較
    // std.io.getStdOut().writer().print(
    //     "🔧 Starting archive process...\n" ++
    //         "📂 Directory to archive: {s}\n" ++
    //         "📦 Output file path:     {s}\n",
    //     .{ argv[1], argv[2] },
    // ) catch {
    //     std.process.exit(2);
    // };

    // 給使用者看的訊息 ++ 用法為串接字串 (0.15 新寫法 Writergate)
    // 需要先自定義 buffer 的 stdout writer
    // 最後使用 interface.print() 來進行格式化輸出
    // 非格式化輸出可以直接使用 std.fs.File.stdout().writeAll();
    var buffer: [256]u8 = undefined;
    const stdout = std.fs.File.stdout().writer(&buffer);
    var writer_interface = stdout.interface;
    writer_interface.print(
        "🔧 Starting archive process...\n" ++
            "📂 Directory to archive: {s}\n" ++
            "📦 Output file path:     {s}\n",
        .{ argv[1], argv[2] },
    ) catch {
        std.process.exit(3);
    };

    // 開始收集 用戶指定路徑的檔案列表
    try app.collectFilesRecursively(app.specify_dir);

    for (app.list.items) |item| {
        std.log.info("file name in list: {s}", .{item});
    }

    // patch.tgz 跟專案資料夾同一個位置 之後會跟 INSTALL.sh 一起打包
    const tgz_file_name = try app.createSourceCodeFileNameAlloc();
    defer app.allocator.free(tgz_file_name);

    // source code archive
    try app.createTarArchive(tgz_file_name);

    var files = std.fs.openFileAbsoluteZ(tgz_file_name, .{
        .mode = .read_only,
    }) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.panic("unexpected error: {}\n", .{err});
        }
        return err;
    };
    defer files.close();

    const output_file_dir = try std.fs.path.join(
        app.allocator,
        &.{ app.specify_dir, app.output_file },
    );
    defer app.allocator.free(output_file_dir);

    std.log.info("🛠️\x1b[34m建立資料打包所需的檔案 {s}\x1b[0m", .{output_file_dir});

    // 預先刪除等等會用到的路徑
    std.fs.deleteTreeAbsolute(output_file_dir) catch |err| {
        switch (err) {
            // 處理我們預期且可以從中恢復的特定錯誤
            error.NotDir => {
                // 這表示它可能是一個檔案，嘗試刪除檔案
                std.fs.deleteFileAbsolute(output_file_dir) catch |file_err| {
                    // 如果刪除檔案也失敗，記錄下來
                    std.log.err("💀\x1b[31m嘗試將 '{s}' 作為檔案刪除失敗: {any}\x1b[0m", .{ output_file_dir, file_err });
                    return;
                };
            },
            // 對於一個我們預期可能發生的非致命錯誤，可以選擇忽略
            error.FileNotFound => {
                // 目標路徑本來就不存在，這很好，我們不需要做任何事。
                std.log.info("'{s}' 本來就不存在，無需刪除。", .{output_file_dir});
            },
            else => {
                // 對於所有其他非預期的錯誤，最好是記錄下來，讓開發者知道
                std.log.err("💀\x1b[31m刪除 '{s}' 時發生非預期錯誤: {any}\x1b[0m", .{ output_file_dir, err });
                return;
            },
        }
    };

    // TODO: 修改 INSTALL.sh 內容
    try app.modifyInstallScript();

    // patch.tgz 成功後可以開始建立 給用戶的資料夾來打包
    std.fs.cwd().makeDir(output_file_dir) catch |err| {
        std.log.err(
            "\x1b[31m{s}創建失敗: {}\x1b[0m",
            .{ output_file_dir, err },
        );

        return;
    };

    // 新增 patch.tgz destination 路徑
    const new_sub_path_source_code = try std.fs.path.join(
        app.allocator,
        &.{ output_file_dir, App.source_code_archive_name },
    );
    defer app.allocator.free(new_sub_path_source_code);

    const old_sub_path_source_code = try std.fs.path.join(
        app.allocator,
        &.{ app.specify_dir, App.source_code_archive_name },
    );
    defer app.allocator.free(old_sub_path_source_code);

    // 新增 INSTALL.sh destination 路徑
    const new_sub_path_script = try std.fs.path.join(
        app.allocator,
        &.{ output_file_dir, "INSTALL.sh" },
    );
    defer app.allocator.free(new_sub_path_script);

    const old_sub_path_script = try std.fs.path.join(
        app.allocator,
        &.{ app.specify_dir, "INSTALL.sh" },
    );
    defer app.allocator.free(old_sub_path_script);

    // 嘗試移動 patch.tgz, INSTALL.sh 到打包資料夾
    std.fs.cwd().rename(
        old_sub_path_source_code,
        new_sub_path_source_code,
    ) catch |err| {
        std.log.err("\x1b[31mFailed to rename patch.tgz: {}\x1b[0m", .{err});
        std.process.exit(4);
    };

    std.fs.cwd().rename(
        old_sub_path_script,
        new_sub_path_script,
    ) catch |err| {
        std.log.err("\x1b[31mFailed to rename INSTALL.sh: {}\x1b[0m", .{err});
        std.process.exit(5);
    };

    // 在一次打包新創的這個目錄
    const final_output_file = try std.fmt.allocPrint(
        app.allocator,
        "{s}{s}",
        .{ output_file_dir, ".tgz" },
    );
    defer app.allocator.free(final_output_file);

    // 再做一次 dupeZ 改成 C-style null-terminated string
    const final_output_file_z = try app.allocator.dupeZ(
        u8,
        final_output_file,
    );
    defer app.allocator.free(final_output_file_z);

    std.log.info(
        "\x1b[34mHere's the file we're outputting {s}\x1b[0m",
        .{final_output_file_z},
    );

    // 最後輸出
    try app.createTarArchive(final_output_file_z);
}

test "main: detectNewline variants" {
    // Use local GPA for precise allocation control
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // CRLF preferred when present
    try std.testing.expect(std.mem.eql(u8, detectNewline("a\r\nb"), "\r\n"));
    // LF
    try std.testing.expect(std.mem.eql(u8, detectNewline("a\nb"), "\n"));
    // CR
    try std.testing.expect(std.mem.eql(u8, detectNewline("a\rb"), "\r"));
    // Empty defaults to \n
    try std.testing.expect(std.mem.eql(u8, detectNewline(""), "\n"));
}

test "main: valiateOutFileName for non-existent, file, and dir" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Create isolated temp directory
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Absolute path of temp dir
    const root_abs = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root_abs);

    // Non-existent path -> true
    const missing = try std.fs.path.join(alloc, &.{ root_abs, "missing.file" });
    defer alloc.free(missing);
    try std.testing.expect(try valiateOutFileName(missing));

    // Create a regular file -> true
    {
        var f = try tmp.dir.createFile("afile.txt", .{});
        defer f.close();
    }
    const afile = try std.fs.path.join(alloc, &.{ root_abs, "afile.txt" });
    defer alloc.free(afile);
    try std.testing.expect(try valiateOutFileName(afile));

    // Create a subdirectory -> false
    try tmp.dir.makeDir("adir");
    const adir = try std.fs.path.join(alloc, &.{ root_abs, "adir" });
    defer alloc.free(adir);
    try std.testing.expect(!(try valiateOutFileName(adir)));
}

test "main: collectFilesRecursively ignores INSTALL.sh and removes .tgz" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Temp directory layout:
    // root/
    //   INSTALL.sh      (should be ignored)
    //   old.tgz         (should be deleted)
    //   a.txt           (should be collected)
    //   nested/inner.txt(should be collected)
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_abs = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root_abs);

    // Create files
    // INSTALL.sh
    {
        var f = try tmp.dir.createFile("INSTALL.sh", .{});
        defer f.close();
        try f.writeAll("echo hi\n");
    }
    // old.tgz
    {
        var f = try tmp.dir.createFile("old.tgz", .{});
        defer f.close();
        try f.writeAll("tgz");
    }
    // a.txt
    {
        var f = try tmp.dir.createFile("a.txt", .{});
        defer f.close();
        try f.writeAll("A");
    }
    // nested/inner.txt
    try tmp.dir.makeDir("nested");
    {
        var nf = try tmp.dir.createFile("nested/inner.txt", .{});
        defer nf.close();
        try nf.writeAll("I");
    }

    // Prepare App instance
    const argv0 = try alloc.dupeZ(u8, "tarify");
    defer alloc.free(argv0);
    const arg_dir = try alloc.dupeZ(u8, root_abs);
    defer alloc.free(arg_dir);
    const arg_out = try alloc.dupeZ(u8, "out");
    defer alloc.free(arg_out);
    const argv: []const [:0]u8 = &.{ argv0, arg_dir, arg_out };

    var app = App.init(alloc, argv);
    defer app.deinit();

    // Run collection on the absolute temp root
    try app.collectFilesRecursively(root_abs);

    // old.tgz should be removed
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile("old.tgz"));

    // Build expected absolute paths
    const p_a = try std.fs.path.join(alloc, &.{ root_abs, "a.txt" });
    defer alloc.free(p_a);
    const p_inner = try std.fs.path.join(alloc, &.{ root_abs, "nested", "inner.txt" });
    defer alloc.free(p_inner);

    // Helper to check membership
    var has_a = false;
    var has_inner = false;
    var has_install = false;
    for (app.list.items) |it| {
        if (std.mem.eql(u8, it, p_a)) has_a = true;
        if (std.mem.eql(u8, it, p_inner)) has_inner = true;
        if (std.mem.endsWith(u8, it, "INSTALL.sh")) has_install = true;
    }
    try std.testing.expect(has_a);
    try std.testing.expect(has_inner);
    try std.testing.expect(!has_install);
}

test "install: modifyInstallScriptContent injects backup list and truncates" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const nl = "\n";
    const original = "#!/bin/sh" ++ nl ++
        "echo before" ++ nl ++
        "# WEB UPDATE START" ++ nl ++
        "TO_BE_REPLACED" ++ nl ++
        "echo after (should be gone)" ++ nl;

    const opts = install_script.ModifyOptions{
        .backup_list = &.{ "conf/app.yaml", "bin/start.sh", "var/data" },
        .newline = nl,
    };

    const output = try install_script.modifyInstallScriptContent(alloc, original, opts);
    defer alloc.free(output);

    // Expectations (will fail with stub):
    // - generated content should contain each backup path
    // - previous payload token should be removed
    try std.testing.expect(std.mem.indexOf(u8, output, "conf/app.yaml") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "bin/start.sh") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "var/data") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "TO_BE_REPLACED") == null);
}

test "cli: validateArgs rejects directory as output path" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_abs = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_abs);

    const argv0 = try alloc.dupeZ(u8, "tarify");
    defer alloc.free(argv0);
    const arg_dir = try alloc.dupeZ(u8, dir_abs);
    defer alloc.free(arg_dir);
    const arg_out = try alloc.dupeZ(u8, dir_abs); // pass a directory intentionally
    defer alloc.free(arg_out);
    const argv: []const [:0]u8 = &.{ argv0, arg_dir, arg_out };

    // Expect a dedicated error when output is a directory
    try std.testing.expectError(error.OutIsDirectory, cli_validate.validateArgs(alloc, argv));
}
