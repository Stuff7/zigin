const std = @import("std");
const zigin = @import("zigin");
const utf8 = @import("utf8utils");
const dbg = @import("dbgutils");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var history = std.ArrayList(std.ArrayList(u8)).init(allocator);
    defer {
        for (history.items) |s| {
            s.deinit();
        }
        history.deinit();
    }

    while (true) {
        const input = try zigin.pushln(allocator, utf8.esc("1") ++ utf8.clr("154") ++ " > " ++ utf8.esc("0"), &history);
        dbg.print("Out: {s}", .{input});

        if (std.mem.eql(u8, input, "q")) {
            break;
        }
    }
}
