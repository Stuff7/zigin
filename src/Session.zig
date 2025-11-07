const std = @import("std");
const term = @import("term.zig");
const log = std.log;

const RingBuffer = @import("RingBuffer.zig").RingBuffer;
const ArrayList = std.ArrayList;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

pub fn Session(history_cap: usize) type {
    return struct {
        const History = RingBuffer(ArrayList(u8), history_cap);
        const Key = term.Key;

        allocator: Allocator,
        history: History = .init(.empty),
        local_history: History = .init(.empty),
        input: ArrayList(u8) = .empty,
        search_input: ArrayList(u8) = .empty,
        searching: bool = false,
        stdout: *Writer,
        stdin: *Reader,

        pub fn deinit(self: *@This()) void {
            for (&self.history.buffer) |*ln| ln.deinit(self.allocator);
            for (&self.local_history.buffer) |*ln| ln.deinit(self.allocator);
            self.input.deinit(self.allocator);
            self.search_input.deinit(self.allocator);
        }

        /// Reads and captures user input into the session history
        ///
        /// # Blocking
        ///
        /// This function blocks execution until the user presses Enter to submit their input.
        /// During this blocking period, the user can navigate through the input history and
        /// perform editing operations. Once the user presses Enter, the entered input is added
        /// to the history, and the function returns a reference to the entered input in the history.
        pub fn capture(self: *@This(), comptime prompt: []const u8) ![]const u8 {
            defer self.input.clearRetainingCapacity();
            defer self.search_input.clearRetainingCapacity();
            defer self.local_history.clear();

            var buf = &self.input;
            var pos: usize = 0;
            var cursor_pos = pos;
            var history_pos = self.history.len;
            const last_history_idx: isize = @as(isize, @intCast(history_pos)) - 1;

            const old = try term.setTermNonBlockingNonEcho(1);
            defer term.resetTerm(old) catch {};

            var match_idx: usize = self.history.len -| 1;

            while (true) {
                if (self.searching) {
                    try term.promptln(self.stdout, .{
                        "(reverse-i-search)`",
                        .input,
                        "': ",
                        if (self.history.at(match_idx)) |ln| ln.items else "",
                    }, self.search_input.items, cursor_pos);
                    if (self.search(self.search_input.items, match_idx)) |idx| match_idx = idx;
                } else {
                    try term.promptln(self.stdout, prompt, buf.items, cursor_pos);
                    match_idx = self.history.len;
                }

                const key = try Key.readToStringWithPosition(
                    self.stdin,
                    self.allocator,
                    if (self.searching) &self.search_input else buf,
                    &pos,
                    &cursor_pos,
                );

                switch (key) {
                    .enter => break,
                    .arrow_up => history_pos = @max(self.history.len -| history_cap, history_pos -| 1),
                    .ctrl_r => {
                        if (self.searching) {
                            if (self.search(self.search_input.items, match_idx + 1)) |idx| match_idx = idx;
                        }

                        self.searching = true;
                        continue;
                    },
                    .ctrl_g => {
                        self.searching = false;
                        self.search_input.clearRetainingCapacity();
                        cursor_pos = 0;
                        pos = 0;
                        continue;
                    },
                    .arrow_down => {
                        if (history_pos < self.history.len) history_pos += 1;
                    },
                    else => continue,
                }

                const local_pos = last_history_idx - @as(isize, @intCast(history_pos));
                var item: *ArrayList(u8) = undefined;

                if (if (local_pos >= 0) self.local_history.at(@intCast(local_pos)) else null) |ln| {
                    item = ln;
                } else if (if (history_pos >= 0) self.history.at(@intCast(history_pos)) else null) |ln| {
                    item = self.local_history.extendLast();
                    item.clearRetainingCapacity();
                    try item.appendSlice(self.allocator, ln.items);
                } else {
                    item = &self.input;
                }

                buf = item;
                pos = item.items.len;
                cursor_pos = term.visualStringLength(item.items) catch pos;
            }

            try self.stdout.writeByte('\n');
            try self.stdout.flush();
            if (buf.items.len == 0) return "";

            const b = self.history.extendLast();
            b.clearRetainingCapacity();
            try b.appendSlice(self.allocator, buf.items);
            return b.items;
        }

        fn search(self: *@This(), query: []const u8, start_idx: ?usize) ?usize {
            if (query.len == 0) return null;

            const search_start = if (start_idx) |idx|
                if (idx > 0) idx - 1 else return null
            else
                self.history.len;

            var i = search_start;
            while (i > 0) : (i -= 1) {
                const item = self.history.at(i - 1).?.items;
                if (std.ascii.indexOfIgnoreCase(item, query)) |_| {
                    return i - 1;
                }
            }

            return null;
        }
    };
}
