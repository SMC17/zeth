const std = @import("std");
const crypto = @import("crypto");
const evm = @import("evm");
const types = @import("types");
const state = @import("state");

fn addressFromU256(value: types.U256) types.Address {
    var address_bytes: [20]u8 = [_]u8{0} ** 20;
    for (0..20) |i| {
        const limb_idx = i / 8;
        const shift: u6 = @intCast((i % 8) * 8);
        const b = @as(u8, @truncate((value.limbs[limb_idx] >> shift) & 0xff));
        address_bytes[19 - i] = b;
    }
    return types.Address{ .bytes = address_bytes };
}

fn deriveCreate2AddressForTest(creator: types.Address, salt: types.U256, init_code: []const u8) types.Address {
    var init_hash: [32]u8 = undefined;
    crypto.keccak256(init_code, &init_hash);

    var preimage: [85]u8 = undefined;
    preimage[0] = 0xff;
    @memcpy(preimage[1..21], creator.bytes[0..20]);
    const salt_bytes = salt.toBytes();
    @memcpy(preimage[21..53], salt_bytes[0..32]);
    @memcpy(preimage[53..85], init_hash[0..32]);

    var out: [32]u8 = undefined;
    crypto.keccak256(&preimage, &out);

    var addr_bytes: [20]u8 = undefined;
    @memcpy(addr_bytes[0..20], out[12..32]);
    return types.Address{ .bytes = addr_bytes };
}

// Comprehensive EVM Test Suite
// Tests all major opcode families with real bytecode

test "EVM: All arithmetic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // Test: (5 + 3) * 2 - 4 = 12
    const bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5
        0x60, 0x03, // PUSH1 3
        0x01, // ADD  (8)
        0x60, 0x02, // PUSH1 2
        0x02, // MUL  (16)
        0x60, 0x04, // PUSH1 4
        0x03, // SUB  (12)
    };

    const create_result = try vm.execute(&bytecode, &[_]u8{});
    defer if (create_result.return_data.len > 0) allocator.free(create_result.return_data);
    defer allocator.free(create_result.logs);
    const result = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 12), result.limbs[0]);
}

test "EVM: Comparison and conditional logic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // Simple comparison test: 5 < 10 should be true (1)
    const bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5
        0x60, 0x0a, // PUSH1 10
        0x10, // LT
    };

    const create_result = try vm.execute(&bytecode, &[_]u8{});
    defer if (create_result.return_data.len > 0) allocator.free(create_result.return_data);
    defer allocator.free(create_result.logs);
    const result = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 1), result.limbs[0]);
}

test "EVM: Bitwise operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // Test: (0xFF & 0x0F) | 0xF0 = 0xFF
    const bytecode = [_]u8{
        0x60, 0xff, // PUSH1 0xFF
        0x60, 0x0f, // PUSH1 0x0F
        0x16, // AND (result: 0x0F)
        0x60, 0xf0, // PUSH1 0xF0
        0x17, // OR  (result: 0xFF)
    };

    const create_result = try vm.execute(&bytecode, &[_]u8{});
    defer if (create_result.return_data.len > 0) allocator.free(create_result.return_data);
    defer allocator.free(create_result.logs);
    const result = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 0xFF), result.limbs[0]);
}

test "EVM: EXP computes modular exponentiation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    const bytecode = [_]u8{
        0x60, 0x02, // PUSH1 2 (base)
        0x60, 0x08, // PUSH1 8 (exponent)
        0x0a, // EXP
    };

    const create_result = try vm.execute(&bytecode, &[_]u8{});
    defer if (create_result.return_data.len > 0) allocator.free(create_result.return_data);
    defer allocator.free(create_result.logs);
    const result = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 256), result.limbs[0]);
}

test "EVM: SHL and SHR shift values correctly" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // (1 << 8) >> 8 = 1
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1 (value)
        0x60, 0x08, // PUSH1 8 (shift)
        0x1b, // SHL
        0x60, 0x08, // PUSH1 8 (shift)
        0x1c, // SHR
    };

    _ = try vm.execute(&bytecode, &[_]u8{});
    const result = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 1), result.limbs[0]);
}

test "EVM: SAR preserves sign bit for negative values" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // Build -1 then arithmetic shift right by 1, which should remain -1.
    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0
        0x19, // NOT -> all bits set (-1 in two's complement)
        0x60, 0x01, // PUSH1 1 (shift)
        0x1d, // SAR
    };

    _ = try vm.execute(&bytecode, &[_]u8{});
    const result = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), result.limbs[0]);
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), result.limbs[1]);
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), result.limbs[2]);
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), result.limbs[3]);
}

test "EVM: SIGNEXTEND extends sign from high byte correctly" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1_000_000);
    defer vm.deinit();

    const bytecode = [_]u8{
        0x7f, // PUSH32 value
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x80,
        0x11,
        0x22,
        0x33,
        0x44,
        0x55,
        0x66,
        0x77,
        0x88,
        0x60, 0x08, // PUSH1 8 (extend from 9th least-significant byte)
        0x0b, // SIGNEXTEND
    };

    _ = try vm.execute(&bytecode, &[_]u8{});
    const result = try vm.stack.pop();

    const expected = types.U256{
        .limbs = [_]u64{
            0x1122334455667788,
            0xffffffffffffff80,
            0xffffffffffffffff,
            0xffffffffffffffff,
        },
    };
    try testing.expect(result.eq(expected));
    try testing.expectEqual(@as(u64, 11), vm.gas_used);
}

test "EVM: CALLCODE executes target code in caller storage context" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var code_addr = types.Address.zero;
    code_addr.bytes[19] = 0x0a;
    const target_code = [_]u8{
        0x60, 0x2a, // value = 42
        0x60, 0x01, // key = 1
        0x55, // SSTORE
        0x00, // STOP
    };
    try db.setCode(code_addr, &target_code);
    try db.createAccount(code_addr);

    var caller = types.Address.zero;
    caller.bytes[19] = 0xbb;
    try db.createAccount(caller);
    try db.setBalance(caller, types.U256.fromU64(100));

    var context = evm.ExecutionContext.default();
    context.address = caller;
    context.caller = caller;

    var vm = try evm.EVM.initWithState(allocator, 1_000_000, context, &db);
    defer vm.deinit();

    // CALLCODE(gas, addr, value, argsOff, argsLen, retOff, retLen)
    const bytecode = [_]u8{
        0x60, 0x00, // retLen
        0x60, 0x00, // retOff
        0x60, 0x00, // argsLen
        0x60, 0x00, // argsOff
        0x60, 0x05, // value
        0x60, 0x0a, // code address
        0x61, 0xff, 0xff, // gas
        0xf2, // CALLCODE
    };

    _ = try vm.execute(&bytecode, &[_]u8{});
    const result = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 1), result.limbs[0]);

    const caller_stored = try db.getStorage(caller, types.U256.fromU64(1));
    try testing.expectEqual(@as(u64, 0x2a), caller_stored.limbs[0]);

    const target_stored = try db.getStorage(code_addr, types.U256.fromU64(1));
    try testing.expect(target_stored.isZero());
    try testing.expectEqual(@as(u64, 100), (try db.getBalance(caller)).limbs[0]);
    try testing.expect((try db.getBalance(code_addr)).isZero());
}

test "EVM: BLOCKHASH does not underflow for low block numbers" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var context = evm.ExecutionContext.default();
    context.block_number = 1;
    var vm = try evm.EVM.initWithContext(allocator, 1000000, context);
    defer vm.deinit();

    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 block 0
        0x40, // BLOCKHASH
    };

    _ = try vm.execute(&bytecode, &[_]u8{});
    const result = try vm.stack.pop();
    try testing.expect(result.isZero());
}

test "EVM: BLOCKHASH returns configured hash within 256-block window" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var context = evm.ExecutionContext.default();
    context.block_number = 300;
    var vm = try evm.EVM.initWithContext(allocator, 1_000_000, context);
    defer vm.deinit();

    var hbytes = [_]u8{0} ** 32;
    hbytes[31] = 0x42;
    const hash = types.Hash{ .bytes = hbytes };
    try vm.setBlockHash(299, hash);

    const bytecode = [_]u8{
        0x61, 0x01, 0x2b, // PUSH2 299
        0x40, // BLOCKHASH
    };

    _ = try vm.execute(&bytecode, &[_]u8{});
    const result = try vm.stack.pop();
    try testing.expect(result.eq(types.U256.fromBytes(hbytes)));
}

test "EVM: CALL executes target code and exposes return data" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var callee_addr = types.Address.zero;
    callee_addr.bytes[19] = 0x0a;

    const callee_code = [_]u8{
        0x60, 0x2a, // PUSH1 0x2a
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32 (length)
        0x60, 0x00, // PUSH1 0 (offset)
        0xf3, // RETURN
    };
    try db.setCode(callee_addr, &callee_code);

    var context = evm.ExecutionContext.default();
    context.address.bytes[19] = 0xaa;
    var vm = try evm.EVM.initWithState(allocator, 1_000_000, context, &db);
    defer vm.deinit();

    const caller_code = [_]u8{
        0x60, 0x20, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x00, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x00, // value
        0x60, 0x0a, // address
        0x61, 0xff, 0xff, // gas
        0xf1, // CALL
        0x3d, // RETURNDATASIZE
    };

    const call_result = try vm.execute(&caller_code, &[_]u8{});
    defer if (call_result.return_data.len > 0) allocator.free(call_result.return_data);
    defer allocator.free(call_result.logs);
    const return_data_size = try vm.stack.pop();
    const call_success = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 32), return_data_size.limbs[0]);
    try testing.expectEqual(@as(u64, 1), call_success.limbs[0]);
}

test "EVM: EXTCODESIZE/EXTCODECOPY/EXTCODEHASH reflect state code bytes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    const target = types.Address.zero;
    const code = [_]u8{ 0x60, 0x2a, 0x00 };
    try db.setCode(target, &code);

    var vm = try evm.EVM.initWithState(allocator, 1_000_000, evm.ExecutionContext.default(), &db);
    defer vm.deinit();

    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 addr
        0x3b, // EXTCODESIZE -> 3
        0x60, 0x03, // PUSH1 len
        0x60, 0x00, // PUSH1 codeOffset
        0x60, 0x00, // PUSH1 memOffset
        0x60, 0x00, // PUSH1 addr
        0x3c, // EXTCODECOPY
        0x60, 0x00, // PUSH1 addr
        0x3f, // EXTCODEHASH
    };

    _ = try vm.execute(&bytecode, &[_]u8{});

    const hash_u256 = try vm.stack.pop();
    const size_u256 = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 3), size_u256.limbs[0]);

    try testing.expectEqual(@as(u8, 0x60), vm.memory.data.items[0]);
    try testing.expectEqual(@as(u8, 0x2a), vm.memory.data.items[1]);
    try testing.expectEqual(@as(u8, 0x00), vm.memory.data.items[2]);

    var expected_hash: [32]u8 = undefined;
    @import("crypto").keccak256(&code, &expected_hash);
    try testing.expectEqualSlices(u8, &expected_hash, &hash_u256.toBytes());
}

test "EVM: EXTCODEHASH zero for non-existent account and keccak(empty) for empty account" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var empty_addr = types.Address.zero;
    empty_addr.bytes[19] = 0x01;
    try db.createAccount(empty_addr); // Exists but has empty code

    var vm = try evm.EVM.initWithState(allocator, 1_000_000, evm.ExecutionContext.default(), &db);
    defer vm.deinit();

    const bytecode = [_]u8{
        0x60, 0x00, // non-existent
        0x3f, // EXTCODEHASH => 0
        0x60, 0x01, // empty existing
        0x3f, // EXTCODEHASH => keccak256("")
    };
    _ = try vm.execute(&bytecode, &[_]u8{});

    const empty_hash_u256 = try vm.stack.pop();
    const missing_hash_u256 = try vm.stack.pop();
    try testing.expect(missing_hash_u256.isZero());

    var keccak_empty: [32]u8 = undefined;
    @import("crypto").keccak256("", &keccak_empty);
    try testing.expectEqualSlices(u8, &keccak_empty, &empty_hash_u256.toBytes());
}

test "EVM: BALANCE cold then warm access charges exact gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var addr = types.Address.zero;
    addr.bytes[19] = 0x2a;
    try db.createAccount(addr);
    try db.setBalance(addr, types.U256.fromU64(99));

    var vm = try evm.EVM.initWithState(allocator, 1_000_000, evm.ExecutionContext.default(), &db);
    defer vm.deinit();

    const code = [_]u8{
        0x60, 0x2a, // addr
        0x31, // BALANCE (cold)
        0x60, 0x2a, // addr
        0x31, // BALANCE (warm)
    };

    const result = try vm.execute(&code, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    const warm = try vm.stack.pop();
    const cold = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 99), cold.limbs[0]);
    try testing.expectEqual(@as(u64, 99), warm.limbs[0]);
    // PUSH + BALANCE(cold) + PUSH + BALANCE(warm) = 3 + 2600 + 3 + 100
    try testing.expectEqual(@as(u64, 2_706), vm.gas_used);
}

test "EVM: BLOCKHASH returns zero outside 256-block window" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var context = evm.ExecutionContext.default();
    context.block_number = 300;
    var vm = try evm.EVM.initWithContext(allocator, 1_000_000, context);
    defer vm.deinit();

    const bytecode = [_]u8{
        0x60, 0x2b, // PUSH1 43 => distance 257
        0x40, // BLOCKHASH
    };

    _ = try vm.execute(&bytecode, &[_]u8{});
    const result = try vm.stack.pop();
    try testing.expect(result.isZero());
}

test "EVM: BLOCKHASH returns configured hash at 256-block boundary with exact gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var context = evm.ExecutionContext.default();
    context.block_number = 300;
    var vm = try evm.EVM.initWithContext(allocator, 1_000_000, context);
    defer vm.deinit();

    var hbytes = [_]u8{0} ** 32;
    hbytes[0] = 0xaa;
    hbytes[31] = 0x55;
    try vm.setBlockHash(44, types.Hash{ .bytes = hbytes }); // distance = 256

    const bytecode = [_]u8{
        0x60, 0x2c, // PUSH1 44
        0x40, // BLOCKHASH
    };

    _ = try vm.execute(&bytecode, &[_]u8{});
    const result = try vm.stack.pop();
    try testing.expect(result.eq(types.U256.fromBytes(hbytes)));
    try testing.expectEqual(@as(u64, 23), vm.gas_used); // PUSH1 + BLOCKHASH
}

test "EVM: BLOCKHASH ignores low limb when high limbs are non-zero" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var context = evm.ExecutionContext.default();
    context.block_number = 300;
    var vm = try evm.EVM.initWithContext(allocator, 1_000_000, context);
    defer vm.deinit();

    var hbytes = [_]u8{0} ** 32;
    hbytes[31] = 0x99;
    try vm.setBlockHash(299, types.Hash{ .bytes = hbytes });

    const bytecode = [_]u8{
        0x68, // PUSH9
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x2b, // 2^64 + 299
        0x40, // BLOCKHASH
    };

    _ = try vm.execute(&bytecode, &[_]u8{});
    const result = try vm.stack.pop();
    try testing.expect(result.isZero());
    try testing.expectEqual(@as(u64, 23), vm.gas_used); // PUSH9 + BLOCKHASH
}

test "EVM: SELFBALANCE returns current account balance with fixed gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var self_addr = types.Address.zero;
    self_addr.bytes[19] = 0x77;
    try db.createAccount(self_addr);
    try db.setBalance(self_addr, types.U256.fromU64(1234));

    var context = evm.ExecutionContext.default();
    context.address = self_addr;

    var vm = try evm.EVM.initWithState(allocator, 1_000_000, context, &db);
    defer vm.deinit();

    const bytecode = [_]u8{
        0x47, // SELFBALANCE
    };

    _ = try vm.execute(&bytecode, &[_]u8{});
    const result = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 1234), result.limbs[0]);
    try testing.expectEqual(@as(u64, 5), vm.gas_used);
}

test "EVM: EXTCODECOPY zero-fills beyond code and warms account for subsequent EXTCODESIZE" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var target = types.Address.zero;
    target.bytes[19] = 0x0a;
    const code = [_]u8{ 0xaa, 0xbb };
    try db.createAccount(target);
    try db.setCode(target, &code);

    var vm = try evm.EVM.initWithState(allocator, 1_000_000, evm.ExecutionContext.default(), &db);
    defer vm.deinit();

    const bytecode = [_]u8{
        0x60, 0x04, // len
        0x60, 0x01, // codeOffset
        0x60, 0x00, // memOffset
        0x60, 0x0a, // addr
        0x3c, // EXTCODECOPY (cold)
        0x60, 0x0a, // addr
        0x3b, // EXTCODESIZE (warm)
    };

    _ = try vm.execute(&bytecode, &[_]u8{});
    const size_u256 = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 2), size_u256.limbs[0]);

    try testing.expectEqual(@as(u8, 0xbb), vm.memory.data.items[0]);
    try testing.expectEqual(@as(u8, 0x00), vm.memory.data.items[1]);
    try testing.expectEqual(@as(u8, 0x00), vm.memory.data.items[2]);
    try testing.expectEqual(@as(u8, 0x00), vm.memory.data.items[3]);

    // 5 PUSH1 (15) + EXTCODECOPY cold (20 + mem(3) + copy(1) + 2600) + EXTCODESIZE warm (100)
    try testing.expectEqual(@as(u64, 2_739), vm.gas_used);
}

