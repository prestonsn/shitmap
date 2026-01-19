const std = @import("std");

pub const ShitMapConfig = struct {
    growable: bool = true,
    load_factor: f32 = 0.80,
    prefetch: bool = false,
    simd_get: bool = false,
};

pub fn ShitMap(comptime K: type, comptime V: type, comptime config: ShitMapConfig) type {
    return struct {
        const Self = @This();

        const EMPTY: u64 = 0;
        const TOMBSTONE: u64 = 1;
        const HASH_MASK: u64 = 1 << 63;

        /// Vectorization stuff.
        /// TODO: set values for these at comptime.
        const VEC_SIZE = 8;
        const HashVec = @Vector(VEC_SIZE, u64);

        const slot_alignment = std.mem.Alignment.@"64";
        slots: []align(slot_alignment.toByteUnits()) Slot,
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

            const slots = try allocator.alignedAlloc(Slot, slot_alignment, capacity + VEC_SIZE - 1);
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

        fn getPtrSimd(self: *Self, key: K) ?*V {
            const hash = hashKey(key);
            const mask = self.capacity - 1;
            const start_idx: usize = @intCast(hash & mask);

            // Splat the target hash across lanes.
            const target_hash: HashVec = @splat(hash);
            const empty_vec: HashVec = @splat(EMPTY);

            var idx = start_idx;
            var slots_checked: usize = 0;

            while (slots_checked < self.capacity) {
                // How many slots remain before we hit capacity (and padding)?
                const slots_until_wrap = self.capacity - idx;

                if (slots_until_wrap >= VEC_SIZE) {
                    // Fast path: can load full vector without hitting padding
                    const slot_ptr: [*]const u64 = @ptrCast(self.slots.ptr + idx);
                    const slot_hashes: HashVec = slot_ptr[0..VEC_SIZE].*;

                    const hash_matches = target_hash == slot_hashes;
                    const empty_slots = empty_vec == slot_hashes;

                    const match_bits: u8 = @bitCast(hash_matches);
                    const empty_bits: u8 = @bitCast(empty_slots);

                    // Find first empty slot position (8 if none)
                    const first_empty: u4 = if (empty_bits != 0) @ctz(empty_bits) else 8;

                    // Check all hash matches that come BEFORE the first empty slot
                    var remaining = match_bits;
                    while (remaining != 0) {
                        const bit_idx: u4 = @ctz(remaining);
                        if (bit_idx >= first_empty) break;

                        const match_idx = idx + bit_idx;
                        if (keysEqual(self.entries[match_idx].key, key)) {
                            return &self.entries[match_idx].value;
                        }
                        remaining &= remaining - 1;
                    }

                    // If we found an empty slot, probe chain ends
                    if (empty_bits != 0) {
                        return null;
                    }

                    idx = (idx + VEC_SIZE) & mask;
                    slots_checked += VEC_SIZE;
                } else {
                    // Slow path: near end of array, check one at a time until wrap
                    const slot = &self.slots[idx];
                    if (slot.hash == EMPTY) {
                        return null;
                    }
                    if (slot.hash == hash and keysEqual(self.entries[idx].key, key)) {
                        return &self.entries[idx].value;
                    }
                    idx = (idx + 1) & mask;
                    slots_checked += 1;
                }
            }

            return null;
        }

        pub fn getPtr(self: *Self, key: K) ?*V {
            if (comptime config.simd_get) {
                return self.getPtrSimd(key);
            }

            const hash = hashKey(key);
            const mask = self.capacity - 1;
            const start_idx: usize = @intCast(hash & mask);

            var idx = start_idx;
            while (true) {
                const next_idx = (idx + 1) & mask;

                if (comptime config.prefetch) {
                    @prefetch(&self.slots[next_idx], .{ .rw = .read, .cache = .data, .locality = 3 });
                }

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

                if (comptime config.prefetch) {
                    @prefetch(&self.slots[next_idx], .{ .rw = .read, .cache = .data, .locality = 3 });
                }

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
                    try self.growImpl();
                }
            }

            const hash = hashKey(key);
            const mask = self.capacity - 1;
            const start_idx: usize = @intCast(hash & mask);

            var idx = start_idx;
            while (true) {
                const next_idx = (idx + 1) & mask;

                if (comptime config.prefetch) {
                    @prefetch(&self.slots[next_idx], .{ .rw = .read, .cache = .data, .locality = 3 });
                    @prefetch(&self.entries[next_idx], .{ .rw = .write, .cache = .data, .locality = 3 });
                }

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

        fn growImpl(self: *Self) Error!void {
            const new_capacity = 2 * self.capacity;
            const old_slots = self.slots;
            const old_entries = self.entries;

            const new_slots = self.allocator.alignedAlloc(Slot, slot_alignment, new_capacity + VEC_SIZE - 1) catch return error.OutOfMemory;
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
