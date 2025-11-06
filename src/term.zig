const std = @import("std");
const zut = @import("zut");
const os = std.os.linux;
const utf8 = zut.utf8;
const log = std.log;

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

pub const stdin = std.fs.File.stdin();

var stdout_buf: [256]u8 = undefined;
var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
pub const stdout = &stdout_writer.interface;

pub const Key = enum {
    na,
    char,
    tab,
    enter,
    backspace,
    arrow_up,
    arrow_down,
    arrow_right,
    arrow_left,
    ctrl_backspace,
    ctrl_arrow_right,
    ctrl_arrow_left,

    /// Reads a single utf-8 character of user input, allowing basic editing operations with a cursor.
    ///
    /// # Blocking
    ///
    /// This function blocks until a key event is detected and returns the corresponding `Key` enum
    /// representing the user input. The function also updates the provided buffer and cursor
    /// position based on the input.
    pub fn readToStringWithPosition(allocator: Allocator, buf: *ArrayList(u8), pos: *usize, cursor_pos: *usize) !Key {
        const key, const ch = try Key.readFromStdin();

        switch (key) {
            Key.char => {
                const charlen = try std.unicode.utf8ByteSequenceLength(ch);
                var slice = [1]u8{ch} ** 4;
                for (1..charlen) |i| {
                    _, slice[i] = try Key.readFromStdin();
                }

                if (pos.* == buf.items.len) {
                    try buf.appendSlice(allocator, slice[0..charlen]);
                } else {
                    try buf.insertSlice(allocator, pos.*, slice[0..charlen]);
                }

                pos.* += charlen;
                cursor_pos.* += try charWidthFromSlice(slice[0..charlen]);
            },
            Key.backspace => {
                if (moveBack(buf.items, pos.*)) |charlen| {
                    pos.* -= charlen;
                    cursor_pos.* -= try charWidthFromSlice(buf.items[pos.* .. pos.* + charlen]);
                    if (charlen == 1) {
                        _ = buf.orderedRemove(pos.*);
                    } else {
                        buf.replaceRangeAssumeCapacity(pos.*, charlen, "");
                    }
                }
            },
            Key.arrow_left => {
                if (moveBack(buf.items, pos.*)) |charlen| {
                    pos.* -= charlen;
                    cursor_pos.* -= try charWidthFromSlice(buf.items[pos.* .. pos.* + charlen]);
                }
            },
            Key.arrow_right => {
                if (pos.* < buf.items.len) {
                    var i: usize = pos.*;
                    const charlen = ret: while (i < buf.items.len) : (i += 1) {
                        if (std.unicode.utf8ByteSequenceLength(buf.items[i]) catch null) |c| {
                            break :ret c;
                        }
                    } else {
                        break :ret 1;
                    };
                    pos.* += charlen;
                    cursor_pos.* += try charWidthFromSlice(buf.items[pos.* - charlen .. pos.*]);
                }
            },
            Key.ctrl_backspace => {
                var idx = pos.*;

                while (idx > 0 and utf8.isSpace(buf.items[idx - 1])) {
                    idx -= 1;
                }

                while (idx > 0 and !utf8.isSpace(buf.items[idx - 1])) {
                    idx -= 1;
                }

                const charlen = try visualStringLength(buf.items[idx..pos.*]);
                buf.replaceRangeAssumeCapacity(idx, pos.* - idx, "");
                pos.* = idx;
                cursor_pos.* -= charlen;
            },
            Key.ctrl_arrow_left => {
                var idx = pos.*;

                while (idx > 0 and utf8.isSpace(buf.items[idx - 1])) {
                    idx -= 1;
                }

                while (idx > 0 and !utf8.isSpace(buf.items[idx - 1])) {
                    idx -= 1;
                }

                const charlen = try visualStringLength(buf.items[idx..pos.*]);
                pos.* = idx;
                cursor_pos.* -= charlen;
            },
            Key.ctrl_arrow_right => {
                var idx = pos.*;

                while (idx < buf.items.len and utf8.isSpace(buf.items[idx])) {
                    idx += 1;
                }

                while (idx < buf.items.len and !utf8.isSpace(buf.items[idx])) {
                    idx += 1;
                }

                const charlen = try visualStringLength(buf.items[pos.*..idx]);
                pos.* = idx;
                cursor_pos.* += charlen;
            },
            else => {},
        }

        return key;
    }

    pub fn fromEscapeSequence() !Key {
        const sequences = [_]struct { key: Key, seq: []const u8 }{
            .{ .key = .arrow_up, .seq = "[A" },
            .{ .key = .arrow_down, .seq = "[B" },
            .{ .key = .arrow_right, .seq = "[C" },
            .{ .key = .arrow_left, .seq = "[D" },
            .{ .key = .ctrl_arrow_right, .seq = "[1;5C" },
            .{ .key = .ctrl_arrow_left, .seq = "[1;5D" },
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

        return .na;
    }

    pub fn readFromStdin() !struct { Key, u8 } {
        const ch = try getch();

        const k = switch (ch) {
            8, 23 => .ctrl_backspace,
            9 => .tab,
            10 => .enter,
            27 => try Key.fromEscapeSequence(),
            127 => .backspace,
            else => if (ch > 31) return .{ .char, ch } else .na,
        };

        return .{ k, ch };
    }
};

pub fn promptln(comptime prompt: []const u8, input: []const u8, cursor: usize) !void {
    try stdout.print("\x1b[2K\r{s}{s}\r", .{ prompt, input });
    const pos = cursor + try utf8.charLength(prompt);

    if (pos > 0) {
        try stdout.print("\x1b[{}C", .{pos});
    }

    try stdout.flush();
}

pub fn setTermNonBlockingNonEcho(min_read: u8) !os.termios {
    var old: os.termios = undefined;

    if (os.tcgetattr(os.STDIN_FILENO, &old) < 0) {
        log.err("errno: {}", .{os._errno()});
        return error.TcGetAttr;
    }

    var new = old;
    new.lflag.ICANON = false;
    new.lflag.ECHO = false;
    new.cc[@intFromEnum(os.V.MIN)] = min_read;
    new.cc[@intFromEnum(os.V.TIME)] = 0;

    if (os.tcsetattr(os.STDIN_FILENO, .NOW, &new) < 0) {
        log.err("errno: {}", .{os._errno()});
        return error.TcSetAttrTCSANOW;
    }

    return old;
}

pub fn resetTerm(t: os.termios) !void {
    if (os.tcsetattr(os.STDIN_FILENO, .DRAIN, &t) < 0) {
        log.err("errno: {}", .{os._errno()});
        return error.TcSetAttrTCSADRAIN;
    }
}

pub fn getch() !u8 {
    var buf = [1]u8{0};
    const bytes_read = try stdin.read(&buf);
    if (bytes_read < 0) {
        log.err("errno: {}", .{os._errno()});
        return error.GetchRead;
    }
    if (bytes_read == 0) {
        return error.GetchBlock;
    }

    return buf[0];
}

/// Given a **utf-8** string it returns the **byte position** 1 character to the left relative to `pos`
/// or **null** if there's no more characters to the left
pub fn moveBack(str: []const u8, pos: usize) ?usize {
    var i = pos;
    const charlen = ret: while (i != 0) : (i -= 1) {
        if (std.unicode.utf8ByteSequenceLength(str[i - 1]) catch null) |c| {
            break :ret c;
        }
    } else {
        break :ret 1;
    };

    return if (i > 0) charlen else null;
}

/// Given a **utf-8** string it returns it's *visual* length based on the **Unicode East Asian Width** of each character
pub fn visualStringLength(str: []const u8) !usize {
    var it = (try std.unicode.Utf8View.init(str)).iterator();
    var charlen: usize = 0;

    while (it.nextCodepoint()) |c| {
        charlen += if (utf8.isWideChar(c)) 2 else 1;
    }

    return charlen;
}

/// Given a **utf-8** character slice it returns it's *visual* length based on the **Unicode East Asian Width**
pub fn charWidthFromSlice(slice: []u8) !usize {
    const codepoint = try utf8.decodeCodepoint(slice);
    return if (utf8.isWideChar(codepoint)) 2 else 1;
}