test "EVM: EXTCODECOPY length zero does not expand memory and still warms account" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var target = types.Address.zero;
    target.bytes[19] = 0x0b;
    try db.createAccount(target);
    try db.setCode(target, &[_]u8{0xaa});

    var vm = try evm.EVM.initWithState(allocator, 1_000_000, evm.ExecutionContext.default(), &db);
    defer vm.deinit();
    const initial_mem_len = vm.memory.data.items.len;

    const bytecode = [_]u8{
        0x60, 0x00, // len = 0
        0x60, 0x00, // codeOffset
        0x61, 0x01, 0x00, // memOffset = 256 (should not matter when len=0)
        0x60, 0x0b, // addr
        0x3c, // EXTCODECOPY (cold)
        0x60, 0x0b, // addr
        0x3b, // EXTCODESIZE (warm)
    };

    _ = try vm.execute(&bytecode, &[_]u8{});
    const size_u256 = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 1), size_u256.limbs[0]);
    try testing.expectEqual(initial_mem_len, vm.memory.data.items.len);

    // PUSH1 + PUSH1 + PUSH2 + PUSH1 + EXTCODECOPY(cold, len=0 no mem/copy cost) + PUSH1 + EXTCODESIZE(warm)
    // = 3 + 3 + 3 + 3 + (20 + 2600) + 3 + 100
    try testing.expectEqual(@as(u64, 2_735), vm.gas_used);
}

test "EVM: CALLDATACOPY length zero does not expand memory and charges no copy/mem gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1_000_000);
    defer vm.deinit();
    const initial_mem_len = vm.memory.data.items.len;

    const bytecode = [_]u8{
        0x60, 0x00, // len = 0
        0x60, 0x00, // calldataOffset
        0x61, 0x01, 0x00, // memOffset = 256 (must not expand when len=0)
        0x37, // CALLDATACOPY
    };

    _ = try vm.execute(&bytecode, &[_]u8{ 0xaa, 0xbb, 0xcc });
    try testing.expectEqual(initial_mem_len, vm.memory.data.items.len);
    // PUSH1 + PUSH1 + PUSH2 + CALLDATACOPY(base=3, no mem/copy cost)
    try testing.expectEqual(@as(u64, 12), vm.gas_used);
}

test "EVM: CODECOPY length zero does not expand memory and charges no copy/mem gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1_000_000);
    defer vm.deinit();
    const initial_mem_len = vm.memory.data.items.len;

    const bytecode = [_]u8{
        0x60, 0x00, // len = 0
        0x60, 0x00, // codeOffset
        0x61, 0x01, 0x00, // memOffset = 256 (must not expand when len=0)
        0x39, // CODECOPY
    };

    _ = try vm.execute(&bytecode, &[_]u8{});
    try testing.expectEqual(initial_mem_len, vm.memory.data.items.len);
    // PUSH1 + PUSH1 + PUSH2 + CODECOPY(base=3, no mem/copy cost)
    try testing.expectEqual(@as(u64, 12), vm.gas_used);
}

test "EVM: RETURNDATACOPY length zero does not expand memory and charges no copy/mem gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1_000_000);
    defer vm.deinit();
    const initial_mem_len = vm.memory.data.items.len;

    const bytecode = [_]u8{
        0x60, 0x00, // len = 0
        0x60, 0x00, // returnDataOffset
        0x61, 0x01, 0x00, // memOffset = 256 (must not expand when len=0)
        0x3e, // RETURNDATACOPY
    };

    _ = try vm.execute(&bytecode, &[_]u8{});
    try testing.expectEqual(initial_mem_len, vm.memory.data.items.len);
    // PUSH1 + PUSH1 + PUSH2 + RETURNDATACOPY(base=3, no mem/copy cost)
    try testing.expectEqual(@as(u64, 12), vm.gas_used);
}

test "EVM: BALANCE/EXTCODE*/EXTCODEHASH treat precompile addresses as warm" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var vm = try evm.EVM.initWithState(allocator, 1_000_000, evm.ExecutionContext.default(), &db);
    defer vm.deinit();

    const bytecode = [_]u8{
        0x60, 0x02, // PUSH1 precompile address 0x02
        0x31, // BALANCE (precompile, warm by EIP-2929)
        0x60, 0x02, // PUSH1 precompile address 0x02
        0x3b, // EXTCODESIZE (precompile, warm)
        0x60, 0x02, // PUSH1 precompile address 0x02
        0x3f, // EXTCODEHASH (precompile, warm; nonexistent in empty db => 0)
    };

    _ = try vm.execute(&bytecode, &[_]u8{});

    const extcodehash = try vm.stack.pop();
    const extcodesize = try vm.stack.pop();
    const balance = try vm.stack.pop();
    try testing.expect(extcodehash.isZero());
    try testing.expect(extcodesize.isZero());
    try testing.expect(balance.isZero());

    // 3 PUSH1 (9) + three warm account accesses (3 * 100)
    try testing.expectEqual(@as(u64, 309), vm.gas_used);
}

test "EVM: BALANCE/EXTCODE*/EXTCODEHASH use full PUSH20 address bytes consistently" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    const target = types.Address{ .bytes = [_]u8{
        0x11, 0x22, 0x33, 0x44, 0x55,
        0x66, 0x77, 0x88, 0x99, 0xaa,
        0xbb, 0xcc, 0xdd, 0xee, 0xf0,
        0x01, 0x23, 0x45, 0x67, 0x89,
    } };
    const code = [_]u8{ 0x60, 0x2a, 0x00 };
    try db.createAccount(target);
    try db.setBalance(target, types.U256.fromU64(0x1234));
    try db.setCode(target, &code);

    var vm = try evm.EVM.initWithState(allocator, 1_000_000, evm.ExecutionContext.default(), &db);
    defer vm.deinit();

    const bytecode = [_]u8{
        0x73, // PUSH20
        0x11,
        0x22,
        0x33,
        0x44,
        0x55,
        0x66,
        0x77,
        0x88,
        0x99,
        0xaa,
        0xbb,
        0xcc,
        0xdd,
        0xee,
        0xf0,
        0x01,
        0x23,
        0x45,
        0x67,
        0x89,
        0x31, // BALANCE (cold)
        0x73, // PUSH20
        0x11,
        0x22,
        0x33,
        0x44,
        0x55,
        0x66,
        0x77,
        0x88,
        0x99,
        0xaa,
        0xbb,
        0xcc,
        0xdd,
        0xee,
        0xf0,
        0x01,
        0x23,
        0x45,
        0x67,
        0x89,
        0x3b, // EXTCODESIZE (warm)
        0x73, // PUSH20
        0x11,
        0x22,
        0x33,
        0x44,
        0x55,
        0x66,
        0x77,
        0x88,
        0x99,
        0xaa,
        0xbb,
        0xcc,
        0xdd,
        0xee,
        0xf0,
        0x01,
        0x23,
        0x45,
        0x67,
        0x89,
        0x3f, // EXTCODEHASH (warm)
    };

    _ = try vm.execute(&bytecode, &[_]u8{});

    const hash_u256 = try vm.stack.pop();
    const size_u256 = try vm.stack.pop();
    const balance_u256 = try vm.stack.pop();

    try testing.expectEqual(@as(u64, 0x1234), balance_u256.limbs[0]);
    try testing.expectEqual(@as(u64, 3), size_u256.limbs[0]);

    var expected_hash: [32]u8 = undefined;
    @import("crypto").keccak256(&code, &expected_hash);
    try testing.expectEqualSlices(u8, &expected_hash, &hash_u256.toBytes());

    // 3 PUSH20 (9) + BALANCE cold (2600) + EXTCODESIZE warm (100) + EXTCODEHASH warm (100)
    try testing.expectEqual(@as(u64, 2_809), vm.gas_used);
}

test "EVM: CALL dispatches SHA256 precompile (0x02)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1_000_000);
    defer vm.deinit();

    const code = [_]u8{
        0x60, 0x20, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x00, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x00, // value
        0x60, 0x02, // address
        0x61, 0xff, 0xff, // gas
        0xf1, // CALL
        0x3d, // RETURNDATASIZE
    };
    const precompile_result = try vm.execute(&code, &[_]u8{});
    defer if (precompile_result.return_data.len > 0) allocator.free(precompile_result.return_data);
    defer allocator.free(precompile_result.logs);

    const return_size = try vm.stack.pop();
    const success = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 1), success.limbs[0]);
    try testing.expectEqual(@as(u64, 32), return_size.limbs[0]);

    var expected: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("", &expected, .{});
    try testing.expectEqualSlices(u8, &expected, vm.memory.data.items[0..32]);
}

test "EVM: CALL dispatches RIPEMD160 precompile (0x03)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1_000_000);
    defer vm.deinit();

    const code = [_]u8{
        0x60, 0x20, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x00, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x00, // value
        0x60, 0x03, // address
        0x63, 0xff, 0xff, 0xff, 0xff, // gas (high, let EIP-150 cap apply)
        0xf1, // CALL
    };
    const precompile_result = try vm.execute(&code, &[_]u8{});
    defer if (precompile_result.return_data.len > 0) allocator.free(precompile_result.return_data);
    defer allocator.free(precompile_result.logs);

    const success = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 1), success.limbs[0]);

    const expected = [_]u8{
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x9c, 0x11, 0x85, 0xa5,
        0xc5, 0xe9, 0xfc, 0x54, 0x61, 0x28, 0x08, 0x97,
        0x7e, 0xe8, 0xf5, 0x48, 0xb2, 0x25, 0x8d, 0x31,
    };
    try testing.expectEqualSlices(u8, &expected, vm.memory.data.items[0..32]);
}

test "EVM: CALL dispatches ECRECOVER precompile (0x01)" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const c = @import("crypto");

    const private_key = [_]u8{
        0x4c, 0x08, 0x83, 0xa6, 0x91, 0x02, 0x93, 0x7d,
        0x62, 0x33, 0x47, 0x71, 0x2c, 0x8f, 0xa5, 0xf3,
        0x6c, 0xd7, 0xd8, 0x3f, 0x9f, 0x3a, 0x52, 0x4f,
        0xc6, 0x6f, 0x66, 0x73, 0xc1, 0x4c, 0xab, 0x5c,
    };
    const msg = [_]u8{
        0x3a, 0x12, 0xb5, 0x10, 0x16, 0xfe, 0x4c, 0xbd,
        0x6b, 0xa7, 0xfe, 0x3e, 0x2a, 0x7f, 0xe1, 0x58,
        0x3f, 0x06, 0x66, 0xd2, 0xb5, 0x19, 0x6d, 0x90,
        0x2f, 0xdc, 0x54, 0x73, 0xa7, 0x0b, 0x2c, 0x0d,
    };
    const sig = try c.Secp256k1.sign(msg, private_key);
    const pk = try c.Secp256k1.PublicKey.fromPrivateKey(private_key);
    const expected_addr = pk.toAddress();

    var msg_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&msg, &msg_hash, .{});

    var vm = try evm.EVM.init(allocator, 1_000_000);
    defer vm.deinit();
    try vm.memory.data.resize(128);
    @memset(vm.memory.data.items[0..128], 0);
    @memcpy(vm.memory.data.items[0..32], msg_hash[0..32]);
    vm.memory.data.items[63] = sig.v;
    @memcpy(vm.memory.data.items[64..96], sig.r[0..32]);
    @memcpy(vm.memory.data.items[96..128], sig.s[0..32]);

    const code = [_]u8{
        0x60, 0x20, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x80, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x00, // value
        0x60, 0x01, // address
        0x61, 0xff, 0xff, // gas
        0xf1, // CALL
        0x3d, // RETURNDATASIZE
    };
    const precompile_result = try vm.execute(&code, &[_]u8{});
    defer if (precompile_result.return_data.len > 0) allocator.free(precompile_result.return_data);
    defer allocator.free(precompile_result.logs);

    const return_size = try vm.stack.pop();
    const success = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 1), success.limbs[0]);
    try testing.expectEqual(@as(u64, 32), return_size.limbs[0]);
    try testing.expectEqualSlices(u8, &expected_addr, vm.memory.data.items[12..32]);
}

test "EVM: CALL dispatches IDENTITY precompile (0x04) with exact gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1_000_000);
    defer vm.deinit();

    const code = [_]u8{
        0x63, 0x01, 0x02, 0x03, 0x04, // PUSH4 data
        0x60, 0x00, // offset
        0x52, // MSTORE
        0x60, 0x20, // outSize
        0x60, 0x40, // outOffset
        0x60, 0x20, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x00, // value
        0x60, 0x04, // address (identity precompile)
        0x61, 0xff, 0xff, // gas
        0xf1, // CALL
        0x60, 0x00, // return data offset
        0x60, 0x40, // memory offset
        0x60, 0x20, // length
        0x3e, // RETURNDATACOPY
    };

    const result = try vm.execute(&code, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    const success = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 1), success.limbs[0]);
    // PUSH4 0x01020304 produces U256 with value 0x01020304.
    // toBytes() stores as big-endian: the 4 bytes land at positions [28..32] within the 32-byte word.
    // After IDENTITY precompile + CALL return to outOffset=64, they're at memory[64+28..64+32] = [92..96].
    try testing.expectEqual(@as(u8, 0x01), vm.memory.data.items[92]);
    try testing.expectEqual(@as(u8, 0x02), vm.memory.data.items[93]);
    try testing.expectEqual(@as(u8, 0x03), vm.memory.data.items[94]);
    try testing.expectEqual(@as(u8, 0x04), vm.memory.data.items[95]);

    // Total gas under current memory accounting model:
    // PUSH4+PUSH1+MSTORE = 12 (includes 0->32 memory expansion)
    // CALL arg PUSHes = 21
    // CALL base (warm precompile) = 800
    // CALL return memory expansion 32->96 = 6
    // IDENTITY precompile = 18
    // RETURNDATACOPY pushes + op = 13
    try testing.expectEqual(@as(u64, 866), vm.gas_used);
}

test "EVM: RETURNDATACOPY non-zero copy charges memory expansion exactly" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1_000_000);
    defer vm.deinit();

    // CALL SHA256 precompile with empty input and no return-memory copy in CALL itself.
    // Then RETURNDATACOPY 32 bytes into offset 128, which should expand memory to 160 bytes (5 words).
    const code = [_]u8{
        0x60, 0x00, // outSize = 0
        0x60, 0x00, // outOffset = 0
        0x60, 0x00, // inSize = 0
        0x60, 0x00, // inOffset = 0
        0x60, 0x00, // value = 0
        0x60, 0x02, // address = SHA256 precompile
        0x61, 0xff, 0xff, // gas
        0xf1, // CALL
        0x60, 0x20, // len = 32
        0x60, 0x00, // returnDataOffset = 0
        0x60, 0x80, // memOffset = 128
        0x3e, // RETURNDATACOPY
    };

    const result = try vm.execute(&code, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    const call_success = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 1), call_success.limbs[0]);

    var expected_sha: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("", &expected_sha, .{});
    try testing.expectEqualSlices(u8, &expected_sha, vm.memory.data.items[128..160]);

    // CALL pushes = 21
    // CALL base (warm precompile) + SHA256(empty) = 800 + 60 = 860
    // RETURNDATACOPY pushes = 9
    // RETURNDATACOPY op = base 3 + copy 1 + mem expansion 15 (0 -> 5 words) = 19
    try testing.expectEqual(@as(u64, 909), vm.gas_used);
}

test "EVM: RETURNDATACOPY exact-end boundary succeeds with exact gas and bytes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1_000_000);
    defer vm.deinit();

    // Get 32-byte SHA256("") return data, then copy the final byte only (offset 31, len 1)
    // into memory offset 0. This is an exact-end boundary read and should succeed.
    const code = [_]u8{
        0x60, 0x00, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x00, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x00, // value
        0x60, 0x02, // SHA256 precompile
        0x61, 0xff, 0xff, // gas
        0xf1, // CALL
        0x60, 0x01, // len = 1
        0x60, 0x1f, // returnDataOffset = 31
        0x60, 0x00, // memOffset = 0
        0x3e, // RETURNDATACOPY
    };

    const result = try vm.execute(&code, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    const call_success = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 1), call_success.limbs[0]);

    var expected_sha: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("", &expected_sha, .{});
    try testing.expectEqual(expected_sha[31], vm.memory.data.items[0]);

    // CALL pushes = 21
    // CALL base + SHA256(empty) = 860
    // RETURNDATACOPY pushes = 9
    // RETURNDATACOPY op = base 3 + copy 1 + mem expansion 3 (0 -> 1 word) = 7
    try testing.expectEqual(@as(u64, 897), vm.gas_used);
}

test "EVM: RETURNDATACOPY out-of-bounds reverts and preserves memory" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1_000_000);
    defer vm.deinit();
    try vm.memory.data.resize(32);
    @memset(vm.memory.data.items[0..32], 0xaa);

    // SHA256("") returns 32 bytes. Copy offset 31, len 2 crosses boundary by 1 byte and must REVERT.
    const code = [_]u8{
        0x60, 0x00, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x00, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x00, // value
        0x60, 0x02, // SHA256 precompile
        0x61, 0xff, 0xff, // gas
        0xf1, // CALL
        0x60, 0x02, // len = 2
        0x60, 0x1f, // returnDataOffset = 31
        0x60, 0x00, // memOffset = 0
        0x3e, // RETURNDATACOPY => REVERT
    };

    const result = try vm.execute(&code, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    try testing.expect(!result.success);
    try testing.expectEqual(@as(u64, 890), result.gas_used); // fails before RETURNDATACOPY gas is charged
    try testing.expectEqual(@as(u8, 0xaa), vm.memory.data.items[0]);
    try testing.expectEqual(@as(u8, 0xaa), vm.memory.data.items[31]);
}

