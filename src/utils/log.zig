const std = @import("std");

pub const Level = enum { INFO, ERROR };

fn prefixForLevel(level: Level) []const u8 {
    return switch (level) {
        .INFO => "[INFO]: ",
        .ERROR => "[ERROR]: ",
    };
}

pub fn log(comptime level: Level, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    // format into buffer
    fbs.writer().print("{s}", .{prefixForLevel(level)}) catch return;
    fbs.writer().print(fmt ++ "\n", args) catch return;

    // write raw to stderr fd (2)
    _ = std.posix.write(2, fbs.getWritten()) catch return;
}
