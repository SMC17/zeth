const std = @import("std");
const types = @import("types");
const crypto = @import("crypto");
const rlp = @import("rlp");

/// State database that manages account states and storage
pub const StateDB = struct {
    allocator: std.mem.Allocator,
    accounts: std.AutoHashMap(types.Address, types.Account),
    storage: std.AutoHashMap(StorageKey, types.U256),
    code: std.AutoHashMap(types.Address, []u8),
    journal: std.ArrayList(JournalEntry),
    checkpoints: std.ArrayList(usize),

    pub fn init(allocator: std.mem.Allocator) StateDB {
        return StateDB{
            .allocator = allocator,
            .accounts = std.AutoHashMap(types.Address, types.Account).init(allocator),
            .storage = std.AutoHashMap(StorageKey, types.U256).init(allocator),
            .code = std.AutoHashMap(types.Address, []u8).init(allocator),
            .journal = std.ArrayList(JournalEntry).init(allocator),
            .checkpoints = std.ArrayList(usize).init(allocator),
        };
    }

    pub fn deinit(self: *StateDB) void {
        for (self.journal.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.journal.deinit();
        self.checkpoints.deinit();
        var code_iter = self.code.iterator();
        while (code_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.code.deinit();
        self.accounts.deinit();
        self.storage.deinit();
    }

    pub fn getAccount(self: *StateDB, address: types.Address) !types.Account {
        return self.accounts.get(address) orelse types.Account.empty();
    }

    pub fn setAccount(self: *StateDB, address: types.Address, account: types.Account) !void {
        try self.recordAccountChange(address);
        try self.setAccountNoJournal(address, account);
    }

    pub fn getBalance(self: *StateDB, address: types.Address) !types.U256 {
        const account = try self.getAccount(address);
        return account.balance;
    }

    pub fn setBalance(self: *StateDB, address: types.Address, balance: types.U256) !void {
        var account = try self.getAccount(address);
        account.balance = balance;
        try self.setAccount(address, account);
    }

    pub fn getNonce(self: *StateDB, address: types.Address) !u64 {
        const account = try self.getAccount(address);
        return account.nonce;
    }

    pub fn incrementNonce(self: *StateDB, address: types.Address) !void {
        var account = try self.getAccount(address);
        account.nonce += 1;
        try self.setAccount(address, account);
    }

    pub fn getStorage(self: *StateDB, address: types.Address, key: types.U256) !types.U256 {
        const storage_key = StorageKey{ .address = address, .key = key };
        return self.storage.get(storage_key) orelse types.U256.zero();
    }

    pub fn setStorage(self: *StateDB, address: types.Address, key: types.U256, value: types.U256) !void {
        const storage_key = StorageKey{ .address = address, .key = key };
        try self.recordStorageChange(storage_key);
        try self.storage.put(storage_key, value);
    }

    pub fn exists(self: *StateDB, address: types.Address) bool {
        return self.accounts.contains(address);
    }

    pub fn createAccount(self: *StateDB, address: types.Address) !void {
        if (!self.exists(address)) {
            try self.setAccount(address, types.Account.empty());
        }
    }

    pub fn getCode(self: *StateDB, address: types.Address) []const u8 {
        return self.code.get(address) orelse &[_]u8{};
    }

    pub fn setCode(self: *StateDB, address: types.Address, code_bytes: []const u8) !void {
        try self.recordCodeChange(address);
        try self.recordAccountChange(address);
        try self.setCodeNoJournal(address, code_bytes);
    }

    pub fn destroyAccount(self: *StateDB, address: types.Address) !void {
        try self.recordAccountChange(address);
        try self.recordCodeChange(address);

        var storage_keys = std.ArrayList(StorageKey).init(self.allocator);
        defer storage_keys.deinit();

        var it = self.storage.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.address.eql(address)) {
                try storage_keys.append(entry.key_ptr.*);
            }
        }
        for (storage_keys.items) |key| {
            try self.recordStorageChange(key);
            _ = self.storage.remove(key);
        }

        self.removeCodeNoJournal(address);
        _ = self.accounts.remove(address);
    }

    pub fn computeStorageRoot(self: *StateDB, address: types.Address) !types.Hash {
        var trie = Trie.init(self.allocator);
        defer trie.deinit();

        var entries = std.ArrayList(StorageEntry).init(self.allocator);
        defer entries.deinit();

        var it = self.storage.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.address.eql(address)) {
                try entries.append(.{
                    .key = entry.key_ptr.key,
                    .value = entry.value_ptr.*,
                });
            }
        }

        std.mem.sort(StorageEntry, entries.items, {}, storageEntryLessThan);

        for (entries.items) |entry| {
            const key_bytes = entry.key.toBytes();
            const value_bytes = try encodeU256Rlp(self.allocator, entry.value);
            defer self.allocator.free(value_bytes);
            try trie.insert(&key_bytes, value_bytes);
        }

        return trie.hash();
    }

    pub fn computeStateRoot(self: *StateDB) !types.Hash {
        var trie = Trie.init(self.allocator);
        defer trie.deinit();

        var addresses = std.ArrayList(types.Address).init(self.allocator);
        defer addresses.deinit();

        var it = self.accounts.iterator();
        while (it.next()) |entry| {
            try addresses.append(entry.key_ptr.*);
        }
        std.mem.sort(types.Address, addresses.items, {}, addressLessThan);

        for (addresses.items) |address| {
            var account = try self.getAccount(address);
            account.storage_root = try self.computeStorageRoot(address);
            const account_bytes = try encodeAccountRlp(self.allocator, account);
            defer self.allocator.free(account_bytes);
            try trie.insert(&address.bytes, account_bytes);
        }

        return trie.hash();
    }

    pub fn snapshot(self: *StateDB) !usize {
        try self.checkpoints.append(self.journal.items.len);
        return self.checkpoints.items.len - 1;
    }

    pub fn commitSnapshot(self: *StateDB, snapshot_id: usize) !void {
        if (snapshot_id + 1 != self.checkpoints.items.len) return error.InvalidSnapshot;
        _ = self.checkpoints.pop();
        if (self.checkpoints.items.len == 0) {
            self.clearJournal();
        }
    }

    pub fn revertToSnapshot(self: *StateDB, snapshot_id: usize) !void {
        if (snapshot_id + 1 != self.checkpoints.items.len) return error.InvalidSnapshot;

        const checkpoint = self.checkpoints.pop().?;
        while (self.journal.items.len > checkpoint) {
            var entry = self.journal.pop().?;
            defer entry.deinit(self.allocator);
            switch (entry) {
                .account => |change| {
                    if (change.previous) |prev| {
                        try self.setAccountNoJournal(change.address, prev);
                    } else {
                        _ = self.accounts.remove(change.address);
                    }
                },
                .storage => |change| {
                    if (change.previous) |prev| {
                        try self.storage.put(change.key, prev);
                    } else {
                        _ = self.storage.remove(change.key);
                    }
                },
                .code => |change| {
                    if (change.previous) |prev| {
                        try self.setCodeNoJournal(change.address, prev);
                    } else {
                        self.removeCodeNoJournal(change.address);
                        var account = try self.getAccount(change.address);
                        account.code_hash = types.Hash.zero;
                        try self.setAccountNoJournal(change.address, account);
                    }
                },
            }
        }
    }

    fn clearJournal(self: *StateDB) void {
        for (self.journal.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.journal.clearRetainingCapacity();
    }

    fn recordAccountChange(self: *StateDB, address: types.Address) !void {
        if (self.checkpoints.items.len == 0) return;
        try self.journal.append(.{
            .account = .{
                .address = address,
                .previous = self.accounts.get(address),
            },
        });
    }

    fn recordStorageChange(self: *StateDB, key: StorageKey) !void {
        if (self.checkpoints.items.len == 0) return;
        try self.journal.append(.{
            .storage = .{
                .key = key,
                .previous = self.storage.get(key),
            },
        });
    }

    fn recordCodeChange(self: *StateDB, address: types.Address) !void {
        if (self.checkpoints.items.len == 0) return;
        const previous = if (self.code.get(address)) |existing|
            try self.allocator.dupe(u8, existing)
        else
            null;
        errdefer if (previous) |bytes| self.allocator.free(bytes);
        try self.journal.append(.{
            .code = .{
                .address = address,
                .previous = previous,
            },
        });
    }

    fn setAccountNoJournal(self: *StateDB, address: types.Address, account: types.Account) !void {
        try self.accounts.put(address, account);
    }

    fn removeCodeNoJournal(self: *StateDB, address: types.Address) void {
        if (self.code.fetchRemove(address)) |old| {
            self.allocator.free(old.value);
        }
    }

    fn setCodeNoJournal(self: *StateDB, address: types.Address, code_bytes: []const u8) !void {
        const new_code = try self.allocator.dupe(u8, code_bytes);
        errdefer self.allocator.free(new_code);

        self.removeCodeNoJournal(address);
        try self.code.put(address, new_code);

        var account = try self.getAccount(address);
        if (new_code.len == 0) {
            account.code_hash = types.Hash.zero;
        } else {
            var hash: [32]u8 = undefined;
            crypto.keccak256(new_code, &hash);
            account.code_hash = types.Hash{ .bytes = hash };
        }
        try self.setAccountNoJournal(address, account);
    }
};

