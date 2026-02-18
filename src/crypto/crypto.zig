const std = @import("std");
const Ecdsa = std.crypto.sign.ecdsa.EcdsaSecp256k1Sha256;
const Curve = std.crypto.ecc.Secp256k1;
const Scalar = Curve.scalar.Scalar;

/// Keccak-256 hash function as used by Ethereum
/// Uses Zig stdlib Keccak-256 implementation (padding 0x01).
pub fn keccak256(data: []const u8, out: *[32]u8) void {
    std.crypto.hash.sha3.Keccak256.hash(data, out, .{});
}

/// RIPEMD-160 hash function
pub fn ripemd160(data: []const u8, out: *[20]u8) void {
    const rl = [_]u8{
        0, 1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15,
        7, 4,  13, 1,  10, 6,  15, 3,  12, 0, 9,  5,  2,  14, 11, 8,
        3, 10, 14, 4,  9,  15, 8,  1,  2,  7, 0,  6,  13, 11, 5,  12,
        1, 9,  11, 10, 0,  8,  12, 4,  13, 3, 7,  15, 14, 5,  6,  2,
        4, 0,  5,  9,  7,  12, 2,  10, 14, 1, 3,  8,  11, 6,  15, 13,
    };
    const rr = [_]u8{
        5,  14, 7,  0, 9, 2,  11, 4,  13, 6,  15, 8,  1,  10, 3,  12,
        6,  11, 3,  7, 0, 13, 5,  10, 14, 15, 8,  12, 4,  9,  1,  2,
        15, 5,  1,  3, 7, 14, 6,  9,  11, 8,  12, 2,  10, 0,  4,  13,
        8,  6,  4,  1, 3, 11, 15, 0,  5,  12, 2,  13, 9,  7,  10, 14,
        12, 15, 10, 4, 1, 5,  8,  7,  6,  2,  13, 14, 0,  3,  9,  11,
    };
    const sl = [_]u8{
        11, 14, 15, 12, 5,  8,  7,  9,  11, 13, 14, 15, 6,  7,  9,  8,
        7,  6,  8,  13, 11, 9,  7,  15, 7,  12, 15, 9,  11, 7,  13, 12,
        11, 13, 6,  7,  14, 9,  13, 15, 14, 8,  13, 6,  5,  12, 7,  5,
        11, 12, 14, 15, 14, 15, 9,  8,  9,  14, 5,  6,  8,  6,  5,  12,
        9,  15, 5,  11, 6,  8,  13, 12, 5,  12, 13, 14, 11, 8,  5,  6,
    };
    const sr = [_]u8{
        8,  9,  9,  11, 13, 15, 15, 5,  7,  7,  8,  11, 14, 14, 12, 6,
        9,  13, 15, 7,  12, 8,  9,  11, 7,  7,  12, 7,  6,  15, 13, 11,
        9,  7,  15, 11, 8,  6,  6,  14, 12, 13, 5,  14, 13, 13, 7,  5,
        15, 5,  8,  11, 14, 14, 6,  14, 6,  9,  12, 9,  12, 5,  15, 8,
        8,  5,  12, 9,  12, 5,  14, 6,  8,  13, 6,  5,  15, 13, 11, 11,
    };

    var h0: u32 = 0x67452301;
    var h1: u32 = 0xefcdab89;
    var h2: u32 = 0x98badcfe;
    var h3: u32 = 0x10325476;
    var h4: u32 = 0xc3d2e1f0;

    var msg = std.ArrayList(u8).init(std.heap.page_allocator);
    defer msg.deinit();
    msg.appendSlice(data) catch unreachable;
    msg.append(0x80) catch unreachable;
    while ((msg.items.len % 64) != 56) msg.append(0) catch unreachable;
    const bit_len: u64 = @intCast(data.len * 8);
    var len_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &len_bytes, bit_len, .little);
    msg.appendSlice(&len_bytes) catch unreachable;

    var offset: usize = 0;
    while (offset < msg.items.len) : (offset += 64) {
        var x: [16]u32 = undefined;
        for (0..16) |i| {
            x[i] = std.mem.readInt(u32, msg.items[offset + i * 4 ..][0..4], .little);
        }

        var al = h0;
        var bl = h1;
        var cl = h2;
        var dl = h3;
        var el = h4;
        var ar = h0;
        var br = h1;
        var cr = h2;
        var dr = h3;
        var er = h4;

        for (0..80) |j| {
            const tl = std.math.rotl(u32, al +% ripemdF(j, bl, cl, dl) +% x[rl[j]] +% ripemdKLeft(j), sl[j]) +% el;
            al = el;
            el = dl;
            dl = std.math.rotl(u32, cl, 10);
            cl = bl;
            bl = tl;

            const tr = std.math.rotl(u32, ar +% ripemdF(79 - j, br, cr, dr) +% x[rr[j]] +% ripemdKRight(j), sr[j]) +% er;
            ar = er;
            er = dr;
            dr = std.math.rotl(u32, cr, 10);
            cr = br;
            br = tr;
        }

        const t = h1 +% cl +% dr;
        h1 = h2 +% dl +% er;
        h2 = h3 +% el +% ar;
        h3 = h4 +% al +% br;
        h4 = h0 +% bl +% cr;
        h0 = t;
    }

    std.mem.writeInt(u32, out[0..4], h0, .little);
    std.mem.writeInt(u32, out[4..8], h1, .little);
    std.mem.writeInt(u32, out[8..12], h2, .little);
    std.mem.writeInt(u32, out[12..16], h3, .little);
    std.mem.writeInt(u32, out[16..20], h4, .little);
}