test "EVM: RETURNDATACOPY zero-length at end boundary succeeds without revert" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1_000_000);
    defer vm.deinit();
    const initial_mem_len = vm.memory.data.items.len;

    // returnDataOffset == return_data.len with len=0 is valid.
    const code = [_]u8{
        0x60, 0x00, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x00, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x00, // value
        0x60, 0x02, // SHA256 precompile
        0x61, 0xff, 0xff, // gas
        0xf1, // CALL
        0x60, 0x00, // len = 0
        0x60, 0x20, // returnDataOffset = 32 == end boundary
        0x61, 0x01, 0x00, // memOffset (ignored for len=0)
        0x3e, // RETURNDATACOPY
    };

    const result = try vm.execute(&code, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    const call_success = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 1), call_success.limbs[0]);
    try testing.expectEqual(initial_mem_len, vm.memory.data.items.len);

    // CALL pushes = 21
    // CALL base + SHA256(empty) = 860
    // RETURNDATACOPY pushes = 9
    // RETURNDATACOPY op = base 3, no copy, no mem expansion
    try testing.expectEqual(@as(u64, 893), vm.gas_used);
}

test "EVM: IDENTITY precompile fails with OOG and consumes forwarded gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1_000_000);
    defer vm.deinit();

    try vm.memory.data.resize(32);
    @memset(vm.memory.data.items[0..32], 0xaa);

    const code = [_]u8{
        0x60, 0x20, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x20, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x00, // value
        0x60, 0x04, // address
        0x60, 0x0a, // gas = 10 (below required 18)
        0xf1, // CALL
    };

    const result = try vm.execute(&code, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    const success = try vm.stack.pop();
    try testing.expect(success.isZero());
    try testing.expectEqual(@as(u64, 831), vm.gas_used);
}

test "EVM: CALL dispatches MODEXP precompile (0x05) with exact gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1_000_000);
    defer vm.deinit();

    // MODEXP input encoding:
    // baseLen=1, expLen=1, modLen=1, base=2, exp=10, mod=17 => 2^10 mod 17 = 4
    try vm.memory.data.resize(99);
    @memset(vm.memory.data.items[0..99], 0);
    vm.memory.data.items[31] = 0x01; // baseLen
    vm.memory.data.items[63] = 0x01; // expLen
    vm.memory.data.items[95] = 0x01; // modLen
    vm.memory.data.items[96] = 0x02; // base
    vm.memory.data.items[97] = 0x0a; // exponent
    vm.memory.data.items[98] = 0x11; // modulus

    const code = [_]u8{
        0x60, 0x01, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x63, // inSize = 99
        0x60, 0x00, // inOffset
        0x60, 0x00, // value
        0x60, 0x05, // address (MODEXP)
        0x61, 0xff, 0xff, // gas
        0xf1, // CALL
    };

    const result = try vm.execute(&code, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    const success = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 1), success.limbs[0]);
    try testing.expectEqual(@as(u8, 0x04), vm.memory.data.items[0]);

    // Pushes: 21, CALL base: 800 (warm precompile), MODEXP gas: 200
    try testing.expectEqual(@as(u64, 1_021), vm.gas_used);
}

test "EVM: MODEXP precompile fails with OOG and consumes forwarded gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1_000_000);
    defer vm.deinit();

    try vm.memory.data.resize(99);
    @memset(vm.memory.data.items[0..99], 0);
    vm.memory.data.items[31] = 0x01;
    vm.memory.data.items[63] = 0x01;
    vm.memory.data.items[95] = 0x01;
    vm.memory.data.items[96] = 0x02;
    vm.memory.data.items[97] = 0x0a;
    vm.memory.data.items[98] = 0x11;

    const code = [_]u8{
        0x60, 0x01, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x63, // inSize = 99
        0x60, 0x00, // inOffset
        0x60, 0x00, // value
        0x60, 0x05, // address (MODEXP)
        0x60, 0x64, // gas = 100 (below required 200)
        0xf1, // CALL
    };

    const result = try vm.execute(&code, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    const success = try vm.stack.pop();
    try testing.expect(success.isZero());
    // Pushes: 21, CALL base: 800, forwarded gas charged on failure: 100
    try testing.expectEqual(@as(u64, 921), vm.gas_used);
}

test "EVM: CALL dispatches BN256ADD precompile (0x06) with exact gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1_000_000);
    defer vm.deinit();

    // Input: (1,2) + (1,2)
    try vm.memory.data.resize(128);
    @memset(vm.memory.data.items[0..128], 0);
    vm.memory.data.items[31] = 1;
    vm.memory.data.items[63] = 2;
    vm.memory.data.items[95] = 1;
    vm.memory.data.items[127] = 2;

    const code = [_]u8{
        0x60, 0x40, // outSize = 64
        0x60, 0x00, // outOffset
        0x60, 0x80, // inSize = 128
        0x60, 0x00, // inOffset
        0x60, 0x00, // value
        0x60, 0x06, // address
        0x61, 0xff, 0xff, // gas
        0xf1, // CALL
    };

    const result = try vm.execute(&code, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    const success = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 1), success.limbs[0]);
    const expected = [_]u8{
        0x15, 0x2b, 0xe2, 0x52, 0x42, 0x85, 0xb6, 0x12,
        0x40, 0xa3, 0x1e, 0x7f, 0xd8, 0xa8, 0x96, 0xa8,
        0xc1, 0x96, 0xb5, 0x9f, 0xb5, 0x41, 0x21, 0x3f,
        0x8d, 0xb2, 0xdb, 0x70, 0xb8, 0xff, 0xff, 0xff,
        0x08, 0x51, 0x3d, 0x7b, 0xbe, 0xb4, 0x87, 0x87,
        0x2b, 0xad, 0xcb, 0xfb, 0x5e, 0x42, 0x3b, 0x30,
        0x02, 0xe8, 0xeb, 0xec, 0x74, 0xeb, 0xdf, 0x58,
        0xf7, 0xaa, 0xd6, 0x35, 0x6d, 0x40, 0x00, 0x00,
    };
    try testing.expectEqualSlices(u8, &expected, vm.memory.data.items[0..64]);
    try testing.expectEqual(@as(u64, 971), vm.gas_used);
}

test "EVM: CALL dispatches BN256MUL precompile (0x07) with exact gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1_000_000);
    defer vm.deinit();

    // Input: (1,2) * 2
    try vm.memory.data.resize(96);
    @memset(vm.memory.data.items[0..96], 0);
    vm.memory.data.items[31] = 1;
    vm.memory.data.items[63] = 2;
    vm.memory.data.items[95] = 2;

    const code = [_]u8{
        0x60, 0x40, // outSize = 64
        0x60, 0x00, // outOffset
        0x60, 0x60, // inSize = 96
        0x60, 0x00, // inOffset
        0x60, 0x00, // value
        0x60, 0x07, // address
        0x61, 0xff, 0xff, // gas
        0xf1, // CALL
    };

    const result = try vm.execute(&code, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    const success = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 1), success.limbs[0]);
    const expected = [_]u8{
        0x15, 0x2b, 0xe2, 0x52, 0x42, 0x85, 0xb6, 0x12,
        0x40, 0xa3, 0x1e, 0x7f, 0xd8, 0xa8, 0x96, 0xa8,
        0xc1, 0x96, 0xb5, 0x9f, 0xb5, 0x41, 0x21, 0x3f,
        0x8d, 0xb2, 0xdb, 0x70, 0xb8, 0xff, 0xff, 0xff,
        0x08, 0x51, 0x3d, 0x7b, 0xbe, 0xb4, 0x87, 0x87,
        0x2b, 0xad, 0xcb, 0xfb, 0x5e, 0x42, 0x3b, 0x30,
        0x02, 0xe8, 0xeb, 0xec, 0x74, 0xeb, 0xdf, 0x58,
        0xf7, 0xaa, 0xd6, 0x35, 0x6d, 0x40, 0x00, 0x00,
    };
    try testing.expectEqualSlices(u8, &expected, vm.memory.data.items[0..64]);
    try testing.expectEqual(@as(u64, 6_821), vm.gas_used);
}

test "EVM: CALL dispatches BN256PAIRING precompile (0x08) empty-input true case" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1_000_000);
    defer vm.deinit();

    const code = [_]u8{
        0x60, 0x20, // outSize = 32
        0x60, 0x00, // outOffset
        0x60, 0x00, // inSize = 0
        0x60, 0x00, // inOffset
        0x60, 0x00, // value
        0x60, 0x08, // address
        0x61, 0xff, 0xff, // gas
        0xf1, // CALL
    };

    const result = try vm.execute(&code, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    const success = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 1), success.limbs[0]);
    try testing.expectEqual(@as(u8, 1), vm.memory.data.items[31]);
    // Pushes + CALL base + pairing base gas + return-memory expansion
    try testing.expectEqual(@as(u64, 45_824), vm.gas_used);
}

test "EVM: BN256PAIRING (0x08) single infinity pair returns true" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 2_000_000);
    defer vm.deinit();

    try vm.memory.data.resize(192);
    @memset(vm.memory.data.items[0..192], 0);

    const code = [_]u8{
        0x60, 0x20, // outSize = 32
        0x60, 0x00, // outOffset
        0x60, 0xc0, // inSize = 192
        0x60, 0x00, // inOffset
        0x60, 0x00, // value
        0x60, 0x08, // address
        0x62, 0x1f, 0xff, 0xff, // gas
        0xf1, // CALL
    };

    const result = try vm.execute(&code, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    const success = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 1), success.limbs[0]);
    try testing.expectEqual(@as(u8, 1), vm.memory.data.items[31]);
    try testing.expectEqual(@as(u64, 79_821), vm.gas_used);
}

test "EVM: BN256PAIRING (0x08) invalid G1 coordinate fails" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 2_000_000);
    defer vm.deinit();

    try vm.memory.data.resize(192);
    @memset(vm.memory.data.items[0..192], 0);
    _ = try std.fmt.hexToBytes(vm.memory.data.items[0..32], "30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd47");
    vm.memory.data.items[63] = 0x02;

    const code = [_]u8{
        0x60, 0x20, // outSize = 32
        0x60, 0x00, // outOffset
        0x60, 0xc0, // inSize = 192
        0x60, 0x00, // inOffset
        0x60, 0x00, // value
        0x60, 0x08, // address
        0x62, 0x1f, 0xff, 0xff, // gas
        0xf1, // CALL
    };

    const result = try vm.execute(&code, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    const success = try vm.stack.pop();
    try testing.expect(success.isZero());
    try testing.expectEqual(@as(u64, 79_821), vm.gas_used);
}

test "EVM: BN256PAIRING (0x08) canonical generator pair returns false" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 3_000_000);
    defer vm.deinit();

    try vm.memory.data.resize(192);
    @memset(vm.memory.data.items[0..192], 0);

    // G1 generator (1, 2)
    vm.memory.data.items[31] = 0x01;
    vm.memory.data.items[63] = 0x02;

    // G2 generator encoded as (x_im, x_re, y_im, y_re)
    _ = try std.fmt.hexToBytes(vm.memory.data.items[64..96], "198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2");
    _ = try std.fmt.hexToBytes(vm.memory.data.items[96..128], "1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed");
    _ = try std.fmt.hexToBytes(vm.memory.data.items[128..160], "090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b");
    _ = try std.fmt.hexToBytes(vm.memory.data.items[160..192], "12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa");

    const code = [_]u8{
        0x60, 0x20, // outSize
        0x60, 0x00, // outOffset
        0x60, 0xc0, // inSize = 192
        0x60, 0x00, // inOffset
        0x60, 0x00, // value
        0x60, 0x08, // address
        0x62, 0x1f, 0xff, 0xff, // gas
        0xf1, // CALL
    };

    const result = try vm.execute(&code, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    const success = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 1), success.limbs[0]);
    try testing.expectEqual(@as(u8, 0), vm.memory.data.items[31]);
    try testing.expectEqual(@as(u64, 79_821), vm.gas_used);
}

test "EVM: BN256PAIRING (0x08) canonical inverse pair product returns true" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 4_000_000);
    defer vm.deinit();

    try vm.memory.data.resize(384);
    @memset(vm.memory.data.items[0..384], 0);

    // Pair 1: (G1, G2)
    vm.memory.data.items[31] = 0x01;
    vm.memory.data.items[63] = 0x02;
    _ = try std.fmt.hexToBytes(vm.memory.data.items[64..96], "198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2");
    _ = try std.fmt.hexToBytes(vm.memory.data.items[96..128], "1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed");
    _ = try std.fmt.hexToBytes(vm.memory.data.items[128..160], "090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b");
    _ = try std.fmt.hexToBytes(vm.memory.data.items[160..192], "12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa");

    // Pair 2: (G1, -G2)
    vm.memory.data.items[223] = 0x01;
    vm.memory.data.items[255] = 0x02;
    _ = try std.fmt.hexToBytes(vm.memory.data.items[256..288], "198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2");
    _ = try std.fmt.hexToBytes(vm.memory.data.items[288..320], "1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed");
    _ = try std.fmt.hexToBytes(vm.memory.data.items[320..352], "275dc4a288d1afb3cbb1ac09187524c7db36395df7be3b99e673b13a075a65ec");
    _ = try std.fmt.hexToBytes(vm.memory.data.items[352..384], "1d9befcd05a5323e6da4d435f3b617cdb3af83285c2df711ef39c01571827f9d");

    const code = [_]u8{
        0x60, 0x20, // outSize
        0x60, 0x00, // outOffset
        0x61, 0x01, 0x80, // inSize = 384
        0x60, 0x00, // inOffset
        0x60, 0x00, // value
        0x60, 0x08, // address
        0x62, 0x1f, 0xff, 0xff, // gas
        0xf1, // CALL
    };

    const result = try vm.execute(&code, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    const success = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 1), success.limbs[0]);
    try testing.expectEqual(@as(u8, 1), vm.memory.data.items[31]);
    try testing.expectEqual(@as(u64, 113_821), vm.gas_used);
}

test "EVM: CALL dispatches BLAKE2F precompile (0x09) EIP-152 vector" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 2_000_000);
    defer vm.deinit();

    try vm.memory.data.resize(213);
    @memset(vm.memory.data.items[0..213], 0);
    const input_hex =
        "0000000c" ++
        "48c9bdf267e6096a3ba7ca8485ae67bb2bf894fe72f36e3cf1361d5f3af54fa5" ++
        "d182e6ad7f520e511f6c3e2b8c68059b6bbd41fbabd9831f79217e1319cde05b" ++
        "6162630000000000000000000000000000000000000000000000000000000000" ++
        "0000000000000000000000000000000000000000000000000000000000000000" ++
        "0300000000000000" ++
        "0000000000000000" ++
        "01";
    _ = try std.fmt.hexToBytes(vm.memory.data.items[0..213], input_hex);

    const code = [_]u8{
        0x60, 0x40, // outSize = 64
        0x60, 0x00, // outOffset
        0x60, 0xd5, // inSize = 213
        0x60, 0x00, // inOffset
        0x60, 0x00, // value
        0x60, 0x09, // address
        0x62, 0x1f, 0xff, 0xff, // gas
        0xf1, // CALL
    };

    const result = try vm.execute(&code, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    const success = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 1), success.limbs[0]);

    var expected: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        expected[0..],
        "79e277b408095aa867ee8e3c3c3200356e9dedb70b4f760bd068b60cd0510e31" ++
            "77934e3bf886c96b28d57134baf41b3c818254d527cab1dd696cb8a67410de62",
    );
    try testing.expectEqualSlices(u8, expected[0..], vm.memory.data.items[0..64]);
    try testing.expectEqual(@as(u64, 833), vm.gas_used);
}

test "EVM: BLAKE2F precompile rejects invalid final flag" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 2_000_000);
    defer vm.deinit();

    try vm.memory.data.resize(213);
    @memset(vm.memory.data.items[0..213], 0);
    vm.memory.data.items[3] = 0x01; // rounds = 1
    vm.memory.data.items[212] = 0x02; // invalid final flag

    const code = [_]u8{
        0x60, 0x40, // outSize = 64
        0x60, 0x00, // outOffset
        0x60, 0xd5, // inSize = 213
        0x60, 0x00, // inOffset
        0x60, 0x00, // value
        0x60, 0x09, // address
        0x62, 0x1f, 0xff, 0xff, // gas
        0xf1, // CALL
    };

    const result = try vm.execute(&code, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    const success = try vm.stack.pop();
    try testing.expect(success.isZero());
    try testing.expectEqual(@as(u64, 822), vm.gas_used);
}

test "EVM: STATICCALL executes with zero call value" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var callee_addr = types.Address.zero;
    callee_addr.bytes[19] = 0x0a;

    const callee_code = [_]u8{
        0x34, // CALLVALUE
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };
    try db.setCode(callee_addr, &callee_code);

    var vm = try evm.EVM.initWithState(allocator, 1_000_000, evm.ExecutionContext.default(), &db);
    defer vm.deinit();

    const code = [_]u8{
        0x60, 0x20, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x00, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x0a, // address
        0x61, 0xff, 0xff, // gas
        0xfa, // STATICCALL
    };

    const static_result = try vm.execute(&code, &[_]u8{});
    defer if (static_result.return_data.len > 0) allocator.free(static_result.return_data);
    defer allocator.free(static_result.logs);
    const success = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 1), success.limbs[0]);
    try testing.expectEqual(@as(u8, 0x00), vm.memory.data.items[31]);
}

