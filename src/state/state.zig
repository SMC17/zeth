const std = @import("std");
const types = @import("types");
const crypto = @import("crypto");

/// State database that manages account states and storage
pub const StateDB = struct {
    allocator: std.mem.Allocator,
    accounts: std.AutoHashMap(types.Address, types.Account),
    storage: std.AutoHashMap(StorageKey, types.U256),
    
    pub fn init(allocator: std.mem.Allocator) StateDB {
        return StateDB{
            .allocator = allocator,
            .accounts = std.AutoHashMap(types.Address, types.Account).init(allocator),
            .storage = std.AutoHashMap(StorageKey, types.U256).init(allocator),
        };
    }
    
    pub fn deinit(self: *StateDB) void {
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
};

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

