const std = @import("std");
const evm = @import("evm");
const types = @import("types");
const state = @import("state");

// ---------------------------------------------------------------------------
// Parity Edge Tests -- Issue #9
// Closes parity gaps for signed arithmetic, bitwise shift edge cases, and
// environmental opcodes.  Every test runs real bytecode through the EVM so
// we are testing the full decode-execute path.
// ---------------------------------------------------------------------------

// ===== helpers =============================================================

/// Build a PUSH32 instruction (0x7f + 32 bytes big-endian).
fn push32(buf: *std.ArrayList(u8), bytes: [32]u8) !void {
    try buf.append(0x7f); // PUSH32
    try buf.appendSlice(&bytes);
}

/// All-ones (MAX_UINT256, i.e. -1 in two's complement) as big-endian bytes
/// for PUSH32.
const MAX_UINT256_BYTES: [32]u8 = [_]u8{0xff} ** 32;

/// MIN_INT256 = 0x8000...0 (highest bit set, rest zero) as big-endian bytes.
const MIN_INT256_BYTES: [32]u8 = blk: {
    var b = [_]u8{0} ** 32;
    b[0] = 0x80;
    break :blk b;
};

/// MAX_INT256 = 0x7FFF...F as big-endian bytes.
const MAX_INT256_BYTES: [32]u8 = blk: {
    var b = [_]u8{0xff} ** 32;
    b[0] = 0x7f;
    break :blk b;
};

/// MAX_UINT256 as limbs (limbs[0]=LSB, limbs[3]=MSB).
const MAX_UINT256 = types.U256{
    .limbs = [_]u64{ 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF },
};

/// MIN_INT256 as limbs: bit 255 set.
const MIN_INT256 = types.U256{
    .limbs = [_]u64{ 0, 0, 0, 0x8000000000000000 },
};

// ===== 1. SDIV MIN_INT256 / -1 = MIN_INT256 ==============================

test "parity: SDIV MIN_INT256 / -1 = MIN_INT256 (overflow)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1_000_000);
    defer vm.deinit();

    // SDIV pops a (top), b (second), pushes b / a.
    // We want MIN_INT256 / (-1) = MIN_INT256.
    // Push b=MIN_INT256 first (deep), then a=-1 (top).
    var code = try std.ArrayList(u8).initCapacity(allocator, 70);
    defer code.deinit();

    try push32(&code, MIN_INT256_BYTES); // b = MIN_INT256 (deep)
    try push32(&code, MAX_UINT256_BYTES); // a = -1 (top)
    try code.append(0x05); // SDIV

    _ = try vm.execute(code.items, &[_]u8{});
    const result = try vm.stack.pop();
    try testing.expect(result.eq(MIN_INT256));
}

// ===== 2. SDIV by zero = 0 ================================================

test "parity: SDIV by zero = 0" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1_000_000);
    defer vm.deinit();

    // SDIV pops a (top), b (second), pushes b / a.
    // We want 5 / 0.  So b=5 (deep), a=0 (top).
    const bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5 (b, deep)
        0x60, 0x00, // PUSH1 0 (a, top -- divisor)
        0x05, // SDIV -> 5 / 0 = 0
    };

    _ = try vm.execute(&bytecode, &[_]u8{});
    const result = try vm.stack.pop();
    try testing.expect(result.isZero());
}

// ===== 3. SMOD edge cases ==================================================

test "parity: SMOD negative dividend -- sign follows dividend" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1_000_000);
    defer vm.deinit();

    // SMOD pops a (top), b (second), pushes b smod a.
    // We want (-7) smod 3 = -1.
    // So b = -7 (deep), a = 3 (top).
    // Build -7 with 0 - 7, then push 3 on top.
    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0
        0x60, 0x07, // PUSH1 7
        0x03, // SUB -> 0 - 7 = -7 (mod 2^256)
        0x60, 0x03, // PUSH1 3
        0x07, // SMOD -> (-7) smod 3 = -1
    };

    _ = try vm.execute(&bytecode, &[_]u8{});
    const result = try vm.stack.pop();
    // -1 is all 0xff in all limbs
    try testing.expect(result.eq(MAX_UINT256));
}

