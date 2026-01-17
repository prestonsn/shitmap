const std = @import("std");
const ziggypoo = @import("ziggypoo");
const Timer = std.time.Timer;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    std.debug.print("\n=== HashMap Benchmark ===\n", .{});

    try benchGetRandom(allocator);
    try benchGetIncreasing(allocator);
    try benchInsertIncreasing(allocator);
    try benchInsertRandom(allocator);
    try benchInsertIncreasingPrealloc(allocator);
    try benchInsertRandomPrealloc(allocator);
}

const BenchmarkConfig = struct {
    samples: usize = 50,
    warmup_samples: usize = 3,
    ops_per_sample: usize = 5_000_000,
};

fn benchInsertIncreasing(allocator: std.mem.Allocator) !void {
    const config = BenchmarkConfig{};

    std.debug.print("\n--- Increasing Keys insert() ---\n", .{});
    std.debug.print("Config: {} samples × {}M ops ({} warmup)\n\n", .{
        config.samples,
        config.ops_per_sample / 1_000_000,
        config.warmup_samples,
    });

    // ShitMap benchmark
    {
        var samples: [config.samples]u64 = undefined;
        var key_offset: u64 = 0;
        var map = try ziggypoo.ShitMap(u64, u64, .{ .growable = true }).init(allocator, 2);
        defer map.deinit();

        for (0..config.warmup_samples) |_| {
            for (0..config.ops_per_sample) |i| {
                try map.insert(key_offset + i, i * 10);
            }
            key_offset += config.ops_per_sample;
        }

        for (&samples) |*sample| {
            var timer = try Timer.start();
            for (0..config.ops_per_sample) |i| {
                try map.insert(key_offset + i, i * 10);
            }
            sample.* = timer.read();
            key_offset += config.ops_per_sample;
        }
        const result = computeStats(&samples, config.ops_per_sample);
        printResult("Increasing Keys -- ShitMap insert", result);
    }

    // AutoHashmap
    {
        var samples: [config.samples]u64 = undefined;
        var key_offset: u64 = 0;
        var map = std.AutoHashMap(u64, u64).init(allocator);
        defer map.deinit();
        try map.ensureTotalCapacity(2);

        for (0..config.warmup_samples) |_| {
            for (0..config.ops_per_sample) |i| {
                try map.put(key_offset + i, i * 10);
            }
            key_offset += config.ops_per_sample;
        }
        for (&samples) |*sample| {
            var timer = try Timer.start();
            for (0..config.ops_per_sample) |i| {
                try map.put(key_offset + i, i * 10);
            }
            sample.* = timer.read();
            key_offset += config.ops_per_sample;
        }
        const result = computeStats(&samples, config.ops_per_sample);
        printResult("Increasing Keys -- AutoHashMap put", result);
    }

    std.debug.print("\n", .{});
}

fn benchInsertRandom(allocator: std.mem.Allocator) !void {
    const config = BenchmarkConfig{};
    const total_keys = (config.warmup_samples + config.samples) * config.ops_per_sample;

    std.debug.print("--- Random Keys insert() ---\n", .{});
    std.debug.print("Config: {} samples × {}M ops ({} warmup)\n", .{
        config.samples,
        config.ops_per_sample / 1_000_000,
        config.warmup_samples,
    });
    std.debug.print("Generating {} random keys...\n\n", .{total_keys});

    // Pre-generate random keys
    const keys = try allocator.alloc(u64, total_keys);
    defer allocator.free(keys);
    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    const random = prng.random();
    for (keys) |*k| {
        k.* = random.int(u64);
    }

    // ShitMap benchmark
    {
        var samples: [config.samples]u64 = undefined;
        var key_idx: usize = 0;
        var map = try ziggypoo.ShitMap(u64, u64, .{ .growable = true }).init(allocator, 2);
        defer map.deinit();

        for (0..config.warmup_samples) |_| {
            for (0..config.ops_per_sample) |_| {
                try map.insert(keys[key_idx], key_idx);
                key_idx += 1;
            }
        }

        for (&samples) |*sample| {
            var timer = try Timer.start();
            for (0..config.ops_per_sample) |_| {
                try map.insert(keys[key_idx], key_idx);
                key_idx += 1;
            }
            sample.* = timer.read();
        }
        const result = computeStats(&samples, config.ops_per_sample);
        printResult("ShitMap insert", result);
    }

    // AutoHashMap benchmark
    {
        var samples: [config.samples]u64 = undefined;
        var key_idx: usize = 0;
        var map = std.AutoHashMap(u64, u64).init(allocator);
        defer map.deinit();
        try map.ensureTotalCapacity(2);

        for (0..config.warmup_samples) |_| {
            for (0..config.ops_per_sample) |_| {
                try map.put(keys[key_idx], key_idx);
                key_idx += 1;
            }
        }

        for (&samples) |*sample| {
            var timer = try Timer.start();
            for (0..config.ops_per_sample) |_| {
                try map.put(keys[key_idx], key_idx);
                key_idx += 1;
            }
            sample.* = timer.read();
        }
        const result = computeStats(&samples, config.ops_per_sample);
        printResult("AutoHashMap put", result);
    }

    std.debug.print("\n", .{});
}

