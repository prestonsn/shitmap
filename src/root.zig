const std = @import("std");

pub const ShitMapConfig = struct {
    growable: bool = true,
    load_factor: f32 = 0.75,
};

pub fn ShitMap(comptime K: type, comptime V: type, comptime config: ShitMapConfig) type {
    return struct {
        const Self = @This();

        const EMPTY: u64 = 0;
        const TOMBSTONE: u64 = 1;
        const HASH_MASK: u64 = 1 << 63;

        slots: []Slot,
        count: usize,
        capacity: usize,
        allocator: std.mem.Allocator,

        const Slot: type = struct {
            hash: u64,
            entry: ?*Entry,
        };

        const Entry = struct { key: K, value: V };

        pub const Error = error{ MapFull, OutOfMemory, CapacityNotPowerOfTwo };

        inline fn isPowerOfTwo(n: usize) bool {
            return n > 0 and (n & (n - 1)) == 0;
        }

        pub fn init(allocator: std.mem.Allocator, capacity: usize) Error!Self {
            if (!isPowerOfTwo(capacity)) {
                return error.CapacityNotPowerOfTwo;
            }

            const slots = allocator.alloc(Slot, capacity) catch return error.OutOfMemory;
            @memset(slots, Slot{ .hash = EMPTY, .entry = null });

            return Self{
                .slots = slots,
                .count = 0,
                .capacity = capacity,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            // Free all entries
            for (self.slots) |slot| {
                if (slot.entry) |entry| {
                    self.allocator.destroy(entry);
                }
            }
            // Free slots array
            self.allocator.free(self.slots);
        }

        inline fn hashKey(key: K) u64 {
            const has_hash = comptime switch (@typeInfo(K)) {
                .@"struct", .@"enum", .@"union", .@"opaque" => @hasDecl(K, "hash"),
                else => false,
            };

            // branch is removed since has_has is comptime, pretty kewl
            const h = if (has_hash)
                key.hash()
            else
                std.hash.Wyhash.hash(0, std.mem.asBytes(&key));

            return h | HASH_MASK;
        }

        inline fn keysEqual(a: K, b: K) bool {
            const has_eql = comptime switch (@typeInfo(K)) {
                .@"struct", .@"enum", .@"union", .@"opaque" => @hasDecl(K, "eql"),
                else => false,
            };

            return if (has_eql)
                a.eql(b)
            else
                std.meta.eql(a, b);
        }

        pub inline fn get(self: *Self, key: K) ?*V {
            const hash = hashKey(key);
            const mask = self.capacity - 1;
            const start_idx: usize = @intCast(hash & mask);

            var idx = start_idx;
            while (true) {
                const slot = &self.slots[idx];

                if (slot.hash == EMPTY) {
                    return null;
                }

                if (slot.hash == hash and keysEqual(slot.entry.?.key, key)) {
                    return &slot.entry.?.value;
                }

                // TODO @prefetch next slot here for cache optimization? wtf is @prefetch
                idx = (idx + 1) & mask;

                if (idx == start_idx) {
                    return null;
                }
            }
        }

        pub inline fn remove(self: *Self, key: K) ?V {
            const hash = hashKey(key);
            const mask = self.capacity - 1;
            const start_idx: usize = @intCast(hash & mask);

            var idx = start_idx;
            while (true) {
                const slot = &self.slots[idx];

                if (slot.hash == EMPTY) {
                    return null;
                }

                if (slot.hash == hash and keysEqual(slot.entry.?.key, key)) {
                    const value = slot.entry.?.value;
                    self.allocator.destroy(slot.entry.?);
                    slot.hash = TOMBSTONE;
                    slot.entry = null;
                    self.count -= 1;
                    return value;
                }

                // TODO @prefetch next slot here for cache optimization? wtf is @prefetch
                idx = (idx + 1) & mask;
                if (idx == start_idx) return null;
            }
        }

        pub inline fn insert(self: *Self, key: K, value: V) Error!void {
            if (comptime config.growable) {
                const load_den = 100;
                const load_num = comptime @as(u64, @intFromFloat(config.load_factor * load_den));
                if (self.count * load_den > self.capacity * load_num) {
                    try self.grow();
                }
            }

            const hash = hashKey(key);
            const mask = self.capacity - 1;
            const start_idx: usize = @intCast(hash & mask);

            var idx = start_idx;
            while (true) {
                const next_idx = (idx + 1) & mask;
                @prefetch(&self.slots[next_idx], .{ .rw = .read, .locality = 3 });

                const slot = &self.slots[idx];

                if (slot.hash == EMPTY or slot.hash == TOMBSTONE) {
                    // We empty, so we insert.
                    const entry = self.allocator.create(Entry) catch return error.OutOfMemory;
                    entry.* = .{ .key = key, .value = value };
                    slot.hash = hash;
                    slot.entry = entry;
                    self.count += 1;

                    return;
                }

                // Key exists, set new value.
                if (slot.hash == hash and keysEqual(slot.entry.?.key, key)) {
                    // Would be nice to return old value.
                    slot.entry.?.value = value;
                    return;
                }

                idx = next_idx;
                if (idx == start_idx) {
                    return Error.MapFull;
                }
            }
        }

        pub const grow = if (config.growable) growImpl else @compileError("Map is not growable");

        fn growImpl(self: *Self) Error!void {
            const new_capacity = 2 * self.capacity;
            const old_slots = self.slots;

            const new_slots = self.allocator.alloc(Slot, new_capacity) catch return error.OutOfMemory;
            @memset(new_slots, Slot{ .hash = EMPTY, .entry = null });

            self.slots = new_slots;
            self.capacity = new_capacity;
            self.count = 0;

            // Re-insert all entries (skip EMPTY and TOMBSTONE) in their new indexes.
            for (old_slots) |slot| {
                if (slot.hash != EMPTY and slot.hash != TOMBSTONE) {
                    // Re-insert using existing Entry pointer (no new allocation needed!)
                    self.insertExistingEntry(slot.hash, slot.entry.?);
                }
            }

            // Free old slots array (but NOT the entries - they're reused)
            self.allocator.free(old_slots);
        }

        fn insertExistingEntry(self: *Self, hash: u64, entry: *Entry) void {
            const mask = self.capacity - 1;
            var idx: usize = @intCast(hash & mask);
            while (true) {
                const slot = &self.slots[idx];
                if (slot.hash == EMPTY) {
                    slot.hash = hash;
                    slot.entry = entry;
                    self.count += 1;
                    return;
                }
                idx = (idx + 1) & mask;
            }
        }
    };
}