test "parity: SMOD by zero = 0" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1_000_000);
    defer vm.deinit();

    // SMOD pops a (top), b (second), pushes b smod a.
    // b=5 (deep), a=0 (top) -> 5 smod 0 = 0.
    const bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5 (b, deep)
        0x60, 0x00, // PUSH1 0 (a, top -- modulus)
        0x07, // SMOD -> 5 smod 0 = 0
    };

    _ = try vm.execute(&bytecode, &[_]u8{});
    const result = try vm.stack.pop();
    try testing.expect(result.isZero());
}

// ===== 4. SGT / SLT with sign boundary ====================================

test "parity: SLT -- positive is NOT less than negative" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1_000_000);
    defer vm.deinit();

    // SLT pops a (top), b (second), pushes (b < a) signed.
    // We want: MAX_INT256 < MIN_INT256?  That is false (positive not < negative).
    // So b=MAX_INT256 (deep), a=MIN_INT256 (top).
    var code = try std.ArrayList(u8).initCapacity(allocator, 70);
    defer code.deinit();

    try push32(&code, MAX_INT256_BYTES); // b (deep)
    try push32(&code, MIN_INT256_BYTES); // a (top)
    try code.append(0x12); // SLT -> MAX_INT256 < MIN_INT256 = false (0)

    _ = try vm.execute(code.items, &[_]u8{});
    const result = try vm.stack.pop();
    try testing.expect(result.isZero());
}

test "parity: SGT -- negative is NOT greater than positive" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1_000_000);
    defer vm.deinit();

    // SGT pops a (top), b (second), pushes (b > a) signed.
    // We want: MIN_INT256 > MAX_INT256?  False.
    // So b=MIN_INT256 (deep), a=MAX_INT256 (top).
    var code = try std.ArrayList(u8).initCapacity(allocator, 70);
    defer code.deinit();

    try push32(&code, MIN_INT256_BYTES); // b (deep)
    try push32(&code, MAX_INT256_BYTES); // a (top)
    try code.append(0x13); // SGT -> MIN_INT256 > MAX_INT256 = false (0)

    _ = try vm.execute(code.items, &[_]u8{});
    const result = try vm.stack.pop();
    try testing.expect(result.isZero());
}

// ===== 5. SIGNEXTEND edge cases ============================================

test "parity: SIGNEXTEND(0, 0x80) extends to all-ones upper bytes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1_000_000);
    defer vm.deinit();

    // SIGNEXTEND pops i (top) then x (second).
    // SIGNEXTEND(0, 0x80): bit 7 of 0x80 is 1 -> fill upper 31 bytes with 0xff.
    // Push x=0x80 first (deep), then i=0 (top).
    const bytecode = [_]u8{
        0x60, 0x80, // PUSH1 0x80 (x, deep)
        0x60, 0x00, // PUSH1 0    (i=0, top)
        0x0b, // SIGNEXTEND
    };

    _ = try vm.execute(&bytecode, &[_]u8{});
    const result = try vm.stack.pop();

    // Expected: 0xFFFFFFFF...FF80 = all limbs 0xFF...FF except lowest byte is 0x80.
    const expected = types.U256{
        .limbs = [_]u64{ 0xFFFFFFFFFFFFFF80, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF },
    };
    try testing.expect(result.eq(expected));
}

test "parity: SIGNEXTEND(0, 0x7F) does NOT extend -- stays 0x7F" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1_000_000);
    defer vm.deinit();

    const bytecode = [_]u8{
        0x60, 0x7f, // PUSH1 0x7F (x)
        0x60, 0x00, // PUSH1 0    (i=0)
        0x0b, // SIGNEXTEND
    };

    _ = try vm.execute(&bytecode, &[_]u8{});
    const result = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 0x7f), result.limbs[0]);
    try testing.expectEqual(@as(u64, 0), result.limbs[1]);
    try testing.expectEqual(@as(u64, 0), result.limbs[2]);
    try testing.expectEqual(@as(u64, 0), result.limbs[3]);
}