fn ripemdF(j: usize, x: u32, y: u32, z: u32) u32 {
    if (j <= 15) return x ^ y ^ z;
    if (j <= 31) return (x & y) | (~x & z);
    if (j <= 47) return (x | ~y) ^ z;
    if (j <= 63) return (x & z) | (y & ~z);
    return x ^ (y | ~z);
}

fn ripemdKLeft(j: usize) u32 {
    if (j <= 15) return 0x00000000;
    if (j <= 31) return 0x5a827999;
    if (j <= 47) return 0x6ed9eba1;
    if (j <= 63) return 0x8f1bbcdc;
    return 0xa953fd4e;
}

fn ripemdKRight(j: usize) u32 {
    if (j <= 15) return 0x50a28be6;
    if (j <= 31) return 0x5c4dd124;
    if (j <= 47) return 0x6d703ef3;
    if (j <= 63) return 0x7a6d76e9;
    return 0x00000000;
}

pub fn ecrecoverAddress(msg_hash: [32]u8, v: u8, r_bytes: [32]u8, s_bytes: [32]u8) ?[20]u8 {
    const sig = Secp256k1.Signature{ .r = r_bytes, .s = s_bytes, .v = v };
    const rec_id: u8 = if (sig.v >= 27) sig.v - 27 else sig.v;
    if (rec_id > 3) return null;

    const parity = rec_id & 1;
    const prefer_overflow = (rec_id >> 1) & 1;
    for ([_]u1{ @intCast(prefer_overflow), @intCast(prefer_overflow ^ 1) }) |overflow_bit| {
        if (Secp256k1.recoverWithParamsRaw(sig, msg_hash, parity, overflow_bit) catch null) |pk| {
            return pk.toAddress();
        }
    }
    return null;
}

