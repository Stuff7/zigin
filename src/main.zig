const std = @import("std");
const readln = @import("readln.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var buf = std.ArrayList(u8).init(gpa.allocator());
    defer buf.deinit();

    try readln.readln("> ", &buf);
    std.debug.print("Out: {s}\n", .{buf.items});
    //
    // const ch = try readln.getch(1);
    // std.debug.print("ch: {c}\n", .{ch});
    //
    // var ch: u8 = 0;
    // const key = try readln.readkey(&ch);
    // std.debug.print("ch: {c}\nkey:{s}\n", .{ ch, @tagName(key) });
}
