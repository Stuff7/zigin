const std = @import("std");
const term = @import("term.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Key = term.Key;

pub const Session = @import("Session.zig").Session;

pub const Simple = struct {
    stdout: *Writer,
    stdin: *Reader,

    /// Reads user input with basic single-line navigation and editing.
    ///
    /// # Blocking
    ///
    /// This function blocks until the Enter key is pressed. The final input is stored in the provided buffer.
    pub fn readln(self: @This(), buf_allocator: Allocator, prompt: anytype, buf: *ArrayList(u8)) ![]const u8 {
        var pos = buf.items.len;
        var cursor_pos = term.visualStringLength(buf.items) catch pos;

        const old = try term.setTermNonBlockingNonEcho(1);
        defer term.resetTerm(old) catch {};

        while (true) {
            try term.promptln(self.stdout, prompt, buf.items, cursor_pos);
            if (try Key.readToStringWithPosition(self.stdin, buf_allocator, buf, &pos, &cursor_pos) == Key.enter) {
                break;
            }
        }

        try self.stdout.writeByte('\n');
        try self.stdout.flush();
        return buf.items;
    }
};

pub const Stdio = struct {
    in_buf: [256]u8 = undefined,
    in: std.fs.File.Reader,
    out_buf: [256]u8 = undefined,
    out: std.fs.File.Writer,

    pub fn initRef(self: *@This()) void {
        self.in = std.fs.File.stdin().reader(&self.in_buf);
        self.out = std.fs.File.stdout().writer(&self.out_buf);
    }
};
