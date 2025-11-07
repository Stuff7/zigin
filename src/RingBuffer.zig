const std = @import("std");

/// A fixed-size ring buffer allocated on the stack that always overwrites oldest entries
pub fn RingBuffer(comptime T: type, comptime capacity: usize) type {
    return struct {
        buffer: [capacity]T = undefined,
        read_idx: usize = 0,
        write_idx: usize = 0,
        len: usize = 0,

        const Self = @This();

        pub fn init(default: T) @This() {
            var buffer: [capacity]T = undefined;
            inline for (&buffer) |*b| b.* = default;

            return .{ .buffer = buffer };
        }

        /// Push an item into the buffer, overwriting the oldest if at capacity
        pub fn push(self: *Self, item: T) void {
            self.buffer[self.write_idx] = item;
            self.write_idx = (self.write_idx + 1) % capacity;

            if (self.len < capacity) {
                self.len += 1;
            } else {
                // Buffer is full, advance read index to maintain window
                self.read_idx = (self.read_idx + 1) % capacity;
            }
        }

        /// Get a reference to the newest item and advance the write index,
        /// like pushing but without inserting a new element.
        pub fn extendLast(self: *Self) *T {
            // slot to fill (this will become the newest element)
            const idx = self.write_idx;

            self.write_idx = (self.write_idx + 1) % capacity;

            // if buffer was full, advancing write_idx collides with read_idx => drop oldest
            if (self.len == capacity) {
                // buffer full: we keep len the same but advance read index to maintain window
                self.read_idx = (self.read_idx + 1) % capacity;
            } else {
                // not full yet, increasing length
                self.len += 1;
            }

            return &self.buffer[idx];
        }

        /// Pop an item from the buffer. Returns null if empty.
        pub fn pop(self: *Self) ?T {
            if (self.isEmpty()) return null;

            const item = self.buffer[self.read_idx];
            self.read_idx = (self.read_idx + 1) % capacity;
            self.len -= 1;

            return item;
        }

        /// Peek at the oldest item without removing it
        pub fn peek(self: *const Self) ?T {
            if (self.isEmpty()) return null;
            return self.buffer[self.read_idx];
        }

        /// Peek at the newest (most recently added) item
        pub fn peekNewest(self: *const Self) ?T {
            if (self.isEmpty()) return null;
            const idx = if (self.write_idx == 0) capacity - 1 else self.write_idx - 1;
            return self.buffer[idx];
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len == 0;
        }

        pub fn clear(self: *Self) void {
            self.read_idx = 0;
            self.write_idx = 0;
            self.len = 0;
        }

        /// Get the maximum capacity of the buffer
        pub fn cap(self: *const Self) usize {
            _ = self;
            return capacity;
        }

        /// Iterator for the ring buffer (oldest to newest)
        pub const Iterator = struct {
            ring: *Self,
            index: usize,
            remaining: usize,

            pub fn next(self: *Iterator) ?*T {
                if (self.remaining == 0) return null;

                const actual_idx = (self.index) % capacity;
                const item = &self.ring.buffer[actual_idx];
                self.index += 1;
                self.remaining -= 1;

                return item;
            }
        };

        /// Create an iterator starting from the oldest element
        pub fn iterator(self: *Self) Iterator {
            return Iterator{
                .ring = self,
                .index = self.read_idx,
                .remaining = self.len,
            };
        }

        /// Get item at index (0 = oldest, len-1 = newest)
        pub fn at(self: *Self, index: usize) ?*T {
            if (index >= self.len) return null;
            const actual_idx = (self.read_idx + index) % capacity;
            return &self.buffer[actual_idx];
        }
    };
}

test "RingBuffer - initialization" {
    var ring = RingBuffer(u32, 5){};
    try std.testing.expect(ring.isEmpty());
    try std.testing.expectEqual(0, ring.len);
    try std.testing.expectEqual(5, ring.cap());
}

