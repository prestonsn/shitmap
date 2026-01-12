const std = @import("std");
const ziggypoo = @import("ziggypoo");
const Timer = std.time.Timer;
const ITERATIONS = 100_000;
const WARMUP_ITERATIONS = 1000;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    std.debug.print("\n=== HashMap Benchmark ===\n", .{});
    std.debug.print("Iterations: {}\n\n", .{ITERATIONS});
    try benchInsert(allocator);
    // try benchGet(allocator);
    // try benchRemove(allocator);
    // try benchMixed(allocator);
}

fn benchInsert(allocator: std.mem.Allocator) !void {
    std.debug.print("--- Insert Benchmark ---\n", .{});

    // Benchmark ShitMap
    {
        var timer = try Timer.start();
        var map = try ziggypoo.ShitMap(u64, u64, .{}).init(allocator, 1024);
        defer map.deinit();

        for (0..ITERATIONS) |i| {
            try map.insert(i, i * 10);
        }

        const elapsed_ns = timer.read();
        const ns_per_op = elapsed_ns / ITERATIONS;
        std.debug.print("ShitMap:      {} ns/op\n", .{ns_per_op});
    }

    // Benchmark std.AutoHashMap
    {
        var timer = try Timer.start();
        var map = std.AutoHashMap(u64, u64).init(allocator);
        defer map.deinit();

        for (0..ITERATIONS) |i| {
            try map.put(i, i * 10);
        }

        const elapsed_ns = timer.read();
        const ns_per_op = elapsed_ns / ITERATIONS;
        std.debug.print("AutoHashMap: {} ns/op\n", .{ns_per_op});
    }

    std.debug.print("\n", .{});
}
