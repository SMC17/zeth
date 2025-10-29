const std = @import("std");

/// 20-byte Ethereum address
pub const Address = struct {
    bytes: [20]u8,

    pub const zero = Address{ .bytes = [_]u8{0} ** 20 };

    pub fn fromSlice(slice: []const u8) !Address {
        if (slice.len != 20) return error.InvalidAddressLength;
        var addr: Address = undefined;
        @memcpy(&addr.bytes, slice);
        return addr;
    }

    pub fn format(
        self: Address,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.writeAll("0x");
        for (self.bytes) |byte| {
            try writer.print("{x:0>2}", .{byte});
        }
    }

    pub fn eql(self: Address, other: Address) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }
};

/// 32-byte hash
pub const Hash = struct {
    bytes: [32]u8,

    pub const zero = Hash{ .bytes = [_]u8{0} ** 32 };

    pub fn fromSlice(slice: []const u8) !Hash {
        if (slice.len != 32) return error.InvalidHashLength;
        var hash: Hash = undefined;
        @memcpy(&hash.bytes, slice);
        return hash;
    }

    pub fn format(
        self: Hash,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.writeAll("0x");
        for (self.bytes) |byte| {
            try writer.print("{x:0>2}", .{byte});
        }
    }

    pub fn eql(self: Hash, other: Hash) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }
};

/// 256-bit unsigned integer
pub const U256 = struct {
    limbs: [4]u64,

    pub fn zero() U256 {
        return U256{ .limbs = [_]u64{0} ** 4 };
    }

    pub fn one() U256 {
        return U256{ .limbs = [_]u64{ 1, 0, 0, 0 } };
    }

    pub fn fromU64(value: u64) U256 {
        return U256{ .limbs = [_]u64{ value, 0, 0, 0 } };
    }

    pub fn fromBytes(bytes: [32]u8) U256 {
        var result = U256.zero();
        for (0..4) |i| {
            result.limbs[i] = std.mem.readInt(u64, bytes[i * 8 ..][0..8], .big);
        }
        return result;
    }

    pub fn toBytes(self: U256) [32]u8 {
        var bytes: [32]u8 = undefined;
        for (0..4) |i| {
            std.mem.writeInt(u64, bytes[i * 8 ..][0..8], self.limbs[i], .big);
        }
        return bytes;
    }

    pub fn add(self: U256, other: U256) U256 {
        var result = U256.zero();
        var carry: u64 = 0;

        inline for (0..4) |i| {
            const sum = @as(u128, self.limbs[i]) + @as(u128, other.limbs[i]) + carry;
            result.limbs[i] = @truncate(sum);
            carry = @intCast(sum >> 64);
        }

        return result;
    }
    
    pub fn sub(self: U256, other: U256) U256 {
        var result = U256.zero();
        var borrow: u64 = 0;
        
        inline for (0..4) |i| {
            const a = @as(u128, self.limbs[i]);
            const b = @as(u128, other.limbs[i]) + borrow;
            if (a >= b) {
                result.limbs[i] = @truncate(a - b);
                borrow = 0;
            } else {
                result.limbs[i] = @truncate((1 << 64) + a - b);
                borrow = 1;
            }
        }
        
        return result;
    }
    
    pub fn mul(self: U256, other: U256) U256 {
        var result = U256.zero();
        
        for (0..4) |i| {
            var carry: u64 = 0;
            for (0..4) |j| {
                if (i + j >= 4) break;
                const product = @as(u128, self.limbs[i]) * @as(u128, other.limbs[j]) + 
                               @as(u128, result.limbs[i + j]) + carry;
                result.limbs[i + j] = @truncate(product);
                carry = @intCast(product >> 64);
            }
        }
        
        return result;
    }
    
    pub fn div(self: U256, other: U256) U256 {
        if (other.isZero()) return U256.zero();
        
        // Simplified division for small values
        if (other.limbs[1] == 0 and other.limbs[2] == 0 and other.limbs[3] == 0 and
            self.limbs[1] == 0 and self.limbs[2] == 0 and self.limbs[3] == 0) {
            return U256.fromU64(self.limbs[0] / other.limbs[0]);
        }
        
        // For larger values, use long division (simplified)
        // TODO: Implement proper Knuth division algorithm
        return U256.zero();
    }
    
    pub fn mod(self: U256, other: U256) U256 {
        if (other.isZero()) return U256.zero();
        
        // Simplified modulo for small values
        if (other.limbs[1] == 0 and other.limbs[2] == 0 and other.limbs[3] == 0 and
            self.limbs[1] == 0 and self.limbs[2] == 0 and self.limbs[3] == 0) {
            return U256.fromU64(self.limbs[0] % other.limbs[0]);
        }
        
        return U256.zero();
    }
    
    pub fn lt(self: U256, other: U256) bool {
        var i: usize = 4;
        while (i > 0) {
            i -= 1;
            if (self.limbs[i] < other.limbs[i]) return true;
            if (self.limbs[i] > other.limbs[i]) return false;
        }
        return false;
    }
    
    pub fn gt(self: U256, other: U256) bool {
        var i: usize = 4;
        while (i > 0) {
            i -= 1;
            if (self.limbs[i] > other.limbs[i]) return true;
            if (self.limbs[i] < other.limbs[i]) return false;
        }
        return false;
    }
    
    pub fn eq(self: U256, other: U256) bool {
        return self.limbs[0] == other.limbs[0] and
               self.limbs[1] == other.limbs[1] and
               self.limbs[2] == other.limbs[2] and
               self.limbs[3] == other.limbs[3];
    }

    pub fn isZero(self: U256) bool {
        return self.limbs[0] == 0 and self.limbs[1] == 0 and 
               self.limbs[2] == 0 and self.limbs[3] == 0;
    }

    pub fn format(
        self: U256,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        
        if (self.isZero()) {
            try writer.writeAll("0");
            return;
        }

        // Simple decimal formatting for small values
        if (self.limbs[1] == 0 and self.limbs[2] == 0 and self.limbs[3] == 0) {
            try writer.print("{}", .{self.limbs[0]});
        } else {
            try writer.writeAll("0x");
            var started = false;
            var i: usize = 4;
            while (i > 0) {
                i -= 1;
                if (started or self.limbs[i] != 0) {
                    if (started) {
                        try writer.print("{x:0>16}", .{self.limbs[i]});
                    } else {
                        try writer.print("{x}", .{self.limbs[i]});
                        started = true;
                    }
                }
            }
        }
    }
};

