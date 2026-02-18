const std = @import("std");

/// Keccak-256 hash function as used by Ethereum
/// Uses Zig stdlib Keccak-256 implementation (padding 0x01).
pub fn keccak256(data: []const u8, out: *[32]u8) void {
    std.crypto.hash.sha3.Keccak256.hash(data, out, .{});
}

/// RIPEMD-160 hash function
pub fn ripemd160(data: []const u8, out: *[20]u8) void {
    // Placeholder - would need proper implementation
    @memset(out, 0);
    _ = data;
}

/// secp256k1 public key recovery
pub const Secp256k1 = struct {
    pub const PublicKey = struct {
        data: [64]u8,

        pub fn fromPrivateKey(private_key: [32]u8) !PublicKey {
            // Placeholder for secp256k1 key derivation
            var pk: PublicKey = undefined;
            @memset(&pk.data, 0);
            _ = private_key;
            return pk;
        }

        pub fn toAddress(self: PublicKey) [20]u8 {
            var hash: [32]u8 = undefined;
            keccak256(&self.data, &hash);

            var address: [20]u8 = undefined;
            @memcpy(&address, hash[12..32]);
            return address;
        }
    };

    pub const Signature = struct {
        r: [32]u8,
        s: [32]u8,
        v: u8,

        pub fn verify(self: Signature, message: [32]u8, public_key: PublicKey) bool {
            // Placeholder for signature verification
            _ = self;
            _ = message;
            _ = public_key;
            return false;
        }

        pub fn recover(self: Signature, message: [32]u8) !PublicKey {
            // Placeholder for public key recovery from signature
            _ = self;
            _ = message;
            return error.NotImplemented;
        }
    };

    pub fn sign(message: [32]u8, private_key: [32]u8) !Signature {
        // Placeholder for signing
        _ = message;
        _ = private_key;
        return error.NotImplemented;
    }
};

test "keccak256 deterministic" {
    const testing = std.testing;

    // Test that hashing is deterministic
    const data = "Hello, Ethereum!";
    var hash1: [32]u8 = undefined;
    var hash2: [32]u8 = undefined;

    keccak256(data, &hash1);
    keccak256(data, &hash2);

    try testing.expectEqualSlices(u8, &hash1, &hash2);

    // Known Ethereum Keccak-256 vector: keccak256("")
    keccak256("", &hash1);
    const expected_empty = [_]u8{
        0xc5, 0xd2, 0x46, 0x01, 0x86, 0xf7, 0x23, 0x3c,
        0x92, 0x7e, 0x7d, 0xb2, 0xdc, 0xc7, 0x03, 0xc0,
        0xe5, 0x00, 0xb6, 0x53, 0xca, 0x82, 0x27, 0x3b,
        0x7b, 0xfa, 0xd8, 0x04, 0x5d, 0x85, 0xa4, 0x70,
    };
    try testing.expectEqualSlices(u8, &expected_empty, &hash1);

    // Known vector: keccak256("abc")
    keccak256("abc", &hash1);
    const expected_abc = [_]u8{
        0x4e, 0x03, 0x65, 0x7a, 0xea, 0x45, 0xa9, 0x4f,
        0xc7, 0xd4, 0x7b, 0xa8, 0x26, 0xc8, 0xd6, 0x67,
        0xc0, 0xd1, 0xe6, 0xe3, 0x3a, 0x64, 0xa0, 0x36,
        0xec, 0x44, 0xf5, 0x8f, 0xa1, 0x2d, 0x6c, 0x45,
    };
    try testing.expectEqualSlices(u8, &expected_abc, &hash1);
}

test "public key to address" {
    const testing = std.testing;

    var pk = Secp256k1.PublicKey{ .data = [_]u8{0} ** 64 };
    const addr = pk.toAddress();

    try testing.expectEqual(@as(usize, 20), addr.len);
}
