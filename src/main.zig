const std = @import("std");
const ziggypoo = @import("ziggypoo");

pub fn main() !void {}

test "simple test" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var map = try ziggypoo.ShitMap(u32, []const u8, .{ .growable = false }).init(allocator, 16);
    defer map.deinit();

    try map.insert(12, "hi");
    try map.insert(13, "there");

    if (map.getPtr(12)) |value| {
        std.debug.print("key {}, value {s}\n", .{ 12, value.* });
    }

    if (map.getPtr(13)) |value| {
        std.debug.print("key {}, value {s}\n", .{ 13, value.* });
    }

    try map.insert(12, "updated");
    if (map.getPtr(12)) |value| {
        std.debug.print("key {} = {s}\n", .{ 12, value.* });
    }
}

test "remove returns value and allows re-insert" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var map = try ziggypoo.ShitMap(u32, u32, .{ .growable = false }).init(allocator, 16);
    defer map.deinit();
    try map.insert(42, 100);

    // Remove should return the value
    const removed = map.remove(42);
    try std.testing.expectEqual(@as(u32, 100), removed.?);

    // Get should return null after removal
    try std.testing.expectEqual(@as(?*u32, null), map.getPtr(42));

    // Re-insert at same key should work (TOMBSTONE handling)
    try map.insert(42, 200);
    try std.testing.expectEqual(@as(u32, 200), map.getPtr(42).?.*);
}

test "static map returns MapFull error" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var map = try ziggypoo.ShitMap(u32, u32, .{ .growable = false }).init(allocator, 4);
    defer map.deinit();

    try map.insert(1, 10);
    try map.insert(2, 20);
    try map.insert(3, 30);
    try map.insert(4, 40);

    const result = map.insert(5, 50);
    try std.testing.expectError(error.MapFull, result);
}

test "growable map auto-resizes" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var map = try ziggypoo.ShitMap(u32, u32, .{ .growable = true, .load_factor = 0.5 }).init(allocator, 4);
    defer map.deinit();
    const initial_capacity = map.capacity;
    // Insert enough to trigger growth (>50% load factor)
    try map.insert(1, 10);
    try map.insert(2, 20);
    try map.insert(3, 30); // This should trigger growth
    try map.insert(4, 40);
    try map.insert(5, 50);
    // Verify capacity increased
    try std.testing.expect(map.capacity > initial_capacity);
    // Verify all elements still retrievable
    try std.testing.expectEqual(@as(u32, 10), map.getPtr(1).?.*);
    try std.testing.expectEqual(@as(u32, 20), map.getPtr(2).?.*);
    try std.testing.expectEqual(@as(u32, 30), map.getPtr(3).?.*);
    try std.testing.expectEqual(@as(u32, 40), map.getPtr(4).?.*);
    try std.testing.expectEqual(@as(u32, 50), map.getPtr(5).?.*);
}

test "capacity must be power of two" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const result = ziggypoo.ShitMap(u32, u32, .{}).init(allocator, 15);
    try std.testing.expectError(error.CapacityNotPowerOfTwo, result);
}

test "linear probing handles collisions" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    // Small capacity to force collisions
    var map = try ziggypoo.ShitMap(u32, u32, .{ .growable = false }).init(allocator, 8);
    defer map.deinit();
    // Insert several keys - some will collide
    const keys = [_]u32{ 0, 8, 16, 1, 9, 2 }; // 0, 8, 16 will hash to same bucket (mod 8)
    for (keys, 0..) |key, i| {
        try map.insert(key, @intCast(i * 10));
    }
    // All should be retrievable
    for (keys, 0..) |key, i| {
        const expected: u32 = @intCast(i * 10);
        try std.testing.expectEqual(expected, map.getPtr(key).?.*);
    }
}