fn benchInsertIncreasingPrealloc(allocator: std.mem.Allocator) !void {
    const config = BenchmarkConfig{};
    const total_ops = (config.warmup_samples + config.samples) * config.ops_per_sample;

    // Round up to next power of two, with headroom for load factor
    const prealloc_size = std.math.ceilPowerOfTwo(usize, total_ops * 2) catch unreachable;
    std.debug.print("--- Increasing Keys insert() (Preallocated) ---\n", .{});
    std.debug.print("Config: {} samples × {}M ops ({} warmup), preallocated {}M slots\n\n", .{
        config.samples,
        config.ops_per_sample / 1_000_000,
        config.warmup_samples,
        prealloc_size / 1_000_000,
    });

    // ShitMap benchmark
    {
        var samples: [config.samples]u64 = undefined;
        var key_offset: u64 = 0;
        var map = try ziggypoo.ShitMap(u64, u64, .{ .growable = true }).init(allocator, prealloc_size);
        defer map.deinit();

        for (0..config.warmup_samples) |_| {
            for (0..config.ops_per_sample) |i| {
                try map.insert(key_offset + i, i * 10);
            }
            key_offset += config.ops_per_sample;
        }

        for (&samples) |*sample| {
            var timer = try Timer.start();
            for (0..config.ops_per_sample) |i| {
                try map.insert(key_offset + i, i * 10);
            }
            sample.* = timer.read();
            key_offset += config.ops_per_sample;
        }

        const result = computeStats(&samples, config.ops_per_sample);
        printResult("ShitMap insert", result);
    }

    // AutoHashMap
    {
        var samples: [config.samples]u64 = undefined;
        var key_offset: u64 = 0;
        var map = std.AutoHashMap(u64, u64).init(allocator);
        defer map.deinit();
        try map.ensureTotalCapacity(@intCast(prealloc_size));

        for (0..config.warmup_samples) |_| {
            for (0..config.ops_per_sample) |i| {
                try map.put(key_offset + i, i * 10);
            }

            key_offset += config.ops_per_sample;
        }

        for (&samples) |*sample| {
            var timer = try Timer.start();
            for (0..config.ops_per_sample) |i| {
                try map.put(key_offset + i, i * 10);
            }
            sample.* = timer.read();
            key_offset += config.ops_per_sample;
        }

        const result = computeStats(&samples, config.ops_per_sample);
        printResult("AutoHashMap put", result);
    }

    std.debug.print("\n", .{});
}

