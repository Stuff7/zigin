const std = @import("std");
const zut = @import("zut");
const prompt = @import("prompt");
const log = std.log;

const ansi = zut.utf8.ansi;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ps = prompt.Session{ .allocator = allocator };
    defer ps.deinit();

    while (true) {
        const input = try ps.capture(allocator, ansi(" > ", "1;154"));
        log.info("{s}", .{input});

        if (std.mem.eql(u8, input, "q")) break;
    }
}
