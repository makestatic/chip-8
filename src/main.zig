const std = @import("std");
const CPU = @import("chip/chip.zig").Chip8;
const log = @import("utils/log.zig").log;
const process = std.process;
const os = std.os;

const c = @cImport({
    @cInclude("termios.h");
    @cInclude("unistd.h");
});

const keymap: [16]u8 = [_]u8{
    '1', '2', '3', '4',
    'q', 'w', 'e', 'r',
    'a', 's', 'd', 'f',
    'z', 'x', 'c', 'v',
};

var tty_file: ?std.fs.File = null;
var orig_term: c.termios = undefined;

pub fn enableRawMode() !void {
    const tty = try std.fs.openFileAbsolute("/dev/tty", .{ .mode = .read_write });
    tty_file = tty;

    if (c.tcgetattr(tty.handle, &orig_term) != 0) {
        return error.TermiosFailed;
    }

    var raw = orig_term;
    raw.c_lflag &= ~(@as(c_uint, c.ICANON) | @as(c_uint, c.ECHO));
    raw.c_cc[c.VMIN] = 0;
    raw.c_cc[c.VTIME] = 1;

    if (c.tcsetattr(tty.handle, c.TCSAFLUSH, &raw) != 0) {
        return error.TermiosFailed;
    }
}

pub fn disableRawMode() void {
    if (tty_file) |tty| {
        _ = c.tcsetattr(tty.handle, c.TCSAFLUSH, &orig_term);
        tty.close();
        tty_file = null;
    }
}

pub fn handleKeys(system: *CPU) void {
    // Clear keypad each frame
    for (&system.keypad) |*k| k.* = 0;

    var buf: [1]u8 = undefined;
    while (true) {
        const n = c.read(c.STDIN_FILENO, &buf, 1);
        if (n <= 0) break;

        const pressed = buf[0];
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            if (keymap[i] == pressed) {
                system.keypad[i] = 1;
            }
        }

        if (pressed == 'q') {
            disableRawMode();
            std.process.exit(0);
        }
    }
}

pub fn render(system: *CPU) !void {
    if (tty_file) |tty| {
        const so = tty.writer(&.{});
        const stdout = so.file;
        try stdout.writeAll("\x1b[H"); // reset cursor

        var y: usize = 0;
        while (y < 32) : (y += 1) {
            var x: usize = 0;
            while (x < 64) : (x += 1) {
                if (system.display[y * 64 + x] == 1) {
                    try stdout.writeAll("█");
                } else {
                    try stdout.writeAll(" ");
                }
            }
            try stdout.writeAll("\n");
        }

        // Debug keypad state
        try stdout.writeAll("\nKeys: ");
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            if (system.keypad[i] == 1) {
                log(.INFO, "[{d}:{c}] ", .{ i, keymap[i] });
            }
        }
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var arg_it = try process.argsWithAllocator(allocator);
    _ = arg_it.skip();

    const filename = arg_it.next() orelse {
        log(.ERROR, "No ROM specified\n\n\tUsage: chip8 <rom file>\n", .{});
        return;
    };

    const stat: std.fs.File.Stat = std.fs.cwd().statFile(filename) catch |err| {
        switch (err) {
            error.FileNotFound => {
                log(.ERROR, "ROM `{s}` not found", .{filename});
                return;
            },
            else => {
                log(.ERROR, "Failed to open ROM `{s}`", .{filename});
                return;
            },
        }
    };

    if (stat.kind != .file) {
        log(.ERROR, "ROM `{s}` is not a file", .{filename});
        return;
    }

    if (stat.size >= 4096) {
        log(.ERROR, "ROM `{s}` is too large", .{filename});
        return;
    }

    if (stat.size == 0) {
        log(.ERROR, "ROM `{s}` is empty", .{filename});
        return;
    }

    var cpu = CPU.init();
    cpu.load(filename, stat, allocator) catch {
        log(.ERROR, "Failed to load ROM `{s}`", .{filename});
        return;
    };

    try enableRawMode();
    defer disableRawMode();

    while (true) {
        cpu.cycle();
        handleKeys(&cpu);
        if (cpu.draw_flag) {
            try render(&cpu);
            cpu.draw_flag = false;
        }

        // 60hz
        std.Thread.sleep(16_666_666);
    }
}
