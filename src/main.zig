const std = @import("std");
const zigin = @import("zigin");
const utf8 = @import("utf8utils");
const dbg = @import("dbgutils");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();

    var input = std.ArrayList(u8).init(gpa.allocator());
    defer input.deinit();

    while (true) {
        try zigin.readln(utf8.esc("1") ++ utf8.clr("154") ++ " > " ++ utf8.esc("0"), &input);
        defer input.clearRetainingCapacity();

        dbg.print("Out: {s}", .{input.items});

        if (std.mem.eql(u8, input.items, "q")) {
            break;
        }
    }
}