const JournalEntry = union(enum) {
    account: struct {
        address: types.Address,
        previous: ?types.Account,
    },
    storage: struct {
        key: StorageKey,
        previous: ?types.U256,
    },
    code: struct {
        address: types.Address,
        previous: ?[]u8,
    },

    fn deinit(self: *JournalEntry, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .code => |change| if (change.previous) |bytes| allocator.free(bytes),
            else => {},
        }
    }
};

const StorageEntry = struct {
    key: types.U256,
    value: types.U256,
};

fn deinitCodeMap(map: *std.AutoHashMap(types.Address, []u8), allocator: std.mem.Allocator) void {
    var code_iter = map.iterator();
    while (code_iter.next()) |entry| {
        allocator.free(entry.value_ptr.*);
    }
    map.deinit();
}

const StorageKey = struct {
    address: types.Address,
    key: types.U256,

    pub fn hash(self: StorageKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(&self.address.bytes);
        hasher.update(&self.key.toBytes());
        return hasher.final();
    }

    pub fn eql(self: StorageKey, other: StorageKey) bool {
        return self.address.eql(other.address) and
            std.mem.eql(u8, &self.key.toBytes(), &other.key.toBytes());
    }
};

/// Merkle Patricia Trie implementation
pub const Trie = struct {
    root: ?*Node,
    allocator: std.mem.Allocator,

    const Node = struct {
        children: [16]?*Node,
        value: ?[]const u8,

        fn init(allocator: std.mem.Allocator) !*Node {
            const node = try allocator.create(Node);
            node.* = Node{
                .children = [_]?*Node{null} ** 16,
                .value = null,
            };
            return node;
        }

        fn deinit(self: *Node, allocator: std.mem.Allocator) void {
            for (self.children) |child| {
                if (child) |c| {
                    c.deinit(allocator);
                    allocator.destroy(c);
                }
            }
            if (self.value) |v| {
                allocator.free(v);
            }
        }
    };

    pub fn init(allocator: std.mem.Allocator) Trie {
        return Trie{
            .root = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Trie) void {
        if (self.root) |root| {
            root.deinit(self.allocator);
            self.allocator.destroy(root);
        }
    }

    pub fn insert(self: *Trie, key: []const u8, value: []const u8) !void {
        if (self.root == null) {
            self.root = try Node.init(self.allocator);
        }

        var current = self.root.?;
        for (key) |byte| {
            const high_nibble = byte >> 4;
            const low_nibble = byte & 0x0F;

            for ([_]u8{ high_nibble, low_nibble }) |nibble| {
                if (current.children[nibble] == null) {
                    current.children[nibble] = try Node.init(self.allocator);
                }
                current = current.children[nibble].?;
            }
        }

        if (current.value) |old_value| {
            self.allocator.free(old_value);
        }

        const new_value = try self.allocator.alloc(u8, value.len);
        @memcpy(new_value, value);
        current.value = new_value;
    }

    pub fn get(self: *Trie, key: []const u8) ?[]const u8 {
        var current = self.root orelse return null;

        for (key) |byte| {
            const high_nibble = byte >> 4;
            const low_nibble = byte & 0x0F;

            for ([_]u8{ high_nibble, low_nibble }) |nibble| {
                current = current.children[nibble] orelse return null;
            }
        }

        return current.value;
    }

    pub fn hash(self: *Trie) types.Hash {
        if (self.root) |root| {
            return self.hashNode(root);
        }
        return types.Hash.zero;
    }

    fn hashNode(self: *Trie, node: *Node) types.Hash {
        var encoded = std.ArrayList(u8).init(self.allocator);
        defer encoded.deinit();

        for (node.children) |child| {
            if (child) |c| {
                const child_hash = self.hashNode(c);
                encoded.append(1) catch unreachable;
                encoded.appendSlice(&child_hash.bytes) catch unreachable;
            } else {
                encoded.append(0) catch unreachable;
            }
        }

        if (node.value) |value| {
            encoded.append(1) catch unreachable;
            var len_buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &len_buf, value.len, .big);
            encoded.appendSlice(&len_buf) catch unreachable;
            encoded.appendSlice(value) catch unreachable;
        } else {
            encoded.append(0) catch unreachable;
        }

        var hash_bytes: [32]u8 = undefined;
        crypto.keccak256(encoded.items, &hash_bytes);
        return types.Hash{ .bytes = hash_bytes };
    }
};

