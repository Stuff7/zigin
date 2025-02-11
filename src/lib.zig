const std = @import("std");
const utf8 = @import("utf8utils");
const dbg = @import("dbgutils");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const os = std.os.linux;

/// Reads user input in a loop with a given prompt and an input history.
///
/// # Blocking
///
/// This function blocks execution until the user presses Enter to submit their input.
/// During this blocking period, the user can navigate through the input history and
/// perform editing operations. Once the user presses Enter, the entered input is added
/// to the history, and the function returns a reference to the entered input in the history.
pub fn pushln(allocator: Allocator, comptime prompt: []const u8, history: *ArrayList(ArrayList(u8))) ![]const u8 {
    const local_history_capacity = 8;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var local_history = ArrayList(ArrayList(u8)).init(arena.allocator());

    var msg_buf: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&msg_buf);
    var new_buf = ArrayList(u8).init(fba.allocator());
    var buf = &new_buf;

    var pos: usize = 0;
    var cursor_pos = pos;
    var history_pos = history.items.len;
    const last_history_idx: isize = @as(isize, @intCast(history_pos)) - 1;

    const old = try setTermNonBlockingNonEcho(1);
    defer resetTerm(old) catch |err| {
        dbg.errMsg("Could not reset terminal state: {}", err);
    };

    while (true) {
        try promptln(prompt, buf.items, cursor_pos);
        const key = try Key.readToStringWithPosition(buf, &pos, &cursor_pos);

        switch (key) {
            .enter => break,
            .arrow_up => history_pos = @max(history.items.len -| local_history_capacity, history_pos -| 1),
            .arrow_down => {
                if (history_pos < history.items.len) {
                    history_pos += 1;
                }
            },
            else => continue,
        }

        const local_pos = last_history_idx - @as(isize, @intCast(history_pos));
        var item: *ArrayList(u8) = undefined;

        if (local_pos >= 0 and local_pos < local_history.items.len) {
            item = &local_history.items[@intCast(local_pos)];
        } else if (history_pos >= 0 and history_pos < history.items.len) {
            var cp = history.items[@intCast(history_pos)];
            cp.allocator = local_history.allocator;
            try local_history.append(try cp.clone());
            item = &local_history.items[@intCast(local_pos)];
        } else {
            item = &new_buf;
        }

        buf = item;
        pos = item.items.len;
        cursor_pos = visualStringLength(item.items) catch pos;
    }

    try dbg.stdout.print("\n", .{});
    if (buf.items.len == 0) {
        return "";
    }

    new_buf = buf.*;
    new_buf.allocator = allocator;
    new_buf = try new_buf.clone();
    try history.append(new_buf);
    return new_buf.items;
}

/// Reads user input with basic single-line navigation and editing.
///
/// # Blocking
///
/// This function blocks until the Enter key is pressed. The final input is stored in the provided buffer.
pub fn readln(comptime prompt: []const u8, buf: *ArrayList(u8)) !void {
    var pos = buf.items.len;
    var cursor_pos = visualStringLength(buf.items) catch pos;

    const old = try setTermNonBlockingNonEcho(1);
    defer resetTerm(old) catch |err| {
        dbg.errMsg("Could not reset terminal state: {}", err);
    };

    while (true) {
        try promptln(prompt, buf.items, cursor_pos);
        if (try Key.readToStringWithPosition(buf, &pos, &cursor_pos) == Key.enter) {
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
    fn readToStringWithPosition(buf: *ArrayList(u8), pos: *usize, cursor_pos: *usize) !Key {
        const key, const ch = try Key.readFromStdin();

        switch (key) {
            Key.char => {
                const charlen = try std.unicode.utf8ByteSequenceLength(ch);
                var slice = [1]u8{ch} ** 4;
                for (1..charlen) |i| {
                    _, slice[i] = try Key.readFromStdin();
                }

                if (pos.* == buf.items.len) {
                    try buf.appendSlice(slice[0..charlen]);
                } else {
                    try buf.insertSlice(pos.*, slice[0..charlen]);
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

    pub fn readFromStdin() !struct { Key, u8 } {
        const ch = try getch();

        const k = switch (ch) {
            8, 23 => .ctrl_backspace,
            9 => .tab,
            10 => .enter,
            27 => try parseEscSeq(),
            127 => .backspace,
            else => if (ch > 31) return .{ .char, ch } else .na,
        };

        return .{ k, ch };
    }
};

const EscapeSequence = struct { key: Key, seq: []const u8 };
fn parseEscSeq() !Key {
    const sequences = [_]EscapeSequence{
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