fn benchInsertRandomPrealloc(allocator: std.mem.Allocator) !void {
    const config = BenchmarkConfig{};
    const total_keys = (config.warmup_samples + config.samples) * config.ops_per_sample;

    // Round up to next power of two, with headroom for load factor
    const prealloc_size = std.math.ceilPowerOfTwo(usize, total_keys * 2) catch unreachable;
    std.debug.print("--- Random Keys insert() (Preallocated) ---\n", .{});
    std.debug.print("Config: {} samples × {}M ops ({} warmup), preallocated {}M slots\n", .{
        config.samples,
        config.ops_per_sample / 1_000_000,
        config.warmup_samples,
        prealloc_size / 1_000_000,
    });

    std.debug.print("Generating {} random keys...\n\n", .{total_keys});
    // Pre-generate random keys
    const keys = try allocator.alloc(u64, total_keys);
    defer allocator.free(keys);
    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    const random = prng.random();
    for (keys) |*k| {
        k.* = random.int(u64);
    }

    // ShitMap benchmark
    {
        var samples: [config.samples]u64 = undefined;
        var key_idx: usize = 0;
        var map = try ziggypoo.ShitMap(u64, u64, .{ .growable = true }).init(allocator, prealloc_size);
        defer map.deinit();

        for (0..config.warmup_samples) |_| {
            for (0..config.ops_per_sample) |_| {
                try map.insert(keys[key_idx], key_idx);
                key_idx += 1;
            }
        }

        for (&samples) |*sample| {
            var timer = try Timer.start();
            for (0..config.ops_per_sample) |_| {
                try map.insert(keys[key_idx], key_idx);
                key_idx += 1;
            }
            sample.* = timer.read();
        }

        const result = computeStats(&samples, config.ops_per_sample);
        printResult("ShitMap insert", result);
    }

    // AutoHashMap benchmark
    {
        var samples: [config.samples]u64 = undefined;
        var key_idx: usize = 0;
        var map = std.AutoHashMap(u64, u64).init(allocator);
        defer map.deinit();
        try map.ensureTotalCapacity(@intCast(prealloc_size));

        for (0..config.warmup_samples) |_| {
            for (0..config.ops_per_sample) |_| {
                try map.put(keys[key_idx], key_idx);
                key_idx += 1;
            }
        }

        for (&samples) |*sample| {
            var timer = try Timer.start();
            for (0..config.ops_per_sample) |_| {
                try map.put(keys[key_idx], key_idx);
                key_idx += 1;
            }
            sample.* = timer.read();
        }

        const result = computeStats(&samples, config.ops_per_sample);
        printResult("AutoHashMap put", result);
    }

    std.debug.print("\n", .{});
}

fn benchGetIncreasing(allocator: std.mem.Allocator) !void {
    const config = BenchmarkConfig{};
    const total_keys = (config.warmup_samples + config.samples) * config.ops_per_sample;

    std.debug.print("--- Increasing Keys get() ---\n", .{});
    std.debug.print("Config: {} samples × {}M ops ({} warmup)\n\n", .{
        config.samples,
        config.ops_per_sample / 1_000_000,
        config.warmup_samples,
    });

    const keys = try allocator.alloc(u64, total_keys);
    defer allocator.free(keys);

    for (keys, 0..) |*key, i| {
        key.* = i;
    }

    // ShitMap get
    {
        var map = try ziggypoo.ShitMap(u64, u64, .{ .growable = true }).init(allocator, 2);
        defer map.deinit();

        // Pre-populate the map with keys
        for (keys) |key| {
            try map.insert(key, key);
        }

        // Warmup
        var key_idx: usize = 0;
        for (0..config.warmup_samples) |_| {
            for (0..config.ops_per_sample) |_| {
                std.mem.doNotOptimizeAway(map.getPtr(keys[key_idx]));
                key_idx += 1;
            }
        }

        var samples: [config.samples]u64 = undefined;

        for (&samples) |*sample| {
            var timer = try Timer.start();
            for (0..config.ops_per_sample) |_| {
                std.mem.doNotOptimizeAway(map.getPtr(keys[key_idx]));
                key_idx += 1;
            }
            sample.* = timer.read();
        }

        const result = computeStats(&samples, config.ops_per_sample);
        printResult("ShitMap increasing keys getPtr()", result);
    }

    // AutoHashMap get
    {
        var map = std.AutoHashMap(u64, u64).init(allocator);
        defer map.deinit();

        // Pre-populate the map with keys
        for (keys) |key| {
            try map.put(key, key);
        }

        // Warmup
        var key_idx: usize = 0;
        for (0..config.warmup_samples) |_| {
            for (0..config.ops_per_sample) |_| {
                std.mem.doNotOptimizeAway(map.getPtr(keys[key_idx]));
                key_idx += 1;
            }
        }

        var samples: [config.samples]u64 = undefined;

        for (&samples) |*sample| {
            var timer = try Timer.start();
            for (0..config.ops_per_sample) |_| {
                std.mem.doNotOptimizeAway(map.getPtr(keys[key_idx]));
                key_idx += 1;
            }
            sample.* = timer.read();
        }

        const result = computeStats(&samples, config.ops_per_sample);
        printResult("AutoHashMap increasing keys get()", result);
    }
}

