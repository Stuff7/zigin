const std = @import("std");
const term = @import("term.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Key = term.Key;

const stdout = term.stdout;

pub const Session = @import("Session.zig");

/// Reads user input with basic single-line navigation and editing.
///
/// # Blocking
///
/// This function blocks until the Enter key is pressed. The final input is stored in the provided buffer.
pub fn readln(buf_allocator: Allocator, comptime prompt: []const u8, buf: *ArrayList(u8)) ![]const u8 {
    var pos = buf.items.len;
    var cursor_pos = term.visualStringLength(buf.items) catch pos;

    const old = try term.setTermNonBlockingNonEcho(1);
    defer term.resetTerm(old) catch |err| {
        std.log.err("Could not reset terminal state: {}", .{err});
    };

    while (true) {
        try term.promptln(prompt, buf.items, cursor_pos);
        if (try Key.readToStringWithPosition(buf_allocator, buf, &pos, &cursor_pos) == Key.enter) {
            break;
        }
    }

    try stdout.writeByte('\n');
    try stdout.flush();
    return buf.items;
}