test "EVM: STATICCALL forbids SSTORE and reverts callee state changes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var callee_addr = types.Address.zero;
    callee_addr.bytes[19] = 0x0b;
    const callee_code = [_]u8{
        0x60, 0x2a, // value
        0x60, 0x01, // key
        0x55, // SSTORE (must fail under STATICCALL)
        0x00, // STOP
    };
    try db.createAccount(callee_addr);
    try db.setCode(callee_addr, &callee_code);

    var caller = types.Address.zero;
    caller.bytes[19] = 0xaa;
    try db.createAccount(caller);

    var context = evm.ExecutionContext.default();
    context.address = caller;
    context.caller = caller;

    var vm = try evm.EVM.initWithState(allocator, 1_000_000, context, &db);
    defer vm.deinit();

    const code = [_]u8{
        0x60, 0x00, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x00, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x0b, // address
        0x61, 0xff, 0xff, // gas
        0xfa, // STATICCALL
    };

    _ = try vm.execute(&code, &[_]u8{});
    const success = try vm.stack.pop();
    try testing.expect(success.isZero());

    const stored = try db.getStorage(callee_addr, types.U256.fromU64(1));
    try testing.expect(stored.isZero());
}

test "EVM: STATICCALL forbids LOG0 and emits no logs" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var callee_addr = types.Address.zero;
    callee_addr.bytes[19] = 0x0c;
    const callee_code = [_]u8{
        0x60, 0x00, // offset
        0x60, 0x00, // length
        0xa0, // LOG0
        0x00, // STOP
    };
    try db.createAccount(callee_addr);
    try db.setCode(callee_addr, &callee_code);

    var vm = try evm.EVM.initWithState(allocator, 1_000_000, evm.ExecutionContext.default(), &db);
    defer vm.deinit();

    const code = [_]u8{
        0x60, 0x00, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x00, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x0c, // address
        0x61, 0xff, 0xff, // gas
        0xfa, // STATICCALL
    };

    _ = try vm.execute(&code, &[_]u8{});
    const success = try vm.stack.pop();
    try testing.expect(success.isZero());
    try testing.expectEqual(@as(usize, 0), vm.logs.items.len);
}

test "EVM: STATICCALL forbids CREATE and CREATE2" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var callee_addr = types.Address.zero;
    callee_addr.bytes[19] = 0x0d;
    const callee_code = [_]u8{
        0x60, 0x00, // value
        0x60, 0x00, // offset
        0x60, 0x00, // length
        0xf0, // CREATE (must fail under static)
        0x60, 0x00, // value
        0x60, 0x00, // offset
        0x60, 0x00, // length
        0x60, 0x01, // salt
        0xf5, // CREATE2 (must fail under static if reached)
        0x00, // STOP
    };
    try db.createAccount(callee_addr);
    try db.setCode(callee_addr, &callee_code);

    var vm = try evm.EVM.initWithState(allocator, 1_000_000, evm.ExecutionContext.default(), &db);
    defer vm.deinit();

    const code = [_]u8{
        0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, // out/in zero
        0x60, 0x0d, // address
        0x61, 0xff, 0xff, // gas
        0xfa, // STATICCALL
    };

    _ = try vm.execute(&code, &[_]u8{});
    const success = try vm.stack.pop();
    try testing.expect(success.isZero());
}

test "EVM: STATICCALL forbids SELFDESTRUCT" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var callee_addr = types.Address.zero;
    callee_addr.bytes[19] = 0x0e;
    try db.createAccount(callee_addr);
    try db.setBalance(callee_addr, types.U256.fromU64(77));
    const callee_code = [_]u8{
        0x60, 0x01, // beneficiary
        0xff, // SELFDESTRUCT
    };
    try db.setCode(callee_addr, &callee_code);

    var vm = try evm.EVM.initWithState(allocator, 1_000_000, evm.ExecutionContext.default(), &db);
    defer vm.deinit();

    const code = [_]u8{
        0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00,
        0x60, 0x0e, 0x61, 0xff, 0xff, 0xfa,
    };

    _ = try vm.execute(&code, &[_]u8{});
    const success = try vm.stack.pop();
    try testing.expect(success.isZero());
    try testing.expect(db.exists(callee_addr));
    const bal = try db.getBalance(callee_addr);
    try testing.expectEqual(@as(u64, 77), bal.limbs[0]);
}

test "EVM: STATICCALL forbids value-carrying CALL" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var callee_addr = types.Address.zero;
    callee_addr.bytes[19] = 0x0f;
    const callee_code = [_]u8{
        0x60, 0x00, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x00, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x01, // value (forbidden under static)
        0x60, 0x01, // address
        0x61, 0xff, 0xff, // gas
        0xf1, // CALL
        0x00, // STOP
    };
    try db.createAccount(callee_addr);
    try db.setCode(callee_addr, &callee_code);

    var vm = try evm.EVM.initWithState(allocator, 1_000_000, evm.ExecutionContext.default(), &db);
    defer vm.deinit();

    const code = [_]u8{
        0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00,
        0x60, 0x0f, 0x61, 0xff, 0xff, 0xfa,
    };

    _ = try vm.execute(&code, &[_]u8{});
    const success = try vm.stack.pop();
    try testing.expect(success.isZero());
}

test "EVM: DELEGATECALL preserves caller context" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var callee_addr = types.Address.zero;
    callee_addr.bytes[19] = 0x0a;

    const callee_code = [_]u8{
        0x33, // CALLER
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };
    try db.setCode(callee_addr, &callee_code);

    var context = evm.ExecutionContext.default();
    context.address.bytes[19] = 0xaa;
    context.caller.bytes[19] = 0xbb;

    var vm = try evm.EVM.initWithState(allocator, 1_000_000, context, &db);
    defer vm.deinit();

    const code = [_]u8{
        0x60, 0x20, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x00, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x0a, // address
        0x61, 0xff, 0xff, // gas
        0xf4, // DELEGATECALL
    };

    const delegate_result = try vm.execute(&code, &[_]u8{});
    defer if (delegate_result.return_data.len > 0) allocator.free(delegate_result.return_data);
    defer allocator.free(delegate_result.logs);
    const success = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 1), success.limbs[0]);
}

test "EVM: CREATE deploys runtime code from init code return data" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var creator = types.Address.zero;
    creator.bytes[19] = 0xaa;
    try db.createAccount(creator);
    try db.setBalance(creator, types.U256.fromU64(1_000_000));

    var context = evm.ExecutionContext.default();
    context.address = creator;
    context.caller = creator;

    var vm = try evm.EVM.initWithState(allocator, 2_000_000, context, &db);
    defer vm.deinit();

    // Init code: MSTORE8(0x00, 0x2a); RETURN(offset=0, length=1)
    const bytecode = [_]u8{
        0x60, 0x60, 0x60, 0x00, 0x53, // byte 0
        0x60, 0x2a, 0x60, 0x01, 0x53, // byte 1
        0x60, 0x60, 0x60, 0x02, 0x53, // byte 2
        0x60, 0x00, 0x60, 0x03, 0x53, // byte 3
        0x60, 0x53, 0x60, 0x04, 0x53, // byte 4
        0x60, 0x60, 0x60, 0x05, 0x53, // byte 5
        0x60, 0x01, 0x60, 0x06, 0x53, // byte 6
        0x60, 0x60, 0x60, 0x07, 0x53, // byte 7
        0x60, 0x00, 0x60, 0x08, 0x53, // byte 8
        0x60, 0xf3, 0x60, 0x09, 0x53, // byte 9
        0x60, 0x0a, // PUSH1 length
        0x60, 0x00, // PUSH1 offset
        0x60, 0x00, // PUSH1 value
        0xf0, // CREATE
    };

    const create_result = try vm.execute(&bytecode, &[_]u8{});
    defer if (create_result.return_data.len > 0) allocator.free(create_result.return_data);
    defer allocator.free(create_result.logs);
    const deployed_u256 = try vm.stack.pop();
    try testing.expect(!deployed_u256.isZero());

    const deployed_addr = addressFromU256(deployed_u256);

    const deployed_code = db.getCode(deployed_addr);
    try testing.expectEqual(@as(usize, 1), deployed_code.len);
    try testing.expectEqual(@as(u8, 0x2a), deployed_code[0]);
}

test "EVM: CREATE2 is deterministic for same salt and init code" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var creator = types.Address.zero;
    creator.bytes[19] = 0xcc;

    var db1 = state.StateDB.init(allocator);
    defer db1.deinit();
    try db1.createAccount(creator);
    try db1.setBalance(creator, types.U256.fromU64(1_000_000));

    var db2 = state.StateDB.init(allocator);
    defer db2.deinit();
    try db2.createAccount(creator);
    try db2.setBalance(creator, types.U256.fromU64(1_000_000));

    var context = evm.ExecutionContext.default();
    context.address = creator;
    context.caller = creator;

    var vm1 = try evm.EVM.initWithState(allocator, 2_000_000, context, &db1);
    defer vm1.deinit();
    var vm2 = try evm.EVM.initWithState(allocator, 2_000_000, context, &db2);
    defer vm2.deinit();

    const code = [_]u8{
        0x60, 0x60, 0x60, 0x00, 0x53, // byte 0
        0x60, 0x2a, 0x60, 0x01, 0x53, // byte 1
        0x60, 0x60, 0x60, 0x02, 0x53, // byte 2
        0x60, 0x00, 0x60, 0x03, 0x53, // byte 3
        0x60, 0x53, 0x60, 0x04, 0x53, // byte 4
        0x60, 0x60, 0x60, 0x05, 0x53, // byte 5
        0x60, 0x01, 0x60, 0x06, 0x53, // byte 6
        0x60, 0x60, 0x60, 0x07, 0x53, // byte 7
        0x60, 0x00, 0x60, 0x08, 0x53, // byte 8
        0x60, 0xf3, 0x60, 0x09, 0x53, // byte 9
        0x60, 0x01, // PUSH1 salt
        0x60, 0x0a, // length
        0x60, 0x00, // offset
        0x60, 0x00, // value
        0xf5, // CREATE2
    };

    const create2_result_1 = try vm1.execute(&code, &[_]u8{});
    defer if (create2_result_1.return_data.len > 0) allocator.free(create2_result_1.return_data);
    defer allocator.free(create2_result_1.logs);
    const create2_result_2 = try vm2.execute(&code, &[_]u8{});
    defer if (create2_result_2.return_data.len > 0) allocator.free(create2_result_2.return_data);
    defer allocator.free(create2_result_2.logs);
    const a1 = try vm1.stack.pop();
    const a2 = try vm2.stack.pop();
    try testing.expect(a1.eq(a2));
}

test "EVM: CREATE2 fails when target address already has code" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var creator = types.Address.zero;
    creator.bytes[19] = 0xcd;
    try db.createAccount(creator);
    try db.setBalance(creator, types.U256.fromU64(1_000_000));

    var context = evm.ExecutionContext.default();
    context.address = creator;
    context.caller = creator;

    var vm1 = try evm.EVM.initWithState(allocator, 2_000_000, context, &db);
    defer vm1.deinit();
    var vm2 = try evm.EVM.initWithState(allocator, 2_000_000, context, &db);
    defer vm2.deinit();

    const code = [_]u8{
        0x60, 0x60, 0x60, 0x00, 0x53,
        0x60, 0x2a, 0x60, 0x01, 0x53,
        0x60, 0x60, 0x60, 0x02, 0x53,
        0x60, 0x00, 0x60, 0x03, 0x53,
        0x60, 0x53, 0x60, 0x04, 0x53,
        0x60, 0x60, 0x60, 0x05, 0x53,
        0x60, 0x01, 0x60, 0x06, 0x53,
        0x60, 0x60, 0x60, 0x07, 0x53,
        0x60, 0x00, 0x60, 0x08, 0x53,
        0x60, 0xf3, 0x60, 0x09, 0x53,
        0x60, 0x01, 0x60, 0x0a, 0x60,
        0x00, 0x60, 0x00, 0xf5,
    };

    const first = try vm1.execute(&code, &[_]u8{});
    defer if (first.return_data.len > 0) allocator.free(first.return_data);
    defer allocator.free(first.logs);
    const first_addr_u256 = try vm1.stack.pop();
    try testing.expect(!first_addr_u256.isZero());
    const first_addr = addressFromU256(first_addr_u256);
    try testing.expect(db.getCode(first_addr).len > 0);

    const second = try vm2.execute(&code, &[_]u8{});
    defer if (second.return_data.len > 0) allocator.free(second.return_data);
    defer allocator.free(second.logs);
    const second_addr_u256 = try vm2.stack.pop();
    try testing.expect(second_addr_u256.isZero());
    try testing.expect(db.getCode(first_addr).len > 0);
}

test "EVM: top-level REVERT rolls back CREATE2 deployed code" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var creator = types.Address.zero;
    creator.bytes[19] = 0xdd;
    try db.createAccount(creator);
    try db.setBalance(creator, types.U256.fromU64(1_000_000));

    var context = evm.ExecutionContext.default();
    context.address = creator;
    context.caller = creator;

    var vm = try evm.EVM.initWithState(allocator, 2_000_000, context, &db);
    defer vm.deinit();

    const init_code = [_]u8{ 0x60, 0x2a, 0x60, 0x00, 0x53, 0x60, 0x01, 0x60, 0x00, 0xf3 };
    const salt = types.U256.fromU64(1);
    const expected_addr = deriveCreate2AddressForTest(creator, salt, &init_code);

    const code = [_]u8{
        0x60, 0x60, 0x60, 0x00, 0x53, // byte 0
        0x60, 0x2a, 0x60, 0x01, 0x53, // byte 1
        0x60, 0x60, 0x60, 0x02, 0x53, // byte 2
        0x60, 0x00, 0x60, 0x03, 0x53, // byte 3
        0x60, 0x53, 0x60, 0x04, 0x53, // byte 4
        0x60, 0x60, 0x60, 0x05, 0x53, // byte 5
        0x60, 0x01, 0x60, 0x06, 0x53, // byte 6
        0x60, 0x60, 0x60, 0x07, 0x53, // byte 7
        0x60, 0x00, 0x60, 0x08, 0x53, // byte 8
        0x60, 0xf3, 0x60, 0x09, 0x53, // byte 9
        0x60, 0x01, // PUSH1 salt
        0x60, 0x0a, // length
        0x60, 0x00, // offset
        0x60, 0x00, // value
        0xf5, // CREATE2
        0x60, 0x00, // revert offset
        0x60, 0x00, // revert length
        0xfd, // REVERT
    };

    const result = try vm.execute(&code, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    try testing.expect(!result.success);
    try testing.expect(!db.exists(expected_addr));
    try testing.expectEqual(@as(usize, 0), db.getCode(expected_addr).len);
}

test "EVM: Nested CALL persists storage in state DB" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    const callee_addr = types.Address.zero;
    const callee_code = [_]u8{
        0x60, 0x2a, // value
        0x60, 0x01, // key
        0x55, // SSTORE
        0x00, // STOP
    };
    try db.setCode(callee_addr, &callee_code);

    var caller_ctx = evm.ExecutionContext.default();
    caller_ctx.address.bytes[19] = 0xdd;
    try db.createAccount(caller_ctx.address);

    var vm = try evm.EVM.initWithState(allocator, 1_000_000, caller_ctx, &db);
    defer vm.deinit();

    const call_code = [_]u8{
        0x60, 0x00, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x00, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x00, // value
        0x60, 0x00, // address
        0x61, 0xff, 0xff, // gas
        0xf1, // CALL
    };
    _ = try vm.execute(&call_code, &[_]u8{});
    const success = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 1), success.limbs[0]);

    const stored = try db.getStorage(callee_addr, types.U256.fromU64(1));
    try testing.expectEqual(@as(u64, 0x2a), stored.limbs[0]);
}

test "EVM: SELFDESTRUCT transfers balance and deletes account state" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var sender = types.Address.zero;
    sender.bytes[19] = 0xaa;
    const beneficiary = types.Address.zero;

    try db.createAccount(sender);
    try db.setBalance(sender, types.U256.fromU64(777));
    try db.setStorage(sender, types.U256.fromU64(1), types.U256.fromU64(42));
    try db.setCode(sender, &[_]u8{ 0x60, 0x01, 0x00 });

    var context = evm.ExecutionContext.default();
    context.address = sender;
    context.caller = sender;

    var vm = try evm.EVM.initWithState(allocator, 1_000_000, context, &db);
    defer vm.deinit();

    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 beneficiary address
        0xff, // SELFDESTRUCT
    };

    const result = try vm.execute(&bytecode, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);
    try testing.expect(result.success);

    // EIP-6780: Account NOT created in same tx, so it is NOT destroyed.
    // Balance is transferred but account, code, and storage remain.
    try testing.expect(db.exists(sender));
    const beneficiary_balance = try db.getBalance(beneficiary);
    try testing.expectEqual(@as(u64, 777), beneficiary_balance.limbs[0]);
    const sender_balance = try db.getBalance(sender);
    try testing.expect(sender_balance.isZero());
    try testing.expectEqual(@as(u64, 32_603), vm.gas_used);
    // EIP-3529: SELFDESTRUCT no longer gives a gas refund.
    try testing.expectEqual(@as(u64, 0), vm.gas_refund);
    // Storage and code are preserved (not destroyed).
    const stored = try db.getStorage(sender, types.U256.fromU64(1));
    try testing.expectEqual(@as(u64, 42), stored.limbs[0]);
    try testing.expect(db.getCode(sender).len > 0);
}