test "parity: SIGNEXTEND(30, x) extends from bit 247" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1_000_000);
    defer vm.deinit();

    // SIGNEXTEND(30, x): sign-extends from bit (30*8+7) = bit 247.
    // We need a value with bit 247 set.  In the internal representation
    // (limbs[0]=LSB), bit 247 is in limbs[3] at bit position 247-192=55.
    // Byte 30 from LSB = byte index 30 = limbs[3] byte 6 (30-24=6).
    // We need big-endian PUSH32 bytes where byte index 1 = 0x80 (since
    // big-endian byte 1 corresponds to byte 30 from LSB).
    var val_bytes = [_]u8{0} ** 32;
    val_bytes[1] = 0x80; // big-endian byte 1 = bit 247 set

    var code = try std.ArrayList(u8).initCapacity(allocator, 40);
    defer code.deinit();
    try push32(&code, val_bytes); // x
    try code.append(0x60); // PUSH1
    try code.append(30); // i = 30
    try code.append(0x0b); // SIGNEXTEND

    _ = try vm.execute(code.items, &[_]u8{});
    const result = try vm.stack.pop();

    // Expected: byte 31 (MSB) becomes 0xFF, byte 30 stays 0x80, bytes 0-29 stay 0.
    // In limbs: limbs[3] had 0x0080_0000_0000_0000, now limbs[3] = 0xFF80_0000_0000_0000.
    const expected = types.U256{
        .limbs = [_]u64{ 0, 0, 0, 0xFF80000000000000 },
    };
    try testing.expect(result.eq(expected));
}

test "parity: SIGNEXTEND(31, x) is identity -- no-op for full width" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1_000_000);
    defer vm.deinit();

    // Build a distinctive value via PUSH32.
    var val_bytes = [_]u8{0} ** 32;
    val_bytes[0] = 0x42;
    val_bytes[15] = 0xab;
    val_bytes[31] = 0xcd;

    var code = try std.ArrayList(u8).initCapacity(allocator, 40);
    defer code.deinit();
    try push32(&code, val_bytes); // x
    try code.append(0x60); // PUSH1
    try code.append(31); // i = 31
    try code.append(0x0b); // SIGNEXTEND

    _ = try vm.execute(code.items, &[_]u8{});
    const result = try vm.stack.pop();

    // SIGNEXTEND(31, x) is a no-op. The result should match what PUSH32 produces.
    // Verify by running the same PUSH32 without SIGNEXTEND.
    var vm2 = try evm.EVM.init(allocator, 1_000_000);
    defer vm2.deinit();

    var code2 = try std.ArrayList(u8).initCapacity(allocator, 40);
    defer code2.deinit();
    try push32(&code2, val_bytes);

    _ = try vm2.execute(code2.items, &[_]u8{});
    const expected = try vm2.stack.pop();

    try testing.expect(result.eq(expected));
}

// ===== 6-7. SHL / SHR by 256 = 0 ==========================================

test "parity: SHL by 256 = 0" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1_000_000);
    defer vm.deinit();

    // SHL pops shift (top) then value (second) -> value << shift.
    // Push value first (deep), then shift on top.
    var code = try std.ArrayList(u8).initCapacity(allocator, 40);
    defer code.deinit();
    try push32(&code, MAX_UINT256_BYTES); // value (all 1s)
    try code.appendSlice(&[_]u8{
        0x61, 0x01, 0x00, // PUSH2 256
        0x1b, // SHL
    });

    _ = try vm.execute(code.items, &[_]u8{});
    const result = try vm.stack.pop();
    try testing.expect(result.isZero());
}

test "parity: SHR by 256 = 0" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1_000_000);
    defer vm.deinit();

    var code = try std.ArrayList(u8).initCapacity(allocator, 40);
    defer code.deinit();
    try push32(&code, MAX_UINT256_BYTES); // value (all 1s)
    try code.appendSlice(&[_]u8{
        0x61, 0x01, 0x00, // PUSH2 256
        0x1c, // SHR
    });

    _ = try vm.execute(code.items, &[_]u8{});
    const result = try vm.stack.pop();
    try testing.expect(result.isZero());
}

// ===== 8. SAR by 256 ======================================================

test "parity: SAR by 256 on positive = 0" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1_000_000);
    defer vm.deinit();

    var code = try std.ArrayList(u8).initCapacity(allocator, 40);
    defer code.deinit();
    try push32(&code, MAX_INT256_BYTES); // positive value (0x7FFF...F)
    try code.appendSlice(&[_]u8{
        0x61, 0x01, 0x00, // PUSH2 256
        0x1d, // SAR
    });

    _ = try vm.execute(code.items, &[_]u8{});
    const result = try vm.stack.pop();
    try testing.expect(result.isZero());
}

