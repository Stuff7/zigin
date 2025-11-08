# Prompt

`Prompt` is a **Linux-only terminal input session manager** in Zig. It supports **history, reverse-i-search, autocomplete**, and a **simple single-line input** mode.

## Features

* **Session**

  * Configurable history
  * Reverse-i-search (`Ctrl+R`/`Ctrl+S`)
  * Autocomplete via user-provided function (`Tab`)
  * UTF-8 aware cursor handling

* **Simple**

  * Single-line input with basic editing
  * Blocking until Enter is pressed

## Usage — Session

```zig
var ps = prompt.Session(8){
    .allocator = allocator,
    .stdin = &stdio.in.interface,
    .stdout = &stdio.out.interface,
    .autocomplete_fn = autocomplete,
};
defer ps.deinit();

while (true) {
    const input = try ps.capture(" > ");
    std.log.info("{s}", .{input});
    if (std.mem.eql(u8, input, "q")) break;
}
```

## Usage — Simple

```zig
var simple = prompt.Simple{
    .stdin = &stdio.in.interface,
    .stdout = &stdio.out.interface,
};
var buf: std.ArrayList(u8) = .empty;
defer buf.deinit(allocator);

const line = try simple.readln(allocator, " > ", &buf);
std.log.info("{s}", .{line});
```

## Key Bindings — Session

| Key           | Action                                  |
| ------------- | --------------------------------------- |
| Enter         | Submit input                            |
| Arrow Up/Down | Navigate history                        |
| Ctrl+R        | Reverse-i-search backward               |
| Ctrl+S        | Reverse-i-search forward                |
| Ctrl+G/C      | Cancel search                           |
| Esc           | Exit search mode                        |
| Tab           | Trigger autocomplete / cycle candidates |

## API

* `Session(history_cap: usize)` → Full-featured session
* `capture(prompt: []const u8) ![]const u8` → Read input (blocking)
* `Simple.readln(buf_allocator, prompt, buf) ![]const u8` → Single-line input
* `deinit()` → Free resources

**Note:** This project is **Linux-only**. It uses Linux-specific terminal handling and will not work on Windows or macOS.
