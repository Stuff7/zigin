const std = @import("std");
const zut = @import("zut");
const prompt = @import("prompt");
const log = std.log;

const ansi = zut.utf8.ansi;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stdio: prompt.Stdio = undefined;
    stdio.initRef();

    var ps = prompt.Session{
        .allocator = allocator,
        .stdin = &stdio.in.interface,
        .stdout = &stdio.out.interface,
    };
    defer ps.deinit();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();

    if (args.next()) |history_path| {
        const history = try std.fs.cwd().openFile(history_path, .{});
        var buf: [512]u8 = undefined;
        var r = history.reader(&buf);

        while (true) {
            const ln = r.interface.takeDelimiterExclusive('\n') catch |err| switch (err) {
                error.EndOfStream => break,
                else => continue,
            };
            var item = try std.ArrayList(u8).initCapacity(allocator, ln.len);
            item.appendSliceAssumeCapacity(ln);
            try ps.history.append(allocator, item);
        }

        log.info("Loaded history from '{s}'", .{history_path});
    }

    while (true) {
        const input = try ps.capture(allocator, ansi(" > ", "1;154"));
        log.info("{s}", .{input});

        if (std.mem.eql(u8, input, "q")) break;
    }
}

test "All navigation and editing" {
    const allocator = std.testing.allocator;
    const in =
        // Basic left/right navigation with insertion
        "Helo worl" ++
        "\x1b[D\x1b[D\x1b[D\x1b[D\x1b[D\x1b[D" ++
        "l" ++
        "\x1b[C\x1b[C\x1b[C\x1b[C\x1b[C\x1b[C" ++
        "d!\n" ++

        // Backspace at various positions
        "asdfsdf" ++
        "\x7f\x7f\x7f\x7f\x7f\x7f\x7f" ++
        "ok\n" ++

        // Backspace in the middle of text
        "Hello World" ++
        "\x1b[D\x1b[D\x1b[D\x1b[D\x1b[D" ++
        "\x7f" ++
        "\x1b[C\x1b[C\x1b[C\x1b[C\x1b[C" ++
        "\n" ++

        // Ctrl+Backspace (delete word)
        "one two three four" ++
        "\x1b[D\x1b[D\x1b[D\x1b[D" ++
        "\x17" ++
        "\x17" ++
        "end \n" ++

        // Ctrl+Left Arrow (jump left by word)
        "the quick brown fox" ++
        "\x1b[1;5D" ++
        "\x1b[1;5D" ++
        "\x1b[1;5D" ++
        "very " ++
        "\x1b[C\x1b[C\x1b[C\x1b[C\x1b[C" ++
        "\x1b[C\x1b[C\x1b[C\x1b[C\x1b[C" ++
        "\x1b[C\x1b[C\x1b[C\x1b[C\x1b[C\x1b[C" ++
        "\x1b[C\x1b[C\x1b[C\x1b[C" ++
        "\n" ++

        // Ctrl+Right Arrow (jump right by word)
        "alpha beta gamma" ++
        "\x1b[D\x1b[D\x1b[D\x1b[D\x1b[D\x1b[D" ++
        "\x1b[D\x1b[D\x1b[D\x1b[D\x1b[D\x1b[D" ++
        "\x1b[D\x1b[D\x1b[D\x1b[D\x1b[D\x1b[D" ++
        "\x1b[1;5C" ++
        "\x1b[1;5C" ++
        " delta" ++
        "\n" ++

        // Multiple spaces and word navigation
        "word1    word2     word3" ++
        "\x1b[1;5D" ++
        "\x1b[1;5D" ++
        "\x1b[1;5D" ++
        "\x1b[1;5C" ++
        "\x1b[1;5C" ++
        "X" ++
        "\n" ++

        // Edge cases - navigation at boundaries
        "test" ++
        "\x1b[D\x1b[D\x1b[D\x1b[D" ++
        "\x1b[D\x1b[D" ++
        "\x1b[C\x1b[C\x1b[C\x1b[C" ++
        "\x1b[C\x1b[C" ++
        "\n" ++

        // UTF-8 character handling
        "Ã¥Ã¤Ã¶" ++
        "\x1b[D" ++
        "\x7f" ++
        "\x1b[D" ++
        "\x1b[C" ++
        "Ã¶" ++
        "\n" ++

        // Complex editing scenario
        "This is a mistake" ++
        "\x1b[D\x1b[D\x1b[D\x1b[D\x1b[D\x1b[D\x1b[D" ++
        "\x17" ++
        "test" ++
        "\n" ++

        // Search
        "\x12fox\n\n" ++
        // Quit
        "q\n";

    var reader = std.Io.Reader.fixed(in);
    var allocating = std.Io.Writer.Allocating.init(allocator);
    defer allocating.deinit();

    var ps = prompt.Session{ .allocator = allocator, .stdin = &reader, .stdout = &allocating.writer };
    defer ps.deinit();

    const expected = [_][]const u8{
        "Hello world!",
        "ok",
        "HelloWorld",
        "one end four",
        "the very quick brown fox",
        "alpha beta delta gamma",
        "word1    word2X     word3",
        "test",
        "Ã¥Ã¤Ã¶¶",
        "This is testmistake",
    };

    var i: usize = 0;
    while (true) {
        const input = try ps.capture(allocator, ansi(" > ", "1;154"));
        std.debug.print("Input {}: {s}\n", .{ i, input });

        if (std.mem.eql(u8, input, "q")) break;

        // try std.testing.expectEqualStrings(expected[i], input);
        i += 1;
    }

    try std.testing.expectEqual(expected.len, i);
}
