const std = @import("std");
const ziggypoo = @import("ziggypoo");
const Timer = std.time.Timer;

const ShitMapConfig = ziggypoo.ShitMapConfig;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const configs = .{
        .{ .name = "scalar", .config = ShitMapConfig{ .growable = true } },
        .{ .name = "simd", .config = ShitMapConfig{ .growable = true, .simd_get = true } },
    };

    inline for (configs) |cfg| {
        std.debug.print("\n=== ShitMap Benchmark ({s}) ===\n", .{cfg.name});
        try benchGetRandom(allocator, cfg.name, cfg.config);
        try benchGetMisses(allocator, cfg.name, cfg.config);
        try benchGetMixed(allocator, cfg.name, cfg.config);
    }

    // AutoHashMap baseline (only once)
    std.debug.print("\n=== AutoHashMap Baseline ===\n", .{});
    try benchGetRandomAutoHashMap(allocator);
    try benchGetMissesAutoHashMap(allocator);
    try benchGetMixedAutoHashMap(allocator);
}

const RunConfig = struct {
    samples: usize = 50,
    warmup_samples: usize = 3,
    ops_per_sample: usize = 5_000_000,
};

fn benchGetRandom(allocator: std.mem.Allocator, name: []const u8, comptime map_config: ShitMapConfig) !void {
    const config = RunConfig{};
    const map_size: usize = 1_000_000;
    const total_lookups = (config.warmup_samples + config.samples) * config.ops_per_sample;
    const prealloc_size = std.math.ceilPowerOfTwo(usize, map_size * 2) catch unreachable;

    std.debug.print("\n--- Random Access getPtr() ({s}) ---\n", .{name});
    std.debug.print("Config: {} samples × {}M ops ({} warmup), map size: {}M keys\n\n", .{
        config.samples,
        config.ops_per_sample / 1_000_000,
        config.warmup_samples,
        map_size / 1_000_000,
    });

    const keys = try allocator.alloc(u64, map_size);
    defer allocator.free(keys);
    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    const random = prng.random();
    for (keys) |*k| {
        k.* = random.int(u64);
    }

    const lookup_indices = try allocator.alloc(usize, total_lookups);
    defer allocator.free(lookup_indices);
    for (lookup_indices) |*idx| {
        idx.* = random.intRangeLessThan(usize, 0, map_size);
    }

    var samples: [config.samples]u64 = undefined;
    var lookup_idx: usize = 0;
    var map = try ziggypoo.ShitMap(u64, u64, map_config).init(allocator, prealloc_size);
    defer map.deinit();

    for (keys) |key| {
        try map.insert(key, key);
    }

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

fn benchGetMisses(allocator: std.mem.Allocator, name: []const u8, comptime map_config: ShitMapConfig) !void {
    const config = RunConfig{};
    const map_size: usize = 1_000_000;
    const total_lookups = (config.warmup_samples + config.samples) * config.ops_per_sample;
    const prealloc_size = std.math.ceilPowerOfTwo(usize, map_size * 2) catch unreachable;

    std.debug.print("\n--- getPtr() All Misses ({s}) ---\n", .{name});
    std.debug.print("Config: {} samples × {}M ops ({} warmup), map size: {}M keys\n\n", .{
        config.samples,
        config.ops_per_sample / 1_000_000,
        config.warmup_samples,
        map_size / 1_000_000,
    });

    const keys = try allocator.alloc(u64, map_size);
    defer allocator.free(keys);
    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    const random = prng.random();
    for (keys) |*k| {
        k.* = random.int(u64) | 1; // odd keys in map
    }

    const miss_keys = try allocator.alloc(u64, total_lookups);
    defer allocator.free(miss_keys);
    for (miss_keys) |*k| {
        k.* = random.int(u64) & ~@as(u64, 1); // even keys for lookup (guaranteed miss)
    }

    var samples: [config.samples]u64 = undefined;
    var lookup_idx: usize = 0;
    var map = try ziggypoo.ShitMap(u64, u64, map_config).init(allocator, prealloc_size);
    defer map.deinit();

    for (keys) |key| {
        try map.insert(key, key);
    }

    for (0..config.warmup_samples) |_| {
        for (0..config.ops_per_sample) |_| {
            std.mem.doNotOptimizeAway(map.getPtr(miss_keys[lookup_idx]));
            lookup_idx += 1;
        }
    }

    for (&samples) |*sample| {
        var timer = try Timer.start();
        for (0..config.ops_per_sample) |_| {
            std.mem.doNotOptimizeAway(map.getPtr(miss_keys[lookup_idx]));
            lookup_idx += 1;
        }
        sample.* = timer.read();
    }
    const result = computeStats(&samples, config.ops_per_sample);
    printResult("ShitMap getPtr() all misses", result);
}

fn benchGetMixed(allocator: std.mem.Allocator, name: []const u8, comptime map_config: ShitMapConfig) !void {
    const config = RunConfig{};
    const map_size: usize = 1_000_000;
    const total_lookups = (config.warmup_samples + config.samples) * config.ops_per_sample;
    const prealloc_size = std.math.ceilPowerOfTwo(usize, map_size * 2) catch unreachable;

    std.debug.print("\n--- getPtr() Mixed Hits/Misses 50%% ({s}) ---\n", .{name});
    std.debug.print("Config: {} samples × {}M ops ({} warmup), map size: {}M keys\n\n", .{
        config.samples,
        config.ops_per_sample / 1_000_000,
        config.warmup_samples,
        map_size / 1_000_000,
    });

    const keys = try allocator.alloc(u64, map_size);
    defer allocator.free(keys);
    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    const random = prng.random();
    for (keys) |*k| {
        k.* = random.int(u64) | 1; // odd keys
    }

    const lookup_keys = try allocator.alloc(u64, total_lookups);
    defer allocator.free(lookup_keys);
    for (lookup_keys) |*k| {
        if (random.boolean()) {
            k.* = keys[random.intRangeLessThan(usize, 0, map_size)]; // hit
        } else {
            k.* = random.int(u64) & ~@as(u64, 1); // miss (even)
        }
    }

    var samples: [config.samples]u64 = undefined;
    var lookup_idx: usize = 0;
    var map = try ziggypoo.ShitMap(u64, u64, map_config).init(allocator, prealloc_size);
    defer map.deinit();

    for (keys) |key| {
        try map.insert(key, key);
    }

    for (0..config.warmup_samples) |_| {
        for (0..config.ops_per_sample) |_| {
            std.mem.doNotOptimizeAway(map.getPtr(lookup_keys[lookup_idx]));
            lookup_idx += 1;
        }
    }

    for (&samples) |*sample| {
        var timer = try Timer.start();
        for (0..config.ops_per_sample) |_| {
            std.mem.doNotOptimizeAway(map.getPtr(lookup_keys[lookup_idx]));
            lookup_idx += 1;
        }
        sample.* = timer.read();
    }
    const result = computeStats(&samples, config.ops_per_sample);
    printResult("ShitMap getPtr() mixed hits/misses", result);
}

// AutoHashMap baselines

fn benchGetRandomAutoHashMap(allocator: std.mem.Allocator) !void {
    const config = RunConfig{};
    const map_size: usize = 1_000_000;
    const total_lookups = (config.warmup_samples + config.samples) * config.ops_per_sample;
    const prealloc_size = std.math.ceilPowerOfTwo(usize, map_size * 2) catch unreachable;

    std.debug.print("\n--- Random Access get() ---\n", .{});

    const keys = try allocator.alloc(u64, map_size);
    defer allocator.free(keys);
    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    const random = prng.random();
    for (keys) |*k| {
        k.* = random.int(u64);
    }

    const lookup_indices = try allocator.alloc(usize, total_lookups);
    defer allocator.free(lookup_indices);
    for (lookup_indices) |*idx| {
        idx.* = random.intRangeLessThan(usize, 0, map_size);
    }

    var samples: [config.samples]u64 = undefined;
    var lookup_idx: usize = 0;
    var map = std.AutoHashMap(u64, u64).init(allocator);
    defer map.deinit();
    try map.ensureTotalCapacity(@intCast(prealloc_size));

    for (keys) |key| {
        try map.put(key, key);
    }

    for (0..config.warmup_samples) |_| {
        for (0..config.ops_per_sample) |_| {
            std.mem.doNotOptimizeAway(map.get(keys[lookup_indices[lookup_idx]]));
            lookup_idx += 1;
        }
    }

    for (&samples) |*sample| {
        var timer = try Timer.start();
        for (0..config.ops_per_sample) |_| {
            std.mem.doNotOptimizeAway(map.get(keys[lookup_indices[lookup_idx]]));
            lookup_idx += 1;
        }
        sample.* = timer.read();
    }
    const result = computeStats(&samples, config.ops_per_sample);
    printResult("AutoHashMap random access get()", result);
}

fn benchGetMissesAutoHashMap(allocator: std.mem.Allocator) !void {
    const config = RunConfig{};
    const map_size: usize = 1_000_000;
    const total_lookups = (config.warmup_samples + config.samples) * config.ops_per_sample;
    const prealloc_size = std.math.ceilPowerOfTwo(usize, map_size * 2) catch unreachable;

    std.debug.print("\n--- get() All Misses ---\n", .{});

    const keys = try allocator.alloc(u64, map_size);
    defer allocator.free(keys);
    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    const random = prng.random();
    for (keys) |*k| {
        k.* = random.int(u64) | 1;
    }

    const miss_keys = try allocator.alloc(u64, total_lookups);
    defer allocator.free(miss_keys);
    for (miss_keys) |*k| {
        k.* = random.int(u64) & ~@as(u64, 1);
    }

    var samples: [config.samples]u64 = undefined;
    var lookup_idx: usize = 0;
    var map = std.AutoHashMap(u64, u64).init(allocator);
    defer map.deinit();
    try map.ensureTotalCapacity(@intCast(prealloc_size));

    for (keys) |key| {
        try map.put(key, key);
    }

    for (0..config.warmup_samples) |_| {
        for (0..config.ops_per_sample) |_| {
            std.mem.doNotOptimizeAway(map.get(miss_keys[lookup_idx]));
            lookup_idx += 1;
        }
    }

    for (&samples) |*sample| {
        var timer = try Timer.start();
        for (0..config.ops_per_sample) |_| {
            std.mem.doNotOptimizeAway(map.get(miss_keys[lookup_idx]));
            lookup_idx += 1;
        }
        sample.* = timer.read();
    }
    const result = computeStats(&samples, config.ops_per_sample);
    printResult("AutoHashMap get() all misses", result);
}

fn benchGetMixedAutoHashMap(allocator: std.mem.Allocator) !void {
    const config = RunConfig{};
    const map_size: usize = 1_000_000;
    const total_lookups = (config.warmup_samples + config.samples) * config.ops_per_sample;
    const prealloc_size = std.math.ceilPowerOfTwo(usize, map_size * 2) catch unreachable;

    std.debug.print("\n--- get() Mixed Hits/Misses 50%% ---\n", .{});

    const keys = try allocator.alloc(u64, map_size);
    defer allocator.free(keys);
    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    const random = prng.random();
    for (keys) |*k| {
        k.* = random.int(u64) | 1;
    }

    const lookup_keys = try allocator.alloc(u64, total_lookups);
    defer allocator.free(lookup_keys);
    for (lookup_keys) |*k| {
        if (random.boolean()) {
            k.* = keys[random.intRangeLessThan(usize, 0, map_size)];
        } else {
            k.* = random.int(u64) & ~@as(u64, 1);
        }
    }

    var samples: [config.samples]u64 = undefined;
    var lookup_idx: usize = 0;
    var map = std.AutoHashMap(u64, u64).init(allocator);
    defer map.deinit();
    try map.ensureTotalCapacity(@intCast(prealloc_size));

    for (keys) |key| {
        try map.put(key, key);
    }

    for (0..config.warmup_samples) |_| {
        for (0..config.ops_per_sample) |_| {
            std.mem.doNotOptimizeAway(map.get(lookup_keys[lookup_idx]));
            lookup_idx += 1;
        }
    }

    for (&samples) |*sample| {
        var timer = try Timer.start();
        for (0..config.ops_per_sample) |_| {
            std.mem.doNotOptimizeAway(map.get(lookup_keys[lookup_idx]));
            lookup_idx += 1;
        }
        sample.* = timer.read();
    }
    const result = computeStats(&samples, config.ops_per_sample);
    printResult("AutoHashMap get() mixed hits/misses", result);
}

const BenchmarkResult = struct {
    mean_ns: f64,
    median_ns: f64,
    std_dev_ns: f64,
    min_ns: f64,
    max_ns: f64,
    ops_per_sample: usize,
    outlier_count: usize,
    sample_count: usize,
};

fn printResult(name: []const u8, result: BenchmarkResult) void {
    const ops_per_sec = 1_000_000_000.0 / result.mean_ns;
    std.debug.print("{s}\n", .{name});
    std.debug.print("  Mean:     {d:.1} ns/op  ± {d:.1} ns  ({d:.1}M ops/sec)\n", .{
        result.mean_ns,
        result.std_dev_ns,
        ops_per_sec / 1_000_000.0,
    });
    std.debug.print("  Median:   {d:.1} ns/op\n", .{result.median_ns});
    std.debug.print("  Range:    [{d:.1} ns ... {d:.1} ns]\n", .{ result.min_ns, result.max_ns });
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

    var variance: f64 = 0.0;
    for (samples) |s| {
        const diff = @as(f64, @floatFromInt(s)) - mean;
        variance += diff * diff;
    }
    const std_dev = @sqrt(variance / @as(f64, @floatFromInt(samples.len)));

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