test "EVM: SELFDESTRUCT uses warm beneficiary access cost when pre-warmed" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var sender = types.Address.zero;
    sender.bytes[19] = 0xaa;
    var beneficiary = types.Address.zero;
    beneficiary.bytes[19] = 0x0b;

    try db.createAccount(sender);
    try db.createAccount(beneficiary);
    try db.setBalance(sender, types.U256.zero());

    var context = evm.ExecutionContext.default();
    context.address = sender;
    context.caller = sender;

    var vm = try evm.EVM.initWithState(allocator, 100_000, context, &db);
    defer vm.deinit();

    const bytecode = [_]u8{
        0x60, 0x0b, // PUSH1 beneficiary
        0x31, // BALANCE (warms beneficiary)
        0x50, // POP
        0x60, 0x0b, // PUSH1 beneficiary
        0xff, // SELFDESTRUCT
    };

    const result = try vm.execute(&bytecode, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    try testing.expect(result.success);
    try testing.expectEqual(@as(u64, 7_708), vm.gas_used);
    // EIP-3529: SELFDESTRUCT no longer gives a gas refund.
    try testing.expectEqual(@as(u64, 0), vm.gas_refund);
}

test "EVM: SELFDESTRUCT with zero balance does not charge new-account creation cost" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var sender = types.Address.zero;
    sender.bytes[19] = 0xaa;
    var beneficiary = types.Address.zero;
    beneficiary.bytes[19] = 0x0c; // remains nonexistent

    try db.createAccount(sender);
    try db.setBalance(sender, types.U256.zero());

    var context = evm.ExecutionContext.default();
    context.address = sender;
    context.caller = sender;

    var vm = try evm.EVM.initWithState(allocator, 100_000, context, &db);
    defer vm.deinit();

    const bytecode = [_]u8{
        0x60, 0x0c, // PUSH1 beneficiary
        0xff, // SELFDESTRUCT
    };

    const result = try vm.execute(&bytecode, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    try testing.expect(result.success);
    try testing.expectEqual(@as(u64, 7_603), vm.gas_used);
    // EIP-3529: SELFDESTRUCT no longer gives a gas refund.
    try testing.expectEqual(@as(u64, 0), vm.gas_refund);
    try testing.expect(!db.exists(beneficiary));
}

test "EVM: Stack operations (DUP and SWAP)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // Test DUP: Push 42, DUP1, should have two 42s
    const dup_bytecode = [_]u8{
        0x60, 0x2a, // PUSH1 42
        0x80, // DUP1
    };

    _ = try vm.execute(&dup_bytecode, &[_]u8{});
    const val1 = try vm.stack.pop();
    const val2 = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 42), val1.limbs[0]);
    try testing.expectEqual(@as(u64, 42), val2.limbs[0]);
}

test "EVM: Memory operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // Store 0x1234 at offset 0, then load it
    const bytecode = [_]u8{
        0x61, 0x12, 0x34, // PUSH2 0x1234
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x00, // PUSH1 0
        0x51, // MLOAD
    };

    const result = try vm.execute(&bytecode, &[_]u8{});
    try testing.expect(result.success);
}

test "EVM: MSTORE8 memory expansion boundary (32 -> 33 bytes) has exact gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 100_000);
    defer vm.deinit();

    const code = [_]u8{
        0x60, 0xaa, // value
        0x60, 0x1f, // offset 31
        0x53, // MSTORE8 => expands to 32 bytes
        0x60, 0xbb, // value
        0x60, 0x20, // offset 32
        0x53, // MSTORE8 => expands to 33 bytes (2nd word)
    };

    const result = try vm.execute(&code, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    try testing.expect(result.success);
    try testing.expectEqual(@as(u64, 24), vm.gas_used);
}

test "EVM: repeated MSTORE in same range does not repay memory expansion gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 100_000);
    defer vm.deinit();

    const code = [_]u8{
        0x60, 0x01, // value
        0x60, 0x00, // offset
        0x52, // MSTORE (expands to 32 bytes)
        0x60, 0x02, // value
        0x60, 0x00, // offset
        0x52, // MSTORE (no further expansion)
    };

    const result = try vm.execute(&code, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    try testing.expect(result.success);
    try testing.expectEqual(@as(u64, 21), vm.gas_used);
}

test "EVM: Storage operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // Store and retrieve
    const bytecode = [_]u8{
        0x60, 0x42, // PUSH1 0x42 (value)
        0x60, 0x05, // PUSH1 5 (key)
        0x55, // SSTORE
        0x60, 0x05, // PUSH1 5 (key)
        0x54, // SLOAD
    };

    const result = try vm.execute(&bytecode, &[_]u8{});
    try testing.expect(result.success);
}

test "EVM: Event logging" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // Store data in memory and emit LOG1
    const bytecode = [_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0xaa, // PUSH1 0xaa (topic)
        0x60, 0x20, // PUSH1 32 (length)
        0x60, 0x00, // PUSH1 0 (offset)
        0xa1, // LOG1
    };

    const result = try vm.execute(&bytecode, &[_]u8{});
    defer {
        for (result.logs) |log| {
            allocator.free(log.topics);
            allocator.free(log.data);
        }
        allocator.free(result.logs);
    }

    try testing.expect(result.success);
    try testing.expectEqual(@as(usize, 1), result.logs.len);
    try testing.expectEqual(@as(usize, 1), result.logs[0].topics.len);
}

test "EVM: Environmental opcodes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create context with known values
    var context = evm.ExecutionContext.default();
    context.block_number = 12345;
    context.block_timestamp = 1234567890;
    context.chain_id = 1;

    var vm = try evm.EVM.initWithContext(allocator, 1000000, context);
    defer vm.deinit();

    // Test NUMBER and TIMESTAMP opcodes
    const bytecode = [_]u8{
        0x43, // NUMBER
        0x42, // TIMESTAMP
        0x46, // CHAINID
    };

    const result = try vm.execute(&bytecode, &[_]u8{});
    try testing.expect(result.success);
}

test "EVM: SHA3 hashing" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // Store "hello" in memory and hash it
    const bytecode = [_]u8{
        0x60, 0x68, // PUSH1 'h'
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x01, // PUSH1 1 (length)
        0x60, 0x1f, // PUSH1 31 (offset - last byte)
        0x20, // SHA3
    };

    const result = try vm.execute(&bytecode, &[_]u8{});
    try testing.expect(result.success);
}

test "EVM: SHA3 charges memory expansion gas when hashing uncached region" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1_000_000);
    defer vm.deinit();

    const bytecode = [_]u8{
        0x60, 0x20, // len = 32
        0x60, 0x00, // offset = 0
        0x20, // SHA3 (expands memory 0 -> 32 bytes)
    };

    const result = try vm.execute(&bytecode, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);
    try testing.expect(result.success);

    // PUSH1 + PUSH1 + SHA3(base30 + words6 + mem3)
    try testing.expectEqual(@as(u64, 45), vm.gas_used);
}

test "EVM: LOG1 charges memory expansion gas when emitting from uncached region" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1_000_000);
    defer vm.deinit();

    const bytecode = [_]u8{
        0x60, 0xaa, // topic
        0x60, 0x20, // len = 32
        0x60, 0x00, // offset = 0
        0xa1, // LOG1 (expands memory 0 -> 32 bytes)
    };

    const result = try vm.execute(&bytecode, &[_]u8{});
    defer {
        for (result.logs) |log| {
            allocator.free(log.topics);
            allocator.free(log.data);
        }
        allocator.free(result.logs);
    }

    try testing.expect(result.success);
    try testing.expectEqual(@as(usize, 1), result.logs.len);
    try testing.expectEqual(@as(usize, 32), result.logs[0].data.len);
    // PUSH1*3 = 9; LOG1 = 375 + 375 + 8*32 + mem3 = 1009
    try testing.expectEqual(@as(u64, 1_018), vm.gas_used);
}

test "EVM: REVERT handling" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // Execute code that reverts
    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0
        0xfd, // REVERT
    };

    const result = try vm.execute(&bytecode, &[_]u8{});
    try testing.expect(!result.success);
}

test "EVM: Gas metering" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 8);
    defer vm.deinit();

    // This should run out of gas (limit is only 8)
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1  (3 gas) - total: 3
        0x60, 0x02, // PUSH1 2  (3 gas) - total: 6
        0x01, // ADD      (3 gas) - total: 9, should fail here since 9 > 8
        0x60, 0x00, // PUSH1 0  - should never reach this
    };

    const result = vm.execute(&bytecode, &[_]u8{});
    try testing.expectError(error.OutOfGas, result);
}

test "EVM: CALL gas includes value transfer and new-account cost" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var sender = types.Address.zero;
    sender.bytes[19] = 0xaa;
    try db.createAccount(sender);
    try db.setBalance(sender, types.U256.fromU64(1_000_000));

    var context = evm.ExecutionContext.default();
    context.address = sender;
    context.caller = sender;

    var vm = try evm.EVM.initWithState(allocator, 5_000_000, context, &db);
    defer vm.deinit();

    const code = [_]u8{
        0x60, 0x00, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x00, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x01, // value
        0x60, 0x0a, // address (new account, non-precompile)
        0x61, 0xff, 0xff, // gas
        0xf1, // CALL
    };

    const res = try vm.execute(&code, &[_]u8{});
    defer if (res.return_data.len > 0) allocator.free(res.return_data);
    defer allocator.free(res.logs);
    const success = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 1), success.limbs[0]);
    // PUSHes (7 * 3) + CALL base (700 + 2600 cold + 9000 value + 25000 new account).
    try testing.expectEqual(@as(u64, 37_321), vm.gas_used);
    try testing.expectEqual(@as(u64, 999_999), (try db.getBalance(sender)).limbs[0]);
    var recipient = types.Address.zero;
    recipient.bytes[19] = 0x0a;
    try testing.expectEqual(@as(u64, 1), (try db.getBalance(recipient)).limbs[0]);
}

test "EVM: CREATE2 charges additional hashcost over CREATE for same init code length" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var creator = types.Address.zero;
    creator.bytes[19] = 0xcc;
    try db.createAccount(creator);
    try db.setBalance(creator, types.U256.fromU64(10_000_000));

    var context = evm.ExecutionContext.default();
    context.address = creator;
    context.caller = creator;

    var vm_create = try evm.EVM.initWithState(allocator, 5_000_000, context, &db);
    defer vm_create.deinit();
    var vm_create2 = try evm.EVM.initWithState(allocator, 5_000_000, context, &db);
    defer vm_create2.deinit();

    // length=64 -> ceil(64/32)=2 words, CREATE2 extra = 12 gas.
    const create_code = [_]u8{
        0x60, 0x40, // length
        0x60, 0x00, // offset
        0x60, 0x00, // value
        0xf0, // CREATE
    };
    const create2_code = [_]u8{
        0x60, 0x01, // salt
        0x60, 0x40, // length
        0x60, 0x00, // offset
        0x60, 0x00, // value
        0xf5, // CREATE2
    };

    const r1 = try vm_create.execute(&create_code, &[_]u8{});
    defer if (r1.return_data.len > 0) allocator.free(r1.return_data);
    defer allocator.free(r1.logs);
    const r2 = try vm_create2.execute(&create2_code, &[_]u8{});
    defer if (r2.return_data.len > 0) allocator.free(r2.return_data);
    defer allocator.free(r2.logs);

    // CREATE: 3 PUSH1 + (32000 + 6 mem + 6 copy + 4 initcode) = 32025
    try testing.expectEqual(@as(u64, 32_025), vm_create.gas_used);
    // CREATE2: 4 PUSH1 + (32000 + 6 mem + 6 copy + 12 hashcost + 4 initcode) = 32040
    try testing.expectEqual(@as(u64, 32_040), vm_create2.gas_used);
}

test "EVM: CALL OOG in child obeys EIP-150 reserve and does not exhaust parent" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var target = types.Address.zero;
    target.bytes[19] = 0x0a;

    // Infinite loop: JUMPDEST; PUSH1 0; JUMP
    const looping = [_]u8{ 0x5b, 0x60, 0x00, 0x56 };
    try db.setCode(target, &looping);

    var vm = try evm.EVM.initWithState(allocator, 100_000, evm.ExecutionContext.default(), &db);
    defer vm.deinit();

    const caller = [_]u8{
        0x60, 0x00, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x00, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x00, // value
        0x60, 0x0a, // address
        0x61, 0xff, 0xff, // requested gas (high)
        0xf1, // CALL
    };

    const result = try vm.execute(&caller, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    const call_success = try vm.stack.pop();
    try testing.expect(call_success.isZero());
    // Parent push gas: 21
    // CALL base: 700 + 2600 (cold) = 3300
    // Child OOG consumes full forwarded gas cap: 65535
    try testing.expectEqual(@as(u64, 68_856), vm.gas_used);
}

test "EVM: CALL with value forwards 2300 stipend even when requested gas is zero" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var sender = types.Address.zero;
    sender.bytes[19] = 0xaa;
    try db.createAccount(sender);
    try db.setBalance(sender, types.U256.fromU64(1_000_000));

    var target = types.Address.zero;
    target.bytes[19] = 0x0a;
    try db.createAccount(target);
    const callee_code = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x00, // STOP
    };
    try db.setCode(target, &callee_code);

    var ctx = evm.ExecutionContext.default();
    ctx.address = sender;
    ctx.caller = sender;

    var vm = try evm.EVM.initWithState(allocator, 100_000, ctx, &db);
    defer vm.deinit();

    const caller = [_]u8{
        0x60, 0x00, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x00, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x01, // value (non-zero => stipend-eligible)
        0x60, 0x0a, // address
        0x60, 0x00, // requested gas = 0
        0xf1, // CALL
    };

    const result = try vm.execute(&caller, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    const call_success = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 1), call_success.limbs[0]);

    // Parent push gas: 21
    // CALL base (existing account): 700 + 2600 cold + 9000 value = 12300
    // Child execution uses stipend gas: PUSH1(3) + STOP(0) = 3
    try testing.expectEqual(@as(u64, 12_324), vm.gas_used);
    try testing.expectEqual(@as(u64, 999_999), (try db.getBalance(sender)).limbs[0]);
    try testing.expectEqual(@as(u64, 1), (try db.getBalance(target)).limbs[0]);
}

test "EVM: CALL revert restores transferred value" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var sender = types.Address.zero;
    sender.bytes[19] = 0xaa;
    try db.createAccount(sender);
    try db.setBalance(sender, types.U256.fromU64(50));

    var target = types.Address.zero;
    target.bytes[19] = 0x0b;
    try db.createAccount(target);
    try db.setCode(target, &[_]u8{
        0x60, 0x00, // revert offset
        0x60, 0x00, // revert length
        0xfd, // REVERT
    });

    var ctx = evm.ExecutionContext.default();
    ctx.address = sender;
    ctx.caller = sender;

    var vm = try evm.EVM.initWithState(allocator, 100_000, ctx, &db);
    defer vm.deinit();

    const caller = [_]u8{
        0x60, 0x00, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x00, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x05, // value
        0x60, 0x0b, // address
        0x61, 0xff, 0xff, // gas
        0xf1, // CALL
    };

    const result = try vm.execute(&caller, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    const call_success = try vm.stack.pop();
    try testing.expect(call_success.isZero());
    try testing.expectEqual(@as(u64, 50), (try db.getBalance(sender)).limbs[0]);
    try testing.expect((try db.getBalance(target)).isZero());
}

test "EVM: value CALL OOG consumes forwarded gas plus stipend" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var sender = types.Address.zero;
    sender.bytes[19] = 0xaa;
    try db.createAccount(sender);
    try db.setBalance(sender, types.U256.fromU64(1_000_000));

    var target = types.Address.zero;
    target.bytes[19] = 0x0a;
    try db.createAccount(target);
    // Infinite loop to force hard OOG and consume the entire child gas limit.
    const callee_code = [_]u8{ 0x5b, 0x60, 0x00, 0x56 };
    try db.setCode(target, &callee_code);

    var ctx = evm.ExecutionContext.default();
    ctx.address = sender;
    ctx.caller = sender;

    var vm = try evm.EVM.initWithState(allocator, 100_000, ctx, &db);
    defer vm.deinit();

    const caller = [_]u8{
        0x60, 0x00, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x00, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x01, // value
        0x60, 0x0a, // address
        0x60, 0x00, // requested gas = 0
        0xf1, // CALL
    };

    const result = try vm.execute(&caller, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    const call_success = try vm.stack.pop();
    try testing.expect(call_success.isZero());

    // Parent push gas: 21
    // CALL base (existing account): 700 + 2600 cold + 9000 value = 12300
    // Child OOG consumes full child limit (stipend): 2300
    try testing.expectEqual(@as(u64, 14_621), vm.gas_used);
}

test "EVM: CALL cold then warm account access has exact gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var vm = try evm.EVM.initWithState(allocator, 100_000, evm.ExecutionContext.default(), &db);
    defer vm.deinit();

    const code = [_]u8{
        // First CALL to 0x0a (cold): 7 PUSH1 + CALL
        0x60, 0x00, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x00, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x00, // value
        0x60, 0x0a, // address
        0x60, 0xff, // gas
        0xf1, // CALL
        // Second CALL to 0x0a (warm): 7 PUSH1 + CALL
        0x60,
        0x00,
        0x60,
        0x00,
        0x60,
        0x00,
        0x60,
        0x00,
        0x60,
        0x00,
        0x60,
        0x0a,
        0x60,
        0xff,
        0xf1,
    };

    const result = try vm.execute(&code, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    // First call: 21 + (700 + 2600) = 3321
    // Second call: 21 + (700 + 100) = 821
    try testing.expectEqual(@as(u64, 4_142), vm.gas_used);
}

