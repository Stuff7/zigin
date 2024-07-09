const std = @import("std");
const term = @import("term.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var buf = std.ArrayList(u8).init(gpa.allocator());
    defer buf.deinit();

    while (true) {
        try term.readln("> ", &buf);
        try term.stdout.print("Out: {s}\n", .{buf.items});

        if (buf.items.len == 1 and buf.items[0] == 'q') {
            break;
        }

        buf.clearRetainingCapacity();
    }
}