/// Ethereum transaction
pub const Transaction = struct {
    nonce: u64,
    gas_price: u64,
    gas_limit: u64,
    to: ?Address,
    value: u128,
    data: []const u8,
    v: u8,
    r: U256,
    s: U256,

    pub fn hash(self: *const Transaction, allocator: std.mem.Allocator) !Hash {
        _ = allocator;
        _ = self;
        // TODO: Implement RLP encoding and hashing
        return Hash.zero;
    }
};

/// Block header
pub const BlockHeader = struct {
    parent_hash: Hash,
    uncle_hash: Hash,
    coinbase: Address,
    root: Hash,
    tx_hash: Hash,
    receipt_hash: Hash,
    bloom: [256]u8,
    difficulty: U256,
    number: u64,
    gas_limit: u64,
    gas_used: u64,
    timestamp: u64,
    extra_data: []const u8,
    mix_digest: Hash,
    nonce: u64,

    pub fn hash(self: *const BlockHeader, allocator: std.mem.Allocator) !Hash {
        _ = allocator;
        _ = self;
        // TODO: Implement RLP encoding and hashing
        return Hash.zero;
    }
};

/// Complete block
pub const Block = struct {
    header: BlockHeader,
    transactions: []Transaction,
    uncles: []BlockHeader,

    pub fn hash(self: *const Block, allocator: std.mem.Allocator) !Hash {
        return try self.header.hash(allocator);
    }
};

/// Account state
pub const Account = struct {
    nonce: u64,
    balance: U256,
    storage_root: Hash,
    code_hash: Hash,

    pub fn empty() Account {
        return Account{
            .nonce = 0,
            .balance = U256.zero(),
            .storage_root = Hash.zero,
            .code_hash = Hash.zero,
        };
    }
};

test "Address creation and formatting" {
    const testing = std.testing;
    
    const addr = Address.zero;
    try testing.expect(addr.eql(Address.zero));
}

test "U256 arithmetic" {
    const testing = std.testing;
    
    const a = U256.fromU64(100);
    const b = U256.fromU64(200);
    const c = a.add(b);
    
    try testing.expectEqual(@as(u64, 300), c.limbs[0]);
    try testing.expect(!c.isZero());
    try testing.expect(U256.zero().isZero());
}

test "Hash creation" {
    const testing = std.testing;
    
    const h1 = Hash.zero;
    const h2 = Hash.zero;
    
    try testing.expect(h1.eql(h2));
}