fn storageEntryLessThan(_: void, a: StorageEntry, b: StorageEntry) bool {
    const a_bytes = a.key.toBytes();
    const b_bytes = b.key.toBytes();
    return std.mem.order(u8, &a_bytes, &b_bytes) == .lt;
}

fn addressLessThan(_: void, a: types.Address, b: types.Address) bool {
    return std.mem.order(u8, &a.bytes, &b.bytes) == .lt;
}

fn encodeU256Rlp(allocator: std.mem.Allocator, value: types.U256) ![]u8 {
    const raw = value.toBytes();
    var first_non_zero: usize = 0;
    while (first_non_zero < raw.len and raw[first_non_zero] == 0) : (first_non_zero += 1) {}
    const minimal = if (first_non_zero == raw.len) &[_]u8{} else raw[first_non_zero..];
    return rlp.encodeBytes(minimal, allocator);
}

fn encodeU64Rlp(allocator: std.mem.Allocator, value: u64) ![]u8 {
    return rlp.encodeU64(value, allocator);
}

fn encodeAccountRlp(allocator: std.mem.Allocator, account: types.Account) ![]u8 {
    const nonce = try encodeU64Rlp(allocator, account.nonce);
    defer allocator.free(nonce);
    const balance = try encodeU256Rlp(allocator, account.balance);
    defer allocator.free(balance);
    const storage_root = try rlp.encodeBytes(&account.storage_root.bytes, allocator);
    defer allocator.free(storage_root);
    const code_hash = try rlp.encodeBytes(&account.code_hash.bytes, allocator);
    defer allocator.free(code_hash);
    const items = [_][]const u8{ nonce, balance, storage_root, code_hash };
    return rlp.encodeList(&items, allocator);
}