test "RingBuffer - push and pop" {
    var ring = RingBuffer(i32, 3){};

    ring.push(10);
    ring.push(20);
    ring.push(30);

    try std.testing.expectEqual(3, ring.len);

    try std.testing.expectEqual(10, ring.pop().?);
    try std.testing.expectEqual(20, ring.pop().?);
    try std.testing.expectEqual(30, ring.pop().?);

    try std.testing.expect(ring.isEmpty());
    try std.testing.expectEqual(null, ring.pop());
}

test "RingBuffer - automatic overwrite when full" {
    var ring = RingBuffer(u32, 3){};

    ring.push(1);
    ring.push(2);
    ring.push(3);
    try std.testing.expectEqual(3, ring.len);

    ring.push(4); // Overwrites 1
    try std.testing.expectEqual(3, ring.len); // Still 3

    ring.push(5); // Overwrites 2
    ring.push(6); // Overwrites 3

    // Should have 4, 5, 6
    try std.testing.expectEqual(4, ring.pop().?);
    try std.testing.expectEqual(5, ring.pop().?);
    try std.testing.expectEqual(6, ring.pop().?);
    try std.testing.expect(ring.isEmpty());
}

test "RingBuffer - peek oldest and newest" {
    var ring = RingBuffer(i32, 3){};

    try std.testing.expectEqual(null, ring.peek());
    try std.testing.expectEqual(null, ring.peekNewest());

    ring.push(100);
    try std.testing.expectEqual(100, ring.peek().?);
    try std.testing.expectEqual(100, ring.peekNewest().?);

    ring.push(200);
    try std.testing.expectEqual(100, ring.peek().?); // Oldest
    try std.testing.expectEqual(200, ring.peekNewest().?); // Newest

    ring.push(300);
    ring.push(400); // Overwrites 100
    try std.testing.expectEqual(200, ring.peek().?); // New oldest
    try std.testing.expectEqual(400, ring.peekNewest().?); // New newest
}

test "RingBuffer - wrap around behavior" {
    var ring = RingBuffer(u32, 3){};

    // Fill the buffer
    ring.push(1);
    ring.push(2);
    ring.push(3);

    // Pop two items
    _ = ring.pop();
    _ = ring.pop();

    // Push three more (should wrap around and overwrite)
    ring.push(4);
    ring.push(5);
    ring.push(6); // Overwrites 3

    try std.testing.expectEqual(3, ring.len);
    try std.testing.expectEqual(4, ring.pop().?);
    try std.testing.expectEqual(5, ring.pop().?);
    try std.testing.expectEqual(6, ring.pop().?);
}

test "RingBuffer - clear" {
    var ring = RingBuffer(u32, 3){};

    ring.push(1);
    ring.push(2);
    ring.push(3);

    ring.clear();

    try std.testing.expect(ring.isEmpty());
    try std.testing.expectEqual(0, ring.len);
    try std.testing.expectEqual(null, ring.pop());
}

test "RingBuffer - different types" {
    // Test with strings
    var ring_str = RingBuffer([]const u8, 2){};
    ring_str.push("hello");
    ring_str.push("world");
    try std.testing.expectEqualStrings("hello", ring_str.pop().?);

    // Test with structs
    const Point = struct { x: i32, y: i32 };
    var ring_point = RingBuffer(Point, 2){};
    ring_point.push(.{ .x = 1, .y = 2 });
    ring_point.push(.{ .x = 3, .y = 4 });
    const p = ring_point.pop().?;
    try std.testing.expectEqual(1, p.x);
    try std.testing.expectEqual(2, p.y);
}