test "parity: SAR by 256 on negative = MAX_UINT256 (all 1s)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1_000_000);
    defer vm.deinit();

    var code = try std.ArrayList(u8).initCapacity(allocator, 40);
    defer code.deinit();
    try push32(&code, MIN_INT256_BYTES); // negative value (0x8000...0)
    try code.appendSlice(&[_]u8{
        0x61, 0x01, 0x00, // PUSH2 256
        0x1d, // SAR
    });

    _ = try vm.execute(code.items, &[_]u8{});
    const result = try vm.stack.pop();
    try testing.expect(result.eq(MAX_UINT256));
}

// ===== 9. SHL/SHR/SAR by 0 = identity =====================================

test "parity: SHL by 0 = identity" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1_000_000);
    defer vm.deinit();

    const bytecode = [_]u8{
        0x60, 0x42, // PUSH1 0x42 (value)
        0x60, 0x00, // PUSH1 0    (shift)
        0x1b, // SHL
    };

    _ = try vm.execute(&bytecode, &[_]u8{});
    const result = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 0x42), result.limbs[0]);
}

test "parity: SHR by 0 = identity" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1_000_000);
    defer vm.deinit();

    const bytecode = [_]u8{
        0x60, 0x42, // PUSH1 0x42 (value)
        0x60, 0x00, // PUSH1 0    (shift)
        0x1c, // SHR
    };

    _ = try vm.execute(&bytecode, &[_]u8{});
    const result = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 0x42), result.limbs[0]);
}

test "parity: SAR by 0 = identity" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1_000_000);
    defer vm.deinit();

    const bytecode = [_]u8{
        0x60, 0x42, // PUSH1 0x42 (value)
        0x60, 0x00, // PUSH1 0    (shift)
        0x1d, // SAR
    };

    _ = try vm.execute(&bytecode, &[_]u8{});
    const result = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 0x42), result.limbs[0]);
}

// ===== 10. SHL by 255 =====================================================

test "parity: SHL by 255 -- only lowest bit survives at highest position" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1_000_000);
    defer vm.deinit();

    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1 (value)
        0x60, 0xff, // PUSH1 255 (shift)
        0x1b, // SHL -> 1 << 255 = 0x8000...0 = MIN_INT256
    };

    _ = try vm.execute(&bytecode, &[_]u8{});
    const result = try vm.stack.pop();
    try testing.expect(result.eq(MIN_INT256));
}

// ===== 11. BALANCE of non-existent account = 0 ============================

test "parity: BALANCE of non-existent account = 0" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    const context = evm.ExecutionContext.default();
    var vm = try evm.EVM.initWithState(allocator, 1_000_000, context, &db);
    defer vm.deinit();

    // Address 0x00...DD does not exist in the StateDB.
    const bytecode = [_]u8{
        0x60, 0xdd, // PUSH1 0xDD (address = 0x00...DD)
        0x31, // BALANCE
    };

    _ = try vm.execute(&bytecode, &[_]u8{});
    const result = try vm.stack.pop();
    try testing.expect(result.isZero());

    // Gas: 3 (PUSH1) + 2600 (cold BALANCE) = 2603
    try testing.expectEqual(@as(u64, 2603), vm.gas_used);
}

// ===== 12. EXTCODESIZE of non-existent account = 0 ========================

test "parity: EXTCODESIZE of non-existent account = 0" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    const context = evm.ExecutionContext.default();
    var vm = try evm.EVM.initWithState(allocator, 1_000_000, context, &db);
    defer vm.deinit();

    const bytecode = [_]u8{
        0x60, 0xee, // PUSH1 0xEE
        0x3b, // EXTCODESIZE
    };

    _ = try vm.execute(&bytecode, &[_]u8{});
    const result = try vm.stack.pop();
    try testing.expect(result.isZero());

    // Gas: 3 (PUSH1) + 2600 (cold EXTCODESIZE) = 2603
    try testing.expectEqual(@as(u64, 2603), vm.gas_used);
}

// ===== 13. EXTCODEHASH =====================================================

test "parity: EXTCODEHASH of non-existent account = 0" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    const context = evm.ExecutionContext.default();
    var vm = try evm.EVM.initWithState(allocator, 1_000_000, context, &db);
    defer vm.deinit();

    const bytecode = [_]u8{
        0x60, 0xcc, // PUSH1 0xCC (does not exist)
        0x3f, // EXTCODEHASH
    };

    _ = try vm.execute(&bytecode, &[_]u8{});
    const result = try vm.stack.pop();
    // EIP-1052: non-existent account -> 0
    try testing.expect(result.isZero());
}

