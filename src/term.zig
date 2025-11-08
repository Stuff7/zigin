const std = @import("std");
const zut = @import("zut");
const os = std.os.linux;
const utf8 = zut.utf8;
const log = std.log;

const ArrayList = std.ArrayList;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

pub const Key = enum {
    na,
    char,
    tab,
    shift_tab,
    enter,
    escape,
    backspace,
    arrow_up,
    arrow_down,
    arrow_right,
    arrow_left,
    ctrl_backspace,
    ctrl_arrow_right,
    ctrl_arrow_left,
    ctrl_c,
    ctrl_g,
    ctrl_r,
    ctrl_s,

    /// Reads a single utf-8 character of user input, allowing basic editing operations with a cursor.
    ///
    /// # Blocking
    ///
    /// This function blocks until a key event is detected and returns the corresponding `Key` enum
    /// representing the user input. The function also updates the provided buffer and cursor
    /// position based on the input.
    pub fn readToStringWithPosition(stdin: *Reader, allocator: Allocator, buf: *ArrayList(u8), pos: *usize, cursor_pos: *usize) !Key {
        const key, const ch = try Key.readFromStdin(stdin);

        switch (key) {
            Key.char => {
                const charlen = try std.unicode.utf8ByteSequenceLength(ch);
                var slice = [1]u8{ch} ** 4;
                for (1..charlen) |i| {
                    _, slice[i] = try Key.readFromStdin(stdin);
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

    pub fn fromEscapeSequence(stdin: *Reader) !Key {
        const sequences = [_]struct { key: Key, seq: []const u8 }{
            .{ .key = .arrow_up, .seq = "[A" },
            .{ .key = .arrow_down, .seq = "[B" },
            .{ .key = .arrow_right, .seq = "[C" },
            .{ .key = .arrow_left, .seq = "[D" },
            .{ .key = .shift_tab, .seq = "[Z" },
            .{ .key = .ctrl_arrow_right, .seq = "[1;5C" },
            .{ .key = .ctrl_arrow_left, .seq = "[1;5D" },
        };

        var ch: u8 = 0;
        var pos: usize = 0;

        while (pos < sequences.len + 1) {
            ch = try stdin.takeByte();

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

        return .escape;
    }

    pub fn readFromStdin(stdin: *Reader) !struct { Key, u8 } {
        const ch = try stdin.takeByte();

        const k = switch (ch) {
            0x08, 0x17 => .ctrl_backspace,
            0x09 => .tab,
            0x0A => .enter,
            0x03 => .ctrl_c,
            0x12 => .ctrl_r,
            0x13 => .ctrl_s,
            0x07 => .ctrl_g,
            0x1B => try Key.fromEscapeSequence(stdin),
            0x7F => .backspace,
            else => if (ch > 31) return .{ .char, ch } else .na,
        };

        return .{ k, ch };
    }
};

pub inline fn isString(comptime T: type) bool {
    const info = @typeInfo(T);

    if (info == .pointer) {
        const ptr_info = info.pointer;

        // []const u8 or []u8 (slices)
        if (ptr_info.size == .slice) {
            return ptr_info.child == u8;
        }

        // *const [N]u8 or *[N]u8 (pointer to array)
        if (ptr_info.size == .one) {
            const child_info = @typeInfo(ptr_info.child);
            if (child_info == .array) {
                return child_info.array.child == u8;
            }
        }
    }

    if (info == .array) {
        return info.array.child == u8;
    }

    return false;
}

pub fn promptln(stdout: *Writer, prompt: anytype, input: []const u8, cursor: usize) !void {
    const args = blk: {
        const P = @TypeOf(prompt);

        if (isString(P)) break :blk .{ prompt, .input };

        if (!@typeInfo(P).@"struct".is_tuple) {
            @compileError(
                \\`prompt` must be either a string or a tuple like `.{"Your prompt ", .input, " more prompts"}`
            );
        }

        break :blk prompt;
    };

    var input_found = false;
    var pos = cursor;
    try stdout.writeAll("\x1b[2K\r");
    inline for (args) |arg| {
        if (isString(@TypeOf(arg))) {
            try stdout.writeAll(arg);
            if (!input_found) pos += try utf8.charLength(arg);
        } else if (arg == .input) {
            try stdout.writeAll(input);
            input_found = true;
        }
    }
    try stdout.writeByte('\r');

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

/// Given a **utf-8** string it returns it's *visual* length based on the **Unicode East Asian Width** of each character
pub fn visualStringLength(str: []const u8) !usize {
    var it = (try std.unicode.Utf8View.init(str)).iterator();
    var charlen: usize = 0;

    while (it.nextCodepoint()) |c| {
        charlen += if (utf8.isWideChar(c)) 2 else 1;
    }

    return charlen;
}

/// Given a **utf-8** string it returns the **byte position** 1 character to the left relative to `pos`
/// or **null** if there's no more characters to the left
fn moveBack(str: []const u8, pos: usize) ?usize {
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

/// Given a **utf-8** character slice it returns it's *visual* length based on the **Unicode East Asian Width**
fn charWidthFromSlice(slice: []u8) !usize {
    const codepoint = try utf8.decodeCodepoint(slice);
    return if (utf8.isWideChar(codepoint)) 2 else 1;
}
