const std = @import("std");
const term = @import("term.zig");
const zut = @import("zut");
const log = std.log;
const utf8 = zut.utf8;

const RingBuffer = zut.mem.RingBuffer;
const ArrayList = std.ArrayList;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;
const Key = term.Key;

pub fn Session(history_cap: usize) type {
    return struct {
        const History = RingBuffer(ArrayList(u8), history_cap);

        const SearchState = struct {
            active: bool = false,
            match_offset: usize = 0,

            fn reset(self: *SearchState) void {
                self.active = false;
                self.match_offset = 0;
            }
        };

        allocator: Allocator,
        history: History = .init(.empty),
        local_history: History = .init(.empty),
        input: ArrayList(u8) = .empty,
        stdout: *Writer,
        stdin: *Reader,
        search_state: SearchState = .{},

        pub fn deinit(self: *@This()) void {
            for (&self.history.buffer) |*ln| ln.deinit(self.allocator);
            for (&self.local_history.buffer) |*ln| ln.deinit(self.allocator);
            self.input.deinit(self.allocator);
        }

        /// Reads and captures user input into the session history
        ///
        /// # Blocking
        ///
        /// This function blocks execution until the user presses Enter to submit their input.
        /// During this blocking period, the user can navigate through the input history and
        /// perform editing operations. Once the user presses Enter, the entered input is added
        /// to the history, and the function returns a reference to the entered input in the history.
        ///
        /// # Reverse-i-Search
        ///
        /// Press Ctrl+R to enter reverse-i-search mode. In this mode:
        /// - Type to search through history
        /// - Ctrl+R: Find next older match
        /// - Ctrl+S: Find next newer match
        /// - Enter: Accept current match
        /// - Ctrl+G or Ctrl+C: Cancel search and clear input
        /// - Esc: Exit search mode and continue editing
        pub fn capture(self: *@This(), comptime prompt: []const u8) ![]const u8 {
            defer self.input.clearRetainingCapacity();
            defer self.local_history.clear();
            defer self.search_state.reset();

            var buf = &self.input;
            var pos: usize = 0;
            var cursor_pos = pos;
            var history_pos = self.history.len;
            const last_history_idx: isize = @as(isize, @intCast(history_pos)) - 1;

            const old = try term.setTermNonBlockingNonEcho(1);
            defer term.resetTerm(old) catch {};

            while (true) {
                // Render prompt based on mode
                if (self.search_state.active) {
                    const match_idx = self.findHistoryMatch(buf.items, self.search_state.match_offset);
                    const search_prompt = getSearchPrompt(buf.items, match_idx != null);
                    const display_text = if (match_idx) |idx| self.history.at(idx).?.items else "";
                    try term.promptln(self.stdout, .{ search_prompt, .input, "': ", display_text }, buf.items, cursor_pos);
                } else {
                    try term.promptln(self.stdout, prompt, buf.items, cursor_pos);
                }

                const key = try Key.readToStringWithPosition(
                    self.stdin,
                    self.allocator,
                    buf,
                    &pos,
                    &cursor_pos,
                );

                if (self.search_state.active) {
                    try self.handleSearch(key, buf, &pos, &cursor_pos);
                    continue;
                }

                // Normal mode key handling
                switch (key) {
                    .enter => break,
                    .ctrl_r => {
                        self.search_state.active = true;
                        self.search_state.match_offset = 0;
                        continue;
                    },
                    .arrow_up => history_pos = @max(self.history.len -| history_cap, history_pos -| 1),
                    .arrow_down => {
                        if (history_pos < self.history.len) history_pos += 1;
                    },
                    else => continue,
                }

                // History navigation
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
                cursor_pos = utf8.visualStringLength(item.items) catch pos;
            }

            try self.stdout.writeByte('\n');
            try self.stdout.flush();
            if (buf.items.len == 0) return "";

            const b = self.history.extendLast();
            b.clearRetainingCapacity();
            try b.appendSlice(self.allocator, buf.items);
            return b.items;
        }

        fn findHistoryMatch(self: *@This(), query: []const u8, nth: usize) ?usize {
            if (query.len == 0) return null;

            var matches_found: usize = 0;
            var i: usize = self.history.len;

            while (i > 0) {
                i -= 1;
                const entry = self.history.at(i) orelse continue;

                if (std.mem.indexOf(u8, entry.items, query) != null) {
                    if (matches_found == nth) {
                        return i;
                    }
                    matches_found += 1;
                }
            }

            return null;
        }

        fn getSearchPrompt(query: []const u8, has_match: bool) []const u8 {
            return if (has_match)
                "(reverse-i-search)`"
            else if (query.len > 0)
                "(failed reverse-i-search)`"
            else
                "(reverse-i-search)`";
        }

        fn handleSearch(self: *@This(), key: Key, buf: *ArrayList(u8), pos: *usize, cursor_pos: *usize) !void {
            switch (key) {
                .ctrl_r => {
                    // Next match (go back further in history)
                    const next_offset = self.search_state.match_offset + 1;
                    if (self.findHistoryMatch(buf.items, next_offset)) |_| {
                        self.search_state.match_offset = next_offset;
                    }
                },
                .ctrl_s => {
                    // Previous match (go forward in history)
                    if (self.search_state.match_offset > 0) {
                        self.search_state.match_offset -= 1;
                    }
                },
                .ctrl_g, .ctrl_c => {
                    // Cancel search, clear input
                    self.search_state.reset();
                    buf.clearRetainingCapacity();
                    pos.* = 0;
                    cursor_pos.* = 0;
                },
                .escape => {
                    // Exit search mode, keep current buffer
                    self.search_state.reset();
                },
                .enter => {
                    // Accept current match and exit search
                    if (self.findHistoryMatch(buf.items, self.search_state.match_offset)) |idx| {
                        const match = self.history.at(idx).?;
                        buf.clearRetainingCapacity();
                        try buf.appendSlice(self.allocator, match.items);
                    }
                    self.search_state.reset();
                },
                .arrow_up, .arrow_down => self.search_state.reset(),
                .char => {
                    // Continue editing in search mode
                    // Reset match offset since query changed
                    self.search_state.match_offset = 0;
                },
                else => {},
            }
        }
    };
}