test "RingBuffer - length stays at capacity" {
    var ring = RingBuffer(u32, 5){};

    try std.testing.expectEqual(0, ring.len);

    ring.push(1);
    try std.testing.expectEqual(1, ring.len);

    ring.push(2);
    ring.push(3);
    try std.testing.expectEqual(3, ring.len);

    _ = ring.pop();
    try std.testing.expectEqual(2, ring.len);

    ring.push(4);
    ring.push(5);
    ring.push(6);
    try std.testing.expectEqual(5, ring.len);

    // Keep pushing, length should stay at 5
    ring.push(7);
    ring.push(8);
    try std.testing.expectEqual(5, ring.len);
}

test "RingBuffer - single element capacity" {
    var ring = RingBuffer(u32, 1){};

    ring.push(42);
    try std.testing.expectEqual(1, ring.len);

    ring.push(99); // Overwrites 42
    try std.testing.expectEqual(1, ring.len);
    try std.testing.expectEqual(99, ring.pop().?);
    try std.testing.expect(ring.isEmpty());
}

test "RingBuffer - continuous overwriting" {
    var ring = RingBuffer(u32, 3){};

    // Push 10 items into a 3-capacity buffer
    for (0..10) |i| {
        ring.push(@intCast(i));
    }

    // Should contain last 3: 7, 8, 9
    try std.testing.expectEqual(3, ring.len);
    try std.testing.expectEqual(7, ring.pop().?);
    try std.testing.expectEqual(8, ring.pop().?);
    try std.testing.expectEqual(9, ring.pop().?);
    try std.testing.expect(ring.isEmpty());
}

test "RingBuffer - iterator" {
    var ring = RingBuffer(u32, 5){};

    // Empty iterator
    var it = ring.iterator();
    try std.testing.expectEqual(null, it.next());

    // Push some items
    ring.push(10);
    ring.push(20);
    ring.push(30);

    // Iterate through items
    it = ring.iterator();
    try std.testing.expectEqual(10, it.next().?.*);
    try std.testing.expectEqual(20, it.next().?.*);
    try std.testing.expectEqual(30, it.next().?.*);
    try std.testing.expectEqual(null, it.next());
}

test "RingBuffer - iterator after overwrite" {
    var ring = RingBuffer(u32, 3){};

    // Fill and overflow
    ring.push(1);
    ring.push(2);
    ring.push(3);
    ring.push(4); // Overwrites 1
    ring.push(5); // Overwrites 2

    // Should iterate: 3, 4, 5
    var it = ring.iterator();
    try std.testing.expectEqual(3, it.next().?.*);
    try std.testing.expectEqual(4, it.next().?.*);
    try std.testing.expectEqual(5, it.next().?.*);
    try std.testing.expectEqual(null, it.next());
}

test "RingBuffer - iterator with for loop" {
    var ring = RingBuffer(u32, 4){};

    ring.push(100);
    ring.push(200);
    ring.push(300);

    var sum: u32 = 0;
    var it = ring.iterator();
    while (it.next()) |value| {
        sum += value.*;
    }

    try std.testing.expectEqual(600, sum);
}

test "RingBuffer - at() indexing" {
    var ring = RingBuffer(u32, 5){};

    ring.push(10);
    ring.push(20);
    ring.push(30);

    try std.testing.expectEqual(10, ring.at(0).?.*); // Oldest
    try std.testing.expectEqual(20, ring.at(1).?.*);
    try std.testing.expectEqual(30, ring.at(2).?.*); // Newest
    try std.testing.expectEqual(null, ring.at(3)); // Out of bounds
    try std.testing.expectEqual(null, ring.at(100)); // Way out of bounds
}

test "RingBuffer - at() after wrap around" {
    var ring = RingBuffer(u32, 3){};

    ring.push(1);
    ring.push(2);
    ring.push(3);
    _ = ring.pop(); // Remove 1
    ring.push(4);
    ring.push(5); // Overwrites 2

    // Buffer contains: 3, 4, 5
    try std.testing.expectEqual(3, ring.at(0).?.*);
    try std.testing.expectEqual(4, ring.at(1).?.*);
    try std.testing.expectEqual(5, ring.at(2).?.*);
}
