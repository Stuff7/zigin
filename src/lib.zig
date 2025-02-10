const std = @import("std");
const utf8 = @import("utf8utils");
const dbg = @import("dbgutils");

const os = std.os.linux;

pub fn readln(comptime prompt: []const u8, buf: *std.ArrayList(u8)) !void {
    var pos = buf.items.len;

    const old = try setTermNonBlockingNonEcho(1);
    defer resetTerm(old) catch |err| {
        dbg.rtAssertFmt(false, "Could not reset terminal state: {}", err);
    };

    while (true) {
        try promptln(prompt, buf.items, pos);
        if (try Key.readToStringWithPosition(buf, &pos) == Key.Enter) {
            break;
        }
    }

    try dbg.stdout.print("\n", .{});
}

fn promptln(comptime prompt: []const u8, input: []const u8, cursor: usize) !void {
    try dbg.stdout.print("\x1b[2K\r{s}{s}\r", .{ prompt, input });
    const pos = cursor + try utf8.charLength(prompt);

    if (pos > 0) {
        try dbg.stdout.print("\x1b[{}C", .{pos});
    }
}

pub const Key = enum {
    NA,
    Char,
    Tab,
    Enter,
    Backspace,
    ArrowUp,
    ArrowDown,
    ArrowRight,
    ArrowLeft,
    CtrlBackspace,
    CtrlArrowRight,
    CtrlArrowLeft,

    fn readToStringWithPosition(buf: *std.ArrayList(u8), pos: *usize) !Key {
        const key, const ch = try Key.readFromStdin();

        switch (key) {
            Key.Char => {
                if (pos.* == buf.items.len) {
                    try buf.append(ch);
                } else {
                    try buf.insert(pos.*, ch);
                }
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
                var idx = pos.*;
                while (idx > 0 and utf8.isSpace(buf.items[idx - 1])) {
                    idx -= 1;
                }
                while (idx > 0 and !utf8.isSpace(buf.items[idx - 1])) {
                    idx -= 1;
                }
                buf.replaceRangeAssumeCapacity(idx, pos.* - idx, "");
                pos.* = idx;
            },
            Key.CtrlArrowLeft => {
                var idx = pos.*;
                while (idx > 0 and utf8.isSpace(buf.items[idx - 1])) {
                    idx -= 1;
                }
                while (idx > 0 and !utf8.isSpace(buf.items[idx - 1])) {
                    idx -= 1;
                }
                pos.* = idx;
            },
            Key.CtrlArrowRight => {
                var idx = pos.*;
                while (idx < buf.items.len and utf8.isSpace(buf.items[idx])) {
                    idx += 1;
                }
                while (idx < buf.items.len and !utf8.isSpace(buf.items[idx])) {
                    idx += 1;
                }
                pos.* = idx;
            },
            else => {},
        }

        return key;
    }

    pub fn readFromStdin() !struct { Key, u8 } {
        const ch = try getch();

        const k = switch (ch) {
            8, 23 => .CtrlBackspace,
            9 => .Tab,
            10 => .Enter,
            27 => try parseEscSeq(),
            127 => .Backspace,
            else => if (ch > 31) return .{ .Char, ch } else .NA,
        };

        return .{ k, ch };
    }
};

const EscapeSequence = struct { key: Key, seq: []const u8 };
fn parseEscSeq() !Key {
    const sequences = [_]EscapeSequence{
        .{ .key = .ArrowUp, .seq = "[A" },
        .{ .key = .ArrowDown, .seq = "[B" },
        .{ .key = .ArrowRight, .seq = "[C" },
        .{ .key = .ArrowLeft, .seq = "[D" },
        .{ .key = .CtrlArrowRight, .seq = "[1;5C" },
        .{ .key = .CtrlArrowLeft, .seq = "[1;5D" },
    };

    var ch: u8 = 0;
    var pos: usize = 0;

    while (pos < sequences.len + 1) {
        ch = try getch();
        for (sequences) |esc| {
            if (pos >= esc.seq.len) {
                continue;
            }

            if (esc.seq[pos] == ch and esc.seq.len - 1 == pos) {
                return esc.key;
            }
        }
        pos += 1;
    }

    return .NA;
}

pub fn setTermNonBlockingNonEcho(min_read: u8) !os.termios {
    var old: os.termios = undefined;

    if (os.tcgetattr(os.STDIN_FILENO, &old) < 0) {
        std.debug.print("errno: {}", .{os._errno()});
        return error.TcGetAttr;
    }

    var new = old;
    new.lflag.ICANON = false;
    new.lflag.ECHO = false;
    new.cc[@intFromEnum(os.V.MIN)] = min_read;
    new.cc[@intFromEnum(os.V.TIME)] = 0;

    if (os.tcsetattr(os.STDIN_FILENO, .NOW, &new) < 0) {
        std.debug.print("errno: {}", .{os._errno()});
        return error.TcSetAttrTCSANOW;
    }

    return old;
}

pub fn resetTerm(t: os.termios) !void {
    if (os.tcsetattr(os.STDIN_FILENO, .DRAIN, &t) < 0) {
        std.debug.print("errno: {}", .{os._errno()});
        return error.TcSetAttrTCSADRAIN;
    }
}

const stdin = std.io.getStdIn().reader();
pub fn getch() !u8 {
    var buf = [1]u8{0};
    const bytes_read = try stdin.read(&buf);
    if (bytes_read < 0) {
        std.debug.print("errno: {}", .{os._errno()});
        return error.GetchRead;
    }
    if (bytes_read == 0) {
        return error.GetchBlock;
    }

    return buf[0];
}