test "parity: EXTCODEHASH of existing empty-code account = keccak256 of empty" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    // Create an account with no code.
    var addr = types.Address.zero;
    addr.bytes[19] = 0xab;
    try db.createAccount(addr);

    const context = evm.ExecutionContext.default();
    var vm = try evm.EVM.initWithState(allocator, 1_000_000, context, &db);
    defer vm.deinit();

    const bytecode = [_]u8{
        0x60, 0xab, // PUSH1 0xAB (matches addr)
        0x3f, // EXTCODEHASH
    };

    _ = try vm.execute(&bytecode, &[_]u8{});
    const result = try vm.stack.pop();

    // keccak256("") = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470
    // The EVM uses types.U256.fromBytes(hash) internally, so we use it too.
    const keccak_empty = types.U256.fromBytes([_]u8{
        0xc5, 0xd2, 0x46, 0x01, 0x86, 0xf7, 0x23, 0x3c,
        0x92, 0x7e, 0x7d, 0xb2, 0xdc, 0xc7, 0x03, 0xc0,
        0xe5, 0x00, 0xb6, 0x53, 0xca, 0x82, 0x27, 0x3b,
        0x7b, 0xfa, 0xd8, 0x04, 0x5d, 0x85, 0xa4, 0x70,
    });
    try testing.expect(result.eq(keccak_empty));
}

// ===== 14. BLOCKHASH range =================================================

test "parity: BLOCKHASH out of 256-block range returns 0" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var context = evm.ExecutionContext.default();
    context.block_number = 300;
    var vm = try evm.EVM.initWithContext(allocator, 1_000_000, context);
    defer vm.deinit();

    // block_number=300, valid range is [44, 299].
    // Block 43 is out of range.  Set a hash for it anyway to prove it is rejected.
    var hbytes = [_]u8{0} ** 32;
    hbytes[31] = 0xBE;
    const hash = types.Hash{ .bytes = hbytes };
    try vm.setBlockHash(43, hash);

    const bytecode = [_]u8{
        0x60, 43, // PUSH1 43
        0x40, // BLOCKHASH
    };

    _ = try vm.execute(&bytecode, &[_]u8{});
    const result = try vm.stack.pop();
    try testing.expect(result.isZero());
}

test "parity: BLOCKHASH in range returns the configured hash" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var context = evm.ExecutionContext.default();
    context.block_number = 300;
    var vm = try evm.EVM.initWithContext(allocator, 1_000_000, context);
    defer vm.deinit();

    var hbytes = [_]u8{0} ** 32;
    hbytes[31] = 0xAA;
    hbytes[0] = 0x11;
    const hash = types.Hash{ .bytes = hbytes };
    try vm.setBlockHash(250, hash);

    const bytecode = [_]u8{
        0x60, 250, // PUSH1 250
        0x40, // BLOCKHASH
    };

    _ = try vm.execute(&bytecode, &[_]u8{});
    const result = try vm.stack.pop();
    // EVM converts hash via types.U256.fromBytes(hash.bytes), so we match.
    const expected = types.U256.fromBytes(hbytes);
    try testing.expect(result.eq(expected));
}

// ===== 15. EXTCODECOPY of empty account ====================================

test "parity: EXTCODECOPY of non-existent account writes zeros to memory" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    const context = evm.ExecutionContext.default();
    var vm = try evm.EVM.initWithState(allocator, 1_000_000, context, &db);
    defer vm.deinit();

    // EXTCODECOPY pops: address, destOffset, codeOffset, size (top to bottom).
    // Push in reverse order so the first to pop (address) is on top.
    const bytecode = [_]u8{
        0x60, 0x20, // PUSH1 32 (size -- deepest)
        0x60, 0x00, // PUSH1 0  (codeOffset)
        0x60, 0x00, // PUSH1 0  (destOffset)
        0x60, 0xff, // PUSH1 0xFF (address -- top)
        0x3c, // EXTCODECOPY
    };

    _ = try vm.execute(&bytecode, &[_]u8{});

    // Memory[0..32] should be all zeros
    for (0..32) |i| {
        const byte = vm.memory.data.items[i];
        try testing.expectEqual(@as(u8, 0), byte);
    }
}