fn benchGetRandom(allocator: std.mem.Allocator) !void {
    const config = BenchmarkConfig{};
    const map_size: usize = 1_000_000; // Fixed map size
    const total_lookups = (config.warmup_samples + config.samples) * config.ops_per_sample;
    const prealloc_size = std.math.ceilPowerOfTwo(usize, map_size * 2) catch unreachable;

    std.debug.print("--- Random Access get() ---\n", .{});
    std.debug.print("Config: {} samples × {}M ops ({} warmup), map size: {}M keys\n", .{
        config.samples,
        config.ops_per_sample / 1_000_000,
        config.warmup_samples,
        map_size / 1_000_000,
    });
    std.debug.print("Generating random keys and lookup indices...\n\n", .{});

    // Pre-generate random keys for the map
    const keys = try allocator.alloc(u64, map_size);
    defer allocator.free(keys);
    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    const random = prng.random();
    for (keys) |*k| {
        k.* = random.int(u64);
    }

    // Pre-generate random lookup indices (indices into the keys array)
    const lookup_indices = try allocator.alloc(usize, total_lookups);
    defer allocator.free(lookup_indices);
    for (lookup_indices) |*idx| {
        idx.* = random.intRangeLessThan(usize, 0, map_size);
    }

    // ShitMap benchmark
    {
        var samples: [config.samples]u64 = undefined;
        var lookup_idx: usize = 0;
        var map = try ziggypoo.ShitMap(u64, u64, .{ .growable = true }).init(allocator, prealloc_size);
        defer map.deinit();

        // Populate map
        for (keys) |key| {
            try map.insert(key, key);
        }

        // Warmup
        for (0..config.warmup_samples) |_| {
            for (0..config.ops_per_sample) |_| {
                std.mem.doNotOptimizeAway(map.getPtr(keys[lookup_indices[lookup_idx]]));
                lookup_idx += 1;
            }
        }

        for (&samples) |*sample| {
            var timer = try Timer.start();
            for (0..config.ops_per_sample) |_| {
                std.mem.doNotOptimizeAway(map.getPtr(keys[lookup_indices[lookup_idx]]));
                lookup_idx += 1;
            }
            sample.* = timer.read();
        }
        const result = computeStats(&samples, config.ops_per_sample);
        printResult("ShitMap random access getPtr()", result);
    }

    // AutoHashMap benchmark
    {
        var samples: [config.samples]u64 = undefined;
        var lookup_idx: usize = 0;
        var map = std.AutoHashMap(u64, u64).init(allocator);
        defer map.deinit();
        try map.ensureTotalCapacity(@intCast(prealloc_size));

        // Populate map
        for (keys) |key| {
            try map.put(key, key);
        }

        // Warmup
        for (0..config.warmup_samples) |_| {
            for (0..config.ops_per_sample) |_| {
                std.mem.doNotOptimizeAway(map.getPtr(keys[lookup_indices[lookup_idx]]));
                lookup_idx += 1;
            }
        }

        for (&samples) |*sample| {
            var timer = try Timer.start();
            for (0..config.ops_per_sample) |_| {
                std.mem.doNotOptimizeAway(map.getPtr(keys[lookup_indices[lookup_idx]]));
                lookup_idx += 1;
            }
            sample.* = timer.read();
        }
        const result = computeStats(&samples, config.ops_per_sample);
        printResult("AutoHashMap random access get()", result);
    }

    std.debug.print("\n", .{});
}