test "StateDB account operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state = StateDB.init(allocator);
    defer state.deinit();

    const addr = types.Address.zero;

    // Initially should not exist
    try testing.expect(!state.exists(addr));

    // Create account
    try state.createAccount(addr);
    try testing.expect(state.exists(addr));

    // Check initial balance is zero
    const balance = try state.getBalance(addr);
    try testing.expect(balance.isZero());

    // Set balance
    const new_balance = types.U256.fromU64(1000);
    try state.setBalance(addr, new_balance);

    const retrieved_balance = try state.getBalance(addr);
    try testing.expectEqual(@as(u64, 1000), retrieved_balance.limbs[0]);
}

test "StateDB storage operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state = StateDB.init(allocator);
    defer state.deinit();

    const addr = types.Address.zero;
    const key = types.U256.fromU64(42);
    const value = types.U256.fromU64(1337);

    try state.setStorage(addr, key, value);

    const retrieved = try state.getStorage(addr, key);
    try testing.expectEqual(@as(u64, 1337), retrieved.limbs[0]);
}

test "StateDB code operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state = StateDB.init(allocator);
    defer state.deinit();

    var addr = types.Address.zero;
    addr.bytes[19] = 0x01;

    const code_bytes = [_]u8{ 0x60, 0x2a, 0x00 };
    try state.setCode(addr, &code_bytes);

    const retrieved = state.getCode(addr);
    try testing.expectEqual(@as(usize, 3), retrieved.len);
    try testing.expectEqual(@as(u8, 0x60), retrieved[0]);

    const account = try state.getAccount(addr);
    try testing.expect(!account.code_hash.eql(types.Hash.zero));
}

