const std = @import("std");
const types = @import("types");
const crypto = @import("crypto");

/// State database that manages account states and storage
pub const StateDB = struct {
    allocator: std.mem.Allocator,
    accounts: std.AutoHashMap(types.Address, types.Account),
    storage: std.AutoHashMap(StorageKey, types.U256),
    code: std.AutoHashMap(types.Address, []u8),
    snapshots: std.ArrayList(Snapshot),

    pub fn init(allocator: std.mem.Allocator) StateDB {
        return StateDB{
            .allocator = allocator,
            .accounts = std.AutoHashMap(types.Address, types.Account).init(allocator),
            .storage = std.AutoHashMap(StorageKey, types.U256).init(allocator),
            .code = std.AutoHashMap(types.Address, []u8).init(allocator),
            .snapshots = std.ArrayList(Snapshot).init(allocator),
        };
    }

    pub fn deinit(self: *StateDB) void {
        for (self.snapshots.items) |*snap| {
            snap.deinit(self.allocator);
        }
        self.snapshots.deinit();
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
        try self.accounts.put(address, account);
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
        const new_code = try self.allocator.dupe(u8, code_bytes);

        if (self.code.fetchRemove(address)) |old| {
            self.allocator.free(old.value);
        }
        try self.code.put(address, new_code);

        var account = try self.getAccount(address);
        if (new_code.len == 0) {
            account.code_hash = types.Hash.zero;
        } else {
            var hash: [32]u8 = undefined;
            crypto.keccak256(new_code, &hash);
            account.code_hash = types.Hash{ .bytes = hash };
        }
        try self.setAccount(address, account);
    }

    pub fn destroyAccount(self: *StateDB, address: types.Address) !void {
        if (self.code.fetchRemove(address)) |old| {
            self.allocator.free(old.value);
        }

        var storage_keys = std.ArrayList(StorageKey).init(self.allocator);
        defer storage_keys.deinit();

        var it = self.storage.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.address.eql(address)) {
                try storage_keys.append(entry.key_ptr.*);
            }
        }
        for (storage_keys.items) |key| {
            _ = self.storage.remove(key);
        }

        _ = self.accounts.remove(address);
    }

    pub fn snapshot(self: *StateDB) !usize {
        var snap = Snapshot{
            .accounts = try self.cloneAccounts(),
            .storage = try self.cloneStorage(),
            .code = undefined,
        };
        errdefer {
            snap.accounts.deinit();
            snap.storage.deinit();
        }
        snap.code = try self.cloneCode();
        try self.snapshots.append(snap);
        return self.snapshots.items.len - 1;
    }

    pub fn commitSnapshot(self: *StateDB, snapshot_id: usize) !void {
        if (snapshot_id + 1 != self.snapshots.items.len) return error.InvalidSnapshot;
        var snap = self.snapshots.pop().?;
        snap.deinit(self.allocator);
    }

    pub fn revertToSnapshot(self: *StateDB, snapshot_id: usize) !void {
        if (snapshot_id + 1 != self.snapshots.items.len) return error.InvalidSnapshot;
        const snap = self.snapshots.pop().?;

        var current_code = self.code;
        deinitCodeMap(&current_code, self.allocator);
        self.accounts.deinit();
        self.storage.deinit();

        self.accounts = snap.accounts;
        self.storage = snap.storage;
        self.code = snap.code;
    }

    fn cloneAccounts(self: *StateDB) !std.AutoHashMap(types.Address, types.Account) {
        var copy = std.AutoHashMap(types.Address, types.Account).init(self.allocator);
        errdefer copy.deinit();
        var it = self.accounts.iterator();
        while (it.next()) |entry| {
            try copy.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        return copy;
    }

    fn cloneStorage(self: *StateDB) !std.AutoHashMap(StorageKey, types.U256) {
        var copy = std.AutoHashMap(StorageKey, types.U256).init(self.allocator);
        errdefer copy.deinit();
        var it = self.storage.iterator();
        while (it.next()) |entry| {
            try copy.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        return copy;
    }

    fn cloneCode(self: *StateDB) !std.AutoHashMap(types.Address, []u8) {
        var copy = std.AutoHashMap(types.Address, []u8).init(self.allocator);
        errdefer deinitCodeMap(&copy, self.allocator);

        var it = self.code.iterator();
        while (it.next()) |entry| {
            const dup = try self.allocator.dupe(u8, entry.value_ptr.*);
            errdefer self.allocator.free(dup);
            try copy.put(entry.key_ptr.*, dup);
        }
        return copy;
    }
};

const Snapshot = struct {
    accounts: std.AutoHashMap(types.Address, types.Account),
    storage: std.AutoHashMap(StorageKey, types.U256),
    code: std.AutoHashMap(types.Address, []u8),

    fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        deinitCodeMap(&self.code, allocator);
        self.accounts.deinit();
        self.storage.deinit();
    }
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
        _ = self;
        _ = node;
        // Simplified - would compute actual Merkle hash
        return types.Hash.zero;
    }
};

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