/// secp256k1 public key recovery
pub const Secp256k1 = struct {
    pub const PublicKey = struct {
        data: [64]u8,

        pub fn fromPrivateKey(private_key: [32]u8) !PublicKey {
            const secret = try Ecdsa.SecretKey.fromBytes(private_key);
            const key_pair = try Ecdsa.KeyPair.fromSecretKey(secret);
            const uncompressed = key_pair.public_key.toUncompressedSec1();
            var out = PublicKey{ .data = undefined };
            @memcpy(out.data[0..64], uncompressed[1..65]);
            return out;
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
            var sec1: [65]u8 = undefined;
            sec1[0] = 0x04;
            @memcpy(sec1[1..65], public_key.data[0..64]);

            const pk = Ecdsa.PublicKey.fromSec1(&sec1) catch return false;
            const sig = Ecdsa.Signature{ .r = self.r, .s = self.s };
            sig.verify(&message, pk) catch return false;
            return true;
        }

        pub fn recover(self: Signature, message: [32]u8) !PublicKey {
            const rec_id: u8 = if (self.v >= 27) self.v - 27 else self.v;
            const parity = rec_id & 1;
            const prefer_overflow = (rec_id >> 1) & 1;

            // Try preferred overflow bit first, then the alternate candidate.
            for ([_]u1{ @intCast(prefer_overflow), @intCast(prefer_overflow ^ 1) }) |overflow_bit| {
                if (try recoverWithParams(self, message, parity, overflow_bit)) |pk| {
                    return pk;
                }
            }
            return error.SignatureVerificationFailed;
        }
    };

    pub fn sign(message: [32]u8, private_key: [32]u8) !Signature {
        const secret = try Ecdsa.SecretKey.fromBytes(private_key);
        const key_pair = try Ecdsa.KeyPair.fromSecretKey(secret);
        const sig = try key_pair.sign(&message, null);
        const uncompressed = key_pair.public_key.toUncompressedSec1();

        // Determine recovery id by matching recovered key against signer pubkey.
        var expected_pk = PublicKey{ .data = undefined };
        @memcpy(expected_pk.data[0..64], uncompressed[1..65]);

        var result = Signature{ .r = sig.r, .s = sig.s, .v = 27 };
        var rec_id: u8 = 0;
        while (rec_id < 4) : (rec_id += 1) {
            result.v = 27 + rec_id;
            const recovered = result.recover(message) catch continue;
            if (std.mem.eql(u8, &recovered.data, &expected_pk.data)) {
                return result;
            }
        }
        return error.SignatureVerificationFailed;
    }

    fn scalarFromMessage(message: [32]u8) Scalar {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&message, &digest, .{});
        var wide = [_]u8{0} ** 48;
        @memcpy(wide[16..48], digest[0..32]);
        return Scalar.fromBytes48(wide, .big);
    }

    fn scalarFromDigest(digest: [32]u8) Scalar {
        var wide = [_]u8{0} ** 48;
        @memcpy(wide[16..48], digest[0..32]);
        return Scalar.fromBytes48(wide, .big);
    }

    fn u256ToBytes(value: u256) [32]u8 {
        var out: [32]u8 = undefined;
        var n = value;
        var i: usize = 32;
        while (i > 0) {
            i -= 1;
            out[i] = @as(u8, @truncate(n & 0xff));
            n >>= 8;
        }
        return out;
    }

    fn bytesToU256(bytes: [32]u8) u256 {
        var n: u256 = 0;
        for (bytes) |b| {
            n = (n << 8) | @as(u256, b);
        }
        return n;
    }

    fn recoverWithParams(
        self: Signature,
        message: [32]u8,
        parity: u8,
        overflow_bit: u1,
    ) !?PublicKey {
        const r = Scalar.fromBytes(self.r, .big) catch return null;
        const s = Scalar.fromBytes(self.s, .big) catch return null;
        if (r.isZero() or s.isZero()) return null;

        const n_order: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        const p_field: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;
        const r_int = bytesToU256(self.r);
        const x_int = if (overflow_bit == 0) blk: {
            break :blk r_int;
        } else blk: {
            const sum = @addWithOverflow(r_int, n_order);
            if (sum[1] != 0) return null;
            break :blk sum[0];
        };
        if (x_int >= p_field) return null;
        const x_bytes = u256ToBytes(x_int);

        const x_fe = Curve.Fe.fromBytes(x_bytes, .big) catch return null;
        const y_fe = Curve.recoverY(x_fe, parity != 0) catch return null;
        const y_bytes = y_fe.toBytes(.big);
        const point_r = Curve.fromSerializedAffineCoordinates(x_bytes, y_bytes, .big) catch return null;

        const z = scalarFromMessage(message);
        const s_r = try point_r.mulPublic(s.toBytes(.little), .little);
        const z_g = try Curve.basePoint.mulPublic(z.toBytes(.little), .little);
        const numerator = s_r.sub(z_g);
        const q = try numerator.mulPublic(r.invert().toBytes(.little), .little);

        const sec1 = q.toUncompressedSec1();
        var pk = PublicKey{ .data = undefined };
        @memcpy(pk.data[0..64], sec1[1..65]);
        return if (self.verify(message, pk)) pk else null;
    }

    fn recoverWithParamsRaw(
        self: Signature,
        digest: [32]u8,
        parity: u8,
        overflow_bit: u1,
    ) !?PublicKey {
        const r = Scalar.fromBytes(self.r, .big) catch return null;
        const s = Scalar.fromBytes(self.s, .big) catch return null;
        if (r.isZero() or s.isZero()) return null;

        const n_order: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        const p_field: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;
        const r_int = bytesToU256(self.r);
        const x_int = if (overflow_bit == 0) blk: {
            break :blk r_int;
        } else blk: {
            const sum = @addWithOverflow(r_int, n_order);
            if (sum[1] != 0) return null;
            break :blk sum[0];
        };
        if (x_int >= p_field) return null;
        const x_bytes = u256ToBytes(x_int);

        const x_fe = Curve.Fe.fromBytes(x_bytes, .big) catch return null;
        const y_fe = Curve.recoverY(x_fe, parity != 0) catch return null;
        const y_bytes = y_fe.toBytes(.big);
        const point_r = Curve.fromSerializedAffineCoordinates(x_bytes, y_bytes, .big) catch return null;

        const z = scalarFromDigest(digest);
        const s_r = try point_r.mulPublic(s.toBytes(.little), .little);
        const z_g = try Curve.basePoint.mulPublic(z.toBytes(.little), .little);
        const numerator = s_r.sub(z_g);
        const q = try numerator.mulPublic(r.invert().toBytes(.little), .little);

        const w = s.invert();
        const u1_bytes = z.mul(w).toBytes(.little);
        const u2_bytes = r.mul(w).toBytes(.little);
        const u1g = try Curve.basePoint.mulPublic(u1_bytes, .little);
        const u2q = try q.mulPublic(u2_bytes, .little);
        const x_check = u1g.add(u2q).affineCoordinates().x.toBytes(.big);
        const r_check = Scalar.fromBytes48(.{
            0,           0,           0,           0,           0,           0,           0,           0,           0,           0,           0,           0,           0,           0,           0,           0,
            x_check[0],  x_check[1],  x_check[2],  x_check[3],  x_check[4],  x_check[5],  x_check[6],  x_check[7],  x_check[8],  x_check[9],  x_check[10], x_check[11], x_check[12], x_check[13], x_check[14], x_check[15],
            x_check[16], x_check[17], x_check[18], x_check[19], x_check[20], x_check[21], x_check[22], x_check[23], x_check[24], x_check[25], x_check[26], x_check[27], x_check[28], x_check[29], x_check[30], x_check[31],
        }, .big);
        if (!r.equivalent(r_check)) return null;

        const sec1 = q.toUncompressedSec1();
        var pk = PublicKey{ .data = undefined };
        @memcpy(pk.data[0..64], sec1[1..65]);
        return pk;
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

test "ripemd160 known vectors" {
    const testing = std.testing;
    var out: [20]u8 = undefined;

    ripemd160("", &out);
    const expected_empty = [_]u8{
        0x9c, 0x11, 0x85, 0xa5, 0xc5, 0xe9, 0xfc, 0x54, 0x61, 0x28,
        0x08, 0x97, 0x7e, 0xe8, 0xf5, 0x48, 0xb2, 0x25, 0x8d, 0x31,
    };
    try testing.expectEqualSlices(u8, &expected_empty, &out);

    ripemd160("abc", &out);
    const expected_abc = [_]u8{
        0x8e, 0xb2, 0x08, 0xf7, 0xe0, 0x5d, 0x98, 0x7a, 0x9b, 0x04,
        0x4a, 0x8e, 0x98, 0xc6, 0xb0, 0x87, 0xf1, 0x5a, 0x0b, 0xfc,
    };
    try testing.expectEqualSlices(u8, &expected_abc, &out);
}

test "secp256k1 sign/verify/recover roundtrip" {
    const testing = std.testing;

    const private_key = [_]u8{
        0x4c, 0x08, 0x83, 0xa6, 0x91, 0x02, 0x93, 0x7d,
        0x62, 0x33, 0x47, 0x71, 0x2c, 0x8f, 0xa5, 0xf3,
        0x6c, 0xd7, 0xd8, 0x3f, 0x9f, 0x3a, 0x52, 0x4f,
        0xc6, 0x6f, 0x66, 0x73, 0xc1, 0x4c, 0xab, 0x5c,
    };
    const message = [_]u8{
        0x3a, 0x12, 0xb5, 0x10, 0x16, 0xfe, 0x4c, 0xbd,
        0x6b, 0xa7, 0xfe, 0x3e, 0x2a, 0x7f, 0xe1, 0x58,
        0x3f, 0x06, 0x66, 0xd2, 0xb5, 0x19, 0x6d, 0x90,
        0x2f, 0xdc, 0x54, 0x73, 0xa7, 0x0b, 0x2c, 0x0d,
    };

    const pk = try Secp256k1.PublicKey.fromPrivateKey(private_key);
    const sig = try Secp256k1.sign(message, private_key);
    try testing.expect(sig.verify(message, pk));

    const recovered = try sig.recover(message);
    try testing.expectEqualSlices(u8, &pk.data, &recovered.data);
}
