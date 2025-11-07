const std = @import("std");
const term = @import("term.zig");
const log = std.log;

const ArrayList = std.ArrayList;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;
const History = ArrayList(ArrayList(u8));
const Key = term.Key;

const readln = @import("prompt.zig").readln;

allocator: Allocator,
history: History = .empty,
searching: bool = false,
stdout: *Writer,
stdin: *Reader,

pub fn deinit(self: *@This()) void {
    for (self.history.items) |*ln| ln.deinit(self.allocator);
    self.history.deinit(self.allocator);
}

/// Reads and captures user input into the session history
///
/// # Blocking
///
/// This function blocks execution until the user presses Enter to submit their input.
/// During this blocking period, the user can navigate through the input history and
/// perform editing operations. Once the user presses Enter, the entered input is added
/// to the history, and the function returns a reference to the entered input in the history.
pub fn capture(self: *@This(), gpa: Allocator, comptime prompt: []const u8) ![]const u8 {
    const local_history_capacity = 8;
    var history = &self.history;
    const history_allocator = self.allocator;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const local_history_allocator = arena.allocator();
    var local_history = History.empty;

    const new_buf_allocator = gpa;
    var new_buf = ArrayList(u8).empty;

    var buf = &new_buf;
    var pos: usize = 0;
    var cursor_pos = pos;
    var history_pos = history.items.len;
    const last_history_idx: isize = @as(isize, @intCast(history_pos)) - 1;

    const old = try term.setTermNonBlockingNonEcho(1);
    defer term.resetTerm(old) catch {};

    var search_buf = ArrayList(u8).empty;
    defer search_buf.deinit(gpa);
    var match_idx: usize = history.items.len -| 1;

    while (true) {
        if (self.searching) {
            try term.promptln(self.stdout, .{
                "(reverse-i-search)`",
                .input,
                "': ",
                if (match_idx < history.items.len) history.items[match_idx].items else "",
            }, search_buf.items, cursor_pos);
            if (self.search(search_buf.items, match_idx)) |idx| match_idx = idx;
        } else {
            try term.promptln(self.stdout, prompt, buf.items, cursor_pos);
            match_idx = history.items.len;
        }

        const key = try Key.readToStringWithPosition(
            self.stdin,
            new_buf_allocator,
            if (self.searching) &search_buf else buf,
            &pos,
            &cursor_pos,
        );

        switch (key) {
            .enter => break,
            .arrow_up => history_pos = @max(history.items.len -| local_history_capacity, history_pos -| 1),
            .ctrl_r => {
                if (self.searching) {
                    if (self.search(search_buf.items, match_idx + 1)) |idx| match_idx = idx;
                }

                self.searching = true;
                continue;
            },
            .ctrl_g => {
                self.searching = false;
                search_buf.clearRetainingCapacity();
                cursor_pos = 0;
                pos = 0;
                continue;
            },
            .arrow_down => {
                if (history_pos < history.items.len) history_pos += 1;
            },
            else => continue,
        }

        const local_pos = last_history_idx - @as(isize, @intCast(history_pos));
        var item: *ArrayList(u8) = undefined;

        if (local_pos >= 0 and local_pos < local_history.items.len) {
            item = &local_history.items[@intCast(local_pos)];
        } else if (history_pos >= 0 and history_pos < history.items.len) {
            var cp = history.items[@intCast(history_pos)];
            try local_history.append(local_history_allocator, try cp.clone(local_history_allocator));
            item = &local_history.items[@intCast(local_pos)];
        } else {
            item = &new_buf;
        }

        buf = item;
        pos = item.items.len;
        cursor_pos = term.visualStringLength(item.items) catch pos;
    }

    try self.stdout.writeByte('\n');
    try self.stdout.flush();
    if (buf.items.len == 0) {
        return "";
    }

    var tmp = new_buf;
    defer tmp.deinit(new_buf_allocator);
    new_buf = buf.*;
    new_buf = try new_buf.clone(history_allocator);
    try history.append(history_allocator, new_buf);
    return new_buf.items;
}

fn search(self: @This(), query: []const u8, start_idx: ?usize) ?usize {
    if (query.len == 0) return null;

    const search_start = if (start_idx) |idx|
        if (idx > 0) idx - 1 else return null
    else
        self.history.items.len;

    var i = search_start;
    while (i > 0) : (i -= 1) {
        const item = self.history.items[i - 1].items;
        if (std.ascii.indexOfIgnoreCase(item, query)) |_| {
            return i - 1;
        }
    }

    return null;
}