test "StateDB destroyAccount clears account code and storage" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state = StateDB.init(allocator);
    defer state.deinit();

    var addr = types.Address.zero;
    addr.bytes[19] = 0x44;
    const key = types.U256.fromU64(7);
    const value = types.U256.fromU64(99);
    const code_bytes = [_]u8{ 0x60, 0x00, 0x00 };

    try state.createAccount(addr);
    try state.setBalance(addr, types.U256.fromU64(1234));
    try state.setStorage(addr, key, value);
    try state.setCode(addr, &code_bytes);

    try state.destroyAccount(addr);

    try testing.expect(!state.exists(addr));
    try testing.expectEqual(@as(usize, 0), state.getCode(addr).len);
    const stored = try state.getStorage(addr, key);
    try testing.expect(stored.isZero());
}

test "StateDB snapshot revert restores all state domains" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state = StateDB.init(allocator);
    defer state.deinit();

    var addr = types.Address.zero;
    addr.bytes[19] = 0x45;
    const key = types.U256.fromU64(3);

    try state.createAccount(addr);
    try state.setBalance(addr, types.U256.fromU64(10));
    try state.setStorage(addr, key, types.U256.fromU64(11));
    try state.setCode(addr, &[_]u8{ 0x60, 0x00, 0x00 });

    const sid = try state.snapshot();
    try state.setBalance(addr, types.U256.fromU64(99));
    try state.setStorage(addr, key, types.U256.fromU64(77));
    try state.destroyAccount(addr);
    try state.revertToSnapshot(sid);

    try testing.expect(state.exists(addr));
    const balance = try state.getBalance(addr);
    try testing.expectEqual(@as(u64, 10), balance.limbs[0]);
    const stored = try state.getStorage(addr, key);
    try testing.expectEqual(@as(u64, 11), stored.limbs[0]);
    try testing.expectEqual(@as(usize, 3), state.getCode(addr).len);
}

test "StateDB snapshot commit keeps changes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state = StateDB.init(allocator);
    defer state.deinit();

    var addr = types.Address.zero;
    addr.bytes[19] = 0x46;
    try state.createAccount(addr);
    try state.setBalance(addr, types.U256.fromU64(1));

    const sid = try state.snapshot();
    try state.setBalance(addr, types.U256.fromU64(2));
    try state.commitSnapshot(sid);

    const balance = try state.getBalance(addr);
    try testing.expectEqual(@as(u64, 2), balance.limbs[0]);
}

