const std = @import("std");
const log = @import("../utils/log.zig").log;

// Handled instructions:

const MAX_TRYING = 4;

pub const Chip8 = struct {
    registers: [16]u8,
    stack: [16]u16,
    I: u16,
    pc: u16,
    op: u16,
    sp: u8,
    memory: [4096]u8,
    display: [64 * 32]u8,
    keypad: [16]u8,
    keypad_pressed: [16]u8, // edge-triggered key presses
    keypad_handled: [16]bool, // cpu already read it
    keypad_state: [16]bool, // key is pressed
    delay_timer: u8,
    sound_timer: u8,
    draw_flag: bool,
    rng: std.Random.DefaultPrng,
    halted: bool,
    // detect infinite loops
    trying: u8,

    const Self = @This();

    pub fn init() Chip8 {
        log(.INFO, "Initializing Chip8", .{});
        // chop 64bs off
        const seed: u64 = @intCast(std.time.nanoTimestamp() & 0xFFFFFFFFFFFFFFFF);
        return Chip8{
            .registers = [_]u8{0x00} ** 16,
            .stack = [_]u16{0x00} ** 16,
            .I = 0x00,
            .op = 0x00,
            .pc = 0x200,
            .sp = 0x00,
            .memory = [_]u8{0x00} ** 4096,
            .display = [_]u8{0x00} ** (64 * 32),
            .keypad = [_]u8{0x00} ** 16,
            .keypad_pressed = [_]u8{0x00} ** 16,
            .keypad_handled = [_]bool{false} ** 16,
            .keypad_state = [_]bool{false} ** 16,
            .delay_timer = 0,
            .sound_timer = 0,
            .draw_flag = true,
            .rng = std.Random.DefaultPrng.init(seed),
            .halted = false,
            .trying = 0,
        };
    }

    /// load FONTSET and ROM > memory
    pub fn load(self: *Self, filename: []const u8, stat: std.fs.File.Stat, allocator: std.mem.Allocator) !void {
        var inputFile = try std.fs.cwd().openFile(filename, .{});
        defer inputFile.close();
        log(.INFO, "Loading ROM `{s}`", .{filename});
        log(.INFO, "ROM size: {d}", .{stat.size});
        const reader = try inputFile.readToEndAlloc(allocator, stat.size);
        defer allocator.free(reader);
        self.loadFontSetInMemory();
        var i: usize = 0;
        while (i < stat.size) : (i += 1) {
            self.memory[i + 0x200] = reader[i];
        }
    }

    fn loadFontSetInMemory(self: *Self) void {
        const fontset = [80]u8{
            0xF0, 0x90, 0x90, 0x90, 0xF0, // 0
            0x20, 0x60, 0x20, 0x20, 0x70, // 1
            0xF0, 0x10, 0xF0, 0x80, 0xF0, // 2
            0xF0, 0x10, 0xF0, 0x10, 0xF0, // 3
            0x90, 0x90, 0xF0, 0x10, 0x10, // 4
            0xF0, 0x80, 0xF0, 0x10, 0xF0, // 5
            0xF0, 0x80, 0xF0, 0x90, 0xF0, // 6
            0xF0, 0x10, 0x20, 0x40, 0x40, // 7
            0xF0, 0x90, 0xF0, 0x90, 0xF0, // 8
            0xF0, 0x90, 0xF0, 0x10, 0xF0, // 9
            0xF0, 0x90, 0xF0, 0x90, 0x90, // A
            0xE0, 0x90, 0xE0, 0x90, 0xE0, // B
            0xF0, 0x80, 0x80, 0x80, 0xF0, // C
            0xE0, 0x90, 0x90, 0x90, 0xE0, // D
            0xF0, 0x80, 0xF0, 0x80, 0xF0, // E
            0xF0, 0x80, 0xF0, 0x80, 0x80, // F
        };

        log(.INFO, "Loading fontset into memory", .{});
        for (fontset, 0..) |value, i| {
            self.memory[0x50 + i] = value;
        }
        log(.INFO, "Fontset loaded successfully", .{});
    }

    fn getRandomByte0to255(self: *Self) u8 {
        return self.rng.random().int(u8);
    }

    /// increment program counter
    /// if program counter overflows: > 0xFFF, reset to 0x200
    fn incrementPC(self: *Chip8) void {
        if (self.pc + 2 >= 0xFFF) {
            log(.ERROR, "Program counter overflow (call: incrementPC): {x}, resetting..", .{self.pc});
            if (self.trying >= MAX_TRYING) {
                self.halted = true;
                return;
            }
            self.trying += 1;
            self.pc = 0x200;
        } else {
            self.pc += 2;
        }
    }

    fn skipNextInstruction(self: *Self) void {
        if (self.pc + 4 >= 0xFFF) {
            log(.ERROR, "Program counter overflow (call: skipNextInstruction): {x}, try last safe instruction..", .{self.pc});
            if (self.trying >= MAX_TRYING) {
                self.halted = true;
                return;
            }
            self.trying += 1;
            self.pc = 0xFFE; // last valid instruction
        } else {
            self.pc += 4;
        }
    }

    fn jumpToAddress(self: *Self, address: u16) void {
        if (address >= 0xFFF) {
            log(.ERROR, "Address out of bounds: {x}", .{address});
            // halt
            self.halted = true;
            return;
        }
        self.pc = address;
    }

    pub fn cycle(self: *Self) void {
        if (self.halted) {
            log(.INFO, "CPU Halted...... EXITING.", .{});
            std.process.exit(0);
        }
        // safty check
        if (self.pc + 1 >= 0x1000) { // = 4096
            log(.ERROR, "PC overflow (call: cycle): {x}, exiting..;", .{self.pc});
            self.halted = true;
            // std.process.exit(1);
            return;
        }

        self.op = (@as(u16, self.memory[self.pc]) << 8) | self.memory[self.pc + 1];
        self.execute(self.op);
    }

    fn execute(self: *Self, op: u16) void {
        const x: usize = @intCast((op & 0x0F00) >> 8);
        const y: usize = @intCast((op & 0x00F0) >> 4);
        const n: u8 = @truncate(op & 0x000F);
        const nn: u8 = @truncate(op & 0x00FF);
        const nnn: u16 = op & 0x0FFF;

        switch (op & 0xF000) {
            0x0000 => switch (op) {
                0x00E0 => { // CLS
                    for (&self.display) |*px| px.* = 0;
                    self.draw_flag = true;
                    self.incrementPC();
                },
                0x00EE => { // RET
                    if (self.sp == 0) {
                        self.halted = true;
                        return;
                    }

                    self.sp -= 1;
                    self.pc = self.stack[self.sp];
                    self.incrementPC();
                },
                else => self.incrementPC(), // SYS (ignored)
            },
            0x1000 => self.jumpToAddress(nnn), // JP addr
            0x2000 => { // CALL addr
                if (self.sp >= 16) {
                    self.halted = true;
                    return;
                }

                self.stack[self.sp] = self.pc;
                self.sp += 1;
                self.jumpToAddress(nnn);
            },
            0x3000 => { // SE Vx byte
                if (self.registers[x] == nn) self.skipNextInstruction();
                self.incrementPC();
            },
            0x4000 => { // SNE Vx byte
                if (self.registers[x] != nn) self.skipNextInstruction();
                self.incrementPC();
            },
            0x5000 => { // SE Vx Vy
                if (self.registers[x] == self.registers[y]) self.skipNextInstruction();
                self.incrementPC();
            },
            0x6000 => { // LD Vx byte
                self.registers[x] = nn;
                self.incrementPC();
            },
            0x7000 => { // ADD Vx byte
                @setRuntimeSafety(false);
                self.registers[x] +%= nn;
                self.incrementPC();
            },
            0x8000 => {
                switch (n) {
                    0x0 => self.registers[x] = self.registers[y], // LD
                    0x1 => self.registers[x] |= self.registers[y], // OR
                    0x2 => self.registers[x] &= self.registers[y], // AND
                    0x3 => self.registers[x] ^= self.registers[y], // XOR
                    0x4 => { // ADD
                        const sum: u16 = @as(u16, self.registers[x]) + @as(u16, self.registers[y]);
                        self.registers[0xF] = if (sum > 0xFF) 1 else 0;
                        self.registers[x] = @truncate(sum);
                    },
                    0x5 => { // SUB
                        self.registers[0xF] = if (self.registers[x] > self.registers[y]) 1 else 0;
                        self.registers[x] -%= self.registers[y];
                    },
                    0x6 => { // SHR
                        self.registers[0xF] = self.registers[x] & 0x01;
                        self.registers[x] >>= 1;
                    },
                    0x7 => { // SUBN
                        self.registers[0xF] = if (self.registers[y] > self.registers[x]) 1 else 0;
                        self.registers[x] = self.registers[y] -% self.registers[x];
                    },
                    0xE => { // SHL
                        self.registers[0xF] = (self.registers[x] >> 7) & 1;
                        self.registers[x] <<= 1;
                    },
                    else => {},
                }
                self.incrementPC();
            },
            0x9000 => { // SNE Vx Vy
                if (self.registers[x] != self.registers[y]) self.skipNextInstruction();
                self.incrementPC();
            },
            0xA000 => { // LD I addr
                self.I = nnn;
                self.incrementPC();
            },
            0xB000 => self.jumpToAddress(nnn + self.registers[0]), // JP V0, addr
            0xC000 => { // RND Vx
                const r = self.getRandomByte0to255();
                self.registers[x] = r & nn;
                self.incrementPC();
            },
            0xD000 => { // DRW Vx Vy N
                const regX: usize = @intCast(self.registers[x]);
                const regY: usize = @intCast(self.registers[y]);
                self.registers[0xF] = 0;

                var row: usize = 0;
                while (row < n) : (row += 1) {
                    const spriteByte = self.memory[self.I + row];
                    var col: u8 = 0;
                    while (col < 8) : (col += 1) {
                        const mask: u8 = @as(u8, 0x80) >> @intCast(col);
                        if ((spriteByte & mask) != 0) {
                            // draw pixel
                            const px = (regX + col) % 64;
                            const py = (regY + row) % 32;
                            const idx = py * 64 + px;
                            if (self.display[idx] == 1) self.registers[0xF] = 1;
                            self.display[idx] ^= 1;
                        }
                    }
                }

                self.draw_flag = true;
                self.incrementPC();
            },
            0xE000 => switch (op & 0x00FF) {
                0x9E => { // SKP Vx
                    if (self.keypad_state[self.registers[x]]) {
                        self.skipNextInstruction();
                    }
                    self.incrementPC();
                },
                0xA1 => { // SKNP Vx
                    if (!self.keypad_state[self.registers[x]]) {
                        self.skipNextInstruction();
                    }
                    self.incrementPC();
                },
                else => self.incrementPC(),
            },
            0xF000 => switch (op & 0x00FF) {
                0x07 => { // LD Vx DT
                    self.registers[x] = self.delay_timer;
                    self.incrementPC();
                },
                0x0A => { // LD Vx, K
                    var i: usize = 0;
                    while (i < 16) : (i += 1) {
                        if (self.keypad_pressed[i] != 0 and !self.keypad_handled[i]) {
                            self.registers[x] = @intCast(i);
                            self.keypad_handled[i] = true;
                            self.incrementPC();
                            break;
                        }
                    }
                },
                0x15 => { // LD DT Vx
                    self.delay_timer = self.registers[x];
                    self.incrementPC();
                },
                0x18 => { // LD ST Vx
                    self.sound_timer = self.registers[x];
                    self.incrementPC();
                },
                0x1E => { // ADD I Vx
                    const sum: u16 = self.I + @as(u16, self.registers[x]);
                    self.I = sum;
                    self.incrementPC();
                },
                0x29 => { // LD F Vx  (I = font sprite for digit in Vx)
                    const digit: u8 = self.registers[x] & 0x0F;
                    self.I = 0x50 + @as(u16, digit) * 5;
                    self.incrementPC();
                },
                0x33 => { // LD B Vx  (BCD of Vx -> memory[I..I+2])
                    const val: u8 = self.registers[x];
                    const hundreds: u8 = val / 100;
                    const tens: u8 = (val % 100) / 10;
                    const ones: u8 = val % 10;

                    if (self.I + 2 < self.memory.len) {
                        self.memory[self.I] = hundreds;
                        self.memory[self.I + 1] = tens;
                        self.memory[self.I + 2] = ones;
                    }
                    self.incrementPC();
                },
                0x55 => { // LD [I] V0..Vx  (store)
                    var ireg: u16 = self.I;
                    var r: usize = 0;
                    while (r <= x and ireg < self.memory.len) : ({
                        ireg += 1;
                        r += 1;
                    }) {
                        self.memory[ireg] = self.registers[r];
                    }
                    self.incrementPC();
                },
                0x65 => { // LD V0..Vx [I]  (load)
                    var ireg: u16 = self.I;
                    var r: usize = 0;
                    while (r <= x and ireg < self.memory.len) : ({
                        ireg += 1;
                        r += 1;
                    }) {
                        self.registers[r] = self.memory[ireg];
                    }
                    self.incrementPC();
                },
                else => {
                    self.incrementPC();
                },
            },
            else => self.incrementPC(),
        }
    }
};