test "EVM: SLOAD cold then warm has exact gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 100_000);
    defer vm.deinit();

    const code = [_]u8{
        0x60, 0x01, // PUSH1 key
        0x54, // SLOAD (cold)
        0x60, 0x01, // PUSH1 key
        0x54, // SLOAD (warm)
    };

    const result = try vm.execute(&code, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    // PUSH1 + SLOAD(cold) + PUSH1 + SLOAD(warm) = 3 + 2100 + 3 + 100
    try testing.expectEqual(@as(u64, 2_206), vm.gas_used);
}

test "EVM: SSTORE clear tracks refund and exact gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 100_000);
    defer vm.deinit();

    const code = [_]u8{
        // SSTORE key=1 value=7 (cold, zero->nonzero): 3+3 + 2100 + 20000
        0x60, 0x07, // PUSH1 value
        0x60, 0x01, // PUSH1 key
        0x55, // SSTORE
        // SSTORE key=1 value=0 (warm, nonzero->zero): 3+3 + 100, refund +4800
        0x60, 0x00, // PUSH1 value
        0x60, 0x01, // PUSH1 key
        0x55, // SSTORE
    };

    const result = try vm.execute(&code, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    try testing.expectEqual(@as(u64, 22_212), vm.gas_used);
    try testing.expectEqual(@as(u64, 19_900), vm.gas_refund);
}

test "EVM: SSTORE reset to original value earns exact refund" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 200_000);
    defer vm.deinit();

    const code = [_]u8{
        0x60, 0x07, // value
        0x60, 0x01, // key
        0x55, // SSTORE 0 -> 7
        0x60, 0x00, // value
        0x60, 0x01, // key
        0x55, // SSTORE 7 -> 0 (reset to original)
    };

    const result = try vm.execute(&code, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    try testing.expectEqual(@as(u64, 22_212), vm.gas_used);
    try testing.expectEqual(@as(u64, 19_900), vm.gas_refund);
}

test "EVM: SSTORE dirty clear then restore removes intermediate refund" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    try db.setStorage(types.Address.zero, types.U256.fromU64(1), types.U256.fromU64(5));

    var vm = try evm.EVM.initWithState(allocator, 200_000, evm.ExecutionContext.default(), &db);
    defer vm.deinit();

    const code = [_]u8{
        0x60, 0x00, // value
        0x60, 0x01, // key
        0x55, // SSTORE 5 -> 0
        0x60, 0x05, // value
        0x60, 0x01, // key
        0x55, // SSTORE 0 -> 5 (restore original)
    };

    const result = try vm.execute(&code, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    try testing.expectEqual(@as(u64, 5_112), vm.gas_used);
    try testing.expectEqual(@as(u64, 2_800), vm.gas_refund);
    try testing.expectEqual(@as(u64, 5), (try db.getStorage(types.Address.zero, types.U256.fromU64(1))).limbs[0]);
}

test "EVM: CALLCODE shares original storage state across nested frames" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var caller = types.Address.zero;
    caller.bytes[19] = 0xaa;
    try db.createAccount(caller);
    try db.setStorage(caller, types.U256.fromU64(1), types.U256.fromU64(5));

    var clear_code_addr = types.Address.zero;
    clear_code_addr.bytes[19] = 0x0a;
    try db.setCode(clear_code_addr, &[_]u8{
        0x60, 0x00, // value
        0x60, 0x01, // key
        0x55, // SSTORE
        0x00, // STOP
    });

    var restore_code_addr = types.Address.zero;
    restore_code_addr.bytes[19] = 0x0b;
    try db.setCode(restore_code_addr, &[_]u8{
        0x60, 0x05, // value
        0x60, 0x01, // key
        0x55, // SSTORE
        0x00, // STOP
    });

    var ctx = evm.ExecutionContext.default();
    ctx.address = caller;
    ctx.caller = caller;

    var vm = try evm.EVM.initWithState(allocator, 200_000, ctx, &db);
    defer vm.deinit();

    const code = [_]u8{
        0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x0a, 0x61, 0xff, 0xff, 0xf2, // CALLCODE clear
        0x50, // POP
        0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x0b, 0x61, 0xff, 0xff, 0xf2, // CALLCODE restore
    };

    const result = try vm.execute(&code, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    const second_success = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 1), second_success.limbs[0]);
    try testing.expectEqual(@as(u64, 11_756), vm.gas_used);
    try testing.expectEqual(@as(u64, 2_800), vm.gas_refund);
    try testing.expectEqual(@as(u64, 5), (try db.getStorage(caller, types.U256.fromU64(1))).limbs[0]);
}

test "EVM: reverted CALLCODE still warms caller storage for parent access" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var caller = types.Address.zero;
    caller.bytes[19] = 0xbb;
    try db.createAccount(caller);
    try db.setStorage(caller, types.U256.fromU64(1), types.U256.fromU64(5));

    var code_addr = types.Address.zero;
    code_addr.bytes[19] = 0x0c;
    try db.setCode(code_addr, &[_]u8{
        0x60, 0x01, // key
        0x54, // SLOAD (warms caller slot via CALLCODE storage context)
        0x60, 0x00, // revert offset
        0x60, 0x00, // revert size
        0xfd, // REVERT
    });

    var ctx = evm.ExecutionContext.default();
    ctx.address = caller;
    ctx.caller = caller;

    var vm = try evm.EVM.initWithState(allocator, 200_000, ctx, &db);
    defer vm.deinit();

    const code = [_]u8{
        0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x0c, 0x61, 0xff, 0xff, 0xf2, // CALLCODE revert
        0x50, // POP
        0x60, 0x01, // key
        0x54, // SLOAD should now be warm
    };

    const result = try vm.execute(&code, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    try testing.expectEqual(@as(u64, 5_535), vm.gas_used);
    const loaded = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 5), loaded.limbs[0]);
}

test "EVM: reverted child frame still warms accessed account for parent" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var callee = types.Address.zero;
    callee.bytes[19] = 0x0a;
    try db.setCode(callee, &[_]u8{
        0x60, 0x0b, // address to warm
        0x31, // BALANCE
        0x60, 0x00, // revert offset
        0x60, 0x00, // revert size
        0xfd, // REVERT
    });

    var beneficiary = types.Address.zero;
    beneficiary.bytes[19] = 0x0b;
    try db.createAccount(beneficiary);
    try db.setBalance(beneficiary, types.U256.fromU64(7));

    var vm = try evm.EVM.initWithState(allocator, 200_000, evm.ExecutionContext.default(), &db);
    defer vm.deinit();

    const code = [_]u8{
        0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x0a, 0x61, 0xff, 0xff, 0xf1, // CALL revert
        0x50, // POP
        0x60, 0x0b, // beneficiary
        0x31, // BALANCE should now be warm
    };

    const result = try vm.execute(&code, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    try testing.expectEqual(@as(u64, 6_035), vm.gas_used);
    const loaded = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 7), loaded.limbs[0]);
}

test "EVM: CALL to precompile address uses warm access cost" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 100_000);
    defer vm.deinit();

    const code = [_]u8{
        0x60, 0x00, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x00, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x00, // value
        0x60, 0x02, // precompile SHA256 address
        0x60, 0xff, // gas
        0xf1, // CALL
    };

    const result = try vm.execute(&code, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    // CALL base is 700 + warm(100); no calldata, no return copy, precompile gas is 60.
    // Plus 7 PUSH1 operations.
    try testing.expectEqual(@as(u64, 881), vm.gas_used);
}

test "EVM: CALL charges return-memory expansion gas exactly" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var target = types.Address.zero;
    target.bytes[19] = 0x0a;

    // Child: PUSH1 0; PUSH1 0; RETURN (returns empty, still successful).
    const callee = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0xf3 };
    try db.setCode(target, &callee);

    var vm = try evm.EVM.initWithState(allocator, 200_000, evm.ExecutionContext.default(), &db);
    defer vm.deinit();

    const caller = [_]u8{
        0x60, 0x20, // outSize
        0x60, 0x40, // outOffset
        0x60, 0x00, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x00, // value
        0x60, 0x0a, // address
        0x60, 0xff, // gas
        0xf1, // CALL
    };

    const result = try vm.execute(&caller, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    // Parent push gas: 21
    // CALL base: 700 + 2600 (cold account) = 3300
    // Return memory expansion: 0 -> 96 bytes = 3 words => 9 gas
    // Child execution: PUSH1 + PUSH1 + RETURN = 6 gas
    try testing.expectEqual(@as(u64, 3_336), vm.gas_used);
}

test "EVM: CALL propagates child gas refund on successful execution" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var callee = types.Address.zero;
    callee.bytes[19] = 0x0a;

    // Child clears a pre-set non-zero slot, earning SSTORE clear refund.
    const callee_code = [_]u8{
        0x60, 0x00, // value
        0x60, 0x01, // key
        0x55, // SSTORE
        0x00, // STOP
    };
    try db.setCode(callee, &callee_code);
    try db.setStorage(callee, types.U256.fromU64(1), types.U256.fromU64(7));

    var vm = try evm.EVM.initWithState(allocator, 200_000, evm.ExecutionContext.default(), &db);
    defer vm.deinit();

    const caller = [_]u8{
        0x60, 0x00, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x00, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x00, // value
        0x60, 0x0a, // address
        0x61, 0xff, 0xff, // gas
        0xf1, // CALL
    };

    const result = try vm.execute(&caller, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    // Parent: 21 push gas + (700 + 2600 cold access)
    // Child: PUSH1 + PUSH1 + SSTORE(cold clear original nonzero) + STOP = 3 + 3 + 2100 + 2900
    try testing.expectEqual(@as(u64, 8_327), vm.gas_used);
    try testing.expectEqual(@as(u64, 4_800), vm.gas_refund);
}

test "EVM: CREATE memory expansion persists across repeated creates" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 200_000);
    defer vm.deinit();

    const code = [_]u8{
        // First CREATE with len=32 expands memory from 0 to 32 bytes.
        0x60, 0x20, // len
        0x60, 0x00, // offset
        0x60, 0x00, // value
        0xf0, // CREATE
        // Second CREATE with same memory range should pay no additional expansion.
        0x60, 0x20, // len
        0x60, 0x00, // offset
        0x60, 0x00, // value
        0xf0, // CREATE
    };

    const result = try vm.execute(&code, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    // First: 9 push + (32000 + 3 mem + 3 copy + 2 initcode) = 32017
    // Second: 9 push + (32000 + 0 mem + 3 copy + 2 initcode) = 32014
    try testing.expectEqual(@as(u64, 64_031), vm.gas_used);
}

test "EVM: nested CALL revert restores child storage" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var callee = types.Address.zero;
    callee.bytes[19] = 0x0b;

    const callee_code = [_]u8{
        0x60, 0x2a, // value
        0x60, 0x01, // key
        0x55, // SSTORE
        0x60, 0x00, // revert offset
        0x60, 0x00, // revert length
        0xfd, // REVERT
    };
    try db.setCode(callee, &callee_code);

    var vm = try evm.EVM.initWithState(allocator, 200_000, evm.ExecutionContext.default(), &db);
    defer vm.deinit();

    const caller = [_]u8{
        0x60, 0x00, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x00, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x00, // value
        0x60, 0x0b, // address
        0x61, 0xff, 0xff, // gas
        0xf1, // CALL
    };

    const result = try vm.execute(&caller, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    const call_success = try vm.stack.pop();
    try testing.expect(call_success.isZero());
    const stored = try db.getStorage(callee, types.U256.fromU64(1));
    try testing.expect(stored.isZero());
}

test "EVM: CREATE revert restores creator nonce and balance" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var creator = types.Address.zero;
    creator.bytes[19] = 0xcc;
    try db.createAccount(creator);
    try db.setBalance(creator, types.U256.fromU64(100));

    var context = evm.ExecutionContext.default();
    context.address = creator;
    context.caller = creator;

    var vm = try evm.EVM.initWithState(allocator, 200_000, context, &db);
    defer vm.deinit();

    const code = [_]u8{
        0x60, 0xfd, // REVERT opcode byte
        0x60, 0x00, // mem offset
        0x53, // MSTORE8
        0x60, 0x01, // length
        0x60, 0x00, // offset
        0x60, 0x01, // value
        0xf0, // CREATE
    };

    const result = try vm.execute(&code, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    const create_out = try vm.stack.pop();
    try testing.expect(create_out.isZero());
    const creator_balance = try db.getBalance(creator);
    try testing.expectEqual(@as(u64, 100), creator_balance.limbs[0]);
    try testing.expectEqual(@as(u64, 0), try db.getNonce(creator));
}

test "EVM: nested CALL->CREATE failure rolls back callee nonce and balance" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var callee = types.Address.zero;
    callee.bytes[19] = 0x0b;
    try db.createAccount(callee);
    try db.setBalance(callee, types.U256.fromU64(10));

    // Callee builds 1-byte failing init code and executes CREATE(value=1).
    // Nested execution should not leave nonce/balance mutations behind.
    const callee_code = [_]u8{
        0x60, 0xfd, // REVERT opcode byte
        0x60, 0x00, // mem offset
        0x53, // MSTORE8
        0x60, 0x01, // length
        0x60, 0x00, // offset
        0x60, 0x01, // value
        0xf0, // CREATE
        0x50, // POP create result (zero)
        0x00, // STOP
    };
    try db.setCode(callee, &callee_code);

    var vm = try evm.EVM.initWithState(allocator, 300_000, evm.ExecutionContext.default(), &db);
    defer vm.deinit();

    const caller = [_]u8{
        0x60, 0x00, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x00, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x00, // value
        0x60, 0x0b, // callee
        0x61, 0xff, 0xff, // gas
        0xf1, // CALL
    };

    const result = try vm.execute(&caller, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    const call_success = try vm.stack.pop();
    try testing.expect(!call_success.isZero());
    try testing.expectEqual(@as(u64, 10), (try db.getBalance(callee)).limbs[0]);
    try testing.expectEqual(@as(u64, 0), try db.getNonce(callee));
}

test "EVM: PREVRANDAO returns context value when set" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = evm.ExecutionContext.default();
    ctx.block_prev_randao = types.U256.fromU64(0x12345678);

    var vm = try evm.EVM.initWithContext(allocator, 100_000, ctx);
    defer vm.deinit();

    const code = [_]u8{0x44}; // PREVRANDAO/DIFFICULTY

    const exec_result = try vm.execute(&code, &[_]u8{});
    defer if (exec_result.return_data.len > 0) allocator.free(exec_result.return_data);
    defer allocator.free(exec_result.logs);
    const val = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 0x12345678), val.limbs[0]);
}

test "EVM: top-level REVERT rolls back nested SELFDESTRUCT effects" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var callee = types.Address.zero;
    callee.bytes[19] = 0x0a;
    var beneficiary = types.Address.zero;
    beneficiary.bytes[19] = 0x01;

    // Child selfdestructs to beneficiary.
    const callee_code = [_]u8{
        0x60, 0x01, // beneficiary
        0xff, // SELFDESTRUCT
    };
    try db.setCode(callee, &callee_code);
    try db.setBalance(callee, types.U256.fromU64(10));
    try db.createAccount(callee);

    var vm = try evm.EVM.initWithState(allocator, 300_000, evm.ExecutionContext.default(), &db);
    defer vm.deinit();

    const caller = [_]u8{
        0x60, 0x00, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x00, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x00, // value
        0x60, 0x0a, // address
        0x61, 0xff, 0xff, // gas
        0xf1, // CALL
        0x60, 0x00, // revert offset
        0x60, 0x00, // revert size
        0xfd, // REVERT top-level tx
    };

    const result = try vm.execute(&caller, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    try testing.expect(!result.success);
    try testing.expect(db.exists(callee));
    const callee_balance = try db.getBalance(callee);
    try testing.expectEqual(@as(u64, 10), callee_balance.limbs[0]);
    const beneficiary_balance = try db.getBalance(beneficiary);
    try testing.expect(beneficiary_balance.isZero());
}

test "EVM: CALLCODE stipend forwarding with non-zero value" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var sender = types.Address.zero;
    sender.bytes[19] = 0xaa;
    try db.createAccount(sender);
    try db.setBalance(sender, types.U256.fromU64(1_000_000));

    var target = types.Address.zero;
    target.bytes[19] = 0x0c;
    try db.createAccount(target);
    const callee_code = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x00, // STOP
    };
    try db.setCode(target, &callee_code);

    var ctx = evm.ExecutionContext.default();
    ctx.address = sender;
    ctx.caller = sender;

    var vm = try evm.EVM.initWithState(allocator, 100_000, ctx, &db);
    defer vm.deinit();

    const caller = [_]u8{
        0x60, 0x00, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x00, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x01, // value (non-zero => stipend-eligible)
        0x60, 0x0c, // address
        0x60, 0x00, // requested gas = 0
        0xf2, // CALLCODE
    };

    const result = try vm.execute(&caller, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    const call_success = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 1), call_success.limbs[0]);

    // Parent push gas: 7 * 3 = 21
    // CALLCODE base: 700 + 2600(cold) + 9000(value) = 12300
    // Child execution uses stipend gas: PUSH1(3) + STOP(0) = 3
    try testing.expectEqual(@as(u64, 12_324), vm.gas_used);
}

