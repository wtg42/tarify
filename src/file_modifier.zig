const std = @import("std");

pub const FileModifier = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) FileModifier {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: FileModifier) void {
        _ = self; // Mark as used
        // No specific deallocation needed for GeneralPurposeAllocator here,
        // as it’s usually managed at a higher level.
        // If we allocated large buffers within the struct, we would free them here.
    }

    /// Reads the entire content of a file into a dynamically allocated buffer.
    /// The caller is responsible for freeing the returned buffer using `self.allocator.free()`.
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
    pub fn write_file_content(self: FileModifier, file_path: []const u8, content: []const u8) !void {
        _ = self; // Mark as used
        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();

        try file.writeAll(content);
    }

    /// Searches for and deletes all occurrences of `text_to_delete` from `original_content`.
    /// Returns a new buffer with the modified content.
    /// The caller is responsible for freeing the returned buffer using `self.allocator.free()`.
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

    /// Inserts `text_to_insert` at the specified `line_number` (1-based) in `original_content`.
    /// Returns a new buffer with the modified content.
    /// The caller is responsible for freeing the returned buffer using `self.allocator.free()`.
    pub fn insert_text_at_line(self: FileModifier, original_content: []const u8, line_number: usize, text_to_insert: []const u8) ![]u8 {
        if (line_number == 0) {
            return error.InvalidLineNumber;
        }

        var list = std.ArrayList(u8).init(self.allocator);
        defer list.deinit();

        var fbs = std.io.fixedBufferStream(original_content);
        var line_stream = std.io.bufferedReader(fbs.reader());
        var line_reader = line_stream.reader();

        var current_line: usize = 1;
        while (true) {
            if (current_line == line_number) {
                try list.appendSlice(text_to_insert);
                if (text_to_insert.len > 0 and text_to_insert[text_to_insert.len - 1] != '\n') {
                    try list.append('\n'); // Ensure newline after inserted text
                }
            }

            var line_buffer: [1024]u8 = undefined; // Temporary buffer for reading lines
            const line = line_reader.readUntilDelimiterOrEof(&line_buffer, '\n') catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            };

            if (line.len > 0) {
                try list.appendSlice(line);
                if (line_reader.buffer.peek(1) catch null == '\n') { // Check if newline was consumed
                    _ = line_reader.readByte() catch {}; // Consume the newline
                    try list.append('\n');
                }
            } else if (line_reader.buffer.peek(1) catch null == '\n') { // Handle empty lines
                _ = line_reader.readByte() catch {};
                try list.appendByte('\n');
            }

            current_line += 1;
        }

        // If line_number is beyond the end of the file, append at the end
        if (line_number >= current_line) {
            try list.appendSlice(text_to_insert);
            if (text_to_insert.len > 0 and text_to_insert[text_to_insert.len - 1] != '\n') {
                try list.appendByte('\n');
            }
        }

        return list.toOwnedSlice();
    }

    /// Saves the `modified_content` to `original_file_path` or `new_file_path`.
    /// If `new_file_path` is null, it overwrites `original_file_path`.
    pub fn save_content(self: FileModifier, original_file_path: []const u8, new_file_path: ?[]const u8, modified_content: []const u8) !void {
        const target_path = if (new_file_path) |path| path else original_file_path;
        try self.write_file_content(target_path, modified_content);
    }
};

test "FileModifier basic operations" {
    const test_allocator = std.testing.allocator;
    var fm = FileModifier.init(test_allocator);
    defer fm.deinit();

    const test_file_path = "test_file.txt";
    const original_content = "Hello, world!\nThis is a test.\nAnother line.";

    // Test write_file_content
    try fm.write_file_content(test_file_path, original_content);
    defer std.fs.cwd().deleteFile(test_file_path) catch {}; // Clean up

    // Test read_file_content
    const read_content = try fm.read_file_content(test_file_path);
    defer test_allocator.free(read_content);
    try std.testing.expectEqualStrings(original_content, read_content);

    // Test delete_text
    const content_after_delete = try fm.delete_text(read_content, "world!");
    defer test_allocator.free(content_after_delete);
    try std.testing.expectEqualStrings("Hello, \nThis is a test.\nAnother line.", content_after_delete);

    const content_after_delete_all_a = try fm.delete_text(read_content, "a");
    defer test_allocator.free(content_after_delete_all_a);
    try std.testing.expectEqualStrings("Hello, world!\nThis is  test.\nAnother line.", content_after_delete_all_a);

    // Test insert_text_at_line
    const content_after_insert = try fm.insert_text_at_line(read_content, 2, "Inserted line.");
    defer test_allocator.free(content_after_insert);
    try std.testing.expectEqualStrings("Hello, world!\nInserted line.\nThis is a test.\nAnother line.", content_after_insert);

    const content_after_insert_at_end = try fm.insert_text_at_line(read_content, 4, "New line at end.");
    defer test_allocator.free(content_after_insert_at_end);
    try std.testing.expectEqualStrings("Hello, world!\nThis is a test.\nAnother line.\nNew line at end.\n", content_after_insert_at_end);

    const content_after_insert_at_empty_file = try fm.insert_text_at_line("", 1, "First line.");
    defer test_allocator.free(content_after_insert_at_empty_file);
    try std.testing.expectEqualStrings("First line.\n", content_after_insert_at_empty_file);

    // Test save_content (overwrite)
    const modified_content_for_save = "Modified content for save.";
    try fm.save_content(test_file_path, null, modified_content_for_save);
    const saved_content = try fm.read_file_content(test_file_path);
    defer test_allocator.free(saved_content);
    try std.testing.expectEqualStrings(modified_content_for_save, saved_content);

    // Test save_content (save as new file)
    const new_file_path = "new_test_file.txt";
    try fm.save_content(test_file_path, new_file_path, original_content);
    defer std.fs.cwd().deleteFile(new_file_path) catch {}; // Clean up
    const new_saved_content = try fm.read_file_content(new_file_path);
    defer test_allocator.free(new_saved_content);
    try std.testing.expectEqualStrings(original_content, new_saved_content);
}
