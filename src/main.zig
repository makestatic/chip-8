const std = @import("std");
const CPU = @import("chip/chip.zig").Chip8;
const log = @import("utils/log.zig").log;
const process = std.process;

const c = @cImport({
    @cInclude("termios.h");
    @cInclude("unistd.h");
});

var FIRST_RUN = true;
var OPCODES_PER_FRAME = 64;

// https://en.wikipedia.org/wiki/CHIP-8#Keyboard
const keymap: [16]u8 = [_]u8{
    '1', '2', '3', '4',
    'q', 'w', 'e', 'r',
    'a', 's', 'd', 'f',
    'z', 'x', 'c', 'v',
};

var prev_display: [64 * 32]u8 = [_]u8{0} ** (64 * 32);

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

pub fn disableRawMode() !void {
    if (tty_file) |tty| {
        defer tty.close();

        _ = c.tcsetattr(tty.handle, c.TCSAFLUSH, &orig_term);
        const so = tty.writer(&.{});
        const stdout = so.file;
        // show cursor
        try stdout.writeAll("\x1b[?25h");
        tty_file = null;
    }
}

pub fn handleKeys(system: *CPU) !void {
    // clear frame state
    var frame_state: [16]bool = [_]bool{false} ** 16;

    if (tty_file) |tty| {
        var buf: [32]u8 = undefined;
        const n = c.read(tty.handle, &buf, buf.len);

        if (n > 0) {
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const pressed = buf[i];

                if (pressed == 'q') {
                    try disableRawMode();
                    process.exit(0);
                }

                var j: usize = 0;
                while (j < 16) : (j += 1) {
                    if (keymap[j] == pressed) {
                        frame_state[j] = true;
                    }
                }
            }
        }

        // update CPU key states
        var j: usize = 0;
        while (j < 16) : (j += 1) {
            if (frame_state[j]) {
                if (!system.keypad_state[j]) {
                    system.keypad_pressed[j] = 1;
                    system.keypad_handled[j] = false;
                } else {
                    system.keypad_pressed[j] = 0;
                }
                system.keypad_state[j] = true;
            } else {
                system.keypad_state[j] = false;
                system.keypad_pressed[j] = 0;
            }
        }
    }
}

pub fn render(system: *CPU) !void {
    if (tty_file) |tty| {
        const so = tty.writer(&.{});
        const stdout = so.file;

        if (FIRST_RUN) {
            // clear screen and hide cursor
            try stdout.writeAll("\x1b[2J\x1b[?25l");
            FIRST_RUN = false;
        }

        var y: usize = 0;
        while (y < 32) : (y += 1) {
            var x: usize = 0;
            while (x < 64) : (x += 1) {
                const idx = y * 64 + x;
                const pixel = system.display[idx];
                if (pixel != prev_display[idx]) {
                    prev_display[idx] = pixel;

                    // Move cursor: row = y+1, col = x+1
                    var buf: [32]u8 = undefined;
                    const len = try std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ y + 1, x + 1 });
                    try stdout.writeAll(buf[0..len.len]);

                    if (pixel != 0) {
                        try stdout.writeAll("█");
                    } else {
                        try stdout.writeAll(" ");
                    }
                }
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

    if (stat.kind != .file or stat.size == 0 or stat.size >= 4096) {
        log(.ERROR, "Invalid ROM `{s}`", .{filename});
        return;
    }

    var cpu = CPU.init();
    cpu.load(filename, stat, allocator) catch {
        log(.ERROR, "Failed to load ROM `{s}`", .{filename});
        return;
    };

    try enableRawMode();

    // ~60Hz
    const tick_ns: u64 = 16_666_666;
    var last_tick = std.time.nanoTimestamp();

    while (true) {
        var i: usize = 0;
        while (i < OPCODES_PER_FRAME) : (i += 1) {
            cpu.cycle();
        }

        try handleKeys(&cpu);

        if (cpu.draw_flag) {
            try render(&cpu);
            cpu.draw_flag = false;
        }

        // Tick
        const now = std.time.nanoTimestamp();
        if (now - last_tick >= tick_ns) {
            if (cpu.delay_timer > 0) {
                cpu.delay_timer -= 1;
            }
            if (cpu.sound_timer > 0) {
                if (tty_file) |tty| {
                    const so = tty.writer(&.{});
                    const stdout = so.file;
                    // BEEP
                    // some terminals may not support this
                    // TODO: a better cross-platform impl
                    try stdout.writeAll("\x07");
                }
                cpu.sound_timer -= 1;
            }
            last_tick = now;
        }

        std.Thread.sleep(1_000_000); // 1ms
    }

    try disableRawMode();
}