test "StateDB nested snapshot revert restores outer preimage" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state = StateDB.init(allocator);
    defer state.deinit();

    var addr = types.Address.zero;
    addr.bytes[19] = 0x47;
    const key = types.U256.fromU64(9);

    try state.createAccount(addr);
    try state.setBalance(addr, types.U256.fromU64(5));
    try state.setStorage(addr, key, types.U256.fromU64(6));

    const outer = try state.snapshot();
    try state.setBalance(addr, types.U256.fromU64(7));

    const inner = try state.snapshot();
    try state.setBalance(addr, types.U256.fromU64(8));
    try state.setStorage(addr, key, types.U256.fromU64(11));
    try state.revertToSnapshot(inner);

    try testing.expectEqual(@as(u64, 7), (try state.getBalance(addr)).limbs[0]);
    try testing.expectEqual(@as(u64, 6), (try state.getStorage(addr, key)).limbs[0]);

    try state.revertToSnapshot(outer);
    try testing.expectEqual(@as(u64, 5), (try state.getBalance(addr)).limbs[0]);
    try testing.expectEqual(@as(u64, 6), (try state.getStorage(addr, key)).limbs[0]);
}

test "StateDB nested snapshot commit preserves inner changes until outer revert" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state = StateDB.init(allocator);
    defer state.deinit();

    var addr = types.Address.zero;
    addr.bytes[19] = 0x48;

    try state.createAccount(addr);
    try state.setBalance(addr, types.U256.fromU64(1));

    const outer = try state.snapshot();
    try state.setBalance(addr, types.U256.fromU64(2));

    const inner = try state.snapshot();
    try state.setBalance(addr, types.U256.fromU64(3));
    try state.commitSnapshot(inner);

    try testing.expectEqual(@as(u64, 3), (try state.getBalance(addr)).limbs[0]);

    try state.revertToSnapshot(outer);
    try testing.expectEqual(@as(u64, 1), (try state.getBalance(addr)).limbs[0]);
}

test "StateDB repeated writes in one snapshot restore original state" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state = StateDB.init(allocator);
    defer state.deinit();

    var addr = types.Address.zero;
    addr.bytes[19] = 0x49;
    const key = types.U256.fromU64(1);

    try state.createAccount(addr);
    try state.setBalance(addr, types.U256.fromU64(10));
    try state.setStorage(addr, key, types.U256.fromU64(20));
    try state.setCode(addr, &[_]u8{ 0x60, 0x01, 0x00 });

    const sid = try state.snapshot();
    try state.setBalance(addr, types.U256.fromU64(11));
    try state.setBalance(addr, types.U256.fromU64(12));
    try state.setStorage(addr, key, types.U256.fromU64(21));
    try state.setStorage(addr, key, types.U256.fromU64(22));
    try state.setCode(addr, &[_]u8{ 0x60, 0x02, 0x00 });
    try state.setCode(addr, &[_]u8{ 0x60, 0x03, 0x00 });

    try state.revertToSnapshot(sid);

    try testing.expectEqual(@as(u64, 10), (try state.getBalance(addr)).limbs[0]);
    try testing.expectEqual(@as(u64, 20), (try state.getStorage(addr, key)).limbs[0]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x60, 0x01, 0x00 }, state.getCode(addr));
}

test "StateDB destroyAccount revert restores account code and storage" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state = StateDB.init(allocator);
    defer state.deinit();

    var addr = types.Address.zero;
    addr.bytes[19] = 0x4a;
    const key_a = types.U256.fromU64(1);
    const key_b = types.U256.fromU64(2);
    const original_code = [_]u8{ 0x60, 0xaa, 0x00 };

    try state.createAccount(addr);
    try state.setBalance(addr, types.U256.fromU64(33));
    try state.setStorage(addr, key_a, types.U256.fromU64(44));
    try state.setStorage(addr, key_b, types.U256.fromU64(55));
    try state.setCode(addr, &original_code);

    const sid = try state.snapshot();
    try state.destroyAccount(addr);
    try testing.expect(!state.exists(addr));

    try state.revertToSnapshot(sid);

    try testing.expect(state.exists(addr));
    try testing.expectEqual(@as(u64, 33), (try state.getBalance(addr)).limbs[0]);
    try testing.expectEqual(@as(u64, 44), (try state.getStorage(addr, key_a)).limbs[0]);
    try testing.expectEqual(@as(u64, 55), (try state.getStorage(addr, key_b)).limbs[0]);
    try testing.expectEqualSlices(u8, &original_code, state.getCode(addr));
}

