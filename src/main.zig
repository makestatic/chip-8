const std = @import("std");
const CPU = @import("chip/chip.zig").Chip8;
const log = @import("utils/log.zig").log;
const process = std.process;
const os = std.os;

const c = @cImport({
    @cInclude("termios.h");
    @cInclude("unistd.h");
});

var FIRST_RUN = true;

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
    raw.c_cc[c.VTIME] = 0;

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
    var buf: [16]u8 = undefined;
    const n = c.read(c.STDIN_FILENO, &buf, buf.len);

    if (n > 0) {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const pressed = buf[i];

            // quit
            if (pressed == 'q') {
                disableRawMode();
                std.process.exit(0);
            }

            // update key states
            var j: usize = 0;
            while (j < 16) : (j += 1) {
                if (keymap[j] == pressed) {
                    system.keypad_pressed[j] = 1;
                    system.keypad_handled[j] = false;
                    // key is down
                    system.keypad_state[j] = true;
                }
            }
        }
    }
}

pub fn render(system: *CPU) !void {
    if (tty_file) |tty| {
        const so = tty.writer(&.{});
        const stdout = so.file;

        if (FIRST_RUN) {
            try stdout.writeAll("\x1b[2J\x1b[H");
            FIRST_RUN = false;
        } else {
            try stdout.writeAll("\x1b[H");
        }

        // display
        var y: usize = 0;
        while (y < 32) : (y += 1) {
            var x: usize = 0;
            while (x < 64) : (x += 1) {
                try stdout.writeAll(if (system.display[y * 64 + x] != 0) "█" else " ");
            }
            try stdout.writeAll("\n");
        }

        // debug pressed keys (max 1)
        try stdout.writeAll("\nKeys: ");
        var count: usize = 0;
        var i: usize = 0;
        while (i < 16 and count < 1) : (i += 1) {
            if (system.keypad_pressed[i] != 0) {
                log(.INFO, "{c} ", .{keymap[i]});
                count += 1;
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