const BenchmarkResult = struct { mean_ns: f64, median_ns: f64, std_dev_ns: f64, min_ns: f64, max_ns: f64, ops_per_sample: usize, outlier_count: usize, sample_count: usize };

fn printResult(name: []const u8, result: BenchmarkResult) void {
    const ops_per_sec = 1_000_000_000.0 / result.mean_ns;
    std.debug.print("{s}\n", .{name});
    std.debug.print("  Mean:     {d:.1} ns/op  ± {d:.1} ns  ({d:.1}M ops/sec)\n", .{
        result.mean_ns,
        result.std_dev_ns,
        ops_per_sec / 1_000_000.0,
    });
    std.debug.print("  Median:   {d:.1} ns/op\n", .{result.median_ns});
    std.debug.print("  Range:    [{} ns ... {} ns]\n", .{ result.min_ns, result.max_ns });
    std.debug.print("  Outliers: {}/{} ({d:.0}%)\n\n", .{
        result.outlier_count,
        result.sample_count,
        @as(f64, @floatFromInt(result.outlier_count)) / @as(f64, @floatFromInt(result.sample_count)) * 100.0,
    });
}

fn computeStats(samples: []u64, ops_per_sample: usize) BenchmarkResult {
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));

    const min = samples[0];
    const max = samples[samples.len - 1];
    const med = samples[samples.len / 2];

    var sum: u128 = 0;
    for (samples) |s| sum += s;
    const mean: f64 = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(samples.len));

    // Standard deviation
    var variance: f64 = 0.0;
    for (samples) |s| {
        const diff = @as(f64, @floatFromInt(s)) - mean;
        variance += diff * diff;
    }
    const std_dev = @sqrt(variance / @as(f64, @floatFromInt(samples.len)));

    // Outliers
    var outlier_count: usize = 0;
    for (samples) |s| {
        const diff = @abs(@as(f64, @floatFromInt(s)) - mean);
        if (diff > std_dev * 2.0) outlier_count += 1;
    }

    return BenchmarkResult{
        .mean_ns = mean / @as(f64, @floatFromInt(ops_per_sample)),
        .median_ns = @as(f64, @floatFromInt(med)) / @as(f64, @floatFromInt(ops_per_sample)),
        .std_dev_ns = std_dev / @as(f64, @floatFromInt(ops_per_sample)),
        .min_ns = @as(f64, @floatFromInt(min)) / @as(f64, @floatFromInt(ops_per_sample)),
        .max_ns = @as(f64, @floatFromInt(max)) / @as(f64, @floatFromInt(ops_per_sample)),
        .ops_per_sample = ops_per_sample,
        .outlier_count = outlier_count,
        .sample_count = samples.len,
    };
}

// pub inline fn rdtscp_fenced() u64 {
//     var hi: u32 = 0;
//     var low: u32 = 0;
//     const clob: u32 = undefined;

//     asm (
//         \\rdtscp
//         \\mfence
//         : [low] "={eax}" (low),
//           [hi] "={edx}" (hi),
//         : [clob] "={ecx}" (clob),
//     );
//     return (@as(u64, hi) << 32) | @as(u64, low);
// }

// pub inline fn rdtscp() u64 {
//     var hi: u32 = undefined;
//     var low: u32 = undefined;
//     const clob: u32 = undefined;

//     asm (
//         \\rdtscp
//         : [low] "={eax}" (low),
//           [hi] "={edx}" (hi),
//         : [clob] "={ecx}" (clob),
//     );
//     return (@as(u64, hi) << 32) | @as(u64, low);
// }

// pub inline fn rdtsc() u64 {
//     var hi: u32 = 0;
//     var low: u32 = 0;

//     asm (
//         \\rdtsc
//         : [low] "={eax}" (low),
//           [hi] "={edx}" (hi),
//     );
//     return (@as(u64, hi) << 32) | @as(u64, low);
// }
