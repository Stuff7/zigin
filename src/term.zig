const std = @import("std");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("termios.h");
    @cInclude("unistd.h");
});

pub const stdout = std.io.getStdOut().writer();

pub fn readln(prompt: str, buf: *std.ArrayList(u8)) !void {
    var pos = buf.items.len;

    while (true) {
        try promptln(prompt, buf.items, pos);
        if (try readch(buf, &pos) == Key.Enter) {
            break;
        }
    }

    try stdout.print("\n", .{});
}

fn promptln(prompt: str, input: str, cursor: usize) !void {
    try stdout.print("{s}\r{s}{s}\r", .{ CLEAR, prompt, input });
    const pos = cursor + prompt.len;

    if (pos > 0) {
        try stdout.print("\x1b[{}C", .{pos});
    }
}

fn readch(buf: *std.ArrayList(u8), pos: *usize) !Key {
    var ch: u8 = 0;
    const key = try readkey(&ch);

    switch (key) {
        Key.Byte => {
            try buf.insert(pos.*, ch);
            pos.* += 1;
        },
        Key.Backspace => {
            if (pos.* > 0) {
                pos.* -= 1;
                _ = buf.orderedRemove(pos.*);
            }
        },
        Key.ArrowLeft => {
            pos.* -|= 1;
        },
        Key.ArrowRight => {
            if (pos.* < buf.items.len) {
                pos.* += 1;
            }
        },
        Key.CtrlBackspace => {
            const idx = std.mem.lastIndexOf(u8, buf.items[0..pos.*], " ") orelse 0;
            try buf.replaceRange(idx, pos.* - idx, "");
            pos.* = idx;
        },
        Key.CtrlArrowLeft => {
            pos.* = std.mem.lastIndexOf(u8, buf.items[0..pos.*], " ") orelse 0;
        },
        Key.CtrlArrowRight => {
            while (pos.* < buf.items.len) {
                pos.* += 1;

                const b: ?u8 = if (pos.* < buf.items.len)
                    buf.items[pos.*]
                else
                    null;

                if (b != null and b == ' ') {
                    break;
                }
            }
        },
        else => {},
    }

    return key;
}

const STDIN_FILENO = std.posix.STDIN_FILENO;
var old: c.struct_termios = undefined;

const ENTER: u8 = '\n';
const BACKSPACE: u8 = 127;
const ESC: u8 = 27;
const CLEAR = "\x1b[2K";

pub const Key = enum {
    NA,
    Byte,
    Enter,
    Backspace,
    ArrowUp,
    ArrowDown,
    ArrowRight,
    ArrowLeft,
    CtrlBackspace,
    CtrlArrowRight,
    CtrlArrowLeft,
};

pub const str = []const u8;

const EscapeSequence = struct { key: Key, seq: str };

const ESC_SEQ_LEN: usize = 6;
const ESC_SEQ_LIST = [ESC_SEQ_LEN]EscapeSequence{
    .{ .key = Key.ArrowUp, .seq = "[A" },
    .{ .key = Key.ArrowDown, .seq = "[B" },
    .{ .key = Key.ArrowRight, .seq = "[C" },
    .{ .key = Key.ArrowLeft, .seq = "[D" },
    .{ .key = Key.CtrlArrowRight, .seq = "[1;5C" },
    .{ .key = Key.CtrlArrowLeft, .seq = "[1;5D" },
};

fn parse_esc_seq() !Key {
    var ch: u8 = 0;
    var pos: usize = 0;

    while (pos < ESC_SEQ_LEN + 1) {
        ch = try getch(1);
        for (ESC_SEQ_LIST) |esc| {
            if (pos >= esc.seq.len) {
                continue;
            }

            if (esc.seq[pos] == ch and esc.seq.len - 1 == pos) {
                return esc.key;
            }
        }
        pos += 1;
    }

    return Key.NA;
}

pub fn readkey(ret: *u8) !Key {
    ret.* = try getch(1);
    return switch (ret.*) {
        8, 23 => Key.CtrlBackspace,
        10 => Key.Enter,
        27 => try parse_esc_seq(),
        127 => Key.Backspace,
        else => Key.Byte,
    };
}

pub fn getch(blocking: u8) !u8 {
    var buf: u8 = 0;

    if (c.tcgetattr(STDIN_FILENO, &old) < 0) {
        std.debug.print("errno: {}", .{std.c._errno()});
        return error.tcgetattr;
    }

    old.c_lflag &= ~@as(c_uint, c.ICANON);
    old.c_lflag &= ~@as(c_uint, c.ECHO);
    old.c_cc[c.VMIN] = blocking;
    old.c_cc[c.VTIME] = 0;

    if (c.tcsetattr(STDIN_FILENO, c.TCSANOW, &old) < 0) {
        std.debug.print("errno: {}", .{std.c._errno()});
        return error.tcsetattrTCSANOW;
    }

    const bytes_read = c.read(STDIN_FILENO, &buf, 1);

    if (bytes_read < 0) {
        std.debug.print("errno: {}", .{std.c._errno()});
        return error.read;
    }

    if (bytes_read == 0) {
        return error.block;
    }

    old.c_lflag |= c.ICANON;
    old.c_lflag |= c.ECHO;

    if (c.tcsetattr(STDIN_FILENO, c.TCSADRAIN, &old) < 0) {
        std.debug.print("errno: {}", .{std.c._errno()});
        return error.tcsetattrTCSADRAIN;
    }

    return buf;
}