test "StateDB storage root is deterministic regardless of insertion order" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state_a = StateDB.init(allocator);
    defer state_a.deinit();
    var state_b = StateDB.init(allocator);
    defer state_b.deinit();

    var addr = types.Address.zero;
    addr.bytes[19] = 0x51;

    const entries = [_]StorageEntry{
        .{ .key = types.U256.fromU64(3), .value = types.U256.fromU64(30) },
        .{ .key = types.U256.fromU64(1), .value = types.U256.fromU64(10) },
        .{ .key = types.U256.fromU64(2), .value = types.U256.fromU64(20) },
    };

    for (entries) |entry| {
        try state_a.setStorage(addr, entry.key, entry.value);
    }
    var i: usize = entries.len;
    while (i > 0) {
        i -= 1;
        const entry = entries[i];
        try state_b.setStorage(addr, entry.key, entry.value);
    }

    const root_a = try state_a.computeStorageRoot(addr);
    const root_b = try state_b.computeStorageRoot(addr);
    try testing.expect(root_a.eql(root_b));
    try testing.expect(!root_a.eql(types.Hash.zero));
}

test "StateDB storage root changes on mutation and restores on revert" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state = StateDB.init(allocator);
    defer state.deinit();

    var addr = types.Address.zero;
    addr.bytes[19] = 0x52;
    const key = types.U256.fromU64(1);

    const empty_root = try state.computeStorageRoot(addr);
    try state.setStorage(addr, key, types.U256.fromU64(7));
    const populated_root = try state.computeStorageRoot(addr);
    try testing.expect(!empty_root.eql(populated_root));

    const sid = try state.snapshot();
    try state.setStorage(addr, key, types.U256.fromU64(9));
    const mutated_root = try state.computeStorageRoot(addr);
    try testing.expect(!populated_root.eql(mutated_root));

    try state.revertToSnapshot(sid);
    const reverted_root = try state.computeStorageRoot(addr);
    try testing.expect(populated_root.eql(reverted_root));
}

test "StateDB state root changes with account state and restores on revert" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state = StateDB.init(allocator);
    defer state.deinit();

    var addr = types.Address.zero;
    addr.bytes[19] = 0x53;
    try state.createAccount(addr);

    const empty_root = try state.computeStateRoot();

    try state.setBalance(addr, types.U256.fromU64(99));
    try state.setStorage(addr, types.U256.fromU64(1), types.U256.fromU64(2));
    try state.setCode(addr, &[_]u8{ 0x60, 0x2a, 0x00 });
    const populated_root = try state.computeStateRoot();
    try testing.expect(!empty_root.eql(populated_root));

    const sid = try state.snapshot();
    try state.setBalance(addr, types.U256.fromU64(100));
    const mutated_root = try state.computeStateRoot();
    try testing.expect(!populated_root.eql(mutated_root));

    try state.revertToSnapshot(sid);
    const reverted_root = try state.computeStateRoot();
    try testing.expect(populated_root.eql(reverted_root));
}

test "Trie insert and get" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var trie = Trie.init(allocator);
    defer trie.deinit();

    try trie.insert("key1", "value1");
    try trie.insert("key2", "value2");

    const v1 = trie.get("key1");
    try testing.expect(v1 != null);
    try testing.expectEqualStrings("value1", v1.?);

    const v2 = trie.get("key2");
    try testing.expect(v2 != null);
    try testing.expectEqualStrings("value2", v2.?);

    const v3 = trie.get("key3");
    try testing.expect(v3 == null);
}