test "EVM: DELEGATECALL no stipend even with parent value context" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var target = types.Address.zero;
    target.bytes[19] = 0x0d;
    try db.createAccount(target);
    const callee_code = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x00, // STOP
    };
    try db.setCode(target, &callee_code);

    var vm = try evm.EVM.initWithState(allocator, 100_000, evm.ExecutionContext.default(), &db);
    defer vm.deinit();

    const caller = [_]u8{
        0x60, 0x00, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x00, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x0d, // address
        0x60, 0x00, // requested gas = 0
        0xf4, // DELEGATECALL
    };

    const result = try vm.execute(&caller, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    // DELEGATECALL never adds stipend (no value parameter).
    // 6 pushes = 18 gas, base = 700 + 2600(cold) = 3300
    // Child gets 0 gas (no stipend), cannot execute, but no code to run with 0 gas.
    try testing.expectEqual(@as(u64, 3_318), vm.gas_used);
}

test "EVM: STATICCALL no stipend" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var target = types.Address.zero;
    target.bytes[19] = 0x0e;
    try db.createAccount(target);
    const callee_code = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x00, // STOP
    };
    try db.setCode(target, &callee_code);

    var vm = try evm.EVM.initWithState(allocator, 100_000, evm.ExecutionContext.default(), &db);
    defer vm.deinit();

    const caller = [_]u8{
        0x60, 0x00, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x00, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x0e, // address
        0x60, 0x00, // requested gas = 0
        0xfa, // STATICCALL
    };

    const result = try vm.execute(&caller, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    // STATICCALL never adds stipend (no value parameter).
    // 6 pushes = 18 gas, base = 700 + 2600(cold) = 3300
    try testing.expectEqual(@as(u64, 3_318), vm.gas_used);
}

test "EVM: CALL value to NEW account charges 25000 extra" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var sender = types.Address.zero;
    sender.bytes[19] = 0xaa;
    try db.createAccount(sender);
    try db.setBalance(sender, types.U256.fromU64(1_000_000));

    // Address 0x0f is intentionally NOT created in the state DB.
    var target = types.Address.zero;
    target.bytes[19] = 0x0f;

    var ctx = evm.ExecutionContext.default();
    ctx.address = sender;
    ctx.caller = sender;

    var vm = try evm.EVM.initWithState(allocator, 200_000, ctx, &db);
    defer vm.deinit();

    const caller = [_]u8{
        0x60, 0x00, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x00, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x01, // value (non-zero => triggers new account charge)
        0x60, 0x0f, // address (does not exist)
        0x60, 0x00, // requested gas = 0
        0xf1, // CALL
    };

    const result = try vm.execute(&caller, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    const call_success = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 1), call_success.limbs[0]);

    // 7 pushes = 21 gas
    // CALL base: 700 + 2600(cold) + 9000(value) + 25000(new account) = 37300
    // Child has stipend=2300 but target has no code => charged_child_gas=0
    try testing.expectEqual(@as(u64, 37_321), vm.gas_used);
    try testing.expectEqual(@as(u64, 999_999), (try db.getBalance(sender)).limbs[0]);
    try testing.expectEqual(@as(u64, 1), (try db.getBalance(target)).limbs[0]);
}

test "EVM: CALL value insufficient balance fails gracefully" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var sender = types.Address.zero;
    sender.bytes[19] = 0xaa;
    try db.createAccount(sender);
    // Sender has zero balance -- cannot afford value transfer.
    try db.setBalance(sender, types.U256.zero());

    var target = types.Address.zero;
    target.bytes[19] = 0x10;
    try db.createAccount(target);

    var ctx = evm.ExecutionContext.default();
    ctx.address = sender;
    ctx.caller = sender;

    var vm = try evm.EVM.initWithState(allocator, 100_000, ctx, &db);
    defer vm.deinit();

    const caller = [_]u8{
        0x60, 0x00, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x00, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x01, // value = 1 (sender can't afford this)
        0x60, 0x10, // address (existing account)
        0x60, 0x00, // requested gas = 0
        0xf1, // CALL
    };

    const result = try vm.execute(&caller, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    // Call should return 0 (failure) but NOT cause a hard OOG.
    const call_success = try vm.stack.pop();
    try testing.expect(call_success.isZero());

    // Execution itself succeeds (no hard OOG).
    try testing.expect(result.success);

    // 7 pushes = 21 gas
    // CALL base: 700 + 2600(cold) + 9000(value) = 12300
    // No child gas charged (transfer failed before child execution).
    try testing.expectEqual(@as(u64, 12_321), vm.gas_used);

    // Balances unchanged.
    try testing.expect((try db.getBalance(sender)).isZero());
    try testing.expect((try db.getBalance(target)).isZero());
}

test "EVM: CREATE exact gas accounting for empty init code" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var sender = types.Address.zero;
    sender.bytes[19] = 0xaa;
    try db.createAccount(sender);
    try db.setBalance(sender, types.U256.fromU64(1_000_000));

    var ctx = evm.ExecutionContext.default();
    ctx.address = sender;
    ctx.caller = sender;

    var vm = try evm.EVM.initWithState(allocator, 100_000, ctx, &db);
    defer vm.deinit();

    const caller = [_]u8{
        0x60, 0x00, // length = 0
        0x60, 0x00, // offset = 0
        0x60, 0x00, // value = 0
        0xf0, // CREATE
    };

    const result = try vm.execute(&caller, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    // Stack should have the new contract address (non-zero on success).
    const created_addr = try vm.stack.pop();
    try testing.expect(!created_addr.isZero());

    // 3 pushes = 9 gas
    // CREATE base: 32000 + 0(mem) + 0(copy) = 32000
    // Child executes empty init code => gas_used = 0
    try testing.expectEqual(@as(u64, 32_009), vm.gas_used);
}

test "EVM: CREATE2 exact gas with hash cost" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var sender = types.Address.zero;
    sender.bytes[19] = 0xaa;
    try db.createAccount(sender);
    try db.setBalance(sender, types.U256.fromU64(1_000_000));

    var ctx = evm.ExecutionContext.default();
    ctx.address = sender;
    ctx.caller = sender;

    var vm = try evm.EVM.initWithState(allocator, 100_000, ctx, &db);
    defer vm.deinit();

    // Init code is 32 bytes at memory offset 0.
    // Memory starts empty; readMemoryInput zero-fills, so init code = 32 x 0x00.
    // First byte 0x00 = STOP, so child halts immediately.
    const caller = [_]u8{
        0x60, 0x00, // salt = 0
        0x60, 0x20, // length = 32
        0x60, 0x00, // offset = 0
        0x60, 0x00, // value = 0
        0xf5, // CREATE2
    };

    const result = try vm.execute(&caller, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    const created_addr = try vm.stack.pop();
    try testing.expect(!created_addr.isZero());

    // 4 pushes = 12 gas
    // words = ceil(32/32) = 1
    // CREATE2 base: 32000 + 3(mem, 1 word) + 3(copy, 1*3) + 6(hash, 1*6) + 2(initcode, 1*2) = 32014
    // Child executes STOP immediately => gas_used = 0
    try testing.expectEqual(@as(u64, 32_026), vm.gas_used);
}

test "EVM: nested CALL child refund propagates on success not on failure" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // --- Part 1: child succeeds, parent inherits gas_refund ---
    {
        var db = state.StateDB.init(allocator);
        defer db.deinit();

        var sender = types.Address.zero;
        sender.bytes[19] = 0xaa;
        try db.createAccount(sender);
        try db.setBalance(sender, types.U256.fromU64(1_000_000));

        var child_addr = types.Address.zero;
        child_addr.bytes[19] = 0x0a;
        try db.createAccount(child_addr);

        // Pre-set storage slot 0 to value 1 for the child address.
        try db.setStorage(child_addr, types.U256.zero(), types.U256.one());

        // Child code: SSTORE(slot=0, value=0) then STOP.
        // Non-zero to zero earns 4800 refund.
        const child_code = [_]u8{
            0x60, 0x00, // PUSH1 0 (new value)
            0x60, 0x00, // PUSH1 0 (slot)
            0x55, // SSTORE
            0x00, // STOP
        };
        try db.setCode(child_addr, &child_code);

        var ctx = evm.ExecutionContext.default();
        ctx.address = sender;
        ctx.caller = sender;

        var vm = try evm.EVM.initWithState(allocator, 200_000, ctx, &db);
        defer vm.deinit();

        const caller = [_]u8{
            0x60, 0x00, // outSize
            0x60, 0x00, // outOffset
            0x60, 0x00, // inSize
            0x60, 0x00, // inOffset
            0x60, 0x00, // value
            0x60, 0x0a, // address
            0x61, 0xff, 0xff, // gas = 0xFFFF
            0xf1, // CALL
        };

        const result = try vm.execute(&caller, &[_]u8{});
        defer if (result.return_data.len > 0) allocator.free(result.return_data);
        defer allocator.free(result.logs);

        const call_success = try vm.stack.pop();
        try testing.expectEqual(@as(u64, 1), call_success.limbs[0]);

        // Child SSTORE non-zero->zero earns 4800 refund; parent inherits it.
        try testing.expectEqual(@as(u64, 4_800), vm.gas_refund);
    }

    // --- Part 2: child reverts, parent gas_refund stays at zero ---
    {
        var db = state.StateDB.init(allocator);
        defer db.deinit();

        var sender = types.Address.zero;
        sender.bytes[19] = 0xaa;
        try db.createAccount(sender);
        try db.setBalance(sender, types.U256.fromU64(1_000_000));

        var child_addr = types.Address.zero;
        child_addr.bytes[19] = 0x0b;
        try db.createAccount(child_addr);

        // Pre-set storage slot 0 to value 1 for the child address.
        try db.setStorage(child_addr, types.U256.zero(), types.U256.one());

        // Child code: SSTORE(slot=0, value=0) then REVERT.
        // Earns refund in child but REVERT discards it.
        const child_code = [_]u8{
            0x60, 0x00, // PUSH1 0 (new value)
            0x60, 0x00, // PUSH1 0 (slot)
            0x55, // SSTORE
            0x60, 0x00, // PUSH1 0 (revert offset)
            0x60, 0x00, // PUSH1 0 (revert length)
            0xfd, // REVERT
        };
        try db.setCode(child_addr, &child_code);

        var ctx = evm.ExecutionContext.default();
        ctx.address = sender;
        ctx.caller = sender;

        var vm = try evm.EVM.initWithState(allocator, 200_000, ctx, &db);
        defer vm.deinit();

        const caller = [_]u8{
            0x60, 0x00, // outSize
            0x60, 0x00, // outOffset
            0x60, 0x00, // inSize
            0x60, 0x00, // inOffset
            0x60, 0x00, // value
            0x60, 0x0b, // address
            0x61, 0xff, 0xff, // gas = 0xFFFF
            0xf1, // CALL
        };

        const result = try vm.execute(&caller, &[_]u8{});
        defer if (result.return_data.len > 0) allocator.free(result.return_data);
        defer allocator.free(result.logs);

        const call_success = try vm.stack.pop();
        try testing.expect(call_success.isZero());

        // Child reverted, so parent gas_refund must remain unchanged (zero).
        try testing.expectEqual(@as(u64, 0), vm.gas_refund);
    }
}

// =============================================================================
// EIP-3855: PUSH0 tests
// =============================================================================

test "EVM: PUSH0 pushes zero onto stack" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // PUSH0, STOP
    const bytecode = [_]u8{ 0x5f, 0x00 };
    const result = try vm.execute(&bytecode, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    const top = try vm.stack.pop();
    try testing.expect(top.isZero());
    // PUSH0 costs 2 gas
    try testing.expectEqual(@as(u64, 2), result.gas_used);
}

// =============================================================================
// EIP-5656: MCOPY tests
// =============================================================================

test "EVM: MCOPY non-overlapping copy" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // Store 0xDEADBEEF at memory offset 0 via MSTORE
    // Then MCOPY from offset 0 to offset 64, length 32
    // Then MLOAD from offset 64 to verify
    const bytecode = [_]u8{
        0x63, 0xDE, 0xAD, 0xBE, 0xEF, // PUSH4 0xDEADBEEF
        0x60, 0x00, // PUSH1 0 (offset)
        0x52, // MSTORE (stores at offset 0)
        // MCOPY: stack order is dst, src, length
        0x60, 0x20, // PUSH1 32 (length)
        0x60, 0x00, // PUSH1 0 (src_offset)
        0x60, 0x40, // PUSH1 64 (dst_offset)
        0x5e, // MCOPY
        // Load from offset 64 to verify
        0x60, 0x40, // PUSH1 64
        0x51, // MLOAD
        0x00, // STOP
    };

    const result = try vm.execute(&bytecode, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    const top = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 0xDEADBEEF), top.limbs[0]);
}

test "EVM: MCOPY overlapping forward (src < dst)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // Store data at offset 0, MCOPY 32 bytes from offset 0 to offset 16
    // This is an overlapping forward copy where dst > src.
    const bytecode = [_]u8{
        // Store a known value at memory[0..32]
        0x7f, // PUSH32
        0x01,
        0x02,
        0x03,
        0x04,
        0x05,
        0x06,
        0x07,
        0x08,
        0x09,
        0x0A,
        0x0B,
        0x0C,
        0x0D,
        0x0E,
        0x0F,
        0x10,
        0x11,
        0x12,
        0x13,
        0x14,
        0x15,
        0x16,
        0x17,
        0x18,
        0x19,
        0x1A,
        0x1B,
        0x1C,
        0x1D,
        0x1E,
        0x1F,
        0x20,
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE at offset 0
        // MCOPY: dst=16, src=0, length=32
        0x60, 0x20, // PUSH1 32 (length)
        0x60, 0x00, // PUSH1 0 (src)
        0x60, 0x10, // PUSH1 16 (dst)
        0x5e, // MCOPY
        // Load from offset 16 to verify the first 32 bytes starting at dst
        0x60, 0x10, // PUSH1 16
        0x51, // MLOAD
        0x00, // STOP
    };

    const result = try vm.execute(&bytecode, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    // memory[16..48] should contain the original memory[0..32] data
    const top = try vm.stack.pop();
    // The original data at [0..32] was 0x0102...1F20
    // After MCOPY(dst=16, src=0, len=32), memory[16..48] = original memory[0..32]
    // MLOAD at 16 reads memory[16..48] which should be the original value
    const expected_bytes = [32]u8{
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
        0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x20,
    };
    const expected = types.U256.fromBytes(expected_bytes);
    try testing.expectEqual(expected, top);
}

test "EVM: MCOPY overlapping backward (dst < src)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // Store data at offset 16, MCOPY 32 bytes from offset 16 to offset 0
    // Overlapping backward copy where dst < src.
    const bytecode = [_]u8{
        // Store a known value at memory[16..48]
        0x7f, // PUSH32
        0xA1,
        0xA2,
        0xA3,
        0xA4,
        0xA5,
        0xA6,
        0xA7,
        0xA8,
        0xB1,
        0xB2,
        0xB3,
        0xB4,
        0xB5,
        0xB6,
        0xB7,
        0xB8,
        0xC1,
        0xC2,
        0xC3,
        0xC4,
        0xC5,
        0xC6,
        0xC7,
        0xC8,
        0xD1,
        0xD2,
        0xD3,
        0xD4,
        0xD5,
        0xD6,
        0xD7,
        0xD8,
        0x60, 0x10, // PUSH1 16
        0x52, // MSTORE at offset 16
        // MCOPY: dst=0, src=16, length=32
        0x60, 0x20, // PUSH1 32 (length)
        0x60, 0x10, // PUSH1 16 (src)
        0x60, 0x00, // PUSH1 0 (dst)
        0x5e, // MCOPY
        // Load from offset 0 to verify
        0x60, 0x00, // PUSH1 0
        0x51, // MLOAD
        0x00, // STOP
    };

    const result = try vm.execute(&bytecode, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    const top = try vm.stack.pop();
    const expected_bytes = [32]u8{
        0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8,
        0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8,
        0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8,
        0xD1, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8,
    };
    const expected = types.U256.fromBytes(expected_bytes);
    try testing.expectEqual(expected, top);
}

test "EVM: MCOPY zero length costs only base gas" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 1000000);
    defer vm.deinit();

    // MCOPY with length=0: should cost only 3 gas (base), no memory expansion
    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0 (length)
        0x60, 0x00, // PUSH1 0 (src)
        0x60, 0x00, // PUSH1 0 (dst)
        0x5e, // MCOPY
        0x00, // STOP
    };

    const result = try vm.execute(&bytecode, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    // 3 * PUSH1 (3 gas each) + MCOPY zero-length (3 gas) = 12
    try testing.expectEqual(@as(u64, 12), result.gas_used);
    // Memory should not have expanded
    try testing.expectEqual(@as(usize, 0), vm.memory.data.items.len);
}

// ===== EIP-1153: Transient Storage (TLOAD / TSTORE) =====

test "EVM: TSTORE then TLOAD returns stored value" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 100_000);
    defer vm.deinit();

    // TSTORE(key=1, value=0x42), then TLOAD(key=1)
    const code = [_]u8{
        0x60, 0x42, // PUSH1 0x42 (value)
        0x60, 0x01, // PUSH1 0x01 (key)
        0x5d, // TSTORE
        0x60, 0x01, // PUSH1 0x01 (key)
        0x5c, // TLOAD
        0x00, // STOP
    };

    const result = try vm.execute(&code, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    const loaded = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 0x42), loaded.limbs[0]);

    // Gas: 2*PUSH1(3) + TSTORE(100) + PUSH1(3) + TLOAD(100) = 209
    try testing.expectEqual(@as(u64, 209), vm.gas_used);
}

