const std = @import("std");

pub const ShitMapConfig = struct {
    growable: bool = true,
    load_factor: f32 = 0.80,
};

pub fn ShitMap(comptime K: type, comptime V: type, comptime config: ShitMapConfig) type {
    return struct {
        const Self = @This();

        const EMPTY: u64 = 0;
        const TOMBSTONE: u64 = 1;
        const HASH_MASK: u64 = 1 << 63;

        slots: []Slot,
        entries: []Entry,
        count: usize,
        capacity: usize,
        allocator: std.mem.Allocator,

        const Slot: type = struct { hash: u64 };

        const Entry = struct { key: K, value: V };

        pub const Error = error{ MapFull, OutOfMemory, CapacityNotPowerOfTwo };

        inline fn isPowerOfTwo(n: usize) bool {
            return n > 0 and (n & (n - 1)) == 0;
        }

        pub fn init(allocator: std.mem.Allocator, capacity: usize) Error!Self {
            if (!isPowerOfTwo(capacity)) {
                return error.CapacityNotPowerOfTwo;
            }

            const slots = try allocator.alloc(Slot, capacity);
            @memset(slots, Slot{ .hash = EMPTY });

            const entries = try allocator.alloc(Entry, capacity);
            @memset(entries, Entry{ .key = undefined, .value = undefined });

            return Self{
                .slots = slots,
                .entries = entries,
                .count = 0,
                .capacity = capacity,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.slots);
            self.allocator.free(self.entries);
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

        pub fn get(self: *Self, key: K) ?*V {
            const hash = hashKey(key);
            const mask = self.capacity - 1;
            const start_idx: usize = @intCast(hash & mask);

            var idx = start_idx;
            while (true) {
                const next_idx = (idx + 1) & mask;
                // @prefetch(&self.slots[next_idx], .{ .rw = .read, .cache = .data, .locality = 3 });

                const slot = &self.slots[idx];
                if (slot.hash == EMPTY) {
                    return null;
                }

                if (slot.hash == hash and keysEqual(self.entries[idx].key, key)) {
                    return &self.entries[idx].value;
                }

                idx = next_idx;
                if (idx == start_idx) {
                    return null;
                }
            }
        }

        pub fn remove(self: *Self, key: K) ?V {
            const hash = hashKey(key);
            const mask = self.capacity - 1;
            const start_idx: usize = @intCast(hash & mask);

            var idx = start_idx;
            while (true) {
                const next_idx = (idx + 1) & mask;
                @prefetch(&self.slots[next_idx], .{ .rw = .read, .cache = .data, .locality = 3 });

                const slot = &self.slots[idx];

                if (slot.hash == EMPTY) {
                    return null;
                }

                if (slot.hash == hash and keysEqual(self.entries[idx].key, key)) {
                    const value = self.entries[idx].value;
                    slot.hash = TOMBSTONE;
                    self.count -= 1;

                    return value;
                }

                idx = next_idx;
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
                @prefetch(&self.slots[next_idx], .{ .rw = .read, .cache = .data, .locality = 3 });
                @prefetch(&self.entries[next_idx], .{ .rw = .write, .cache = .data, .locality = 3 });

                const slot = &self.slots[idx];

                if (slot.hash <= TOMBSTONE) {
                    // Slot is empty or tombstone, so we insert.
                    slot.hash = hash;
                    self.entries[idx] = .{ .key = key, .value = value };
                    self.count += 1;
                    return;
                }

                // Key exists, set new value.
                if (slot.hash == hash and keysEqual(self.entries[idx].key, key)) {
                    // Would be nice to return old value.
                    self.entries[idx].value = value;
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
            const old_entries = self.entries;

            const new_slots = self.allocator.alloc(Slot, new_capacity) catch return error.OutOfMemory;
            const new_entries = self.allocator.alloc(Entry, new_capacity) catch return error.OutOfMemory;

            @memset(new_slots, Slot{ .hash = EMPTY });
            @memset(new_entries, Entry{ .key = undefined, .value = undefined });

            self.slots = new_slots;
            self.entries = new_entries;
            self.capacity = new_capacity;
            self.count = 0;

            // Re-insert all entries (skip EMPTY and TOMBSTONE) in their new indexes.
            for (old_slots, 0..) |slot, old_idx| {
                if (slot.hash > TOMBSTONE) {
                    self.insertExistingEntry(slot.hash, old_entries[old_idx]);
                }
            }

            self.allocator.free(old_slots);
            self.allocator.free(old_entries);
        }

        fn insertExistingEntry(self: *Self, hash: u64, entry: Entry) void {
            const mask = self.capacity - 1;
            var idx: usize = @intCast(hash & mask);
            while (true) {
                const slot = &self.slots[idx];
                if (slot.hash == EMPTY) {
                    slot.hash = hash;
                    self.entries[idx] = entry;
                    self.count += 1;
                    return;
                }
                idx = (idx + 1) & mask;
            }
        }
    };
}
