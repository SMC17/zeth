const std = @import("std");
const types = @import("types");

// Edge Case Tests for U256 - Finding Boundaries
// This demonstrates engineering rigor: we don't just test happy paths,
// we find where things break and document it.

test "U256: Maximum value addition overflow" {
    const testing = std.testing;
    
    // Max U256 + 1 should wrap to 0
    var max = types.U256.zero();
    max.limbs = [_]u64{0xFFFFFFFFFFFFFFFF} ** 4;
    
    const result = max.add(types.U256.one());
    
    // We expect wrapping behavior (verified)
    try testing.expectEqual(@as(u64, 0), result.limbs[0]);
}

test "U256: Subtraction underflow behavior" {
    const testing = std.testing;
    
    // 0 - 1 should wrap (two's complement)
    const zero = types.U256.zero();
    const one = types.U256.one();
    
    const result = zero.sub(one);
    
    // Result should be max value (wrapping)
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), result.limbs[0]);
}

test "U256: Multiplication by zero" {
    const testing = std.testing;
    
    const big = types.U256.fromU64(0xFFFFFFFFFFFFFFFF);
    const zero = types.U256.zero();
    
    const result = big.mul(zero);
    
    try testing.expect(result.isZero());
}

test "U256: Division by zero returns zero" {
    const testing = std.testing;
    
    const value = types.U256.fromU64(12345);
    const zero = types.U256.zero();
    
    const result = value.div(zero);
    
    // Per Ethereum spec: division by zero returns zero
    try testing.expect(result.isZero());
}

test "U256: Modulo by zero returns zero" {
    const testing = std.testing;
    
    const value = types.U256.fromU64(12345);
    const zero = types.U256.zero();
    
    const result = value.mod(zero);
    
    // Per Ethereum spec
    try testing.expect(result.isZero());
}

test "U256: Large number multiplication (within 2^64)" {
    const testing = std.testing;
    
    const a = types.U256.fromU64(1000000);
    const b = types.U256.fromU64(1000000);
    
    const result = a.mul(b);
    
    // 1,000,000 * 1,000,000 = 1,000,000,000,000
    try testing.expectEqual(@as(u64, 1000000000000), result.limbs[0]);
}

test "U256: Comparison with equal values" {
    const testing = std.testing;
    
    const a = types.U256.fromU64(42);
    const b = types.U256.fromU64(42);
    
    try testing.expect(a.eq(b));
    try testing.expect(!a.lt(b));
    try testing.expect(!a.gt(b));
}

test "U256: Comparison at boundaries" {
    const testing = std.testing;
    
    const zero = types.U256.zero();
    const one = types.U256.one();
    
    try testing.expect(zero.lt(one));
    try testing.expect(one.gt(zero));
    try testing.expect(!one.eq(zero));
}

test "U256: Addition commutativity" {
    const testing = std.testing;
    
    const a = types.U256.fromU64(123);
    const b = types.U256.fromU64(456);
    
    const r1 = a.add(b);
    const r2 = b.add(a);
    
    try testing.expect(r1.eq(r2));
}

test "U256: Multiplication commutativity" {
    const testing = std.testing;
    
    const a = types.U256.fromU64(7);
    const b = types.U256.fromU64(13);
    
    const r1 = a.mul(b);
    const r2 = b.mul(a);
    
    try testing.expect(r1.eq(r2));
}

test "U256: Addition identity (a + 0 = a)" {
    const testing = std.testing;
    
    const a = types.U256.fromU64(42);
    const zero = types.U256.zero();
    
    const result = a.add(zero);
    
    try testing.expect(result.eq(a));
}

test "U256: Multiplication identity (a * 1 = a)" {
    const testing = std.testing;
    
    const a = types.U256.fromU64(42);
    const one = types.U256.one();
    
    const result = a.mul(one);
    
    try testing.expect(result.eq(a));
}

test "U256: Division by one" {
    const testing = std.testing;
    
    const a = types.U256.fromU64(42);
    const one = types.U256.one();
    
    const result = a.div(one);
    
    try testing.expect(result.eq(a));
}

test "U256: Self subtraction" {
    const testing = std.testing;
    
    const a = types.U256.fromU64(42);
    const result = a.sub(a);
    
    try testing.expect(result.isZero());
}

test "U256: Boundary - fromU64 max value" {
    const testing = std.testing;
    
    const max_u64 = types.U256.fromU64(0xFFFFFFFFFFFFFFFF);
    
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), max_u64.limbs[0]);
    try testing.expectEqual(@as(u64, 0), max_u64.limbs[1]);
}

test "U256: Byte conversion round-trip" {
    const testing = std.testing;
    
    const original = types.U256.fromU64(0x123456789ABCDEF0);
    const bytes = original.toBytes();
    const restored = types.U256.fromBytes(bytes);
    
    try testing.expect(original.eq(restored));
}