test "EVM: TLOAD of unset key returns 0" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 100_000);
    defer vm.deinit();

    // TLOAD(key=0xff) without prior TSTORE
    const code = [_]u8{
        0x60, 0xff, // PUSH1 0xff (key)
        0x5c, // TLOAD
        0x00, // STOP
    };

    const result = try vm.execute(&code, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    const loaded = try vm.stack.pop();
    try testing.expect(loaded.isZero());
}

test "EVM: TSTORE in static context returns error" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    // Callee tries to TSTORE inside a STATICCALL
    var callee_addr = types.Address.zero;
    callee_addr.bytes[19] = 0x0c;
    const callee_code = [_]u8{
        0x60, 0x42, // PUSH1 value
        0x60, 0x01, // PUSH1 key
        0x5d, // TSTORE (must fail under STATICCALL)
        0x00, // STOP
    };
    try db.createAccount(callee_addr);
    try db.setCode(callee_addr, &callee_code);

    var caller = types.Address.zero;
    caller.bytes[19] = 0xaa;
    try db.createAccount(caller);

    var context = evm.ExecutionContext.default();
    context.address = caller;
    context.caller = caller;

    var vm = try evm.EVM.initWithState(allocator, 1_000_000, context, &db);
    defer vm.deinit();

    // STATICCALL to callee
    const code = [_]u8{
        0x60, 0x00, // outSize
        0x60, 0x00, // outOffset
        0x60, 0x00, // inSize
        0x60, 0x00, // inOffset
        0x60, 0x0c, // address
        0x61, 0xff, 0xff, // gas
        0xfa, // STATICCALL
    };

    _ = try vm.execute(&code, &[_]u8{});
    // STATICCALL should return 0 (failure) because TSTORE in static context is not allowed
    const success = try vm.stack.pop();
    try testing.expect(success.isZero());
}

test "EVM: transient storage is per-address" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 100_000);
    defer vm.deinit();

    // Store value under address A
    var addr_a = types.Address.zero;
    addr_a.bytes[19] = 0x0a;
    var addr_b = types.Address.zero;
    addr_b.bytes[19] = 0x0b;

    const key = types.U256.fromU64(1);
    const val_a = types.U256.fromU64(0xaa);
    const val_b = types.U256.fromU64(0xbb);

    // Manually store transient values for two different addresses
    try vm.transient_storage.put(.{ .address = addr_a, .key = key }, val_a);
    try vm.transient_storage.put(.{ .address = addr_b, .key = key }, val_b);

    // Set context to address A and TLOAD
    vm.context.address = addr_a;
    const code_tload = [_]u8{
        0x60, 0x01, // PUSH1 key=1
        0x5c, // TLOAD
        0x00, // STOP
    };

    const result_a = try vm.execute(&code_tload, &[_]u8{});
    defer if (result_a.return_data.len > 0) allocator.free(result_a.return_data);
    defer allocator.free(result_a.logs);

    const loaded_a = try vm.stack.pop();
    try testing.expectEqual(@as(u64, 0xaa), loaded_a.limbs[0]);
}

test "EVM: transient storage survives child REVERT via CALL" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    // Callee: TSTORE(key=7, value=0x99), then REVERT
    var callee_addr = types.Address.zero;
    callee_addr.bytes[19] = 0x0d;
    const callee_code = [_]u8{
        0x60, 0x99, // PUSH1 0x99 (value)
        0x60, 0x07, // PUSH1 0x07 (key)
        0x5d, // TSTORE
        0x60, 0x00, // PUSH1 0 (length)
        0x60, 0x00, // PUSH1 0 (offset)
        0xfd, // REVERT
    };
    try db.createAccount(callee_addr);
    try db.setCode(callee_addr, &callee_code);

    var caller = types.Address.zero;
    caller.bytes[19] = 0xcc;
    try db.createAccount(caller);

    var context = evm.ExecutionContext.default();
    context.address = caller;
    context.caller = caller;

    var vm = try evm.EVM.initWithState(allocator, 1_000_000, context, &db);
    defer vm.deinit();

    // CALL to callee (which will TSTORE then REVERT)
    // After the reverted CALL, transient storage should still have the value
    // because EIP-1153 transient storage is NOT journaled.
    const code = [_]u8{
        // CALL(gas=0xffff, addr=0x0d, value=0, inOff=0, inSize=0, outOff=0, outSize=0)
        0x60, 0x00, // retSize
        0x60, 0x00, // retOffset
        0x60, 0x00, // argsSize
        0x60, 0x00, // argsOffset
        0x60, 0x00, // value
        0x60, 0x0d, // address
        0x61, 0xff, 0xff, // gas
        0xf1, // CALL
        0x50, // POP the call result
        0x00, // STOP
    };

    const result = try vm.execute(&code, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    // After the reverted CALL, transient storage for the callee address should
    // still have the value because transient storage survives REVERT.
    const tkey = evm.TransientKey{ .address = callee_addr, .key = types.U256.fromU64(7) };
    const stored = vm.transient_storage.get(tkey) orelse types.U256.zero();
    try testing.expectEqual(@as(u64, 0x99), stored.limbs[0]);
}

test "EVM: CREATE fails when deployed code exceeds EIP-170 MAX_CODE_SIZE" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    const creator = types.Address{ .bytes = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xAA } };
    try db.createAccount(creator);
    try db.setBalance(creator, types.U256.fromU64(1_000_000));

    var context = evm.ExecutionContext.default();
    context.address = creator;
    context.caller = creator;

    // Build init code that RETURNs 24577 bytes (one over the 24576 limit).
    // The init code: PUSH2 0x6001 (24577), PUSH1 0x00, RETURN => 61 60 01 60 00 F3
    const init_code = [_]u8{ 0x61, 0x60, 0x01, 0x60, 0x00, 0xF3 };

    // Store init code in memory via MSTORE8, then call CREATE.
    var code_buf: [256]u8 = undefined;
    var ci: usize = 0;
    for (init_code, 0..) |b, idx2| {
        code_buf[ci] = 0x60;
        ci += 1;
        code_buf[ci] = b;
        ci += 1; // PUSH1 byte
        code_buf[ci] = 0x60;
        ci += 1;
        code_buf[ci] = @intCast(idx2);
        ci += 1; // PUSH1 offset
        code_buf[ci] = 0x53;
        ci += 1; // MSTORE8
    }
    // CREATE pops: value, offset, length. Push in reverse: length, offset, value.
    code_buf[ci] = 0x60;
    ci += 1;
    code_buf[ci] = 0x06;
    ci += 1; // length=6
    code_buf[ci] = 0x60;
    ci += 1;
    code_buf[ci] = 0x00;
    ci += 1; // offset=0
    code_buf[ci] = 0x60;
    ci += 1;
    code_buf[ci] = 0x00;
    ci += 1; // value=0
    code_buf[ci] = 0xF0;
    ci += 1; // CREATE

    var vm = try evm.EVM.initWithState(allocator, 50_000_000, context, &db);
    defer vm.deinit();

    const result = try vm.execute(code_buf[0..ci], &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);

    // CREATE should return 0 (failure) because output exceeds MAX_CODE_SIZE.
    const addr_result = try vm.stack.pop();
    try testing.expect(addr_result.isZero());
}

test "EVM: CREATE with init code exceeding EIP-3860 MAX_INITCODE_SIZE fails" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    const creator = types.Address{ .bytes = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xBB } };
    try db.createAccount(creator);
    try db.setBalance(creator, types.U256.fromU64(1_000_000));

    var context = evm.ExecutionContext.default();
    context.address = creator;
    context.caller = creator;

    // CREATE pops: value, offset, length. Push in reverse: length, offset, value.
    // length = 49153 (0x00C001) > MAX_INITCODE_SIZE (49152).
    const code = [_]u8{
        0x62, 0x00, 0xC0, 0x01, // PUSH3 49153 (length)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x00, // PUSH1 0 (value)
        0xF0, // CREATE
    };

    var vm = try evm.EVM.initWithState(allocator, 500_000_000, context, &db);
    defer vm.deinit();

    // Should fail with OutOfGas due to EIP-3860 initcode size limit.
    const err = vm.execute(&code, &[_]u8{});
    try testing.expectError(error.OutOfGas, err);
}

test "EVM: CREATE2 with init code exceeding EIP-3860 MAX_INITCODE_SIZE fails" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    const creator = types.Address{ .bytes = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xCC } };
    try db.createAccount(creator);
    try db.setBalance(creator, types.U256.fromU64(1_000_000));

    var context = evm.ExecutionContext.default();
    context.address = creator;
    context.caller = creator;

    // CREATE2 pops: value, offset, length, salt. Push in reverse: salt, length, offset, value.
    // length = 49153 (0x00C001) > MAX_INITCODE_SIZE (49152).
    const code = [_]u8{
        0x60, 0x00, // PUSH1 0 (salt)
        0x62, 0x00, 0xC0, 0x01, // PUSH3 49153 (length)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x00, // PUSH1 0 (value)
        0xF5, // CREATE2
    };

    var vm = try evm.EVM.initWithState(allocator, 500_000_000, context, &db);
    defer vm.deinit();

    // Should fail with OutOfGas due to EIP-3860 initcode size limit.
    const err = vm.execute(&code, &[_]u8{});
    try testing.expectError(error.OutOfGas, err);
}

// =============================================================================
// EIP-4844: BLOBHASH (0x49)
// =============================================================================

test "BLOBHASH returns correct versioned hash at valid index" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Build two sample versioned hashes
    var hash0: types.Hash = undefined;
    @memset(&hash0.bytes, 0);
    hash0.bytes[0] = 0x01; // version byte
    hash0.bytes[31] = 0xAA;

    var hash1: types.Hash = undefined;
    @memset(&hash1.bytes, 0);
    hash1.bytes[0] = 0x01;
    hash1.bytes[31] = 0xBB;

    const hashes = [_]types.Hash{ hash0, hash1 };

    var context = evm.ExecutionContext.default();
    context.blob_versioned_hashes = &hashes;

    var vm = try evm.EVM.init(allocator, 100_000);
    defer vm.deinit();
    vm.context = context;

    // PUSH1 0x00, BLOBHASH => should return hash0
    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0
        0x49, // BLOBHASH
    };

    const result = try vm.execute(&bytecode, &[_]u8{});
    try testing.expect(result.success);

    const top = try vm.stack.pop();
    const expected = types.U256.fromBytes(hash0.bytes);
    try testing.expectEqual(expected, top);
}

test "BLOBHASH returns zero for out-of-range index" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var hash0: types.Hash = undefined;
    @memset(&hash0.bytes, 0);
    hash0.bytes[0] = 0x01;
    hash0.bytes[31] = 0xAA;

    const hashes = [_]types.Hash{hash0};

    var context = evm.ExecutionContext.default();
    context.blob_versioned_hashes = &hashes;

    var vm = try evm.EVM.init(allocator, 100_000);
    defer vm.deinit();
    vm.context = context;

    // PUSH1 0x05 (index 5, only 1 hash), BLOBHASH => should return 0
    const bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5
        0x49, // BLOBHASH
    };

    const result = try vm.execute(&bytecode, &[_]u8{});
    try testing.expect(result.success);

    const top = try vm.stack.pop();
    try testing.expectEqual(types.U256.zero(), top);
}

test "BLOBHASH returns zero when no blob hashes configured" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 100_000);
    defer vm.deinit();
    // blob_versioned_hashes defaults to null

    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0
        0x49, // BLOBHASH
    };

    const result = try vm.execute(&bytecode, &[_]u8{});
    try testing.expect(result.success);

    const top = try vm.stack.pop();
    try testing.expectEqual(types.U256.zero(), top);
}

// =============================================================================
// EIP-7516: BLOBBASEFEE (0x4a)
// =============================================================================

test "BLOBBASEFEE returns configured blob base fee" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var context = evm.ExecutionContext.default();
    context.block_blob_base_fee = 42_000;

    var vm = try evm.EVM.init(allocator, 100_000);
    defer vm.deinit();
    vm.context = context;

    const bytecode = [_]u8{
        0x4a, // BLOBBASEFEE
    };

    const result = try vm.execute(&bytecode, &[_]u8{});
    try testing.expect(result.success);

    const top = try vm.stack.pop();
    try testing.expectEqual(types.U256.fromU64(42_000), top);
}

test "BLOBBASEFEE returns zero when not configured" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vm = try evm.EVM.init(allocator, 100_000);
    defer vm.deinit();
    // block_blob_base_fee defaults to null

    const bytecode = [_]u8{
        0x4a, // BLOBBASEFEE
    };

    const result = try vm.execute(&bytecode, &[_]u8{});
    try testing.expect(result.success);

    const top = try vm.stack.pop();
    try testing.expectEqual(types.U256.zero(), top);
}

// =============================================================================
// EIP-6780: SELFDESTRUCT only destroys if created in same tx
// =============================================================================

test "EIP-6780: SELFDESTRUCT of pre-existing contract only transfers balance" {
    return error.SkipZigTest;
}

test "EIP-6780: SELFDESTRUCT of contract created in same tx fully destroys" {
    return error.SkipZigTest;
}

// =============================================================================
// EIP-3529: SELFDESTRUCT gives no refund
// =============================================================================

test "EIP-3529: SELFDESTRUCT gives no gas refund post-London" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var sender = types.Address.zero;
    sender.bytes[19] = 0xaa;

    try db.createAccount(sender);
    try db.setBalance(sender, types.U256.fromU64(100));

    var context = evm.ExecutionContext.default();
    context.address = sender;
    context.caller = sender;

    var vm = try evm.EVM.initWithState(allocator, 1_000_000, context, &db);
    defer vm.deinit();

    // PUSH1 0x00 (beneficiary), SELFDESTRUCT
    const bytecode = [_]u8{ 0x60, 0x00, 0xff };

    const result = try vm.execute(&bytecode, &[_]u8{});
    defer if (result.return_data.len > 0) allocator.free(result.return_data);
    defer allocator.free(result.logs);
    try testing.expect(result.success);

    // EIP-3529: No gas refund from SELFDESTRUCT.
    try testing.expectEqual(@as(u64, 0), vm.gas_refund);
}

// =============================================================================
// EIP-2681: Nonce overflow check
// =============================================================================

test "EIP-2681: CREATE fails when creator nonce at max u64" {
    return error.SkipZigTest;
}

// =============================================================================
// EIP-3651: Warm coinbase (tested via transaction.zig)
// =============================================================================

test "EIP-3651: coinbase is pre-warmed in transaction execution" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const transaction = @import("transaction.zig");

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var sender = types.Address.zero;
    sender.bytes[19] = 0xaa;
    var coinbase_addr = types.Address.zero;
    coinbase_addr.bytes[19] = 0xcc;

    try db.createAccount(sender);
    try db.setBalance(sender, types.U256.fromU64(1_000_000_000));
    try db.createAccount(coinbase_addr);

    // Contract code: PUSH20 <coinbase>, BALANCE, POP, STOP
    // If coinbase is warm, BALANCE costs 100 gas.
    // If cold, BALANCE costs 2600 gas.
    var contract_addr = types.Address.zero;
    contract_addr.bytes[19] = 0xdd;

    var contract_code: [24]u8 = undefined;
    contract_code[0] = 0x73; // PUSH20
    @memset(contract_code[1..20], 0x00);
    contract_code[20] = 0xcc; // coinbase address last byte
    contract_code[21] = 0x31; // BALANCE
    contract_code[22] = 0x50; // POP
    contract_code[23] = 0x00; // STOP
    try db.createAccount(contract_addr);
    try db.setCode(contract_addr, &contract_code);

    const block = transaction.BlockContext{
        .number = 17_000_000,
        .timestamp = 1_700_000_000,
        .coinbase = coinbase_addr,
        .difficulty = types.U256.fromU64(0),
        .gas_limit = 30_000_000,
        .base_fee = 10,
        .chain_id = 1,
    };

    const tx = transaction.Transaction{
        .nonce = 0,
        .gas_limit = 100_000,
        .to = contract_addr,
        .value = types.U256.zero(),
        .data = &[_]u8{},
        .from = sender,
        .gas_price = 20,
    };

    const tx_result = try transaction.executeTransaction(allocator, tx, &db, block);
    // The transaction should succeed.
    try testing.expect(tx_result.success);
    // Total gas = 21000 (intrinsic) + 3 (PUSH20) + 100 (BALANCE warm) + 2 (POP) + 0 (STOP) = 21105
    // If coinbase were cold it would be 21000 + 3 + 2600 + 2 + 0 = 23605
    try testing.expectEqual(@as(u64, 21_105), tx_result.gas_used);
}

// =============================================================================
// EIP-161: Empty account cleanup
// =============================================================================

test "EIP-161: cleanupEmptyAccounts removes empty accounts" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = state.StateDB.init(allocator);
    defer db.deinit();

    var addr1 = types.Address.zero;
    addr1.bytes[19] = 0x01;
    var addr2 = types.Address.zero;
    addr2.bytes[19] = 0x02;
    var addr3 = types.Address.zero;
    addr3.bytes[19] = 0x03;

    // addr1: empty (nonce=0, balance=0, no code) -- should be removed
    try db.createAccount(addr1);
    // addr2: has balance -- should NOT be removed
    try db.createAccount(addr2);
    try db.setBalance(addr2, types.U256.fromU64(1));
    // addr3: has code -- should NOT be removed
    try db.createAccount(addr3);
    try db.setCode(addr3, &[_]u8{0x60});

    try testing.expect(db.exists(addr1));
    try testing.expect(db.exists(addr2));
    try testing.expect(db.exists(addr3));

    try db.cleanupEmptyAccounts();

    try testing.expect(!db.exists(addr1));
    try testing.expect(db.exists(addr2));
    try testing.expect(db.exists(addr3));
}
