const std = @import("std");

pub const Args = struct {
    dir: []const u8,
    out: []const u8,
};

/// Validate CLI argv and return normalized arguments.
/// TDD plan: initial stub only checks argc >= 3; tests will require
/// additional validation (e.g., reject when out is a directory).
pub fn validateArgs(
    allocator: std.mem.Allocator,
    argv: []const [:0]u8,
) !Args {
    _ = allocator;
    if (argv.len < 3) return error.InvalidArgs;
    // Reject when output is an existing directory
    const st = std.fs.cwd().statFile(argv[2]) catch |err| {
        if (err == error.FileNotFound) return .{ .dir = argv[1], .out = argv[2] };
        return err;
    };
    if (st.kind == .directory) return error.OutIsDirectory;
    return .{ .dir = argv[1], .out = argv[2] };
}
