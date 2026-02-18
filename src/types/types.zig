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
        var borrow: i128 = 0;

        inline for (0..4) |i| {
            const a = @as(i128, self.limbs[i]);
            const b = @as(i128, other.limbs[i]);
            const diff = a - b - borrow;

            if (diff < 0) {
                result.limbs[i] = @intCast(@as(u128, @bitCast(diff + (1 << 64))) & 0xFFFFFFFFFFFFFFFF);
                borrow = 1;
            } else {
                result.limbs[i] = @intCast(diff);
                borrow = 0;
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
        if (self.lt(other)) return U256.zero();

        const div_result = self.divMod(other);
        return div_result.quotient;
    }

    pub fn mod(self: U256, other: U256) U256 {
        if (other.isZero()) return U256.zero();
        if (self.lt(other)) return self;

        const div_result = self.divMod(other);
        return div_result.remainder;
    }

    fn getBit(self: U256, bit_index: usize) bool {
        const limb_idx = bit_index / 64;
        const bit_in_limb: u6 = @intCast(bit_index % 64);
        return ((self.limbs[limb_idx] >> bit_in_limb) & 1) != 0;
    }

    fn setBit(self: *U256, bit_index: usize) void {
        const limb_idx = bit_index / 64;
        const bit_in_limb: u6 = @intCast(bit_index % 64);
        self.limbs[limb_idx] |= (@as(u64, 1) << bit_in_limb);
    }

    fn shl1(self: U256) U256 {
        var result = U256.zero();
        var carry: u64 = 0;
        for (0..4) |i| {
            const next_carry = self.limbs[i] >> 63;
            result.limbs[i] = (self.limbs[i] << 1) | carry;
            carry = next_carry;
        }
        return result;
    }

    const DivModResult = struct {
        quotient: U256,
        remainder: U256,
    };

    fn divMod(self: U256, divisor: U256) DivModResult {
        var quotient = U256.zero();
        var remainder = U256.zero();

        var bit: usize = 256;
        while (bit > 0) {
            bit -= 1;

            remainder = remainder.shl1();
            if (self.getBit(bit)) {
                remainder.limbs[0] |= 1;
            }

            if (!remainder.lt(divisor)) {
                remainder = remainder.sub(divisor);
                quotient.setBit(bit);
            }
        }

        return DivModResult{
            .quotient = quotient,
            .remainder = remainder,
        };
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

    // Signed arithmetic helpers (two's complement)

    /// Check if a U256 represents a negative number in two's complement
    /// Returns true if the MSB (bit 255) is set
    pub fn isSignedNegative(self: U256) bool {
        return (self.limbs[3] >> 63) != 0;
    }

    /// Get absolute value of signed number (two's complement)
    pub fn signedAbs(self: U256) U256 {
        if (self.isSignedNegative()) {
            // Two's complement negation: flip all bits and add 1
            var result = U256.zero();
            result.limbs[0] = ~self.limbs[0];
            result.limbs[1] = ~self.limbs[1];
            result.limbs[2] = ~self.limbs[2];
            result.limbs[3] = ~self.limbs[3];

            // Add 1
            var carry: u64 = 1;
            var i: usize = 0;
            while (i < 4) {
                const sum = @addWithOverflow(result.limbs[i], carry);
                result.limbs[i] = sum[0];
                carry = if (sum[1] != 0) 1 else 0;
                if (carry == 0) break;
                i += 1;
            }
            return result;
        }
        return self;
    }

    /// Negate a signed number (two's complement)
    pub fn signedNegateFast(self: U256) U256 {
        if (self.isZero()) return self;
        // Two's complement: flip all bits and add 1
        var result = U256.zero();
        result.limbs[0] = ~self.limbs[0];
        result.limbs[1] = ~self.limbs[1];
        result.limbs[2] = ~self.limbs[2];
        result.limbs[3] = ~self.limbs[3];

        // Add 1
        var carry: u64 = 1;
        var i: usize = 0;
        while (i < 4) {
            const sum = @addWithOverflow(result.limbs[i], carry);
            result.limbs[i] = sum[0];
            carry = if (sum[1] != 0) 1 else 0;
            if (carry == 0) break;
            i += 1;
        }
        return result;
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
        var encoded = std.ArrayList(u8).init(allocator);
        defer encoded.deinit();

        try appendU64(&encoded, self.nonce);
        try appendU64(&encoded, self.gas_price);
        try appendU64(&encoded, self.gas_limit);

        if (self.to) |to_addr| {
            try appendBytesPrefixed(&encoded, &to_addr.bytes);
        } else {
            try appendBytesPrefixed(&encoded, &[_]u8{});
        }

        try appendU128(&encoded, self.value);
        try appendBytesPrefixed(&encoded, self.data);
        try encoded.append(self.v);
        try appendU256(&encoded, self.r);
        try appendU256(&encoded, self.s);

        var hash_bytes: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(encoded.items, &hash_bytes, .{});
        return Hash{ .bytes = hash_bytes };
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
        var encoded = std.ArrayList(u8).init(allocator);
        defer encoded.deinit();

        try appendBytesPrefixed(&encoded, &self.parent_hash.bytes);
        try appendBytesPrefixed(&encoded, &self.uncle_hash.bytes);
        try appendBytesPrefixed(&encoded, &self.coinbase.bytes);
        try appendBytesPrefixed(&encoded, &self.root.bytes);
        try appendBytesPrefixed(&encoded, &self.tx_hash.bytes);
        try appendBytesPrefixed(&encoded, &self.receipt_hash.bytes);
        try appendBytesPrefixed(&encoded, &self.bloom);
        try appendU256(&encoded, self.difficulty);
        try appendU64(&encoded, self.number);
        try appendU64(&encoded, self.gas_limit);
        try appendU64(&encoded, self.gas_used);
        try appendU64(&encoded, self.timestamp);
        try appendBytesPrefixed(&encoded, self.extra_data);
        try appendBytesPrefixed(&encoded, &self.mix_digest.bytes);
        try appendU64(&encoded, self.nonce);

        var hash_bytes: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(encoded.items, &hash_bytes, .{});
        return Hash{ .bytes = hash_bytes };
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

fn appendBytesPrefixed(out: *std.ArrayList(u8), bytes: []const u8) !void {
    var len_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &len_buf, bytes.len, .big);
    try out.appendSlice(&len_buf);
    try out.appendSlice(bytes);
}

fn appendU64(out: *std.ArrayList(u8), value: u64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, value, .big);
    try out.appendSlice(&buf);
}

fn appendU128(out: *std.ArrayList(u8), value: u128) !void {
    var buf: [16]u8 = undefined;
    std.mem.writeInt(u128, &buf, value, .big);
    try out.appendSlice(&buf);
}

fn appendU256(out: *std.ArrayList(u8), value: U256) !void {
    const bytes = value.toBytes();
    try out.appendSlice(&bytes);
}

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

test "U256 division and modulo for large values" {
    const testing = std.testing;

    // 2^128 / 2^64 = 2^64
    const a = U256{ .limbs = [_]u64{ 0, 0, 1, 0 } };
    const b = U256{ .limbs = [_]u64{ 0, 1, 0, 0 } };
    const q = a.div(b);
    try testing.expect(q.eq(U256{ .limbs = [_]u64{ 0, 1, 0, 0 } }));

    // (2^128 + 5) mod 2^64 = 5
    const c = U256{ .limbs = [_]u64{ 5, 0, 1, 0 } };
    const d = U256{ .limbs = [_]u64{ 0, 1, 0, 0 } };
    const r = c.mod(d);
    try testing.expectEqual(@as(u64, 5), r.limbs[0]);
    try testing.expect(r.limbs[1] == 0 and r.limbs[2] == 0 and r.limbs[3] == 0);
}

test "Hash creation" {
    const testing = std.testing;

    const h1 = Hash.zero;
    const h2 = Hash.zero;

    try testing.expect(h1.eql(h2));
}

test "Transaction hash deterministic and nonce-sensitive" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tx = Transaction{
        .nonce = 1,
        .gas_price = 1_000_000_000,
        .gas_limit = 21_000,
        .to = Address.zero,
        .value = 42,
        .data = &[_]u8{ 0xaa, 0xbb },
        .v = 27,
        .r = U256.fromU64(1),
        .s = U256.fromU64(2),
    };

    const h1 = try tx.hash(allocator);
    const h2 = try tx.hash(allocator);
    try testing.expect(h1.eql(h2));

    tx.nonce = 2;
    const h3 = try tx.hash(allocator);
    try testing.expect(!h1.eql(h3));
}

test "BlockHeader hash deterministic and field-sensitive" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var header = BlockHeader{
        .parent_hash = Hash.zero,
        .uncle_hash = Hash.zero,
        .coinbase = Address.zero,
        .root = Hash.zero,
        .tx_hash = Hash.zero,
        .receipt_hash = Hash.zero,
        .bloom = [_]u8{0} ** 256,
        .difficulty = U256.fromU64(100),
        .number = 1,
        .gas_limit = 30_000_000,
        .gas_used = 21_000,
        .timestamp = 1_700_000_000,
        .extra_data = "zeth",
        .mix_digest = Hash.zero,
        .nonce = 1,
    };

    const h1 = try header.hash(allocator);
    const h2 = try header.hash(allocator);
    try testing.expect(h1.eql(h2));

    header.number = 2;
    const h3 = try header.hash(allocator);
    try testing.expect(!h1.eql(h3));
}
